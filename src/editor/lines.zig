//! Splits a document into display segments, the unit the view lays out.
//! A segment is one logical line; a line longer than `fold` bytes is cut into
//! pieces so that no single Pango layout is ever large (layout cost grows
//! faster than linearly with the text it is given). Cut points depend only on
//! the line's start, so walking in either direction finds the same pieces.
//! Pieces end after a space or tab when one is near the nominal cut, so a
//! folded paragraph still breaks between words.
const std = @import("std");

/// Longest piece of one line, in bytes, before it is folded onto another row.
/// Laying out one paragraph this long costs a few milliseconds.
pub const fold: usize = 16 * 1024;
/// How far before the nominal cut a space may be looked for.
const soft_limit: usize = 256;

fn soft(cut: usize) usize {
    return @min(soft_limit, cut / 8);
}

pub const Segment = struct {
    /// Start of the logical line this piece belongs to.
    line: usize,
    start: usize,
    /// The text to lay out is `text[start..text_end]`; `[text_end..next)` is
    /// the terminator ("\n" or "\r\n"), empty for a cut piece or the last line.
    text_end: usize,
    next: usize,

    pub fn len(s: Segment) usize {
        return s.next - s.start;
    }
    pub fn terminated(s: Segment) bool {
        return s.text_end < s.next;
    }
};

fn continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

/// Start of the line containing `pos`: just after the last line break before it.
/// Scans backwards 32 bytes at a time, as a line can be megabytes long.
pub fn lineStart(text: []const u8, pos: usize) usize {
    const V = @Vector(32, u8);
    const newline: V = @splat('\n');
    var end = @min(pos, text.len);
    while (end >= 32) : (end -= 32) {
        const hit = text[end - 32 ..][0..32].* == newline;
        if (@reduce(.Or, hit)) return end - 32 + (31 - @clz(@as(u32, @bitCast(hit)))) + 1;
    }
    while (end > 0) {
        end -= 1;
        if (text[end] == '\n') return end + 1;
    }
    return 0;
}

/// Whether the cursor position `pos` lies in `s`: before its end, or at the
/// very end of the text when `s` is the last segment.
pub fn holds(s: Segment, pos: usize, len: usize) bool {
    return s.start <= pos and (pos < s.next or (pos == len and s.next == len and !s.terminated()));
}

/// Start of piece `k` of the line starting at `line`: `cut` bytes apart, moved
/// back to just after a nearby space or tab, or else forward onto a character
/// boundary. It depends on nothing but the line, so any piece can be found
/// without visiting the ones before it.
fn pieceStart(text: []const u8, line: usize, k: usize, cut: usize) usize {
    if (k == 0) return line;
    const nominal = std.math.add(usize, line, std.math.mul(usize, k, cut) catch return text.len) catch return text.len;
    if (nominal >= text.len) return text.len;
    var back = nominal;
    const floor = nominal - soft(cut);
    while (back > floor) {
        back -= 1;
        if (text[back] == ' ' or text[back] == '\t') return back + 1;
    }
    var pos = nominal;
    while (pos < text.len and continuation(text[pos])) pos += 1;
    return pos;
}

/// The index of the piece starting at `start`, in a line starting at `line`.
fn pieceIndex(start: usize, line: usize, cut: usize) usize {
    return (start - line + soft(cut)) / cut;
}

fn atTerminator(text: []const u8, pos: usize) bool {
    if (pos >= text.len) return true;
    return text[pos] == '\n' or (text[pos] == '\r' and pos + 1 < text.len and text[pos + 1] == '\n');
}

/// The piece that starts at `start`, `k` pieces into the line starting at `line`.
fn piece(text: []const u8, line: usize, start: usize, k: usize, cut: usize) Segment {
    const limit = pieceStart(text, line, k + 1, cut);
    // A terminator that ends exactly at the limit still belongs to this piece,
    // so a line of exactly `cut` bytes does not grow an empty second row.
    const window = text[start..@min(text.len, limit +| 2)];
    if (std.mem.indexOfScalar(u8, window, '\n')) |rel| {
        const nl = start + rel;
        if (nl <= limit or (nl == limit + 1 and text[limit] == '\r')) {
            const end = if (nl > start and text[nl - 1] == '\r') nl - 1 else nl;
            return .{ .line = line, .start = start, .text_end = end, .next = nl + 1 };
        }
    }
    const end = @min(limit, text.len);
    return .{ .line = line, .start = start, .text_end = end, .next = end };
}

/// The segment containing byte offset `pos` (`text.len` is the end of the last line).
pub fn at(text: []const u8, pos: usize, cut: usize) Segment {
    const p = @min(pos, text.len);
    return atLine(text, p, lineStart(text, p), cut);
}

/// `at`, for a caller that already knows where `pos`'s line starts.
pub fn atLine(text: []const u8, pos: usize, line: usize, cut: usize) Segment {
    const p = @min(pos, text.len);
    var k = pieceIndex(p, line, cut);
    var start = pieceStart(text, line, k, cut);
    // A boundary after `p` means `p` is in an earlier piece. So is a position
    // at or inside a terminator that follows a full piece.
    while (k > 0 and (start > p or atTerminator(text, start))) {
        k -= 1;
        start = pieceStart(text, line, k, cut);
    }
    return piece(text, line, start, k, cut);
}

