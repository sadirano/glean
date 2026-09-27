const std = @import("std");
const builtin = @import("builtin");
const stream = @import("stream.zig");
const pick = @import("pick.zig");
const fuzzy = @import("fuzzy.zig");

const usage = "usage: glean [--multi] [--prompt TEXT] [--header-lines N] [--delimiter C] [--with-nth N..] [--max-rows N] [--filter QUERY] [--preview COMMAND | --preview-text] [--preview-window up:N%[:wrap]] [FILE | -- COMMAND...]\n";

const FileRows = struct { rows: []const []const u8 };

fn pushFileRows(ctx: *anyopaque, sink: *stream.Sink) anyerror!void {
    const source: *FileRows = @ptrCast(@alignCast(ctx));
    for (source.rows) |row| if (!sink.push(row)) break;
}

const TextContext = struct { io: std.Io };

fn showText(ctx: *anyopaque, arena: std.mem.Allocator, row: []const u8) anyerror!pick.PreviewText {
    const source: *TextContext = @ptrCast(@alignCast(ctx));
    var path = row;
    var focus: ?usize = null;
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, row, at, ':')) |colon| {
        at = colon + 1;
        const end = std.mem.indexOfScalarPos(u8, row, at, ':') orelse break;
        const number = std.fmt.parseInt(usize, row[at..end], 10) catch continue;
        if (number == 0) continue;
        path = row[0..colon];
        focus = number;
        break;
    }
    return pick.textPreview(arena, source.io, path, focus);
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const code = try run(init, arena, args[1..]);
    if (code != 0) std.process.exit(code);
}

