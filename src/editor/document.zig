//! Document state has no Wayland dependency. Undo records own both sides of an edit.
const std = @import("std");
const a = std.heap.c_allocator;
const pango = @import("pango.zig");
const lines = @import("lines.zig");
/// Largest document, in bytes. The text lives in one contiguous buffer.
pub const limit: usize = 4 * 1024 * 1024 * 1024;
/// A line-number waypoint is kept about this often, so locating a line scans
/// at most this much text and edits only have to adjust a short list.
const waypoint_span: usize = 1024 * 1024;
/// How far either side of the cursor character and word movement look.
const boundary_reach: usize = 2048;
const Waypoint = struct { offset: usize, line: usize };
const Edit = struct {
    at: usize,
    before: []u8,
    after: []u8,
    cursor: usize,
    anchor: usize,
    fn deinit(e: Edit) void {
        a.free(e.before);
        a.free(e.after);
    }
};
/// Which part of the text an edit left alone: the first `lo` bytes and the
/// last `suffix` bytes are the same before and after, so a position in either
/// can be mapped between the old and the new text. Edits since the last
/// `takeChange` are merged into one span.
pub const Change = struct {
    lo: usize,
    suffix: usize,
    old_len: usize,
    new_len: usize,

    /// End of the changed part of the new text.
    pub fn hi(c: Change) usize {
        return c.new_len - c.suffix;
    }
    /// The offset in the old text of the byte now at `new`, which must be at
    /// or after `hi()`.
    pub fn oldAfter(c: Change, new: usize) usize {
        return new + c.old_len - c.new_len;
    }
};
pub const Document = struct {
    text: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    anchor: usize = 0,
    history: std.ArrayList(Edit) = .empty,
    position: usize = 0,
    saved: ?usize = 0,
    history_bytes: usize = 0,
    revision: usize = 0,
    bom: bool = false,
    crlf: bool = false,
    /// Byte offset of the first line on screen. Edits keep it in step, so
    /// changing text above the view does not move what is shown.
    top: usize = 0,
    /// While a save reads the text in place, edits are refused instead of copied.
    locked: bool = false,
    waypoints: std.ArrayList(Waypoint) = .empty,
    /// Bounds of the line most recently asked about, so repeated queries in
    /// one enormous line do not each scan back to its start.
    line_memo: struct { revision: usize = std.math.maxInt(usize), start: usize = 0, end: usize = 0 } = .{},
    /// What edits changed since `takeChange`; the view uses it to glide the
    /// lines an edit moved instead of snapping them.
    change: ?Change = null,

    pub fn deinit(d: *Document) void {
        d.text.deinit(a);
        d.waypoints.deinit(a);
        for (d.history.items) |e| e.deinit();
        d.history.deinit(a);
    }
    pub fn init(bytes: []const u8) !Document {
        if (bytes.len > limit) return error.FileTooLarge;
        const bom = std.mem.startsWith(u8, bytes, "\xef\xbb\xbf");
        const value = bytes[if (bom) @as(usize, 3) else 0..];
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(a);
        try text.appendSlice(a, value);
        return adopt(text, bom);
    }
    /// Takes the already-read `text` (without its BOM) as the document. On
    /// error the caller still owns the buffer.
    pub fn adopt(text: std.ArrayList(u8), bom: bool) !Document {
        if (text.items.len > limit) return error.FileTooLarge;
        try validate(text.items);
        return .{ .text = text, .bom = bom, .crlf = hasCrlf(text.items) };
    }
    pub fn validate(value: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(value)) return error.UnsupportedEncoding;
        if (hasControl(value)) return error.BinaryFile;
    }
    /// Rejects a binary or non-UTF-8 file from its first bytes, before the rest
    /// of a huge file is read. A multi-byte character cut by the end of
    /// `prefix` is not an error.
    pub fn sniff(prefix: []const u8) !void {
        var end = prefix.len;
        while (end > 0 and prefix.len - end < 4 and !std.unicode.utf8ValidateSlice(prefix[0..end])) end -= 1;
        try validate(prefix[0..end]);
    }
    /// Any control character other than tab and line breaks.
    fn hasControl(value: []const u8) bool {
        const V = @Vector(32, u8);
        var i: usize = 0;
        while (i + 32 <= value.len) : (i += 32) {
            const v: V = value[i..][0..32].*;
            const low = v < @as(V, @splat(32));
            const allowed = (v == @as(V, @splat('\t'))) | (v == @as(V, @splat('\n'))) | (v == @as(V, @splat('\r')));
            if (@reduce(.Or, low & ~allowed)) return true;
        }
        for (value[i..]) |b| if (b < 32 and b != '\n' and b != '\r' and b != '\t') return true;
        return false;
    }
    fn hasCrlf(value: []const u8) bool {
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, value, at, '\r')) |r| : (at = r + 1) {
            if (r + 1 < value.len and value[r + 1] == '\n') return true;
        }
        return false;
    }
    pub fn modified(d: *const Document) bool {
        return d.saved == null or d.saved.? != d.position;
    }
    pub fn selection(d: *const Document) [2]usize {
        return .{ @min(d.cursor, d.anchor), @max(d.cursor, d.anchor) };
    }
    pub fn move(d: *Document, pos: usize, extend: bool) void {
        d.cursor = @min(pos, d.text.items.len);
        if (!extend) d.anchor = d.cursor;
    }
    fn replace(d: *Document, at: usize, len: usize, bytes: []const u8) !void {
        const size = d.text.items.len - len + bytes.len;
        if (size > limit) return error.FileTooLarge;
        try d.text.ensureTotalCapacity(a, size);
        d.retarget(at, len, bytes);
        d.noteChange(at, len, bytes.len);
        const old = d.text.items.len;
        if (size > old) d.text.items.len = size;
        @memmove(d.text.items[at + bytes.len .. size], d.text.items[at + len .. old]);
        if (size < old) d.text.items.len = size;
        @memcpy(d.text.items[at..][0..bytes.len], bytes);
        d.revision +%= 1;
    }
    fn noteChange(d: *Document, at: usize, len: usize, added: usize) void {
        const old = d.text.items.len;
        const tail = old - at - len;
        d.change = if (d.change) |c| .{
            .lo = @min(c.lo, at),
            .suffix = @min(c.suffix, tail),
            .old_len = c.old_len,
            .new_len = old - len + added,
        } else .{ .lo = at, .suffix = tail, .old_len = old, .new_len = old - len + added };
    }
    /// The merged span of every edit since the last call, then forgets it.
    pub fn takeChange(d: *Document) ?Change {
        defer d.change = null;
        return d.change;
    }
    /// Keeps the view anchor and line waypoints valid across replacing
    /// `len` bytes at `at` with `bytes`. Call before the text changes.
    fn retarget(d: *Document, at: usize, len: usize, bytes: []const u8) void {
        const removed = std.mem.count(u8, d.text.items[at..][0..len], "\n");
        const added = std.mem.count(u8, bytes, "\n");
        var kept: usize = 0;
        for (d.waypoints.items) |w| {
            var next = w;
            if (w.offset > at) {
                if (w.offset < at + len) continue;
                next = .{ .offset = w.offset - len + bytes.len, .line = w.line - removed + added };
            }
            d.waypoints.items[kept] = next;
            kept += 1;
        }
        d.waypoints.shrinkRetainingCapacity(kept);
        if (d.top > at) d.top = if (d.top >= at + len) d.top - len + bytes.len else at;
    }
    /// How many line breaks precede `pos`, i.e. its zero-based line number.
    pub fn linesBefore(d: *Document, pos: usize) usize {
        const text = d.text.items;
        const end = @min(pos, text.len);
        var index = std.sort.upperBound(Waypoint, d.waypoints.items, end, struct {
            fn order(key: usize, w: Waypoint) std.math.Order {
                return std.math.order(key, w.offset);
            }
        }.order);
        var offset: usize = 0;
        var line: usize = 0;
        if (index > 0) {
            offset = d.waypoints.items[index - 1].offset;
            line = d.waypoints.items[index - 1].line;
        }
        while (end - offset > waypoint_span) {
            offset += waypoint_span;
            line += std.mem.count(u8, text[offset - waypoint_span .. offset], "\n");
            // A far jump leaves a trail of waypoints, so the next one is cheap.
            d.waypoints.insert(a, index, .{ .offset = offset, .line = line }) catch continue;
            index += 1;
        }
        return line + std.mem.count(u8, text[offset..end], "\n");
    }
    pub fn insert(d: *Document, bytes: []const u8) !void {
        if (d.locked) return error.Busy;
        try validate(bytes);
        const sel = d.selection();
        if (std.mem.eql(u8, d.text.items[sel[0]..sel[1]], bytes)) {
            d.move(sel[0] + bytes.len, false);
            return;
        }
        const before = try a.dupe(u8, d.text.items[sel[0]..sel[1]]);
        errdefer a.free(before);
        const after = try a.dupe(u8, bytes);
        errdefer a.free(after);
        try d.history.ensureUnusedCapacity(a, 1);
        try d.replace(sel[0], sel[1] - sel[0], after);
        if (d.saved) |s| if (s > d.position) {
            d.saved = null;
        };
        for (d.history.items[d.position..]) |e| {
            d.history_bytes -= e.before.len + e.after.len;
            e.deinit();
        }
        d.history.shrinkRetainingCapacity(d.position);
        d.history.appendAssumeCapacity(.{ .at = sel[0], .before = before, .after = after, .cursor = d.cursor, .anchor = d.anchor });
        d.position += 1;
        d.history_bytes += before.len + after.len;
        d.move(sel[0] + bytes.len, false);
        while (d.history_bytes > 64 * 1024 * 1024 and d.history.items.len > 1) {
            const e = d.history.orderedRemove(0);
            d.history_bytes -= e.before.len + e.after.len;
            e.deinit();
            d.position -= 1;
            if (d.saved) |s| {
                d.saved = if (s == 0) null else s - 1;
            }
        }
    }
    pub const replaceAll = @import("document_search.zig").replaceAll;
    pub fn undo(d: *Document, redo: bool) !void {
        if (d.locked) return error.Busy;
        if (redo) {
            if (d.position == d.history.items.len) return;
            const e = d.history.items[d.position];
            try d.replace(e.at, e.before.len, e.after);
            d.move(e.at + e.after.len, false);
            d.position += 1;
        } else {
            if (d.position == 0) return;
            const e = d.history.items[d.position - 1];
            try d.replace(e.at, e.after.len, e.before);
            d.cursor = e.cursor;
            d.anchor = e.anchor;
            d.position -= 1;
        }
    }
    /// The display segment containing `pos` (see lines.zig).
    pub fn segmentAt(d: *Document, pos: usize) lines.Segment {
        const text = d.text.items;
        const p = @min(pos, text.len);
        const memo = &d.line_memo;
        if (memo.revision != d.revision or p < memo.start or p > memo.end) {
            memo.* = .{ .revision = d.revision, .start = lines.lineStart(text, p), .end = std.mem.indexOfScalarPos(u8, text, p, '\n') orelse text.len };
        }
        return lines.atLine(text, p, memo.start, lines.fold);
    }
    pub fn lineStart(d: *const Document, pos: usize) usize {
        return lines.lineStart(d.text.items, pos);
    }
    pub fn lineEnd(d: *const Document, pos: usize) usize {
        const end = if (std.mem.indexOfScalarPos(u8, d.text.items, pos, '\n')) |n| n else d.text.items.len;
        return if (end > pos and d.text.items[end - 1] == '\r') end - 1 else end;
    }
    /// Pango word boundaries around a hit, bounded like keyboard movement.
    /// At EOF select the preceding word; at a word start select that word.
    pub fn wordRange(d: *const Document, at: usize) [2]usize {
        const text = d.text.items;
        if (text.len == 0) return .{ 0, 0 };
        var pos = @min(at, text.len - 1);
        while (pos > 0 and text[pos] & 0xc0 == 0x80) pos -= 1;
        var probe = d.*;
        probe.cursor = pos;
        const end = probe.boundary(true, true);
        // Starting just inside this range makes the reverse lookup include
        // a boundary exactly at the hit rather than the preceding separator.
        probe.cursor = pos + (std.unicode.utf8ByteSequenceLength(text[pos]) catch 1);
        return .{ probe.boundary(false, true), end };
    }
    pub fn boundary(d: *const Document, right: bool, word: bool) usize {
        const pos = d.cursor;
        const text = d.text.items;
        if (right and pos == text.len or !right and pos == 0) return pos;
        // Only the text near the cursor is analysed, so moving along a single
        // enormous line costs the same as along a short one.
        const from = if (!right and pos > 0) pos - 1 else pos;
        const floor = from -| boundary_reach;
        var start = if (std.mem.lastIndexOfScalar(u8, text[floor..from], '\n')) |n| floor + n + 1 else floor;
        while (start < pos and text[start] & 0xc0 == 0x80) start += 1;
        var end = if (std.mem.indexOfScalarPos(u8, text[0..@min(text.len, pos +| boundary_reach)], pos, '\n')) |n| n + 1 else @min(text.len, pos +| boundary_reach);
        while (end > pos and end < text.len and text[end] & 0xc0 == 0x80) end -= 1;
        const slice = text[start..end];
        const count = std.unicode.utf8CountCodepoints(slice) catch return pos;
        const attrs = a.alloc(u32, count + 1) catch return pos;
        defer a.free(attrs);
        pango.pango_get_log_attrs(slice.ptr, @intCast(slice.len), -1, null, attrs.ptr, @intCast(attrs.len));
        var byte = start;
        var previous = start;
        const mask: u32 = if (word) 1 << 12 else 1 << 4;
        for (attrs, 0..) |attr, i| {
            if (attr & mask != 0) {
                if (right and byte > pos) return byte;
                if (!right and byte >= pos) return previous;
                previous = byte;
            }
            if (i < count) byte += std.unicode.utf8ByteSequenceLength(text[byte]) catch 1;
        }
        return if (right) end else previous;
    }
};

