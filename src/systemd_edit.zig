//! Authorized Type= edits. systemctl owns atomic file replacement; we only
//! replace our dedicated drop-in, then let the D-Bus client reload its owner.
const std = @import("std");
const systemd = @import("systemd.zig");
const gpa = @import("main.zig").gpa;
const Child = @import("session/child.zig");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("unistd.h");
});

pub const Request = struct {
    client: *systemd.Client,
    io: std.Io,
    child: *Child,

    fn destroy(self: *Request) void {
        self.child.detach();
        gpa.destroy(self);
    }
};

pub fn start(client: *systemd.Client, unit: []const u8, value: []const u8) !void {
    // No paths, patterns or option-like unit names may reach privileged edit.
    if (unit.len <= ".service".len or unit.len > 255 or unit[0] == '-' or
        !std.mem.endsWith(u8, unit, ".service") or systemd.typeIndex(value) == null) return error.InvalidSetting;
    for (unit) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "_.:@-\\", ch) == null) return error.InvalidUnit;
    const req = try gpa.create(Request);
    errdefer gpa.destroy(req);
    req.* = .{ .client = client, .io = client.server.io, .child = undefined };
    var sockets: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &sockets) != 0) return error.SocketPairFailed;
    defer {
        if (sockets[0] >= 0) _ = c.close(sockets[0]);
        if (sockets[1] >= 0) _ = c.close(sockets[1]);
    }
    const pkexec = if (c.access("/usr/bin/pkexec", c.X_OK) == 0) "/usr/bin/pkexec" else "/bin/pkexec";
    const systemctl = if (c.access("/usr/bin/systemctl", c.X_OK) == 0) "/usr/bin/systemctl" else "/bin/systemctl";
    var child = try std.process.spawn(req.io, .{
        .argv = &.{ pkexec, "--disable-internal-agent", systemctl, "--system", "--no-reload", "--stdin", "--drop-in=zz-rediwm-notify.conf", "edit", "--", unit },
        .stdin = .{ .file = .{ .handle = sockets[0], .flags = .{ .nonblocking = false } } },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer {
        child.kill(req.io);
    }
    _ = c.close(sockets[0]);
    sockets[0] = -1;
    var buffer: [64]u8 = undefined;
    const contents = try std.fmt.bufPrint(&buffer, "[Service]\nType={s}\n", .{value});
    var written: usize = 0;
    while (written < contents.len) {
        const n = c.send(sockets[1], contents.ptr + written, contents.len - written, c.MSG_NOSIGNAL);
        if (n <= 0) return error.RequestWriteFailed;
        written += @intCast(n);
    }
    _ = c.close(sockets[1]);
    sockets[1] = -1;
    req.child = try Child.watch(gpa, client.server.wl_server.getEventLoop(), child.id.?, req, ready);
    client.edit_request = req;
}

fn ready(owner: ?*anyopaque, _: *Child, result: ?u32) void {
    const req: *Request = @ptrCast(@alignCast(owner.?));
    const client = req.client;
    client.edit_request = null;
    const status: i32 = if (result) |raw| if (raw & 0x7f == 0) @intCast((raw >> 8) & 0xff) else -1 else -1;
    req.destroy();
    client.edited(status);
}

pub fn cancel(client: *systemd.Client) void {
    const req = client.edit_request orelse return;
    client.edit_request = null;
    // pidfd prevents sending a signal to a reused PID. pkexec execs systemctl.
    req.child.signal(.KILL);
    req.destroy();
}
