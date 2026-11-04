//! Rendering: shm buffers, the frame and the client-side titlebar.

const std = @import("std");
const c = @import("c.zig").api;
const app_mod = @import("app.zig");
const shell_ui = @import("ui").cairo;
const ui_theme = @import("ui").theme;
const a = std.heap.c_allocator;
const main = @import("main.zig");
const Buffer = main.Buffer;
const Client = @import("Client.zig");
const wl = @import("wayland").client.wl;

pub fn acquireBuffer(self: *Client, w: i32, h: i32) !*Buffer {
    var i: usize = 0;
    while (i < self.buffers.items.len) {
        const buffer = self.buffers.items[i];
        if (!buffer.busy and (buffer.w != w or buffer.h != h)) {
            _ = self.buffers.swapRemove(i);
            buffer.destroy();
        } else i += 1;
    }
    for (self.buffers.items) |buffer| {
        if (!buffer.busy) return buffer;
    }
    const buffer = try Buffer.create(self, w, h);
    errdefer buffer.destroy();
    try self.buffers.append(a, buffer);
    return buffer;
}

/// Device rows [y1, y2) one commit changed.
pub const RowBand = struct { y1: i32 = 0, y2: i32 = 0 };

/// Brings a recycled `buffer` up to the last published image (`retained`):
/// only the rows committed since it was last painted, when they are still
/// in `self.bands`, else all of it.
fn refreshBuffer(self: *Client, buffer: *Buffer, bw: i32, bh: i32) void {
    const pixels: [*]u8 = @ptrCast(buffer.memory);
    const stride: usize = @intCast(bw * 4);
    if (buffer.seq == 0 or self.commit_seq - buffer.seq > self.bands.len) {
        @memcpy(pixels[0..buffer.len], self.retained.items);
        return;
    }
    var y1 = bh;
    var y2: i32 = 0;
    var seq = buffer.seq + 1;
    while (seq <= self.commit_seq) : (seq += 1) {
        const band = self.bands[seq % self.bands.len];
        y1 = @min(y1, band.y1);
        y2 = @max(y2, band.y2);
    }
    if (y2 <= y1) return;
    const from = @as(usize, @intCast(y1)) * stride;
    const to = @as(usize, @intCast(y2)) * stride;
    @memcpy(pixels[from..to], self.retained.items[from..to]);
}

fn frameDone(callback: *wl.Callback, _: wl.Callback.Event, self: *Client) void {
    callback.destroy();
    self.frame_callback = null;
}