/// The segment after `s`, or null if `s` is the last.
pub fn after(text: []const u8, s: Segment, cut: usize) ?Segment {
    if (s.next >= text.len and !s.terminated()) return null;
    if (s.terminated()) return piece(text, s.next, s.next, 0, cut);
    return piece(text, s.line, s.next, pieceIndex(s.next, s.line, cut), cut);
}

/// The segment before `s`, or null if `s` is the first.
pub fn before(text: []const u8, s: Segment, cut: usize) ?Segment {
    if (s.start == 0) return null;
    if (s.start > s.line) {
        const k = pieceIndex(s.start, s.line, cut) - 1;
        return piece(text, s.line, pieceStart(text, s.line, k, cut), k, cut);
    }
    return at(text, s.start - 1, cut);
}

fn expectCovers(text: []const u8, cut: usize) !void {
    var list: std.ArrayList(Segment) = .empty;
    defer list.deinit(std.testing.allocator);
    var seg = at(text, 0, cut);
    try std.testing.expectEqual(@as(usize, 0), seg.start);
    while (true) {
        try list.append(std.testing.allocator, seg);
        seg = after(text, seg, cut) orelse break;
        try std.testing.expectEqual(list.items[list.items.len - 1].next, seg.start);
        try std.testing.expect(list.items.len <= text.len + 2);
    }
    const last = list.items[list.items.len - 1];
    try std.testing.expectEqual(text.len, last.next);
    try std.testing.expect(!last.terminated());
    for (list.items, 0..) |s, i| {
        try std.testing.expect(s.start <= s.text_end and s.text_end <= s.next);
        try std.testing.expect(s.len() <= cut + soft(cut) + 5);
        // No piece cuts a character, and none is an empty cut piece.
        if (s.start < text.len) try std.testing.expect(!continuation(text[s.start]));
        if (!s.terminated() and s.next < text.len) try std.testing.expect(s.next > s.start);
        if (i > 0) {
            const back = before(text, s, cut).?;
            try std.testing.expectEqual(list.items[i - 1], back);
        } else try std.testing.expectEqual(@as(?Segment, null), before(text, s, cut));
    }
    var i: usize = 0;
    var pos: usize = 0;
    while (pos <= text.len) : (pos += 1) {
        if (pos < text.len and continuation(text[pos])) continue;
        while (i + 1 < list.items.len and list.items[i].next <= pos) i += 1;
        const s = list.items[i];
        try std.testing.expect(s.start <= pos and (pos < s.next or pos == text.len));
        try std.testing.expectEqual(s, at(text, pos, cut));
        try std.testing.expect(holds(s, pos, text.len));
        if (i > 0) try std.testing.expect(!holds(list.items[i - 1], pos, text.len));
    }
    // The vectorized scan agrees with a plain one at every position.
    for (0..text.len + 1) |p| {
        const expected = if (std.mem.lastIndexOfScalar(u8, text[0..p], '\n')) |n| n + 1 else 0;
        try std.testing.expectEqual(expected, lineStart(text, p));
    }
}

test "segments partition any text identically in both directions" {
    try expectCovers("", 4);
    try expectCovers("\n", 4);
    try expectCovers("a", 4);
    try expectCovers("abcd", 4);
    try expectCovers("abcd\n", 4);
    try expectCovers("abcd\r\n", 4);
    try expectCovers("abcde\r\nfg\n\n\nhijklmnopq", 4);
    try expectCovers("abcdefgh\nabcdefgh\r\n", 4);
    try expectCovers("é雪👩é雪👩é雪👩é雪👩\nx", 4);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    const alphabet = [_][]const u8{ "a", "b", " ", "\n", "\r\n", "\r", "é", "雪", "👩", "\t" };
    for (0..2000) |_| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(std.testing.allocator);
        const n = random.uintLessThan(usize, 120);
        for (0..n) |_| try buf.appendSlice(std.testing.allocator, alphabet[random.uintLessThan(usize, alphabet.len)]);
        // Small cuts exercise folding hard; 16 and 40 also let a space be preferred.
        try expectCovers(buf.items, switch (random.uintLessThan(usize, 4)) {
            0 => 16,
            1 => 40,
            else => 4 + random.uintLessThan(usize, 9),
        });
    }
}

test "a huge single line folds into bounded pieces without scanning it all" {
    const a = std.testing.allocator;
    const text = try a.alloc(u8, 3 * 1024 * 1024);
    defer a.free(text);
    @memset(text, 'x');
    var seg = at(text, text.len / 2, fold);
    try std.testing.expect(seg.len() <= fold);
    try std.testing.expectEqual(@as(usize, 0), seg.line);
    var count: usize = 0;
    seg = at(text, 0, fold);
    while (after(text, seg, fold)) |n| : (seg = n) count += 1;
    try std.testing.expectEqual(text.len / fold - 1, count);
}

test "a folded paragraph breaks after a space when one is near" {
    // No word is longer than the 8 bytes looked back at this cut, so every
    // piece can end after a space.
    const text = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau " ** 3;
    var seg = at(text, 0, 64);
    var pieces: usize = 0;
    while (true) : (pieces += 1) {
        if (after(text, seg, 64)) |n| {
            try std.testing.expectEqual(@as(u8, ' '), text[seg.next - 1]);
            seg = n;
        } else break;
    }
    try std.testing.expect(pieces >= 4);
}
