//! Append-only row feeds for the picker and noninteractive collection.

const std = @import("std");
const builtin = @import("builtin");
const pick = @import("pick.zig");
const tui = @import("tui.zig");
const lifecycle = @import("lifecycle.zig");

const Allocator = std.mem.Allocator;
// Rows are allocated one by one on the reader thread and read by the UI
// thread, so this must be thread-safe - and not page_allocator, which spends
// a whole page per row.
const reader_allocator = std.heap.smp_allocator;

const Mutex = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn lock(self: *Mutex) void {
        while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Mutex) void {
        self.held.store(false, .release);
    }
};

fn stripCr(line: []const u8) []const u8 {
    return if (line.len != 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

extern "kernel32" fn GetFileType(handle: *anyopaque) callconv(.winapi) u32;
extern "kernel32" fn PeekNamedPipe(handle: *anyopaque, buffer: ?*anyopaque, size: u32, read: ?*u32, available: ?*u32, left: ?*u32) callconv(.winapi) i32;
extern "kernel32" fn CancelSynchronousIo(handle: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

pub const LineFilter = struct {
    ctx: *anyopaque,
    /// Return the row to keep (a subslice of line is fine) or null to drop it.
    func: *const fn (ctx: *anyopaque, line: []const u8) ?[]const u8,
};

pub const Source = union(enum) {
    /// Only the direct child is terminated. Descendants must not retain stdout
    /// after it exits; glean joins the reader and cannot cancel inherited pipes.
    command: struct {
        argv: []const []const u8,
        cwd: ?[]const u8 = null,
        env: ?*const std.process.Environ.Map = null,
        quiet_stderr: bool = false,
    },
    stdin,
    callback: struct {
        ctx: *anyopaque,
        /// Must return promptly when push returns false. Glean joins this callback
        /// on shutdown; blocking work must provide its own cancellation mechanism.
        func: *const fn (ctx: *anyopaque, sink: *Sink) anyerror!void,
    },
};

pub const Feed = struct {
    source: Source,
    filter: ?LineFilter = null,
    max_rows: usize = 0,
};

pub const FeedOutcome = union(enum) {
    picked: []const []const u8,
    cancelled,
    no_console,
    empty,
};

const Status = struct { count: usize, done: bool, eof: bool, capped: bool, failure: ?anyerror };

const Shared = struct {
    mutex: Mutex = .{},
    rows: std.ArrayList([]const u8) = .empty,
    filter: ?LineFilter,
    max_rows: usize,
    stopped: bool = false,
    done: bool = false,
    eof: bool = false,
    capped: bool = false,
    failure: ?anyerror = null,

    fn status(self: *Shared) Status {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .count = self.rows.items.len, .done = self.done, .eof = self.eof, .capped = self.capped, .failure = self.failure };
    }

    fn isStopped(self: *Shared) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stopped or self.capped or self.failure != null;
    }

    fn stop(self: *Shared) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopped = true;
    }

    fn finish(self: *Shared, eof: bool, failure: ?anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.done = true;
        self.eof = eof;
        if (failure) |err| self.failure = err;
    }

    fn snapshot(self: *Shared, allocator: Allocator, from: usize) ![]const []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return try allocator.dupe([]const u8, self.rows.items[from..]);
    }

    fn deinit(self: *Shared) void {
        for (self.rows.items) |row| reader_allocator.free(row);
        self.rows.deinit(reader_allocator);
    }
};

pub const Sink = struct {
    shared: *Shared,

    pub fn push(self: *Sink, line: []const u8) bool {
        if (self.shared.isStopped()) return false;
        const kept = if (self.shared.filter) |filter| filter.func(filter.ctx, line) orelse return !self.shared.isStopped() else line;
        const copy = reader_allocator.dupe(u8, kept) catch {
            self.shared.finish(false, error.OutOfMemory);
            return false;
        };
        self.shared.mutex.lock();
        defer self.shared.mutex.unlock();
        if (self.shared.stopped or self.shared.capped or self.shared.failure != null) {
            reader_allocator.free(copy);
            return false;
        }
        self.shared.rows.append(reader_allocator, copy) catch {
            reader_allocator.free(copy);
            self.shared.failure = error.OutOfMemory;
            return false;
        };
        if (self.shared.max_rows != 0 and self.shared.rows.items.len >= self.shared.max_rows) {
            self.shared.capped = true;
            return false;
        }
        return true;
    }
};

