//! A console session needs a user bus even when the OS has no user manager.
//! Reuse a responding inherited bus; otherwise hold a private daemon until the
//! supervisor exits. The daemon survives compositor restarts as a preexisting child.
const std = @import("std");
const platform = @import("platform");
const sys = @import("login_sys.zig");

pub const Daemon = struct {
    child: std.process.Child,
    handle: platform.child.Handle,
    socket_path: [:0]const u8,
    pub fn stop(self: *Daemon, io: std.Io) void {
        defer self.handle.close();
        // The supervisor may already have reaped a failed bus as an adopted
        // child. Never hand its potentially reused numeric pid to Child.kill.
        if (self.handle.exited()) {
            _ = platform.child.reap(self.child.id.?);
            self.child.id = null;
        } else self.child.kill(io);
        sys.unlinkZ(self.socket_path) catch {};
    }
};

pub fn ensure(io: std.Io, arena: std.mem.Allocator, bus: anytype, env: *std.process.Environ.Map, runtime: []const u8) !?Daemon {
    if (bus.user_address.len != 0 and bus.userReady()) {
        try env.put("DBUS_SESSION_BUS_ADDRESS", bus.user_address);
        return null;
    }
    const socket_path = try std.fmt.allocPrintSentinel(arena, "{s}/rediwm-bus-{d}", .{ runtime, std.c.getpid() }, 0);
    if (socket_path.len >= @sizeOf(@FieldType(std.posix.sockaddr.un, "path"))) return error.RuntimePathTooLong;
    const address = try std.fmt.allocPrint(arena, "unix:path={s}", .{socket_path});
    const argument = try std.fmt.allocPrint(arena, "--address={s}", .{address});
    var child = try std.process.spawn(io, .{
        .argv = &.{ "dbus-daemon", "--session", "--nofork", "--nopidfile", "--print-address=1", argument },
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .pipe,
    });
    errdefer {
        child.kill(io);
        sys.unlinkZ(socket_path) catch {};
    }
    const output = child.stdout.?;
    defer output.close(io);
    child.stdout = null;
    var text: [1024]u8 = undefined;
    var used: usize = 0;
    const deadline = sys.monotonicMs() + 5000;
    while (true) {
        const remaining = deadline - sys.monotonicMs();
        if (remaining <= 0 or used == text.len) return error.SessionBusNotReady;
        var fds = [_]std.c.pollfd{.{ .fd = output.handle, .events = std.c.POLL.IN, .revents = 0 }};
        if (try sys.retry(std.c.poll, .{ &fds, 1, @as(c_int, @intCast(remaining)) }) == 0) return error.SessionBusNotReady;
        const n = try sys.retry(std.c.read, .{ output.handle, text[used..].ptr, text.len - used });
        if (n == 0) return error.SessionBusNotReady;
        used += n;
        if (std.mem.indexOfScalar(u8, text[0..used], '\n') != null) break;
    }
    bus.user_address = address;
    if (!bus.userReady()) return error.SessionBusNotReady;
    try env.put("DBUS_SESSION_BUS_ADDRESS", address);
    const handle = try platform.child.Handle.open(child.id.?);
    bus.owns_user_bus = true;
    return .{ .child = child, .handle = handle, .socket_path = socket_path };
}