test "selection, undo saved point, branching and CRLF remain lossless" {
    var d = try Document.init("\xef\xbb\xbfhello\r\nworld\n");
    defer d.deinit();
    try std.testing.expect(d.bom and d.crlf and !d.modified());
    d.move(5, false);
    try d.insert("!");
    try std.testing.expect(d.modified());
    try d.undo(false);
    try std.testing.expect(!d.modified());
    try d.undo(true);
    d.saved = d.position;
    try d.undo(false);
    try d.insert("?");
    try std.testing.expect(d.modified());
    try std.testing.expectEqualStrings("hello?\r\nworld\n", d.text.items);
    d.move(0, false);
    d.move(d.text.items.len, true);
    try d.insert("雪");
    try d.undo(false);
    try std.testing.expectEqualStrings("hello?\r\nworld\n", d.text.items);
}
test "cursor treats combining characters, emoji and CRLF as clusters" {
    var d = try Document.init("e\xcc\x81👩‍💻\r\nx");
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 3), d.boundary(true, false));
    d.move(3, false);
    const end = d.boundary(true, false);
    try std.testing.expectEqual(@as(usize, 14), end);
    d.move(end, false);
    try std.testing.expectEqual(@as(usize, 16), d.boundary(true, false));
    d.move(16, false);
    try std.testing.expectEqual(end, d.boundary(false, false));
    try std.testing.expectError(error.BinaryFile, Document.init("abc\x00"));
    try std.testing.expectError(error.UnsupportedEncoding, Document.init("\xff"));
}