const Splitter = struct {
    pending: std.ArrayList(u8) = .empty,

    fn add(self: *Splitter, sink: *Sink, bytes: []const u8) !bool {
        var rest = bytes;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |line_end| {
            try self.pending.appendSlice(reader_allocator, rest[0..line_end]);
            if (!sink.push(stripCr(self.pending.items))) return false;
            self.pending.clearRetainingCapacity();
            rest = rest[line_end + 1 ..];
        }
        try self.pending.appendSlice(reader_allocator, rest);
        return true;
    }

    fn end(self: *Splitter, sink: *Sink) void {
        if (self.pending.items.len != 0) _ = sink.push(stripCr(self.pending.items));
    }

    fn deinit(self: *Splitter) void {
        self.pending.deinit(reader_allocator);
    }
};

const Session = struct {
    io: std.Io,
    feed: Feed,
    shared: Shared,
    child: ?std.process.Child = null,
    output: ?std.Io.File = null,
    thread: ?std.Thread = null,
    completed: bool = false,

    fn init(io: std.Io, feed: Feed) Session {
        return .{ .io = io, .feed = feed, .shared = .{ .filter = feed.filter, .max_rows = feed.max_rows } };
    }

    fn start(self: *Session) !void {
        if (self.feed.source == .command) {
            const command = self.feed.source.command;
            self.child = try std.process.spawn(self.io, .{
                .argv = command.argv,
                .cwd = if (command.cwd) |path| .{ .path = path } else .inherit,
                .environ_map = command.env,
                .stdout = .pipe,
                .stderr = if (command.quiet_stderr) .ignore else .inherit,
            });
            // Reaping closes Child's streams; the reader owns this one until join.
            self.output = self.child.?.stdout;
            self.child.?.stdout = null;
        }
        errdefer {
            if (self.child) |*child| child.kill(self.io);
            if (self.output) |file| file.close(self.io);
            self.output = null;
            self.child = null;
        }
        self.thread = try std.Thread.spawn(.{}, readerMain, .{ self, self.output });
    }

    fn readRows(self: *Session, file: std.Io.File, sink: *Sink, is_stdin: bool) !bool {
        var splitter: Splitter = .{};
        defer splitter.deinit();
        var buffer: [16 * 1024]u8 = undefined;
        const piped_stdin = builtin.os.tag == .windows and is_stdin and GetFileType(file.handle) == 3;
        while (!self.shared.isStopped()) {
            if (piped_stdin) {
                var available: u32 = 0;
                if (PeekNamedPipe(file.handle, null, 0, null, &available, null) == 0) {
                    try pipeEnd(GetLastError());
                    splitter.end(sink);
                    return true;
                }
                if (available == 0) {
                    Sleep(10);
                    continue;
                }
            }
            const size = lifecycle.readSize(file.readStreaming(self.io, &.{buffer[0..]})) catch |err| {
                if (err == error.Canceled and self.shared.isStopped()) return false;
                return err;
            };
            if (size == 0) {
                splitter.end(sink);
                return true;
            }
            if (!try splitter.add(sink, buffer[0..size])) return false;
        }
        return false;
    }

    fn readerMain(self: *Session, output: ?std.Io.File) void {
        var sink: Sink = .{ .shared = &self.shared };
        const eof = switch (self.feed.source) {
            .command => self.readRows(output.?, &sink, false),
            .stdin => self.readRows(std.Io.File.stdin(), &sink, true),
            .callback => |callback| blk: {
                callback.func(callback.ctx, &sink) catch |err| break :blk @as(anyerror!bool, err);
                break :blk @as(anyerror!bool, true);
            },
        } catch |err| {
            self.shared.finish(false, err);
            return;
        };
        self.shared.finish(eof, null);
    }

    fn complete(self: *Session, stop: bool) void {
        if (self.completed) return;
        if (stop) {
            self.shared.stop();
            if (self.child) |*child| {
                child.kill(self.io);
            } else if (builtin.os.tag == .windows and self.feed.source == .stdin) {
                if (self.thread) |thread| cancelReader(&self.shared, thread, interruptThread);
            }
        }
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (!stop) {
            const status = self.shared.status();
            if (self.child) |*child| {
                if (status.eof and !status.capped) {
                    lifecycle.reapBounded(child, self.io, 200);
                } else {
                    child.kill(self.io);
                }
            }
        }
        if (self.output) |file| file.close(self.io);
        self.output = null;
        self.completed = true;
    }

    fn deinit(self: *Session) void {
        self.complete(true);
        self.shared.deinit();
    }
};

