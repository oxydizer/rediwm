pub const Action = enum { poweroff, reboot, @"suspend" };
pub const Inhibitor = enum { lid, sleep };
pub const Event = enum { sleep, shutdown, lock, owner_changed };
pub const ActionError = enum { unknown_method, inhibited, authorization_required, denied, other };
pub const Api = struct { with_flags: bool = false, list_inhibitors: bool = false };

pub const SessionField = enum { id, uid, remote, desktop, kind, class, state };
pub const Request = union(enum) {
    session_for_pid: u32,
    session: []const u8,
    session_field: struct { path: []const u8, field: SessionField },
    list_sessions,
    locked_hint: struct { path: []const u8, locked: bool },
    capability: Action,
    action: struct { kind: Action, interactive: bool, with_flags: bool },
    inhibit: Inhibitor,
    list_inhibitors,
    inspect,
    owner,
};

pub const Target = struct {
    destination: []const u8,
    path: []const u8,
    interface: []const u8,
    member: []const u8,
    signature: []const u8 = "",
    flags: u8 = 0,
};
