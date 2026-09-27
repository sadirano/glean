//! The native picker's state, input transitions, and frame renderer.
//! Console handles and input records stay in tui.zig.

const std = @import("std");
const fuzzy = @import("fuzzy.zig");
const tui = @import("tui.zig");
const preview = @import("preview.zig");
const theme_zig = @import("theme.zig");
const ansi = @import("ansi.zig");
const cells = @import("cells.zig");
const decoded = cells.decoded;
const appendRune = cells.appendRune;
const columns = cells.columns;
const displayWidth = cells.displayWidth;
const indexedRgb = cells.indexedRgb;

const Allocator = std.mem.Allocator;

pub const PreviewText = preview.PreviewText;
pub const Previewer = preview.Previewer;
pub const CommandPreview = preview.Command;
pub const PreviewWorker = preview.Worker;
pub const commandPreviewer = preview.commandPreviewer;
pub const textPreview = preview.textPreview;

pub const Options = struct {
    prompt: []const u8 = "> ",
    multi: bool = false,
    header_lines: usize = 0,
    delimiter: ?u8 = null,
    with_nth_from: usize = 1,
    /// fzf `--color=` words applied over default_colors; callers normally
    /// pass the FZF_DEFAULT_OPTS environment value. Other words are ignored.
    colors: ?[]const u8 = null,
    preview: ?Previewer = null,
    preview_percent: u8 = 40,
    preview_wrap: bool = false,
    preview_header_lines: usize = 0,
    /// fzf's --ansi: rows may carry SGR colors, which are drawn but neither
    /// matched against nor returned.
    ansi: bool = false,
};

pub const default_colors = theme_zig.default_colors;
pub const Rgb = theme_zig.Rgb;
pub const Color = theme_zig.Color;
pub const Theme = theme_zig.Theme;

pub const Outcome = union(enum) { picked: []const u32, cancelled, no_console };