fn finishRows(shared: *Shared, state: *pick.State, displayed: usize) !void {
    // Done is published after the last append, so this snapshot is final.
    const final = try shared.snapshot(reader_allocator, displayed);
    defer reader_allocator.free(final);
    if (final.len != 0) try state.appendRows(final);
    try state.refreshRows();
}

fn cancelReader(shared: *Shared, context: anytype, comptime cancel: fn (@TypeOf(context)) void) void {
    // Keep cancelling until the reader acknowledges exit: it may enter read
    // after the first cancellation found no pending synchronous operation.
    while (!shared.status().done) {
        cancel(context);
        lifecycle.sleepMs(1);
    }
}

fn pipeEnd(code: u32) !void {
    switch (code) {
        109, 233 => return,
        5 => return error.AccessDenied,
        else => return error.InputOutput,
    }
}

fn interruptThread(thread: std.Thread) void {
    _ = CancelSynchronousIo(thread.getHandle());
}

pub fn collect(arena: Allocator, io: std.Io, feed: Feed) ![]const []const u8 {
    var session = Session.init(io, feed);
    defer session.deinit();
    try session.start();
    session.complete(false);
    const status = session.shared.status();
    if (status.failure) |err| return err;
    const snapshot = try session.shared.snapshot(reader_allocator, 0);
    defer reader_allocator.free(snapshot);
    const rows = try arena.alloc([]const u8, snapshot.len);
    for (snapshot, rows) |row, *copy| copy.* = try arena.dupe(u8, row);
    return rows;
}

pub fn pickFeed(arena: Allocator, io: std.Io, feed: Feed, opts: pick.Options) !FeedOutcome {
    var console = tui.Console.open() catch return .no_console;
    defer console.close();
    var session = Session.init(io, feed);
    defer session.deinit();
    var state = try pick.State.init(arena, &.{}, opts);
    defer state.deinit();
    try session.start();
    var frame_arena = std.heap.ArenaAllocator.init(arena);
    defer frame_arena.deinit();
    var preview_worker: ?pick.PreviewWorker = if (opts.preview) |callback| pick.PreviewWorker.init(callback) else null;
    if (preview_worker) |*worker| try worker.start();
    defer if (preview_worker) |*worker| worker.deinit();
    var last_preview_id: ?usize = null;
    const theme = pick.Theme.fromEnvironment(opts.colors);
    var running = true;
    var displayed: usize = 0;
    var pending_rows = false;
    var wakes: usize = 0;
    var draw = true;
    while (true) {
        if (preview_worker) |*worker| {
            if (try pick.syncPreview(&state, worker, &last_preview_id)) draw = true;
        }
        if (draw) {
            _ = frame_arena.reset(.retain_capacity);
            state.producer_running = running;
            const size = try console.size();
            const frame = try pick.render(&state, theme, size.width, size.height, console.vt, console.vt, frame_arena.allocator());
            try console.write(frame);
            draw = false;
        }
        if (!running) {
            const key = if (preview_worker != null) try console.pollKey(50) else try console.readKey();
            if (key) |pressed| {
                if (try state.step(pressed)) |outcome| return try selected(arena, &state, outcome);
                draw = true;
            }
            continue;
        }
        if (try console.pollKey(50)) |key| {
            if (try state.step(key)) |outcome| return try selected(arena, &state, outcome);
            draw = true;
        }
        const fresh = try session.shared.snapshot(reader_allocator, displayed);
        defer reader_allocator.free(fresh);
        if (fresh.len != 0) {
            try state.appendRows(fresh);
            displayed += fresh.len;
            pending_rows = true;
        }
        const status = session.shared.status();
        if (status.failure) |err| return err;
        if (status.done) {
            session.complete(false);
            try finishRows(&session.shared, &state, displayed);
            if (state.rows.len == 0) return .empty;
            running = false;
            draw = true;
        } else {
            state.spinner_frame += 1;
            wakes += 1;
            if (wakes >= 2) {
                if (pending_rows) try state.refreshRows();
                pending_rows = false;
                wakes = 0;
                draw = true;
            }
        }
    }
}

