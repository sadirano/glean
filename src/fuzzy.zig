//! Query parsing and row ranking for the native fuzzy picker.
//!
//! The query syntax, v1 window search, v2 alignment scoring, and bonus
//! constants follow fzf by Junegunn Choi (MIT); see NOTICE for attribution.

const std = @import("std");

pub const Case = enum { smart, respect, ignore };

pub const TermKind = enum { fuzzy, exact, prefix, suffix, equal };
pub const Term = struct {
    text: []const u8,
    kind: TermKind,
    inverse: bool,
    case_sensitive: bool,
};

/// AND of groups; a group is an OR of terms.
pub const Query = struct { groups: []const []const Term };

pub fn parseQuery(arena: std.mem.Allocator, text: []const u8, case: Case) !Query {
    var groups: std.ArrayList([]const Term) = .empty;
    var terms: std.ArrayList(Term) = .empty;
    var token: std.ArrayList(u8) = .empty;
    var after_or = false;

    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == ' ') {
            if (token.items.len == 0) continue;
            const raw = try token.toOwnedSlice(arena);
            defer arena.free(raw);
            if (std.mem.eql(u8, raw, "|")) {
                if (terms.items.len != 0) after_or = true;
                continue;
            }
            if (terms.items.len != 0 and !after_or)
                try groups.append(arena, try terms.toOwnedSlice(arena));
            try terms.append(arena, try parseTerm(arena, raw, case));
            after_or = false;
            continue;
        }
        if (text[i] == '\\' and i + 1 < text.len and text[i + 1] == ' ') {
            try token.append(arena, ' ');
            i += 1;
        } else {
            try token.append(arena, text[i]);
        }
    }
    if (terms.items.len != 0)
        try groups.append(arena, try terms.toOwnedSlice(arena));
    return .{ .groups = try groups.toOwnedSlice(arena) };
}

fn parseTerm(arena: std.mem.Allocator, raw: []const u8, case: Case) !Term {
    var part = raw;
    var inverse = false;
    var kind: TermKind = .fuzzy;
    if (part.len > 1 and part[0] == '!') {
        inverse = true;
        part = part[1..];
    }
    if (part.len > 1 and part[0] == '\'') {
        kind = .exact;
        part = part[1..];
    } else if (part.len > 1 and part[0] == '^') {
        kind = .prefix;
        part = part[1..];
    }
    if (part.len > 1 and part[part.len - 1] == '$') {
        kind = if (kind == .prefix) .equal else .suffix;
        part = part[0 .. part.len - 1];
    }
    if (inverse and kind == .fuzzy) kind = .exact;

    var sensitive = case == .respect;
    if (case == .smart) {
        var scan: usize = 0;
        while (scan < part.len) {
            const rune = readRune(part, scan);
            const base = foldAccent(rune.value);
            if (base >= 'A' and base <= 'Z') sensitive = true;
            scan = rune.end;
        }
    }
    var folded: std.ArrayList(u8) = .empty;
    var scan: usize = 0;
    while (scan < part.len) {
        const rune = readRune(part, scan);
        const value = normalize(rune.value, sensitive);
        var bytes: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(value, &bytes);
        try folded.appendSlice(arena, bytes[0..length]);
        scan = rune.end;
    }
    return .{ .text = try folded.toOwnedSlice(arena), .kind = kind, .inverse = inverse, .case_sensitive = sensitive };
}

const Rune = struct { value: u21, start: usize, end: usize };

fn readRune(bytes: []const u8, start: usize) Rune {
    const length: usize = std.unicode.utf8ByteSequenceLength(bytes[start]) catch 1;
    const end = @min(start + length, bytes.len);
    const value = std.unicode.utf8Decode(bytes[start..end]) catch @as(u21, bytes[start]);
    return .{ .value = value, .start = start, .end = if (value == bytes[start] and length != 1) start + 1 else end };
}

fn previousRune(bytes: []const u8, end: usize) Rune {
    var start = end - 1;
    while (start > 0 and bytes[start] & 0xc0 == 0x80) : (start -= 1) {}
    const rune = readRune(bytes, start);
    if (rune.end == end) return rune;
    return .{ .value = bytes[end - 1], .start = end - 1, .end = end };
}