fn naiveLines(text: []const u8, pos: usize) usize {
    return std.mem.count(u8, text[0..pos], "\n");
}

test "line numbers and the view anchor survive edits across waypoints" {
    const gpa = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);
    var i: usize = 0;
    while (source.items.len < 3 * waypoint_span + 1000) : (i += 1) try source.print(gpa, "line {d} of the document\n", .{i});
    var d = try Document.init(source.items);
    defer d.deinit();
    const len = d.text.items.len;
    // A far query leaves waypoints behind, and they agree with a plain count.
    try std.testing.expectEqual(naiveLines(d.text.items, len), d.linesBefore(len));
    try std.testing.expect(d.waypoints.items.len >= 2);
    for ([_]usize{ 0, 17, waypoint_span - 1, waypoint_span, waypoint_span + 5, 2 * waypoint_span + 99, len }) |pos| {
        try std.testing.expectEqual(naiveLines(d.text.items, pos), d.linesBefore(pos));
    }
    d.top = 2 * waypoint_span;
    // Inserting lines before the view moves the anchor by the inserted bytes.
    d.move(100, false);
    try d.insert("a\nb\nc\n");
    try std.testing.expectEqual(2 * waypoint_span + 6, d.top);
    // Replacing text that spans the anchor pulls it back to the edit.
    d.move(d.top - 50, false);
    d.move(d.top + 50, true);
    try d.insert("x");
    try std.testing.expectEqual(2 * waypoint_span + 6 - 50, d.top);
    // After every edit the waypoints still describe the new text.
    d.move(waypoint_span + 3, false);
    d.move(waypoint_span + 3000, true);
    try d.insert("replaced\nwith\nthree lines\n");
    try d.undo(false);
    try d.undo(false);
    try d.undo(false);
    const total = d.text.items.len;
    for ([_]usize{ 0, 100, waypoint_span, waypoint_span + 3000, 2 * waypoint_span, 3 * waypoint_span, total }) |pos| {
        try std.testing.expectEqual(naiveLines(d.text.items, pos), d.linesBefore(pos));
    }
    try std.testing.expectEqualStrings(source.items, d.text.items);
}

