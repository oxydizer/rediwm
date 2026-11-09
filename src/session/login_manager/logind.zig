//! logind/elogind wire protocol. Keep Linux behavior here when adding backends.
const std = @import("std");
const dbus = @import("dbus");
const wire = dbus.wire;
const types = @import("types.zig");
const Action = types.Action;
const name = "org.freedesktop.login1";
const path = "/org/freedesktop/login1";
const manager = name ++ ".Manager";
const session = name ++ ".Session";
const bus = "org.freedesktop.DBus";
const bus_path = "/org/freedesktop/DBus";

pub const owner_match = "type='signal',sender='org.freedesktop.DBus',path='/org/freedesktop/DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.freedesktop.login1'";

pub fn encode(request: types.Request, body: *wire.Writer) !types.Target {
    var target: types.Target = .{ .destination = name, .path = path, .interface = manager, .member = "" };
    switch (request) {
        .session_for_pid => |pid| {
            target.member = "GetSessionByPID";
            target.signature = "u";
            try body.uint32(pid);
        },
        .session => |id| {
            target.member = "GetSession";
            target.signature = "s";
            try body.string(id);
        },
        .session_field => |field| {
            target.path = field.path;
            target.interface = "org.freedesktop.DBus.Properties";
            target.member = "Get";
            target.signature = "ss";
            try body.string(session);
            try body.string(switch (field.field) {
                .id => "Id",
                .uid => "User",
                .remote => "Remote",
                .desktop => "Desktop",
                .kind => "Type",
                .class => "Class",
                .state => "State",
            });
        },
        .list_sessions => target.member = "ListSessions",
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
            target.flags = if (action.interactive) wire.flag_allow_interactive_authorization else 0;
            if (action.with_flags) {
                target.member = switch (action.kind) {
                    .poweroff => "PowerOffWithFlags",
                    .reboot => "RebootWithFlags",
                    .@"suspend" => "SuspendWithFlags",
                };
                target.signature = "t";
                // SD_LOGIND_ROOT_CHECK_INHIBITORS: never bypass inhibitor locks.
                try body.uint64(1 << 0);
            } else {
                target.member = switch (action.kind) {
                    .poweroff => "PowerOff",
                    .reboot => "Reboot",
                    .@"suspend" => "Suspend",
                };
                target.signature = "b";
                try body.boolean(action.interactive);
            }
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

fn returned(msg: wire.Message, signature: []const u8) !wire.Reader {
    if (msg.kind != .method_return) return error.Refused;
    if (!std.mem.eql(u8, msg.headers.signature, signature)) return error.InvalidReply;
    return msg.body;
}

pub fn readSessionPath(msg: wire.Message) ![]const u8 {
    var body = try returned(msg, "o");
    return body.objectPath();
}

pub fn readSessionId(msg: wire.Message) ![]const u8 {
    var body = try returned(msg, "v");
    if (!std.mem.eql(u8, try body.variant(), "s")) return error.InvalidReply;
    return body.string();
}

pub fn readApi(msg: wire.Message) types.Api {
    if (msg.kind != .method_return) return .{};
    var body = msg.body;
    const xml = body.string() catch return .{};
    return .{
        .with_flags = std.mem.indexOf(u8, xml, "SuspendWithFlags") != null,
        .list_inhibitors = std.mem.indexOf(u8, xml, "ListInhibitors") != null,
    };
}

pub fn actionError(error_name: []const u8) types.ActionError {
    const eq = std.mem.eql;
    if (eq(u8, error_name, bus ++ ".Error.UnknownMethod")) return .unknown_method;
    if (eq(u8, error_name, name ++ ".OperationInhibited") or eq(u8, error_name, name ++ ".BlockedByInhibitorLock")) return .inhibited;
    if (eq(u8, error_name, bus ++ ".Error.InteractiveAuthorizationRequired")) return .authorization_required;
    if (eq(u8, error_name, bus ++ ".Error.AccessDenied") or eq(u8, error_name, name ++ ".NotEnoughPrivileges")) return .denied;
    return .other;
}

pub fn usesCommand(kind: Action) bool {
    return kind != .@"suspend";
}

/// systemctl requires systemd as init; elogind's loginctl has no --no-block.
pub fn commandArgv(buf: *[4][]const u8, kind: Action, ask_password: bool, no_block: bool) []const []const u8 {
    std.debug.assert(usesCommand(kind));
    const systemd = std.posix.system.access("/run/systemd/system", std.posix.F_OK) == 0;
    buf[0] = if (systemd) "systemctl" else "loginctl";
    buf[1] = @tagName(kind);
    var len: usize = 2;
    if (!ask_password) {
        buf[len] = "--no-ask-password";
        len += 1;
    }
    if (no_block and systemd) {
        buf[len] = "--no-block";
        len += 1;
    }
    return buf[0..len];
}
