//! Descriptors that wake a poll loop from another thread. Linux uses eventfd:
//! writing 8 bytes (a u64 count) makes the descriptor readable, reading 8 bytes
//! drains it.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

// std.os.linux issues Linux syscall numbers on any target, so a build for
// another OS must fail here and not ask its kernel something else.
comptime {
    if (builtin.os.tag != .linux)
        @compileError("platform.wake is not ported to this OS yet (docs/plans/freebsd.md, P.4)");
}

/// A new wake descriptor: close-on-exec, non-blocking, count zero. The caller
/// closes it. Null when the system refuses.
pub fn create() ?std.posix.fd_t {
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn readable(fd: std.posix.fd_t) bool {
    var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    return linux.errno(linux.poll(&fds, 1, 0)) == .SUCCESS and fds[0].revents != 0;
}

test "a wake descriptor turns readable when written and drains when read" {
    const fd = create().?;
    defer _ = linux.close(fd);
    try std.testing.expect(!readable(fd));
    const one: u64 = 1;
    try std.testing.expectEqual(@as(usize, 8), linux.write(fd, std.mem.asBytes(&one), 8));
    try std.testing.expect(readable(fd));
    var count: u64 = 0;
    try std.testing.expectEqual(@as(usize, 8), linux.read(fd, std.mem.asBytes(&count), 8));
    try std.testing.expectEqual(@as(u64, 1), count);
    try std.testing.expect(!readable(fd));
}
