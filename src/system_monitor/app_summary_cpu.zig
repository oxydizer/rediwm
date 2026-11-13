//! The expanded CPU card: totals and load average, one segmented tower per online
//! logical CPU, and the 60-second history when the card is wide enough.
const std = @import("std");
const tr = @import("i18n").tr;
const ui = @import("ui");
const cairo = ui.cairo;
const c = @import("../files/c.zig").api;
const App = @import("app.zig").App;
const Rect = cairo.Rect;
const summary = @import("app_summary.zig");

pub fn paint(self: *App, cr: *c.cairo_t, box: Rect) void {
    const info_w = std.math.clamp(box.w * 0.22, 190, 240);
    const text_x = box.x + 62;
    const text_w = info_w - 76;
    summary.paintBadge(cr, 0, box, false);
    summary.label(cr, tr("CPU"), .{ .x = text_x, .y = box.y + 10, .w = text_w, .h = 24 }, cairo.headingSize() * 1.25, true);
    summary.paintPercent(cr, summary.cpuPercent(self), .{ .x = text_x, .y = box.y + 34, .w = text_w, .h = 40 }, 2.6);
    var buf: [128]u8 = undefined;
    summary.label(cr, summary.cpuLine(self, &buf), .{ .x = box.x + 16, .y = box.y + 76, .w = info_w - 28, .h = 20 }, cairo.textSize(), false);
    var line = loadLine(self, &buf, true);
    if (cairo.measureText(cr, line, cairo.statusSize(), false) > info_w - 28) line = loadLine(self, &buf, false);
    summary.label(cr, line, .{ .x = box.x + 16, .y = box.y + 96, .w = info_w - 28, .h = 18 }, cairo.statusSize(), false);

    var right = box.x + box.w - summary.collapse_room;
    if (box.w >= 820) {
        const axis_w = summary.axisWidth(cr, 0, null);
        const graph_w = std.math.clamp(box.w * 0.24, 180, 300);
        const graph: Rect = .{ .x = right - axis_w - 8 - graph_w, .y = box.y + 18, .w = graph_w, .h = 84 };
        const n = if (self.model.snapshot) |s| s.cores.len else 0;
        // Keep enough room for a row of two-digit-wide meters before giving
        // space to history. Dense machines can use the entire detail area.
        if (graph.x - 28 - box.x - info_w >= @as(f32, @floatFromInt(n)) * (meterWidth(cr) + 8)) {
            summary.paintGraph(self, cr, 0, graph, false);
            right = graph.x - 28;
        }
    }
    paintCores(self, cr, .{ .x = box.x + info_w, .y = box.y + 14, .w = right - box.x - info_w, .h = box.h - 28 });
}

/// "Load 0.52 · 0.58 · 0.59 · 1234 threads", dropping what the OS lacks.
fn loadLine(self: *const App, buf: []u8, with_threads: bool) []const u8 {
    const system = (self.model.snapshot orelse return "").system;
    var used: usize = 0;
    if (system.load) |load| {
        used = (std.fmt.bufPrint(buf, "{s} {d:.2} · {d:.2} · {d:.2}", .{ tr("Load"), load[0], load[1], load[2] }) catch return "").len;
    }
    if (system.threads) |threads| if (with_threads or used == 0) {
        var count: [64]u8 = undefined;
        const text = @import("i18n").fmt(&count, @import("i18n").trn("{n} thread", "{n} threads", threads), .{ .n = threads }) catch return buf[0..used];
        used += (std.fmt.bufPrint(buf[used..], "{s}{s}", .{ if (used > 0) " · " else "", text }) catch return buf[0..used]).len;
    };
    return buf[0..used];
}

const Tier = enum { full, numbered, bars };
const Grid = struct { tier: Tier, cols: usize, cell: f32, pitch: f32 };

fn meterWidth(cr: *c.cairo_t) f32 {
    return @max(16, @as(f32, @floatCast(cairo.measureText(cr, "00", cairo.statusSize(), false))) + 2);
}

