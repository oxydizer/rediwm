//! ConsoleKit2 2.x. Protocol checked against upstream's Manager/Session XML.
//! Session identities are object paths (also what polkit's unix-session uses).
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const types = @import("types.zig");
const name = "org.freedesktop.ConsoleKit";
const path = "/org/freedesktop/ConsoleKit/Manager";
const manager = name ++ ".Manager";
const session = name ++ ".Session";
const bus = "org.freedesktop.DBus";
const bus_path = "/org/freedesktop/DBus";
pub const owns_session = true;
pub const login = @import("consolekit_login.zig").login;
pub const conflict = @import("consolekit_login.zig").conflict;
pub const release = @import("consolekit_login.zig").release;
pub const owner_match = "type='signal',sender='org.freedesktop.DBus',path='/org/freedesktop/DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.freedesktop.ConsoleKit'";

pub fn encode(request: types.Request, body: *wire.Writer) !types.Target {
    var target: types.Target = .{ .destination = name, .path = path, .interface = manager, .member = "" };
    switch (request) {
        .session_for_pid => |pid| {
            target.member = "GetSessionForUnixProcess";
            target.signature = "u";
            try body.uint32(pid);
        },
        .session => |id| {
            target.member = "GetSession";
            target.signature = "s";
            // GetId returns a path, but Manager.GetSession takes the short id.
            const prefix = "/org/freedesktop/ConsoleKit/";
            if (!std.mem.startsWith(u8, id, prefix) or id.len == prefix.len or std.mem.indexOfScalar(u8, id[prefix.len..], '/') != null) return error.InvalidSession;
            try body.string(id[prefix.len..]);
        },
        .session_field => |field| {
            target.path = field.path;
            target.interface = session;
            target.member = switch (field.field) {
                .id => "GetId",
                .uid => "GetUnixUser",
                .remote => "GetRemoteHostName",
                .local => "IsLocal",
                .kind => "GetSessionType",
                .class => "GetSessionClass",
                .state => "GetSessionState",
                .desktop => return error.Unsupported,
            };
        },
        .list_sessions => target.member = "GetSessions",
        .locked_hint => |hint| {
            target.path = hint.path;
            target.interface = session;
            target.member = "SetLockedHint";
            target.signature = "b";
            try body.boolean(hint.locked);
        },
        .capability => |kind| target.member = switch (kind) {
            .poweroff => "CanPowerOff",
            .reboot => "CanReboot",
            .@"suspend" => "CanSuspend",
        },
        .action => |action| {
            target.member = switch (action.kind) {
                .poweroff => "PowerOff",
                .reboot => "Reboot",
                .@"suspend" => "Suspend",
            };
            target.signature = "b";
            target.flags = if (action.interactive) wire.flag_allow_interactive_authorization else 0;
            try body.boolean(action.interactive);
        },
        .inhibit => |which| {
            target.member = "Inhibit";
            target.signature = "ssss";
            const args: [4][]const u8 = switch (which) {
                .lid => .{ "handle-lid-switch", "RediWM", "RediWM manages lid actions", "block" },
                .sleep => .{ "sleep", "RediWM", "Lock the screen before sleep", "delay" },
            };
            for (args) |arg| try body.string(arg);
        },
        .list_inhibitors => target.member = "ListInhibitors",
        .inspect => {
            target.interface = "org.freedesktop.DBus.Introspectable";
            target.member = "Introspect";
        },
        .owner => {
            target.destination = bus;
            target.path = bus_path;
            target.interface = bus;
            target.member = "GetNameOwner";
            target.signature = "s";
            try body.string(name);
        },
        .open_session => |context| {
            target.member = "OpenSessionWithParameters";
            target.signature = "a(sv)";
            const array = try body.beginArray(8);
            const parameters = [_][2][]const u8{
                .{ "session-type", "wayland" },                .{ "session-class", "user" },
                .{ "display-device", context.display_device }, .{ "remote-host-name", "" },
            };
            for (parameters) |parameter| {
                try body.alignTo(8);
                try body.string(parameter[0]);
                try body.variant("s");
                try body.string(parameter[1]);
            }
            try body.endArray(array);
        },
        .session_for_cookie, .close_session => |cookie| {
            target.member = if (request == .session_for_cookie) "GetSessionForCookie" else "CloseSession";
            target.signature = "s";
            try body.string(cookie);
        },
    }
    return target;
}

pub fn signal(event: types.Event, sender: ?[]const u8, owner: ?*anyopaque, callback: dbus.Connection.Signal) dbus.Connection.SignalHandler {
    return .{
        .sender = if (event == .owner_changed) bus else sender,
        .path = switch (event) {
            .lock => null,
            .owner_changed => bus_path,
            else => path,
        },
        .interface = switch (event) {
            .lock => session,
            .owner_changed => bus,
            else => manager,
        },
        .member = switch (event) {
            .sleep => "PrepareForSleep",
            .shutdown => "PrepareForShutdown",
            .lock => "Lock",
            .owner_changed => "NameOwnerChanged",
        },
        .owner = owner,
        .callback = callback,
    };
}

pub fn changedOwner(msg: wire.Message) !?[]const u8 {
    var body = msg.body;
    if (!std.mem.eql(u8, try body.string(), name)) return null;
    _ = try body.string();
    return try body.string();
}

pub fn readSessionPath(msg: wire.Message) ![]const u8 {
    if (msg.kind != .method_return) return error.Refused;
    if (!std.mem.eql(u8, msg.headers.signature, "o")) return error.InvalidReply;
    var body = msg.body;
    return body.objectPath();
}
pub const readSessionId = readSessionPath;

pub fn readApi(msg: wire.Message) types.Api {
    if (msg.kind != .method_return) return .{};
    var body = msg.body;
    const xml = body.string() catch return .{};
    return .{ .list_inhibitors = std.mem.indexOf(u8, xml, "ListInhibitors") != null };
}

pub fn actionError(error_name: []const u8) types.ActionError {
    const eq = std.mem.eql;
    if (eq(u8, error_name, bus ++ ".Error.UnknownMethod")) return .unknown_method;
    if (eq(u8, error_name, manager ++ ".Error.Inhibited")) return .inhibited;
    if (eq(u8, error_name, manager ++ ".Error.AuthorizationRequired") or eq(u8, error_name, bus ++ ".Error.InteractiveAuthorizationRequired")) return .authorization_required;
    if (eq(u8, error_name, manager ++ ".Error.InsufficientPermission") or eq(u8, error_name, bus ++ ".Error.AccessDenied")) return .denied;
    return .other;
}

pub fn usesCommand(_: types.Action) bool {
    return false;
}
pub fn commandArgv(_: *[4][]const u8, _: types.Action, _: bool, _: bool) ?[]const []const u8 {
    return null;
}
