//! The session's fade in from black and the greeter's fade out to it: a veil
//! the output pass draws over everything but the cursor
//! (`rediwm_scene_output_set_veil`). Only displays someone looks at (DRM,
//! nested) carry it; headless outputs never do. Output frames drive the fade;
//! the one timer is a one-shot bound, so nothing wakes once it is over.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const anim = @import("ui").anim;
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const startup = @import("startup.zig");

const Reveal = @This();

/// After the first frame is shown, how long the fade waits for the decoded
/// wallpaper, so it does not rise on the plain colour and then swap.
const wallpaper_wait_ms = 150;
/// The fade begins by then even if no frame is ever acknowledged.
const max_hold_ms = 1000;
/// The greeter rises faster than a desktop (`session_reveal`): the login UI is
/// not operational until its veil has cleared, so this is part of the wait.
const greeter_reveal_ms = 150;
const cover_ms = 200;
/// Past the cover's own length: a display that stops presenting must not keep
/// the greeter from exiting.
const cover_slack_ms = 250;
/// The black frame reaches the screen before the greeter exits.
const covered_settle_ms = 20;

const Phase = enum {
    off,
    /// Black on every veiled output until the first frame and the wallpaper.
    held,
    revealing,
    covering,
    /// Black; `on_covered` runs from the timer.
    covered,
};

server: ?*Server = null,
phase: Phase = .off,
visible: bool = false,
fade: anim.Anim = .{},
timer: ?*wl.EventSource = null,
on_covered: ?*const fn (*Server) void = null,

/// Before the backend starts, so each output's first frame is already black.
/// A crash-restart into a locked session shows its lock at once; the greeter
/// (also a lock) fades in like a session.
pub fn arm(self: *Reveal, server: *Server) void {
    self.server = server;
    if ((server.locker != null and !server.greeter_mode) or anim.curveFor(.session_reveal) == .off) return;
    self.phase = .held;
    self.armTimer(max_hold_ms);
}

pub fn deinit(self: *Reveal) void {
    if (self.timer) |timer| timer.remove();
    self.timer = null;
    self.phase = .off;
}

fn veils(wlr_output: *wlr.Output) bool {
    return wlr_output.isDrm() or wlr_output.isWl();
}

/// A display that appears while the desktop is still held starts black too.
pub fn outputCreated(self: *Reveal, output: *Output) void {
    if (self.phase != .held or !veils(output.wlr_output)) return;
    self.setVeil(output, 1);
}

/// The first frame reached a screen.
pub fn onVisible(self: *Reveal) void {
    self.visible = true;
    if (self.phase != .held) return;
    const server = self.server orelse return;
    if (server.wallpaper_loader == null or showsAccountWallpaper(server)) return self.begin();
    self.armTimer(wallpaper_wait_ms);
}

/// The greeter draws the account's snapshot over the decoded wallpaper, which
/// then only matters for an account without one: nothing to wait for.
fn showsAccountWallpaper(server: *const Server) bool {
    const lock = server.locker orelse return false;
    return server.greeter_mode and lock.greeter_wallpaper != null;
}

/// The wallpaper decoded (and is on its node) or failed.
pub fn onWallpaper(self: *Reveal) void {
    if (self.phase == .held and self.visible) self.begin();
}

fn begin(self: *Reveal) void {
    self.disarmTimer();
    self.phase = .revealing;
    const greeter = if (self.server) |server| server.greeter_mode else false;
    self.fade = .initCurve(1, 0, anim.nowMs(), if (greeter)
        .{ .duration = .{ .ms = greeter_reveal_ms, .ease = .in_out_sine } }
    else
        anim.curveFor(.session_reveal));
    // Reduced motion keeps a short fade rather than a cut.
    self.fade.property = .opacity;
    self.scheduleFrames();
}

/// Fades every veiled output to black, then calls `done` (the greeter's
/// exit). With nothing to fade it calls `done` at once.
pub fn cover(self: *Reveal, server: *Server, done: *const fn (*Server) void) void {
    self.server = server;
    if (self.phase == .covering or self.phase == .covered) return;
    var any = false;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        if (veils(output.wlr_output) and output.wlr_output.enabled) any = true;
    }
    const now = anim.nowMs();
    const from = self.current(now);
    var fade: anim.Anim = .initCurve(from, 1, now, .{ .duration = .{ .ms = cover_ms, .ease = .in_out_sine } });
    fade.property = .opacity;
    if (!any or fade.settled(now)) return done(server);
    self.on_covered = done;
    self.fade = fade;
    self.phase = .covering;
    const length: f32 = @as(f32, cover_ms) / @max(anim.speed(), 0.25);
    self.armTimer(@as(c_int, @intFromFloat(length)) + cover_slack_ms);
    self.scheduleFrames();
}

fn current(self: *const Reveal, now_ms: i64) f32 {
    return switch (self.phase) {
        .off => 0,
        .held, .covered => 1,
        .revealing, .covering => self.fade.value(now_ms),
    };
}

/// Once per output frame, before the frame is built. True while it fades.
pub fn tick(self: *Reveal, output: *Output, now_ms: i64) bool {
    if (self.phase != .revealing and self.phase != .covering) return false;
    if (!veils(output.wlr_output)) return false;
    if (!self.fade.settled(now_ms)) {
        // Whole alpha steps: an unchanged one repaints nothing.
        self.setVeil(output, @round(self.fade.value(now_ms) * 255) / 255);
        return true;
    }
    if (self.phase == .revealing) {
        self.phase = .off;
        startup.markRevealed();
        // Every output, so one that is between frames is not left dark.
        var it = output.server.outputs.iterator(.forward);
        while (it.next()) |each| self.setVeil(each, 0);
    } else {
        self.phase = .covered;
        var it = output.server.outputs.iterator(.forward);
        while (it.next()) |each| if (veils(each.wlr_output)) self.setVeil(each, 1);
        self.armTimer(covered_settle_ms);
    }
    return false;
}

fn setVeil(self: *Reveal, output: *Output, alpha: f32) void {
    const server = self.server orelse return;
    const scene_output = server.scene_outputs.get(output.wlr_output) orelse return;
    // A presented black/fading frame is not an operational greeter.
    if (alpha != 0) {
        output.greeter_unveiled = false;
        output.greeter_presented = false;
        output.greeter_commit_seq = null;
    }
    if (server.output_renderer.setVeil(scene_output, alpha)) {
        output.greeter_unveiled = alpha == 0;
    } else {
        std.log.scoped(.reveal).warn("could not veil {s}", .{output.wlr_output.name});
    }
}

fn scheduleFrames(self: *Reveal) void {
    const server = self.server orelse return;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| output.wlr_output.scheduleFrame();
}

fn armTimer(self: *Reveal, ms: c_int) void {
    const server = self.server orelse return;
    if (self.timer == null) {
        self.timer = server.wl_server.getEventLoop().addTimer(*Reveal, handleTimer, self) catch null;
    }
    const timer = self.timer orelse return self.expire();
    timer.timerUpdate(@max(ms, 1)) catch self.expire();
}

fn disarmTimer(self: *Reveal) void {
    if (self.timer) |timer| timer.timerUpdate(0) catch {};
}

fn handleTimer(self: *Reveal) c_int {
    self.expire();
    return 0;
}

fn expire(self: *Reveal) void {
    switch (self.phase) {
        .held => self.begin(),
        .covering, .covered => {
            self.disarmTimer();
            self.phase = .covered;
            const done = self.on_covered orelse return;
            self.on_covered = null;
            if (self.server) |server| done(server);
        },
        .off, .revealing => {},
    }
}