// The table keeps fzf's single-rune folds, including irregular letters.
const fold_00c0 = "AAAAAA.CEEEEIIII" ++
    ".NOOOOO.OUUUUY.s" ++
    "aaaaaa.ceeeeiiii" ++
    ".nooooo.ouuuuy.y" ++
    "aaaaaaccccccccdd" ++
    "ddeeeeeeeeeegggg" ++
    "gggghhhhiiiiiiii" ++
    "Ii..jjkk.lllllll" ++
    "lllnnnnnn...oooo" ++
    "oo..rrrrrrssssss" ++
    "ssttttttuuuuuuuu" ++
    "uuuuwwyyYzzzzzzs" ++
    "bBbb..OccDDdd.E." ++
    "EffG...Ikkl.MNnO" ++
    "oo..pp.....tttTu" ++
    "u.Vyyzz........." ++
    ".............aai" ++
    "ioouu........e.." ++
    "....ggggkkoo...." ++
    "j...gg..nn......" ++
    "aaaaeeeeiiiioooo" ++
    "rrrruuuusstt..hh" ++
    "Nd..zzaaee....oo" ++
    "..yylntj...CcL.s" ++
    "z..BUVEeJjQqRrYy" ++
    "aa.bocdde..eeeej" ++
    "gg...hh.i..lll.m" ++
    "mmnn.o...rrrrrrr" ++
    "..s....ttu.vvwy." ++
    "zz.....c..e..jk." ++
    "q.............h.";
const fold_1d00 = "........ei......" ++
    ".ooo..oo.....uum" ++
    "................" ++
    "................" ++
    "................" ++
    "................" ++
    "..iruv.........." ++
    "................";
const fold_1e00 = "aabbbbbb..dddddd" ++
    "dddd....eeee..ff" ++
    "gghhhhhhhhhhii.." ++
    "kkkkkkll..llllmm" ++
    "mmmmnnnnnnnn...." ++
    "....pppprrrr..rr" ++
    "ssss......tttttt" ++
    "ttuuuuuu....vvvv" ++
    "wwwwwwwwwwxxxxyy" ++
    "zzzzzzhtwyas..s." ++
    "aaaaAaAaAaAaAaAa" ++
    "AaAaAaAaeeeeeeEe" ++
    "EeEeEeEeiiiioooo" ++
    "OoOoOoOoOoOoOoOo" ++
    "OoOouuuuUuUuUuUu" ++
    "Uuyyyyyyyy......";
const fold_2070 = ".i.............." ++
    "................" ++
    ".....hklmnpst...";
const fold_2100 = "................" ++
    "................" ++
    "..........ka...." ++
    "................" ++
    "................" ++
    "................" ++
    "................" ++
    "................" ++
    "...cc...........";
const fold_2c60 = "..l.r........ama" ++
    "..............sz";
const fold_a720 = "................" ++
    "................" ++
    "................" ++
    "................" ++
    "................" ++
    "................" ++
    ".............h.." ++
    "................" ++
    "..........hegl.." ++
    "ktj............." ++
    ".....s.........." ++
    "................" ++
    "................" ++
    "................";
const fold_ff00 = "................" ++
    "................" ++
    ".ABCDEFGHIJKLMNO" ++
    "PQRSTUVWXYZ....." ++
    ".abcdefghijklmno" ++
    "pqrstuvwxyz.....";

fn foldAccent(cp: u21) u21 {
    const mapped: u8 = switch (cp) {
        0x00c0...0x02af => fold_00c0[@intCast(cp - 0x00c0)],
        0x1d00...0x1d7f => fold_1d00[@intCast(cp - 0x1d00)],
        0x1e00...0x1eff => fold_1e00[@intCast(cp - 0x1e00)],
        0x2070...0x209f => fold_2070[@intCast(cp - 0x2070)],
        0x2100...0x218f => fold_2100[@intCast(cp - 0x2100)],
        0x2c60...0x2c7f => fold_2c60[@intCast(cp - 0x2c60)],
        0xa720...0xa7ff => fold_a720[@intCast(cp - 0xa720)],
        0xff00...0xff5f => fold_ff00[@intCast(cp - 0xff00)],
        else => return cp,
    };
    return if (mapped == '.') cp else mapped;
}
fn normalize(cp: u21, sensitive: bool) u21 {
    const base = foldAccent(cp);
    return if (!sensitive and base >= 'A' and base <= 'Z') base + ('a' - 'A') else base;
}

fn same(query_char: u21, row_char: u21, sensitive: bool) bool {
    return query_char == normalize(row_char, sensitive);
}

