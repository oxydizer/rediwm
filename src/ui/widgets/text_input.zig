// Editing primitives for a `.text_input` widget. `value` is heap-owned by
// the widget itself (freed/reallocated here on every edit) — the caller
// picks the allocator once at construction and passes the same one to
// every call here; the compositor's keyboard handler maps xkb keysyms onto
// these (a printable key -> `insertText`, Backspace -> `backspace`, …).
//
// Cursor blink is a timer the caller owns, not layout state — see
// layout.zig's dirty-tracking note.
const std = @import("std");
const Allocator = std.mem.Allocator;
const layout = @import("../layout.zig");
const Widget = layout.Widget;

fn prevBoundary(bytes: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and (bytes[i] & 0xc0) == 0x80) : (i -= 1) {}
    return i;
}

fn nextBoundary(bytes: []const u8, pos: usize) usize {
    if (pos >= bytes.len) return bytes.len;
    var i = pos + 1;
    while (i < bytes.len and (bytes[i] & 0xc0) == 0x80) : (i += 1) {}
    return i;
}

/// Prepares `data` for a cursor move: `extend` starts (or keeps) a selection
/// anchored where the caret was, anything else drops the selection. Called by
/// every motion below so the two behaviours stay in one place.
fn beginMove(data: *layout.TextInputData, extend: bool) void {
    if (extend) {
        if (data.selection_anchor == null) data.selection_anchor = data.cursor_pos;
    } else {
        data.selection_anchor = null;
    }
}

pub fn moveCursorLeft(widget: *Widget, extend: bool) void {
    switch (widget.kind) {
        .text_input => |*data| {
            // Plain Left with a selection collapses to its left edge rather
            // than stepping back one more character — what every editor does,
            // and the thing that makes "select, then arrow away" feel right.
            if (!extend) {
                if (data.selection()) |range| {
                    data.selection_anchor = null;
                    data.cursor_pos = range.start;
                    return;
                }
            }
            beginMove(data, extend);
            data.cursor_pos = prevBoundary(data.value, data.cursor_pos);
        },
        else => {},
    }
}

pub fn moveCursorRight(widget: *Widget, extend: bool) void {
    switch (widget.kind) {
        .text_input => |*data| {
            if (!extend) {
                if (data.selection()) |range| {
                    data.selection_anchor = null;
                    data.cursor_pos = range.end;
                    return;
                }
            }
            beginMove(data, extend);
            data.cursor_pos = nextBoundary(data.value, data.cursor_pos);
        },
        else => {},
    }
}

pub fn moveCursorHome(widget: *Widget, extend: bool) void {
    switch (widget.kind) {
        .text_input => |*data| {
            beginMove(data, extend);
            data.cursor_pos = 0;
        },
        else => {},
    }
}

pub fn moveCursorEnd(widget: *Widget, extend: bool) void {
    switch (widget.kind) {
        .text_input => |*data| {
            beginMove(data, extend);
            data.cursor_pos = data.value.len;
        },
        else => {},
    }
}

pub fn selectAll(widget: *Widget) void {
    switch (widget.kind) {
        .text_input => |*data| {
            data.selection_anchor = 0;
            data.cursor_pos = data.value.len;
        },
        else => {},
    }
}

pub fn selectNone(widget: *Widget) void {
    switch (widget.kind) {
        .text_input => |*data| data.selection_anchor = null,
        else => {},
    }
}

/// Moves the caret to `pos`, extending the selection if `extend` (a
/// shift-click or a drag) and dropping it otherwise (a plain click).
pub fn setCursor(widget: *Widget, pos: usize, extend: bool) void {
    switch (widget.kind) {
        .text_input => |*data| {
            beginMove(data, extend);
            data.cursor_pos = alignBoundary(data.value, @min(pos, data.value.len));
        },
        else => {},
    }
}

/// Selects the word around `pos` — a double-click. Falls back to selecting
/// everything when `pos` is in a run of separators, matching how a
/// double-click in whitespace behaves in most toolkits.
pub fn selectWordAt(widget: *Widget, pos: usize) void {
    switch (widget.kind) {
        .text_input => |*data| {
            const value = data.value;
            if (value.len == 0) return;
            const at = alignBoundary(value, @min(pos, value.len));
            const probe = if (at < value.len) at else prevBoundary(value, at);
            if (isWordByte(value[probe])) {
                var start = probe;
                while (start > 0 and isWordByte(value[prevBoundary(value, start)])) start = prevBoundary(value, start);
                var end = probe;
                while (end < value.len and isWordByte(value[end])) end = nextBoundary(value, end);
                data.selection_anchor = start;
                data.cursor_pos = end;
            } else {
                selectAll(widget);
            }
        },
        else => {},
    }
}

/// Continuation bytes are part of whatever their leading byte is, and every
/// non-ASCII byte counts as a word byte: a word boundary inside a script this
/// has no table for is a worse answer than treating the run as one word.
fn isWordByte(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => byte >= 0x80,
    };
}

