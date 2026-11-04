//! The cursor and rendering the window.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const c = @import("../files/c.zig").api;
const shell_ui = @import("ui").cairo;
const ui_button = @import("ui").widgets.button;
const scrollbar = @import("ui").widgets.scrollbar;
const ui_theme = @import("ui").theme;
const app_mod = @import("app.zig");
const App = app_mod.App;
const Action = app_mod.Action;
const labels = app_mod.labels;
const clippedText = app_mod.clippedText;
const rounded = app_mod.rounded;
const paintImage = app_mod.paintImage;
const checker = app_mod.checker;
const glyph = app_mod.glyph;
const shellRect = app_mod.shellRect;
const setSource = app_mod.setSource;
const drawText = app_mod.drawText;
const measureText = app_mod.measureText;

pub fn cursorName(self: *const App) [*:0]const u8 {
    if (self.operation != null) return "wait";
    if (self.dialog == .save and self.filenameRect().contains(self.px, self.py)) return "text";
    if (self.dialog != .none) return "default";
    if (self.crop_mode and self.canvas().contains(self.px, self.py)) return "crosshair";
    if (self.dragging or self.strip_drag.active) return "grabbing";
    if (self.canvas().contains(self.px, self.py) and !self.view.fitting) return "grab";
    return "default";
}

