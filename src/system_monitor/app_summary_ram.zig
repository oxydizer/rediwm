//! The expanded RAM card: used and cached memory as one composition bar, the
//! kernel's breakdown and swap, the processes holding the most resident
//! memory, and the 60-second history when the card is wide enough.
const std = @import("std");
const tr = @import("i18n").tr;
const ui = @import("ui");
const cairo = ui.cairo;
const theme = ui.theme;
const c = @import("../files/c.zig").api;
const app = @import("app.zig");
const App = app.App;
const Rect = cairo.Rect;
const collector = @import("collector.zig");
const proc = @import("proc.zig");
const summary = @import("app_summary.zig");

const details_w: f32 = 330;
const top_count = 4;

pub fn paint(self: *App, cr: *c.cairo_t, box: Rect) void {
    const snap = self.model.snapshot;
    const mem = if (snap) |s| s.memory else null;
    const info_w = std.math.clamp(box.w * 0.22, 190, 240);
    const text_x = box.x + 62;
    const text_w = info_w - 76;
    summary.paintBadge(cr, 1, box, false);
    summary.label(cr, tr("RAM"), .{ .x = text_x, .y = box.y + 10, .w = text_w, .h = 24 }, cairo.headingSize() * 1.25, true);
    summary.paintPercent(cr, summary.memoryPercent(self), .{ .x = text_x, .y = box.y + 34, .w = text_w, .h = 40 }, 2.6);
    var buf: [128]u8 = undefined;
    summary.label(cr, if (mem) |m| app.bytesPair(&buf, m.used(), m.total) else "—", .{ .x = box.x + 16, .y = box.y + 76, .w = info_w - 28, .h = 20 }, cairo.textSize(), false);
    paintComposition(cr, .{ .x = box.x + 16, .y = box.y + 101, .w = info_w - 28, .h = 8 }, mem);

    const right = box.x + box.w - summary.collapse_room;
    var x = box.x + info_w;
    paintDetails(cr, .{ .x = x, .y = box.y + 14, .w = @min(details_w, right - x), .h = box.h - 28 }, mem);
    x += details_w + 24;
    const room = right - x;
    if (room < 160) return;
    const list_w = @min(room, 210);
    paintLargest(self, cr, .{ .x = x, .y = box.y + 12, .w = list_w, .h = box.h - 24 });
    x += list_w + 28;
    const axis_w = summary.axisWidth(cr, 1, if (mem) |m| m.total else null);
    const graph_w = right - x - axis_w - 8;
    if (graph_w >= 120) summary.paintGraph(self, cr, 1, .{ .x = x, .y = box.y + 18, .w = graph_w, .h = 84 }, false);
}

fn cachedColor() [4]f32 {
    var color = theme.shellPalette().accent;
    color[3] *= 0.4;
    return color;
}

/// Used, then reclaimable cache, over the whole capacity. The cache segment
/// never runs past what is not free, so the bar always sums to the total.
fn paintComposition(cr: *c.cairo_t, box: Rect, mem: ?proc.Memory) void {
    const layer_value = cairo.Layer.begin(cr, box) orelse return;
    var layer = layer_value;
    defer layer.finish();
    layer.renderer.fillRect(0, 0, box.w, box.h, .{ .color = theme.global.app_divider, .radius = box.h / 2 });
    const m = mem orelse return;
    if (m.total == 0) return;
    const total: f32 = @floatFromInt(m.total);
    const used = @as(f32, @floatFromInt(m.used())) / total;
    const room = @as(f32, @floatFromInt(m.total -| m.used() -| (m.free orelse 0))) / total;
    const cached = @min(room, @as(f32, @floatFromInt(m.cached orelse 0)) / total);
    const end = box.w * std.math.clamp(used + cached, 0, 1);
    if (end > 0) layer.renderer.fillRect(0, 0, end, box.h, .{ .color = cachedColor(), .radius = @min(end, box.h) / 2 });
    const used_w = box.w * std.math.clamp(used, 0, 1);
    if (used_w > 0) layer.renderer.fillRect(0, 0, used_w, box.h, .{ .color = theme.shellPalette().accent, .radius = @min(used_w, box.h) / 2 });
}

