// An `.arrangement`: screens drawn to scale in a recessed canvas, dragged
// into place like the display arrangement in Windows, macOS or Plasma. A drag
// slides the screen along its neighbours' edges, so a drop never leaves a gap
// or an overlap; a click selects. The model is the caller's (layout.zig's
// `ArrangementData`): this only maps it to pixels and writes positions and
// `selected` back.
const std = @import("std");
const layout = @import("../layout.zig");
const Widget = layout.Widget;
const Item = layout.ArrangementItem;
const paint_mod = @import("../paint.zig");
const Renderer = paint_mod.Renderer;
const theme = @import("../theme.zig");
const Rect = @import("field.zig").Rect;

/// Natural size; the settings page stretches the width.
pub const natural_width: f32 = 320;
pub const natural_height: f32 = 220;
/// Canvas inset from the widget's edges, before the drop margin.
const padding: f32 = 12;
/// Pointer travel before a press on a screen becomes a drag, not a click.
const drag_slop: f32 = 4;
/// Pixels within which a dragged screen aligns with a neighbour's edges or centre.
const align_snap_px: f32 = 10;
/// Space between touching screens so each reads as its own tile.
const tile_gap: f32 = 2;

/// Layout coordinates to widget-local pixels: `x * scale + offset_x`.
pub const View = struct {
    scale: f32 = 1,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

pub const Drag = struct {
    index: usize,
    /// Frozen at the press: refitting under a moving screen would scale the
    /// canvas under the pointer.
    view: View,
    press_x: f32,
    press_y: f32,
    start_x: i32,
    start_y: i32,
    moved: bool = false,
};

pub const Point = struct { x: i32, y: i32 };

/// Fits every item into a `width` × `height` widget, leaving half the
/// smallest screen free on each side so there is room to drop one there.
pub fn fitView(width: f32, height: f32, items: []const Item) View {
    if (items.len == 0) return .{};
    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    var small_w: f32 = std.math.floatMax(f32);
    var small_h: f32 = std.math.floatMax(f32);
    for (items) |item| {
        const x: f32 = @floatFromInt(item.x);
        const y: f32 = @floatFromInt(item.y);
        const w: f32 = @floatFromInt(@max(1, item.width));
        const h: f32 = @floatFromInt(@max(1, item.height));
        min_x = @min(min_x, x);
        min_y = @min(min_y, y);
        max_x = @max(max_x, x + w);
        max_y = @max(max_y, y + h);
        small_w = @min(small_w, w);
        small_h = @min(small_h, h);
    }
    const extent_w = (max_x - min_x) + small_w;
    const extent_h = (max_y - min_y) + small_h;
    const scale = @min(@max(1, width - 2 * padding) / extent_w, @max(1, height - 2 * padding) / extent_h);
    return .{
        .scale = scale,
        .offset_x = width / 2 - (min_x + max_x) / 2 * scale,
        .offset_y = height / 2 - (min_y + max_y) / 2 * scale,
    };
}

fn currentView(widget: *const Widget, data: layout.ArrangementData) View {
    if (data.drag) |drag| return drag.view;
    return fitView(widget.computed_width, widget.computed_height, data.items);
}

/// Where item `index` is drawn, in the same coordinates as `computed_x/y`.
pub fn tileRect(widget: *const Widget, index: usize) Rect {
    const data = widget.kind.arrangement;
    return tileIn(widget, currentView(widget, data), data.items[index]);
}

fn tileIn(widget: *const Widget, view: View, item: Item) Rect {
    const inset = tile_gap / 2;
    return .{
        .x = widget.computed_x + view.offset_x + @as(f32, @floatFromInt(item.x)) * view.scale + inset,
        .y = widget.computed_y + view.offset_y + @as(f32, @floatFromInt(item.y)) * view.scale + inset,
        .w = @max(1, @as(f32, @floatFromInt(item.width)) * view.scale - tile_gap),
        .h = @max(1, @as(f32, @floatFromInt(item.height)) * view.scale - tile_gap),
    };
}

fn itemAt(widget: *const Widget, view: View, x: f32, y: f32) ?usize {
    const items = widget.kind.arrangement.items;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const r = tileIn(widget, view, items[i]);
        if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) return i;
    }
    return null;
}