const CharClass = enum { white, nonword, delimiter, lower, upper, letter, number };

fn charClass(cp: u21) CharClass {
    const value = foldAccent(cp);
    if (value == ' ' or (value >= 9 and value <= 13) or value == 0xa0) return .white;
    if (value == '/' or value == ',' or value == ':' or value == ';' or value == '|') return .delimiter;
    if (value >= 'a' and value <= 'z') return .lower;
    if (value >= 'A' and value <= 'Z') return .upper;
    if (value >= '0' and value <= '9') return .number;
    if (value >= 0x80) return .letter;
    return .nonword;
}

fn bonus(prev: CharClass, current: CharClass) i32 {
    if (current == .white) return 10;
    if (current == .nonword or current == .delimiter) return 8;
    if (prev == .white) return 10;
    if (prev == .delimiter) return 9;
    if (prev == .nonword) return 8;
    if ((prev == .lower and current == .upper) or (prev != .number and current == .number)) return 7;
    return 0;
}

fn bonusAt(row: []const u8, pos: usize) i32 {
    const prev: CharClass = if (pos == 0) .white else charClass(previousRune(row, pos).value);
    return bonus(prev, charClass(readRune(row, pos).value));
}

fn clampedScore(value: i64) i32 {
    return @intCast(std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32)));
}

const MatchChar = struct { value: u21, start: usize, end: usize, bonus: i32 };

fn appendSpan(list: *std.ArrayList(usize), arena: std.mem.Allocator, start: usize, end: usize) !void {
    for (start..end) |offset| try list.append(arena, offset);
}

