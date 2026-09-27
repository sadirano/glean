const std = @import("std");
const fuzzy = @import("fuzzy.zig");
const pick = @import("pick.zig");

test "parallel rank releases worker bookkeeping" {
    var query_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer query_arena.deinit();
    const query = try fuzzy.parseQuery(query_arena.allocator(), "a", .smart);
    const rows = [_][]const u8{"a"} ** 4000;
    const hits = try fuzzy.rank(std.testing.allocator, query, &rows);
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(rows.len, hits.len);
}

fn initState(allocator: std.mem.Allocator) !void {
    var state = try pick.State.init(allocator, &.{"row"}, .{});
    defer state.deinit();
}

test "state initialization releases allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initState, .{});
}

test "renderer replaces malformed UTF-8 in rows and prompts" {
    const a = std.testing.allocator;
    var state = try pick.State.init(a, &.{"\xff\xc3("}, .{ .prompt = "\xff " });
    defer state.deinit();
    const frame = try pick.render(&state, .{}, 20, 4, false, false, a);
    defer a.free(frame);
    try std.testing.expect(std.unicode.utf8ValidateSlice(frame));
    try std.testing.expect(std.mem.indexOf(u8, frame, "??(") != null);
}

test "tiny frames and shrinking matches preserve valid selection and marks" {
    const a = std.testing.allocator;
    var state = try pick.State.init(a, &.{ "alpha", "beta" }, .{ .multi = true });
    defer state.deinit();
    _ = try state.step(.up);
    _ = try state.step(.tab);
    _ = try state.step(.{ .character = 'z' });
    try std.testing.expectEqual(@as(usize, 0), state.hits.len);
    for (0..4) |width| for (0..4) |height| {
        const frame = try pick.render(&state, .{}, width, height, false, false, a);
        defer a.free(frame);
        try std.testing.expect(std.unicode.utf8ValidateSlice(frame));
    };
    _ = try state.step(.ctrl_u);
    try state.appendRows(&.{"gamma"});
    try state.refreshRows();
    try std.testing.expect(state.current < state.hits.len);
    try std.testing.expect(state.marked[1]);
}

test "query edge cases and DP limits keep highlights within rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long_query = "a" ** 257;
    const long_row = "a" ** 600;
    for ([_][]const u8{ "", "\\", "!", "^", "$", "^$", "|", "\xff", "a", "a" ** 32, long_query }) |text| {
        const query = try fuzzy.parseQuery(a, text, .smart);
        for ([_][]const u8{ "", "\\!^$", "\xff\xc3(", "caf\u{00e9}", "a" ** 300, long_row }) |row| {
            var positions: std.ArrayList(usize) = .empty;
            const value = try fuzzy.matchRow(query, row, &positions, a);
            for (positions.items) |position| try std.testing.expect(position < row.len);
            if (std.mem.eql(u8, text, long_query) and std.mem.eql(u8, row, long_row))
                try std.testing.expect(value != null);
        }
    }
}

test "growing the viewport clamps scroll to a full final page" {
    const rows = [_][]const u8{"row"} ** 100;
    var state = try pick.State.init(std.testing.allocator, &rows, .{});
    defer state.deinit();
    state.setHeight(5);
    for (0..99) |_| _ = try state.step(.up);
    state.setHeight(50);
    try std.testing.expectEqual(@as(usize, 52), state.scroll);
    try std.testing.expectEqual(@as(usize, 99), state.current);
}

test "moving the cursor keeps the old preview where it was until the new one arrives" {
    const a = std.testing.allocator;
    var state = try pick.State.init(a, &.{ "alpha", "beta" }, .{});
    defer state.deinit();
    state.preview_scroll = 7;
    _ = try state.step(.up);
    try std.testing.expectEqual(@as(usize, 7), state.preview_scroll);
    state.setPreview(.{ .text = "one\ntwo", .focus_line = 2 });
    try std.testing.expect(state.preview_focus_pending);
}

test "header lines line up with the rows under them" {
    const a = std.testing.allocator;
    var state = try pick.State.init(a, &.{ "NAME", "alpha" }, .{ .header_lines = 1 });
    defer state.deinit();
    const frame = try pick.render(&state, .{}, 20, 5, false, false, a);
    defer a.free(frame);
    var lines = std.mem.splitSequence(u8, frame, "\r\n");
    var header_col: ?usize = null;
    var row_col: ?usize = null;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "NAME")) |col| header_col = col;
        if (std.mem.indexOf(u8, line, "alpha")) |col| row_col = col;
    }
    try std.testing.expectEqual(row_col.?, header_col.?);
}

test "an ansi row keeps its colors on screen but is matched and returned plain" {
    const a = std.testing.allocator;
    var state = try pick.State.init(a, &.{"\x1b[34msrc/a.zig\x1b[0m:\x1b[32m7\x1b[0m:x"}, .{ .ansi = true });
    defer state.deinit();
    try std.testing.expectEqualStrings("src/a.zig:7:x", state.currentRow().?.text);
    try std.testing.expectEqualStrings("src/a.zig:7:x", state.visible[0]);
    const frame = try pick.render(&state, .{}, 40, 4, true, false, a);
    defer a.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b[34msrc/a.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b[32m7") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b[0m:") == null);
}

test "tab marks and moves down the drawn list, and the info line counts marks" {
    const a = std.testing.allocator;
    var state = try pick.State.init(a, &.{ "one", "two", "three" }, .{ .multi = true });
    defer state.deinit();
    _ = try state.step(.up);
    _ = try state.step(.tab);
    try std.testing.expectEqual(@as(usize, 0), state.current);
    _ = try state.step(.backtab);
    try std.testing.expectEqual(@as(usize, 1), state.current);
    const frame = try pick.render(&state, .{}, 30, 6, false, false, a);
    defer a.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "3/3 (2)") != null);
}
