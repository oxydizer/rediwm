const std = @import("std");
const builtin = @import("builtin");
/// Shared process allocator. The executable owns shutdown and leak reporting.
var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
pub const gpa = if (builtin.mode == .debug) debug_allocator.allocator() else std.heap.c_allocator;
pub fn deinit() bool {
    return if (builtin.mode == .debug) debug_allocator.deinit() == .leak else false;
}

extern "c" fn mallopt(param: c_int, value: c_int) c_int;

/// For a long-running process that frees large pixel buffers (panels, the
/// Settings window): glibc raises its mmap threshold to the largest block
/// freed so far, after which such buffers come from the heap and stay
/// resident when freed (+15 MB after opening and closing Settings, measured
/// 2026-11-25). Fixed thresholds stop that: blocks of 1 MiB and more are
/// mapped and handed back when freed, and the heap top is trimmed past 4 MiB.
/// Smaller blocks (titlebar and taskbar rasters, repainted many times a second)
/// stay in the heap; a 128 KiB threshold cost 1200 page faults a second there.
pub fn tuneForLongRunning() void {
    if (builtin.os.tag != .linux or !builtin.abi.isGnu()) return;
    const M_TRIM_THRESHOLD = -1;
    const M_MMAP_THRESHOLD = -3;
    _ = mallopt(M_MMAP_THRESHOLD, 1024 * 1024);
    _ = mallopt(M_TRIM_THRESHOLD, 4 * 1024 * 1024);
}