pub const State = struct {
    arena: Allocator,
    scratch: std.heap.ArenaAllocator,
    rows: []const []const u8,
    rows_buffer: ?[][]const u8 = null,
    visible: [][]const u8,
    visible_buffer: [][]const u8,
    marked: []bool,
    marked_buffer: []bool,
    opts: Options,
    query: std.ArrayList(u8) = .empty,
    query_cursor: usize = 0,
    parsed: fuzzy.Query = .{ .groups = &.{} },
    hits: []const fuzzy.Hit = &.{},
    current: usize = 0,
    scroll: usize = 0,
    screen_height: usize = 24,
    preview_height: usize = 0,
    preview_text: ?PreviewText = null,
    preview_scroll: usize = 0,
    preview_focus_pending: bool = false,
    producer_running: bool = false,
    spinner_frame: usize = 0,
    /// Under opts.ansi, each row with its escapes removed, by row id.
    plain_rows: std.ArrayList([]const u8) = .empty,
    plain_store: std.heap.ArenaAllocator,

    pub fn init(arena: Allocator, rows: []const []const u8, opts: Options) !State {
        const headers = @min(opts.header_lines, rows.len);
        const selectable = rows.len - headers;
        const visible = try arena.alloc([]const u8, selectable);
        errdefer arena.free(visible);
        const marked = try arena.alloc(bool, selectable);
        errdefer arena.free(marked);
        @memset(marked, false);
        var state: State = .{
            .arena = arena,
            .scratch = std.heap.ArenaAllocator.init(arena),
            .plain_store = std.heap.ArenaAllocator.init(arena),
            .rows = rows,
            .visible = visible,
            .visible_buffer = visible,
            .marked = marked,
            .marked_buffer = marked,
            .opts = opts,
        };
        errdefer state.scratch.deinit();
        errdefer state.plain_store.deinit();
        errdefer state.plain_rows.deinit(arena);
        try state.addPlain(rows);
        for (rows[headers..], visible, headers..) |_, *part, id| {
            part.* = fuzzy.visiblePart(state.rowText(id), opts.delimiter, opts.with_nth_from);
        }
        try state.rerank();
        return state;
    }

    pub fn deinit(self: *State) void {
        self.scratch.deinit();
        self.plain_store.deinit();
        self.plain_rows.deinit(self.arena);
        self.query.deinit(self.arena);
        if (self.rows_buffer) |buffer| self.arena.free(buffer);
        self.arena.free(self.visible_buffer);
        self.arena.free(self.marked_buffer);
    }

    pub fn appendRows(self: *State, additions: []const []const u8) !void {
        if (additions.len == 0) return;
        const old_len = self.rows.len;
        const total = try std.math.add(usize, old_len, additions.len);
        const capacity = if (self.rows_buffer) |buffer| buffer.len else 0;
        if (total > capacity) {
            const new_capacity = @max(total, @max(@as(usize, 16), capacity *| 2));
            const rows_buffer = try self.arena.alloc([]const u8, new_capacity);
            errdefer self.arena.free(rows_buffer);
            const visible_buffer = try self.arena.alloc([]const u8, new_capacity);
            errdefer self.arena.free(visible_buffer);
            const marked_buffer = try self.arena.alloc(bool, new_capacity);
            errdefer self.arena.free(marked_buffer);
            @memcpy(rows_buffer[0..old_len], self.rows);
            @memcpy(visible_buffer[0..self.visible.len], self.visible);
            @memcpy(marked_buffer[0..self.marked.len], self.marked);
            if (self.rows_buffer) |old| self.arena.free(old);
            self.arena.free(self.visible_buffer);
            self.arena.free(self.marked_buffer);
            self.rows_buffer = rows_buffer;
            self.visible_buffer = visible_buffer;
            self.marked_buffer = marked_buffer;
        }
        @memcpy(self.rows_buffer.?[old_len..total], additions);
        try self.addPlain(additions);
        const headers = @min(self.opts.header_lines, total);
        const selectable = total - headers;
        self.rows = self.rows_buffer.?[0..total];
        for (self.visible.len..selectable) |index| {
            self.visible_buffer[index] = fuzzy.visiblePart(self.rowText(headers + index), self.opts.delimiter, self.opts.with_nth_from);
            self.marked_buffer[index] = false;
        }
        self.rows = self.rows_buffer.?[0..total];
        self.visible = self.visible_buffer[0..selectable];
        self.marked = self.marked_buffer[0..selectable];
    }

    fn addPlain(self: *State, additions: []const []const u8) !void {
        if (!self.opts.ansi) return;
        try self.plain_rows.ensureUnusedCapacity(self.arena, additions.len);
        for (additions) |row| self.plain_rows.appendAssumeCapacity(try ansi.strip(self.plain_store.allocator(), row));
    }

    /// rowText is a row as matched and returned: without its escapes under
    /// opts.ansi, verbatim otherwise.
    pub fn rowText(self: *const State, id: usize) []const u8 {
        return if (self.opts.ansi) self.plain_rows.items[id] else self.rows[id];
    }

    pub fn refreshRows(self: *State) !void {
        const selected = if (self.current < self.hits.len) self.hits[self.current].index else null;
        try self.rerank();
        if (selected) |index| {
            for (self.hits, 0..) |hit, position| {
                if (hit.index == index) {
                    self.current = position;
                    self.keepInView();
                    break;
                }
            }
        }
    }

    fn rerank(self: *State) !void {
        _ = self.scratch.reset(.retain_capacity);
        const a = self.scratch.allocator();
        self.parsed = try fuzzy.parseQuery(a, self.query.items, .smart);
        self.hits = try fuzzy.rank(a, self.parsed, self.visible);
        // A new query re-orders the list, so the old position points at an
        // unrelated row; fzf goes back to the best match, and so do we.
        self.current = 0;
        self.scroll = 0;
    }

    pub fn setHeight(self: *State, height: usize) void {
        self.screen_height = height;
        const headers = @min(self.opts.header_lines, self.rows.len);
        const content = if (self.opts.preview != null and height >= 8)
            @min(height * @as(usize, @min(self.opts.preview_percent, 100)) / 100, height -| (3 +| headers))
        else
            0;
        self.preview_height = if (content > 0) content + 1 else 0;
        self.keepInView();
    }

    pub const CurrentRow = struct { id: usize, text: []const u8 };

    pub fn currentRow(self: *const State) ?CurrentRow {
        if (self.current >= self.hits.len) return null;
        const id = @as(usize, self.hits[self.current].index) + @min(self.opts.header_lines, self.rows.len);
        return .{ .id = id, .text = self.rowText(id) };
    }

    pub fn setPreview(self: *State, value: PreviewText) void {
        self.preview_text = value;
        self.preview_scroll = 0;
        self.preview_focus_pending = true;
    }

    fn listHeight(self: *const State) usize {
        const headers = @min(self.opts.header_lines, self.rows.len);
        return self.screen_height -| (2 +| headers +| self.preview_height);
    }

    fn keepInView(self: *State) void {
        if (self.hits.len == 0) return;
        const capacity = @max(1, self.listHeight());
        if (self.current < self.scroll) self.scroll = self.current;
        if (self.current >= self.scroll +| capacity) self.scroll = self.current - capacity + 1;
        self.scroll = @min(self.scroll, self.hits.len -| capacity);
    }

    fn move(self: *State, delta: isize) void {
        if (self.hits.len == 0) return;
        if (delta < 0) {
            self.current -|= @intCast(-delta);
        } else {
            self.current = @min(self.hits.len - 1, self.current +| @as(usize, @intCast(delta)));
        }
        self.keepInView();
    }

    fn toggle(self: *State) void {
        if (!self.opts.multi or self.hits.len == 0) return;
        const index = self.hits[self.current].index;
        self.marked[index] = !self.marked[index];
    }

    fn picked(self: *State) !Outcome {
        var picks: std.ArrayList(u32) = .empty;
        const headers = @min(self.opts.header_lines, self.rows.len);
        if (self.opts.multi) {
            for (self.marked, 0..) |yes, index| {
                if (yes) try picks.append(self.arena, @intCast(index + headers));
            }
        }
        if (picks.items.len == 0 and self.hits.len > 0) {
            try picks.append(self.arena, self.hits[self.current].index + @as(u32, @intCast(headers)));
        }
        return .{ .picked = try picks.toOwnedSlice(self.arena) };
    }

    fn delete(self: *State, start: usize, end: usize) !void {
        std.mem.copyForwards(u8, self.query.items[start..], self.query.items[end..]);
        self.query.items.len -= end - start;
        self.query_cursor = start;
        try self.rerank();
    }

    pub fn step(self: *State, key: tui.Key) !?Outcome {
        switch (key) {
            // The list grows upward from the prompt, so the best match is at
            // the bottom and "up" on screen means further down the ranking.
            .up, .ctrl_k, .ctrl_p => self.move(1),
            .down, .ctrl_j, .ctrl_n => self.move(-1),
            .page_up => self.move(@intCast(@min(self.listHeight(), std.math.maxInt(isize)))),
            .page_down => self.move(-@as(isize, @intCast(@min(self.listHeight(), std.math.maxInt(isize))))),
            .shift_up => {
                self.preview_scroll -|= 1;
                self.preview_focus_pending = false;
            },
            .shift_down => {
                self.preview_scroll +|= 1;
                self.preview_focus_pending = false;
            },
            // fzf's toggle+down and toggle+up: down as the list is drawn.
            .tab => {
                self.toggle();
                if (self.opts.multi) self.move(-1);
            },
            .backtab => {
                self.toggle();
                if (self.opts.multi) self.move(1);
            },
            .enter => return try self.picked(),
            .escape, .ctrl_c, .ctrl_g => return .cancelled,
            .left => self.query_cursor = prevCodepoint(self.query.items, self.query_cursor),
            .right => self.query_cursor = nextCodepoint(self.query.items, self.query_cursor),
            .home, .ctrl_a => self.query_cursor = 0,
            .end, .ctrl_e => self.query_cursor = self.query.items.len,
            .backspace, .ctrl_h => if (self.query_cursor > 0) {
                try self.delete(prevCodepoint(self.query.items, self.query_cursor), self.query_cursor);
            },
            .ctrl_u => if (self.query.items.len > 0) try self.delete(0, self.query.items.len),
            .ctrl_w => if (self.query_cursor > 0) {
                var start = self.query_cursor;
                while (start > 0 and isWordSpace(self.query.items[prevCodepoint(self.query.items, start)])) {
                    start = prevCodepoint(self.query.items, start);
                }
                while (start > 0 and !isWordSpace(self.query.items[prevCodepoint(self.query.items, start)])) {
                    start = prevCodepoint(self.query.items, start);
                }
                try self.delete(start, self.query_cursor);
            },
            .character => |cp| {
                if (cp < 0x20 or cp == 0x7f) return null;
                var encoded: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &encoded) catch return null;
                try self.query.insertSlice(self.arena, self.query_cursor, encoded[0..len]);
                self.query_cursor += len;
                try self.rerank();
            },
            .resize => {},
        }
        return null;
    }
};

