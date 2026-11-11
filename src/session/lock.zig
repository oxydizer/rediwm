//! Built-in session lock. The opaque per-output guard exists before locking;
//! optional wallpaper/UI allocation never determines desktop confidentiality.
//!
//! Greeter mode (`rediwm --greeter`) is the same lock that never unlocks: it
//! picks an account and session and signs in through rediwm-dm, then exits.
const i18n = @import("i18n");
const std = @import("std");
const platform = @import("platform");
const Child = @import("child.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const col = @import("../color.zig");
const xkb = @import("xkbcommon");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const gpa = @import("../main.zig").gpa;
const Buffer = @import("../panel_buffer.zig").PanelBuffer;
const ui = @import("ui");
const text = @import("ui").text;
const png = @import("../png.zig");
const anim = @import("ui").anim;
const greeter_mod = @import("greeter.zig");
const ClientLock = @import("client_lock.zig").ClientLock;
const lock_controls = @import("lock_controls.zig");
const power_cmd = @import("power.zig");
const Controls = lock_controls.Controls;
const CaretOverlay = @import("../caret_overlay.zig").CaretOverlay;
const Greeter = greeter_mod.Greeter;
const login_appearance = @import("login_appearance.zig");
const ImageBuffer = @import("../ImageBuffer.zig");
const lock_account = @import("lock_account.zig");
const lock_events = @import("lock_events.zig");
const lock_input = @import("lock_input.zig");
pub const c = @import("c");
const text_field = ui.widgets.field;
const SecretInput = ui.widgets.secret_input.Input;
const Auth = opaque {};
extern fn rediwm_account([*]u8, usize, [*]u8, usize, [*]u8, usize) c_int;
extern fn rediwm_secret_clear([*]u8, usize) void;
pub extern fn rediwm_auth_start([*:0]const u8) ?*Auth;
pub extern fn rediwm_auth_poll(*Auth) c_int;
pub extern fn rediwm_auth_fd(*Auth) c_int;
pub extern fn rediwm_auth_destroy(*Auth) void;

pub fn clearKeyScratch(bytes: []u8) void {
    rediwm_secret_clear(bytes.ptr, bytes.len);
}

pub const Lock = struct {
    server: *Server,
    /// Handles the clock and transient controls deadlines.
    timer: *wl.EventSource,
    user: [256]u8 = @splat(0),
    name: [256]u8 = @splat(0),
    password: [512:0]u8 = @splat(0),
    /// Edits `password`; reach it through `field()`.
    input: SecretInput = .{ .storage = &.{} },
    reveal: bool = false,
    caps: bool = false,
    focus: u8 = 0, // password, reveal, unlock, power, restart, account, session
    auth: ?*Auth = null,
    /// Readable when `auth` has a result; only set while `auth` is.
    auth_source: ?*wl.EventSource = null,
    /// Set in greeter mode: rediwm-dm, not PAM, decides, and success exits.
    greeter: ?*Greeter = null,
    greeter_appearance_root: []const u8 = login_appearance.root,
    greeter_default_theme: ui.theme.Theme = .{},
    greeter_appearance: ?login_appearance.Saved = null,
    greeter_wallpaper: ?*ImageBuffer = null,
    /// Who started the lock. Only a client lock whose client died may be
    /// taken over by a new ext-session-lock client.
    origin: enum { builtin, client } = .builtin,
    /// The ext-session-lock client drawing over this lock, if any.
    client: ?*ClientLock = null,
    status: []const u8 = unlock_hint,
    /// Last key into the lock: restarts the field caret's blink phase.
    caret_edit_ms: i64 = 0,
    retry_at: i64 = 0,
    revision: u64 = 1,
    minute: i64 = -1,
    controls_visible: bool = false,
    controls_hide_at: i64 = 0,
    confirm: ?bool = null, // false = power off, true = reboot
    power_child: ?*Child = null,
    avatar: ?png.Image = null,
    /// Volume and brightness sliders; none in the greeter.
    controls: Controls = .{},
    /// The active keyboard layout's text for the layout button; empty hides
    /// it (one layout, or the greeter). Copied, so painting needs no server.
    layout_label: [24]u8 = undefined,
    layout_label_len: u8 = 0,

    pub fn start(server: *Server) void {
        if (server.locker != null) return;
        _ = create(server, .builtin) catch |err| std.log.err("Cannot lock: {}", .{err});
    }

    /// Locks now. A client lock still needs its PAM account: the built-in
    /// screen is the fallback if the client dies.
    pub fn create(server: *Server, origin: @FieldType(Lock, "origin")) !*Lock {
        std.debug.assert(server.locker == null);
        const self = try gpa.create(Lock);
        errdefer gpa.destroy(self);
        self.* = .{ .server = server, .timer = undefined, .origin = origin, .status = i18n.tr("Press Enter to unlock") };
        var home: [4096]u8 = @splat(0);
        if (rediwm_account(&self.user, self.user.len, &self.name, self.name.len, &home, home.len) != 0) return error.NoAccount;
        self.timer = try server.wl_server.getEventLoop().addTimer(*Lock, tick, self);
        self.engage();
        self.loadAvatar(std.mem.sliceTo(&home, 0));
        return self;
    }

    /// Covers every output with the greeter until rediwm-dm starts a session.
    pub fn startGreeter(server: *Server) !void {
        std.debug.assert(server.locker == null);
        const greeter = try Greeter.create(server.io, server.wl_server.getEventLoop(), server.environ);
        errdefer greeter.destroy();
        const self = try gpa.create(Lock);
        errdefer gpa.destroy(self);
        self.* = .{ .server = server, .timer = undefined, .greeter = greeter, .greeter_default_theme = server.config.theme };
        self.timer = try server.wl_server.getEventLoop().addTimer(*Lock, tick, self);
        greeter.owner = self;
        greeter.notify = greeterEvent;
        self.engage();
        self.showAccount();
        self.status = self.idleStatus();
        std.log.info("greeter: {d} account(s), {d} session(s), login service {s}", .{
            greeter.users.len,
            greeter.sessions.len,
            if (greeter.client != null) "connected" else "not running (REDIWM_GREETER_FD unset)",
        });
    }

    pub fn engage(self: *Lock) void {
        const server = self.server;
        // First, so a crash anywhere below still restarts the session locked.
        announce(server, true);
        _ = c.mlock(&self.password, self.password.len);
        platform.process.denyDumps() catch {};
        server.switcher.cancel();
        server.screenshot_selector.cancel();
        server.locker = self;
        self.refreshLayoutLabel();
        if (server.bluetooth) |bluetooth| bluetooth.closed();
        if (server.input.open_control_center) |cc| {
            cc.bluetooth.clearPin();
            cc.key_settings.clearSecrets();
            if (cc.key_settings.client) |client| client.cancel();
            cc.refresh();
        }
        @import("../extra_protocols.zig").rediwm_protocols_revoke(server.extra_protocols);
        server.world.mini_map.hide();
        if (server.ipc) |ipc| ipc.wait_mgr.failAll("SessionLocked");
        if (server.polkit) |agent| agent.pauseForLock();
        // Clear undo state on lock: restoring spatial state across a screen
        // lock session would be confusing (different user context).
        if (server.input.tiling_grab != null) server.input.finishTilingGrab(false);
        server.undo.clear();
        var keyboards = server.input.keyboards.iterator(.forward);
        while (keyboards.next()) |keyboard| keyboard.cancelHardware();
        server.input.cancelResize();
        server.input.cursor_mode = .passthrough;
        server.input.grabbed_toplevel = null;
        server.input.pan_session = null;
        server.input.active_buttons = 0;
        server.input.seat.keyboardEndGrab();
        server.input.seat.pointerEndGrab();
        server.input.window_menu.close();
        server.input.seat.keyboardClearFocus();
        server.input.seat.pointerClearFocus();
        server.input.setDefaultCursor();
        ui.input.reset();
        var it = server.outputs.iterator(.forward);
        while (it.next()) |out| {
            out.closeStartMenu();
            out.closePowerMenu();
            out.closeBattery();
            out.closeWifi();
            out.lock_view.cover(out);
            out.lock_commit_pending = out.isAvailable();
        }
        // The greeter runs no audio and no external tools.
        if (self.greeter == null) {
            server.brightness.query(server);
            _ = self.controls.refresh(server);
        }
        self.changed();
        self.minute = @divTrunc(c.time(null), 60);
        self.scheduleClock();
    }

    /// Wakes for the next clock minute or transient controls timeout.
    pub fn scheduleClock(self: *Lock) void {
        var delay: i64 = (60 - @mod(c.time(null), 60)) * 1000 + 25;
        if (self.controls_visible and self.controls_hide_at > 0) {
            delay = @min(delay, @max(1, self.controls_hide_at - anim.nowMs()));
        }
        self.timer.timerUpdate(@intCast(delay)) catch {};
    }

    /// Everyone outside the compositor who tracks the lock: rediwm-session,
    /// so a crash restarts locked, and logind's LockedHint.
    pub fn announce(server: *Server, locked: bool) void {
        @import("activation.zig").reportLocked(server.environ, locked);
        if (server.power) |power| power.lockChanged(locked);
    }

    /// Whether every available output has committed a frame with the lock
    /// covering it (`Output.lock_commit_pending`).
    pub fn covered(self: *const Lock) bool {
        var it = self.server.outputs.iterator(.forward);
        while (it.next()) |out| {
            if (out.lock_commit_pending and out.isAvailable()) return false;
        }
        return true;
    }

    /// An output committed a covered frame, went dark or went away.
    pub fn outputCovered(self: *Lock) void {
        if (self.client) |client| client.checkLocked();
        if (self.covered()) if (self.server.power) |power| power.lockCovered();
    }

    pub const showAccount = lock_account.showAccount;
    pub const applyAccountAppearance = lock_account.applyAccountAppearance;
    pub const clearAccountAppearance = lock_account.clearAccountAppearance;
    pub const idleStatus = lock_account.idleStatus;
    pub const busy = lock_account.busy;
    pub const prompting = lock_account.prompting;
    pub const greeterEvent = lock_account.greeterEvent;
    pub const loadAvatar = lock_account.loadAvatar;
    pub const readAvatar = lock_account.readAvatar;

    /// The password editor, bound to `password` on every access so a moved
    /// `Lock` (tests build them on the stack) never leaves it dangling. The
    /// last byte stays zero: PAM reads `password` as a C string.
    pub fn field(self: *Lock) *SecretInput {
        self.input.storage = self.password[0 .. self.password.len - 1];
        return &self.input;
    }

    pub fn clear(self: *Lock) void {
        rediwm_secret_clear(&self.password, self.password.len);
        self.input.len = 0;
        self.input.cursor = 0;
        self.reveal = false;
    }

    pub fn destroy(self: *Lock) void {
        if (self.client) |client| client.end();
        self.timer.remove();
        if (self.power_child) |child| child.detach();
        if (self.auth_source) |source| source.remove();
        if (self.auth) |auth| rediwm_auth_destroy(auth);
        if (self.greeter) |greeter| {
            self.clearAccountAppearance();
            greeter.destroy();
        }
        self.clear();
        _ = c.munlock(&self.password, self.password.len);
        if (self.avatar) |avatar| avatar.deinit(gpa);
        gpa.destroy(self);
    }

    /// Ends the lock after PAM success or the lock client's own unlock.
    pub fn release(self: *Lock) void {
        // Greeter mode never starts PAM; only rediwm-dm can end it.
        std.debug.assert(self.greeter == null);
        const server = self.server;
        server.input.seat.keyboardEndGrab();
        server.input.seat.pointerEndGrab();
        server.input.seat.keyboardClearFocus();
        server.input.seat.pointerClearFocus();
        server.locker = null;
        // Clear undo across the lock boundary.
        server.undo.clear();
        var it = server.outputs.iterator(.forward);
        while (it.next()) |out| {
            out.lock_view.hide();
            out.lock_commit_pending = false;
        }
        self.destroy();
        if (server.polkit) |agent| agent.resumeAfterLock();
        if (server.world.toplevels.first()) |top| server.world.focus(top);
        server.scheduleFrames();
        announce(server, false);
    }

    /// The lock client died without unlocking: the built-in screen takes over.
    pub fn clientGone(self: *Lock) void {
        self.focus = 0;
        self.status = i18n.tr("Press Enter to unlock");
        self.changed();
    }

    pub const changed = lock_events.changed;
    pub const themeChanged = lock_events.themeChanged;
    pub const inputSourceChanged = lock_events.inputSourceChanged;
    pub const refreshLayoutLabel = lock_events.refreshLayoutLabel;
    pub const controlsChanged = lock_events.controlsChanged;
    pub const showControl = lock_events.showControl;
    pub const showControls = lock_events.showControls;
    pub const controlsAt = lock_events.controlsAt;
    pub const pointerMoved = lock_events.pointerMoved;
    pub const pointerReleased = lock_events.pointerReleased;
    pub const powerExited = lock_events.powerExited;
    pub const tick = lock_events.tick;

    pub const authReady = lock_input.authReady;
    pub const submit = lock_input.submit;
    pub const submitGreeter = lock_input.submitGreeter;
    pub const choose = lock_input.choose;
    pub const focusOrder = lock_input.focusOrder;
    pub const moveFocus = lock_input.moveFocus;
    pub const modifiers = lock_input.modifiers;
    pub const keyRepeats = lock_input.keyRepeats;
    pub const key = lock_input.key;
    pub const activate = lock_input.activate;
    pub const click = lock_input.click;
};

pub const ControlsAt = struct { hit: lock_controls.Hit, left: f32, span: f32 };

/// What the volume/brightness block of a `w` x `h` output has at an
/// output-local point: the control, and its track's left edge and width in
/// the same pixels.
pub fn controlsPick(controls: *const Controls, w: f32, h: f32, px: f32, py: f32) ?ControlsAt {
    if (controls.rows() == 0) return null;
    const geo = Geometry.init(w, h);
    const box = geo.controlsBox(controls.height());
    const origin_x: f32 = @floatFromInt(box.x);
    const origin_y: f32 = @floatFromInt(box.y);
    const hit = controls.pick((px - origin_x) / geo.s, (py - origin_y) / geo.s) orelse return null;
    return .{ .hit = hit, .left = origin_x + lock_controls.track_x * geo.s, .span = lock_controls.track_w * geo.s };
}

pub const unlock_hint = "Press Enter to unlock";
pub const login_hint = "Press Enter to log in";
pub const focus_account: u8 = 5;
pub const focus_session: u8 = 6;
/// The keyboard layout button (`lock_view.layoutButtonShown`).
pub const focus_layout: u8 = 7;

const lock_view = @import("lock_view.zig");
pub const Geometry = lock_view.Geometry;
pub const field_options = lock_view.field_options;
pub const View = lock_view.View;
pub const ControlsKey = lock_view.ControlsKey;
pub const lockBackground = lock_view.lockBackground;
pub const label = lock_view.label;
pub const Painted = lock_view.Painted;
pub const paint = lock_view.paint;
pub const paintChoices = lock_view.paintChoices;

test {
    _ = @import("lock_tests.zig");
}