test "edits since the last look merge into one span of what they left alone" {
    var d = try Document.init("0123456789");
    defer d.deinit();
    try std.testing.expectEqual(@as(?Change, null), d.takeChange());
    d.move(4, false);
    try d.insert("ab");
    const one = d.takeChange().?;
    try std.testing.expectEqual(Change{ .lo = 4, .suffix = 6, .old_len = 10, .new_len = 12 }, one);
    // The "4" that followed the edit was at 4 and is now at 6.
    try std.testing.expectEqual(@as(usize, 6), one.hi());
    try std.testing.expectEqual(@as(usize, 4), one.oldAfter(6));
    try std.testing.expectEqual(@as(?Change, null), d.takeChange());
    // Two edits, the second before and shorter: one span covering both.
    try d.insert("c");
    d.move(1, false);
    d.anchor = 2;
    try d.insert("");
    try d.insert("xyz");
    const two = d.takeChange().?;
    try std.testing.expectEqual(@as(usize, 1), two.lo);
    try std.testing.expectEqual(@as(usize, 6), two.suffix);
    try std.testing.expectEqual(@as(usize, 12), two.old_len);
    try std.testing.expectEqual(d.text.items.len, two.new_len);
    // Undo is an edit too.
    try d.undo(false);
    try std.testing.expect(d.takeChange() != null);
}

