//! Login service boundary shared by the supervisor, power policy and polkit.
//! The backend owns service names, method signatures and reply formats. The
//! callers own connection lifetime, authorization policy and stale-reply guards.
//! Selection is static: logind on Linux, ConsoleKit2 on FreeBSD.
const dbus = @import("dbus");
const backend = switch (@import("builtin").os.tag) {
    .freebsd => @import("login_manager/consolekit.zig"),
    else => @import("login_manager/logind.zig"),
};
const types = @import("login_manager/types.zig");

pub const Action = types.Action;
pub const Inhibitor = types.Inhibitor;
pub const Request = types.Request;
pub const Event = types.Event;
pub const ActionError = types.ActionError;
pub const Api = types.Api;
pub const Context = types.Context;

pub fn Service(comptime implementation: type) type {
    return struct {
        /// A recording transport can replace conn; no installed runtime hook.
        /// Explicit destinations pin requests to the owner's current generation.
        pub fn call(conn: anytype, request: Request, destination: ?[]const u8, owner: ?*anyopaque, callback: ?dbus.Connection.Callback, timeout_ms: u32) !u32 {
            var body: dbus.wire.Writer = .{ .allocator = conn.allocator };
            defer body.deinit();
            const target = try implementation.encode(request, &body);
            return conn.callWithFlags(destination orelse target.destination, target.path, target.interface, target.member, target.signature, &body, owner, callback, timeout_ms, target.flags);
        }
        pub fn commandArgv(buf: *[4][]const u8, kind: Action, ask_password: bool, no_block: bool) ?[]const []const u8 {
            return implementation.commandArgv(buf, kind, ask_password, no_block);
        }
        pub const login = implementation.login;
        pub const conflict = implementation.conflict;
        pub const release = implementation.release;
        pub const usesCommand = implementation.usesCommand;
        pub const signal = implementation.signal;
        pub const owner_match = implementation.owner_match;
        pub const changedOwner = implementation.changedOwner;
        pub const readSessionPath = implementation.readSessionPath;
        pub const readSessionId = implementation.readSessionId;
        pub const readApi = implementation.readApi;
        pub const actionError = implementation.actionError;
        pub const owns_session = implementation.owns_session;
    };
}

const Native = Service(backend);
pub const call = Native.call;
pub const commandArgv = Native.commandArgv;
pub const login = Native.login;
pub const conflict = Native.conflict;
pub const release = Native.release;
pub const usesCommand = Native.usesCommand;
pub const signal = Native.signal;
pub const owner_match = Native.owner_match;
pub const changedOwner = Native.changedOwner;
pub const readSessionPath = Native.readSessionPath;
pub const readSessionId = Native.readSessionId;
pub const readApi = Native.readApi;
pub const actionError = Native.actionError;
pub const owns_session = Native.owns_session;

test {
    _ = @import("login_manager/tests.zig");
    _ = @import("login_manager/consolekit_tests.zig");
}