pub fn render(self: *Client) !void {
    if (!self.configured or !self.app.dirty or self.outstanding >= 2) return;
    // Partial repaints (hover, proximity glow, fades) follow the display,
    // not the pointer rate: wait for the last commit's frame callback.
    if (self.app.paint_damage != null and self.frame_callback != null and !self.ack_uncommitted) return;

    const tbh = self.titlebarHeight();
    const w = self.app.w;
    const h = self.app.h + tbh;
    const bw = w * self.scale;
    const bh = h * self.scale;
    const buffer = try self.acquireBuffer(bw, bh);

    const partial = self.retained.items.len == buffer.len and self.retained_w == bw and self.applied_scale == self.scale and self.app.paint_damage != null;
    // The rows this paint can change: the clip of a partial paint (rounded
    // out to device pixels like `clipDamage`), else everything. Outside
    // them the buffer already equals `retained`, so only these are compared
    // and copied back.
    var band: RowBand = .{ .y1 = 0, .y2 = bh };
    var cols: RowBand = .{ .y1 = 0, .y2 = bw }; // the same, for columns
    if (partial) {
        const damage = self.app.paint_damage.?;
        const s: f64 = @floatFromInt(self.scale);
        const top = (damage.y + @as(f64, @floatFromInt(tbh))) * s;
        const left = damage.x * s;
        band = .{
            .y1 = @intFromFloat(std.math.clamp(@floor(top), 0, @as(f64, @floatFromInt(bh)))),
            .y2 = @intFromFloat(std.math.clamp(@ceil(top + damage.h * s), 0, @as(f64, @floatFromInt(bh)))),
        };
        cols = .{
            .y1 = @intFromFloat(std.math.clamp(@floor(left), 0, @as(f64, @floatFromInt(bw)))),
            .y2 = @intFromFloat(std.math.clamp(@ceil(left + damage.w * s), 0, @as(f64, @floatFromInt(bw)))),
        };
        refreshBuffer(self, buffer, bw, bh);
        c.cairo_surface_mark_dirty(buffer.image);
    }
    const cr = c.cairo_create(buffer.image) orelse return error.CairoFailed;
    defer c.cairo_destroy(cr);

    c.cairo_scale(cr, @floatFromInt(self.scale), @floatFromInt(self.scale));
    if (partial) {
        var rect = self.app.paint_damage.?;
        rect.y += @floatFromInt(tbh);
        app_mod.clipDamage(cr, rect);
    }

    if (tbh > 0) self.renderTitlebar(cr, w, tbh);

    c.cairo_save(cr);
    c.cairo_translate(cr, 0, @floatFromInt(tbh));
    self.app.render(cr);
    c.cairo_restore(cr);

    c.cairo_surface_flush(buffer.image);

    const bytes: []const u8 = @as([*]const u8, @ptrCast(buffer.memory))[0..buffer.len];
    var x1 = bw;
    var y1 = bh;
    var x2: i32 = 0;
    var y2: i32 = 0;
    if (self.retained.items.len != bytes.len or self.retained_w != bw or self.applied_scale != self.scale) {
        x1 = 0;
        y1 = 0;
        x2 = bw;
        y2 = bh;
    } else {
        // Compare against the last published image, never against this recycled buffer.
        const stride: usize = @intCast(bw * 4);
        const col0: usize = @intCast(cols.y1);
        const col1: usize = @intCast(cols.y2);
        for (@intCast(band.y1)..@intCast(band.y2)) |row| {
            const offset = row * stride;
            const now: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, bytes[offset + col0 * 4 .. offset + col1 * 4]));
            const was: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, self.retained.items[offset + col0 * 4 .. offset + col1 * 4]));
            if (std.mem.eql(u32, now, was)) continue;
            y1 = @min(y1, @as(i32, @intCast(row)));
            y2 = @as(i32, @intCast(row + 1));
            const left = std.mem.indexOfDiff(u32, now, was).?;
            var right = now.len;
            while (right > left and now[right - 1] == was[right - 1]) right -= 1;
            x1 = @min(x1, @as(i32, @intCast(col0 + left)));
            x2 = @max(x2, @as(i32, @intCast(col0 + right)));
        }
    }
    if (partial) {
        const stride: usize = @intCast(bw * 4);
        if (y2 > y1) {
            const from = @as(usize, @intCast(y1)) * stride;
            const to = @as(usize, @intCast(y2)) * stride;
            @memcpy(self.retained.items[from..to], bytes[from..to]);
        }
    } else {
        try self.retained.resize(a, bytes.len);
        @memcpy(self.retained.items, bytes);
    }
    self.retained_w = bw;
    if (self.applied_scale != self.scale) {
        self.surface.setBufferScale(self.scale);
        self.applied_scale = self.scale;
    }
    if (x2 > x1 and y2 > y1) {
        self.commit_seq += 1;
        self.bands[self.commit_seq % self.bands.len] = .{ .y1 = y1, .y2 = y2 };
        if (self.frame_callback == null) {
            if (self.surface.frame()) |callback| {
                callback.setListener(*Client, frameDone, self);
                self.frame_callback = callback;
            } else |_| {}
        }
        self.xdg_surface.setWindowGeometry(0, 0, w, h);
        self.surface.attach(buffer.wl_buffer, 0, 0);
        self.surface.damageBuffer(x1, y1, x2 - x1, y2 - y1);
        self.surface.commit();
        buffer.busy = true;
        self.outstanding += 1;
    } else if (self.ack_uncommitted) {
        // Keep the attached buffer; the commit only applies the ack.
        self.xdg_surface.setWindowGeometry(0, 0, w, h);
        self.surface.commit();
    }
    // Committed or not, the buffer now holds exactly the published image.
    buffer.seq = self.commit_seq;
    self.ack_uncommitted = false;
    self.app.dirty = false;
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

    const title = std.mem.span(self.app.getTitle());
    shell_ui.setSource(cr, ui_theme.global.window_fg);
    const tw = app_mod.measureText(cr, title, 12, true);
    app_mod.drawText(cr, title, (w_f - tw) / 2.0, h_f / 2.0 + 4, 12, true);

    const close_w: f64 = @min(h_f, 32);
    const hovered = self.inside and self.pointer_y < h_f and self.pointer_x >= w_f - close_w;
    if (hovered) {
        shell_ui.setSource(cr, ui_theme.global.window_close_hover);
        c.cairo_rectangle(cr, w_f - close_w, 0, close_w, h_f);
        c.cairo_fill(cr);
        c.cairo_set_source_rgb(cr, 1, 1, 1);
    } else {
        shell_ui.setSource(cr, ui_theme.global.window_dim);
    }
    const cx = w_f - close_w / 2.0;
    const cy = h_f / 2.0;
    c.cairo_set_line_width(cr, 1.5);
    c.cairo_move_to(cr, cx - 5, cy - 5);
    c.cairo_line_to(cr, cx + 5, cy + 5);
    c.cairo_move_to(cr, cx + 5, cy - 5);
    c.cairo_line_to(cr, cx - 5, cy + 5);
    c.cairo_stroke(cr);
}