fn isWordSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

fn prevCodepoint(s: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    while (p > 0 and s[p] & 0xc0 == 0x80) p -= 1;
    return p;
}

fn nextCodepoint(s: []const u8, pos: usize) usize {
    if (pos >= s.len) return s.len;
    var p = pos + 1;
    while (p < s.len and s[p] & 0xc0 == 0x80) p += 1;
    return p;
}

// These glyphs are safe despite the repository's ASCII-output convention:
// tui writes the completed frame through WriteConsoleW as UTF-16, bypassing
// legacy console code pages. Source uses escapes so it remains ASCII.
const Glyphs = struct { pointer: []const u8, marker: []const u8, separator: []const u8, scroll: []const u8, spinner: []const []const u8 };
const unicode_glyphs: Glyphs = .{
    .pointer = "\u{258C}",
    .marker = "\u{2503}",
    .separator = "\u{2500}",
    .scroll = "\u{2502}",
    .spinner = &.{ "\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283C}", "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280F}" },
};
const ascii_glyphs: Glyphs = .{ .pointer = ">", .marker = "*", .separator = "-", .scroll = "|", .spinner = &.{ "-", "\\", "|", "/" } };

fn append(out: *std.ArrayList(u8), arena: Allocator, s: []const u8) !void {
    try out.appendSlice(arena, s);
}

