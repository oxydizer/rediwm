//! Rendering: shm buffers, the frame and the client-side titlebar.

const std = @import("std");
const c = @import("c.zig");
const ui_theme = @import("ui").theme;
const shell_ui = @import("ui").cairo;
const main_mod = @import("main.zig");
const Client = main_mod.Client;
const Buffer = main_mod.Buffer;
const wl = @import("wayland").client.wl;

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
    if (!self.configured or !(self.app.dirty or self.app.toolbar_dirty) or self.outstanding >= 2) return;
    if (!self.app.dirty and self.frame_callback != null) return;

    const tbh = self.titlebarHeight();
    const w = self.app.w;
    const h = self.app.h + tbh;
    const buffer = (try self.acquireBuffer(w * self.scale, h * self.scale)) orelse return;
    // A proximity-glow frame repaints only the toolbar strip when this
    // buffer already holds everything else (see `content_frame`).
    const partial = !self.app.dirty and buffer.frame != 0 and
        buffer.frame >= self.content_frame and self.applied_scale == self.scale;
    const strip_h: i32 = @intFromFloat(@ceil(self.app.toolbarRect().h));

    const cr = c.api.cairo_create(buffer.image) orelse return error.CairoFailed;
    defer c.api.cairo_destroy(cr);

    c.api.cairo_scale(cr, @floatFromInt(self.scale), @floatFromInt(self.scale));

    if (partial) {
        c.api.cairo_rectangle(cr, 0, @floatFromInt(tbh), @floatFromInt(w), @floatFromInt(strip_h));
        c.api.cairo_clip(cr);
    } else if (tbh > 0) self.renderTitlebar(cr, w, tbh);

    c.api.cairo_save(cr);
    c.api.cairo_translate(cr, 0, @floatFromInt(tbh));
    self.app.render(cr);
    c.api.cairo_restore(cr);

    c.api.cairo_surface_flush(buffer.image);

    if (self.applied_scale != self.scale) {
        self.surface.setBufferScale(self.scale);
        self.applied_scale = self.scale;
    }
    self.xdg_surface.setWindowGeometry(0, 0, w, h);
    buffer.busy = true;
    self.outstanding += 1;
    self.frames += 1;
    buffer.frame = self.frames;
    if (self.app.dirty) self.content_frame = self.frames;
    if (self.frame_callback == null) {
        if (self.surface.frame()) |callback| {
            callback.setListener(*Client, frameDone, self);
            self.frame_callback = callback;
        } else |_| {}
    }
    self.surface.attach(buffer.wl_buffer, 0, 0);
    if (partial) self.surface.damage(0, tbh, w, strip_h) else self.surface.damage(0, 0, w, h);
    self.surface.commit();
    self.app.dirty = false;
    self.app.toolbar_dirty = false;
}

fn frameDone(callback: *wl.Callback, _: wl.Callback.Event, self: *Client) void {
    callback.destroy();
    self.frame_callback = null;
}

pub fn renderTitlebar(self: *Client, cr: *c.api.cairo_t, w: i32, h: i32) void {
    const w_f: f64 = @floatFromInt(w);
    const h_f: f64 = @floatFromInt(h);

    shell_ui.setSource(cr, ui_theme.global.window_bg);
    c.api.cairo_rectangle(cr, 0, 0, w_f, h_f);
    c.api.cairo_fill(cr);

    shell_ui.setSource(cr, ui_theme.global.app_divider);
    c.api.cairo_set_line_width(cr, 1.0);
    c.api.cairo_move_to(cr, 0, h_f - 0.5);
    c.api.cairo_line_to(cr, w_f, h_f - 0.5);
    c.api.cairo_stroke(cr);

    const title = std.mem.span(self.app.getTitle());
    shell_ui.setSource(cr, ui_theme.global.window_fg);
    const tw = shell_ui.measureText(cr, title, 12, true);
    c.api.cairo_save(cr);
    c.api.cairo_rectangle(cr, 36, 0, @max(0, w_f - 72), h_f);
    c.api.cairo_clip(cr);
    shell_ui.drawText(cr, title, @max(36.0, (w_f - tw) / 2.0), h_f / 2.0 + 4, 12, true);
    c.api.cairo_restore(cr);

    const close_w: f64 = @min(h_f, 32.0);
    const hovered = self.inside and self.pointer_y < h_f and self.pointer_x >= w_f - close_w;
    if (hovered) {
        shell_ui.setSource(cr, ui_theme.global.window_close_hover);
        c.api.cairo_rectangle(cr, w_f - close_w, 0, close_w, h_f);
        c.api.cairo_fill(cr);
        c.api.cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
    } else {
        shell_ui.setSource(cr, ui_theme.global.window_dim);
    }
    const cx = w_f - close_w / 2.0;
    const cy = h_f / 2.0;
    c.api.cairo_set_line_width(cr, 1.5);
    c.api.cairo_move_to(cr, cx - 5, cy - 5);
    c.api.cairo_line_to(cr, cx + 5, cy + 5);
    c.api.cairo_move_to(cr, cx + 5, cy - 5);
    c.api.cairo_line_to(cr, cx - 5, cy + 5);
    c.api.cairo_stroke(cr);
}