fn run(init: std.process.Init, arena: std.mem.Allocator, args: []const []const u8) !u8 {
    const io = init.io;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const err = &stderr_writer.interface;
    var opts: pick.Options = .{};
    var file: ?[]const u8 = null;
    var filter: ?[]const u8 = null;
    var command: ?[]const []const u8 = null;
    var preview_line: ?[]const u8 = null;
    var preview_text = false;
    var max_rows: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            if (file != null or i + 1 >= args.len) {
                try err.writeAll(usage);
                try err.flush();
                return 2;
            }
            command = args[i + 1 ..];
            break;
        }
        if (std.mem.eql(u8, arg, "--multi")) {
            opts.multi = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--preview-text")) {
            preview_text = true;
            preview_line = null;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            if (!std.mem.eql(u8, arg, "--prompt") and
                !std.mem.eql(u8, arg, "--header-lines") and
                !std.mem.eql(u8, arg, "--delimiter") and
                !std.mem.eql(u8, arg, "--with-nth") and
                !std.mem.eql(u8, arg, "--max-rows") and
                !std.mem.eql(u8, arg, "--preview") and
                !std.mem.eql(u8, arg, "--preview-window") and
                !std.mem.eql(u8, arg, "--filter"))
            {
                try err.print("glean: unknown option {s}\n", .{arg});
                try err.flush();
                return 2;
            }
            if (i + 1 >= args.len) {
                try err.print("glean: missing value for {s}\n", .{arg});
                try err.flush();
                return 2;
            }
            i += 1;
            const value = args[i];
            if (std.mem.eql(u8, arg, "--filter")) {
                filter = value;
            } else if (std.mem.eql(u8, arg, "--preview")) {
                preview_line = value;
                preview_text = false;
            } else if (std.mem.eql(u8, arg, "--preview-window")) {
                const prefix = "up:";
                if (!std.mem.startsWith(u8, value, prefix)) {
                    try err.print("glean: unsupported preview window {s}\n", .{value});
                    try err.flush();
                    return 2;
                }
                const spec = value[prefix.len..];
                const percent_end = std.mem.indexOfScalar(u8, spec, '%') orelse {
                    try err.print("glean: invalid preview window {s}\n", .{value});
                    try err.flush();
                    return 2;
                };
                const suffix = spec[percent_end + 1 ..];
                const percent = std.fmt.parseInt(u8, spec[0..percent_end], 10) catch 101;
                if (percent > 100 or (!std.mem.eql(u8, suffix, "") and !std.mem.eql(u8, suffix, ":wrap"))) {
                    try err.print("glean: invalid preview window {s}\n", .{value});
                    try err.flush();
                    return 2;
                }
                opts.preview_percent = percent;
                opts.preview_wrap = std.mem.eql(u8, suffix, ":wrap");
            } else if (std.mem.eql(u8, arg, "--max-rows")) {
                max_rows = std.fmt.parseInt(usize, value, 10) catch {
                    try err.print("glean: invalid value for {s}: {s}\n", .{ arg, value });
                    try err.flush();
                    return 2;
                };
            } else if (std.mem.eql(u8, arg, "--prompt")) {
                opts.prompt = value;
            } else if (std.mem.eql(u8, arg, "--header-lines")) {
                opts.header_lines = std.fmt.parseInt(usize, value, 10) catch {
                    try err.print("glean: invalid value for {s}: {s}\n", .{ arg, value });
                    try err.flush();
                    return 2;
                };
            } else if (std.mem.eql(u8, arg, "--delimiter")) {
                if (std.mem.eql(u8, value, "\\t")) {
                    opts.delimiter = '\t';
                } else if (value.len == 1) {
                    opts.delimiter = value[0];
                } else {
                    try err.print("glean: invalid value for {s}: {s}\n", .{ arg, value });
                    try err.flush();
                    return 2;
                }
            } else {
                if (value.len < 3 or !std.mem.endsWith(u8, value, "..")) {
                    try err.print("glean: invalid value for {s}: {s}\n", .{ arg, value });
                    try err.flush();
                    return 2;
                }
                opts.with_nth_from = std.fmt.parseInt(usize, value[0 .. value.len - 2], 10) catch 0;
                if (opts.with_nth_from == 0) {
                    try err.print("glean: invalid value for {s}: {s}\n", .{ arg, value });
                    try err.flush();
                    return 2;
                }
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            try err.print("glean: unknown option {s}\n", .{arg});
            try err.flush();
            return 2;
        }
        if (file != null) {
            try err.writeAll(usage);
            try err.flush();
            return 2;
        }
        file = arg;
    }

    opts.colors = init.minimal.environ.getAlloc(arena, "FZF_DEFAULT_OPTS") catch null;
    var text_context: TextContext = .{ .io = io };
    var preview_argv: [4][]const u8 = undefined;
    var command_preview: pick.CommandPreview = undefined;
    if (preview_text) {
        opts.preview = .{ .ctx = &text_context, .func = showText };
    } else if (preview_line) |line| {
        if (builtin.os.tag == .windows) {
            preview_argv = .{ "cmd.exe", "/d", "/c", line };
            command_preview = .{ .io = io, .argv = preview_argv[0..4], .shell_quote = true };
        } else {
            preview_argv = .{ "sh", "-c", line, "" };
            command_preview = .{ .io = io, .argv = preview_argv[0..3], .shell_quote = true };
        }
        opts.preview = pick.commandPreviewer(&command_preview);
    }
    var file_rows: FileRows = .{ .rows = &.{} };
    if (file) |path| file_rows.rows = try splitRows(arena, try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited));
    const feed: stream.Feed = .{
        .source = if (command) |argv|
            .{ .command = .{ .argv = argv } }
        else if (file != null)
            .{ .callback = .{ .ctx = &file_rows, .func = pushFileRows } }
        else
            .stdin,
        .max_rows = max_rows,
    };

    // fzf's --filter: rank without a UI, so the matcher can be compared
    // against fzf on the same input, for speed and for ranking.
    if (filter) |text| {
        // Nothing is shown until the end, so streaming buys nothing here, and
        // copying each row as it arrives costs two allocations per row: read
        // a file or a redirected file whole. A command or a pipe still goes
        // through the stream reader, which knows how to drain a Windows pipe.
        const all_rows = if (file != null)
            file_rows.rows
        else if (command == null and !stdinIsPipe())
            try splitRows(arena, try readStdin(arena, io))
        else
            try stream.collect(arena, io, feed);
        const capped = all_rows[0..if (max_rows == 0) all_rows.len else @min(max_rows, all_rows.len)];
        const rows = capped[@min(opts.header_lines, capped.len)..];
        if (rows.len == 0) return 1;
        const query = try fuzzy.parseQuery(arena, text, .smart);
        const visible = try arena.alloc([]const u8, rows.len);
        for (rows, visible) |row, *part| part.* = fuzzy.visiblePart(row, opts.delimiter, opts.with_nth_from);
        const hits = try fuzzy.rank(arena, query, visible);
        var out_buffer: [64 * 1024]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(io, &out_buffer);
        for (hits) |hit| try out_writer.interface.print("{s}\n", .{rows[hit.index]});
        try out_writer.interface.flush();
        return if (hits.len == 0) 1 else 0;
    }

    switch (try stream.pickFeed(arena, io, feed, opts)) {
        .picked => |rows| {
            if (rows.len == 0) return 1;
            var stdout_buffer: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
            for (rows) |row| try stdout_writer.interface.print("{s}\n", .{row});
            try stdout_writer.interface.flush();
            return 0;
        },
        .cancelled => return 130,
        .no_console => return 2,
        .empty => return 1,
    }
}

fn readStdin(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    var buffer: [64 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buffer);
    return reader.interface.allocRemaining(arena, .unlimited);
}

fn splitRows(arena: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    var rows: std.ArrayList([]const u8) = .empty;
    if (bytes.len == 0) return rows.items;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (lines.index == null and line.len == 0 and bytes[bytes.len - 1] == '\n') break;
        try rows.append(arena, std.mem.trimEnd(u8, line, "\r"));
    }
    return rows.items;
}

extern "kernel32" fn GetFileType(handle: *anyopaque) callconv(.winapi) u32;

fn stdinIsPipe() bool {
    if (@import("builtin").os.tag != .windows) return true;
    return GetFileType(std.Io.File.stdin().handle) == 3;
}