fn setColor(out: *std.ArrayList(u8), arena: Allocator, color: Color, background: bool) !void {
    var buf: [48]u8 = undefined;
    const s = switch (color) {
        .terminal => if (background) "\x1b[49m" else "\x1b[39m",
        .rgb => |rgb| try std.fmt.bufPrint(&buf, "\x1b[{d};2;{d};{d};{d}m", .{ if (background) @as(u8, 48) else @as(u8, 38), rgb.r, rgb.g, rgb.b }),
        .indexed => |index| blk: {
            const rgb = indexedRgb(index);
            break :blk try std.fmt.bufPrint(&buf, "\x1b[{d};2;{d};{d};{d}m", .{ if (background) @as(u8, 48) else @as(u8, 38), rgb.r, rgb.g, rgb.b });
        },
    };
    try append(out, arena, s);
}

fn style(out: *std.ArrayList(u8), arena: Allocator, colors: bool, fg: Color, bg: Color) !void {
    if (!colors) return;
    try setColor(out, arena, bg, true);
    try setColor(out, arena, fg, false);
}

fn plainWidth(out: *std.ArrayList(u8), arena: Allocator, s: []const u8, width: usize) !usize {
    var used: usize = 0;
    var i: usize = 0;
    const clipped = displayWidth(s) > width;
    const budget = if (clipped) width -| 2 else width;
    while (i < s.len) {
        const d = decoded(s, i);
        const w = if (d.cp == '\t') @as(usize, 1) else columns(d.cp);
        if (used + w > budget) break;
        if (d.cp == '\t' or d.cp < 0x20 or d.cp == 0x7f) {
            try append(out, arena, " ");
        } else {
            try appendRune(out, arena, d.cp);
        }
        used += w;
        i += d.len;
    }
    if (clipped) {
        try pad(out, arena, used, budget);
        used = budget;
        const dots = @min(width - used, @as(usize, 2));
        for (0..dots) |_| try append(out, arena, ".");
        used += dots;
    }
    return used;
}

fn pad(out: *std.ArrayList(u8), arena: Allocator, used: usize, width: usize) !void {
    for (used..width) |_| try append(out, arena, " ");
}

fn renderRow(out: *std.ArrayList(u8), state: *State, theme: Theme, arena: Allocator, width: usize, hit_pos: usize, colors: bool, glyphs: Glyphs, scrollbar: bool, thumb: bool) !void {
    const hit = state.hits[hit_pos];
    const active = hit_pos == state.current;
    const bg = if (active) theme.bg_plus else theme.bg;
    const fg = if (active) theme.fg_plus else theme.fg;
    const hl = if (active) theme.hl_plus else theme.hl;
    try style(out, arena, colors, theme.pointer, bg);
    if (width > 0) try append(out, arena, if (active) glyphs.pointer else " ");
    if (width > 1) {
        try style(out, arena, colors, theme.marker, bg);
        try append(out, arena, if (state.marked[hit.index]) glyphs.marker else " ");
    }
    if (width > 2) {
        try style(out, arena, colors, fg, if (active) bg else theme.gutter);
        try append(out, arena, " ");
    }
    const gutter = @min(width, @as(usize, 3));
    const scroll_width: usize = if (scrollbar and width > gutter) 1 else 0;
    const text_width = width - gutter - scroll_width;
    const row = state.visible[hit.index];
    // Under --ansi the row's own colors are decoded per frame, for the few
    // rows on screen, rather than kept for every row.
    var decode_arena = std.heap.ArenaAllocator.init(arena);
    defer decode_arena.deinit();
    const styles: ?[]const ansi.Style = if (state.opts.ansi) blk: {
        const headers = @min(state.opts.header_lines, state.rows.len);
        const decoded_row = try ansi.decode(decode_arena.allocator(), state.rows[headers + hit.index]);
        const plain = decoded_row.plain;
        const offset = @intFromPtr(fuzzy.visiblePart(plain, state.opts.delimiter, state.opts.with_nth_from).ptr) - @intFromPtr(plain.ptr);
        break :blk decoded_row.styles[offset..];
    } else null;
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(arena);
    _ = try fuzzy.matchRow(state.parsed, row, &positions, arena);
    const clipped = displayWidth(row) > text_width;
    const budget = if (clipped) text_width -| 2 else text_width;
    var used: usize = 0;
    var i: usize = 0;
    var pos: usize = 0;
    // A row's own colors are written as they arrived, so the basic 16 keep
    // the terminal's palette; the theme's colors go through setColor.
    const Pen = struct { fg: Color, own: bool = false, bold: bool = false };
    var shown: Pen = .{ .fg = fg };
    try style(out, arena, colors, fg, bg);
    while (i < row.len) {
        const d = decoded(row, i);
        const w = if (d.cp == '\t') @as(usize, 1) else columns(d.cp);
        if (used + w > budget) break;
        while (pos < positions.items.len and positions.items[pos] < i) pos += 1;
        const match = pos < positions.items.len and positions.items[pos] < i + d.len;
        // A match wins over the row's own color, as in fzf.
        const own: ansi.Style = if (styles) |all| (if (i < all.len) all[i] else .{}) else .{};
        const want: Pen = if (match)
            .{ .fg = hl, .bold = own.bold }
        else if (own.fg) |color|
            .{ .fg = color, .own = true, .bold = own.bold }
        else
            .{ .fg = fg, .bold = own.bold };
        if (colors and !std.meta.eql(want, shown)) {
            if (want.bold != shown.bold) try append(out, arena, if (want.bold) "\x1b[1m" else "\x1b[22m");
            if (want.own) try ansi.writeFg(out, arena, want.fg) else try setColor(out, arena, want.fg, false);
            shown = want;
        }
        if (d.cp == '\t' or d.cp < 0x20 or d.cp == 0x7f) {
            try append(out, arena, " ");
        } else {
            try appendRune(out, arena, d.cp);
        }
        used += w;
        i += d.len;
    }
    if (colors and !std.meta.eql(shown, Pen{ .fg = fg })) {
        if (shown.bold) try append(out, arena, "\x1b[22m");
        try setColor(out, arena, fg, false);
    }
    if (clipped) {
        try pad(out, arena, used, budget);
        used = budget;
        const dots = @min(text_width - used, @as(usize, 2));
        for (0..dots) |_| try append(out, arena, ".");
        used += dots;
    }
    try pad(out, arena, used, text_width);
    if (scroll_width != 0) {
        try style(out, arena, colors, fg, if (active) bg else theme.gutter);
        try append(out, arena, if (thumb) glyphs.scroll else " ");
    }
}

