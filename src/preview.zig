//! Preview work and terminal-safe preview text for the picker.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const worker_allocator = std.heap.smp_allocator;
const lifecycle = @import("lifecycle.zig");
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

fn sleepMs(milliseconds: u32) void {
    if (builtin.os.tag == .windows) {
        Sleep(milliseconds);
    } else {
        const Timespec = extern struct { tv_sec: isize, tv_nsec: isize };
        const request: Timespec = .{ .tv_sec = milliseconds / 1000, .tv_nsec = @as(isize, milliseconds % 1000) * 1_000_000 };
        _ = std.os.linux.syscall2(.nanosleep, @intFromPtr(&request), 0);
    }
}

/// Job is the request a preview callback is serving, so a command it runs
/// can notice the cursor has moved on and stop early.
const Job = struct {
    worker: *Worker,
    generation: usize,

    fn superseded(self: Job) bool {
        self.worker.mutex.lock();
        defer self.worker.mutex.unlock();
        return self.worker.stopped or self.worker.generation != self.generation;
    }
};

threadlocal var current_job: ?Job = null;

pub const PreviewText = struct {
    /// SGR is retained by the renderer; other terminal escapes are dropped.
    text: []const u8,
    /// One-based source line to place a third of the way down the pane.
    focus_line: ?usize = null,
};

pub const Previewer = struct {
    ctx: *anyopaque,
    /// Runs on the preview thread. The result must be allocated in arena.
    /// Must return promptly when superseded by a new row or on shutdown.
    /// Glean joins the worker; the context must supply any cancellation signal
    /// needed by blocking work, since this callback has no stop-token argument.
    func: *const fn (ctx: *anyopaque, arena: Allocator, row: []const u8) anyerror!PreviewText,
};

const Mutex = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn lock(self: *Mutex) void {
        while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.held.store(false, .release);
    }
};

const Request = struct { id: usize, row: []u8 };
const Result = struct {
    id: usize,
    arena: std.heap.ArenaAllocator,
    value: PreviewText,

    fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};

pub const Worker = struct {
    previewer: Previewer,
    mutex: Mutex = .{},
    request: ?Request = null,
    published: ?Result = null,
    displayed: ?Result = null,
    generation: usize = 0,
    stopped: bool = false,
    thread: ?std.Thread = null,

    pub fn init(previewer: Previewer) Worker {
        return .{ .previewer = previewer };
    }

    pub fn start(self: *Worker) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn post(self: *Worker, id: usize, row: []const u8) !void {
        const copy = try worker_allocator.dupe(u8, row);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.request) |old| worker_allocator.free(old.row);
        self.request = .{ .id = id, .row = copy };
        self.generation +%= 1;
    }

    pub fn clear(self: *Worker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.request) |old| worker_allocator.free(old.row);
        self.request = null;
        self.generation +%= 1;
    }

    /// A stale result is discarded while the displayed result stays alive.
    pub fn take(self: *Worker, current_id: ?usize) ?PreviewText {
        self.mutex.lock();
        var fresh = self.published;
        self.published = null;
        self.mutex.unlock();
        if (fresh) |*result| {
            if (current_id != null and result.id == current_id.?) {
                if (self.displayed) |*old| old.deinit();
                self.displayed = result.*;
                return self.displayed.?.value;
            }
            result.deinit();
        }
        return null;
    }

    pub fn deinit(self: *Worker) void {
        self.mutex.lock();
        self.stopped = true;
        self.mutex.unlock();
        if (self.thread) |thread| thread.join();
        if (self.request) |request| worker_allocator.free(request.row);
        if (self.published) |*result| result.deinit();
        if (self.displayed) |*result| result.deinit();
    }

    fn run(self: *Worker) void {
        var seen: usize = 0;
        while (true) {
            self.mutex.lock();
            const stop = self.stopped;
            const generation = self.generation;
            const request = if (generation != seen) self.request else null;
            if (!stop and generation != seen) self.request = null;
            self.mutex.unlock();
            if (stop) return;
            if (generation == seen or request == null) {
                sleepMs(2);
                seen = generation;
                continue;
            }
            seen = generation;
            const work = request.?;
            // No quiet interval: a preview starts at once, and one the cursor
            // has already left is abandoned (a command preview kills its
            // child) rather than waited out.
            var arena = std.heap.ArenaAllocator.init(worker_allocator);
            current_job = .{ .worker = self, .generation = generation };
            defer current_job = null;
            const value = self.previewer.func(self.previewer.ctx, arena.allocator(), work.row) catch |err| blk: {
                const message = std.fmt.allocPrint(arena.allocator(), "preview: {s}", .{@errorName(err)}) catch "preview: out of memory";
                break :blk PreviewText{ .text = message };
            };
            worker_allocator.free(work.row);
            self.mutex.lock();
            if (!self.stopped and self.generation == generation) {
                if (self.published) |*old| old.deinit();
                self.published = .{ .id = work.id, .arena = arena, .value = value };
            } else {
                arena.deinit();
            }
            self.mutex.unlock();
        }
    }
};

