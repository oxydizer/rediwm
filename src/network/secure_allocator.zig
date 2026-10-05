//! Page-isolated, locked allocations for passwords and their D-Bus encoding.
const std = @import("std");
extern "c" fn mlock(*const anyopaque, usize) c_int;
extern "c" fn munlock(*const anyopaque, usize) c_int;
pub const allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const p = std.heap.page_allocator.rawAlloc(len, alignment, ra) orelse return null;
    if (mlock(p, len) != 0) {
        std.heap.page_allocator.rawFree(p[0..len], alignment, ra);
        return null;
    }
    return p;
}
fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
    std.crypto.secureZero(u8, memory);
    _ = munlock(memory.ptr, memory.len);
    std.heap.page_allocator.rawFree(memory, alignment, ra);
}
