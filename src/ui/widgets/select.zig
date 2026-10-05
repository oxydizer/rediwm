//! A single-choice dropdown. Geometry is shared by painting and input; menus
//! stay inside the root panel and scroll when the options exceed its height.
const std = @import("std");
const layout = @import("../layout.zig");
const Widget = layout.Widget;
pub const padding: f32 = 5;
pub fn rowHeight() f32 {
    return @max(32, @import("../theme.zig").global.font_size * 1.2 + 14);
}
pub fn popupBounds(w: *const Widget) Widget.PaintBounds {
    var root = w;
    while (root.parent) |parent| root = parent;
    const below = @max(0, root.computed_y + root.computed_height - (w.computed_y + w.computed_height) - 6);
    const above = @max(0, w.computed_y - root.computed_y - 6);
    const desired = @as(f32, @floatFromInt(w.kind.select.labels.len)) * rowHeight() + padding * 2;
    const up = below < desired and above > below;
    const available = if (up) above else below;
    const rows = @max(0, @floor((available - padding * 2) / rowHeight()));
    const h = @min(desired, rows * rowHeight() + padding * 2);
    const width = @min(w.computed_width, root.computed_width);
    return .{ .x = std.math.clamp(w.computed_x, root.computed_x, root.computed_x + root.computed_width - width), .y = if (up) w.computed_y - 6 - h else w.computed_y + w.computed_height + 6, .w = width, .h = h };
}
pub fn visibleCount(w: *const Widget) usize {
    return @intFromFloat(@max(0, @floor((popupBounds(w).h - padding * 2) / rowHeight())));
}
pub fn optionAt(w: *const Widget, x: f32, y: f32) ?usize {
    const b = popupBounds(w);
    if (x < b.x + padding or x >= b.x + b.w - padding or y < b.y + padding) return null;
    if (y >= b.y + b.h - padding) return null;
    const row: usize = @intFromFloat(@floor((y - b.y - padding) / rowHeight()));
    if (row >= visibleCount(w)) return null;
    const index = w.kind.select.first_visible + row;
    return if (index < w.kind.select.labels.len) index else null;
}
pub fn open(w: *Widget) void {
    const d = &w.kind.select;
    if (d.disabled or d.labels.len == 0 or visibleCount(w) == 0) return;
    d.open = true;
    d.highlighted = @min(d.selected orelse 0, d.labels.len - 1);
    reveal(w);
    w.markPaintDirty();
}
pub fn close(w: *Widget) void {
    if (!w.kind.select.open) return;
    w.kind.select.open = false;
    w.markPaintDirty();
}
pub fn highlight(w: *Widget, index: usize) void {
    const d = &w.kind.select;
    if (d.labels.len == 0) return;
    const next = @min(index, d.labels.len - 1);
    if (d.highlighted == next) return;
    d.highlighted = next;
    reveal(w);
    w.markPaintDirty();
}
fn reveal(w: *Widget) void {
    const d = &w.kind.select;
    const count = @max(1, visibleCount(w));
    if (d.highlighted < d.first_visible) d.first_visible = d.highlighted;
    if (d.highlighted >= d.first_visible + count) d.first_visible = d.highlighted + 1 - count;
    d.first_visible = @min(d.first_visible, d.labels.len -| count);
}
pub fn commit(w: *Widget, index: usize) void {
    const d = &w.kind.select;
    if (d.disabled or index >= d.labels.len or std.mem.indexOfScalar(usize, d.disabled_options, index) != null) return;
    const changed = d.selected == null or d.selected.? != index;
    const callback = d.on_change;
    const owner = d.owner;
    const id = d.id;
    d.selected = index;
    close(w);
    w.markPaintDirty();
    // Last operation: the callback is allowed to destroy this tree.
    if (changed) if (callback) |cb| cb(owner, id, index);
}

/// Wheel input scrolls the viewport immediately, independently of the hover.
pub fn scroll(w: *Widget, delta: f32) void {
    const d = &w.kind.select;
    const count = @max(1, visibleCount(w));
    const max_first = d.labels.len -| count;
    const first = if (delta > 0) @min(max_first, d.first_visible +| 1) else d.first_visible -| 1;
    if (delta == 0 or first == d.first_visible) return;
    d.first_visible = first;
    d.highlighted = std.math.clamp(d.highlighted, first, @min(d.labels.len, first + count) -| 1);
    w.markPaintDirty();
}