pub const VisualLine = struct { text: []const u8, width: usize, source: usize };
pub const Formatted = struct { lines: []const VisualLine, focus_row: ?usize };

fn columns(cp: u21) usize {
    if ((cp >= 0x300 and cp <= 0x36f) or (cp >= 0x1ab0 and cp <= 0x1aff) or
        (cp >= 0x1dc0 and cp <= 0x1dff) or (cp >= 0x20d0 and cp <= 0x20ff) or
        (cp >= 0xfe20 and cp <= 0xfe2f) or (cp >= 0x3099 and cp <= 0x309a)) return 0;
    if ((cp >= 0x1100 and cp <= 0x115f) or (cp >= 0x2329 and cp <= 0x232a) or
        (cp >= 0x2e80 and cp <= 0xa4cf) or (cp >= 0xac00 and cp <= 0xd7a3) or
        (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0xfe10 and cp <= 0xfe19) or
        (cp >= 0xfe30 and cp <= 0xfe6f) or (cp >= 0xff01 and cp <= 0xff60) or
        (cp >= 0xffe0 and cp <= 0xffe6) or (cp >= 0x20000 and cp <= 0x3fffd)) return 2;
    return 1;
}

fn finishLine(arena: Allocator, lines: *std.ArrayList(VisualLine), line: *std.ArrayList(u8), used: usize, colors: bool, source: usize, focus: ?usize, focus_row: *?usize) !void {
    if (focus_row.* == null and focus != null and source == focus.?) focus_row.* = lines.items.len;
    if (colors) try line.appendSlice(arena, "\x1b[0m");
    try lines.append(arena, .{ .text = try line.toOwnedSlice(arena), .width = used, .source = source });
}

fn escapeEnd(text: []const u8, start: usize) usize {
    if (start + 1 >= text.len) return text.len;
    if (text[start + 1] == '[') {
        var end = start + 2;
        while (end < text.len and (text[end] < 0x40 or text[end] > 0x7e)) : (end += 1) {}
        return @min(end + 1, text.len);
    }
    if (text[start + 1] == ']' or text[start + 1] == 'P' or text[start + 1] == 'X' or
        text[start + 1] == '^' or text[start + 1] == '_')
    {
        var end = start + 2;
        while (end < text.len) : (end += 1) {
            if (text[end] == 7) return end + 1;
            if (text[end] == 0x1b and end + 1 < text.len and text[end + 1] == '\\') return end + 2;
        }
        return text.len;
    }
    var end = start + 1;
    while (end < text.len and text[end] >= 0x20 and text[end] <= 0x2f) : (end += 1) {}
    return @min(end + 1, text.len);
}

fn isSgr(text: []const u8) bool {
    if (text.len < 3 or text[0] != 0x1b or text[1] != '[' or text[text.len - 1] != 'm') return false;
    for (text[2 .. text.len - 1]) |byte| {
        if (!std.ascii.isDigit(byte) and byte != ';' and byte != ':') return false;
    }
    return true;
}

