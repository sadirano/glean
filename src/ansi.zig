//! fzf's --ansi: SGR colors in a row are drawn, and everything else about the
//! row (matching, the returned text, previews) sees it without escapes.

const std = @import("std");
const Color = @import("theme.zig").Color;

const Allocator = std.mem.Allocator;

/// Style is what a row's own escapes set for one byte. Only the foreground and
/// bold are kept: the picker owns the background, since the current row and
/// the theme paint it.
pub const Style = struct {
    fg: ?Color = null,
    bold: bool = false,
};

/// strip returns the row without escape sequences, or the row itself when it
/// has none.
pub fn strip(allocator: Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, 0x1b) == null) return raw;
    var out: std.ArrayList(u8) = try .initCapacity(allocator, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == 0x1b) {
            i = skip(raw, i).end;
            continue;
        }
        out.appendAssumeCapacity(raw[i]);
        i += 1;
    }
    return out.items;
}

pub const Decoded = struct { plain: []const u8, styles: []const Style };

/// decode strips the row and records the style in force at each plain byte.
pub fn decode(allocator: Allocator, raw: []const u8) !Decoded {
    var plain: std.ArrayList(u8) = try .initCapacity(allocator, raw.len);
    var styles: std.ArrayList(Style) = try .initCapacity(allocator, raw.len);
    var current: Style = .{};
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == 0x1b) {
            const escape = skip(raw, i);
            if (escape.sgr) |params| apply(&current, params);
            i = escape.end;
            continue;
        }
        plain.appendAssumeCapacity(raw[i]);
        styles.appendAssumeCapacity(current);
        i += 1;
    }
    return .{ .plain = plain.items, .styles = styles.items };
}

/// writeFg emits a row's own color in the form it arrived in, so the 16 basic
/// colors follow the terminal's palette as they did under fzf.
pub fn writeFg(out: *std.ArrayList(u8), allocator: Allocator, color: Color) !void {
    var buf: [32]u8 = undefined;
    const s = switch (color) {
        .terminal => "\x1b[39m",
        .indexed => |n| if (n < 8)
            try std.fmt.bufPrint(&buf, "\x1b[{d}m", .{30 + @as(u16, n)})
        else if (n < 16)
            try std.fmt.bufPrint(&buf, "\x1b[{d}m", .{90 + @as(u16, n) - 8})
        else
            try std.fmt.bufPrint(&buf, "\x1b[38;5;{d}m", .{n}),
        .rgb => |c| try std.fmt.bufPrint(&buf, "\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
    };
    try out.appendSlice(allocator, s);
}

const Escape = struct { end: usize, sgr: ?[]const u8 = null };

/// skip measures the escape sequence starting at `start`: CSI (ESC [ ... final),
/// OSC (ESC ] ... BEL or ESC \), or a two-byte escape. A truncated sequence
/// runs to the end of the row.
fn skip(raw: []const u8, start: usize) Escape {
    if (start + 1 >= raw.len) return .{ .end = raw.len };
    switch (raw[start + 1]) {
        '[' => {
            var j = start + 2;
            while (j < raw.len and !(raw[j] >= 0x40 and raw[j] <= 0x7e)) j += 1;
            if (j >= raw.len) return .{ .end = raw.len };
            return .{ .end = j + 1, .sgr = if (raw[j] == 'm') raw[start + 2 .. j] else null };
        },
        ']' => {
            var j = start + 2;
            while (j < raw.len) : (j += 1) {
                if (raw[j] == 0x07) return .{ .end = j + 1 };
                if (raw[j] == 0x1b and j + 1 < raw.len and raw[j + 1] == '\\') return .{ .end = j + 2 };
            }
            return .{ .end = raw.len };
        },
        else => return .{ .end = start + 2 },
    }
}

fn apply(style: *Style, params: []const u8) void {
    if (params.len == 0) {
        style.* = .{};
        return;
    }
    var numbers: [16]u16 = undefined;
    var count: usize = 0;
    var it = std.mem.splitAny(u8, params, ";:");
    while (it.next()) |part| {
        if (count == numbers.len) break;
        numbers[count] = std.fmt.parseInt(u16, part, 10) catch 0;
        count += 1;
    }
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const n = numbers[k];
        switch (n) {
            0 => style.* = .{},
            1 => style.bold = true,
            22 => style.bold = false,
            30...37 => style.fg = .{ .indexed = @intCast(n - 30) },
            90...97 => style.fg = .{ .indexed = @intCast(n - 90 + 8) },
            39 => style.fg = null,
            38, 48 => {
                // Extended colors carry their own arguments; a background is
                // read past rather than applied.
                if (k + 1 >= count) break;
                if (numbers[k + 1] == 5 and k + 2 < count) {
                    if (n == 38) style.fg = .{ .indexed = @intCast(@min(numbers[k + 2], 255)) };
                    k += 2;
                } else if (numbers[k + 1] == 2 and k + 4 < count) {
                    if (n == 38) style.fg = .{ .rgb = .{
                        .r = @intCast(@min(numbers[k + 2], 255)),
                        .g = @intCast(@min(numbers[k + 3], 255)),
                        .b = @intCast(@min(numbers[k + 4], 255)),
                    } };
                    k += 4;
                } else k += 1;
            },
            else => {},
        }
    }
}

test "strip and decode agree on the plain text, and styles follow ripgrep's escapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const raw = "\x1b[0m\x1b[34msrc/a.zig\x1b[0m:\x1b[0m\x1b[32m12\x1b[0m:x \x1b[0m\x1b[1m\x1b[31mhit\x1b[0m";
    const plain = try strip(a, raw);
    try std.testing.expectEqualStrings("src/a.zig:12:x hit", plain);
    const d = try decode(a, raw);
    try std.testing.expectEqualStrings(plain, d.plain);
    try std.testing.expectEqual(Color{ .indexed = 4 }, d.styles[0].fg.?);
    try std.testing.expect(d.styles[9].fg == null); // the ':' after a reset
    try std.testing.expectEqual(Color{ .indexed = 2 }, d.styles[10].fg.?);
    const h = std.mem.indexOf(u8, plain, "hit").?;
    try std.testing.expect(d.styles[h].bold);
    try std.testing.expectEqual(Color{ .indexed = 1 }, d.styles[h].fg.?);
}

test "extended colors, backgrounds, OSC and truncated escapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = try decode(a, "\x1b[48;2;1;2;3;38;5;200ma\x1b]8;;http://x\x07b\x1b[38;2;9;8;7mc\x1b[");
    try std.testing.expectEqualStrings("abc", d.plain);
    try std.testing.expectEqual(Color{ .indexed = 200 }, d.styles[0].fg.?);
    try std.testing.expectEqual(Color{ .rgb = .{ .r = 9, .g = 8, .b = 7 } }, d.styles[2].fg.?);
    const plain = "no escapes";
    try std.testing.expect((try strip(a, plain)).ptr == plain.ptr);
}
