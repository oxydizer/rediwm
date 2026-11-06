//! Rendering: shm buffers, the frame and the client-side titlebar.

const std = @import("std");
const c = @import("../files/c.zig").api;
const shell_ui = @import("ui").cairo;
const wl = @import("wayland").client.wl;
const ui_theme = @import("ui").theme;
const button_widget = @import("ui").widgets.button;
const IconId = @import("ui").layout.IconId;
const main_mod = @import("main.zig");
const Client = main_mod.Client;
const Buffer = main_mod.Buffer;
const HeaderControl = Client.HeaderControl;

pub fn acquireBuffer(self: *Client, w: i32, h: i32) !?*Buffer {
    for (self.buffers) |slot| if (slot) |buffer| {
        if (!buffer.busy and buffer.w == w and buffer.h == h) return buffer;
    };
    for (&self.buffers) |*slot| {
        if (slot.*) |buffer| {
            if (buffer.busy) continue;
            buffer.destroy();
            slot.* = null;
        }
        slot.* = try Buffer.create(self, w, h);
        return slot.*;
    }
    return null;
}

pub fn render(self: *Client) !void {
    self.updateCursor();
    if (!self.configured or (!self.app.dirty and !self.app.caret_dirty and !self.app.glow_dirty and !self.app.reflow_dirty) or self.outstanding >= 2) return;
    // Glow and gliding lines follow the display, not the loop's own timer; the
    // caret moving with them must not make them run ahead of it.
    if (!self.app.dirty and self.frame_callback != null and (!self.app.caret_dirty or self.app.reflow_dirty)) return;
    const full = self.app.dirty or self.app.glow_dirty or self.app.reflow_dirty;

    const tbh = self.titlebarHeight();
    const w = self.app.w;
    const h = self.app.h + tbh;
    const buffer = (try self.acquireBuffer(w * self.scale, h * self.scale)) orelse return;

    const cr = c.cairo_create(buffer.image) orelse return error.CairoFailed;
    defer c.cairo_destroy(cr);

    c.cairo_scale(cr, @floatFromInt(self.scale), @floatFromInt(self.scale));

    // CSD owns the complete frame, including transparent rounded corners.
    // Clear recycled buffers before clipping so old edge pixels cannot linger.
    if (self.wantsCsd()) {
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
        c.cairo_paint(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
        if (!self.maximized and !self.fullscreen) {
            const radius: f64 = ui_theme.global.radius_lg;
            const width: f64 = @floatFromInt(w);
            const height: f64 = @floatFromInt(h);
            c.cairo_new_sub_path(cr);
            c.cairo_arc(cr, width - radius, radius, radius, -std.math.pi / 2.0, 0);
            c.cairo_arc(cr, width - radius, height - radius, radius, 0, std.math.pi / 2.0);
            c.cairo_arc(cr, radius, height - radius, radius, std.math.pi / 2.0, std.math.pi);
            c.cairo_arc(cr, radius, radius, radius, std.math.pi, 3 * std.math.pi / 2.0);
            c.cairo_close_path(cr);
            c.cairo_clip(cr);
        }
    }

    if (tbh > 0) self.renderTitlebar(cr, w, tbh);

    c.cairo_save(cr);
    c.cairo_translate(cr, 0, @floatFromInt(tbh));
    self.app.render(cr);
    c.cairo_restore(cr);

    c.cairo_surface_flush(buffer.image);

    if (self.applied_scale != self.scale) {
        self.surface.setBufferScale(self.scale);
        self.applied_scale = self.scale;
    }
    self.xdg_surface.setWindowGeometry(0, 0, w, h);
    buffer.busy = true;
    self.outstanding += 1;
    if (self.frame_callback == null) {
        if (self.surface.frame()) |callback| {
            callback.setListener(*Client, frameDone, self);
            self.frame_callback = callback;
        } else |_| {}
    }
    self.surface.attach(buffer.wl_buffer, 0, 0);
    if (full) self.surface.damageBuffer(0, 0, w * self.scale, h * self.scale) else {
        const rect = self.app.caretDamage();
        self.surface.damageBuffer(rect.x * self.scale, (rect.y + tbh) * self.scale, rect.width * self.scale, rect.height * self.scale);
    }
    self.surface.commit();
    self.app.dirty = false;
    self.app.caret_dirty = false;
    self.app.glow_dirty = false;
    self.app.reflow_dirty = false;
    self.app.caret_painted = self.app.caret.box;
}

fn frameDone(callback: *wl.Callback, _: wl.Callback.Event, self: *Client) void {
    callback.destroy();
    self.frame_callback = null;
}

pub fn renderTitlebar(self: *Client, cr: *c.cairo_t, w: i32, h: i32) void {
    const w_f: f64 = @floatFromInt(w);
    const h_f: f64 = @floatFromInt(h);

    shell_ui.setSource(cr, ui_theme.global.window_bg);
    c.cairo_rectangle(cr, 0, 0, w_f, h_f);
    c.cairo_fill(cr);

    shell_ui.setSource(cr, ui_theme.global.app_divider);
    c.cairo_set_line_width(cr, 1);
    c.cairo_move_to(cr, 0, h_f - 0.5);
    c.cairo_line_to(cr, w_f, h_f - 0.5);
    c.cairo_stroke(cr);

    const menu_rect = self.headerButton(.menu);
    self.app.menu_anchor = menu_rect.x + menu_rect.w;
    if (shell_ui.Layer.begin(cr, .{ .x = 16, .y = @floatCast((h_f - 20) / 2), .w = 20, .h = 20 })) |l| {
        var layer = l;
        layer.renderer.drawIcon(0, 0, 20, 20, .{ .id = .edit, .color = ui_theme.global.window_fg });
        layer.finish();
    }
    const title = std.mem.span(self.app.getTitle());
    const title_size = ui_theme.global.title_size;
    const metrics = shell_ui.fontMetrics(cr, title_size);
    shell_ui.setSource(cr, ui_theme.global.window_fg);
    c.cairo_save(cr);
    c.cairo_rectangle(cr, 46, 0, @max(0, menu_rect.x - 54), h_f);
    c.cairo_clip(cr);
    shell_ui.drawText(cr, title, 46, (h_f + metrics.ascent - metrics.descent) / 2, title_size, true);
    c.cairo_restore(cr);

    const divider = (menu_rect.x + menu_rect.w + self.headerButton(.minimize).x) / 2;
    shell_ui.setSource(cr, ui_theme.global.app_divider);
    c.cairo_set_line_width(cr, 1);
    c.cairo_move_to(cr, @floor(divider) + 0.5, h_f * 0.3);
    c.cairo_line_to(cr, @floor(divider) + 0.5, h_f * 0.7);
    c.cairo_stroke(cr);
    inline for (.{ HeaderControl.menu, HeaderControl.minimize, HeaderControl.maximize, HeaderControl.close }) |control| {
        const r = self.headerButton(control);
        if (shell_ui.Layer.begin(cr, r)) |l| {
            var layer = l;
            layer.renderer.palette = ui_theme.shellPalette();
            button_widget.paint(&layer.renderer, layer.local(), .{
                .label = if (control == .menu) @import("i18n").tr("Menu") else "",
                .icon = switch (control) {
                    .menu => IconId.more,
                    .minimize => IconId.minimize,
                    .maximize => IconId.maximize,
                    .close => IconId.close,
                },
                .variant = if (control == .close) .chrome else .ghost,
                .size = .sm,
                .icon_scale = if (control == .menu) 1.25 else 0.5,
            }, .{
                .pointer = if (self.overHeaderButton(control)) .hover else .idle,
                .selected = control == .menu and self.app.menu_open,
            });
            layer.finish();
        }
    }
}
