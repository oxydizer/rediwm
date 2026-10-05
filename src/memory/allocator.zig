const std = @import("std");
/// Shared process allocator. The executable owns shutdown and leak reporting.
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
pub const gpa = if (@import("builtin").mode == .Debug) debug_allocator.allocator() else std.heap.c_allocator;
pub fn deinit() bool {
    return if (@import("builtin").mode == .Debug) debug_allocator.deinit() == .leak else false;
}
