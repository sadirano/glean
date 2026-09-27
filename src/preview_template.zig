const std = @import("std");

pub fn parse(arena: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (at < line.len) {
        while (at < line.len and std.ascii.isWhitespace(line[at])) : (at += 1) {}
        if (at == line.len) break;
        var token: std.ArrayList(u8) = .empty;
        var quote: ?u8 = null;
        while (at < line.len) : (at += 1) {
            const byte = line[at];
            if (quote) |delimiter| {
                if (byte == delimiter) quote = null else try token.append(arena, byte);
            } else if (byte == '"' or byte == '\'') {
                quote = byte;
            } else if (std.ascii.isWhitespace(byte)) {
                break;
            } else {
                try token.append(arena, byte);
            }
        }
        if (quote != null) return error.UnclosedPreviewQuote;
        const arg = try token.toOwnedSlice(arena);
        if (!std.mem.eql(u8, arg, "{}") and std.mem.indexOf(u8, arg, "{}") != null)
            return error.EmbeddedPreviewPlaceholder;
        try argv.append(arena, arg);
    }
    if (argv.items.len == 0 or argv.items[0].len == 0 or std.mem.eql(u8, argv.items[0], "{}"))
        return error.MissingPreviewExecutable;
    return argv.toOwnedSlice(arena);
}