fn alignBoundary(bytes: []const u8, pos: usize) usize {
    var i = @min(pos, bytes.len);
    while (i > 0 and i < bytes.len and (bytes[i] & 0xc0) == 0x80) : (i -= 1) {}
    return i;
}

/// Deletes the selection if there is one and reports whether it did, so
/// callers can tell "replaced a selection" from "nothing was selected".
pub fn deleteSelection(allocator: Allocator, widget: *Widget) !bool {
    switch (widget.kind) {
        .text_input => |*data| {
            const range = data.selection() orelse return false;
            try removeRange(allocator, widget, range.start, range.end);
            widget.kind.text_input.cursor_pos = range.start;
            widget.kind.text_input.selection_anchor = null;
            return true;
        },
        else => return false,
    }
}

pub fn clear(allocator: Allocator, widget: *Widget) !void {
    switch (widget.kind) {
        .text_input => |*data| {
            if (data.value.len == 0) return;
            const new_value = try allocator.alloc(u8, 0);
            allocator.free(data.value);
            data.value = new_value;
            data.cursor_pos = 0;
            data.selection_anchor = null;
            widget.markDirty();
            data.on_change(data.owner, data.id, data.value);
        },
        else => {},
    }
}

pub fn insertText(allocator: Allocator, widget: *Widget, utf8: []const u8) !void {
    if (utf8.len == 0) return;
    // Typing over a selection replaces it. Do this first so the insert below
    // sees a plain caret; it fires `on_change` twice, which every caller
    // already tolerates (each edit fires it once anyway).
    _ = try deleteSelection(allocator, widget);
    switch (widget.kind) {
        .text_input => |*data| {
            const new_value = try allocator.alloc(u8, data.value.len + utf8.len);
            @memcpy(new_value[0..data.cursor_pos], data.value[0..data.cursor_pos]);
            @memcpy(new_value[data.cursor_pos..][0..utf8.len], utf8);
            @memcpy(new_value[data.cursor_pos + utf8.len ..], data.value[data.cursor_pos..]);
            allocator.free(data.value);
            data.value = new_value;
            data.cursor_pos += utf8.len;
            widget.markDirty();
            data.on_change(data.owner, data.id, data.value);
        },
        else => {},
    }
}

pub fn backspace(allocator: Allocator, widget: *Widget) !void {
    if (try deleteSelection(allocator, widget)) return;
    switch (widget.kind) {
        .text_input => |*data| {
            if (data.cursor_pos == 0) return;
            const start = prevBoundary(data.value, data.cursor_pos);
            const end = data.cursor_pos;
            try removeRange(allocator, widget, start, end);
            widget.kind.text_input.cursor_pos = start;
        },
        else => {},
    }
}

pub fn deleteForward(allocator: Allocator, widget: *Widget) !void {
    if (try deleteSelection(allocator, widget)) return;
    switch (widget.kind) {
        .text_input => |*data| {
            if (data.cursor_pos >= data.value.len) return;
            const end = nextBoundary(data.value, data.cursor_pos);
            try removeRange(allocator, widget, data.cursor_pos, end);
        },
        else => {},
    }
}

fn removeRange(allocator: Allocator, widget: *Widget, start: usize, end: usize) !void {
    switch (widget.kind) {
        .text_input => |*data| {
            const new_value = try allocator.alloc(u8, data.value.len - (end - start));
            @memcpy(new_value[0..start], data.value[0..start]);
            @memcpy(new_value[start..], data.value[end..]);
            allocator.free(data.value);
            data.value = new_value;
            widget.markDirty();
            data.on_change(data.owner, data.id, data.value);
        },
        else => {},
    }
}

test "insertText grows the value and advances the cursor" {
    const Recorder = struct {
        var last_len: usize = 0;
        fn call(_: ?*anyopaque, _: usize, v: []const u8) void {
            last_len = v.len;
        }
    };
    var widget = Widget{ .kind = .{ .text_input = .{ .placeholder = "", .value = &.{}, .on_change = &Recorder.call } } };
    try insertText(std.testing.allocator, &widget, "hi");
    defer std.testing.allocator.free(widget.kind.text_input.value);

    try std.testing.expectEqualStrings("hi", widget.kind.text_input.value);
    try std.testing.expectEqual(@as(usize, 2), widget.kind.text_input.cursor_pos);
    try std.testing.expectEqual(@as(usize, 2), Recorder.last_len);
}

test "backspace removes the char before the cursor" {
    const Ignore = struct {
        fn call(_: ?*anyopaque, _: usize, _: []const u8) void {}
    };
    const initial = try std.testing.allocator.dupe(u8, "abc");
    var widget = Widget{ .kind = .{ .text_input = .{ .placeholder = "", .value = initial, .cursor_pos = 3, .on_change = &Ignore.call } } };

    try backspace(std.testing.allocator, &widget);
    defer std.testing.allocator.free(widget.kind.text_input.value);

    try std.testing.expectEqualStrings("ab", widget.kind.text_input.value);
    try std.testing.expectEqual(@as(usize, 2), widget.kind.text_input.cursor_pos);
}