fn renderPrompt(out: *std.ArrayList(u8), state: *const State, theme: Theme, arena: Allocator, width: usize, colors: bool) !usize {
    try style(out, arena, colors, theme.prompt, theme.bg);
    const prompt_used = try plainWidth(out, arena, state.opts.prompt, width);
    const available = width - prompt_used;
    if (available == 0) return width -| 1;
    const caret_col = displayWidth(state.query.items[0..state.query_cursor]);
    const skip_cols = if (caret_col >= available) caret_col - available + 1 else 0;
    var skip_bytes: usize = 0;
    var skipped: usize = 0;
    while (skip_bytes < state.query.items.len and skipped < skip_cols) {
        const d = decoded(state.query.items, skip_bytes);
        skipped += columns(d.cp);
        skip_bytes += d.len;
    }
    try style(out, arena, colors, theme.query, theme.bg);
    const used = try plainWidth(out, arena, state.query.items[skip_bytes..], available);
    try pad(out, arena, prompt_used + used, width);
    return @min(width - 1, prompt_used + (caret_col -| skipped));
}

fn previewTextWidth(out: *std.ArrayList(u8), arena: Allocator, text: []const u8, limit: usize, colors: bool) !usize {
    var i: usize = 0;
    var used: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            var end = i + 1;
            while (end < text.len and text[end] != 'm') : (end += 1) {}
            end = @min(end + 1, text.len);
            if (colors) try append(out, arena, text[i..end]);
            i = end;
            continue;
        }
        const d = decoded(text, i);
        const count = columns(d.cp);
        if (used + count > limit) break;
        try append(out, arena, text[i .. i + d.len]);
        used += count;
        i += d.len;
    }
    return used;
}

