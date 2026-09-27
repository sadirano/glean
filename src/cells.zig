//! Cell-level text measurement and color conversion for the frame renderer.

const std = @import("std");
const Rgb = @import("theme.zig").Rgb;

const Allocator = std.mem.Allocator;

pub fn decoded(s: []const u8, index: usize) struct { cp: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(s[index]) catch return .{ .cp = '?', .len = 1 };
    if (index + len > s.len) return .{ .cp = '?', .len = 1 };
    const cp = std.unicode.utf8Decode(s[index .. index + len]) catch return .{ .cp = '?', .len = 1 };
    return .{ .cp = cp, .len = len };
}

pub fn appendRune(out: *std.ArrayList(u8), arena: Allocator, cp: u21) !void {
    var bytes: [4]u8 = undefined;
    const length = try std.unicode.utf8Encode(cp, &bytes);
    try out.appendSlice(arena, bytes[0..length]);
}

pub fn columns(cp: u21) usize {
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

pub fn displayWidth(s: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const d = decoded(s, i);
        width += if (d.cp == '\t') 1 else columns(d.cp);
        i += d.len;
    }
    return width;
}

pub fn indexedRgb(index: u8) Rgb {
    const basic = [_]Rgb{
        .{ .r = 0, .g = 0, .b = 0 },       .{ .r = 128, .g = 0, .b = 0 },
        .{ .r = 0, .g = 128, .b = 0 },     .{ .r = 128, .g = 128, .b = 0 },
        .{ .r = 0, .g = 0, .b = 128 },     .{ .r = 128, .g = 0, .b = 128 },
        .{ .r = 0, .g = 128, .b = 128 },   .{ .r = 192, .g = 192, .b = 192 },
        .{ .r = 128, .g = 128, .b = 128 }, .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },     .{ .r = 255, .g = 255, .b = 0 },
        .{ .r = 0, .g = 0, .b = 255 },     .{ .r = 255, .g = 0, .b = 255 },
        .{ .r = 0, .g = 255, .b = 255 },   .{ .r = 255, .g = 255, .b = 255 },
    };
    if (index < 16) return basic[index];
    if (index >= 232) {
        const gray: u8 = @intCast(8 + (index - 232) * @as(u16, 10));
        return .{ .r = gray, .g = gray, .b = gray };
    }
    const cube = index - 16;
    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
    return .{ .r = levels[cube / 36], .g = levels[cube / 6 % 6], .b = levels[cube % 6] };
}