pub fn beginDrag(widget: *Widget, x: f32, y: f32) void {
    const data = &widget.kind.arrangement;
    data.drag = null;
    const view = fitView(widget.computed_width, widget.computed_height, data.items);
    const index = itemAt(widget, view, x, y) orelse return;
    data.drag = .{
        .index = index,
        .view = view,
        .press_x = x,
        .press_y = y,
        .start_x = data.items[index].x,
        .start_y = data.items[index].y,
    };
}

pub fn dragTo(widget: *Widget, x: f32, y: f32) void {
    const data = &widget.kind.arrangement;
    const drag = if (data.drag) |*d| d else return;
    if (!drag.moved and @abs(x - drag.press_x) < drag_slop and @abs(y - drag.press_y) < drag_slop) return;
    drag.moved = true;
    // One screen has nothing to be arranged against.
    if (data.items.len < 2) return;
    const scale = drag.view.scale;
    const want: Point = .{
        .x = drag.start_x + @as(i32, @intFromFloat(@round((x - drag.press_x) / scale))),
        .y = drag.start_y + @as(i32, @intFromFloat(@round((y - drag.press_y) / scale))),
    };
    const next = snap(data.items, drag.index, want, @intFromFloat(@round(align_snap_px / scale)));
    const item = &data.items[drag.index];
    if (item.x == next.x and item.y == next.y) return;
    item.x = next.x;
    item.y = next.y;
    widget.markDirty();
}

/// A press and release on a screen without moving selects it; a drop selects
/// the dragged screen.
pub fn endDrag(widget: *Widget) void {
    const data = &widget.kind.arrangement;
    const drag = data.drag orelse return;
    data.drag = null;
    data.selected = drag.index;
    widget.markDirty();
}

/// The position nearest `want` where item `index` shares an edge with
/// another item and overlaps none. Along that edge it slides freely but keeps
/// a quarter of the shorter side in contact; within `threshold` of the
/// neighbour's start, end or centre it aligns to it.
pub fn snap(items: []const Item, index: usize, want: Point, threshold: i32) Point {
    const moving = items[index];
    var best: ?Point = null;
    var best_distance: i64 = std.math.maxInt(i64);
    for (items, 0..) |other, i| {
        if (i == index) continue;
        const beside_y = slide(want.y, other.y, other.height, moving.height, threshold);
        const beside_x = slide(want.x, other.x, other.width, moving.width, threshold);
        const candidates = [_]Point{
            .{ .x = other.x - moving.width, .y = beside_y },
            .{ .x = other.x + other.width, .y = beside_y },
            .{ .x = beside_x, .y = other.y - moving.height },
            .{ .x = beside_x, .y = other.y + other.height },
        };
        for (candidates) |candidate| {
            if (overlapsAny(items, index, candidate)) continue;
            const dx: i64 = candidate.x - want.x;
            const dy: i64 = candidate.y - want.y;
            const distance = dx * dx + dy * dy;
            if (distance < best_distance) {
                best_distance = distance;
                best = candidate;
            }
        }
    }
    return best orelse .{ .x = moving.x, .y = moving.y };
}

/// `want` along one axis, clamped so `[want, want + len)` keeps contact with
/// `[start, start + other_len)`, then aligned when close.
fn slide(want: i32, start: i32, other_len: i32, len: i32, threshold: i32) i32 {
    const contact = @max(1, @divTrunc(@min(other_len, len), 4));
    const clamped = std.math.clamp(want, start - len + contact, start + other_len - contact);
    var value = clamped;
    var nearest = threshold + 1;
    for ([_]i32{ start, start + other_len - len, start + @divTrunc(other_len - len, 2) }) |aligned| {
        const distance: i32 = @intCast(@abs(clamped - aligned));
        if (distance < nearest) {
            nearest = distance;
            value = aligned;
        }
    }
    return value;
}

fn overlapsAny(items: []const Item, index: usize, at: Point) bool {
    const moving = items[index];
    for (items, 0..) |other, i| {
        if (i == index) continue;
        if (at.x < other.x + other.width and other.x < at.x + moving.width and
            at.y < other.y + other.height and other.y < at.y + moving.height) return true;
    }
    return false;
}

