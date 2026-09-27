const std = @import("std");

pub const Rune = struct { value: u21, start: usize, end: usize };

pub fn readRune(bytes: []const u8, start: usize) Rune {
    if (bytes[start] < 0x80) return .{ .value = bytes[start], .start = start, .end = start + 1 };
    const length: usize = std.unicode.utf8ByteSequenceLength(bytes[start]) catch 1;
    const end = @min(start + length, bytes.len);
    const value = std.unicode.utf8Decode(bytes[start..end]) catch @as(u21, bytes[start]);
    return .{ .value = value, .start = start, .end = if (value == bytes[start] and length != 1) start + 1 else end };
}

pub fn previousRune(bytes: []const u8, end: usize) Rune {
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

pub fn foldAccent(cp: u21) u21 {
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
pub fn normalize(cp: u21, sensitive: bool) u21 {
    const base = foldAccent(cp);
    return if (!sensitive and base >= 'A' and base <= 'Z') base + ('a' - 'A') else base;
}

pub const ascii_fold: [2][256]u21 = blk: {
    @setEvalBranchQuota(10_000);
    var result: [2][256]u21 = undefined;
    for (0..256) |byte| {
        result[0][byte] = normalize(@intCast(byte), false);
        result[1][byte] = normalize(@intCast(byte), true);
    }
    break :blk result;
};

pub fn same(query_char: u21, row_char: u21, sensitive: bool) bool {
    return query_char == normalize(row_char, sensitive);
}

pub const CharClass = enum { white, nonword, delimiter, lower, upper, letter, number };

pub fn charClass(cp: u21) CharClass {
    const value = foldAccent(cp);
    if (value == ' ' or (value >= 9 and value <= 13) or value == 0xa0) return .white;
    if (value == '/' or value == ',' or value == ':' or value == ';' or value == '|') return .delimiter;
    if (value >= 'a' and value <= 'z') return .lower;
    if (value >= 'A' and value <= 'Z') return .upper;
    if (value >= '0' and value <= '9') return .number;
    if (value >= 0x80) return .letter;
    return .nonword;
}

pub fn bonus(prev: CharClass, current: CharClass) i32 {
    if (current == .white) return 10;
    if (current == .nonword or current == .delimiter) return 8;
    if (prev == .white) return 10;
    if (prev == .delimiter) return 9;
    if (prev == .nonword) return 8;
    if ((prev == .lower and current == .upper) or (prev != .number and current == .number)) return 7;
    return 0;
}

pub fn bonusAt(row: []const u8, pos: usize) i32 {
    const prev: CharClass = if (pos == 0) .white else charClass(previousRune(row, pos).value);
    return bonus(prev, charClass(readRune(row, pos).value));
}