fn v1Match(term: Term, row: []const u8, end: usize, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator) !i32 {
    var chars: std.ArrayList(MatchChar) = .empty;
    defer chars.deinit(arena);
    var qend = term.text.len;
    var rend = end;
    while (qend != 0) {
        const rune = previousRune(row, rend);
        rend = rune.start;
        const q = previousRune(term.text, qend);
        if (!same(q.value, rune.value, term.case_sensitive)) continue;
        try chars.append(arena, .{ .value = rune.value, .start = rune.start, .end = rune.end, .bonus = bonusAt(row, rune.start) });
        qend = q.start;
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

fn v2Match(term: Term, row: []const u8, start: usize, end: usize, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator) !?i32 {
    var query_chars: [max_query]u21 = undefined;
    var qlen: usize = 0;
    var qpos: usize = 0;
    while (qpos < term.text.len) {
        if (qlen == max_query) return null;
        const rune = readRune(term.text, qpos);
        query_chars[qlen] = rune.value;
        qlen += 1;
        qpos = rune.end;
    }
    var window: [max_window]MatchChar = undefined;
    var wlen: usize = 0;
    var rpos = start;
    var prev_class: CharClass = if (start == 0) .white else charClass(previousRune(row, start).value);
    while (rpos < end) {
        if (wlen == max_window) return null;
        const rune = readRune(row, rpos);
        const current_class = charClass(rune.value);
        window[wlen] = .{ .value = rune.value, .start = rune.start, .end = rune.end, .bonus = bonus(prev_class, current_class) };
        wlen += 1;
        prev_class = current_class;
        rpos = rune.end;
    }
    if (qlen * wlen > max_cells) return null;

    var prev_match: [max_window]i32 = undefined;
    var prev_gap: [max_window]i32 = undefined;
    var prev_run: [max_window]i32 = undefined;
    var curr_match: [max_window]i32 = undefined;
    var curr_gap: [max_window]i32 = undefined;
    var curr_run: [max_window]i32 = undefined;
    var match_from: [max_cells]u8 = undefined;
    var gap_from: [max_cells]u8 = undefined;

    for (0..qlen) |qi| {
        for (0..wlen) |wi| {
            const cell = qi * wlen + wi;
            curr_match[wi] = minus_inf;
            curr_run[wi] = 0;
            if (positions != null) match_from[cell] = 0;
            if (same(query_chars[qi], window[wi].value, term.case_sensitive)) {
                if (qi == 0) {
                    curr_match[wi] = 16 + 2 * window[wi].bonus;
                    curr_run[wi] = window[wi].bonus;
                } else if (wi > 0) {
                    if (prev_match[wi - 1] != minus_inf) {
                        const run = @max(prev_run[wi - 1], window[wi].bonus);
                        curr_match[wi] = prev_match[wi - 1] + 16 + @max(run, 4);
                        curr_run[wi] = run;
                        if (positions != null) match_from[cell] = 1;
                    }
                    if (prev_gap[wi - 1] != minus_inf) {
                        const separated = prev_gap[wi - 1] + 16 + window[wi].bonus;
                        if (separated > curr_match[wi]) {
                            curr_match[wi] = separated;
                            curr_run[wi] = window[wi].bonus;
                            if (positions != null) match_from[cell] = 2;
                        }
                    }
                }
            }
            curr_gap[wi] = minus_inf;
            if (positions != null) gap_from[cell] = 0;
            if (wi > 0) {
                if (curr_match[wi - 1] != minus_inf) {
                    curr_gap[wi] = curr_match[wi - 1] - 3;
                    if (positions != null) gap_from[cell] = 1;
                }
                if (curr_gap[wi - 1] != minus_inf and curr_gap[wi - 1] - 1 > curr_gap[wi]) {
                    curr_gap[wi] = curr_gap[wi - 1] - 1;
                    if (positions != null) gap_from[cell] = 2;
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
        const old_len = list.items.len;
        var qi = qlen - 1;
        var wi = best_end;
        var state: u8 = 1;
        while (true) {
            const cell = qi * wlen + wi;
            if (state == 1) {
                try appendSpan(list, arena, window[wi].start, window[wi].end);
                if (qi == 0) break;
                state = match_from[cell];
                qi -= 1;
            } else {
                state = gap_from[cell];
            }
            wi -= 1;
        }
        std.mem.reverse(usize, list.items[old_len..]);
    }
    return best_score;
}

fn fuzzyMatch(term: Term, row: []const u8, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator) !?i32 {
    if (term.text.len > row.len) return null;
    var qpos: usize = 0;
    var rpos: usize = 0;
    var first: usize = 0;
    var end: usize = 0;
    while (rpos < row.len) {
        const rune = readRune(row, rpos);
        if (same(readRune(term.text, qpos).value, rune.value, term.case_sensitive)) {
            if (qpos == 0) first = rune.start;
            qpos = readRune(term.text, qpos).end;
            if (qpos == term.text.len) {
                end = rune.end;
                break;
            }
        }
        rpos = rune.end;
    }
    if (end == 0) return null;
    var last_end = end;
    const last_query = previousRune(term.text, term.text.len).value;
    rpos = end;
    while (rpos < row.len) {
        const rune = readRune(row, rpos);
        if (same(last_query, rune.value, term.case_sensitive)) last_end = rune.end;
        rpos = rune.end;
    }
    if (try v2Match(term, row, first, last_end, positions, arena)) |score| return score;
    return try v1Match(term, row, end, positions, arena);
}

fn exactAt(term: Term, row: []const u8, start: usize) ?usize {
    var qpos: usize = 0;
    var rpos = start;
    while (qpos < term.text.len) {
        if (rpos == row.len) return null;
        const q = readRune(term.text, qpos);
        const r = readRune(row, rpos);
        if (!same(q.value, r.value, term.case_sensitive)) return null;
        qpos = q.end;
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
    var length: i64 = 0;
    var qpos: usize = 0;
    while (qpos < term.text.len) : (length += 1) qpos = readRune(term.text, qpos).end;
    return clampedScore(length * 16 + best_bonus);
}

fn positiveMatch(term: Term, row: []const u8, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator) !?i32 {
    return switch (term.kind) {
        .fuzzy => fuzzyMatch(term, row, positions, arena),
        else => exactMatch(term, row, positions, arena),
    };
}

/// null means no match. Higher scores rank first. Positions are byte offsets.
pub fn matchRow(query: Query, row: []const u8, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator) !?i32 {
    if (positions) |list| list.clearRetainingCapacity();
    var total: i64 = 0;
    for (query.groups) |group| {
        var best_score: ?i32 = null;
        var best_term: ?Term = null;
        for (group) |term| {
            const positive = try positiveMatch(term, row, null, arena);
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
            if (!term.inverse) _ = try positiveMatch(term, row, list, arena);
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

pub const Hit = struct { index: u32, score: i32 };

/// Filter and rank; an empty query preserves input order.
pub fn rank(arena: std.mem.Allocator, query: Query, rows: []const []const u8) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    for (rows, 0..) |row, index| {
        const score = try matchRow(query, row, null, arena) orelse continue;
        try hits.append(arena, .{ .index = std.math.cast(u32, index) orelse return error.TooManyRows, .score = score });
    }
    if (query.groups.len != 0) std.sort.pdq(Hit, hits.items, rows, struct {
        fn less(all_rows: []const []const u8, a: Hit, b: Hit) bool {
            if (a.score != b.score) return a.score > b.score;
            const a_len = all_rows[a.index].len;
            const b_len = all_rows[b.index].len;
            if (a_len != b_len) return a_len < b_len;
            return a.index < b.index;
        }
    }.less);
    return hits.toOwnedSlice(arena);
}

/// fzf's `--delimiter D --with-nth N..` display and search region.
pub fn visiblePart(row: []const u8, delimiter: ?u8, from: usize) []const u8 {
    const delim = delimiter orelse return row;
    if (from <= 1) return row;
    var field: usize = 1;
    for (row, 0..) |ch, index| {
        if (ch != delim) continue;
        field += 1;
        if (field == from) return row[index + 1 ..];
    }
    return row[row.len..];
}

/// Strip complete CSI and OSC control sequences, preserving clean input.
pub fn stripAnsi(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var changed = false;
    var copied: usize = 0;
    var i: usize = 0;
    while (i + 1 < line.len) {
        if (line[i] != 0x1b) {
            i += 1;
            continue;
        }
        var end: ?usize = null;
        if (line[i + 1] == '[') {
            var j = i + 2;
            while (j < line.len) : (j += 1) {
                if (line[j] >= 0x40 and line[j] <= 0x7e) {
                    end = j + 1;
                    break;
                }
            }
        } else if (line[i + 1] == ']') {
            var j = i + 2;
            while (j < line.len) : (j += 1) {
                if (line[j] == 0x07) {
                    end = j + 1;
                    break;
                }
                if (line[j] == 0x1b and j + 1 < line.len and line[j + 1] == '\\') {
                    end = j + 2;
                    break;
                }
            }
        }
        if (end) |stop| {
            try out.appendSlice(arena, line[copied..i]);
            copied = stop;
            i = stop;
            changed = true;
        } else {
            i += 1;
        }
    }
    if (!changed) return line;
    try out.appendSlice(arena, line[copied..]);
    return out.toOwnedSlice(arena);
}

test "parseQuery supports extended terms and smart case" {
    const a = std.testing.allocator;
    const plain = try parseQuery(a, "foo bar", .smart);
    defer freeQuery(a, plain);
    try std.testing.expectEqual(@as(usize, 2), plain.groups.len);
    try std.testing.expectEqualStrings("foo", plain.groups[0][0].text);
    try std.testing.expectEqualStrings("bar", plain.groups[1][0].text);
    try std.testing.expectEqual(TermKind.fuzzy, plain.groups[0][0].kind);

    const cases = .{
        .{ "'foo", TermKind.exact, false, "foo" },
        .{ "^foo", TermKind.prefix, false, "foo" },
        .{ "foo$", TermKind.suffix, false, "foo" },
        .{ "^foo$", TermKind.equal, false, "foo" },
        .{ "!foo", TermKind.exact, true, "foo" },
        .{ "!^foo", TermKind.prefix, true, "foo" },
        .{ "foo\\ bar", TermKind.fuzzy, false, "foo bar" },
        .{ "!", TermKind.fuzzy, false, "!" },
        .{ "'", TermKind.fuzzy, false, "'" },
        .{ "^", TermKind.fuzzy, false, "^" },
        .{ "$", TermKind.fuzzy, false, "$" },
    };
    inline for (cases) |item| {
        const q = try parseQuery(a, item[0], .smart);
        defer freeQuery(a, q);
        const term = q.groups[0][0];
        try std.testing.expectEqual(item[1], term.kind);
        try std.testing.expectEqual(item[2], term.inverse);
        try std.testing.expectEqualStrings(item[3], term.text);
    }
    const ors = try parseQuery(a, "a | b c", .smart);
    defer freeQuery(a, ors);
    try std.testing.expectEqual(@as(usize, 2), ors.groups.len);
    try std.testing.expectEqual(@as(usize, 2), ors.groups[0].len);
    try std.testing.expectEqualStrings("b", ors.groups[0][1].text);
    const upper = try parseQuery(a, "Foo", .smart);
    defer freeQuery(a, upper);
    const lower = try parseQuery(a, "foo", .smart);
    defer freeQuery(a, lower);
    try std.testing.expect(upper.groups[0][0].case_sensitive);
    try std.testing.expect(!lower.groups[0][0].case_sensitive);
}

fn freeQuery(a: std.mem.Allocator, query: Query) void {
    for (query.groups) |group| {
        for (group) |term| a.free(term.text);
        a.free(group);
    }
    a.free(query.groups);
}

test "fuzzy subsequences match and reject" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const query = try parseQuery(a, "fbr", .smart);
    try std.testing.expect((try matchRow(query, "foo/bar", null, a)) != null);
    try std.testing.expect((try matchRow(query, "src/fuzzy.zig", null, a)) == null);
    try std.testing.expect((try matchRow(query, "fbx", null, a)) == null);
    const absent = try parseQuery(a, "fbx", .smart);
    try std.testing.expect((try matchRow(absent, "src/fuzzy.zig", null, a)) == null);
}

test "exact family, inverse, and ASCII case select rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exact = try parseQuery(a, "'bar", .smart);
    try std.testing.expect((try matchRow(exact, "foo/bar", null, a)) != null);
    try std.testing.expect((try matchRow(exact, "br", null, a)) == null);
    const prefix = try parseQuery(a, "^foo", .smart);
    try std.testing.expect((try matchRow(prefix, "foobar", null, a)) != null);
    try std.testing.expect((try matchRow(prefix, "xfoo", null, a)) == null);
    const suffix = try parseQuery(a, "bar$", .smart);
    try std.testing.expect((try matchRow(suffix, "foobar", null, a)) != null);
    try std.testing.expect((try matchRow(suffix, "barx", null, a)) == null);
    const equal = try parseQuery(a, "^foo$", .smart);
    try std.testing.expect((try matchRow(equal, "foo", null, a)) != null);
    try std.testing.expect((try matchRow(equal, "foobar", null, a)) == null);
    const inverse_prefix = try parseQuery(a, "!^foo", .smart);
    try std.testing.expect((try matchRow(inverse_prefix, "xfoo", null, a)) != null);
    try std.testing.expect((try matchRow(inverse_prefix, "foobar", null, a)) == null);
    const smart = try parseQuery(a, "Foo", .smart);
    try std.testing.expect((try matchRow(smart, "foo", null, a)) == null);
    const ignored = try parseQuery(a, "Foo", .ignore);
    try std.testing.expect((try matchRow(ignored, "foo", null, a)) != null);
    const respected = try parseQuery(a, "foo", .respect);
    try std.testing.expect((try matchRow(respected, "FOO", null, a)) == null);
}

test "empty queries keep every row in input order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = &[_][]const u8{ "long row", "x", "middle" };
    for (&[_][]const u8{ "", "   " }) |query_text| {
        const hits = try rank(a, try parseQuery(a, query_text, .smart), rows);
        try std.testing.expectEqual(@as(usize, 3), hits.len);
        for (hits, 0..) |hit, i| {
            try std.testing.expectEqual(@as(u32, @intCast(i)), hit.index);
            try std.testing.expectEqual(@as(i32, 0), hit.score);
        }
    }
}

test "group scores add and highlight offsets do not repeat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try parseQuery(a, "'ab", .smart);
    const second = try parseQuery(a, "^ab", .smart);
    const both = try parseQuery(a, "'ab ^ab", .smart);
    const row = "abc";
    const one_score = (try matchRow(first, row, null, a)).?;
    const two_score = (try matchRow(second, row, null, a)).?;
    var positions: std.ArrayList(usize) = .empty;
    const total = (try matchRow(both, row, &positions, a)).?;
    try std.testing.expectEqual(one_score + two_score, total);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, positions.items);
}

test "ranking favors the main path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = &[_][]const u8{ "src/domain_test.zig", "src/main.zig", "docs/maintenance.md" };
    const hits = try rank(a, try parseQuery(a, "main", .smart), rows);
    try std.testing.expectEqual(@as(u32, 1), hits[0].index);
}

test "boundary matches beat middle matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = &[_][]const u8{ "xaxb", "a_b" };
    const hits = try rank(a, try parseQuery(a, "ab", .smart), rows);
    try std.testing.expectEqual(@as(u32, 1), hits[0].index);
}

test "equal scores break ties by length then index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = &[_][]const u8{ "abc", "ab", "ab" };
    const hits = try rank(a, try parseQuery(a, "^ab", .smart), rows);
    try std.testing.expectEqual(@as(u32, 1), hits[0].index);
    try std.testing.expectEqual(@as(u32, 2), hits[1].index);
    try std.testing.expectEqual(@as(u32, 0), hits[2].index);
}

