//! Shared context-menu appearance for Files, Editor and the desktop.
const std = @import("std");
const c = @cImport(@cInclude("cairo.h"));
const ui = @import("cairo.zig");
const theme = @import("theme.zig");
const IconId = @import("layout.zig").IconId;

pub const width = 216;
pub const row_height = 32;
pub const padding = 6;
pub const separator_space = 7;
pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    pub fn contains(r: Rect, x: f64, y: f64) bool {
        return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
    }
};

fn rounded(cr: *c.cairo_t, r: Rect, radius: f64) void {
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, r.x + r.w - radius, r.y + radius, radius, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, r.x + r.w - radius, r.y + r.h - radius, radius, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, r.x + radius, r.y + r.h - radius, radius, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, r.x + radius, r.y + radius, radius, std.math.pi, 3 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
}

pub fn frame(cr_any: *anyopaque, box: Rect, context: bool) void {
    const cr: *c.cairo_t = @ptrCast(cr_any);
    const radius: f64 = if (context) 12 else 7;
    var shadow = theme.global.shadow;
    shadow[3] *= 0.16;
    for (0..6) |step| {
        const spread: f64 = @floatFromInt(step);
        rounded(cr, .{ .x = box.x - spread, .y = box.y + 3 - spread, .w = box.w + 2 * spread, .h = box.h + 2 * spread }, radius + spread);
        ui.setSource(cr, shadow);
        c.cairo_fill(cr);
    }
    rounded(cr, box, radius);
    ui.setSource(cr, theme.global.app_toolbar);
    c.cairo_fill_preserve(cr);
    ui.setSource(cr, theme.global.app_item_border);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
}

pub const Row = struct {
    label: []const u8,
    hint: ?[]const u8 = null,
    icon: ?IconId = null,
    selected: bool = false,
    separator: bool = false,
};

pub fn row(cr_any: *anyopaque, box: Rect, opts: Row, context: bool) void {
    const cr: *c.cairo_t = @ptrCast(cr_any);
    if (opts.separator) {
        ui.setSource(cr, theme.global.app_divider);
        c.cairo_set_line_width(cr, 1);
        c.cairo_move_to(cr, box.x + 6, box.y - 3.5);
        c.cairo_line_to(cr, box.x + box.w - 6, box.y - 3.5);
        c.cairo_stroke(cr);
    }
    if (opts.selected) {
        rounded(cr, box, if (context) 7 else 4);
        ui.setSource(cr, if (context) theme.global.app_item_hover else theme.global.app_nav_selected);
        c.cairo_fill(cr);
    }
    if (opts.icon) |id| {
        const size: f32 = if (context) 16 else 14;
        if (ui.Layer.begin(cr, .{ .x = @floatCast(box.x + (if (context) @as(f64, 10) else 4)), .y = @floatCast(box.y + (box.h - size) / 2), .w = size, .h = size })) |l| {
            var layer = l;
            layer.renderer.drawIcon(0, 0, size, size, .{ .id = id, .color = theme.global.window_fg });
            layer.finish();
        }
    }
    const metrics = ui.fontMetrics(cr, ui.textSize());
    ui.setSource(cr, theme.global.window_fg);
    ui.drawText(cr, opts.label, box.x + (if (context) @as(f64, 36) else 24), box.y + (box.h + metrics.ascent - metrics.descent) / 2, ui.textSize(), false);
    if (opts.hint) |hint| {
        const hint_metrics = ui.fontMetrics(cr, ui.statusSize());
        var ink = theme.global.window_fg;
        ink[3] *= 0.4;
        ui.setSource(cr, ink);
        ui.drawText(cr, hint, box.x + box.w - 12 - ui.measureText(cr, hint, ui.statusSize(), false), box.y + (box.h + hint_metrics.ascent - hint_metrics.descent) / 2, ui.statusSize(), false);
    }
}