pub fn paint(widget: *const Widget, data: layout.ArrangementData, r: *Renderer) void {
    const t = r.palette orelse theme.global;
    const x = widget.computed_x;
    const y = widget.computed_y;
    const w = widget.computed_width;
    const h = widget.computed_height;
    r.fillRect(x, y, w, h, .{ .color = t.app_bg, .radius = t.radius, .border_width = 1, .border_color = t.app_item_border });
    const prev_clip = r.clip;
    defer r.clip = prev_clip;
    r.clip = paint_mod.intersectClip(prev_clip, .{ .x = x + 1, .y = y + 1, .w = @max(0, w - 2), .h = @max(0, h - 2) });
    const view = currentView(widget, data);
    // The dragged screen last, over its neighbours.
    const lifted = if (data.drag) |drag| (if (drag.moved) drag.index else null) else null;
    for (data.items, 0..) |item, i| {
        if (lifted == i) continue;
        paintTile(r, t, tileIn(widget, view, item), item, data.selected == i, false);
    }
    if (lifted) |i| paintTile(r, t, tileIn(widget, view, data.items[i]), data.items[i], true, true);
}

fn paintTile(r: *Renderer, t: theme.Theme, box: Rect, item: Item, selected: bool, lifted: bool) void {
    const radius: f32 = @min(6, @min(box.w, box.h) / 4);
    r.fillRect(box.x, box.y, box.w, box.h, .{
        .color = if (selected) t.app_item_selected else t.app_item_hover,
        .radius = radius,
        .border_width = if (selected) 2 else 1,
        .border_color = if (selected) t.accent else if (lifted) t.window_border_hover else .{ 1, 1, 1, 0.16 },
    });
    if (item.primary and box.h > 24) {
        // A menu bar along the top marks the main display.
        const inset: f32 = if (selected) 5 else 4;
        r.fillRect(box.x + inset, box.y + inset, @max(0, box.w - 2 * inset), 4, .{ .color = .{ t.fg[0], t.fg[1], t.fg[2], 0.55 }, .radius = 2 });
    }
    const text_w = @max(0, box.w - 8);
    // Step down before ellipsizing: a portrait screen's tile is narrow.
    var name_size: f32 = 13;
    for ([_]f32{ 13, 11.5, 10 }) |size| {
        name_size = size;
        if (paint_mod.labelWidth(item.label, size) <= text_w) break;
    }
    const detail_size: f32 = 11.5;
    const line_h: f32 = 18;
    const show_detail = item.detail.len > 0 and box.h >= 2 * line_h + 12 and
        paint_mod.labelWidth(item.detail, detail_size) <= text_w;
    const block_h = if (show_detail) 2 * line_h else line_h;
    const top = box.y + (box.h - block_h) / 2;
    const prev_clip = r.clip;
    defer r.clip = prev_clip;
    r.clip = paint_mod.intersectClip(prev_clip, .{ .x = box.x + 4, .y = box.y, .w = text_w, .h = box.h });
    const name_x = paint_mod.centeredTextX(box.x + 4, text_w, item.label, name_size);
    r.drawText(name_x, top, box.x + 4 + text_w - name_x, line_h, .{
        .content = item.label,
        .font_size = name_size,
        .weight = 600,
        .color = t.fg,
    });
    if (show_detail) r.drawText(paint_mod.centeredTextX(box.x, box.w, item.detail, detail_size), top + line_h, box.w, line_h, .{
        .content = item.detail,
        .font_size = detail_size,
        .color = t.dim,
    });
}

fn testItems() [2]Item {
    return .{
        .{ .x = 0, .y = 0, .width = 1920, .height = 1080, .label = "A" },
        .{ .x = 1920, .y = 0, .width = 1280, .height = 800, .label = "B" },
    };
}