test "positions are ascending byte offsets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var positions: std.ArrayList(usize) = .empty;
    const query = try parseQuery(a, "fbr", .smart);
    _ = try matchRow(query, "foo/bar", &positions, a);
    try std.testing.expectEqualSlices(usize, &.{ 0, 4, 6 }, positions.items);
}

test "accent folding works in rows and queries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = try parseQuery(a, "cafe", .smart);
    const accented = try parseQuery(a, "caf\u{00e9}", .smart);
    try std.testing.expect((try matchRow(plain, "caf\u{00e9}", null, a)) != null);
    try std.testing.expect((try matchRow(accented, "cafe", null, a)) != null);
    const extended = try parseQuery(a, "a\u{00e7}\u{0101}o", .smart);
    try std.testing.expect((try matchRow(extended, "\u{00e3}cao", null, a)) != null);
    const upper = try parseQuery(a, "\u{00c9}", .smart);
    try std.testing.expect((try matchRow(upper, "e", null, a)) == null);
    try std.testing.expect((try matchRow(upper, "E", null, a)) != null);
}

test "multibyte matches highlight every source byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var positions: std.ArrayList(usize) = .empty;
    const query = try parseQuery(a, "cafe", .smart);
    _ = try matchRow(query, "caf\u{00e9}", &positions, a);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, positions.items);
}

