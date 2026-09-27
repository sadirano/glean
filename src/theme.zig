//! Colors and the fzf `--color` theme parser.

const std = @import("std");

pub const default_colors =
    "--color=fg:#c0caf5,bg:-1,hl:#2ac3de,fg+:#c0caf5,bg+:#283457 " ++
    "--color=hl+:#2ac3de,info:#7aa2f7,prompt:#2ac3de,pointer:#ff007c " ++
    "--color=marker:#ff5da0,spinner:#ff007c,header:#ff9e64,query:#c0caf5 " ++
    "--color=border:#27a1b9,separator:#ff9e64,gutter:#283457";

pub const Rgb = struct { r: u8, g: u8, b: u8 };
pub const Color = union(enum) { terminal, indexed: u8, rgb: Rgb };

pub const Theme = struct {
    fg: Color = .terminal,
    fg_plus: Color = .terminal,
    bg: Color = .terminal,
    bg_plus: Color = .terminal,
    hl: Color = .terminal,
    hl_plus: Color = .terminal,
    info: Color = .terminal,
    marker: Color = .terminal,
    prompt: Color = .terminal,
    spinner: Color = .terminal,
    pointer: Color = .terminal,
    header: Color = .terminal,
    border: Color = .terminal,
    separator: Color = .terminal,
    query: Color = .terminal,
    gutter: Color = .terminal,
    label: Color = .terminal,

    pub fn fromEnvironment(extra: ?[]const u8) Theme {
        var theme: Theme = .{};
        theme.apply(default_colors);
        if (extra) |words| theme.apply(words);
        return theme;
    }

    /// Only color words affect this parser; other fzf options belong to their
    /// callers and may appear anywhere in FZF_DEFAULT_OPTS.
    pub fn apply(self: *Theme, words: []const u8) void {
        var it = std.mem.tokenizeAny(u8, words, " \t\r\n");
        while (it.next()) |word| {
            const specs = if (std.mem.startsWith(u8, word, "--color=")) word[8..] else continue;
            var parts = std.mem.splitScalar(u8, specs, ',');
            while (parts.next()) |part| {
                const colon = std.mem.indexOfScalar(u8, part, ':') orelse continue;
                const color = parseColor(part[colon + 1 ..]) orelse continue;
                self.set(part[0..colon], color);
            }
        }
    }

    fn set(self: *Theme, name: []const u8, value: Color) void {
        const fields = .{
            .{ "fg", &self.fg },           .{ "fg+", &self.fg_plus },
            .{ "bg", &self.bg },           .{ "bg+", &self.bg_plus },
            .{ "hl", &self.hl },           .{ "hl+", &self.hl_plus },
            .{ "info", &self.info },       .{ "marker", &self.marker },
            .{ "prompt", &self.prompt },   .{ "spinner", &self.spinner },
            .{ "pointer", &self.pointer }, .{ "header", &self.header },
            .{ "border", &self.border },   .{ "separator", &self.separator },
            .{ "query", &self.query },     .{ "gutter", &self.gutter },
            .{ "label", &self.label },
        };
        inline for (fields) |field| {
            if (std.mem.eql(u8, name, field[0])) {
                field[1].* = value;
                return;
            }
        }
    }
};

fn parseColor(text: []const u8) ?Color {
    if (std.mem.eql(u8, text, "-1")) return .terminal;
    if (text.len == 7 and text[0] == '#') {
        return .{ .rgb = .{
            .r = std.fmt.parseInt(u8, text[1..3], 16) catch return null,
            .g = std.fmt.parseInt(u8, text[3..5], 16) catch return null,
            .b = std.fmt.parseInt(u8, text[5..7], 16) catch return null,
        } };
    }
    return .{ .indexed = std.fmt.parseInt(u8, text, 10) catch return null };
}
