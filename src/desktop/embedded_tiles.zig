//! The desktop's canvas and the tiles it is published as.

const std = @import("std");
const pixman = @import("pixman");
const c = @import("c.zig").api;
const app_mod = @import("app.zig");
const grid = @import("grid.zig");
const geometry = @import("../geometry.zig");
const log = std.log.scoped(.desktop);
const a = std.heap.c_allocator;
const TileBuffer = @import("TileBuffer.zig");
const embedded_mod = @import("embedded.zig");
const Desktop = embedded_mod.Desktop;
const tile_logical = embedded_mod.tile_logical;
const Tile = Desktop.Tile;
const canvas_idle_ms = Desktop.canvas_idle_ms;

pub fn rebuild(self: *Desktop) !void {
    self.freeCanvas();
    self.clearTiles();
    const width = geometry.devicePixels(self.box.width, self.scale);
    const height = geometry.devicePixels(self.box.height, self.scale);
    if (width > 16384 or height > 16384) return error.InvalidSize;
    self.canvas_width = width;
    self.canvas_height = height;

    var ly: i32 = 0;
    while (ly < self.box.height) : (ly += tile_logical) {
        var lx: i32 = 0;
        while (lx < self.box.width) : (lx += tile_logical) {
            const lw = @min(tile_logical, self.box.width - lx);
            const lh = @min(tile_logical, self.box.height - ly);
            // Device edges come from the same rounding for every tile, so
            // neighbours share them exactly.
            const x0 = deviceEdge(lx, self.scale, width);
            const y0 = deviceEdge(ly, self.scale, height);
            const x1 = deviceEdge(lx + lw, self.scale, width);
            const y1 = deviceEdge(ly + lh, self.scale, height);
            if (x1 <= x0 or y1 <= y0) continue;
            const node = try self.tree.createSceneBuffer(null);
            self.scene_data.attach(&node.node);
            // Opaque once it has something to show.
            node.setOpacity(0);
            node.node.setPosition(lx, ly);
            node.setDestSize(lw, lh);
            self.tiles.append(a, .{ .node = node, .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0, .logical = .{ .x = lx, .y = ly, .w = lw, .h = lh } }) catch |err| {
                node.node.destroy();
                return err;
            };
        }
    }
    self.app.invalidate();
}

pub fn deviceEdge(logical: i32, scale: f32, limit: i32) i32 {
    const edge: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(logical)) * scale));
    return std.math.clamp(edge, 0, limit);
}

/// The canvas for a paint, all of whose tiles are stale when it is new.
pub fn ensureCanvas(self: *Desktop) !*c.cairo_surface_t {
    if (self.surface) |surface| return surface;
    const width = self.canvas_width;
    const height = self.canvas_height;
    if (width <= 0 or height <= 0) return error.InvalidSize;
    const count: usize = @intCast(width * height);
    // calloc: an mmap-sized block arrives zeroed, and only the tiles the
    // paint reaches are ever touched.
    const raw = std.c.calloc(count, @sizeOf(u32)) orelse return error.OutOfMemory;
    const pixels = @as([*]u32, @ptrCast(@alignCast(raw)))[0..count];
    const surface = c.cairo_image_surface_create_for_data(@ptrCast(pixels.ptr), c.CAIRO_FORMAT_ARGB32, width, height, width * 4) orelse {
        std.c.free(raw);
        return error.CairoFailed;
    };
    if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
        c.cairo_surface_destroy(surface);
        std.c.free(raw);
        return error.CairoFailed;
    }
    self.canvas = pixels;
    self.surface = surface;
    // A tile that shows nothing is the zeros it already holds.
    for (self.tiles.items) |*tile| tile.valid = !tile.shown;
    return surface;
}

/// The tiles keep showing what they last published.
pub fn freeCanvas(self: *Desktop) void {
    if (self.surface) |surface| c.cairo_surface_destroy(surface);
    self.surface = null;
    if (self.canvas.len > 0) std.c.free(self.canvas.ptr);
    self.canvas = &.{};
    self.canvas_release_at = null;
    for (self.tiles.items) |*tile| tile.valid = false;
}

pub fn clearTiles(self: *Desktop) void {
    for (self.tiles.items) |tile| tile.node.node.destroy();
    self.tiles.clearRetainingCapacity();
}