test "whitespace boundary beats delimiter boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = &[_][]const u8{ "a/b", "a b" };
    const hits = try rank(a, try parseQuery(a, "b", .smart), rows);
    try std.testing.expectEqual(@as(u32, 1), hits[0].index);
}

test "v2 scores an earlier alignment above the v1 window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const query = try parseQuery(a, "abc", .smart);
    const term = query.groups[0][0];
    const row = "abab_c";
    const v1_score = try v1Match(term, row, row.len, null, a);
    const v2_score = (try matchRow(query, row, null, a)).?;
    try std.testing.expect(v2_score > v1_score);
    const other = "aba__c";
    try std.testing.expect((try v1Match(term, other, other.len, null, a)) > v1_score);
    const rows = &[_][]const u8{ row, other };
    const hits = try rank(a, query, rows);
    try std.testing.expectEqual(@as(u32, 0), hits[0].index);
}

test "inverse exact terms remove containing rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = &[_][]const u8{ "src/proc_test.zig", "src/proc.zig" };
    const hits = try rank(a, try parseQuery(a, "!test", .smart), rows);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(u32, 1), hits[0].index);
}

test "OR terms keep either suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = &[_][]const u8{ "a.zig", "b.md", "c.txt" };
    const hits = try rank(a, try parseQuery(a, "zig$ | md$", .smart), rows);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqual(@as(u32, 0), hits[0].index);
    try std.testing.expectEqual(@as(u32, 1), hits[1].index);
}