// ---- Selection ----

const TestField = struct {
    widget: Widget,
    fn init(value: []u8) TestField {
        const Ignore = struct {
            fn call(_: ?*anyopaque, _: usize, _: []const u8) void {}
        };
        return .{ .widget = .{ .kind = .{ .text_input = .{
            .placeholder = "",
            .value = value,
            .cursor_pos = 0,
            .on_change = &Ignore.call,
        } } } };
    }
    fn data(self: *TestField) *layout.TextInputData {
        return &self.widget.kind.text_input;
    }
    fn selected(self: *TestField) []const u8 {
        return self.data().selectedText();
    }
};

test "shift extends a selection from where the caret was, plain arrows collapse it" {
    var value = "hello".*;
    var field = TestField.init(&value);
    const w = &field.widget;

    moveCursorEnd(w, false);
    try std.testing.expect(field.data().selection() == null);

    moveCursorLeft(w, true);
    moveCursorLeft(w, true);
    try std.testing.expectEqualStrings("lo", field.selected());
    // The anchor stays put while the cursor keeps moving, so shrinking the
    // selection back works too.
    moveCursorRight(w, true);
    try std.testing.expectEqualStrings("o", field.selected());

    // A plain arrow collapses to the selection's edge rather than stepping
    // one further from the cursor.
    moveCursorLeft(w, true);
    moveCursorLeft(w, true);
    try std.testing.expectEqualStrings("llo", field.selected());
    moveCursorLeft(w, false);
    try std.testing.expect(field.data().selection() == null);
    try std.testing.expectEqual(@as(usize, 2), field.data().cursor_pos);
}

test "selectAll covers the value and an anchor equal to the cursor is not a selection" {
    var value = "hello".*;
    var field = TestField.init(&value);

    selectAll(&field.widget);
    try std.testing.expectEqualStrings("hello", field.selected());

    // Collapsed, not selected: there is nothing to highlight, copy or replace.
    field.data().selection_anchor = 3;
    field.data().cursor_pos = 3;
    try std.testing.expect(field.data().selection() == null);
    try std.testing.expectEqualStrings("", field.selected());
}

test "typing and deleting replace the selection" {
    const allocator = std.testing.allocator;
    var field = TestField.init(try allocator.dupe(u8, "hello world"));
    defer allocator.free(field.data().value);
    const w = &field.widget;

    field.data().selection_anchor = 0;
    field.data().cursor_pos = 5;
    try insertText(allocator, w, "goodbye");
    try std.testing.expectEqualStrings("goodbye world", field.data().value);
    try std.testing.expectEqual(@as(usize, 7), field.data().cursor_pos);
    try std.testing.expect(field.data().selection() == null);

    // Backspace on a selection deletes the selection, not one more character
    // before it.
    field.data().selection_anchor = 7;
    field.data().cursor_pos = 13;
    try backspace(allocator, w);
    try std.testing.expectEqualStrings("goodbye", field.data().value);
    try std.testing.expectEqual(@as(usize, 7), field.data().cursor_pos);

    // With nothing selected it is an ordinary backspace again.
    try backspace(allocator, w);
    try std.testing.expectEqualStrings("goodby", field.data().value);
}

test "double click selects the word under the point, or everything in a gap" {
    var value = "alpha beta-gamma".*;
    var field = TestField.init(&value);
    const w = &field.widget;

    selectWordAt(w, 2);
    try std.testing.expectEqualStrings("alpha", field.selected());

    // '-' is a separator, so the word ends there rather than running on.
    selectWordAt(w, 7);
    try std.testing.expectEqualStrings("beta", field.selected());
    selectWordAt(w, 12);
    try std.testing.expectEqualStrings("gamma", field.selected());

    // In whitespace there is no word to take, so take the lot — what a
    // double click in a gap does in most toolkits.
    selectWordAt(w, 5);
    try std.testing.expectEqualStrings("alpha beta-gamma", field.selected());
}

test "setCursor lands on a character boundary, never inside a codepoint" {
    var value = "aé漢".*; // 1 + 2 + 3 bytes
    var field = TestField.init(&value);
    const w = &field.widget;

    // Byte 2 is the middle of 'é'; the caret belongs before it, not inside.
    setCursor(w, 2, false);
    try std.testing.expectEqual(@as(usize, 1), field.data().cursor_pos);
    setCursor(w, 3, false);
    try std.testing.expectEqual(@as(usize, 3), field.data().cursor_pos);
    setCursor(w, 99, false);
    try std.testing.expectEqual(value.len, field.data().cursor_pos);

    // A drag extends rather than replacing, so the anchor survives.
    setCursor(w, 0, false);
    setCursor(w, 3, true);
    try std.testing.expectEqualStrings("aé", field.selected());
}

test "non-ASCII runs count as one word rather than splitting on bytes" {
    var value = "hi 漢字 bye".*;
    var field = TestField.init(&value);
    selectWordAt(&field.widget, 3);
    try std.testing.expectEqualStrings("漢字", field.selected());
}
