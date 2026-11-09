//! Poweroff/reboot through systemctl (like DMS), or loginctl where systemd is
//! not init (elogind, e.g. Artix); suspend through logind.
//! FreeBSD's ConsoleKit2 backend sends all three actions over the system bus.
//! Capability probes and preparation signals still use the system bus.
//! Requests run as the logged-in user, with normal authorization and inhibitor
//! checks. Automatic power commands use --no-ask-password. Suspend uses
//! SuspendWithFlags with inhibitor checks, falling back to legacy Suspend.
//! Preparation does not log out: the session manager sends SIGTERM when ready.
//!
//! With `lock_on_suspend` a "sleep" delay inhibitor is held, so logind waits
//! until the lock covers every output before the system sleeps. A verified
//! login (REDIWM_LOGIN_SESSION) also follows logind's Lock request and keeps
//! the session's LockedHint current. logind's Unlock is deliberately ignored:
//! only the lock screen's own authentication ends a lock.
const i18n = @import("i18n");
const std = @import("std");
const Child = @import("child.zig");
const wl = @import("wayland").server.wl;

const dbus = @import("dbus");
const wire = dbus.wire;
const Server = @import("../Server.zig");
const Lock = @import("lock.zig").Lock;
const power_inhibitors = @import("power_inhibitors.zig");
const power_session = @import("power_session.zig");
const power_capabilities = @import("power_capabilities.zig");
const power_bus = @import("power_bus.zig");
const power_requests = @import("power_requests.zig");

const log = std.log.scoped(.power);
const login = @import("login_manager.zig");

pub const call_timeout_ms: u32 = 5000;
/// How long PrepareForSleep waits for the lock to reach the screen. logind
/// itself gives up on delay inhibitors after InhibitDelayMaxSec (5 s default).
pub const sleep_lock_timeout_ms: i32 = 2000;

pub const Kind = enum {
    poweroff,
    reboot,
    @"suspend",

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .poweroff => i18n.tr("Power off"),
            .reboot => i18n.tr("Restart"),
            .@"suspend" => i18n.tr("Suspend"),
        };
    }
    pub fn loginAction(self: Kind) login.Action {
        return switch (self) {
            .poweroff => .poweroff,
            .reboot => .reboot,
            .@"suspend" => .@"suspend",
        };
    }
    pub fn inhibitorType(self: Kind) []const u8 {
        return switch (self) {
            .poweroff, .reboot => "shutdown",
            .@"suspend" => "sleep",
        };
    }
};

pub const Capability = enum {
    unknown,
    yes,
    challenge,
    no,
    na,

    pub fn isAvailable(self: Capability) bool {
        return switch (self) {
            .no, .na => false,
            .unknown, .yes, .challenge => true,
        };
    }

    pub fn parse(text: []const u8) Capability {
        return std.meta.stringToEnum(Capability, text) orelse .unknown;
    }
};

pub const Request = struct {
    kind: Kind,
    interactive: bool,
};

/// The poweroff/reboot command line, written into `buf`. systemctl needs
/// systemd as init (sd_booted's `/run/systemd/system` test); elogind systems
/// have these verbs in loginctl, which only asks logind and never waits for
/// the job, so it has no --no-block.
pub fn commandArgv(buf: *[4][]const u8, kind: Kind, ask_password: bool, no_block: bool) ?[]const []const u8 {
    return login.commandArgv(buf, kind.loginAction(), ask_password, no_block);
}

