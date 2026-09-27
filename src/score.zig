const std = @import("std");
const fold = @import("fold.zig");

pub const TermKind = enum { fuzzy, exact, prefix, suffix, equal };
pub const Term = struct {
    text: []const u8,
    kind: TermKind,
    inverse: bool,
    case_sensitive: bool,
    folded: []const u21 = &.{},
    ascii: bool = false,
};

const readRune = fold.readRune;
const previousRune = fold.previousRune;
const same = fold.same;
const charClass = fold.charClass;
const CharClass = fold.CharClass;
const bonus = fold.bonus;
const bonusAt = fold.bonusAt;

fn clampedScore(value: i64) i32 {
    return @intCast(std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32)));
}

const MatchChar = struct { value: u21, start: usize, end: usize, bonus: i32 };

fn appendSpan(list: *std.ArrayList(usize), arena: std.mem.Allocator, start: usize, end: usize) !void {
    for (start..end) |offset| try list.append(arena, offset);
}

pub fn v1Match(term: Term, row: []const u8, end: usize, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator) !i32 {
    var chars: std.ArrayList(MatchChar) = .empty;
    defer chars.deinit(arena);
    var qend = term.folded.len;
    var rend = end;
    while (qend != 0) {
        const rune = previousRune(row, rend);
        rend = rune.start;
        if (term.folded[qend - 1] != fold.normalize(rune.value, term.case_sensitive)) continue;
        try chars.append(arena, .{ .value = rune.value, .start = rune.start, .end = rune.end, .bonus = bonusAt(row, rune.start) });
        qend -= 1;
    }
    std.mem.reverse(MatchChar, chars.items);
    var score: i64 = 0;
    var run_bonus: i32 = 0;
    for (chars.items, 0..) |ch, index| {
        var match_bonus = ch.bonus;
        if (index == 0) {
            score += 16 + @as(i64, match_bonus) * 2;
        } else {
            const prev = chars.items[index - 1];
            if (prev.end == ch.start) {
                run_bonus = @max(run_bonus, match_bonus);
                match_bonus = @max(run_bonus, 4);
            } else {
                var gap: i64 = 0;
                var cursor = prev.end;
                while (cursor < ch.start) : (gap += 1) cursor = readRune(row, cursor).end;
                score -= 3 + gap - 1;
                run_bonus = match_bonus;
            }
            score += 16 + match_bonus;
        }
        if (index == 0) run_bonus = ch.bonus;
        if (positions) |list| try appendSpan(list, arena, ch.start, ch.end);
    }
    return clampedScore(score);
}

// A bounded matrix keeps ranking scratch space independent of the row count.
const max_window = 512;
const max_query = 256;
const max_cells = 8192;
const minus_inf = -1_000_000_000;

pub const Backtrack = struct {
    match_from: [max_cells]u8 = undefined,
    gap_from: [max_cells]u8 = undefined,
};

pub const Scratch = struct {
    window: [max_window]MatchChar = undefined,
    prev_match: [max_window]i32 = undefined,
    prev_gap: [max_window]i32 = undefined,
    prev_run: [max_window]i32 = undefined,
    curr_match: [max_window]i32 = undefined,
    curr_gap: [max_window]i32 = undefined,
    curr_run: [max_window]i32 = undefined,
    backtrack: ?*Backtrack = null,
};

