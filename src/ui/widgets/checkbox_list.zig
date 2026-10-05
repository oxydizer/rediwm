//! A reusable, independently checked list. The caller owns the model and
//! supplies stable IDs; rebuilding the list does not change selections.
const std = @import("std");
const layout = @import("../layout.zig");
const Widget = layout.Widget;

pub const Item = struct {
    id: usize,
    name: []const u8,
    label: []const u8,
    checked: bool,
    disabled: bool = false,
    icon: ?layout.ImageData = null,
};

/// Rows shown before the list scrolls inside its own scrollbar.
pub const max_visible_rows = 4;

pub fn build(a: std.mem.Allocator, items: []const Item, owner: ?*anyopaque, changed: *const fn (?*anyopaque, usize, bool) void, scroll: layout.ScrollState) !Widget {
    const rows = try a.alloc(Widget, items.len);
    for (items, rows) |item, *row| row.* = .{
        .name = item.name,
        .kind = .{ .checkbox = .{
            .label = item.label,
            .icon = item.icon,
            .checked = item.checked,
            .disabled = item.disabled,
            .on_change = changed,
            .owner = owner,
            .id = item.id,
        } },
        .width = .{ .percent = 1 },
        .height = .{ .fixed = 34 },
    };
    var state = scroll;
    state.chain_at_edge = true;
    return .{
        .kind = .{ .scroll_container = state },
        .direction = .column,
        .height = .{ .fixed = @floatFromInt(@as(usize, @min(@max(items.len, 1), max_visible_rows)) * 38) },
        .width = .{ .percent = 1 },
        .gap = 4,
        .children = rows,
    };
}
