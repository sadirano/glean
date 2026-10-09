const std = @import("std");
const fuzzy = @import("fuzzy.zig");
const pick = @import("pick.zig");

test "parallel rank releases worker bookkeeping" {
    var query_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer query_arena.deinit();
    const query = try fuzzy.parseQuery(query_arena.allocator(), "a", .smart);
    const rows = @as([4000][]const u8, @splat("a"));
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
    const long_query = &@as([257]u8, @splat('a'));
    const long_row = &@as([600]u8, @splat('a'));
    for ([_][]const u8{ "", "\\", "!", "^", "$", "^$", "|", "\xff", "a", &@as([32]u8, @splat('a')), long_query }) |text| {
        const query = try fuzzy.parseQuery(a, text, .smart);
        for ([_][]const u8{ "", "\\!^$", "\xff\xc3(", "caf\u{00e9}", &@as([300]u8, @splat('a')), long_row }) |row| {
            var positions: std.ArrayList(usize) = .empty;
            const value = try fuzzy.matchRow(query, row, &positions, a);
            for (positions.items) |position| try std.testing.expect(position < row.len);
            if (std.mem.eql(u8, text, long_query) and std.mem.eql(u8, row, long_row))
                try std.testing.expect(value != null);
        }
    }
}

test "growing the viewport clamps scroll to a full final page" {
    const rows = @as([100][]const u8, @splat("row"));
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

fn previewStub(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!pick.PreviewText {
    return .{ .text = "" };
}

test "preview header stays fixed while the remaining lines follow focus and scroll" {
    const a = std.testing.allocator;
    var context: u8 = 0;
    var state = try pick.State.init(a, &.{"row"}, .{
        .preview = .{ .ctx = &context, .func = previewStub },
        .preview_percent = 50,
        .preview_header_lines = 3,
    });
    defer state.deinit();
    state.setPreview(.{ .text = "H1\nH2\nH3\n4\n5\n6\n7\n8\n9\n10", .focus_line = 9 });
    const frame = try pick.render(&state, .{}, 12, 12, false, false, a);
    defer a.free(frame);
    try std.testing.expectEqual(@as(usize, 4), state.preview_scroll);
    var lines = std.mem.splitSequence(u8, frame, "\r\n");
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, " H1"));
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, " H2"));
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, " H3"));
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, " 8"));
    _ = try state.step(.shift_down);
    const scrolled = try pick.render(&state, .{}, 12, 12, false, false, a);
    defer a.free(scrolled);
    lines = std.mem.splitSequence(u8, scrolled, "\r\n");
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, " H1"));
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, " H2"));
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, " H3"));
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, " 9"));
}

test "preview scroll position overlays the first row in reverse info color" {
    const a = std.testing.allocator;
    var context: u8 = 0;
    var state = try pick.State.init(a, &.{"row"}, .{
        .preview = .{ .ctx = &context, .func = previewStub },
        .preview_percent = 50,
        .preview_header_lines = 3,
    });
    defer state.deinit();
    state.setPreview(.{ .text = "H1\nH2\nH3\n4\n5\n6\n7\n8\n9\n10" });
    state.preview_scroll = 4;
    state.preview_focus_pending = false;
    const plain = try pick.render(&state, .{}, 12, 12, false, false, a);
    defer a.free(plain);
    var plain_lines = std.mem.splitSequence(u8, plain, "\r\n");
    const first = plain_lines.next().?;
    try std.testing.expectEqual(@as(usize, 12), first.len);
    try std.testing.expect(std.mem.endsWith(u8, first, "8/10"));
    var theme: pick.Theme = .{};
    theme.info = .{ .rgb = .{ .r = 11, .g = 22, .b = 33 } };
    const colored = try pick.render(&state, theme, 12, 12, true, false, a);
    defer a.free(colored);
    try std.testing.expect(std.mem.indexOf(u8, colored, "\x1b[38;2;11;22;33m\x1b[7m8/10") != null);
    state.opts.preview_header_lines = 0;
    state.opts.preview_wrap = true;
    state.setPreview(.{ .text = "abcdefghijklmnopqrstu\nz" });
    const wrapped = try pick.render(&state, .{}, 6, 8, false, false, a);
    defer a.free(wrapped);
    var wrapped_lines = std.mem.splitSequence(u8, wrapped, "\r\n");
    try std.testing.expect(std.mem.endsWith(u8, wrapped_lines.next().?, "1/2"));
}

test "preview has one column of padding on each side" {
    const a = std.testing.allocator;
    var context: u8 = 0;
    var state = try pick.State.init(a, &.{"row"}, .{
        .preview = .{ .ctx = &context, .func = previewStub },
        .preview_percent = 50,
    });
    defer state.deinit();
    state.setPreview(.{ .text = "abcdefghi" });
    const frame = try pick.render(&state, .{}, 8, 12, false, false, a);
    defer a.free(frame);
    var frame_lines = std.mem.splitSequence(u8, frame, "\r\n");
    try std.testing.expectEqualStrings(" abcdef ", frame_lines.next().?);
    for (0..4) |width| {
        const tiny = try pick.render(&state, .{}, width, 12, false, false, a);
        defer a.free(tiny);
        var lines = std.mem.splitSequence(u8, tiny, "\r\n");
        while (lines.next()) |line| try std.testing.expectEqual(width, line.len);
    }
}

test "inactive gutter and scrollbar cells use gutter as their background" {
    const a = std.testing.allocator;
    const rows = @as([10][]const u8, @splat("row"));
    var state = try pick.State.init(a, &rows, .{});
    defer state.deinit();
    var theme: pick.Theme = .{};
    theme.gutter = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } };
    theme.bg_plus = .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } };
    const frame = try pick.render(&state, theme, 12, 6, true, false, a);
    defer a.free(frame);
    var lines = std.mem.splitSequence(u8, frame, "\r\n");
    const inactive = lines.next().?;
    _ = lines.next();
    _ = lines.next();
    const current = lines.next().?;
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, inactive, "\x1b[48;2;1;2;3m"));
    try std.testing.expect(std.mem.indexOf(u8, current, "\x1b[48;2;1;2;3m") == null);
    try std.testing.expect(std.mem.indexOf(u8, current, "\x1b[48;2;4;5;6m") != null);
}

test "query uses the terminal cursor only in colored frames" {
    const a = std.testing.allocator;
    var state = try pick.State.init(a, &.{"row"}, .{});
    defer state.deinit();
    _ = try state.step(.{ .character = 'a' });
    _ = try state.step(.{ .character = 'b' });
    _ = try state.step(.left);
    const plain = try pick.render(&state, .{}, 12, 4, false, false, a);
    defer a.free(plain);
    try std.testing.expect(std.mem.indexOfScalar(u8, plain, 0x1b) == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, plain, '_') == null);
    try std.testing.expect(std.mem.endsWith(u8, plain, "> ab        "));
    const colored = try pick.render(&state, .{}, 12, 4, true, false, a);
    defer a.free(colored);
    try std.testing.expect(std.mem.startsWith(u8, colored, "\x1b[?25l\x1b[H"));
    try std.testing.expect(std.mem.endsWith(u8, colored, "\x1b[4;4H\x1b[?25h"));
}
