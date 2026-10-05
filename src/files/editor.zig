//! Shared UTF-8 single-line editor for paths, queries and filenames.
const std = @import("std");
const c = @import("c.zig").api;

pub const Editor = struct {
    text: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    anchor: usize = 0,
    select_all: bool = false,
    scroll: f64 = 0,

    pub fn deinit(self: *Editor, a: std.mem.Allocator) void {
        self.text.deinit(a);
    }
    pub fn selection(self: *const Editor) [2]usize {
        if (self.select_all) return .{ 0, self.text.items.len };
        return .{ @min(self.cursor, @min(self.anchor, self.text.items.len)), @max(self.cursor, @min(self.anchor, self.text.items.len)) };
    }
    pub fn normalize(self: *Editor) void {
        self.cursor = @min(self.cursor, self.text.items.len);
        self.anchor = @min(self.anchor, self.text.items.len);
        if (self.select_all) {
            self.cursor = self.text.items.len;
            self.anchor = 0;
            self.select_all = false;
        }
    }
    pub fn set(self: *Editor, a: std.mem.Allocator, value: []const u8) !void {
        try self.text.ensureTotalCapacity(a, value.len);
        self.text.clearRetainingCapacity();
        self.text.appendSliceAssumeCapacity(value);
        self.cursor = value.len;
        self.anchor = self.cursor;
        self.select_all = false;
        self.scroll = 0;
    }
    pub fn prev(text: []const u8, position: usize) usize {
        var p = position -| 1;
        while (p > 0 and text[p] & 0xc0 == 0x80) p -= 1;
        return p;
    }
    pub fn next(text: []const u8, position: usize) usize {
        var p = @min(text.len, position + 1);
        while (p < text.len and text[p] & 0xc0 == 0x80) p += 1;
        return p;
    }
    fn separator(ch: u8) bool {
        return ch == '/' or ch == ' ' or ch == '\t' or ch == '-' or ch == '_';
    }
    fn word(self: *const Editor, right: bool) usize {
        const text = self.text.items;
        var p = self.cursor;
        if (right) {
            while (p < text.len and !separator(text[p])) p = next(text, p);
            while (p < text.len and separator(text[p])) p = next(text, p);
        } else {
            while (p > 0 and separator(text[prev(text, p)])) p = prev(text, p);
            while (p > 0 and !separator(text[prev(text, p)])) p = prev(text, p);
        }
        return p;
    }
    pub fn move(self: *Editor, position: usize, extend: bool) void {
        self.normalize();
        self.cursor = @min(position, self.text.items.len);
        if (!extend) self.anchor = self.cursor;
    }
    pub fn insert(self: *Editor, a: std.mem.Allocator, bytes: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfAny(u8, bytes, "\x00\r\n") != null) return error.InvalidText;
        self.normalize();
        const sel = self.selection();
        const size = self.text.items.len - (sel[1] - sel[0]) + bytes.len;
        if (size > 16382) return error.TextTooLong;
        try self.text.ensureTotalCapacity(a, size);
        std.mem.copyForwards(u8, self.text.items[sel[0]..], self.text.items[sel[1]..]);
        self.text.shrinkRetainingCapacity(self.text.items.len - (sel[1] - sel[0]));
        try self.text.insertSlice(a, sel[0], bytes);
        self.cursor = sel[0] + bytes.len;
        self.anchor = self.cursor;
    }
    pub fn key(self: *Editor, a: std.mem.Allocator, sym: u32, utf8: []const u8, ctrl: bool, shift: bool, alt: bool) void {
        self.normalize();
        if (ctrl and (sym == c.XKB_KEY_a or sym == c.XKB_KEY_A)) {
            self.anchor = 0;
            self.cursor = self.text.items.len;
            return;
        }
        const sel = self.selection();
        if (sym == c.XKB_KEY_Left or sym == c.XKB_KEY_Right or sym == c.XKB_KEY_Home or sym == c.XKB_KEY_End) {
            const right = sym == c.XKB_KEY_Right;
            const p = if (sym == c.XKB_KEY_Home) 0 else if (sym == c.XKB_KEY_End) self.text.items.len else if (!shift and sel[0] != sel[1] and !ctrl) (if (right) sel[1] else sel[0]) else if (ctrl) self.word(right) else if (right) next(self.text.items, self.cursor) else prev(self.text.items, self.cursor);
            self.move(p, shift);
        } else if (sym == c.XKB_KEY_BackSpace or sym == c.XKB_KEY_Delete) {
            if (sel[0] == sel[1]) self.anchor = if (ctrl) self.word(sym == c.XKB_KEY_Delete) else if (sym == c.XKB_KEY_Delete) next(self.text.items, self.cursor) else prev(self.text.items, self.cursor);
            self.insert(a, "") catch {};
        } else if (!ctrl and !alt and utf8.len > 0 and utf8[0] >= 32) {
            self.insert(a, utf8) catch {};
        }
    }
};

test "UTF-8 selection, words, deletion and shortcut isolation" {
    const a = std.testing.allocator;
    var e: Editor = .{};
    defer e.deinit(a);
    try e.set(a, "/tmp/été.txt");
    e.key(a, c.XKB_KEY_Left, "", true, true, false);
    try std.testing.expectEqualStrings("été.txt", e.text.items[e.selection()[0]..e.selection()[1]]);
    try e.insert(a, "雪");
    try std.testing.expectEqualStrings("/tmp/雪", e.text.items);
    e.key(a, c.XKB_KEY_BackSpace, "", false, false, false);
    try std.testing.expectEqualStrings("/tmp/", e.text.items);
    e.key(a, c.XKB_KEY_a, "a", true, false, false);
    try e.insert(a, "αβ");
    e.key(a, c.XKB_KEY_Home, "", false, false, false);
    e.key(a, c.XKB_KEY_Right, "", false, true, false);
    try std.testing.expectEqualStrings("α", e.text.items[e.selection()[0]..e.selection()[1]]);
    e.key(a, c.XKB_KEY_c, "c", true, false, false);
    try std.testing.expectEqualStrings("αβ", e.text.items);
}
