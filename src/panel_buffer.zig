// CPU-rasterized overlay-panel buffer. wlroots holds the displayed buffer
// until the next one replaces it, so two pooled slots are enough: the frame
// being shown and the one being painted. Recycling them matters because a
// fresh panel buffer is a ~1.3MB mmap whose first touch faults every page
// in. Buffers are immutable while the scene/renderer holds a lock; the pool
// only ever sees a buffer after wlroots has dropped it.
const std = @import("std");
const wlr = @import("wlroots");

const gpa = @import("main.zig").gpa;
const geometry = @import("geometry.zig");
const panel_present = @import("panel_present.zig");

extern "c" fn wlr_buffer_finish(buffer: *wlr.Buffer) void;

pub const PanelBuffer = struct {
    base: wlr.Buffer,
    width: i32,
    height: i32,
    pixels: []u32,
    /// Allocation capacity is independent of the published raster dimensions.
    storage: []u32,
    sensitive: bool = false,
    /// Off for buffers made by `createUnpooled`, which never enter the pool.
    pooled: bool = true,

    const drm_format_argb8888: u32 = 0x34325241;

    const impl = wlr.Buffer.Impl{
        .destroy = destroyBuffer,
        .get_dmabuf = null,
        .get_shm = null,
        .begin_data_ptr_access = beginDataPtrAccess,
        .end_data_ptr_access = endDataPtrAccess,
    };

    var pool: [2]?*PanelBuffer = .{ null, null };

    pub fn create(logical_width: i32, logical_height: i32, scale: f32) !*PanelBuffer {
        const buf = try createUninitialized(logical_width, logical_height, scale);
        @memset(buf.pixels, 0);
        return buf;
    }

    /// Flip a freshly painted background before adding upright panel content.
    /// Used to point taskbar popups towards either screen edge.
    pub fn flipVertical(self: *PanelBuffer) void {
        std.debug.assert(self.base.n_locks == 0);
        const width: usize = @intCast(self.width);
        const height: usize = @intCast(self.height);
        for (0..height / 2) |y| {
            for (0..width) |x| {
                std.mem.swap(u32, &self.pixels[y * width + x], &self.pixels[(height - 1 - y) * width + x]);
            }
        }
    }

    /// A small cleared buffer that bypasses the pool: creating it doesn't
    /// occupy the panels' pooled slots, and
    /// dropping it frees it. For tiny rasters redrawn per frame, like a caret.
    pub fn createUnpooled(logical_width: i32, logical_height: i32, scale: f32) !*PanelBuffer {
        const width = geometry.devicePixels(logical_width, scale);
        const height = geometry.devicePixels(logical_height, scale);
        const buf = try gpa.create(PanelBuffer);
        errdefer gpa.destroy(buf);
        const pixels = try gpa.alloc(u32, @intCast(width * height));
        @memset(pixels, 0);
        buf.* = .{ .base = undefined, .width = width, .height = height, .pixels = pixels, .storage = pixels, .pooled = false };
        buf.base.init(&impl, width, height);
        return buf;
    }

    /// The caller must initialize every pixel before publishing this buffer.
    /// Cached panel backgrounds overwrite the whole buffer, so clearing it
    /// first would be a redundant full-buffer write.
    pub fn createUninitialized(logical_width: i32, logical_height: i32, scale: f32) !*PanelBuffer {
        const width = geometry.devicePixels(logical_width, scale);
        const height = geometry.devicePixels(logical_height, scale);
        const bytes: u64 = @as(u64, @intCast(width)) * @as(u64, @intCast(height)) * @sizeOf(u32);

        for (&pool) |*slot| {
            const recycled = slot.* orelse continue;
            const length: usize = @intCast(width * height);
            if (recycled.storage.len < length) {
                // Grow geometrically during a resize; never resize a buffer
                // until wlroots has released it into this pool.
                const capacity = @max(length, recycled.storage.len + recycled.storage.len / 2);
                recycled.storage = try gpa.realloc(recycled.storage, capacity);
                panel_present.addAlloc(@as(u64, @intCast(capacity)) * @sizeOf(u32));
            } else panel_present.addReuse(bytes);
            slot.* = null;
            recycled.width = width;
            recycled.height = height;
            recycled.pixels = recycled.storage[0..length];
            // wlr_buffer_init resets the whole struct (impl, size, lock count
            // and both signals), which is exactly what a reused one needs.
            recycled.base.init(&impl, width, height);
            return recycled;
        }

        const buf = try gpa.create(PanelBuffer);
        errdefer gpa.destroy(buf);

        const length: usize = @intCast(width * height);
        const pixels = try gpa.alloc(u32, length);
        errdefer gpa.free(pixels);

        buf.* = .{ .base = undefined, .width = width, .height = height, .pixels = pixels, .storage = pixels };
        buf.base.init(&impl, width, height);
        panel_present.addAlloc(bytes);
        return buf;
    }

    pub fn publish(buf: *PanelBuffer, node: *wlr.SceneBuffer, scale: f32, damage: ?@import("ui").paint.ClipRect) void {
        if (damage) |box| {
            const pixman = @import("pixman");
            // Scene damage is buffer-local: use the actual raster scale,
            // not the rounded destination dimensions' ratio.
            const sx: f64 = scale;
            const sy: f64 = scale;
            const x: i32 = @intFromFloat(@floor(box.x * sx));
            const y: i32 = @intFromFloat(@floor(box.y * sy));
            const right: i32 = @intFromFloat(@ceil((box.x + box.w) * sx));
            const bottom: i32 = @intFromFloat(@ceil((box.y + box.h) * sy));
            var region: pixman.Region32 = undefined;
            region.initRect(x, y, @intCast(right - x), @intCast(bottom - y));
            defer region.deinit();
            node.setBufferWithDamage(&buf.base, &region);
        } else node.setBuffer(&buf.base);
    }

    /// Release the pooled buffers. wlroots has already let go of anything that
    /// reaches the pool, so this only ever frees memory nothing can reach.
    pub fn drainPool() void {
        for (&pool) |*slot| {
            const buf = slot.* orelse continue;
            slot.* = null;
            gpa.free(buf.storage);
            gpa.destroy(buf);
        }
    }

    fn destroyBuffer(base: *wlr.Buffer) callconv(.c) void {
        // wlroots 0.20 leaves this to the producer. Notify texture wrappers
        // before pooling/freeing storage, so they cannot retain a stale source.
        wlr_buffer_finish(base);
        const buf: *PanelBuffer = @fieldParentPtr("base", base);
        if (buf.sensitive) {
            std.crypto.secureZero(u32, buf.storage);
            gpa.free(buf.storage);
            gpa.destroy(buf);
            return;
        }
        if (!buf.pooled) {
            gpa.free(buf.storage);
            gpa.destroy(buf);
            return;
        }
        for (&pool) |*slot| {
            if (slot.* == null) {
                slot.* = buf;
                return;
            }
        }
        gpa.free(buf.storage);
        gpa.destroy(buf);
    }

    fn beginDataPtrAccess(base: *wlr.Buffer, _: u32, data: **anyopaque, format: *u32, stride: *usize) callconv(.c) bool {
        const buf: *PanelBuffer = @fieldParentPtr("base", base);
        data.* = @ptrCast(buf.pixels.ptr);
        format.* = drm_format_argb8888;
        stride.* = @as(usize, @intCast(buf.width)) * @sizeOf(u32);
        return true;
    }

    fn endDataPtrAccess(_: *wlr.Buffer) callconv(.c) void {}
};

