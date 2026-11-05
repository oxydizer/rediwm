//! Facts about the running system that differ between operating systems.
const std = @import("std");
const builtin = @import("builtin");

/// Time since boot, suspended time included where the system counts it:
/// Linux's CLOCK_BOOTTIME, FreeBSD's CLOCK_UPTIME.
pub const boot_clock: std.posix.clockid_t = switch (builtin.os.tag) {
    .linux => .BOOTTIME,
    .freebsd => .UPTIME,
    else => @compileError("platform.system is not ported to this OS yet (docs/plans/freebsd.md, phase 1)"),
};

test "the boot clock reads a time" {
    var ts: std.posix.timespec = undefined;
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(std.posix.system.clock_gettime(boot_clock, &ts)));
    try std.testing.expect(ts.sec > 0);
}