test "a binary or non-UTF-8 file is refused from its first bytes" {
    try Document.sniff("plain text, even cut mid-character: \xc3");
    try Document.sniff("日本語".*[0..4]);
    try std.testing.expectError(error.BinaryFile, Document.sniff("ok\x00binary"));
    try std.testing.expectError(error.UnsupportedEncoding, Document.sniff("bad \xff byte"));
}

test "documents refuse edits while a save reads them in place" {
    var d = try Document.init("abc");
    defer d.deinit();
    d.locked = true;
    try std.testing.expectError(error.Busy, d.insert("x"));
    try std.testing.expectError(error.Busy, d.undo(false));
    d.locked = false;
    try d.insert("x");
    try std.testing.expectEqualStrings("xabc", d.text.items);
}

test "moving by character or word inside an enormous line looks only nearby" {
    const gpa = std.testing.allocator;
    const line = try gpa.alloc(u8, 4 * 1024 * 1024);
    defer gpa.free(line);
    for (line, 0..) |*b, n| b.* = if (n % 8 == 7) ' ' else 'a';
    var d = try Document.init(line);
    defer d.deinit();
    d.move(2 * 1024 * 1024 + 3, false);
    try std.testing.expectEqual(d.cursor + 1, d.boundary(true, false));
    try std.testing.expectEqual(d.cursor - 1, d.boundary(false, false));
    // The next word boundary is found without scanning the line.
    const word = d.boundary(true, true);
    try std.testing.expect(word > d.cursor and word - d.cursor < 16);
}

test "double-click word ranges include Unicode and exclude neighbouring words" {
    var d = try Document.init("hello café, snow 雪!\r\n");
    defer d.deinit();
    for ([_]usize{ 0, 2, 4 }) |pos| try std.testing.expectEqualStrings("hello", d.text.items[d.wordRange(pos)[0]..d.wordRange(pos)[1]]);
    for ([_]usize{ 6, 8, 10 }) |pos| try std.testing.expectEqualStrings("café", d.text.items[d.wordRange(pos)[0]..d.wordRange(pos)[1]]);
    const snow = d.wordRange(18);
    try std.testing.expectEqualStrings("雪", d.text.items[snow[0]..snow[1]]);
    const punctuation = d.wordRange(11);
    try std.testing.expectEqualStrings(",", d.text.items[punctuation[0]..punctuation[1]]);
    var empty: Document = .{};
    try std.testing.expectEqual([2]usize{ 0, 0 }, empty.wordRange(0));
    var eof = try Document.init("last");
    defer eof.deinit();
    try std.testing.expectEqual([2]usize{ 0, 4 }, eof.wordRange(4));
}
