//! Descriptors that wake a poll loop from another thread. Both systems use
//! eventfd: writing 8 bytes (a u64 count) makes the descriptor readable,
//! reading 8 bytes drains it.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

// std.os.linux issues Linux syscall numbers on any target, so a build for
// another OS must fail here and not ask its kernel something else.
comptime {
    if (builtin.os.tag != .linux and builtin.os.tag != .freebsd)
        @compileError("platform.wake is not ported to this OS yet (docs/plans/freebsd.md, P.4)");
}

/// A new wake descriptor: close-on-exec, non-blocking, count zero. The caller
/// closes it. Null when the system refuses.
pub fn create() ?std.posix.fd_t {
    switch (builtin.os.tag) {
        .linux => {
            const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
            if (linux.errno(rc) != .SUCCESS) return null;
            return @intCast(rc);
        },
        .freebsd => {
            // EFD_NONBLOCK is O_NONBLOCK and EFD_CLOEXEC is O_CLOEXEC (sys/eventfd.h).
            const fd = std.c.eventfd(0, 0x00000004 | 0x00100000);
            return if (fd < 0) null else fd;
        },
        else => unreachable,
    }
}

test "a wake descriptor turns readable when written and drains when read" {
    const sys = std.posix.system;
    const fd = create().?;
    defer _ = sys.close(fd);
    try std.testing.expect(!readable(fd));
    const one: u64 = 1;
    try std.testing.expectEqual(@as(usize, 8), @as(usize, @intCast(sys.write(fd, std.mem.asBytes(&one), 8))));
    try std.testing.expect(readable(fd));
    var count: u64 = 0;
    try std.testing.expectEqual(@as(usize, 8), @as(usize, @intCast(sys.read(fd, std.mem.asBytes(&count), 8))));
    try std.testing.expectEqual(@as(u64, 1), count);
    try std.testing.expect(!readable(fd));
}

fn readable(fd: std.posix.fd_t) bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    return std.posix.errno(std.posix.system.poll(&fds, 1, 0)) == .SUCCESS and fds[0].revents != 0;
}
