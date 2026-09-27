const std = @import("std");
const pick = @import("pick.zig");
const fuzzy = @import("fuzzy.zig");

const usage = "usage: glean [--multi] [--prompt TEXT] [--header-lines N] [--delimiter C] [--with-nth N..] [--filter QUERY] [FILE]\n";

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
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--multi")) {
            opts.multi = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            if (!std.mem.eql(u8, arg, "--prompt") and
                !std.mem.eql(u8, arg, "--header-lines") and
                !std.mem.eql(u8, arg, "--delimiter") and
                !std.mem.eql(u8, arg, "--with-nth") and
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
    const bytes = if (file) |path|
        try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited)
    else blk: {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
        break :blk try stdin_reader.interface.allocRemaining(arena, .unlimited);
    };
    var rows: std.ArrayList([]const u8) = .empty;
    if (bytes.len != 0) {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (lines.index == null and line.len == 0 and bytes[bytes.len - 1] == '\n') break;
            try rows.append(arena, std.mem.trimEnd(u8, line, "\r"));
        }
    }
    if (rows.items.len == 0) return 1;

    // fzf's --filter: rank without a UI, so the matcher can be compared
    // against fzf on the same input, for speed and for ranking.
    if (filter) |text| {
        const query = try fuzzy.parseQuery(arena, text, .smart);
        const visible = try arena.alloc([]const u8, rows.items.len);
        for (rows.items, visible) |row, *part| part.* = fuzzy.visiblePart(row, opts.delimiter, opts.with_nth_from);
        const hits = try fuzzy.rank(arena, query, visible);
        var out_buffer: [64 * 1024]u8 = undefined;
        var out_writer = std.Io.File.stdout().writer(io, &out_buffer);
        for (hits) |hit| try out_writer.interface.print("{s}\n", .{rows.items[hit.index]});
        try out_writer.interface.flush();
        return if (hits.len == 0) 1 else 0;
    }

    switch (try pick.pick(arena, rows.items, opts)) {
        .picked => |indices| {
            if (indices.len == 0) return 1;
            var stdout_buffer: [4096]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
            for (indices) |index| try stdout_writer.interface.print("{s}\n", .{rows.items[index]});
            try stdout_writer.interface.flush();
            return 0;
        },
        .cancelled => return 130,
        .no_console => return 2,
    }
}
