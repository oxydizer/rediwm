//! Dispatcher key handling: focus traversal, activation and text editing keys.

const std = @import("std");
const Allocator = std.mem.Allocator;
const anim = @import("anim.zig");
const fold = @import("fold.zig");
const Widget = @import("layout.zig").Widget;
const text_input_widget = @import("widgets/text_input.zig");
const select_widget = @import("widgets/select.zig");
const input_mod = @import("input.zig");
const Dispatcher = input_mod.Dispatcher;
const Key = input_mod.Key;
const Mods = input_mod.Mods;
const KeyOutcome = input_mod.KeyOutcome;

const type_select_timeout_ms: i64 = 1000;

fn sameFolded(a: []const u8, b: []const u8) bool {
    return fold.eql(a, b, .{ .turkish = @import("i18n").isTurkish() });
}

fn typeSelect(self: *Dispatcher, widget: *Widget, chars: []const u8) void {
    const state = &self.type_select;
    const now = anim.nowMs();
    const options: fold.Options = .{ .turkish = @import("i18n").isTurkish() };
    const expired = state.len == 0 or now - state.last_ms > type_select_timeout_ms;
    const data = widget.kind.select;

    // Repeating one character cycles through choices with that prefix.
    if (!expired and state.len == chars.len and sameFolded(state.buffer[0..state.len], chars)) {
        state.last_ms = now;
        for (0..data.labels.len) |offset| {
            const index = (data.highlighted + 1 + offset) % data.labels.len;
            if (std.mem.indexOfScalar(usize, data.disabled_options, index) != null) continue;
            if (fold.startsWith(data.labels[index], chars, options)) {
                select_widget.highlight(widget, index);
                return;
            }
        }
        return;
    }

    if (expired or chars.len > state.buffer.len - state.len) state.len = 0;
    if (chars.len > state.buffer.len) return;
    @memcpy(state.buffer[state.len..][0..chars.len], chars);
    state.len += chars.len;
    state.last_ms = now;

    const prefix = state.buffer[0..state.len];
    var found: ?usize = null;
    for (data.labels, 0..) |label, index| {
        if (std.mem.indexOfScalar(usize, data.disabled_options, index) != null) continue;
        if (fold.startsWith(label, prefix, options)) {
            found = index;
            break;
        }
    }

    // If the accumulated prefix has no match, treat this key as a fresh query.
    if (found == null and state.len > chars.len) {
        @memcpy(state.buffer[0..chars.len], chars);
        state.len = chars.len;
        for (data.labels, 0..) |label, index| {
            if (std.mem.indexOfScalar(usize, data.disabled_options, index) != null) continue;
            if (fold.startsWith(label, chars, options)) {
                found = index;
                break;
            }
        }
    }
    if (found) |index| select_widget.highlight(widget, index);
}

test "dropdown type-ahead accumulates multiple characters" {
    var dispatcher: Dispatcher = .{};
    var widget: Widget = .{ .kind = .{ .select = .{
        .labels = &.{ "Russian", "Croatian", "Czech" },
    } } };
    typeSelect(&dispatcher, &widget, "C");
    typeSelect(&dispatcher, &widget, "R");
    typeSelect(&dispatcher, &widget, "O");
    try std.testing.expectEqual(@as(usize, 1), widget.kind.select.highlighted);
}

pub fn keyEvent(self: *Dispatcher, allocator: Allocator, key: Key, mods: Mods) !KeyOutcome {
    const widget = self.focused orelse return .{};
    if (widget.kind == .select) {
        if (widget.kind.select.disabled) return .{};
        switch (key) {
            .escape, .tab => select_widget.close(widget),
            .enter => if (widget.kind.select.open) {
                select_widget.commit(widget, widget.kind.select.highlighted);
            } else {
                select_widget.open(widget);
            },
            .char => |chars| {
                if (std.mem.eql(u8, chars, " ")) {
                    if (widget.kind.select.open) select_widget.commit(widget, widget.kind.select.highlighted) else select_widget.open(widget);
                } else if (chars.len > 0) {
                    if (!widget.kind.select.open) select_widget.open(widget);
                    typeSelect(self, widget, chars);
                }
            },
            .up, .down, .home, .end, .page_up, .page_down => {
                if (!widget.kind.select.open) {
                    select_widget.open(widget);
                    return .{};
                }
                const d = widget.kind.select;
                const next = switch (key) {
                    .up => d.highlighted -| 1,
                    .down => d.highlighted +| 1,
                    .home => 0,
                    .end => d.labels.len -| 1,
                    .page_up => d.highlighted -| select_widget.visibleCount(widget),
                    else => d.highlighted +| select_widget.visibleCount(widget),
                };
                select_widget.highlight(widget, next);
            },
            else => {},
        }
        return .{};
    }
    if (widget.kind == .secret_input) {
        const input = widget.kind.secret_input.input;
        self.caret.noteEdit(anim.nowMs());
        switch (key) {
            .char => |utf8| _ = input.insert(utf8),
            .backspace => input.backspace(),
            .delete => input.delete(),
            .left => input.left(),
            .right => input.right(),
            .home => input.cursor = 0,
            .end, .select_all => input.cursor = input.len,
            // Secret values never use the clipboard.
            .copy, .cut, .paste => return .{},
            .enter, .up, .down, .page_up, .page_down, .tab, .escape => return .{},
        }
        widget.markDirty();
        return .{};
    }
    if (std.meta.activeTag(widget.kind) != .text_input) return .{};
    // Before the edit: `insertText` and friends call `on_change`, which is
    // what rebuilds the start menu's tree, and the rebuild must already
    // see the caret held solid.
    const now = anim.nowMs();
    switch (key) {
        // These land somewhere unrelated to where the caret was, so they
        // snap rather than sweeping the width of the field.
        .home, .end, .select_all => self.caret.noteJump(now),
        .char, .paste => self.caret.noteInsert(now),
        .backspace, .delete, .left, .right, .cut => self.caret.noteEdit(now),
        .copy, .enter, .up, .down, .page_up, .page_down, .tab, .escape => {},
    }
    switch (key) {
        .char => |utf8| try text_input_widget.insertText(allocator, widget, utf8),
        .paste => |utf8| try text_input_widget.insertText(allocator, widget, utf8),
        .backspace => try text_input_widget.backspace(allocator, widget),
        .delete => try text_input_widget.deleteForward(allocator, widget),
        .left => text_input_widget.moveCursorLeft(widget, mods.shift),
        .right => text_input_widget.moveCursorRight(widget, mods.shift),
        .home => text_input_widget.moveCursorHome(widget, mods.shift),
        .end => text_input_widget.moveCursorEnd(widget, mods.shift),
        .select_all => text_input_widget.selectAll(widget),
        // Null, not an empty slice: Ctrl+C or Ctrl+X with nothing selected
        // must leave the clipboard alone rather than blanking it, and that
        // is easier to get right here than at every caller.
        .copy => {
            const selected = widget.kind.text_input.selectedText();
            if (selected.len == 0) return .{};
            return .{ .copy = try allocator.dupe(u8, selected) };
        },
        .cut => {
            // Duplicated before the delete, which frees the buffer the
            // selection points into.
            const selected = widget.kind.text_input.selectedText();
            if (selected.len == 0) return .{};
            const owned = try allocator.dupe(u8, selected);
            errdefer allocator.free(owned);
            _ = try text_input_widget.deleteSelection(allocator, widget);
            return .{ .copy = owned };
        },
        .enter, .up, .down, .page_up, .page_down, .tab, .escape => {},
    }
    return .{};
}