/// Prefer IDs above and percentages below each tower, then drop labels as
/// needed. CPU numbers run left to right, wrapping on many-core machines.
fn grid(n: usize, region: Rect, bar_w: f32, id_w: f32, value_w: f32, label_h: f32) Grid {
    const bar_h = @max(28, bar_w * 1.75);
    const tiers = [_]struct { tier: Tier, width: f32, height: f32 }{
        .{ .tier = .full, .width = @max(bar_w, @max(id_w, value_w)) + 6, .height = bar_h + 2 * label_h + 6 },
        .{ .tier = .numbered, .width = @max(bar_w, id_w) + 8, .height = bar_h + label_h + 6 },
        .{ .tier = .bars, .width = bar_w + 8, .height = bar_h + 6 },
    };
    for (tiers) |tier| {
        const cols = @min(n, @max(1, @as(usize, @intFromFloat(@floor(region.w / tier.width)))));
        const rows = std.math.divCeil(usize, n, cols) catch 1;
        const pitch = region.h / @as(f32, @floatFromInt(rows));
        if (pitch >= tier.height and region.w >= tier.width) return .{
            .tier = tier.tier,
            .cols = cols,
            .cell = region.w / @as(f32, @floatFromInt(cols)),
            .pitch = pitch,
        };
    }
    // Keep every CPU visible even when the towers must become narrower.
    const max_rows: usize = @max(1, @as(usize, @intFromFloat(@floor(region.h / (bar_h + 6)))));
    const cols = std.math.divCeil(usize, n, max_rows) catch 1;
    const rows = std.math.divCeil(usize, n, cols) catch 1;
    return .{ .tier = .bars, .cols = cols, .cell = region.w / @as(f32, @floatFromInt(cols)), .pitch = region.h / @as(f32, @floatFromInt(rows)) };
}

fn cellAt(g: Grid, i: usize) Rect {
    return .{ .x = @as(f32, @floatFromInt(i % g.cols)) * g.cell, .y = @as(f32, @floatFromInt(i / g.cols)) * g.pitch, .w = g.cell, .h = g.pitch };
}

fn drawTower(renderer: *ui.paint.Renderer, box: Rect, percent: ?f64) void {
    const count: usize = @intFromFloat(std.math.clamp(@floor((box.h + 2) / 6), 2, 10));
    const pitch = (box.h + 2) / @as(f32, @floatFromInt(count));
    const lit: usize = if (percent) |p| @intFromFloat(@ceil(std.math.clamp(p / 100, 0, 1) * @as(f64, @floatFromInt(count)))) else 0;
    for (0..count) |i| {
        const y = box.y + box.h - @as(f32, @floatFromInt(i + 1)) * pitch + 2;
        renderer.fillRect(box.x, y, box.w, pitch - 2, .{
            .color = if (i < lit) ui.theme.shellPalette().accent else ui.theme.global.app_divider,
            .radius = 1,
        });
    }
}

fn labelCentered(cr: *c.cairo_t, text: []const u8, box: Rect) void {
    const width: f32 = @floatCast(cairo.measureText(cr, text, cairo.statusSize(), false));
    const inset = @max(0, (box.w - width) / 2);
    summary.label(cr, text, .{ .x = box.x + inset, .y = box.y, .w = box.w - inset, .h = box.h }, cairo.statusSize(), false);
}

fn paintCores(self: *const App, cr: *c.cairo_t, region: Rect) void {
    if (region.w <= 0 or region.h <= 0) return;
    const snap = self.model.snapshot orelse return;
    const n = snap.cores.len;
    if (n == 0) {
        summary.label(cr, tr("Per-core load is unavailable"), region, cairo.textSize(), false);
        return;
    }
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, region.x, region.y, region.w, region.h);
    c.cairo_clip(cr);
    const size = cairo.statusSize();
    var buf: [16]u8 = undefined;
    const id_w: f32 = @floatCast(cairo.measureText(cr, std.fmt.bufPrint(&buf, "{d}", .{snap.cores[n - 1].id}) catch "00", size, false));
    const value_w: f32 = @floatCast(cairo.measureText(cr, "100%", size, false));
    const label_h = @max(16, size + 4);
    const g = grid(n, region, meterWidth(cr), id_w, value_w, label_h);
    const bar_w = @min(meterWidth(cr), g.cell * 0.75);
    const label_space = label_h * @as(f32, if (g.tier == .full) 2 else if (g.tier == .numbered) 1 else 0);
    // Every bar in one offscreen layer; the text goes on top afterwards.
    if (cairo.Layer.begin(cr, region)) |value| {
        var layer = value;
        for (snap.core_percent, 0..) |percent, i| {
            const at = cellAt(g, i);
            drawTower(&layer.renderer, .{ .x = at.x + (g.cell - bar_w) / 2, .y = at.y + (if (g.tier == .bars) @as(f32, 0) else label_h) + 3, .w = bar_w, .h = g.pitch - label_space - 6 }, percent);
        }
        layer.finish();
    }
    if (g.tier == .bars) return;
    for (snap.cores, snap.core_percent, 0..) |core, percent, i| {
        const at = cellAt(g, i);
        labelCentered(cr, std.fmt.bufPrint(&buf, "{d}", .{core.id}) catch "", .{ .x = region.x + at.x, .y = region.y + at.y, .w = g.cell, .h = label_h });
        if (g.tier == .full) {
            const text = if (percent) |p| std.fmt.bufPrint(&buf, "{d:.0}%", .{p}) catch "—" else "—";
            labelCentered(cr, text, .{ .x = region.x + at.x, .y = region.y + at.y + g.pitch - label_h, .w = g.cell, .h = label_h });
        }
    }
}