pub fn format(arena: Allocator, value: PreviewText, width: usize, wrap: bool, colors: bool) !Formatted {
    var lines: std.ArrayList(VisualLine) = .empty;
    var line: std.ArrayList(u8) = .empty;
    var used: usize = 0;
    var source: usize = 1;
    var focus_row: ?usize = null;
    var clipped = false;
    var i: usize = 0;
    while (i < value.text.len) {
        const byte = value.text[i];
        if (byte == '\n') {
            try finishLine(arena, &lines, &line, used, colors, source, value.focus_line, &focus_row);
            used = 0;
            clipped = false;
            source += 1;
            i += 1;
            continue;
        }
        if (byte == 0x1b) {
            const end = escapeEnd(value.text, i);
            if (!clipped and colors and isSgr(value.text[i..end])) try line.appendSlice(arena, value.text[i..end]);
            i = end;
            continue;
        }
        if (byte == '\r' or (byte < 0x20 and byte != '\t') or byte == 0x7f) {
            i += 1;
            continue;
        }
        if (byte == '\t') {
            const spaces = 4 - used % 4;
            for (0..spaces) |_| {
                if (!clipped and wrap and width > 0 and used == width) {
                    try finishLine(arena, &lines, &line, used, colors, source, value.focus_line, &focus_row);
                    used = 0;
                }
                if (!clipped and used < width) {
                    try line.append(arena, ' ');
                    used += 1;
                } else if (!wrap or width == 0) {
                    clipped = true;
                }
            }
            i += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        const end = @min(i + length, value.text.len);
        const decoded = std.unicode.utf8Decode(value.text[i..end]) catch null;
        const count = if (decoded) |cp| columns(cp) else 1;
        if (!clipped and wrap and width > 0 and used > 0 and used + count > width) {
            try finishLine(arena, &lines, &line, used, colors, source, value.focus_line, &focus_row);
            used = 0;
        }
        if (!clipped and width > 0 and used + count <= width) {
            if (decoded != null) try line.appendSlice(arena, value.text[i..end]) else try line.append(arena, '?');
            used += count;
        } else if (!wrap or width == 0) {
            clipped = true;
        }
        i = if (decoded != null) end else i + 1;
    }
    if (value.text.len == 0 or value.text[value.text.len - 1] != '\n') {
        try finishLine(arena, &lines, &line, used, colors, source, value.focus_line, &focus_row);
    }
    return .{ .lines = try lines.toOwnedSlice(arena), .focus_row = focus_row };
}

/// Return numbered text. The picker colors focus_line with its `hl` color.
const max_preview_bytes = 1024 * 1024;

pub fn textPreview(arena: Allocator, io: std.Io, path: []const u8, focus_line: ?usize) !PreviewText {
    return textPreviewFromDir(arena, io, std.Io.Dir.cwd(), path, focus_line);
}

fn textPreviewFromDir(arena: Allocator, io: std.Io, base: std.Io.Dir, path: []const u8, focus_line: ?usize) !PreviewText {
    if (base.openDir(io, path, .{ .iterate = true })) |dir| {
        return directoryPreview(arena, io, dir);
    } else |_| {}
    // A pane shows a screenful, and the cursor may land on a multi-GB log:
    // read only the head of the file.
    const file = try base.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const head = try arena.alloc(u8, max_preview_bytes);
    const bytes = head[0..try reader.interface.readSliceShort(head)];
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return .{ .text = "(binary file)" };
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    var number: usize = 1;
    while (it.next()) |raw| : (number += 1) {
        if (it.index == null and raw.len == 0 and bytes.len > 0 and bytes[bytes.len - 1] == '\n') break;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const mark = if (focus_line != null and focus_line.? == number) ">" else " ";
        try out.appendSlice(arena, try std.fmt.allocPrint(arena, "{s}{d}: {s}\n", .{ mark, number, line }));
    }
    return .{ .text = try out.toOwnedSlice(arena), .focus_line = focus_line };
}

fn directoryPreview(arena: Allocator, io: std.Io, opened: std.Io.Dir) !PreviewText {
    var dir = opened;
    defer dir.close(io);
    var iterator = dir.iterate();
    var out: std.ArrayList(u8) = .empty;
    while (try iterator.next(io)) |entry| {
        try out.appendSlice(arena, entry.name);
        if (entry.kind == .directory) try out.append(arena, '/');
        try out.append(arena, '\n');
    }
    return .{ .text = try out.toOwnedSlice(arena) };
}

pub const Command = struct {
    io: std.Io,
    argv: []const []const u8,
    /// Bounds the direct child's lifetime. Descendants must not retain stdout:
    /// inherited writers can prevent the reader from reaching timeout cleanup.
    timeout_ms: u32 = 3000,
    /// Legacy shell-source substitution, unsafe for untrusted rows or arbitrary
    /// quoting contexts. Prefer whole-argument substitution with this disabled.
    shell_quote: bool = false,
};

/// Each argv element equal to "{}" becomes the row. With shell_quote set,
/// embedded "{}" tokens are replaced with a shell-quoted row as well.
pub fn commandPreviewer(command: *Command) Previewer {
    return .{ .ctx = command, .func = commandRun };
}

fn quotedRow(arena: Allocator, row: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (builtin.os.tag == .windows) {
        try out.append(arena, '"');
        for (row) |byte| {
            if (byte == '"') try out.append(arena, '"');
            if (byte == '%' or byte == '!') try out.append(arena, '^');
            try out.append(arena, byte);
        }
        try out.append(arena, '"');
    } else {
        try out.append(arena, '\'');
        for (row) |byte| {
            if (byte == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, byte);
        }
        try out.append(arena, '\'');
    }
    return out.toOwnedSlice(arena);
}

fn replaceTokens(arena: Allocator, template: []const u8, row: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = template;
    while (std.mem.indexOf(u8, rest, "{}")) |at| {
        try out.appendSlice(arena, rest[0..at]);
        try out.appendSlice(arena, row);
        rest = rest[at + 2 ..];
    }
    try out.appendSlice(arena, rest);
    return out.toOwnedSlice(arena);
}

const Watchdog = struct {
    const State = enum(u8) { running, reaping_by_main, killed_by_watchdog };
    child: *std.process.Child,
    io: std.Io,
    timeout_ms: u32,
    job: ?Job = null,
    state: std.atomic.Value(State) = .init(.running),
    gate: Mutex = .{},

    fn claim(self: *Watchdog, target: State, require_exit: bool) bool {
        // The gate also protects probing the handle from concurrent closure.
        self.gate.lock();
        defer self.gate.unlock();
        if (self.state.load(.acquire) != .running) return false;
        if (require_exit and !lifecycle.exited(self.child)) return false;
        return self.state.cmpxchgStrong(.running, target, .acq_rel, .acquire) == null;
    }

    fn run(self: *Watchdog) void {
        var waited: u32 = 0;
        while (waited < self.timeout_ms) {
            if (self.state.load(.acquire) != .running) return;
            if (self.job) |job| if (job.superseded()) break;
            const interval = @min(10, self.timeout_ms - waited);
            sleepMs(interval);
            waited += interval;
        }
        if (self.claim(.killed_by_watchdog, false)) {
            self.child.kill(self.io);
        }
    }
};

fn commandRun(ctx: *anyopaque, arena: Allocator, row: []const u8) !PreviewText {
    const command: *Command = @ptrCast(@alignCast(ctx));
    const argv = try arena.alloc([]const u8, command.argv.len);
    const quoted = if (command.shell_quote) try quotedRow(arena, row) else row;
    for (command.argv, argv) |arg, *item| {
        item.* = if (command.shell_quote)
            try replaceTokens(arena, arg, quoted)
        else if (std.mem.eql(u8, arg, "{}"))
            row
        else
            arg;
    }
    var child = try std.process.spawn(command.io, .{ .argv = argv, .stdout = .pipe, .stderr = .ignore });
    const output = child.stdout.?;
    // Keep the reader's handle alive while the watchdog reaps the child.
    child.stdout = null;
    defer output.close(command.io);
    var watchdog: Watchdog = .{ .child = &child, .io = command.io, .timeout_ms = command.timeout_ms, .job = current_job };
    const thread = std.Thread.spawn(.{}, Watchdog.run, .{&watchdog}) catch |err| {
        child.kill(command.io);
        return err;
    };
    defer {
        if (watchdog.claim(.reaping_by_main, false)) child.kill(command.io);
        thread.join();
    }
    var out: std.ArrayList(u8) = .empty;
    var buffer: [8192]u8 = undefined;
    while (true) {
        const size = lifecycle.readSize(output.readStreaming(command.io, &.{buffer[0..]})) catch |err| {
            if (watchdog.state.load(.acquire) == .killed_by_watchdog) break;
            return err;
        };
        if (size == 0) break;
        if (out.items.len + size > 8 * 1024 * 1024) {
            return .{ .text = "(preview output too large)" };
        }
        try out.appendSlice(arena, buffer[0..size]);
    }
    while (watchdog.state.load(.acquire) == .running) {
        if (watchdog.claim(.reaping_by_main, true)) {
            _ = try child.wait(command.io);
            return .{ .text = try out.toOwnedSlice(arena) };
        }
        lifecycle.waitExit(&child, 5);
    }
    return .{ .text = "(preview timed out)" };
}

fn emptyPreview(_: *anyopaque, _: Allocator, _: []const u8) anyerror!PreviewText {
    return .{ .text = "" };
}

test "stopping before a queued request leaves ownership with deinit" {
    var dummy: u8 = 0;
    var worker = Worker.init(.{ .ctx = &dummy, .func = emptyPreview });
    defer worker.deinit();
    try worker.post(1, "row");
    worker.stopped = true;
    worker.run();
    try std.testing.expect(worker.request != null);
}

test "preview formatting retains SGR, drops other escapes, and resets lines" {
    const arena = std.testing.allocator;
    const content = try format(arena, .{ .text = "\x1b[31mA\x1b[2JB\x1b(0\x1b]title\x07\nC" }, 4, false, true);
    defer {
        for (content.lines) |line| arena.free(line.text);
        arena.free(content.lines);
    }
    try std.testing.expectEqual(@as(usize, 2), content.lines.len);
    try std.testing.expectEqual(@as(usize, 2), content.lines[0].width);
    try std.testing.expect(std.mem.startsWith(u8, content.lines[0].text, "\x1b[31mAB"));
    try std.testing.expect(std.mem.endsWith(u8, content.lines[0].text, "\x1b[0m"));
    try std.testing.expect(std.mem.indexOf(u8, content.lines[0].text, "\x1b[2J") == null);
    try std.testing.expect(std.mem.endsWith(u8, content.lines[1].text, "\x1b[0m"));
}

test "preview tabs expand to four columns and CJK uses two" {
    const arena = std.testing.allocator;
    const content = try format(arena, .{ .text = "a\tb\u{65e5}" }, 12, false, false);
    defer {
        for (content.lines) |line| arena.free(line.text);
        arena.free(content.lines);
    }
    try std.testing.expectEqualStrings("a   b\u{65e5}", content.lines[0].text);
    try std.testing.expectEqual(@as(usize, 7), content.lines[0].width);
}

test "preview wraps at the display width" {
    const arena = std.testing.allocator;
    const content = try format(arena, .{ .text = "ab\t\u{65e5}" }, 4, true, false);
    defer {
        for (content.lines) |line| arena.free(line.text);
        arena.free(content.lines);
    }
    try std.testing.expectEqual(@as(usize, 2), content.lines.len);
    try std.testing.expectEqualStrings("ab  ", content.lines[0].text);
    try std.testing.expectEqualStrings("\u{65e5}", content.lines[1].text);
    try std.testing.expectEqual(@as(usize, 2), content.lines[1].width);
}

test "stale preview results leave the displayed result alive" {
    var dummy: u8 = 0;
    var worker = Worker.init(.{ .ctx = &dummy, .func = emptyPreview });
    defer worker.deinit();
    worker.published = .{ .id = 1, .arena = std.heap.ArenaAllocator.init(worker_allocator), .value = .{ .text = "first" } };
    try std.testing.expectEqualStrings("first", worker.take(1).?.text);
    worker.published = .{ .id = 2, .arena = std.heap.ArenaAllocator.init(worker_allocator), .value = .{ .text = "stale" } };
    try std.testing.expect(worker.take(1) == null);
    try std.testing.expectEqualStrings("first", worker.displayed.?.value.text);
}

test "text preview numbers a file and detects binary data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "small.txt", .data = "one\ntwo\nthree\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "binary.dat", .data = "a\x00b" });
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    const numbered = try textPreviewFromDir(result_arena.allocator(), std.testing.io, tmp.dir, "small.txt", 2);
    try std.testing.expectEqualStrings(" 1: one\n>2: two\n 3: three\n", numbered.text);
    try std.testing.expectEqual(@as(?usize, 2), numbered.focus_line);
    const binary = try textPreviewFromDir(result_arena.allocator(), std.testing.io, tmp.dir, "binary.dat", null);
    try std.testing.expectEqualStrings("(binary file)", binary.text);
    const directory = try textPreviewFromDir(result_arena.allocator(), std.testing.io, tmp.dir, ".", null);
    try std.testing.expect(std.mem.indexOf(u8, directory.text, "small.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, directory.text, "binary.dat") != null);
}

test "Windows command preview substitutes the row and times out" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var echo: Command = .{ .io = std.testing.io, .argv = &.{ "cmd.exe", "/d", "/c", "echo", "{}" } };
    const shown = try commandRun(&echo, arena, "hello");
    try std.testing.expectEqualStrings("hello", std.mem.trim(u8, shown.text, "\r\n"));
    var slow: Command = .{ .io = std.testing.io, .argv = &.{ "cmd.exe", "/d", "/c", "ping -n 4 127.0.0.1 >nul" }, .timeout_ms = 50 };
    const timed = try commandRun(&slow, arena, "unused");
    try std.testing.expectEqualStrings("(preview timed out)", timed.text);
}