pub fn paint(self: *Desktop) void {
    if (self.tiles.items.len == 0) return;
    self.app.prepareDamage();
    if (!self.app.damage.full and self.app.damage.len == 0) {
        self.app.presented();
        return;
    }
    const surface = self.ensureCanvas() catch |err| {
        log.warn("desktop canvas {d}x{d}: {}", .{ self.canvas_width, self.canvas_height, err });
        return;
    };
    // A tile the canvas does not hold is repainted whole when damage
    // reaches it, judged as `publish` judges it, so every tile published
    // is one the canvas holds. Where 240 logical px is not a whole number
    // of device px, a tile's own rect reaches its neighbour: repeat.
    var grew = true;
    while (grew and !self.app.damage.full) {
        grew = false;
        const reached = self.app.damage;
        for (self.tiles.items) |*tile| {
            if (tile.valid) continue;
            for (reached.rects[0..reached.len]) |r| if (self.touches(tile.*, r)) {
                self.app.damage.add(tile.logical);
                tile.valid = true;
                grew = true;
                break;
            };
        }
    }
    if (self.app.damage.full) for (self.tiles.items) |*tile| {
        tile.valid = true;
    };
    self.canvas_release_at = app_mod.nowMs() + canvas_idle_ms;
    const cr = c.cairo_create(surface) orelse return;
    c.cairo_scale(cr, self.scale, self.scale);
    const counters = &@import("../ipc/stats.zig").global_stats.desktop;
    counters.paints +%= 1;
    if (self.app.damage.full) {
        counters.damage_pixels +%= @intCast(self.box.width * self.box.height);
    } else for (self.app.damage.rects[0..self.app.damage.len]) |r| {
        counters.damage_pixels +%= @intCast(@max(0, r.w) * @max(0, r.h));
    }
    self.app.paint(cr, &self.app.damage);
    c.cairo_destroy(cr);
    c.cairo_surface_flush(surface);
    self.publish(&self.app.damage);
    self.paintOverlay() catch |err| log.warn("desktop overlay: {}", .{err});
    self.app.presented();
}

/// Copies each damaged tile into a fresh buffer and hands projection the
/// tile-local device damage.
pub fn publish(self: *Desktop, damage: *const app_mod.Damage) void {
    const projection = self.server.world.projection;
    for (self.tiles.items) |*tile| {
        var region: pixman.Region32 = undefined;
        region.init();
        defer region.deinit();
        if (!damage.full) {
            for (damage.rects[0..damage.len]) |r| {
                const d = self.deviceRect(r);
                const x0 = @max(d.x, tile.x);
                const y0 = @max(d.y, tile.y);
                const x1 = @min(d.x + d.w, tile.x + tile.w);
                const y1 = @min(d.y + d.h, tile.y + tile.h);
                if (x1 <= x0 or y1 <= y0) continue;
                _ = region.unionRect(&region, x0 - tile.x, y0 - tile.y, @intCast(x1 - x0), @intCast(y1 - y0));
            }
            if (!region.notEmpty()) continue;
        }
        if (tile.valid and self.tileEmpty(tile.*)) {
            // Nothing to show: nothing to upload or draw. The texture stays
            // for an in-place update when the tile shows something again.
            if (tile.shown) tile.node.setOpacity(0);
            tile.shown = false;
            continue;
        }
        const buffer = TileBuffer.acquire(tile.w, tile.h) catch |err| {
            log.warn("desktop tile buffer: {}", .{err});
            continue;
        };
        const stride: usize = @intCast(self.canvas_width);
        const w: usize = @intCast(tile.w);
        for (0..@intCast(tile.h)) |row| {
            const start = (@as(usize, @intCast(tile.y)) + row) * stride + @as(usize, @intCast(tile.x));
            @memcpy(buffer.pixels[row * w ..][0..w], self.canvas[start..][0..w]);
        }
        // A tile shown again holds what it showed before it emptied: all of it is new.
        const whole = damage.full or !tile.shown;
        if (!tile.shown) tile.node.setOpacity(1);
        tile.shown = true;
        const textured = tile.textured;
        tile.textured = true;
        const in_place = projection.presentOwned(tile.node, self.server.renderer, &buffer.base, if (whole) null else &region);
        buffer.base.drop();
        const counters = &@import("../ipc/stats.zig").global_stats.desktop;
        counters.tile_presents +%= 1;
        // A tile's first texture is not a repaint that failed to update one.
        if (!in_place and textured) counters.texture_uploads +%= 1;
    }
}

pub fn tileEmpty(self: *const Desktop, tile: Tile) bool {
    const stride: usize = @intCast(self.canvas_width);
    const w: usize = @intCast(tile.w);
    for (0..@intCast(tile.h)) |row| {
        const start = (@as(usize, @intCast(tile.y)) + row) * stride + @as(usize, @intCast(tile.x));
        for (self.canvas[start..][0..w]) |pixel| if (pixel != 0) return false;
    }
    return true;
}

/// The device pixels a logical damage rect can touch, as App.paintRect
/// snaps its clip. An edge that lands on a device pixel edge but for float
/// error (240 x 1.6f is 384.0000057) stays there: Cairo may paint the
/// pixel past it, with what was there, but it is not damage, and it must
/// not reach into a tile the canvas does not hold.
pub fn deviceRect(self: *const Desktop, r: grid.Rect) grid.Rect {
    const s: f64 = self.scale;
    const slack = 1e-3;
    const x0: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(r.x)) * s + slack));
    const y0: i32 = @intFromFloat(@floor(@as(f64, @floatFromInt(r.y)) * s + slack));
    const x1: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(r.x + r.w)) * s - slack));
    const y1: i32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(r.y + r.h)) * s - slack));
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// Whether a damage rect reaches the tile's device pixels.
pub fn touches(self: *const Desktop, tile: Tile, r: grid.Rect) bool {
    const d = self.deviceRect(r);
    return d.x < tile.x + tile.w and tile.x < d.x + d.w and d.y < tile.y + tile.h and tile.y < d.y + d.h;
}
