//! Startup feedback: while an application launched from the shell is still
//! starting, the default arrow becomes the animated "progress" cursor.
//!
//! A launch ends when a new window appears that belongs to it (activation
//! token, pid chain or app id, as for placeholders), when it activates an
//! existing window with its token, when its process fails, or after
//! `timeout_ms`. Launchers that exit successfully (single-instance handoff,
//! wrappers) keep waiting for the window.
const std = @import("std");
const wl = @import("wayland").server.wl;
const Server = @import("Server.zig");
const Toplevel = @import("Toplevel.zig");
const placeholder_match = @import("placeholder_match.zig");

const Self = @This();

pub const timeout_ms = 15_000;
const max_launches = 16;

pub const Spec = struct {
    pid: i32 = 0,
    token: ?[]const u8 = null,
    desktop_id: []const u8 = "",
    startup_wm_class: ?[]const u8 = null,
};

const Launch = struct {
    pid: i32,
    token: Str(64),
    desktop_id: Str(128),
    wm_class: Str(128),
    has_wm_class: bool,
    /// Windows with this id or lower existed before the launch.
    after_id: u64,
    deadline_ms: i64,
};

fn Str(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,

        fn init(value: []const u8) @This() {
            var s: @This() = .{};
            s.len = @min(value.len, n);
            @memcpy(s.buf[0..s.len], value[0..s.len]);
            return s;
        }

        fn get(s: *const @This()) []const u8 {
            return s.buf[0..s.len];
        }
    };
}

server: *Server = undefined,
launches: [max_launches]Launch = undefined,
len: usize = 0,
timer: ?*wl.EventSource = null,

pub fn init(self: *Self, server: *Server) void {
    self.* = .{ .server = server };
}

pub fn deinit(self: *Self) void {
    if (self.timer) |t| t.remove();
    self.timer = null;
    self.len = 0;
}

pub fn busy(self: *const Self) bool {
    return self.len > 0;
}

pub fn begin(self: *Self, spec: Spec) void {
    // Full: the oldest launch is the least likely to still be starting.
    if (self.len == max_launches) self.removeAt(0);
    self.launches[self.len] = .{
        .pid = spec.pid,
        .token = .init(spec.token orelse ""),
        .desktop_id = .init(spec.desktop_id),
        .wm_class = .init(spec.startup_wm_class orelse ""),
        .has_wm_class = spec.startup_wm_class != null,
        .after_id = self.server.next_toplevel_id -| 1,
        .deadline_ms = Toplevel.nowMs() + timeout_ms,
    };
    self.len += 1;
    self.armTimer();
    if (self.len == 1) self.server.input.refreshBusyCursor();
}

pub fn windowMapped(self: *Self, toplevel: *Toplevel) void {
    if (self.len == 0) return;
    const pid = toplevel.clientPid() orelse 0;
    const app_id = toplevel.appId();
    var i: usize = 0;
    var changed = false;
    while (i < self.len) {
        const launch = &self.launches[i];
        const ours = toplevel.id > launch.after_id and
            ((launch.pid > 0 and pid > 0 and placeholder_match.matchesPidChain(pid, launch.pid)) or
                placeholder_match.matchesAppId(app_id, if (launch.has_wm_class) launch.wm_class.get() else null, launch.desktop_id.get()));
        if (ours) {
            self.removeAt(i);
            changed = true;
        } else i += 1;
    }
    if (changed) self.finish();
}

/// End the launch holding this activation token: the app used it (it is up,
/// even if it only raised an existing window), or the launch was abandoned.
pub fn endToken(self: *Self, token: []const u8) void {
    if (token.len == 0) return;
    var i: usize = 0;
    var changed = false;
    while (i < self.len) {
        if (std.mem.eql(u8, self.launches[i].token.get(), token)) {
            self.removeAt(i);
            changed = true;
        } else i += 1;
    }
    if (changed) self.finish();
}

/// A launched process exited. Failure ends its launch; success may be a
/// handoff to an existing instance or a wrapper, so keep waiting.
pub fn processExited(self: *Self, pid: i32, succeeded: bool) void {
    if (succeeded or pid <= 0) return;
    var i: usize = 0;
    var changed = false;
    while (i < self.len) {
        if (self.launches[i].pid == pid) {
            self.removeAt(i);
            changed = true;
        } else i += 1;
    }
    if (changed) self.finish();
}

fn removeAt(self: *Self, i: usize) void {
    std.mem.copyForwards(Launch, self.launches[i .. self.len - 1], self.launches[i + 1 .. self.len]);
    self.len -= 1;
}

fn finish(self: *Self) void {
    self.armTimer();
    if (self.len == 0) self.server.input.refreshBusyCursor();
}

/// One timer for the earliest deadline, disarmed when idle.
fn armTimer(self: *Self) void {
    if (self.len == 0) {
        if (self.timer) |t| t.timerUpdate(0) catch {};
        return;
    }
    var earliest = self.launches[0].deadline_ms;
    for (self.launches[1..self.len]) |launch| earliest = @min(earliest, launch.deadline_ms);
    if (self.timer == null) {
        self.timer = self.server.wl_server.getEventLoop().addTimer(*Self, expire, self) catch return;
    }
    const delay = @max(1, earliest - Toplevel.nowMs());
    self.timer.?.timerUpdate(@intCast(delay)) catch {};
}

fn expire(self: *Self) c_int {
    const now = Toplevel.nowMs();
    var i: usize = 0;
    while (i < self.len) {
        if (self.launches[i].deadline_ms <= now) self.removeAt(i) else i += 1;
    }
    self.finish();
    return 0;
}