fn v2Match(term: Term, row: []const u8, start: usize, end: usize, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator, scratch: *Scratch, row_ascii: bool) !?i32 {
    const qlen = term.folded.len;
    if (qlen > max_query) return null;
    const window = &scratch.window;
    var wlen: usize = 0;
    var rpos = start;
    var prev_class: CharClass = if (start == 0) .white else charClass(previousRune(row, start).value);
    while (rpos < end) {
        if (wlen == max_window) return null;
        const rune = readRune(row, rpos);
        const current_class = charClass(rune.value);
        const normalized = if (row_ascii) fold.ascii_fold[@intFromBool(term.case_sensitive)][@as(u8, @intCast(rune.value))] else fold.normalize(rune.value, term.case_sensitive);
        window[wlen] = .{ .value = normalized, .start = rune.start, .end = rune.end, .bonus = bonus(prev_class, current_class) };
        wlen += 1;
        prev_class = current_class;
        rpos = rune.end;
    }
    if (qlen * wlen > max_cells) return null;

    const prev_match = &scratch.prev_match;
    const prev_gap = &scratch.prev_gap;
    const prev_run = &scratch.prev_run;
    const curr_match = &scratch.curr_match;
    const curr_gap = &scratch.curr_gap;
    const curr_run = &scratch.curr_run;
    const backtrack = scratch.backtrack;

    for (0..qlen) |qi| {
        for (0..wlen) |wi| {
            const cell = qi * wlen + wi;
            curr_match[wi] = minus_inf;
            curr_run[wi] = 0;
            if (backtrack) |table| table.match_from[cell] = 0;
            if (term.folded[qi] == window[wi].value) {
                if (qi == 0) {
                    curr_match[wi] = 16 + 2 * window[wi].bonus;
                    curr_run[wi] = window[wi].bonus;
                } else if (wi > 0) {
                    if (prev_match[wi - 1] != minus_inf) {
                        const run = @max(prev_run[wi - 1], window[wi].bonus);
                        curr_match[wi] = prev_match[wi - 1] + 16 + @max(run, 4);
                        curr_run[wi] = run;
                        if (backtrack) |table| table.match_from[cell] = 1;
                    }
                    if (prev_gap[wi - 1] != minus_inf) {
                        const separated = prev_gap[wi - 1] + 16 + window[wi].bonus;
                        if (separated > curr_match[wi]) {
                            curr_match[wi] = separated;
                            curr_run[wi] = window[wi].bonus;
                            if (backtrack) |table| table.match_from[cell] = 2;
                        }
                    }
                }
            }
            curr_gap[wi] = minus_inf;
            if (backtrack) |table| table.gap_from[cell] = 0;
            if (wi > 0) {
                if (curr_match[wi - 1] != minus_inf) {
                    curr_gap[wi] = curr_match[wi - 1] - 3;
                    if (backtrack) |table| table.gap_from[cell] = 1;
                }
                if (curr_gap[wi - 1] != minus_inf and curr_gap[wi - 1] - 1 > curr_gap[wi]) {
                    curr_gap[wi] = curr_gap[wi - 1] - 1;
                    if (backtrack) |table| table.gap_from[cell] = 2;
                }
            }
        }
        @memcpy(prev_match[0..wlen], curr_match[0..wlen]);
        @memcpy(prev_gap[0..wlen], curr_gap[0..wlen]);
        @memcpy(prev_run[0..wlen], curr_run[0..wlen]);
    }
    var best_score: i32 = minus_inf;
    var best_end: usize = 0;
    for (prev_match[0..wlen], 0..) |score, wi| {
        if (score > best_score) {
            best_score = score;
            best_end = wi;
        }
    }
    if (best_score == minus_inf) return null;
    if (positions) |list| {
        const table = backtrack.?;
        const old_len = list.items.len;
        var qi = qlen - 1;
        var wi = best_end;
        var state: u8 = 1;
        while (true) {
            const cell = qi * wlen + wi;
            if (state == 1) {
                try appendSpan(list, arena, window[wi].start, window[wi].end);
                if (qi == 0) break;
                state = table.match_from[cell];
                qi -= 1;
            } else {
                state = table.gap_from[cell];
            }
            wi -= 1;
        }
        std.mem.reverse(usize, list.items[old_len..]);
    }
    return best_score;
}

