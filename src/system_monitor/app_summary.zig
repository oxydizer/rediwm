//! CPU and RAM cards: current values beside a bounded, gap-aware history.
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const ui = @import("ui");
const cairo = ui.cairo;
const theme = ui.theme;
const c = @import("../files/c.zig").api;
const app = @import("app.zig");
const App = app.App;
const Rect = cairo.Rect;
const Position = struct { x: f64, y: f64 };

pub fn paint(self: *App, cr: *c.cairo_t) void {
    const width = (@as(f32, @floatFromInt(self.w)) - 48) / 2;
    for (0..2) |index| paintCard(self, cr, index, .{
        .x = 16 + @as(f32, @floatFromInt(index)) * (width + 16),
        .y = 14,
        .w = width,
        .h = 122,
    });
}

fn paintCard(self: *App, cr: *c.cairo_t, index: usize, box: Rect) void {
    const compact = box.w < 420;
    const info_width = std.math.clamp(box.w * 0.38, 200, 260);
    const accent = theme.shellPalette().accent;
    const snap = self.model.snapshot;
    const mem = if (snap) |s| s.memory else null;
    const percent: ?f64 = if (index == 0)
        (if (snap) |s| s.cpu_percent else null)
    else if (mem) |m|
        (if (m.total > 0) @as(f64, @floatFromInt(m.used())) * 100 / @as(f64, @floatFromInt(m.total)) else null)
    else
        null;
    if (cairo.Layer.begin(cr, box)) |value| {
        var layer = value;
        layer.renderer.fillRect(0.5, 0.5, box.w - 1, box.h - 1, .{
            .color = theme.global.app_bar,
            .radius = theme.global.radius_md,
            .border_width = 1,
            .border_color = theme.global.app_divider,
        });
        const badge: f32 = if (compact) 28 else 36;
        var tint = accent;
        tint[3] *= 0.14;
        layer.renderer.fillRect(12, 12, badge, badge, .{ .color = tint, .radius = theme.global.radius });
        layer.renderer.drawIcon(17, 17, badge - 10, badge - 10, .{ .id = if (index == 0) .cpu else .ram, .color = accent });
        layer.finish();
    }
    const text_x = box.x + (if (compact) @as(f32, 48) else 62);
    const text_w = if (compact) box.w - 166 else info_width - 76;
    label(cr, if (index == 0) tr("CPU") else tr("RAM"), .{ .x = text_x, .y = box.y + 10, .w = text_w, .h = 24 }, cairo.headingSize() * 1.25, true);
    var buf: [128]u8 = undefined;
    const percent_text = if (percent) |p| std.fmt.bufPrint(&buf, "{d:.1}%", .{p}) catch "—" else "—";
    const number_box: Rect = if (compact)
        .{ .x = box.x + box.w - 118, .y = box.y + 8, .w = 106, .h = 36 }
    else
        .{ .x = text_x, .y = box.y + (if (index == 0) @as(f32, 36) else 58), .w = text_w, .h = 40 };
    label(cr, percent_text, number_box, cairo.headingSize() * (if (compact) @as(f32, 2.2) else 2.6), true);
    const details: Rect = if (compact)
        .{ .x = box.x + 12, .y = box.y + 43, .w = box.w - 24, .h = 22 }
    else
        .{ .x = text_x, .y = box.y + (if (index == 0) @as(f32, 84) else 34), .w = text_w, .h = 24 };
    if (index == 0) {
        var count_buf: [48]u8 = undefined;
        const system = if (snap) |s| s.system else @import("proc.zig").System{};
        const count = if (system.logical_cpus) |n| i18n.fmt(&count_buf, i18n.trn("{n} CPU", "{n} CPUs", n), .{ .n = n }) catch "—" else "—";
        const text = if (system.frequency_ghz) |ghz| std.fmt.bufPrint(&buf, "{d:.1} GHz · {s}", .{ ghz, count }) catch "—" else count;
        label(cr, text, details, cairo.textSize(), false);
    } else {
        const text = if (mem) |m| app.bytesPair(&buf, m.used(), m.total) else "—";
        label(cr, text, details, cairo.textSize(), false);
        const meter: Rect = if (compact)
            .{ .x = box.x + 12, .y = box.y + 66, .w = box.w - 24, .h = 4 }
        else
            .{ .x = text_x, .y = box.y + 101, .w = text_w, .h = 8 };
        paintMeter(cr, meter, percent);
    }
    const axis_w = axisWidth(cr, index, if (mem) |m| m.total else null);
    const graph: Rect = if (compact)
        .{ .x = box.x + 12, .y = box.y + 78, .w = box.w - 32 - axis_w, .h = 32 }
    else
        .{ .x = box.x + info_width, .y = box.y + 18, .w = box.w - info_width - axis_w - 20, .h = 84 };
    paintGrid(cr, graph, index, if (mem) |m| m.total else null, compact);
    paintHistory(self, cr, index, graph);
    if (!compact) label(cr, tr("60 seconds"), .{ .x = graph.x, .y = box.y + 104, .w = graph.w, .h = 16 }, cairo.statusSize(), false);
}

fn label(cr: *c.cairo_t, text: []const u8, box: Rect, size: f32, bold: bool) void {
    app.textBox(cr, text, box, size, bold, theme.global.window_fg);
}

