//! Login service boundary shared by the supervisor, power policy and polkit.
//! The backend owns service names, method signatures and reply formats. The
//! callers own connection lifetime, authorization policy and stale-reply guards.
//! Selection is static: ConsoleKit2 replaces logind here in the next port step.
const dbus = @import("dbus");
const backend = @import("login_manager/logind.zig");
const types = @import("login_manager/types.zig");

pub const Action = types.Action;
pub const Inhibitor = types.Inhibitor;
pub const Request = types.Request;
pub const Event = types.Event;
pub const ActionError = types.ActionError;
pub const Api = types.Api;

/// `conn` can also be a recording transport in tests. There is no runtime
/// switch or test hook in the installed programs. An explicit destination pins
/// session and inhibitor requests to the owner whose generation the caller holds.
pub fn call(conn: anytype, request: Request, destination: ?[]const u8, owner: ?*anyopaque, callback: ?dbus.Connection.Callback, timeout_ms: u32) !u32 {
    var body: dbus.wire.Writer = .{ .allocator = conn.allocator };
    defer body.deinit();
    const target = try backend.encode(request, &body);
    return conn.callWithFlags(destination orelse target.destination, target.path, target.interface, target.member, target.signature, &body, owner, callback, timeout_ms, target.flags);
}

pub const login = @import("login_manager/logind_login.zig").login;
pub const conflict = @import("login_manager/logind_login.zig").conflict;
pub const commandArgv = backend.commandArgv;
pub const usesCommand = backend.usesCommand;
pub const signal = backend.signal;
pub const owner_match = backend.owner_match;
pub const changedOwner = backend.changedOwner;
pub const readSessionPath = backend.readSessionPath;
pub const readSessionId = backend.readSessionId;
pub const readApi = backend.readApi;
pub const actionError = backend.actionError;

test {
    _ = @import("login_manager/tests.zig");
}