pub fn render(state: *State, theme: Theme, width: usize, height: usize, colors: bool, unicode: bool, arena: Allocator) ![]const u8 {
    state.setHeight(height);
    const glyphs = if (unicode) unicode_glyphs else ascii_glyphs;
    var out: std.ArrayList(u8) = .empty;
    if (colors) try append(&out, arena, "\x1b[?25l\x1b[H");
    const pane_height = state.preview_height -| 1;
    const preview_left = @min(width, @as(usize, 1));
    const preview_right = @min(width - preview_left, @as(usize, 1));
    const preview_width = width - preview_left - preview_right;
    const formatted = if (pane_height > 0 and state.preview_text != null)
        try preview.format(arena, state.preview_text.?, preview_width, state.opts.preview_wrap, colors)
    else
        null;
    defer if (formatted) |content| {
        for (content.lines) |line| arena.free(line.text);
        arena.free(content.lines);
    };
    var sticky: usize = 0;
    if (formatted) |content| {
        while (sticky < content.lines.len and content.lines[sticky].source <= state.opts.preview_header_lines) : (sticky += 1) {}
        sticky = @min(sticky, pane_height);
        if (state.preview_focus_pending) {
            state.preview_scroll = if (content.focus_row) |row| (row -| sticky) -| ((pane_height - sticky) / 3) else 0;
            state.preview_focus_pending = false;
        }
        state.preview_scroll = @min(state.preview_scroll, content.lines.len -| (sticky + 1));
    }
    const header_count = @min(@min(state.opts.header_lines, state.rows.len), height -| (2 +| state.preview_height));
    const list_height = height -| (2 + header_count + state.preview_height);
    const list_start = state.preview_height;
    const overflow = state.hits.len > list_height and list_height > 0;
    var cursor_col: usize = 0;
    for (0..height) |line| {
        if (line != 0) try append(&out, arena, "\r\n");
        if (line < pane_height) {
            if (formatted) |content| {
                const position = if (line < sticky) line else state.preview_scroll + line;
                var indicator: []const u8 = "";
                var indicator_buf: [48]u8 = undefined;
                if (line == 0 and content.lines.len > pane_height) {
                    const top = @min(sticky + state.preview_scroll, content.lines.len - 1);
                    indicator = try std.fmt.bufPrint(&indicator_buf, "{d}/{d}", .{ content.lines[top].source, content.lines[content.lines.len - 1].source });
                    if (indicator.len > width) indicator = "";
                }
                const limit = if (indicator.len > 0) width - indicator.len else width;
                if (position < content.lines.len) {
                    const visual = content.lines[position];
                    const focused = state.preview_text.?.focus_line != null and visual.source == state.preview_text.?.focus_line.?;
                    try style(&out, arena, colors, if (focused) theme.hl else theme.fg, theme.bg);
                    try pad(&out, arena, 0, @min(preview_left, limit));
                    const used = try previewTextWidth(&out, arena, visual.text, limit -| preview_left, colors);
                    if (colors) try append(&out, arena, "\x1b[0m");
                    try pad(&out, arena, @min(preview_left, limit) + used, limit);
                } else {
                    try pad(&out, arena, 0, limit);
                }
                if (indicator.len > 0) {
                    try style(&out, arena, colors, theme.info, theme.bg);
                    if (colors) try append(&out, arena, "\x1b[7m");
                    try append(&out, arena, indicator);
                }
            } else {
                try pad(&out, arena, 0, width);
            }
        } else if (state.preview_height > 0 and line == pane_height) {
            try style(&out, arena, colors, theme.border, theme.bg);
            for (0..width) |_| try append(&out, arena, glyphs.separator);
        } else if (line >= list_start and line < list_start + list_height) {
            const from_bottom = list_start + list_height - 1 - line;
            const hit_pos = state.scroll + from_bottom;
            if (hit_pos < state.hits.len) {
                const thumb_from_bottom = if (overflow)
                    state.scroll * (list_height - 1) / (state.hits.len - list_height)
                else
                    0;
                const thumb = overflow and from_bottom == thumb_from_bottom;
                try renderRow(&out, state, theme, arena, width, hit_pos, colors, glyphs, overflow, thumb);
            } else {
                try style(&out, arena, colors, theme.fg, theme.bg);
                try pad(&out, arena, 0, width);
            }
        } else if (line >= list_start + list_height and line < height -| 2) {
            const header = line - (list_start + list_height);
            try style(&out, arena, colors, theme.header, theme.bg);
            const text = fuzzy.visiblePart(state.rowText(header), state.opts.delimiter, state.opts.with_nth_from);
            // Indented by the rows' gutter, so a header names the columns below it.
            const gutter = @min(width, @as(usize, 3));
            try pad(&out, arena, 0, gutter);
            const used = gutter + try plainWidth(&out, arena, text, width - gutter);
            try pad(&out, arena, used, width);
        } else if (height >= 2 and line == height - 2) {
            try style(&out, arena, colors, theme.info, theme.bg);
            var buf: [64]u8 = undefined;
            const info = if (state.opts.multi)
                try std.fmt.bufPrint(&buf, "{d}/{d} ({d}) ", .{ state.hits.len, state.visible.len, std.mem.count(bool, state.marked, &.{true}) })
            else
                try std.fmt.bufPrint(&buf, "{d}/{d} ", .{ state.hits.len, state.visible.len });
            var used = try plainWidth(&out, arena, info, width);
            if (state.producer_running and used < width) {
                try style(&out, arena, colors, theme.spinner, theme.bg);
                const spinner = glyphs.spinner[state.spinner_frame % glyphs.spinner.len];
                used += try plainWidth(&out, arena, spinner, width - used);
                if (used < width) {
                    try append(&out, arena, " ");
                    used += 1;
                }
            }
            try style(&out, arena, colors, theme.separator, theme.bg);
            for (used..width) |_| try append(&out, arena, glyphs.separator);
        } else if (line == height - 1) {
            cursor_col = try renderPrompt(&out, state, theme, arena, width, colors);
        } else {
            try pad(&out, arena, 0, width);
        }
        if (colors) try append(&out, arena, "\x1b[0m");
    }
    if (colors and width > 0 and height > 0) {
        var cursor_buf: [48]u8 = undefined;
        try append(&out, arena, try std.fmt.bufPrint(&cursor_buf, "\x1b[{d};{d}H\x1b[?25h", .{ height, cursor_col + 1 }));
    }
    return out.toOwnedSlice(arena);
}