test "visiblePart selects fields" {
    try std.testing.expectEqualStrings("action\tdesc", visiblePart("3\taction\tdesc", '\t', 2));
    try std.testing.expectEqualStrings("", visiblePart("3\taction\tdesc", '\t', 4));
    try std.testing.expectEqualStrings("3\taction\tdesc", visiblePart("3\taction\tdesc", null, 2));
}

test "stripAnsi removes CSI and OSC without copying clean lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("src:12:x", try stripAnsi(a, "\x1b[35msrc\x1b[0m:12:x"));
    try std.testing.expectEqualStrings("abc", try stripAnsi(a, "a\x1b]0;title\x07b\x1b]x\x1b\\c"));
    const clean = "src:12:x";
    const result = try stripAnsi(a, clean);
    try std.testing.expectEqual(@intFromPtr(clean.ptr), @intFromPtr(result.ptr));
}

test "Scale 100000 rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try a.alloc([]const u8, 100_000);
    var expected: usize = 0;
    for (rows, 0..) |*row, i| {
        row.* = try std.fmt.allocPrint(a, "dir{d}/sub{d}/file{d}.zig", .{ i, i % 97, i });
        const file = std.mem.lastIndexOf(u8, row.*, "/file").?;
        if (std.mem.indexOfScalar(u8, row.*[file + 5 ..], '9') != null) expected += 1;
    }
    const hits = try rank(a, try parseQuery(a, "sub file9", .smart), rows);
    try std.testing.expectEqual(expected, hits.len);
}