fn selected(arena: Allocator, state: *pick.State, outcome: pick.Outcome) !FeedOutcome {
    return switch (outcome) {
        .cancelled => .cancelled,
        .no_console => .no_console,
        .picked => |indices| blk: {
            defer arena.free(indices);
            const rows = try arena.alloc([]const u8, indices.len);
            for (indices, rows) |index, *row| row.* = try arena.dupe(u8, state.rowText(index));
            break :blk .{ .picked = rows };
        },
    };
}

fn testPreview(_: *anyopaque, _: Allocator, _: []const u8) anyerror!pick.PreviewText {
    return .{ .text = "" };
}

test "preview layout and focused line share the screen with the list" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    var state = try pick.State.init(a, &.{"row"}, .{ .preview = .{ .ctx = &dummy, .func = testPreview } });
    defer state.deinit();
    state.setPreview(.{ .text = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11", .focus_line = 8 });
    const frame = try pick.render(&state, .{}, 40, 20, false, false, a);
    defer a.free(frame);
    var lines = std.mem.splitSequence(u8, frame, "\r\n");
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (index == 2) try std.testing.expect(std.mem.startsWith(u8, line, " 8"));
        if (index == 8) {
            try std.testing.expectEqual(@as(usize, 40), line.len);
            for (line) |byte| try std.testing.expectEqual(@as(u8, '-'), byte);
        }
        if (index == 17) try std.testing.expect(std.mem.startsWith(u8, line, ">  row"));
        if (index == 18) try std.testing.expect(std.mem.startsWith(u8, line, "1/1"));
        if (index == 19) try std.testing.expect(std.mem.startsWith(u8, line, "> "));
    }
    try std.testing.expectEqual(@as(usize, 20), index);
    try std.testing.expectEqual(@as(usize, 5), state.preview_scroll);
    _ = try state.step(.shift_down);
    try std.testing.expectEqual(@as(usize, 6), state.preview_scroll);
    _ = try state.step(.shift_up);
    try std.testing.expectEqual(@as(usize, 5), state.preview_scroll);
    const small = try pick.render(&state, .{}, 40, 7, false, false, a);
    defer a.free(small);
    try std.testing.expectEqual(@as(usize, 0), state.preview_height);
}

test "splitter handles CR, split reads, and a final line" {
    var shared: Shared = .{ .filter = null, .max_rows = 0 };
    defer shared.deinit();
    var sink: Sink = .{ .shared = &shared };
    var splitter: Splitter = .{};
    defer splitter.deinit();
    try std.testing.expect(try splitter.add(&sink, "a\r\nlon"));
    try std.testing.expect(try splitter.add(&sink, "g\nlast"));
    splitter.end(&sink);
    try std.testing.expectEqual(@as(usize, 3), shared.rows.items.len);
    try std.testing.expectEqualStrings("a", shared.rows.items[0]);
    try std.testing.expectEqualStrings("long", shared.rows.items[1]);
    try std.testing.expectEqualStrings("last", shared.rows.items[2]);
}

fn keepNotSkip(_: *anyopaque, line: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, "skip")) return null;
    return line;
}

test "filter and cap count only kept rows" {
    var dummy: u8 = 0;
    var shared: Shared = .{ .filter = .{ .ctx = &dummy, .func = keepNotSkip }, .max_rows = 2 };
    defer shared.deinit();
    var sink: Sink = .{ .shared = &shared };
    try std.testing.expect(sink.push("skip one"));
    try std.testing.expect(sink.push("one"));
    try std.testing.expect(sink.push("skip two"));
    try std.testing.expect(!sink.push("two"));
    try std.testing.expect(!sink.push("three"));
    try std.testing.expectEqual(@as(usize, 2), shared.status().count);
}

fn appendMany(shared: *Shared) void {
    var sink: Sink = .{ .shared = shared };
    for (0..2000) |_| {
        if (!sink.push("row")) break;
    }
    shared.finish(true, null);
}

test "snapshots remain valid while rows append" {
    var shared: Shared = .{ .filter = null, .max_rows = 0 };
    defer shared.deinit();
    const thread = try std.Thread.spawn(.{}, appendMany, .{&shared});
    defer thread.join();
    var previous: usize = 0;
    while (true) {
        const snapshot = try shared.snapshot(reader_allocator, 0);
        defer reader_allocator.free(snapshot);
        try std.testing.expect(snapshot.len >= previous);
        for (snapshot) |row| try std.testing.expectEqualStrings("row", row);
        previous = snapshot.len;
        if (shared.status().done) break;
    }
    try std.testing.expectEqual(@as(usize, 2000), shared.status().count);
}

