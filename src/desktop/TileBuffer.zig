//! One tile's pixels, owned by wlroots once published. Released buffers
//! return to a small pool of mostly equal-sized tiles.

const std = @import("std");
const wlr = @import("wlroots");
const a = std.heap.c_allocator;
const TileBuffer = @This();

base: wlr.Buffer,
width: i32,
height: i32,
pixels: []u32,
pooled: bool,

const drm_format_argb8888: u32 = 0x34325241;
const impl = wlr.Buffer.Impl{
    .destroy = destroyBuffer,
    .get_dmabuf = null,
    .get_shm = null,
    .begin_data_ptr_access = beginDataPtrAccess,
    .end_data_ptr_access = endDataPtrAccess,
};
const max_pooled = 32;
var pool: std.ArrayList(*TileBuffer) = .empty;

pub fn acquire(width: i32, height: i32) !*TileBuffer {
    for (pool.items, 0..) |buf, i| {
        if (buf.width != width or buf.height != height) continue;
        _ = pool.swapRemove(i);
        buf.base.init(&impl, width, height);
        return buf;
    }
    return create(width, height, true);
}

pub fn create(width: i32, height: i32, pooled: bool) !*TileBuffer {
    const buf = try a.create(TileBuffer);
    errdefer a.destroy(buf);
    const pixels = try a.alloc(u32, @intCast(width * height));
    buf.* = .{ .base = undefined, .width = width, .height = height, .pixels = pixels, .pooled = pooled };
    buf.base.init(&impl, width, height);
    return buf;
}

fn destroyBuffer(base: *wlr.Buffer) callconv(.c) void {
    // Notify texture wrappers and finish addons before reusing the buffer.
    base.finish();
    const buf: *TileBuffer = @fieldParentPtr("base", base);
    if (buf.pooled and pool.items.len < max_pooled) {
        if (pool.append(a, buf)) return else |_| {}
    }
    a.free(buf.pixels);
    a.destroy(buf);
}

fn beginDataPtrAccess(base: *wlr.Buffer, _: u32, data: **anyopaque, format: *u32, stride: *usize) callconv(.c) bool {
    const buf: *TileBuffer = @fieldParentPtr("base", base);
    data.* = @ptrCast(buf.pixels.ptr);
    format.* = drm_format_argb8888;
    stride.* = @as(usize, @intCast(buf.width)) * @sizeOf(u32);
    return true;
}

fn endDataPtrAccess(_: *wlr.Buffer) callconv(.c) void {}
