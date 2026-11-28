//! Frames for the app-kit window host (`window.zig`): the render that paints
//! only what changed (`frameDamage`) into a released buffer, the client-side
//! titlebar, and frame callbacks for App animations. Methods of `Host(App)`,
//! aliased there.
const std = @import("std");
const ui = @import("ui");
const wl = @import("wayland").client.wl;
const c = @import("c_gfx");
const shell_ui = ui.cairo;
const ui_theme = ui.theme;

pub fn Render(comptime Client: type) type {
    return struct {
        /// Asks for the next frame callback if an App animation wants one;
        /// the commit that follows carries the request.
        pub fn requestAnimationFrame(self: *Client) void {
            if (!Client.has_animation or !self.app.animating or self.frame_callback != null) return;
            const callback = self.surface.frame() catch return;
            callback.setListener(*Client, frameDone, self);
            self.frame_callback = callback;
        }

        pub fn frameDone(callback: *wl.Callback, _: wl.Callback.Event, self: *Client) void {
            callback.destroy();
            self.frame_callback = null;
            if (Client.has_animation and self.app.animating) self.app.dirty = true;
        }

        pub fn wantsFrame(self: *const Client) bool {
            return self.configured and self.app.dirty and !self.app.suspended and self.buffers.outstanding < 2;
        }

        pub fn render(self: *Client) !void {
            self.updateCursor();
            if (!self.wantsFrame()) return;

            const tbh = self.titlebarHeight();
            const w = self.app.w;
            const h = self.app.h + tbh;
            const raster_scale: f64 = if (self.viewport != null) self.density else @floatFromInt(self.scale);
            const bw: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * raster_scale));
            const bh: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(h)) * raster_scale));
            const buffer = (try self.buffers.acquire(bw, bh)) orelse return;

            // What changed since the last commit, in surface coordinates.
            var damage = self.damage;
            if (Client.has_damage) {
                const app_damage = self.app.frameDamage();
                if (app_damage.full) damage = .whole else for (app_damage.slice()) |r| damage.add(.{ .x = r.x, .y = r.y + tbh, .w = r.w, .h = r.h });
            } else damage = .whole;
            if (damage.isEmpty()) {
                // Nothing to show, but an animation still waits for the display.
                if (Client.has_animation and self.app.animating and self.frame_callback == null) {
                    self.requestAnimationFrame();
                    self.surface.commit();
                }
                self.app.dirty = false;
                return;
            }
            // A recycled buffer also missed what was drawn into the other one.
            var repaint = damage;
            repaint.merge(&buffer.stale);

            const cr = c.cairo_create(buffer.image) orelse return error.CairoFailed;
            defer c.cairo_destroy(cr);

            const sx = @as(f64, @floatFromInt(bw)) / @as(f64, @floatFromInt(w));
            const sy = @as(f64, @floatFromInt(bh)) / @as(f64, @floatFromInt(h));
            if (!repaint.covers(w, h, 0.6)) {
                // Whole device pixels, so the clip is a pixel region.
                for (repaint.slice()) |r| {
                    const x0 = @max(0, @floor(@as(f64, @floatFromInt(r.x)) * sx));
                    const y0 = @max(0, @floor(@as(f64, @floatFromInt(r.y)) * sy));
                    const x1 = @min(@as(f64, @floatFromInt(bw)), @ceil(@as(f64, @floatFromInt(r.x + r.w)) * sx));
                    const y1 = @min(@as(f64, @floatFromInt(bh)), @ceil(@as(f64, @floatFromInt(r.y + r.h)) * sy));
                    if (x1 > x0 and y1 > y0) c.cairo_rectangle(cr, x0, y0, x1 - x0, y1 - y0);
                }
                c.cairo_clip(cr);
            }
            c.cairo_scale(cr, sx, sy);

            if (tbh > 0) self.renderTitlebar(cr, w, tbh);

            c.cairo_save(cr);
            c.cairo_translate(cr, 0, @floatFromInt(tbh));
            self.app.render(cr);
            c.cairo_restore(cr);

            c.cairo_surface_flush(buffer.image);

            const buffer_scale: i32 = if (self.viewport != null) 1 else self.scale;
            if (self.applied_scale != buffer_scale) {
                self.surface.setBufferScale(buffer_scale);
                self.applied_scale = buffer_scale;
            }
            if (self.viewport) |viewport| viewport.setDestination(w, h);
            self.xdg_surface.setWindowGeometry(0, 0, w, h);
            self.buffers.painted(buffer, &damage);
            self.buffers.submit(buffer);
            self.surface.attach(buffer.wl_buffer, 0, 0);
            if (damage.full) self.surface.damage(0, 0, w, h) else for (damage.slice()) |r| self.surface.damage(r.x, r.y, r.w, r.h);
            self.requestAnimationFrame();
            self.surface.commit();
            self.damage.clear();
            self.app.dirty = false;
        }

        pub fn renderTitlebar(self: *Client, cr: *c.cairo_t, w: i32, h: i32) void {
            shell_ui.setSource(cr, ui_theme.global.window_bg);
            c.cairo_rectangle(cr, 0, 0, @floatFromInt(w), @floatFromInt(h));
            c.cairo_fill(cr);
            shell_ui.setSource(cr, ui_theme.global.window_fg);
            shell_ui.drawText(cr, std.mem.span(self.app.getTitle()), 16, @as(f64, @floatFromInt(h)) / 2 + shell_ui.statusSize() / 3, shell_ui.statusSize(), true);
            self.arrangeClose();
            if (shell_ui.Layer.begin(cr, .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) })) |value| {
                var layer = value;
                ui.paint.paint(&self.close_button, &layer.renderer);
                layer.finish();
            }
        }
    };
}