/// Only one request may be in flight; a second action while one is
/// pending is reported and dropped rather than queued. There is no automatic
/// retry after a lost connection — the next explicit user action reconnects.
pub const Manager = struct {
    server: *Server,
    allocator: std.mem.Allocator,
    conn: ?*dbus.Connection = null,
    signal_sender: ?[]const u8 = null,
    hello_done: bool = false,
    introspect_done: bool = false,
    has_with_flags: bool = false,
    has_list_inhibitors: bool = false,
    can_poweroff: Capability = .unknown,
    can_reboot: Capability = .unknown,
    can_suspend: Capability = .unknown,
    probing: bool = false,
    probe_replies_pending: u8 = 0,
    want_probe: bool = false,
    pending: ?Request = null,
    command_child: ?*Child = null,
    /// argv[0] of `command_child`, for its log lines.
    command_tool: []const u8 = "",
    closing: bool = false,
    lid_fd: ?std.posix.fd_t = null,
    lid_pending: bool = false,
    /// The "sleep" delay inhibitor held while `lock_on_suspend` is on.
    sleep_fd: ?std.posix.fd_t = null,
    sleep_pending: bool = false,
    /// PrepareForSleep(true) until the lock covers every output.
    sleep_waiting: bool = false,
    sleep_timer: ?*wl.EventSource = null,
    /// This login's logind session object, for Lock and LockedHint.
    session_path: ?[]u8 = null,
    session_pending: bool = false,
    /// What the lock last announced, and what logind was last told.
    locked: bool = false,
    locked_hint: ?bool = null,
    owner_generation: u64 = 0,
    owner_changed: bool = false,

    pub const Inhibitor = login.Inhibitor;
    pub const OwnerRequest = struct { manager: *Manager, generation: u64, inhibitor: Inhibitor = .lid };

    pub const wantsInhibitor = power_inhibitors.wantsInhibitor;
    pub const inhibitorFd = power_inhibitors.inhibitorFd;
    pub const inhibitorPending = power_inhibitors.inhibitorPending;
    pub const releaseInhibitor = power_inhibitors.releaseInhibitor;
    pub const syncInhibitors = power_inhibitors.syncInhibitors;
    pub const acquireInhibitor = power_inhibitors.acquireInhibitor;
    pub const resetSignalOwner = power_inhibitors.resetSignalOwner;
    pub const lockForSleep = power_inhibitors.lockForSleep;
    pub const lockCovered = power_inhibitors.lockCovered;
    pub const finishSleepWait = power_inhibitors.finishSleepWait;
    pub const lockChanged = power_inhibitors.lockChanged;

    // ---- lock before sleep, logind Lock and LockedHint --------------------

    pub const watchSession = power_session.watchSession;
    pub const forgetSession = power_session.forgetSession;
    pub const syncLockedHint = power_session.syncLockedHint;
    pub const onDisconnect = power_session.onDisconnect;
    pub const watchSignalOwner = power_session.watchSignalOwner;

    pub fn create(server: *Server, allocator: std.mem.Allocator) !*Manager {
        const mgr = try allocator.create(Manager);
        mgr.* = .{ .server = server, .allocator = allocator };
        mgr.ensureConnected();
        return mgr;
    }

    pub const isAvailable = power_capabilities.isAvailable;
    pub const unavailableExplanation = power_capabilities.unavailableExplanation;
    pub const setCapability = power_capabilities.setCapability;
    pub const probeCapabilities = power_capabilities.probeCapabilities;
    pub const maybeProbe = power_capabilities.maybeProbe;
    pub const queryProbe = power_capabilities.queryProbe;
    pub const finishProbeReply = power_capabilities.finishProbeReply;

    pub fn ensureConnected(self: *Manager) void {
        _ = self.connection() catch {};
    }

    pub fn deinit(self: *Manager) void {
        self.closing = true;
        self.releaseInhibitor(.lid);
        self.releaseInhibitor(.sleep);
        if (self.sleep_timer) |timer| timer.remove();
        if (self.command_child) |child| child.detach();
        if (self.conn) |c| c.destroy();
        if (self.signal_sender) |sender| self.allocator.free(sender);
        if (self.session_path) |path| self.allocator.free(path);
        self.allocator.destroy(self);
    }

    pub const requestPowerOff = power_requests.requestPowerOff;
    pub const requestReboot = power_requests.requestReboot;
    pub const requestSuspend = power_requests.requestSuspend;
    pub const requestPowerOffAuto = power_requests.requestPowerOffAuto;
    pub const requestRebootAuto = power_requests.requestRebootAuto;
    pub const requestSuspendAuto = power_requests.requestSuspendAuto;
    pub const request = power_requests.request;
    pub const beginRequest = power_requests.beginRequest;
    pub const startCommand = power_requests.startCommand;
    pub const queryCapability = power_requests.queryCapability;
    pub const callAction = power_requests.callAction;
    pub const queryInhibitors = power_requests.queryInhibitors;
    pub const handleInhibitors = power_requests.handleInhibitors;
    pub const failed = power_requests.failed;
    pub const failedMsg = power_requests.failedMsg;
    pub const report = power_requests.report;

    pub const connection = power_bus.connection;
    pub const subscribeSignals = power_bus.subscribeSignals;
    pub const inspectApi = power_bus.inspectApi;
};
