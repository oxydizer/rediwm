//! Noninstalled ConsoleKit2 client for private-bus integration tests.
const std = @import("std");
const Service = @import("session/login_manager.zig").Service(@import("session/login_manager/consolekit.zig"));
const Bus = @import("session/login_bus.zig").Client(Service);

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // Only the private test bus, never an implicit system connection.
    const address = init.minimal.environ.getPosix("DBUS_SESSION_BUS_ADDRESS") orelse return error.NoPrivateBus;
    var bus = try Bus.init(allocator, address, address);
    defer bus.deinit();
    const args = init.minimal.args.vector;
    if (args.len > 2 and std.mem.eql(u8, std.mem.span(args[1]), "--user-bus")) {
        var env = try init.minimal.environ.createMap(allocator);
        defer env.deinit();
        bus.user_address = "";
        const user_bus = @import("session/user_bus.zig");
        var daemon = (try user_bus.ensure(init.io, allocator, &bus, &env, std.mem.span(args[2]))).?;
        defer daemon.stop(init.io);
        if (try user_bus.ensure(init.io, allocator, &bus, &env, std.mem.span(args[2])) != null) return error.DuplicateDaemon;
        var lease = try @import("session/private_publication.zig").Publication(Bus).init(allocator, &bus, "", "");
        defer lease.deinit();
        try lease.publish(&.{.{ .key = "WAYLAND_DISPLAY", .value = "wayland-fixture" }});
        // Model the supervisor reaping a failed private bus before final cleanup.
        try daemon.handle.signal(.TERM);
        var fds = [_]std.c.pollfd{.{ .fd = daemon.handle.fd, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 5000) != 1) return error.DaemonDidNotExit;
        if (@import("platform").child.reap(daemon.child.id.?) == null) return error.DaemonNotReaped;
        try @import("platform").login_io.writeAll(1, "private user bus ready\n");
        return;
    }
    const device = if (args.len > 1) std.mem.span(args[1]) else "/dev/ttyv0";
    const id = try bus.login(allocator, .{ .display_device = device });
    const text = try std.fmt.allocPrint(allocator, "verified {s}\n", .{id});
    try @import("platform").login_io.writeAll(1, text);
}
