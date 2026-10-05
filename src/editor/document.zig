//! Document state has no Wayland dependency. Undo records own both sides of an edit.
const std = @import("std");
const a = std.heap.c_allocator;
const pango = @import("pango.zig");
pub const limit = 16 * 1024 * 1024;
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

    pub fn deinit(d: *Document) void {
        d.text.deinit(a);
        for (d.history.items) |e| e.deinit();
        d.history.deinit(a);
    }
    pub fn init(bytes: []const u8) !Document {
        if (bytes.len > limit) return error.FileTooLarge;
        const bom = std.mem.startsWith(u8, bytes, "\xef\xbb\xbf");
        const value = bytes[if (bom) @as(usize, 3) else 0..];
        try validate(value);
        var d: Document = .{ .bom = bom, .crlf = std.mem.indexOf(u8, value, "\r\n") != null };
        try d.text.appendSlice(a, value);
        return d;
    }
    pub fn validate(value: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(value)) return error.UnsupportedEncoding;
        for (value) |b| if (b < 32 and b != '\n' and b != '\r' and b != '\t') return error.BinaryFile;
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
        const old = d.text.items.len;
        if (size > old) {
            d.text.items.len = size;
            std.mem.copyBackwards(u8, d.text.items[at + bytes.len ..], d.text.items[at + len .. old]);
        } else {
            std.mem.copyForwards(u8, d.text.items[at + bytes.len .. size], d.text.items[at + len ..]);
            d.text.items.len = size;
        }
        @memcpy(d.text.items[at..][0..bytes.len], bytes);
        d.revision +%= 1;
    }
    pub fn insert(d: *Document, bytes: []const u8) !void {
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
    pub fn undo(d: *Document, redo: bool) !void {
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
    pub fn lineStart(d: *const Document, pos: usize) usize {
        return if (std.mem.lastIndexOfScalar(u8, d.text.items[0..pos], '\n')) |n| n + 1 else 0;
    }
    pub fn lineEnd(d: *const Document, pos: usize) usize {
        const end = if (std.mem.indexOfScalarPos(u8, d.text.items, pos, '\n')) |n| n else d.text.items.len;
        return if (end > pos and d.text.items[end - 1] == '\r') end - 1 else end;
    }
    pub fn boundary(d: *const Document, right: bool, word: bool) usize {
        const pos = d.cursor;
        if (right and pos == d.text.items.len or !right and pos == 0) return pos;
        const start = d.lineStart(if (!right and pos > 0) pos - 1 else pos);
        const end = if (std.mem.indexOfScalarPos(u8, d.text.items, pos, '\n')) |n| n + 1 else d.text.items.len;
        const slice = d.text.items[start..end];
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
            if (i < count) byte += std.unicode.utf8ByteSequenceLength(d.text.items[byte]) catch 1;
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