const Counter = struct { calls: usize = 0 };

fn produceRows(ctx: *anyopaque, sink: *Sink) anyerror!void {
    const counter: *Counter = @ptrCast(@alignCast(ctx));
    for (0..10_000) |_| {
        counter.calls += 1;
        if (!sink.push("row")) break;
    }
}

test "callback collection and cap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var counter: Counter = .{};
    const source: Source = .{ .callback = .{ .ctx = &counter, .func = produceRows } };
    const all = try collect(arena_state.allocator(), std.testing.io, .{ .source = source });
    try std.testing.expectEqual(@as(usize, 10_000), all.len);
    try std.testing.expectEqual(@as(usize, 10_000), counter.calls);
    counter.calls = 0;
    const capped = try collect(arena_state.allocator(), std.testing.io, .{ .source = source, .max_rows = 10 });
    try std.testing.expectEqual(@as(usize, 10), capped.len);
    try std.testing.expectEqual(@as(usize, 10), counter.calls);
}

test "Windows command collection and early cap" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const source: Source = .{ .command = .{ .argv = &.{ "cmd.exe", "/d", "/c", "for /l %i in (1,1,3000) do @echo row%i" } } };
    const all = try collect(arena_state.allocator(), std.testing.io, .{ .source = source });
    try std.testing.expectEqual(@as(usize, 3000), all.len);
    try std.testing.expectEqualStrings("row1", all[0]);
    try std.testing.expectEqualStrings("row3000", all[2999]);
    const capped = try collect(arena_state.allocator(), std.testing.io, .{ .source = source, .max_rows = 100 });
    try std.testing.expectEqual(@as(usize, 100), capped.len);
}

test "done handling consumes rows published after the earlier snapshot" {
    var shared: Shared = .{ .filter = null, .max_rows = 0 };
    defer shared.deinit();
    var sink: Sink = .{ .shared = &shared };
    try std.testing.expect(sink.push("first"));
    const early = try shared.snapshot(std.testing.allocator, 0);
    defer std.testing.allocator.free(early);
    var state = try pick.State.init(std.testing.allocator, early, .{});
    defer state.deinit();
    try std.testing.expect(sink.push("final"));
    shared.finish(true, null);
    try std.testing.expect(shared.status().done);
    try finishRows(&shared, &state, early.len);
    try std.testing.expectEqual(@as(usize, 2), state.rows.len);
    try std.testing.expectEqualStrings("final", state.rows[1]);
}

test "EOF collection with a cap bounds process reaping" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source: Source = .{ .command = .{ .argv = &.{ "python", "-c", "import os,time;os.write(1,b'row\\n');os.close(1);time.sleep(2)" } } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]usize{ 1, 2 }) |cap| {
        const start = lifecycle.GetTickCount64();
        const rows = try collect(arena.allocator(), std.testing.io, .{ .source = source, .max_rows = cap });
        try std.testing.expectEqual(@as(usize, 1), rows.len);
        try std.testing.expect(lifecycle.GetTickCount64() - start < 1500);
    }
}

test "cancelling after EOF kills a child that has not exited" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const source: Source = .{ .command = .{ .argv = &.{ "python", "-c", "import os,time;os.close(1);time.sleep(2)" } } };
    var session = Session.init(std.testing.io, .{ .source = source });
    defer session.deinit();
    try session.start();
    session.thread.?.join();
    session.thread = null;
    try std.testing.expect(session.shared.status().eof);
    const start = lifecycle.GetTickCount64();
    session.complete(true);
    try std.testing.expect(lifecycle.GetTickCount64() - start < 1000);
}

test "stdin cancellation retries when read enters after the first cancel" {
    const FakeReader = struct {
        shared: Shared = .{ .filter = null, .max_rows = 0 },
        calls: usize = 0,
        fn cancel(self: *@This()) void {
            self.calls += 1;
            // The first cancellation precedes read entry; the second reaches it.
            if (self.calls == 2) self.shared.finish(false, null);
        }
    };
    var reader: FakeReader = .{};
    reader.shared.stop();
    cancelReader(&reader.shared, &reader, FakeReader.cancel);
    try std.testing.expect(reader.shared.status().done);
    try std.testing.expectEqual(@as(usize, 2), reader.calls);
}