test "preview timeout covers exit after stdout closes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var command: Command = .{
        .io = std.testing.io,
        .argv = &.{ "python", "-c", "import os,time;os.close(1);time.sleep(2)" },
        .timeout_ms = 300,
    };
    const start = lifecycle.GetTickCount64();
    const result = try commandRun(&command, arena.allocator(), "unused");
    try std.testing.expectEqualStrings("(preview timed out)", result.text);
    try std.testing.expect(lifecycle.GetTickCount64() - start < 1500);
}

test "harness preview passes shell metacharacters as one literal argument" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var command: Command = .{ .io = std.testing.io, .argv = try @import("preview_template.zig").parse(arena.allocator(), "python -c \"import sys;sys.stdout.write(sys.argv[1])\" \"{}\"") };
    const row = "a&echo R1_INJECTED";
    const result = try commandRun(&command, arena.allocator(), row);
    try std.testing.expectEqualStrings(row, result.text);
}

test "a command preview the cursor has left is killed, so the next row's preview is not held up" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var command: Command = .{
        .io = std.testing.io,
        .argv = &.{ "python", "-c", "import sys,time\nif sys.argv[1]=='slow': time.sleep(5)\nprint(sys.argv[1])", "{}" },
        .timeout_ms = 10_000,
    };
    var worker = Worker.init(commandPreviewer(&command));
    try worker.start();
    defer worker.deinit();
    try worker.post(1, "slow");
    sleepMs(500);
    try worker.post(2, "fast");
    const started = lifecycle.GetTickCount64();
    while (lifecycle.GetTickCount64() - started < 3000) : (sleepMs(10)) {
        if (worker.take(2)) |value| {
            try std.testing.expect(std.mem.startsWith(u8, value.text, "fast"));
            return;
        }
    }
    return error.TestExpectedPreview;
}
