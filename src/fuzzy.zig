//! Query parsing and row ranking for the native fuzzy picker.
//!
//! The query syntax, v1 window search, v2 alignment scoring, and bonus
//! constants follow fzf by Junegunn Choi (MIT); see NOTICE for attribution.

const std = @import("std");
const fold = @import("fold.zig");
const score = @import("score.zig");

const readRune = fold.readRune;
const foldAccent = fold.foldAccent;
const normalize = fold.normalize;
const v1Match = score.v1Match;

pub const Case = enum { smart, respect, ignore };

pub const TermKind = score.TermKind;
pub const Term = score.Term;

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
    var runes: std.ArrayList(u21) = .empty;
    var ascii = true;
    var scan: usize = 0;
    while (scan < part.len) {
        const rune = readRune(part, scan);
        const value = normalize(rune.value, sensitive);
        try runes.append(arena, value);
        if (value >= 0x80) ascii = false;
        var bytes: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(value, &bytes);
        try folded.appendSlice(arena, bytes[0..length]);
        scan = rune.end;
    }
    return .{
        .text = try folded.toOwnedSlice(arena),
        .kind = kind,
        .inverse = inverse,
        .case_sensitive = sensitive,
        .folded = try runes.toOwnedSlice(arena),
        .ascii = ascii,
    };
}

pub fn matchRow(query: Query, row: []const u8, positions: ?*std.ArrayList(usize), arena: std.mem.Allocator) !?i32 {
    const scratch = try arena.create(score.Scratch);
    defer arena.destroy(scratch);
    scratch.* = .{};
    const backtrack = if (positions != null) try arena.create(score.Backtrack) else null;
    defer if (backtrack) |table| arena.destroy(table);
    scratch.backtrack = backtrack;
    return score.matchRow(query, row, positions, arena, scratch);
}

pub const Hit = struct { index: u32, score: i32 };

const RankWorker = struct {
    query: Query,
    rows: []const []const u8,
    first: usize,
    local_arena: std.heap.ArenaAllocator,
    hits: std.ArrayList(Hit) = .empty,
    failure: ?anyerror = null,

    fn run(self: *RankWorker) void {
        self.process() catch |err| {
            self.failure = err;
        };
    }

    fn process(self: *RankWorker) !void {
        const allocator = self.local_arena.allocator();
        const scratch = try allocator.create(score.Scratch);
        scratch.* = .{};
        for (self.rows, 0..) |row, offset| {
            const value = try score.matchRow(self.query, row, null, allocator, scratch) orelse continue;
            try self.hits.append(allocator, .{
                .index = std.math.cast(u32, self.first + offset) orelse return error.TooManyRows,
                .score = value,
            });
        }
    }
};

fn sortHits(hits: []Hit, rows: []const []const u8) void {
    std.sort.pdq(Hit, hits, rows, struct {
        fn less(all_rows: []const []const u8, a: Hit, b: Hit) bool {
            if (a.score != b.score) return a.score > b.score;
            const a_len = all_rows[a.index].len;
            const b_len = all_rows[b.index].len;
            if (a_len != b_len) return a_len < b_len;
            return a.index < b.index;
        }
    }.less);
}

/// Filter and rank; an empty query preserves input order.
pub fn rank(arena: std.mem.Allocator, query: Query, rows: []const []const u8) ![]Hit {
    if (query.groups.len == 0) {
        const result = try arena.alloc(Hit, rows.len);
        for (result, 0..) |*hit, index| hit.* = .{
            .index = std.math.cast(u32, index) orelse return error.TooManyRows,
            .score = 0,
        };
        return result;
    }

    const worker_count = @min(std.Thread.getCpuCount() catch 1, @max(@as(usize, 1), rows.len / 20_000));
    if (worker_count == 1) {
        const scratch = try arena.create(score.Scratch);
        defer arena.destroy(scratch);
        scratch.* = .{};
        var hits: std.ArrayList(Hit) = .empty;
        for (rows, 0..) |row, index| {
            const value = try score.matchRow(query, row, null, arena, scratch) orelse continue;
            try hits.append(arena, .{
                .index = std.math.cast(u32, index) orelse return error.TooManyRows,
                .score = value,
            });
        }
        sortHits(hits.items, rows);
        return hits.toOwnedSlice(arena);
    }

    const workers = try arena.alloc(RankWorker, worker_count);
    var initialized: usize = 0;
    defer for (workers[0..initialized]) |*worker| worker.local_arena.deinit();
    const chunk = (rows.len + worker_count - 1) / worker_count;
    for (workers, 0..) |*worker, index| {
        const first = index * chunk;
        worker.* = .{
            .query = query,
            .rows = rows[first..@min(first + chunk, rows.len)],
            .first = first,
            .local_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
        initialized += 1;
    }
    const threads = try arena.alloc(std.Thread, worker_count - 1);
    var started: usize = 0;
    for (workers[1..]) |*worker| {
        threads[started] = std.Thread.spawn(.{}, RankWorker.run, .{worker}) catch {
            worker.run();
            continue;
        };
        started += 1;
    }
    workers[0].run();
    for (threads[0..started]) |thread| thread.join();

    var total: usize = 0;
    for (workers) |worker| {
        if (worker.failure) |err| return err;
        total += worker.hits.items.len;
    }
    const result = try arena.alloc(Hit, total);
    var cursor: usize = 0;
    for (workers) |worker| {
        const source = worker.hits.items;
        @memcpy(result[cursor..][0..source.len], source);
        cursor += source.len;
    }
    sortHits(result, rows);
    return result;
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
        for (group) |term| {
            a.free(term.text);
            a.free(term.folded);
        }
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