pub fn render(self: *App, cr: *c.cairo_t) void {
    const t = ui_theme.global;
    setSource(cr, t.app_toolbar);
    c.cairo_paint(cr);
    for (std.meta.tags(Action)) |act| {
        const r = self.buttonRect(act);
        const label = if (act == .crop and self.crop_mode) tr("Apply crop") else labels[@intFromEnum(act)].get();
        const opts: ui_button.Options = if (act == .crop and self.crop_mode)
            .{ .variant = .primary, .label = tr("Apply") }
        else if (self.w >= 1400)
            .{ .variant = .ghost, .leading_icon = glyph(act), .label = label }
        else if (act == .fit or act == .actual)
            .{ .variant = .ghost, .label = label }
        else
            .{ .variant = .ghost, .icon = glyph(act), .label = label };
        const proximity = self.buttonProximity(act, self.px, self.py);
        var layer = shell_ui.Layer.beginVisible(cr, shellRect(r)) orelse continue;
        ui_button.paint(&layer.renderer, layer.local(), opts, .{
            .pointer = if (!self.enabled(act) or self.operation != null) .disabled else if (self.hover == act) .hover else .idle,
            .proximity_distance = proximity.distance,
            .proximity_x = proximity.x,
            .proximity_y = proximity.y,
        });
        layer.finish();
    }
    const hint = if (self.operation) |op| (if (op.kind == .save) tr("Saving image…") else tr("Moving to Trash…")) else if (self.hover) |act| (if (act == .crop and self.crop_mode) tr("Apply crop · Enter") else labels[@intFromEnum(act)].get()) else if (self.notice_len > 0) self.notice[0..self.notice_len] else if (self.crop_mode) tr("Drag to select · Enter: crop · Esc: cancel") else if (self.modified) tr("Unsaved edits · Ctrl+S: save · Ctrl+Z: undo") else tr("C: crop · Ctrl+S: save · Delete: trash");
    setSource(cr, t.window_fg);
    clippedText(cr, hint, .{ .x = 16, .y = self.toolbarBottom() + 2, .w = @floatFromInt(self.w - 32), .h = 22 }, shell_ui.statusSize(), false);
    const box = self.canvas();
    // A partial repaint (glow, hover) often leaves the canvas out entirely.
    if (shell_ui.clipTouches(cr, shellRect(box))) {
        c.cairo_save(cr);
        rounded(cr, box, 8);
        c.cairo_clip(cr);
        setSource(cr, t.app_bg);
        c.cairo_paint(cr);
        if (self.image) |im| {
            const z = self.view.scale(box, @floatFromInt(im.w), @floatFromInt(im.h));
            const dims = self.view.dimensions(@floatFromInt(im.w), @floatFromInt(im.h));
            const cx = box.x + box.w / 2 + self.view.pan_x;
            const cy = box.y + box.h / 2 + self.view.pan_y;
            c.cairo_save(cr);
            c.cairo_rectangle(cr, cx - dims[0] * z / 2, cy - dims[1] * z / 2, dims[0] * z, dims[1] * z);
            c.cairo_clip(cr);
            checker(cr, box);
            c.cairo_restore(cr);
            c.cairo_translate(cr, cx, cy);
            c.cairo_rotate(cr, @as(f64, @floatFromInt(self.view.rotation)) * std.math.pi / 2.0);
            paintImage(cr, im, .{ .x = -@as(f64, @floatFromInt(im.w)) * z / 2, .y = -@as(f64, @floatFromInt(im.h)) * z / 2, .w = @as(f64, @floatFromInt(im.w)) * z, .h = @as(f64, @floatFromInt(im.h)) * z });
        } else {
            const msg = self.error_message orelse tr("Loading image…");
            setSource(cr, t.window_fg);
            drawText(cr, msg, box.x + @max(12, (box.w - measureText(cr, msg, shell_ui.textSize(), false)) / 2), box.y + box.h / 2, shell_ui.textSize(), false);
        }
        c.cairo_restore(cr);
    }
    if (self.crop_mode) self.drawCrop(cr);
    for (0..self.thumbCount()) |slot| {
        const r = self.thumbRect(slot);
        // Cards outside a partial repaint's clip, border stroke included.
        if (!shell_ui.clipTouches(cr, shellRect(.{ .x = r.x - 2, .y = r.y - 2, .w = r.w + 4, .h = r.h + 4 }))) continue;
        const idx = self.indexAt(self.thumbStart() + slot);
        c.cairo_save(cr);
        rounded(cr, r, 7);
        c.cairo_clip(cr);
        setSource(cr, t.app_item);
        c.cairo_paint(cr);
        if (self.cached(idx)) {
            if (self.thumbImage(idx)) |im| {
                const z = @min((r.w - 8) / @as(f64, @floatFromInt(im.w)), (r.h - 8) / @as(f64, @floatFromInt(im.h)));
                const iw = @as(f64, @floatFromInt(im.w)) * z;
                const ih = @as(f64, @floatFromInt(im.h)) * z;
                paintImage(cr, im, .{ .x = r.x + (r.w - iw) / 2, .y = r.y + (r.h - ih) / 2, .w = iw, .h = ih });
            } else {
                setSource(cr, t.window_fg);
                drawText(cr, "?", r.x + r.w / 2 - 4, r.y + r.h / 2 + 5, 16, false);
            }
        }
        c.cairo_restore(cr);
        // Keep the glow outside the card's rounded image clip, but inside the
        // visible filmstrip viewport.
        shell_ui.drawProximityGlow(
            cr,
            shellRect(r),
            7,
            .{ .x = self.px, .y = self.py },
            .{ .x = 16, .y = @floatCast(@as(f64, @floatFromInt(self.h - 32)) - self.thumbHeight()), .w = @floatFromInt(self.w - 32), .h = @floatCast(self.thumbHeight() + 8.0) },
        );
        rounded(cr, r, 7);
        c.cairo_set_line_width(cr, 1);
        setSource(cr, t.app_item_border);
        c.cairo_stroke(cr);
    }
    const highlight = self.selection_glide.frame;
    if (highlight.alpha > 0 and self.count() > 0) {
        var r = self.thumbRect(0);
        r.x += @as(f64, highlight.col) * (r.w + 12);
        rounded(cr, r, 7);
        c.cairo_set_line_width(cr, 3);
        var color = ui_theme.shellPalette().accent;
        color[3] *= highlight.alpha;
        setSource(cr, color);
        c.cairo_stroke(cr);
    }
    if (self.stripBar()) |bar| shell_ui.drawScrollbarAt(cr, scrollbar.look(bar, self.strip_appearance, ui_theme.global.scrollbar_width, ui_theme.shellPalette()), .{ .x = self.px, .y = self.py });
    var status: [160]u8 = undefined;
    const text = if (self.image) |im| std.fmt.bufPrint(&status, "{d} × {d}   ·   {d:.0}%   ·   {d} / {d}", .{ im.w, im.h, self.view.scale(box, @floatFromInt(im.w), @floatFromInt(im.h)) * self.density * 100, self.position() + 1, self.count() }) catch "" else tr("Space / Esc to close  ·  Arrow keys to browse");
    setSource(cr, t.window_fg);
    drawText(cr, text, (@as(f64, @floatFromInt(self.w)) - measureText(cr, text, shell_ui.statusSize(), false)) / 2, @floatFromInt(self.h - 3), shell_ui.statusSize(), false);
    if (self.dialog != .none) self.drawDialog(cr);
}