pub fn syncPreview(state: *State, worker: *PreviewWorker, last_id: *?usize) !bool {
    const current = state.currentRow();
    const id: ?usize = if (current) |row| row.id else null;
    var changed = false;
    if (id != last_id.*) {
        if (current) |row| {
            try worker.post(row.id, row.text);
        } else {
            worker.clear();
            state.preview_text = null;
        }
        // The old pane stays as it was until the new row's text arrives, as
        // fzf's does: resetting its scroll here would flash the old file from
        // its top before setPreview jumps the new one to its focus line.
        last_id.* = id;
        changed = true;
    }
    if (worker.take(id)) |value| {
        state.setPreview(value);
        changed = true;
    }
    return changed;
}

pub fn pick(arena: Allocator, rows: []const []const u8, opts: Options) !Outcome {
    var console = tui.Console.open() catch return .no_console;
    defer console.close();
    var state = try State.init(arena, rows, opts);
    defer state.deinit();
    var frame_arena = std.heap.ArenaAllocator.init(arena);
    defer frame_arena.deinit();
    var worker: ?PreviewWorker = if (opts.preview) |callback| PreviewWorker.init(callback) else null;
    if (worker) |*active| try active.start();
    defer if (worker) |*active| active.deinit();
    var last_id: ?usize = null;
    const theme = Theme.fromEnvironment(opts.colors);
    while (true) {
        if (worker) |*active| _ = try syncPreview(&state, active, &last_id);
        _ = frame_arena.reset(.retain_capacity);
        const size = try console.size();
        const frame = try render(&state, theme, size.width, size.height, console.vt, console.vt, frame_arena.allocator());
        try console.write(frame);
        const key = if (worker) |*active| try console.pollKeyOrWake(active.wake, 50) else try console.readKey();
        if (key) |pressed| if (try state.step(pressed)) |result| return result;
    }
}

test "theme applies FZF_DEFAULT_OPTS over the built-in palette" {
    const user =
        "--color=fg:#c8d3f5,fg+:#c8d3f5,bg:-1,bg+:#2d3f76 " ++
        "--color=hl:#65BCFF,hl+:#65BCFF,info:#FF966C,marker:#B792F4 " ++
        "--color=prompt:#B792F4,spinner:#FF966C,pointer:#c8d3f5,header:#589ED7 " ++
        "--color=border:#262626,separator:#FF966C,label:#aeaeae,query:#c8d3f5 " ++
        "--color=gutter:-1";
    const theme = Theme.fromEnvironment(user);
    try std.testing.expectEqualDeep(Color{ .rgb = .{ .r = 0x65, .g = 0xbc, .b = 0xff } }, theme.hl);
    try std.testing.expectEqualDeep(Color{ .rgb = .{ .r = 0x2d, .g = 0x3f, .b = 0x76 } }, theme.bg_plus);
    try std.testing.expectEqualDeep(Color.terminal, theme.bg);
    var other: Theme = .{};
    other.apply("--layout=reverse --color=fg:196,unknown:#ffffff --height=10");
    try std.testing.expectEqualDeep(Color{ .indexed = 196 }, other.fg);
}

test "step narrows, clamps, marks, accepts, cancels, and edits" {
    const a = std.testing.allocator;
    var state = try State.init(a, &.{ "alpha", "beta", "gamma" }, .{ .multi = true });
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 3), state.hits.len);
    _ = try state.step(.{ .character = 'b' });
    try std.testing.expectEqual(@as(usize, 1), state.hits.len);
    try std.testing.expectEqual(@as(u32, 1), state.hits[0].index);
    _ = try state.step(.up);
    _ = try state.step(.down);
    try std.testing.expectEqual(@as(usize, 0), state.current);
    _ = try state.step(.tab);
    try std.testing.expect(state.marked[1]);
    const marked = (try state.step(.enter)).?;
    try std.testing.expectEqualSlices(u32, &.{1}, marked.picked);
    a.free(marked.picked);
    _ = try state.step(.ctrl_u);
    try std.testing.expectEqualStrings("", state.query.items);
    _ = try state.step(.{ .character = 'h' });
    _ = try state.step(.{ .character = 'i' });
    _ = try state.step(.{ .character = ' ' });
    _ = try state.step(.{ .character = 'x' });
    _ = try state.step(.ctrl_w);
    try std.testing.expectEqualStrings("hi ", state.query.items);
    _ = try state.step(.ctrl_u);
    try std.testing.expectEqualStrings("", state.query.items);
    try std.testing.expect((try state.step(.escape)).? == .cancelled);

    var plain = try State.init(a, &.{ "one", "two" }, .{});
    defer plain.deinit();
    _ = try plain.step(.up);
    _ = try plain.step(.up);
    try std.testing.expectEqual(@as(usize, 1), plain.current);
    const current = (try plain.step(.enter)).?;
    try std.testing.expectEqualSlices(u32, &.{1}, current.picked);
    a.free(current.picked);
}