test "snap keeps a dragged screen against its neighbour without overlap" {
    var items = testItems();
    // Dragged into A: pushed back out to the nearest free edge.
    const inside = snap(&items, 1, .{ .x = 1500, .y = 60 }, 50);
    try std.testing.expectEqual(Point{ .x = 1920, .y = 60 }, inside);
    // Dragged far below: lands under A, still touching it.
    const below = snap(&items, 1, .{ .x = 200, .y = 4000 }, 50);
    try std.testing.expectEqual(Point{ .x = 200, .y = 1080 }, below);
    // Dragged to the left: beside A's left edge.
    const left = snap(&items, 1, .{ .x = -2000, .y = 200 }, 50);
    try std.testing.expectEqual(Point{ .x = -1280, .y = 200 }, left);
}

test "snap aligns to a neighbour's edges and centre within the threshold" {
    var items = testItems();
    try std.testing.expectEqual(@as(i32, 0), snap(&items, 1, .{ .x = 2500, .y = 30 }, 50).y);
    // Bottom edges line up at 1080 - 800.
    try std.testing.expectEqual(@as(i32, 280), snap(&items, 1, .{ .x = 2500, .y = 300 }, 50).y);
    // Centred: (1080 - 800) / 2.
    try std.testing.expectEqual(@as(i32, 140), snap(&items, 1, .{ .x = 2500, .y = 120 }, 50).y);
    // Outside the threshold the position is kept.
    try std.testing.expectEqual(@as(i32, 210), snap(&items, 1, .{ .x = 2500, .y = 210 }, 50).y);
}

test "snap keeps a quarter of the shorter side in contact" {
    var items = testItems();
    // B can hang no further than 3/4 of its 800 px height below A's bottom.
    try std.testing.expectEqual(Point{ .x = 1920, .y = 1080 - 200 }, snap(&items, 1, .{ .x = 3000, .y = 1200 }, 0));
}

test "snap never overlaps a third screen" {
    var items = [_]Item{
        .{ .x = 0, .y = 0, .width = 1000, .height = 1000, .label = "A" },
        .{ .x = 1000, .y = 0, .width = 1000, .height = 1000, .label = "B" },
        .{ .x = 0, .y = 1000, .width = 1000, .height = 1000, .label = "C" },
    };
    // Right of A is B; the nearest free spot touching something is below B.
    const p = snap(&items, 2, .{ .x = 1000, .y = 900 }, 0);
    try std.testing.expect(!overlapsAny(&items, 2, p));
    try std.testing.expectEqual(Point{ .x = 1000, .y = 1000 }, p);
}

test "a click selects, a drag moves the screen and selects it" {
    var items = testItems();
    var widget = Widget{ .kind = .{ .arrangement = .{ .items = &items, .selected = 0 } } };
    widget.computed_width = 400;
    widget.computed_height = 200;
    const b = tileRect(&widget, 1);
    beginDrag(&widget, b.x + b.w / 2, b.y + b.h / 2);
    endDrag(&widget);
    try std.testing.expectEqual(@as(?usize, 1), widget.kind.arrangement.selected);
    try std.testing.expectEqual(@as(i32, 1920), items[1].x);

    widget.kind.arrangement.selected = 0;
    beginDrag(&widget, b.x + b.w / 2, b.y + b.h / 2);
    // Move B under A, with the view frozen while the pointer is down.
    const a = tileRect(&widget, 0);
    dragTo(&widget, a.x + a.w / 2, a.y + a.h + b.h / 2);
    try std.testing.expectEqual(@as(i32, 1080), items[1].y);
    try std.testing.expect(items[1].x >= 0 and items[1].x + items[1].width <= 1920);
    endDrag(&widget);
    try std.testing.expectEqual(@as(?usize, 1), widget.kind.arrangement.selected);
    try std.testing.expect(widget.kind.arrangement.drag == null);
}

test "fitView keeps every screen inside the widget" {
    var items = testItems();
    var widget = Widget{ .kind = .{ .arrangement = .{ .items = &items } } };
    widget.computed_width = 500;
    widget.computed_height = 220;
    for (0..items.len) |i| {
        const r = tileRect(&widget, i);
        try std.testing.expect(r.x >= padding and r.y >= padding);
        try std.testing.expect(r.x + r.w <= 500 - padding and r.y + r.h <= 220 - padding);
    }
}