fn paintMeter(cr: *c.cairo_t, box: Rect, percent: ?f64) void {
    if (cairo.Layer.begin(cr, box)) |value| {
        var layer = value;
        layer.renderer.fillRect(0, 0, box.w, box.h, .{ .color = theme.global.app_divider, .radius = box.h / 2 });
        if (percent) |p| {
            const width = box.w * @as(f32, @floatCast(std.math.clamp(p / 100, 0, 1)));
            if (width > 0) layer.renderer.fillRect(0, 0, width, box.h, .{ .color = theme.shellPalette().accent, .radius = @min(width, box.h) / 2 });
        }
        layer.finish();
    }
}

fn axisLabel(buf: []u8, index: usize, total: ?u64, quarter: usize) []const u8 {
    if (index == 0) return std.fmt.bufPrint(buf, "{d}%", .{quarter * 25}) catch "—";
    const bytes = total orelse return "—";
    if (quarter == 0) return "0 B";
    // Divide before multiplying so very large capacities cannot overflow.
    return app.bytesLabel(buf, bytes / 4 * quarter + bytes % 4 * quarter / 4);
}

fn axisWidth(cr: *c.cairo_t, index: usize, total: ?u64) f32 {
    var width: f32 = 0;
    var buf: [32]u8 = undefined;
    for (0..5) |quarter| width = @max(width, @as(f32, @floatCast(cairo.measureText(cr, axisLabel(&buf, index, total, quarter), cairo.statusSize(), false))));
    return width;
}

fn paintGrid(cr: *c.cairo_t, graph: Rect, index: usize, total: ?u64, compact: bool) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_set_line_width(cr, 1);
    cairo.setSource(cr, theme.global.app_divider);
    for (0..5) |line| {
        const x = graph.x + graph.w * @as(f32, @floatFromInt(line)) / 4;
        c.cairo_move_to(cr, x, graph.y);
        c.cairo_line_to(cr, x, graph.y + graph.h);
        if (!compact or line % 2 == 0) {
            const y = graph.y + graph.h * @as(f32, @floatFromInt(line)) / 4;
            c.cairo_move_to(cr, graph.x, y);
            c.cairo_line_to(cr, graph.x + graph.w, y);
        }
    }
    c.cairo_stroke(cr);
    var buf: [32]u8 = undefined;
    for (0..5) |line| {
        if (compact and line % 2 != 0) continue;
        const y = graph.y + graph.h * @as(f32, @floatFromInt(line)) / 4;
        label(cr, axisLabel(&buf, index, total, 4 - line), .{ .x = graph.x + graph.w + 8, .y = y - 8, .w = 80, .h = 16 }, cairo.statusSize(), false);
    }
}

fn paintHistory(self: *const App, cr: *c.cairo_t, index: usize, graph: Rect) void {
    const snap = self.model.snapshot orelse return;
    var points: [60]Position = undefined;
    var count: usize = 0;
    var last: ?u64 = null;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, graph.x, graph.y - 1, graph.w, graph.h + 2);
    c.cairo_clip(cr);
    for (self.history.points[0..self.history.count]) |point| {
        const value = if (index == 0) point.cpu else point.memory;
        const age = snap.at_ns -| point.at_ns;
        if (value == null or age >= 60_000_000_000 or (last != null and point.at_ns -| last.? > 2_000_000_000)) {
            paintSegment(cr, points[0..count], graph.y + graph.h);
            count = 0;
            last = null;
        }
        if (value == null or age >= 60_000_000_000) continue;
        points[count] = .{
            .x = graph.x + graph.w * (1 - @as(f64, @floatFromInt(age)) / 60_000_000_000),
            .y = graph.y + graph.h * (1 - std.math.clamp(value.?, 0, 100) / 100),
        };
        count += 1;
        last = point.at_ns;
    }
    paintSegment(cr, points[0..count], graph.y + graph.h);
}

fn paintSegment(cr: *c.cairo_t, points: []const Position, bottom: f64) void {
    if (points.len == 0) return;
    const accent = theme.shellPalette().accent;
    if (points.len == 1) {
        cairo.setSource(cr, accent);
        c.cairo_arc(cr, points[0].x, points[0].y, 1.5, 0, 2 * std.math.pi);
        c.cairo_fill(cr);
        return;
    }
    var top = bottom;
    c.cairo_move_to(cr, points[0].x, bottom);
    for (points) |point| {
        c.cairo_line_to(cr, point.x, point.y);
        top = @min(top, point.y);
    }
    c.cairo_line_to(cr, points[points.len - 1].x, bottom);
    c.cairo_close_path(cr);
    const gradient = c.cairo_pattern_create_linear(0, top, 0, @max(top + 1, bottom));
    defer c.cairo_pattern_destroy(gradient);
    c.cairo_pattern_add_color_stop_rgba(gradient, 0, accent[0], accent[1], accent[2], accent[3] * 0.28);
    c.cairo_pattern_add_color_stop_rgba(gradient, 1, accent[0], accent[1], accent[2], accent[3] * 0.025);
    c.cairo_set_source(cr, gradient);
    c.cairo_fill(cr);
    c.cairo_move_to(cr, points[0].x, points[0].y);
    for (points[1..]) |point| c.cairo_line_to(cr, point.x, point.y);
    cairo.setSource(cr, accent);
    c.cairo_set_line_width(cr, 2);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);
    c.cairo_stroke(cr);
}