test "marks return original list order even after moving backward" {
    const a = std.testing.allocator;
    var state = try State.init(a, &.{ "one", "two", "three" }, .{ .multi = true });
    defer state.deinit();
    _ = try state.step(.up);
    _ = try state.step(.up);
    _ = try state.step(.tab);
    _ = try state.step(.down);
    _ = try state.step(.down);
    _ = try state.step(.tab);
    const result = (try state.step(.enter)).?;
    try std.testing.expectEqualSlices(u32, &.{ 0, 2 }, result.picked);
    a.free(result.picked);
}

test "render uses the bottom prompt, info, pointer, and display-width clipping" {
    const a = std.testing.allocator;
    const long = "012345678901234567890123456789012345678901234567890123456789";
    var state = try State.init(a, &.{long}, .{});
    defer state.deinit();
    _ = try state.step(.{ .character = '0' });
    const frame = try render(&state, .{}, 40, 10, true, true, a);
    defer a.free(frame);
    const clean = try fuzzy.stripAnsi(a, frame);
    defer if (clean.ptr != frame.ptr) a.free(clean);
    var lines = std.mem.splitSequence(u8, clean, "\r\n");
    var found_row = false;
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        if (index == 8) try std.testing.expect(std.mem.indexOf(u8, line, "1/1") != null);
        if (index == 9) try std.testing.expect(std.mem.startsWith(u8, line, "> 0"));
        if (std.mem.startsWith(u8, line, "\u{258C}  0123")) {
            found_row = true;
            try std.testing.expectEqual(@as(usize, 40), displayWidth(line));
            try std.testing.expect(std.mem.endsWith(u8, line, ".."));
        }
    }
    try std.testing.expect(found_row);

    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(a);
    for (0..30) |_| try wide.appendSlice(a, "\u{65E5}");
    var cjk = try State.init(a, &.{wide.items}, .{});
    defer cjk.deinit();
    const cjk_frame = try render(&cjk, .{}, 40, 10, false, true, a);
    defer a.free(cjk_frame);
    var cjk_lines = std.mem.splitSequence(u8, cjk_frame, "\r\n");
    var found_cjk = false;
    while (cjk_lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "\u{258C}  \u{65E5}")) continue;
        found_cjk = true;
        try std.testing.expectEqual(@as(usize, 40), displayWidth(line));
        try std.testing.expect(std.mem.endsWith(u8, line, ".."));
    }
    try std.testing.expect(found_cjk);
}

test "with-nth hides and excludes the key field" {
    const a = std.testing.allocator;
    var state = try State.init(a, &.{ "secret\taction", "other\tchoice" }, .{ .delimiter = '\t', .with_nth_from = 2 });
    defer state.deinit();
    try std.testing.expectEqualStrings("action", state.visible[0]);
    _ = try state.step(.{ .character = 's' });
    _ = try state.step(.{ .character = 'e' });
    _ = try state.step(.{ .character = 'c' });
    try std.testing.expectEqual(@as(usize, 0), state.hits.len);
    _ = try state.step(.ctrl_u);
    const frame = try render(&state, .{}, 40, 10, false, true, a);
    defer a.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "action") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "secret") == null);
}

test "header lines render and cannot be selected" {
    const a = std.testing.allocator;
    var state = try State.init(a, &.{ "heading", "choice" }, .{ .header_lines = 1 });
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.hits.len);
    const frame = try render(&state, .{}, 40, 10, false, true, a);
    defer a.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "heading") != null);
    const result = (try state.step(.enter)).?;
    try std.testing.expectEqualSlices(u32, &.{1}, result.picked);
    a.free(result.picked);
}

test "appended rows preserve marks and the selected row" {
    const a = std.testing.allocator;
    var state = try State.init(a, &.{}, .{ .multi = true });
    defer state.deinit();
    try state.appendRows(&.{ "one", "two" });
    try state.refreshRows();
    _ = try state.step(.up);
    _ = try state.step(.tab);
    try std.testing.expect(state.marked[1]);
    try state.appendRows(&.{ "three", "four" });
    try state.refreshRows();
    try std.testing.expect(state.marked[1]);
    const result = (try state.step(.enter)).?;
    try std.testing.expectEqualSlices(u32, &.{1}, result.picked);
    a.free(result.picked);
}
