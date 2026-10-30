//! Kernel power-supply event transport. Snapshots remain in taskbar/battery.zig.
const std = @import("std");
const linux = std.os.linux;

/// Nonblocking socket on the kernel's uevent multicast group; `null` leaves
/// only the minute poll. Receiving needs no privileges, and sending to the
/// group does, so nothing unprivileged can fake these (they only trigger a
/// sysfs read anyway).
pub fn openUeventSocket() ?std.posix.fd_t {
    const rc = std.posix.system.socket(linux.AF.NETLINK, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, linux.NETLINK.KOBJECT_UEVENT);
    // The platform uses libc here; failures use -1/errno.
    if (rc < 0) return null;
    const fd: std.posix.fd_t = @intCast(rc);
    const addr: linux.sockaddr.nl = .{ .pid = 0, .groups = 1 };
    if (std.posix.system.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.nl)) < 0) {
        _ = std.posix.system.close(fd);
        return null;
    }
    return fd;
}

/// Empties the socket. True when any message could change `read`'s result,
/// including an overflow that may have dropped one.
pub fn drainUevents(fd: std.posix.fd_t) bool {
    var relevant = false;
    var buf: [8192]u8 = undefined;
    while (true) {
        const rc = std.posix.system.recvfrom(fd, &buf, buf.len, 0, null, null);
        switch (std.posix.errno(rc)) {
            .SUCCESS => if (isSystemPowerSupplyUevent(buf[0..@intCast(rc)])) {
                relevant = true;
            },
            .INTR => {},
            .NOBUFS => relevant = true,
            else => return relevant,
        }
    }
}

/// Kernel uevents are `action@devpath` then NUL-separated KEY=VALUE pairs.
/// Peripheral batteries are ignored by `read`, so their events are too.
pub fn isSystemPowerSupplyUevent(msg: []const u8) bool {
    var fields = std.mem.splitScalar(u8, msg, 0);
    if (std.mem.indexOfScalar(u8, fields.first(), '@') == null) return false;
    var power_supply = false;
    while (fields.next()) |kv| {
        if (std.mem.eql(u8, kv, "SUBSYSTEM=power_supply")) power_supply = true;
        if (std.mem.eql(u8, kv, "POWER_SUPPLY_SCOPE=Device")) return false;
    }
    return power_supply;
}