/// Name over value in three columns; Used and Cached carry the bar's colours.
/// The last column is wider for swap's "used / total".
fn paintDetails(cr: *c.cairo_t, region: Rect, mem: ?proc.Memory) void {
    if (region.w <= 0) return;
    const names = [_][]const u8{ tr("Used"), tr("Cached"), tr("Swap"), tr("Available"), tr("Free"), tr("Shared") };
    const values = [_]usize{ 0, 2, 5, 1, 3, 4 };
    const unit = region.w / details_w;
    const cols = [_]f32{ 0, 100 * unit, 200 * unit, region.w };
    const row_h = region.h / 2;
    const swatch: f32 = 8;
    const pad = (row_h - 36) / 2;
    if (cairo.Layer.begin(cr, region)) |value| {
        var layer = value;
        const y = pad + 8 - swatch / 2;
        layer.renderer.fillRect(cols[0], y, swatch, swatch, .{ .color = theme.shellPalette().accent, .radius = 2 });
        layer.renderer.fillRect(cols[1], y, swatch, swatch, .{ .color = cachedColor(), .radius = 2 });
        layer.finish();
    }
    for (names, values, 0..) |name, slot, i| {
        var buf: [64]u8 = undefined;
        const x = region.x + cols[i % 3] + (if (i < 2) swatch + 6 else 0);
        const w = region.x + cols[i % 3 + 1] - x - 10;
        const y = region.y + @as(f32, @floatFromInt(i / 3)) * row_h + pad;
        summary.label(cr, name, .{ .x = x, .y = y, .w = w, .h = 16 }, cairo.statusSize(), false);
        summary.label(cr, detailValue(&buf, mem, slot), .{ .x = region.x + cols[i % 3], .y = y + 16, .w = region.x + cols[i % 3 + 1] - region.x - cols[i % 3] - 10, .h = 20 }, cairo.textSize(), true);
    }
}

fn detailValue(buf: []u8, mem: ?proc.Memory, index: usize) []const u8 {
    const m = mem orelse return "—";
    const bytes: ?u64 = switch (index) {
        0 => m.used(),
        1 => m.available,
        2 => m.cached,
        3 => m.free,
        4 => m.shared,
        else => {
            const total = m.swap_total orelse return "—";
            if (total == 0) return tr("None");
            return app.bytesPair(buf, total -| (m.swap_free orelse total), total);
        },
    };
    return if (bytes) |value| app.bytesLabel(buf, value) else "—";
}

/// Every user's processes, not just the table's filter: what to close first.
fn paintLargest(self: *const App, cr: *c.cairo_t, region: Rect) void {
    summary.label(cr, tr("Most memory"), .{ .x = region.x, .y = region.y, .w = region.w, .h = 16 }, cairo.statusSize(), false);
    const snap = self.model.snapshot orelse return;
    var top: [top_count]*const collector.Process = undefined;
    var count: usize = 0;
    for (snap.processes) |*row| {
        const bytes = row.resident_bytes orelse continue;
        var at = count;
        while (at > 0 and (top[at - 1].resident_bytes orelse 0) < bytes) at -= 1;
        if (at == top_count) continue;
        if (count < top_count) count += 1;
        var move = count - 1;
        while (move > at) : (move -= 1) top[move] = top[move - 1];
        top[at] = row;
    }
    const pitch = (region.h - 20) / @as(f32, top_count);
    for (top[0..count], 0..) |row, i| {
        var buf: [32]u8 = undefined;
        const y = region.y + 20 + @as(f32, @floatFromInt(i)) * pitch;
        const size = app.bytesLabel(&buf, row.resident_bytes.?);
        const size_w: f32 = @floatCast(cairo.measureText(cr, size, cairo.textSize(), false));
        summary.label(cr, row.name, .{ .x = region.x, .y = y, .w = region.w - size_w - 10, .h = pitch }, cairo.textSize(), false);
        summary.labelRight(cr, size, .{ .x = region.x, .y = y, .w = region.w, .h = pitch }, cairo.textSize(), false);
    }
}
