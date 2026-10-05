//! Obtain a connection labelled by security-context-v1, then discard the
//! unrestricted connection and the listener before any PDF is parsed.
const std = @import("std");
const wl = @import("wayland").client.wl;
const wp = @import("wayland").client.wp;
const c = @import("c.zig").api;

const Registry = struct {
    manager: ?*wp.SecurityContextManagerV1 = null,

    fn event(registry: *wl.Registry, ev: wl.Registry.Event, self: *Registry) void {
        switch (ev) {
            .global => |g| {
                if (std.mem.eql(u8, std.mem.span(g.interface), "wp_security_context_manager_v1"))
                    self.manager = registry.bind(g.name, wp.SecurityContextManagerV1, 1) catch null;
            },
            else => {},
        }
    }
};

pub fn connect() !*wl.Display {
    const control = try wl.Display.connect(null);
    defer control.disconnect();
    const registry = try control.getRegistry();
    defer registry.destroy();
    var state: Registry = .{};
    registry.setListener(*Registry, Registry.event, &state);
    if (control.roundtrip() != .SUCCESS) return error.DisplayFailed;
    const manager = state.manager orelse return error.SecurityContextUnavailable;
    defer manager.destroy();

    var directory = "/tmp/rediwm-pdf-XXXXXX".*;
    if (c.mkdtemp(&directory) == null) return error.SocketFailed;
    defer _ = c.rmdir(&directory);
    var path_storage: [108]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_storage, "{s}/wayland", .{directory});
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    @memcpy(@as([*]u8, @ptrCast(&address.sun_path))[0..path.len], path);

    const listener = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (listener < 0) return error.SocketFailed;
    defer _ = c.close(listener);
    if (std.posix.system.bind(listener, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)) != 0) return error.SocketFailed;
    defer _ = c.unlink(path.ptr);
    if (c.listen(listener, 1) != 0) return error.SocketFailed;
    var close_pipe: [2]c_int = undefined;
    if (c.pipe2(&close_pipe, c.O_CLOEXEC) != 0) return error.SocketFailed;
    defer _ = c.close(close_pipe[0]);
    defer _ = c.close(close_pipe[1]);

    const context = try manager.createListener(listener, close_pipe[0]);
    context.setSandboxEngine("org.rediwm.pdf");
    context.setAppId("rediwm-pdf");
    context.commit();
    context.destroy();
    if (control.roundtrip() != .SUCCESS) return error.DisplayFailed;

    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    if (std.posix.system.connect(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)) != 0) {
        _ = c.close(fd);
        return error.SocketFailed;
    }
    // connectToFd takes ownership, including on failure.
    const display = try wl.Display.connectToFd(fd);
    errdefer display.disconnect();
    // Ensure acceptance before closing the pipe removes the listener.
    // Existing clients retain their security context.
    if (display.roundtrip() != .SUCCESS) return error.DisplayFailed;
    return display;
}