test "panel buffer destruction notifies consumers before pooling or freeing" {
    const wl = @import("wayland").server.wl;
    const Watch = struct {
        destroyed: bool = false,
        listener: wl.Listener(void) = .init(notify),

        fn notify(listener: *wl.Listener(void)) void {
            const self: *@This() = @fieldParentPtr("listener", listener);
            self.destroyed = true;
            listener.link.remove();
        }
    };
    defer PanelBuffer.drainPool();
    for ([_]bool{ true, false }) |pooled| {
        const buf = if (pooled) try PanelBuffer.create(16, 8, 1) else try PanelBuffer.createUnpooled(16, 8, 1);
        var watch: Watch = .{};
        buf.base.events.destroy.add(&watch.listener);
        _ = buf.base.lock();
        buf.base.drop();
        try std.testing.expect(!watch.destroyed);
        buf.base.unlock();
        try std.testing.expect(watch.destroyed);
    }
}

test "same-size panel buffers are reused from the pool" {
    panel_present.reset();
    defer PanelBuffer.drainPool();

    const first = try PanelBuffer.create(16, 8, 1);
    @memset(first.pixels, 0xdeadbeef);
    first.base.drop();
    const second = try PanelBuffer.create(16, 8, 1);
    for (second.pixels) |pixel| try std.testing.expectEqual(@as(u32, 0), pixel);
    second.base.drop();

    const stats = panel_present.snapshot();
    const bytes: u64 = 16 * 8 * 4;
    try std.testing.expectEqual(bytes, stats.allocated_bytes);
    try std.testing.expectEqual(bytes, stats.reused_bytes);
}

test "resized panel buffers reuse capacity with exact dimensions and respect locks" {
    panel_present.reset();
    defer PanelBuffer.drainPool();

    const first = try PanelBuffer.create(32, 16, 1);
    const storage = first.storage.ptr;
    _ = first.base.lock();
    first.base.drop();
    const busy = try PanelBuffer.create(24, 16, 1);
    try std.testing.expect(busy.storage.ptr != storage);
    first.base.unlock();
    const second = try PanelBuffer.create(16, 8, 1);
    try std.testing.expectEqual(storage, second.storage.ptr);
    try std.testing.expectEqual(@as(i32, 16), second.base.width);
    try std.testing.expectEqual(@as(i32, 8), second.base.height);
    try std.testing.expectEqual(@as(usize, 16 * 8), second.pixels.len);
    second.base.drop();
    const grown = try PanelBuffer.create(33, 16, 1);
    const grown_storage = grown.storage.ptr;
    try std.testing.expect(grown.storage.len > grown.pixels.len);
    grown.base.drop();
    const next = try PanelBuffer.create(34, 16, 1);
    try std.testing.expectEqual(grown_storage, next.storage.ptr);
    next.base.drop();
    busy.base.drop();

    const stats = panel_present.snapshot();
    try std.testing.expectEqual(@as(u64, (16 * 8 + 34 * 16) * 4), stats.reused_bytes);
}
