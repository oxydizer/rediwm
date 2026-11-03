//! Privileged account helper requests and their asynchronous lifetime.
const std = @import("std");
const i18n = @import("i18n");
const panel = @import("../panel.zig");
const Child = @import("../../session/child.zig");
const gpa = @import("../../main.zig").gpa;
const platform = @import("platform");
const c = @import("c");
extern fn rediwm_polkit_clear([*]u8, usize) void;

pub const AuthRequest = struct {
    allocator: std.mem.Allocator,
    cc: ?*panel.ControlCenter,
    io: std.Io,
    child: *Child,
    is_authorization: bool,
};

pub fn startHelper(cc: *panel.ControlCenter, request: anytype, is_authorization: bool) !void {
    if (cc.users.auth != null) return;
    const req = try gpa.create(AuthRequest);
    errdefer gpa.destroy(req);
    req.* = .{ .allocator = gpa, .cc = cc, .io = cc.server.io, .child = undefined, .is_authorization = is_authorization };
    const encoded = try std.json.Stringify.valueAlloc(gpa, request, .{});
    const contains_secret = comptime @hasField(@TypeOf(request), "password");
    defer {
        if (contains_secret) rediwm_polkit_clear(encoded.ptr, encoded.len);
        gpa.free(encoded);
    }
    var sockets: [2]c_int = undefined;
    if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &sockets) != 0) return error.SocketPairFailed;
    defer {
        if (sockets[0] >= 0) _ = c.close(sockets[0]);
        if (sockets[1] >= 0) _ = c.close(sockets[1]);
    }

    const executable = platform.tool.system(cc.server.io, "pkexec") orelse return error.FileNotFound;
    var child = try std.process.spawn(cc.server.io, .{
        .argv = &.{ executable, "--disable-internal-agent", @import("install_paths").bin ++ "/rediwm-accounts-helper" },
        .stdin = .{ .file = .{ .handle = sockets[0], .flags = .{ .nonblocking = false } } },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    errdefer {
        child.kill(cc.server.io);
    }
    _ = c.close(sockets[0]);
    sockets[0] = -1;
    var written: usize = 0;
    while (written < encoded.len) {
        const n = c.send(sockets[1], encoded.ptr + written, encoded.len - written, c.MSG_NOSIGNAL);
        if (n <= 0) return error.RequestWriteFailed;
        written += @intCast(n);
    }
    _ = c.close(sockets[1]);
    sockets[1] = -1;
    req.child = try Child.watch(gpa, cc.server.wl_server.getEventLoop(), child.id.?, req, authReady);
    cc.users.auth = req;
    cc.users.message = "";
    cc.refresh();
}

fn authReady(owner: ?*anyopaque, _: *Child, status: ?u32) void {
    const req: *AuthRequest = @ptrCast(@alignCast(owner.?));
    if (req.cc) |cc| {
        if (cc.users.auth == req) {
            cc.users.auth = null;
            if (status != null and status.? == 0) {
                if (req.is_authorization) {
                    cc.users.unlocked = true;
                    cc.users.message = "";
                } else {
                    cc.users.message = i18n.tr("Changes saved.");
                }
            } else {
                if (req.is_authorization) {
                    cc.users.unlocked = false;
                    cc.users.message = i18n.tr("Authentication was cancelled or denied.");
                } else {
                    cc.users.message = i18n.tr("No changes were made. Authentication was cancelled or the request failed.");
                }
            }
            cc.refresh();
        }
    }
    req.allocator.destroy(req);
}

/// Stop a pending pkexec when its Settings window closes.
pub fn cancelAuthorization(cc: *panel.ControlCenter) void {
    if (cc.users.auth) |req| {
        cc.users.auth = null;
        req.cc = null;
        req.child.signal(.TERM);
        req.child.detach();
        req.allocator.destroy(req);
    }
}