fn fuzzyMatch(term: Term, row: []const u8, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator, scratch: *Scratch, row_ascii: bool) !?i32 {
    if (term.text.len > row.len) return null;
    var qpos: usize = 0;
    var first: usize = 0;
    var end: usize = 0;
    var last_end: usize = 0;
    if (row_ascii and term.ascii) {
        const table = &fold.ascii_fold[@intFromBool(term.case_sensitive)];
        for (row, 0..) |byte, index| {
            const value = table[byte];
            if (end == 0) {
                if (term.folded[qpos] == value) {
                    if (qpos == 0) first = index;
                    qpos += 1;
                    if (qpos == term.folded.len) {
                        end = index + 1;
                        last_end = end;
                    }
                }
            } else if (term.folded[term.folded.len - 1] == value) {
                last_end = index + 1;
            }
        }
    } else {
        var rpos: usize = 0;
        while (rpos < row.len) {
            const rune = readRune(row, rpos);
            const value = fold.normalize(rune.value, term.case_sensitive);
            if (end == 0) {
                if (term.folded[qpos] == value) {
                    if (qpos == 0) first = rune.start;
                    qpos += 1;
                    if (qpos == term.folded.len) {
                        end = rune.end;
                        last_end = end;
                    }
                }
            } else if (term.folded[term.folded.len - 1] == value) {
                last_end = rune.end;
            }
            rpos = rune.end;
        }
    }
    if (end == 0) return null;
    if (try v2Match(term, row, first, last_end, positions, arena, scratch, row_ascii)) |score| return score;
    return try v1Match(term, row, end, positions, arena);
}

fn exactAt(term: Term, row: []const u8, start: usize) ?usize {
    var rpos = start;
    for (term.folded) |query_char| {
        if (rpos == row.len) return null;
        const r = readRune(row, rpos);
        if (query_char != fold.normalize(r.value, term.case_sensitive)) return null;
        rpos = r.end;
    }
    return rpos;
}

fn exactMatch(term: Term, row: []const u8, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator) !?i32 {
    var best_start: ?usize = null;
    var best_end: usize = 0;
    var best_bonus: i32 = -1;
    var start: usize = 0;
    while (start < row.len) : (start = readRune(row, start).end) {
        const end = exactAt(term, row, start) orelse continue;
        const allowed = switch (term.kind) {
            .exact => true,
            .prefix => start == 0,
            .suffix => end == row.len,
            .equal => start == 0 and end == row.len,
            .fuzzy => unreachable,
        };
        if (!allowed) continue;
        const score_bonus = bonusAt(row, start);
        if (score_bonus > best_bonus) {
            best_start = start;
            best_end = end;
            best_bonus = score_bonus;
            if (score_bonus == 10) break;
        }
    }
    const found = best_start orelse return null;
    if (positions) |list| try appendSpan(list, arena, found, best_end);
    return clampedScore(@as(i64, @intCast(term.folded.len)) * 16 + best_bonus);
}

fn positiveMatch(term: Term, row: []const u8, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator, scratch: *Scratch, row_ascii: bool) !?i32 {
    return switch (term.kind) {
        .fuzzy => fuzzyMatch(term, row, positions, arena, scratch, row_ascii),
        else => exactMatch(term, row, positions, arena),
    };
}

/// null means no match. Higher scores rank first. Positions are byte offsets.
pub fn matchRow(query: anytype, row: []const u8, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator, scratch: *Scratch) !?i32 {
    if (positions) |list| list.clearRetainingCapacity();
    var row_ascii = true;
    for (row) |byte| {
        if (byte >= 0x80) {
            row_ascii = false;
            break;
        }
    }
    var total: i64 = 0;
    for (query.groups) |group| {
        var best_score: ?i32 = null;
        var best_term: ?Term = null;
        for (group) |term| {
            const positive = try positiveMatch(term, row, null, arena, scratch, row_ascii);
            const score: ?i32 = if (term.inverse)
                (if (positive == null) @as(i32, 0) else null)
            else
                positive;
            if (score) |value| {
                if (best_score == null or value > best_score.?) {
                    best_score = value;
                    best_term = term;
                }
            }
        }
        const value = best_score orelse {
            if (positions) |list| list.clearRetainingCapacity();
            return null;
        };
        total += value;
        if (positions) |list| {
            const term = best_term.?;
            if (!term.inverse) _ = try positiveMatch(term, row, list, arena, scratch, row_ascii);
        }
    }
    if (positions) |list| {
        std.sort.pdq(usize, list.items, {}, std.sort.asc(usize));
        var out: usize = 0;
        for (list.items) |pos| {
            if (out != 0 and list.items[out - 1] == pos) continue;
            list.items[out] = pos;
            out += 1;
        }
        list.items.len = out;
    }
    return clampedScore(total);
}
