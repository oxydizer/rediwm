//! Built-in session lock. The opaque per-output guard exists before locking;
//! optional wallpaper/UI allocation never determines desktop confidentiality.
//!
//! Greeter mode (`rediwm --greeter`) is the same lock that never unlocks: it
//! picks an account and session and signs in through rediwm-dm, then exits.
const std = @import("std");
const Child = @import("child.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
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
const Controls = lock_controls.Controls;
const CaretOverlay = @import("../caret_overlay.zig").CaretOverlay;
const Greeter = greeter_mod.Greeter;
const c = @cImport({
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/prctl.h");
});
const text_field = ui.widgets.field;
const SecretInput = ui.widgets.secret_input.Input;
const Auth = opaque {};
extern fn rediwm_account([*]u8, usize, [*]u8, usize, [*]u8, usize) c_int;
extern fn rediwm_secret_clear([*]u8, usize) void;
extern fn rediwm_auth_start([*:0]const u8) ?*Auth;
extern fn rediwm_auth_poll(*Auth) c_int;
extern fn rediwm_auth_fd(*Auth) c_int;
extern fn rediwm_auth_destroy(*Auth) void;

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
        self.* = .{ .server = server, .timer = undefined, .origin = origin };
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
        self.* = .{ .server = server, .timer = undefined, .greeter = greeter };
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

    fn engage(self: *Lock) void {
        const server = self.server;
        // First, so a crash anywhere below still restarts the session locked.
        announce(server, true);
        _ = c.mlock(&self.password, self.password.len);
        _ = c.prctl(c.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
        server.switcher.cancel();
        server.screenshot_selector.cancel();
        server.locker = self;
        if (server.bluetooth) |bluetooth| bluetooth.closed();
        if (server.input.open_control_center) |cc| cc.bluetooth.clearPin();
        @import("../extra_protocols.zig").rediwm_protocols_revoke(server.extra_protocols);
        server.world.mini_map.hide();
        if (server.ipc) |ipc| ipc.wait_mgr.failAll("SessionLocked");
        if (server.polkit) |agent| agent.pauseForLock();
        // Clear undo state on lock: restoring spatial state across a screen
        // lock session would be confusing (different user context).
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
    fn scheduleClock(self: *Lock) void {
        var delay: i64 = (60 - @mod(c.time(null), 60)) * 1000 + 25;
        if (self.controls_visible and self.controls_hide_at > 0) {
            delay = @min(delay, @max(1, self.controls_hide_at - anim.nowMs()));
        }
        self.timer.timerUpdate(@intCast(delay)) catch {};
    }

    /// Everyone outside the compositor who tracks the lock: rediwm-session,
    /// so a crash restarts locked, and logind's LockedHint.
    fn announce(server: *Server, locked: bool) void {
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

    /// Greeter: shows the selected account's name and picture.
    fn showAccount(self: *Lock) void {
        const greeter = self.greeter orelse return;
        if (self.avatar) |avatar| avatar.deinit(gpa);
        self.avatar = null;
        @memset(&self.user, 0);
        @memset(&self.name, 0);
        const user = greeter.selectedUser() orelse return;
        const n = @min(user.name.len, self.user.len - 1);
        @memcpy(self.user[0..n], user.name[0..n]);
        const m = @min(user.real.len, self.name.len - 1);
        @memcpy(self.name[0..m], user.real[0..m]);
        // Home directories are usually private to their owner; AccountsService
        // pictures are the ones a greeter can normally read.
        self.loadAvatar(user.home);
    }

    fn idleStatus(self: *const Lock) []const u8 {
        const greeter = self.greeter orelse return unlock_hint;
        if (greeter.users.len == 0) return "No user accounts found";
        if (greeter.sessions.len == 0) return "No sessions installed";
        return login_hint;
    }

    fn busy(self: *const Lock) bool {
        if (self.greeter) |greeter| return greeter.busy();
        return self.auth != null;
    }

    fn prompting(self: *const Lock) bool {
        const greeter = self.greeter orelse return false;
        return greeter.phase == .prompting;
    }

    fn greeterEvent(owner: ?*anyopaque, event: greeter_mod.Event) void {
        const self: *Lock = @ptrCast(@alignCast(owner.?));
        switch (event) {
            .status => |message| self.status = message,
            .prompt => |p| {
                self.clear();
                self.status = p.text;
                self.reveal = p.visible;
                self.focus = 0;
            },
            .rejected => {
                self.status = "Incorrect password. Try again.";
                self.retry_at = anim.nowMs() + 1500;
            },
            .failed => |message| {
                self.status = message;
                self.retry_at = anim.nowMs() + 1500;
            },
            .started => {
                self.status = "Starting session…";
                std.log.info("greeter: rediwm-dm accepted the session; exiting", .{});
                self.server.terminate();
            },
            .disconnected => {
                self.status = "Lost contact with login service. Try again.";
                std.log.info("greeter: lost the rediwm-dm connection; exiting so it starts a new greeter", .{});
                self.server.terminate();
            },
        }
        self.changed();
    }

    fn loadAvatar(self: *Lock, home: []const u8) void {
        var path: [4352]u8 = undefined;
        if (home.len > 0) for ([_][]const u8{ ".face", ".face.png" }) |file| {
            const p = std.fmt.bufPrint(&path, "{s}/{s}", .{ home, file }) catch continue;
            if (self.readAvatar(p)) return;
        };
        const p = std.fmt.bufPrint(&path, "/var/lib/AccountsService/icons/{s}", .{std.mem.sliceTo(&self.user, 0)}) catch return;
        _ = self.readAvatar(p);
    }

    fn readAvatar(self: *Lock, path: []const u8) bool {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.server.io, path, gpa, .limited(4 * 1024 * 1024)) catch return false;
        defer gpa.free(bytes);
        // Bound decoded allocation as well as file size before using the PNG decoder.
        if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return false;
        if (std.mem.readInt(u32, bytes[16..20], .big) > 2048 or std.mem.readInt(u32, bytes[20..24], .big) > 2048) return false;
        self.avatar = png.decode(gpa, bytes) catch return false;
        return true;
    }

    /// The password editor, bound to `password` on every access so a moved
    /// `Lock` (tests build them on the stack) never leaves it dangling. The
    /// last byte stays zero: PAM reads `password` as a C string.
    fn field(self: *Lock) *SecretInput {
        self.input.storage = self.password[0 .. self.password.len - 1];
        return &self.input;
    }

    fn clear(self: *Lock) void {
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
        if (self.greeter) |greeter| greeter.destroy();
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
        self.status = unlock_hint;
        self.changed();
    }

    fn changed(self: *Lock) void {
        self.revision +%= 1;
        self.server.scheduleFrames();
    }

    /// A reskin invalidates both the screen and its small controls raster.
    pub fn themeChanged(self: *Lock) void {
        var outputs = self.server.outputs.iterator(.forward);
        while (outputs.next()) |out| out.lock_view.controls_key = null;
        self.changed();
    }

    /// Volume, mute or brightness changed; redraw only the controls block.
    pub fn controlsChanged(self: *Lock) void {
        if (self.greeter != null) return;
        const previous_volume = self.controls.volume;
        const previous_muted = self.controls.muted;
        const previous_brightness = self.controls.brightness;
        if (self.controls.refresh(self.server)) {
            self.server.scheduleFrames();
            if (self.controls.volume != previous_volume or self.controls.muted != previous_muted or self.controls.brightness != previous_brightness) {
                self.showControls();
            }
        }
    }

    fn showControls(self: *Lock) void {
        if (self.greeter != null or self.controls.height() == 0) return;
        const newly_visible = !self.controls_visible;
        self.controls_visible = true;
        self.controls_hide_at = anim.nowMs() + 2500;
        self.scheduleClock();
        if (newly_visible) self.server.scheduleFrames();
    }

    /// The control under a layout point, with its track's left edge and
    /// width in layout pixels. An ext-session-lock client's surface hides
    /// the built-in controls along with the rest of the screen.
    fn controlsAt(self: *Lock, x: f64, y: f64) ?ControlsAt {
        if (self.greeter != null) return null;
        const out = Output.atLayout(self.server, x, y) orelse return null;
        if (self.client) |client| if (client.covers(out)) return null;
        const b = out.cached_box;
        const found = controlsPick(&self.controls, @floatFromInt(b.width), @floatFromInt(b.height), @floatCast(x - @as(f64, @floatFromInt(b.x))), @floatCast(y - @as(f64, @floatFromInt(b.y)))) orelse return null;
        return .{ .hit = found.hit, .left = found.left + @as(f32, @floatFromInt(b.x)), .span = found.span };
    }

    /// The pointer moved: continues a drag, else follows the hover.
    pub fn pointerMoved(self: *Lock, x: f64, y: f64) void {
        if (self.controls.drag != null) {
            const before = self.controls.revision;
            self.controls.dragTo(self.server, @floatCast(x));
            self.controls_hide_at = anim.nowMs() + 2500;
            self.scheduleClock();
            if (self.controls.revision != before) self.server.scheduleFrames();
            return;
        }
        const at = self.controlsAt(x, y);
        if (at != null) self.showControls();
        const hit: ?lock_controls.Hit = if (at) |found| found.hit else null;
        if (self.controls.setHover(hit)) self.server.scheduleFrames();
    }

    /// The primary button went up, wherever the pointer is.
    pub fn pointerReleased(self: *Lock) void {
        if (self.controls.endDrag()) {
            self.controls_hide_at = anim.nowMs() + 2500;
            self.scheduleClock();
            self.server.scheduleFrames();
        }
    }

    fn powerExited(owner: ?*anyopaque, _: *Child, status: ?u32) void {
        const self: *Lock = @ptrCast(@alignCast(owner.?));
        self.power_child = null;
        self.status = if (status != null and status.? == 0) "Power request accepted" else "Power request denied or unavailable";
        self.changed();
    }

    fn tick(self: *Lock) c_int {
        const minute = @divTrunc(c.time(null), 60);
        if (minute != self.minute) {
            self.minute = minute;
            self.changed();
        }
        if (self.controls_visible and self.controls.drag == null and anim.nowMs() >= self.controls_hide_at) {
            self.controls_visible = false;
            self.controls_hide_at = 0;
            _ = self.controls.setHover(null);
            self.server.scheduleFrames();
        }
        self.scheduleClock();
        return 0;
    }

    /// The PAM worker finished: its eventfd became readable.
    fn authReady(_: c_int, _: wl.EventMask, self: *Lock) c_int {
        const auth = self.auth orelse return 0;
        const result = rediwm_auth_poll(auth);
        if (result == 0) return 0;
        // Removing a source inside its own callback is safe: libwayland defers the free.
        if (self.auth_source) |source| source.remove();
        self.auth_source = null;
        rediwm_auth_destroy(auth);
        self.auth = null;
        self.clear();
        if (result == 1) {
            self.release();
            return 0;
        }
        self.status = "Unable to unlock. Try again.";
        self.retry_at = anim.nowMs() + 1500;
        self.changed();
        return 0;
    }

    fn submit(self: *Lock) void {
        if (self.greeter) |greeter| return self.submitGreeter(greeter);
        if (self.auth != null or self.input.len == 0 or anim.nowMs() < self.retry_at) return;
        self.auth = rediwm_auth_start(&self.password);
        self.clear();
        if (self.auth) |auth| {
            self.auth_source = self.server.wl_server.getEventLoop().addFd(*Lock, rediwm_auth_fd(auth), .{ .readable = true }, authReady, self) catch null;
            if (self.auth_source == null) {
                // Nothing would ever report the result. Joining waits for PAM
                // to finish, which is acceptable on this resource-exhaustion path.
                rediwm_auth_destroy(auth);
                self.auth = null;
            }
        }
        self.status = if (self.auth != null) "Checking password…" else "Authentication unavailable. Try again.";
        self.changed();
    }

    fn submitGreeter(self: *Lock, greeter: *Greeter) void {
        if (anim.nowMs() < self.retry_at) return;
        defer self.changed();
        if (greeter.phase == .prompting) {
            greeter.answer(self.field().value()) catch {
                self.status = "Lost contact with login service. Try again.";
            };
            if (greeter.phase == .authenticating) self.status = "Checking…";
            self.clear();
            return;
        }
        if (greeter.busy() or self.input.len == 0) return;
        self.status = greeter.begin(self.field().value()) catch |err| switch (err) {
            error.NoService => "No login service",
            error.NoAccount => "No user accounts found",
            error.NoSession => "No sessions installed",
            else => "Cannot reach login service. Try again.",
        };
        self.clear();
    }

    /// Greeter: account or session choice changed.
    fn choose(self: *Lock, target: u8, delta: isize) void {
        const greeter = self.greeter orelse return;
        if (greeter.phase != .idle) return;
        if (target == focus_account) {
            if (greeter.users.len < 2) return;
            greeter.cycleUser(delta);
            self.clear();
            self.showAccount();
        } else if (target == focus_session) {
            greeter.cycleSession(delta);
        }
        self.status = self.idleStatus();
    }

    /// Tab order; greeter mode adds the account and session choosers.
    fn focusOrder(self: *const Lock, buf: *[7]u8) []const u8 {
        const greeter = self.greeter orelse {
            buf[0..5].* = .{ 0, 1, 2, 3, 4 };
            return buf[0..5];
        };
        var n: usize = 0;
        if (greeter.users.len > 1) {
            buf[n] = focus_account;
            n += 1;
        }
        for ([_]u8{ 0, 1, 2 }) |f| {
            buf[n] = f;
            n += 1;
        }
        if (greeter.sessions.len > 1) {
            buf[n] = focus_session;
            n += 1;
        }
        buf[n..][0..2].* = .{ 3, 4 };
        return buf[0 .. n + 2];
    }

    fn moveFocus(self: *Lock, backward: bool) void {
        var buf: [7]u8 = undefined;
        const order = self.focusOrder(&buf);
        const at = std.mem.indexOfScalar(u8, order, self.focus) orelse 0;
        self.focus = order[(at + if (backward) order.len - 1 else 1) % order.len];
    }

    pub fn modifiers(self: *Lock, mods: wlr.Keyboard.ModifierMask) void {
        if (self.caps == mods.caps) return;
        self.caps = mods.caps;
        self.changed();
    }

    /// Which held keys `Keyboard` repeats: typing and caret keys in the
    /// field, and stepping through the greeter's account and session
    /// choices. Buttons, Return and Escape fire once.
    pub fn keyRepeats(self: *const Lock, sym: xkb.Keysym, utf8: []const u8) bool {
        if (self.busy()) return false;
        if (self.focus == 0) return @import("../input/repeat_keys.zig").editing(sym, utf8);
        if (self.focus == focus_account or self.focus == focus_session) {
            const value = @intFromEnum(sym);
            return value == xkb.Keysym.Left or value == xkb.Keysym.Right;
        }
        return false;
    }

    pub fn key(self: *Lock, sym: xkb.Keysym, utf8: []const u8, mods: wlr.Keyboard.ModifierMask) void {
        self.caps = mods.caps;
        self.caret_edit_ms = anim.nowMs();
        defer self.changed();
        const value = @intFromEnum(sym);
        if (value == xkb.Keysym.Escape) {
            self.clear();
            self.confirm = null;
            self.focus = 0;
            if (self.prompting()) {
                self.greeter.?.cancel();
                self.status = "Sign-in cancelled";
            } else if (!self.busy()) self.status = self.idleStatus();
            return;
        }
        if (self.busy()) return;
        switch (value) {
            xkb.Keysym.Tab, xkb.Keysym.ISO_Left_Tab => self.moveFocus(mods.shift or value == xkb.Keysym.ISO_Left_Tab),
            xkb.Keysym.Up, xkb.Keysym.Down => if (!self.prompting()) self.choose(focus_account, if (value == xkb.Keysym.Up) -1 else 1),
            xkb.Keysym.Left, xkb.Keysym.Right => if (self.focus == focus_account or self.focus == focus_session)
                self.choose(self.focus, if (value == xkb.Keysym.Left) -1 else 1)
            else if (self.focus == 0) {
                if (value == xkb.Keysym.Left) self.field().left() else self.field().right();
            },
            xkb.Keysym.Home => if (self.focus == 0) {
                self.input.cursor = 0;
            },
            xkb.Keysym.End => if (self.focus == 0) {
                self.input.cursor = self.input.len;
            },
            xkb.Keysym.Return, xkb.Keysym.KP_Enter => self.activate(self.focus),
            xkb.Keysym.space => {
                if (self.focus != 0) self.activate(self.focus) else _ = self.field().insert(" ");
            },
            xkb.Keysym.BackSpace => self.field().backspace(),
            xkb.Keysym.Delete => if (self.focus == 0) self.field().delete(),
            else => {
                if (mods.ctrl or mods.alt or mods.logo) return;
                if (utf8.len == 0 or utf8[0] < 32 or utf8[0] == 127) return;
                if (!self.field().insert(utf8)) return;
                self.focus = 0;
                self.confirm = null;
                if (!self.prompting()) self.status = self.idleStatus();
            },
        }
    }

    fn activate(self: *Lock, focus: u8) void {
        switch (focus) {
            0, 2 => self.submit(),
            1 => self.reveal = !self.reveal,
            3, 4 => {
                if (self.power_child != null) return;
                const reboot = focus == 4;
                if (self.confirm == null or self.confirm.? != reboot) {
                    self.clear();
                    self.confirm = reboot;
                    self.status = if (reboot) "Restart? Activate Restart again to confirm." else "Power off? Activate Power again to confirm.";
                    return;
                }
                self.confirm = null;
                // systemctl delegates to logind/polkit; no privileged syscall or
                // shell interpolation. Never request an interactive auth agent
                // behind the locked screen.
                var child = std.process.spawn(self.server.io, .{ .argv = &.{ "systemctl", if (reboot) "reboot" else "poweroff", "--no-ask-password", "--no-block" } }) catch {
                    self.status = "Power service unavailable";
                    return;
                };
                self.power_child = Child.watch(gpa, self.server.wl_server.getEventLoop(), child.id.?, self, powerExited) catch {
                    child.kill(self.server.io);
                    self.status = "Power service unavailable";
                    return;
                };
                self.status = "Requesting power action…";
            },
            focus_account, focus_session => self.choose(focus, 1),
            else => {},
        }
    }

    pub fn click(self: *Lock, x: f64, y: f64) void {
        if (self.controlsAt(x, y)) |at| {
            self.showControls();
            switch (at.hit.part) {
                .icon => if (at.hit.kind == .volume) lock_controls.toggleMute(self.server),
                .track => self.controls.beginDrag(self.server, at.hit.kind, at.left, at.span, @floatCast(x)),
            }
            self.server.scheduleFrames();
            return;
        }
        const out = Output.atLayout(self.server, x, y) orelse return;
        const b = out.cached_box;
        const geo = Geometry.init(@floatFromInt(b.width), @floatFromInt(b.height));
        const px: f32 = @floatCast(x - @as(f64, @floatFromInt(b.x)));
        const py: f32 = @floatCast(y - @as(f64, @floatFromInt(b.y)));
        // Design units, as the field is laid out.
        const dx = px / geo.s;
        const dy = py / geo.s;
        const box = geo.field();
        const eye = text_field.arrange(box, field_options, ui.theme.shellPalette()).trailing.?;
        if (dx >= box.x and dx <= box.x + box.w and dy >= box.y and dy <= box.y + box.h) {
            self.focus = if (dx >= eye.x) 1 else 0;
            if (self.focus == 1) self.activate(1);
        } else {
            const submit_box = geo.submit();
            if (dx >= submit_box.x and dx <= submit_box.x + submit_box.w and dy >= submit_box.y and dy <= submit_box.y + submit_box.h) {
                self.focus = 2;
                self.activate(2);
            }
        }
        if (self.greeter) |greeter| if (!self.busy()) {
            const ay = geo.top + 214 * geo.s;
            const cx = geo.w / 2;
            if (greeter.users.len > 1 and py >= ay and py <= ay + 120 * geo.s) {
                if (px >= cx - 150 * geo.s and px <= cx - 70 * geo.s) {
                    self.focus = focus_account;
                    self.choose(focus_account, -1);
                } else if (px >= cx + 70 * geo.s and px <= cx + 150 * geo.s) {
                    self.focus = focus_account;
                    self.choose(focus_account, 1);
                }
            }
            if (greeter.sessions.len > 1 and py >= geo.h - 100 * geo.s and py <= geo.h - 20 * geo.s and px <= 320 * geo.s) {
                self.focus = focus_session;
                self.choose(focus_session, 1);
            }
        };
        if (py >= geo.h - 100 * geo.s and py <= geo.h - 20 * geo.s) {
            if (px >= geo.w - 220 * geo.s and px < geo.w - 120 * geo.s) {
                self.focus = 3;
                self.activate(3);
            } else if (px >= geo.w - 120 * geo.s and px < geo.w - 20 * geo.s) {
                self.focus = 4;
                self.activate(4);
            }
        }
        self.changed();
    }
};

const ControlsAt = struct { hit: lock_controls.Hit, left: f32, span: f32 };

/// What the volume/brightness block of a `w` x `h` output has at an
/// output-local point: the control, and its track's left edge and width in
/// the same pixels.
fn controlsPick(controls: *const Controls, w: f32, h: f32, px: f32, py: f32) ?ControlsAt {
    if (controls.rows() == 0) return null;
    const geo = Geometry.init(w, h);
    const box = geo.controlsBox(controls.height());
    const origin_x: f32 = @floatFromInt(box.x);
    const origin_y: f32 = @floatFromInt(box.y);
    const hit = controls.pick((px - origin_x) / geo.s, (py - origin_y) / geo.s) orelse return null;
    return .{ .hit = hit, .left = origin_x + lock_controls.track_x * geo.s, .span = lock_controls.track_w * geo.s };
}

const unlock_hint = "Press Enter to unlock";
const login_hint = "Press Enter to log in";
const focus_account: u8 = 5;
const focus_session: u8 = 6;

const Geometry = struct {
    s: f32,
    w: f32,
    h: f32,
    left: f32,
    top: f32,
    fn init(w: f32, h: f32) Geometry {
        // ui_scale trims the whole panel (fonts, field, button) down from the
        // 600x900 design canvas's 1:1 cap — full size read as oversized on
        // typical outputs.
        const ui_scale: f32 = 0.85;
        const s = @min(1, @min(w / 600, h / 900)) * ui_scale;
        return .{ .w = w, .h = h, .s = s, .left = (w - 390 * s) / 2, .top = (h - 670 * s) / 2 - 20 * s };
    }

    /// The password field in design units: draw through `Renderer.zoomed(s)`.
    fn field(geo: Geometry) text_field.Rect {
        return .{ .x = geo.left / geo.s, .y = geo.top / geo.s + 430, .w = 390, .h = 56 };
    }

    /// Power (0) and Restart (1), bottom right, in the same units.
    fn powerAction(geo: Geometry, i: usize) text_field.Rect {
        const center = geo.w / geo.s - 170 + @as(f32, @floatFromInt(i)) * 100;
        return .{ .x = center - 45, .y = geo.h / geo.s - 96, .w = 90, .h = 76 };
    }

    /// The volume/brightness block of `block_h` design units, centred on the
    /// power buttons' band and horizontally on the screen, in whole layout
    /// pixels output-local. It never reaches the power buttons: the canvas is
    /// at least 705 design units wide, they start 215 from its right edge.
    fn controlsBox(geo: Geometry, block_h: f32) struct { x: i32, y: i32, w: i32, h: i32 } {
        const x = (geo.w / geo.s - lock_controls.width) / 2;
        const y = geo.h / geo.s - 58 - block_h / 2;
        return .{
            .x = @intFromFloat(@round(x * geo.s)),
            .y = @intFromFloat(@round(y * geo.s)),
            .w = @intFromFloat(@ceil(lock_controls.width * geo.s)),
            .h = @intFromFloat(@ceil(block_h * geo.s)),
        };
    }

    /// The Unlock / Log In button, in the same units.
    fn submit(geo: Geometry) text_field.Rect {
        return .{ .x = geo.left / geo.s, .y = geo.top / geo.s + 508, .w = 390, .h = 52 };
    }
};

const field_options: text_field.Options = .{ .size = .lg, .secret_dots = .{ .diameter = 0.46, .pitch = 1.05 }, .trailing = .reveal };

pub const View = struct {
    tree: *wlr.SceneTree,
    guard: *wlr.SceneRect,
    wallpaper: *wlr.SceneBuffer,
    ui_node: *wlr.SceneBuffer,
    /// The password field's caret, above `ui_node`: it blinks and glides
    /// without re-rastering the whole screen.
    caret: CaretOverlay,
    /// The volume/brightness block: its own small raster (`Lock.controls`),
    /// so dragging a slider never re-rasters the screen under it.
    controls_node: *wlr.SceneBuffer,
    controls_key: ?ControlsKey = null,
    revision: u64 = 0,
    width: i32 = 0,
    height: i32 = 0,
    scale: f32 = 0,

    pub fn create(parent: *wlr.SceneTree) !View {
        const tree = try parent.createSceneTree();
        errdefer tree.node.destroy();
        const guard = try col.createRect(tree, 0, 0, col.Straight.fromRgba(lockBackground()).premultiply());
        const wallpaper = try tree.createSceneBuffer(null);
        wallpaper.setOpacity(ui.theme.global.lock_wallpaper_opacity);
        wallpaper.setFilterMode(.bilinear);
        const node = try tree.createSceneBuffer(null);
        node.setFilterMode(.bilinear);
        const caret = try CaretOverlay.create(tree);
        const controls_node = try tree.createSceneBuffer(null);
        controls_node.setFilterMode(.bilinear);
        controls_node.node.setEnabled(false);
        tree.node.setEnabled(false);
        return .{ .tree = tree, .guard = guard, .wallpaper = wallpaper, .ui_node = node, .caret = caret, .controls_node = controls_node };
    }

    pub fn cover(self: *View, out: *Output) void {
        var box: wlr.Box = undefined;
        out.server.output_layout.getBox(out.wlr_output, &box);
        self.tree.node.setPosition(box.x, box.y);
        self.guard.setSize(box.width, box.height);
        col.setRect(self.guard, col.Straight.fromRgba(lockBackground()).premultiply());
        self.wallpaper.setOpacity(ui.theme.global.lock_wallpaper_opacity);
        self.tree.node.setEnabled(true);
        out.server.lock_tree.node.raiseToTop();
    }

    pub fn hide(self: *View) void {
        self.tree.node.setEnabled(false);
        self.ui_node.setBuffer(null);
        self.wallpaper.setBuffer(null);
        self.caret.hide();
        self.hideControls();
        self.revision = 0;
        Buffer.drainPool();
    }

    fn hideControls(self: *View) void {
        self.controls_node.node.setEnabled(false);
        self.controls_node.setBuffer(null);
        self.controls_key = null;
    }

    /// Rasters the volume/brightness block when it, or the output it sits
    /// on, changed. The greeter and an output without either backend show none.
    fn syncControls(self: *View, lock: *Lock, b: wlr.Box, scale: f32) void {
        const block_h = lock.controls.height();
        if (lock.greeter != null or !lock.controls_visible or block_h == 0 or b.width <= 0 or b.height <= 0) return self.hideControls();
        const key = ControlsKey{ .revision = lock.controls.revision, .width = b.width, .height = b.height, .scale = scale };
        if (self.controls_key) |have| if (std.meta.eql(have, key)) return;
        const geo = Geometry.init(@floatFromInt(b.width), @floatFromInt(b.height));
        const box = geo.controlsBox(block_h);
        const buf = Buffer.createUnpooled(box.w, box.h, scale) catch return;
        defer buf.base.drop();
        var renderer = ui.paint.Renderer.init(buf.pixels, buf.width, buf.height, scale);
        var zoomed = renderer.zoomed(geo.s);
        zoomed.palette = ui.theme.shellPalette();
        lock.controls.paint(&zoomed);
        buf.publish(self.controls_node, scale, null);
        self.controls_node.setDestSize(box.w, box.h);
        self.controls_node.node.setPosition(box.x, box.y);
        self.controls_node.node.setEnabled(true);
        self.controls_key = key;
    }

    /// Returns whether the field's caret still wants frames.
    pub fn sync(self: *View, out: *Output) bool {
        const lock = out.server.locker orelse return false;
        self.cover(out);
        // A lock client's surface replaces the built-in screen, which stays
        // ready underneath in case the client dies.
        const covered = if (lock.client) |client| blk: {
            client.syncOutput(out);
            break :blk client.covers(out);
        } else false;
        self.ui_node.node.setEnabled(!covered);
        self.wallpaper.node.setEnabled(!covered);
        if (covered) {
            self.caret.hide();
            self.hideControls();
            return false;
        }
        const b = out.cached_box;
        const scale = out.wlr_output.scale;
        const now = anim.nowMs();
        self.syncControls(lock, b, scale);
        if (self.revision == lock.revision and self.width == b.width and self.height == b.height and self.scale == scale) return self.caret.frame(now);
        if (b.width <= 0 or b.height <= 0) return false;
        // Drop stale pixels before a failed resize allocation.
        self.ui_node.setBuffer(null);
        if (out.server.wallpaper) |image| {
            self.wallpaper.setBuffer(&image.base);
            self.wallpaper.setDestSize(b.width, b.height);
        }
        const buf = Buffer.create(b.width, b.height, scale) catch return false;
        defer buf.base.drop();
        buf.sensitive = true;
        var renderer = ui.paint.Renderer{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = scale };
        const painted = paint(&renderer, lock, @floatFromInt(b.width), @floatFromInt(b.height), lock.server.config.region.clock_24h);
        self.caret.update(now, if (painted.caret) |place| .{
            .caret = place,
            .origin_x = 0,
            .origin_y = 0,
            .factor = painted.factor,
            .scale = scale,
            .color = ui.theme.shellPalette().caretColor(),
        } else null, lock.caret_edit_ms);
        self.ui_node.setBuffer(&buf.base);
        self.ui_node.setDestSize(b.width, b.height);
        self.revision = lock.revision;
        self.width = b.width;
        self.height = b.height;
        self.scale = scale;
        return self.caret.frame(now);
    }
};

const ControlsKey = struct { revision: u64, width: i32, height: i32, scale: f32 };

fn lockBackground() [4]f32 {
    var bg = ui.theme.global.lock_bg;
    bg[3] = 1;
    return bg;
}
fn label(r: *ui.paint.Renderer, cx: f32, y: f32, width: f32, height: f32, value: []const u8, size: f32, color: [4]f32) void {
    const measured = text.measureWidthF(value, .manrope, size, r.scale) catch width;
    const w = @min(width, measured + 1);
    r.drawText(cx - w / 2, y, w, height, .{ .content = value, .font_size = size, .color = color });
}

/// Where the field's caret went, in design units `factor` layout pixels
/// wide; the caret itself is the view's overlay.
const Painted = struct { caret: ?ui.widgets.secret_input.Input.CaretPlace, factor: f32 };

fn paint(r: *ui.paint.Renderer, lock: *Lock, w: f32, h: f32, clock_24h: bool) Painted {
    const fg = ui.theme.global.lock_fg;
    const muted = ui.theme.global.lock_dim;
    const geo = Geometry.init(w, h);
    const s = geo.s;
    const y = geo.top;
    const cx = w / 2;
    var raw = c.time(null);
    var tm: c.struct_tm = undefined;
    var time_buf: [32]u8 = @splat(0);
    var date_buf: [96]u8 = @splat(0);
    var period: [16]u8 = @splat(0);
    if (c.localtime_r(&raw, &tm) != null) {
        _ = c.strftime(&time_buf, time_buf.len, if (clock_24h) "%H:%M" else "%l:%M", &tm);
        if (!clock_24h) _ = c.strftime(&period, period.len, "%p", &tm);
        _ = c.strftime(&date_buf, date_buf.len, "%A, %B %-d", &tm);
    }
    const time_str = std.mem.trim(u8, std.mem.sliceTo(&time_buf, 0), " ");
    const period_str = std.mem.sliceTo(&period, 0);
    const tw = text.measureWidthF(time_str, .manrope, 100 * s, r.scale) catch 220 * s;
    const pw = text.measureWidthF(period_str, .manrope, 64 * s, r.scale) catch 100 * s;
    const period_gap: f32 = if (period_str.len == 0) 0 else 20 * s;
    const start = cx - (tw + pw + period_gap) / 2;
    r.drawText(start, y, tw + 2, 110 * s, .{ .content = time_str, .font_size = 100 * s, .color = fg });
    r.drawText(start + tw + period_gap, y + 24 * s, pw + 2, 86 * s, .{ .content = period_str, .font_size = 64 * s, .color = muted });
    label(r, cx, y + 110 * s, w, 45 * s, std.mem.sliceTo(&date_buf, 0), 30 * s, muted);
    r.fillRect(cx - 35 * s, y + 174 * s, 70 * s, 2 * s, .{ .color = muted });
    // Shared components draw in the 600x900 design units the layout uses.
    var zoomed = r.zoomed(s);
    zoomed.palette = ui.theme.shellPalette();
    const avatar_image: ?ui.paint.Image = if (lock.avatar) |image| .{ .pixels = image.pixels, .width = image.width, .height = image.height } else null;
    ui.widgets.avatar.paint(&zoomed, cx / s - 60, y / s + 214, 120, .{ .image = avatar_image, .ring = true });
    const name = std.mem.sliceTo(&lock.name, 0);
    label(r, cx, y + 343 * s, 500 * s, 36 * s, if (name.len > 0) name else std.mem.sliceTo(&lock.user, 0), 25 * s, fg);
    label(r, cx, y + 380 * s, 500 * s, 30 * s, std.mem.sliceTo(&lock.user, 0), 18 * s, muted);
    if (lock.greeter) |greeter| paintChoices(r, lock, greeter, geo, h);
    const field = text_field.paintSecret(&zoomed, geo.field(), field_options, .{
        .focused = lock.focus == 0,
        .disabled = lock.busy(),
        .revealed = lock.reveal,
        .trailing_focused = lock.focus == 1,
        .external_caret = true,
    }, lock.field(), if (lock.prompting()) "Response" else "Password");
    const action = if (lock.greeter != null)
        (if (lock.busy()) "Signing in…" else if (lock.prompting()) "Continue" else "Log In")
    else if (lock.busy()) "Checking…" else "Unlock";
    ui.widgets.button.paint(&zoomed, geo.submit(), .{
        .variant = .primary,
        .size = .lg,
        .label = action,
        .trailing_icon = .chevron_right,
    }, .{ .pointer = if (lock.busy()) .disabled else .idle, .focused = lock.focus == 2 });
    label(r, cx, y + 590 * s, w - 20, 32 * s, if (lock.caps and std.mem.eql(u8, lock.status, lock.idleStatus())) "Caps Lock is on" else lock.status, 16 * s, muted);
    for (0..2) |i| ui.widgets.button.paint(&zoomed, geo.powerAction(i), .{
        .variant = .ghost,
        .size = .sm,
        .stacked = true,
        .leading_icon = if (i == 0) .power else .reboot,
        .label = if (i == 0) "Power" else "Restart",
    }, .{ .focused = lock.focus == 3 + i });
    r.fillRect(w - 120 * s, h - 90 * s, s, 34 * s, .{ .color = ui.theme.global.lock_divider });
    return .{ .caret = field.caret, .factor = s };
}

/// Greeter: account arrows beside the picture, session chooser bottom-left.
fn paintChoices(r: *ui.paint.Renderer, lock: *const Lock, greeter: *const Greeter, geo: Geometry, h: f32) void {
    const fg = ui.theme.global.lock_fg;
    const muted = ui.theme.global.lock_dim;
    const s = geo.s;
    const cx = geo.w / 2;
    const ay = geo.top + 214 * s;
    const idle = greeter.phase == .idle;
    if (greeter.users.len > 1) {
        if (lock.focus == focus_account) r.fillRect(cx - 150 * s, ay - 6 * s, 300 * s, 205 * s, .{ .color = .{ 0, 0, 0, 0 }, .radius = 14 * s, .border_width = s, .border_color = fg });
        if (idle) {
            var zoomed = r.zoomed(s);
            zoomed.palette = ui.theme.shellPalette();
            for ([_]f32{ -1, 1 }) |side| ui.widgets.button.paint(&zoomed, .{ .x = cx / s + side * 110 - 22, .y = ay / s + 30, .w = 44, .h = 60 }, .{
                .variant = .ghost,
                .icon = if (side < 0) .chevron_left else .chevron_right,
                .icon_scale = 0.7,
                .label = if (side < 0) "Previous account" else "Next account",
            }, .{});
        }
    }
    const session = greeter.selectedSession() orelse return;
    const color = if (lock.focus == focus_session) fg else muted;
    const x = 30 * s;
    const name_w = @min(280 * s, (text.measureWidthF(session.name, .manrope, 16 * s, r.scale) catch 280 * s) + 1);
    r.drawText(x, h - 90 * s, name_w, 30 * s, .{ .content = session.name, .font_size = 16 * s, .color = if (lock.focus == focus_session) fg else ui.theme.global.lock_session_fg });
    const caption = if (greeter.sessions.len > 1) "Session  ›" else "Session";
    const caption_w = (text.measureWidthF(caption, .manrope, 13 * s, r.scale) catch 90 * s) + 1;
    r.drawText(x, h - 54 * s, caption_w, 24 * s, .{ .content = caption, .font_size = 13 * s, .color = color });
    if (lock.focus == focus_session) r.fillRect(x - 12 * s, h - 96 * s, @max(name_w, caption_w) + 24 * s, 76 * s, .{ .color = .{ 0, 0, 0, 0 }, .radius = 10 * s, .border_width = s, .border_color = fg });
}

test "lock password editing clears complete UTF-8 characters and Escape never unlocks" {
    var server: Server = undefined;
    server.polkit = null;
    server.outputs.init();
    var lock = Lock{ .server = &server, .timer = undefined };
    server.locker = &lock;
    lock.key(@enumFromInt('a'), "a", .{});
    lock.key(@enumFromInt('e'), "é", .{});
    try std.testing.expectEqualStrings("aé", lock.field().value());
    lock.key(@enumFromInt(xkb.Keysym.BackSpace), "", .{});
    try std.testing.expectEqualStrings("a", lock.field().value());
    try std.testing.expectEqual(@as(u8, 0), lock.password[2]);
    lock.reveal = true;
    lock.key(@enumFromInt(xkb.Keysym.Escape), "", .{});
    try std.testing.expect(server.locker == &lock);
    try std.testing.expect(!lock.reveal);
    try std.testing.expectEqual(@as(usize, 0), lock.input.len);
    for (lock.password) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    // Oversized input must not produce a partial UTF-8 sequence or overrun.
    const full = [_]u8{'a'} ** 511;
    lock.key(@enumFromInt('a'), &full, .{});
    lock.key(@enumFromInt('e'), "é", .{});
    try std.testing.expectEqual(@as(usize, 511), lock.input.len);
    try std.testing.expectEqual(@as(u8, 0), lock.password[511]);
    lock.clear();
}

test "lock IPC and client focus requests stop before touching desktop state" {
    var server: Server = undefined;
    var lock = Lock{ .server = &server, .timer = undefined };
    server.locker = &lock;
    const response = try @import("../ipc/handlers.zig").handleRequest(&server, null, .version, std.testing.allocator, null);
    try std.testing.expectEqualStrings("SessionLocked", response.err);
    var world: @import("../World.zig") = undefined;
    world.server = &server;
    var top: @import("../Toplevel.zig") = undefined;
    world.focusSurface(&top, null);
    var layer: @import("../LayerSurface.zig") = undefined;
    layer.server = &server;
    layer.focus();
    var input: @import("../Input.zig") = undefined;
    input.server = &server;
    input.processCursorMotion(1);
    input.warpCursor(100, 100, 1);
    // These deliberately undefined desktop structures would fault if any of
    // the locked guards reached their ordinary client-facing paths.
}

test "lock output guard is opaque independent of wallpaper and UI buffers" {
    const scene = try wlr.Scene.create();
    defer scene.tree.node.destroy();
    var view = try View.create(&scene.tree);
    try std.testing.expect(!view.tree.node.enabled);
    try std.testing.expectEqual(@as(f32, 1), view.guard.color[3]);
    view.tree.node.setEnabled(true);
    view.guard.setSize(1920, 1080);
    try std.testing.expectEqual(@as(i32, 1920), view.guard.width);
    try std.testing.expect(view.ui_node.buffer == null);
    view.hide();
    try std.testing.expect(!view.tree.node.enabled);
}

test "lock raster scales to small outputs and renders a solid accent unlock button" {
    var lock = Lock{ .server = undefined, .timer = undefined, .controls_visible = true };
    @memcpy(lock.name[0..11], "Alex Morgan");
    @memcpy(lock.user[0..10], "alexmorgan");
    lock.controls = .{ .has_volume = true, .volume = 0.5, .has_brightness = true, .brightness = 0.25 };
    const scene = try wlr.Scene.create();
    defer scene.tree.node.destroy();
    var view = try View.create(&scene.tree);
    for ([_][3]i32{ .{ 1672, 941, 1 }, .{ 640, 480, 1 }, .{ 1280, 720, 2 } }) |size| {
        const scale: f32 = if (size[2] == 2) 1.5 else 1;
        const buf = try Buffer.create(size[0], size[1], scale);
        defer buf.base.drop();
        @memset(buf.pixels, 0xff090b12);
        var renderer = ui.paint.Renderer{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = scale };
        _ = paint(&renderer, &lock, @floatFromInt(size[0]), @floatFromInt(size[1]), size[0] == 640);
        const geo = Geometry.init(@floatFromInt(size[0]), @floatFromInt(size[1]));
        const px: usize = @intFromFloat((geo.left + 15 * geo.s) * scale);
        const py: usize = @intFromFloat((geo.top + 530 * geo.s) * scale);
        // The volume/brightness block is its own raster, bottom centre, and
        // never reaches the power buttons however small the output.
        view.syncControls(&lock, .{ .x = 0, .y = 0, .width = size[0], .height = size[1] }, scale);
        const placed = geo.controlsBox(lock.controls.height());
        const node = &view.controls_node.node;
        try std.testing.expect(node.enabled and view.controls_node.buffer != null);
        try std.testing.expectEqual(placed.x, node.x);
        try std.testing.expectEqual(placed.y, node.y);
        try std.testing.expect(node.y >= 0 and node.y + placed.h <= size[1]);
        try std.testing.expect(node.x + placed.w <= @as(i32, @intFromFloat(geo.powerAction(0).x * geo.s)));
        // Pointer: the volume track is found where it is drawn, and a drag
        // maps the pointer across exactly that track, clamped at its ends.
        var no_audio: Server = undefined;
        no_audio.audio = null;
        const w: f32 = @floatFromInt(size[0]);
        const h: f32 = @floatFromInt(size[1]);
        const row_y: f32 = @as(f32, @floatFromInt(placed.y)) + 16 * geo.s;
        const track = controlsPick(&lock.controls, w, h, @as(f32, @floatFromInt(placed.x)) + 100 * geo.s, row_y) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(lock_controls.Kind.volume, track.hit.kind);
        try std.testing.expectEqual(lock_controls.Part.track, track.hit.part);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(placed.x)) + lock_controls.track_x * geo.s, track.left, 0.01);
        try std.testing.expectEqual(lock_controls.Part.icon, controlsPick(&lock.controls, w, h, @as(f32, @floatFromInt(placed.x)) + 10 * geo.s, row_y).?.hit.part);
        try std.testing.expectEqual(lock_controls.Kind.brightness, controlsPick(&lock.controls, w, h, @as(f32, @floatFromInt(placed.x)) + 100 * geo.s, row_y + 40 * geo.s).?.hit.kind);
        try std.testing.expect(controlsPick(&lock.controls, w, h, w / 2, h / 4) == null);
        var drag = lock.controls;
        drag.beginDrag(&no_audio, .volume, track.left, track.span, track.left + track.span * 0.75);
        try std.testing.expectApproxEqAbs(@as(f32, 0.75), drag.volume, 0.0001);
        drag.dragTo(&no_audio, track.left + track.span * 3);
        try std.testing.expectEqual(@as(f32, 1), drag.volume);
        drag.dragTo(&no_audio, track.left - 50);
        try std.testing.expectEqual(@as(f32, 0), drag.volume);
        try std.testing.expect(drag.endDrag() and !drag.endDrag());
        const actual = buf.pixels[py * @as(usize, @intCast(buf.width)) + px];
        try std.testing.expectEqual(@as(u32, 255), actual >> 24);
        inline for (.{ 16, 8, 0 }, 0..) |shift, channel| {
            const got: f32 = @floatFromInt((actual >> shift) & 255);
            try std.testing.expectApproxEqAbs(ui.theme.shellPalette().accent[channel] * 255, got, 1);
        }
        if (size[0] == 1672) {
            const env = @cImport({
                @cInclude("stdlib.h");
            });
            if (env.getenv("REDIWM_LOCK_PREVIEW")) |path| {
                const bytes = try @import("../screenshot/encode.zig").encodePng(std.testing.allocator, @intCast(buf.width), @intCast(buf.height), buf.pixels, @intCast(buf.width));
                defer std.testing.allocator.free(bytes);
                try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = std.mem.span(path), .data = bytes });
            }
        }
    }
    // No backend, no block: the greeter and a desktop without a backlight or
    // a sound server show nothing there.
    lock.controls = .{};
    view.syncControls(&lock, .{ .x = 0, .y = 0, .width = 1280, .height = 720 }, 1);
    try std.testing.expect(!view.controls_node.node.enabled and view.controls_node.buffer == null);
    Buffer.drainPool();
}

test "lock authentication failure stays locked and success releases lock state" {
    // This symbol is provided exclusively by tests/auth_test.c, never by the
    // production executable. It controls PAM results at link time.
    const fixture = struct {
        extern fn rediwm_test_auth_scenario(c_int) void;
    };
    const display = try wl.Server.create();
    defer display.destroy();
    const seat = try wlr.Seat.create(display, "lock-test");
    defer seat.destroy();
    var server: Server = undefined;
    // Resume the real agent only after successful PAM, without opening a bus.
    var conn: @import("dbus").Connection = undefined;
    conn.closed = true;
    var agent = @import("../polkit/agent.zig").Agent{
        .allocator = gpa,
        .conn = &conn,
        .loop = display.getEventLoop(),
        .locale = "C",
        .suspended = true,
    };
    server.polkit = &agent;
    server.wl_server = display;
    server.outputs.init();
    server.world.toplevels.init();
    server.input.seat = seat;
    // Releasing announces the unlock: no supervisor fd and no logind here.
    server.environ = std.process.Environ.empty;
    server.power = null;
    for ([_]c_int{ 1, 2, 3, 4, 0 }) |scenario| {
        fixture.rediwm_test_auth_scenario(scenario);
        const lock = try gpa.create(Lock);
        lock.* = .{ .server = &server, .timer = undefined };
        lock.timer = try display.getEventLoop().addTimer(*Lock, Lock.tick, lock);
        server.locker = lock;
        try std.testing.expect(lock.field().insert("fixture-password"));
        lock.submit();
        try std.testing.expectEqual(@as(usize, 0), lock.input.len);
        try std.testing.expect(lock.auth != null);
        for (0..10000) |_| {
            if (rediwm_auth_poll(lock.auth.?) != 0) break;
            _ = c.usleep(1000);
        }
        try std.testing.expect(rediwm_auth_poll(lock.auth.?) != 0);
        // The worker's eventfd, not a timer, reports the result.
        try std.testing.expect(lock.auth_source != null);
        try display.getEventLoop().dispatch(1000);
        if (scenario == 0) {
            try std.testing.expect(server.locker == null);
            try std.testing.expect(!agent.suspended);
        } else {
            try std.testing.expect(server.locker == lock);
            try std.testing.expect(agent.suspended);
            try std.testing.expect(lock.auth == null);
            try std.testing.expect(lock.retry_at > @import("ui").anim.nowMs());
            for (lock.password) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
            lock.destroy();
            server.locker = null;
        }
    }
}

test "lock covers new outputs and follows layout and mode changes without UI" {
    const display = try wl.Server.create();
    defer display.destroy();
    const backend = try wlr.Backend.createHeadless(display.getEventLoop());
    defer backend.destroy();
    const output_layout = try wlr.OutputLayout.create(display);
    defer output_layout.destroy();
    const scene = try wlr.Scene.create();
    defer scene.tree.node.destroy();
    var server: Server = undefined;
    server.output_layout = output_layout;
    server.lock_tree = try scene.tree.createSceneTree();
    for (0..2) |i| {
        const output = try backend.headlessAddOutput(1280, 720);
        var state = wlr.Output.State.init();
        defer state.finish();
        state.setEnabled(true);
        try std.testing.expect(output.commitState(&state));
        const x: i32 = if (i == 0) -1280 else 0;
        _ = try output_layout.add(output, x, 100);
        var out = Output{ .server = &server, .wlr_output = output, .lock_view = try View.create(server.lock_tree) };
        out.lock_view.cover(&out);
        try std.testing.expect(out.lock_view.tree.node.enabled);
        try std.testing.expectEqual(x, out.lock_view.tree.node.x);
        try std.testing.expectEqual(@as(i32, 100), out.lock_view.tree.node.y);
        try std.testing.expectEqual(@as(i32, 1280), out.lock_view.guard.width);
        try std.testing.expectEqual(@as(i32, 720), out.lock_view.guard.height);
        try std.testing.expect(out.lock_view.ui_node.buffer == null);
        state.setCustomMode(1920, 1080, 60000);
        try std.testing.expect(output.commitState(&state));
        _ = try output_layout.add(output, x, -50);
        out.lock_view.cover(&out);
        try std.testing.expectEqual(@as(i32, 1920), out.lock_view.guard.width);
        try std.testing.expectEqual(@as(i32, 1080), out.lock_view.guard.height);
        try std.testing.expectEqual(@as(i32, -50), out.lock_view.tree.node.y);
    }
}

test "greeter signs in through rediwm-dm and exits only once the session starts" {
    const sock = @cImport({
        @cInclude("sys/socket.h");
        @cInclude("unistd.h");
    });
    const peer = struct {
        fd: c_int,
        buf: [4096]u8 = undefined,
        fn read(self: *@This()) ![]const u8 {
            var header: [4]u8 = undefined;
            if (sock.read(self.fd, &header, 4) != 4) return error.Short;
            const n = std.mem.readInt(u32, &header, @import("builtin").cpu.arch.endian());
            var got: usize = 0;
            while (got < n) {
                const r = sock.read(self.fd, self.buf[got..].ptr, n - got);
                if (r <= 0) return error.Short;
                got += @intCast(r);
            }
            return self.buf[0..n];
        }
        fn write(self: *@This(), json: []const u8) void {
            var header: [4]u8 = undefined;
            std.mem.writeInt(u32, &header, @intCast(json.len), @import("builtin").cpu.arch.endian());
            _ = sock.write(self.fd, &header, 4);
            _ = sock.write(self.fd, json.ptr, json.len);
        }
    };
    const display = try wl.Server.create();
    defer display.destroy();
    var server: Server = undefined;
    server.outputs.init();
    server.wl_server = display;
    server.io = std.testing.io;
    server.shutting_down = false;
    server.layout_autosave = null;
    var users = [_]greeter_mod.User{
        .{ .name = "rediwm-test-a", .real = "Test A", .home = "", .uid = 1000 },
        .{ .name = "rediwm-test-b", .real = "", .home = "", .uid = 1001 },
    };
    var sessions = [_]greeter_mod.Session{
        .{ .id = "rediwm", .name = "RediWM", .exec = "/usr/local/bin/rediwm-session", .desktops = "rediwm" },
        .{ .id = "sway", .name = "Sway", .exec = "sway", .desktops = "sway" },
    };
    // Greeter.destroy frees through libc, as Greeter.create allocates.
    const greeter = try std.heap.c_allocator.create(Greeter);
    greeter.* = .{ .arena = .init(std.heap.c_allocator), .io = std.testing.io, .loop = display.getEventLoop(), .users = &users, .sessions = &sessions };
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), sock.socketpair(sock.AF_UNIX, sock.SOCK_STREAM | sock.SOCK_CLOEXEC, 0, &fds));
    defer _ = sock.close(fds[1]);
    try greeter.adopt(fds[0]);
    var daemon = peer{ .fd = fds[1] };
    var lock = Lock{ .server = &server, .timer = undefined, .greeter = greeter };
    greeter.owner = &lock;
    greeter.notify = Lock.greeterEvent;
    server.locker = &lock;
    defer {
        greeter.destroy();
        if (lock.avatar) |avatar| avatar.deinit(gpa);
        lock.clear();
    }
    lock.showAccount();
    try std.testing.expectEqualStrings("rediwm-test-a", std.mem.sliceTo(&lock.user, 0));

    // Account and session choice.
    lock.key(@enumFromInt(xkb.Keysym.Down), "", .{});
    try std.testing.expectEqualStrings("rediwm-test-b", std.mem.sliceTo(&lock.user, 0));
    lock.key(@enumFromInt(xkb.Keysym.Up), "", .{});
    try std.testing.expectEqualStrings("Test A", std.mem.sliceTo(&lock.name, 0));
    lock.key(@enumFromInt(xkb.Keysym.ISO_Left_Tab), "", .{ .shift = true });
    try std.testing.expectEqual(focus_account, lock.focus);
    lock.key(@enumFromInt(xkb.Keysym.Tab), "", .{});
    try std.testing.expectEqual(@as(u8, 0), lock.focus);
    for (0..3) |_| lock.key(@enumFromInt(xkb.Keysym.Tab), "", .{});
    try std.testing.expectEqual(focus_session, lock.focus);
    lock.key(@enumFromInt(xkb.Keysym.Right), "", .{});
    try std.testing.expectEqualStrings("sway", greeter.selectedSession().?.id);
    lock.key(@enumFromInt(xkb.Keysym.Left), "", .{});
    lock.focus = 0;

    // The password typed up front answers dm's first question.
    for ("pw") |ch| lock.key(@enumFromInt(ch), &.{ch}, .{});
    lock.key(@enumFromInt(xkb.Keysym.Return), "", .{});
    try std.testing.expectEqualStrings("{\"type\":\"login\",\"user\":\"rediwm-test-a\"}", try daemon.read());
    try std.testing.expectEqual(@as(usize, 0), lock.input.len);
    lock.key(@enumFromInt('x'), "x", .{});
    try std.testing.expectEqual(@as(usize, 0), lock.input.len);
    try std.testing.expect(lock.busy());
    daemon.write("{\"type\":\"question\",\"kind\":\"secret\",\"text\":\"Password:\"}");
    greeter.pump();
    try std.testing.expectEqualStrings("{\"type\":\"answer\",\"response\":\"pw\"}", try daemon.read());
    for (greeter.pending) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    // A second factor is asked of the user; info messages need an empty reply.
    daemon.write("{\"type\":\"question\",\"kind\":\"info\",\"text\":\"Touch the key\"}");
    greeter.pump();
    try std.testing.expectEqualStrings("Touch the key", lock.status);
    try std.testing.expectEqualStrings("{\"type\":\"answer\",\"response\":null}", try daemon.read());
    daemon.write("{\"type\":\"question\",\"kind\":\"visible\",\"text\":\"Code: \"}");
    greeter.pump();
    try std.testing.expectEqualStrings("Code:", lock.status);
    try std.testing.expect(lock.prompting() and lock.reveal and !lock.busy());
    for ("123") |ch| lock.key(@enumFromInt(ch), &.{ch}, .{});
    try std.testing.expectEqualStrings("Code:", lock.status);
    lock.key(@enumFromInt(xkb.Keysym.Return), "", .{});
    try std.testing.expectEqualStrings("{\"type\":\"answer\",\"response\":\"123\"}", try daemon.read());

    // Wrong answers cancel the attempt and never start a session.
    daemon.write("{\"type\":\"denied\",\"text\":\"pam_authenticate: AUTH_ERR\"}");
    greeter.pump();
    try std.testing.expectEqualStrings("Incorrect password. Try again.", lock.status);
    try std.testing.expectEqualStrings("{\"type\":\"cancel\"}", try daemon.read());
    daemon.write("{\"type\":\"ok\"}");
    greeter.pump();
    try std.testing.expectEqual(greeter_mod.Phase.idle, greeter.phase);
    try std.testing.expect(!server.shutting_down);

    // Escape abandons a question.
    lock.retry_at = 0;
    for ("pw") |ch| lock.key(@enumFromInt(ch), &.{ch}, .{});
    lock.key(@enumFromInt(xkb.Keysym.Return), "", .{});
    _ = try daemon.read();
    daemon.write("{\"type\":\"question\",\"kind\":\"secret\",\"text\":\"Password:\"}");
    greeter.pump();
    _ = try daemon.read();
    daemon.write("{\"type\":\"question\",\"kind\":\"secret\",\"text\":\"New password:\"}");
    greeter.pump();
    lock.key(@enumFromInt(xkb.Keysym.Escape), "", .{});
    try std.testing.expectEqualStrings("{\"type\":\"cancel\"}", try daemon.read());
    daemon.write("{\"type\":\"ok\"}");
    greeter.pump();
    try std.testing.expectEqual(greeter_mod.Phase.idle, greeter.phase);

    // Success starts the chosen session with its desktop identity, and the
    // greeter exits only after dm accepts it.
    for ("pw") |ch| lock.key(@enumFromInt(ch), &.{ch}, .{});
    lock.key(@enumFromInt(xkb.Keysym.Return), "", .{});
    _ = try daemon.read();
    daemon.write("{\"type\":\"ok\"}");
    greeter.pump();
    try std.testing.expectEqualStrings(
        "{\"type\":\"start\",\"session\":\"rediwm\"}",
        try daemon.read(),
    );
    for (greeter.pending) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expect(!server.shutting_down);
    lock.key(@enumFromInt(xkb.Keysym.Down), "", .{});
    try std.testing.expectEqualStrings("rediwm-test-a", std.mem.sliceTo(&lock.user, 0));
    daemon.write("{\"type\":\"ok\"}");
    greeter.pump();
    try std.testing.expect(server.shutting_down);
    try std.testing.expectEqual(greeter_mod.Phase.done, greeter.phase);
}

test "greeter reports a lost login service and exits to be replaced" {
    const sock = @cImport({
        @cInclude("sys/socket.h");
        @cInclude("unistd.h");
    });
    const display = try wl.Server.create();
    defer display.destroy();
    var server: Server = undefined;
    server.outputs.init();
    server.wl_server = display;
    server.shutting_down = false;
    server.layout_autosave = null;
    var users = [_]greeter_mod.User{.{ .name = "rediwm-test-a", .real = "", .home = "", .uid = 1000 }};
    var sessions = [_]greeter_mod.Session{.{ .id = "rediwm", .name = "RediWM", .exec = "rediwm-session", .desktops = "rediwm" }};
    const greeter = try std.heap.c_allocator.create(Greeter);
    greeter.* = .{ .arena = .init(std.heap.c_allocator), .io = std.testing.io, .loop = display.getEventLoop(), .users = &users, .sessions = &sessions };
    var lock = Lock{ .server = &server, .timer = undefined, .greeter = greeter };
    greeter.owner = &lock;
    greeter.notify = Lock.greeterEvent;
    defer {
        greeter.destroy();
        lock.clear();
    }
    // No REDIWM_GREETER_FD: a clear message, not a crash or an unlock.
    for ("pw") |ch| lock.key(@enumFromInt(ch), &.{ch}, .{});
    lock.key(@enumFromInt(xkb.Keysym.Return), "", .{});
    try std.testing.expectEqualStrings("No login service", lock.status);
    try std.testing.expectEqual(@as(usize, 0), lock.input.len);
    try std.testing.expectEqual(greeter_mod.Phase.idle, greeter.phase);

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), sock.socketpair(sock.AF_UNIX, sock.SOCK_STREAM | sock.SOCK_CLOEXEC, 0, &fds));
    try greeter.adopt(fds[0]);
    for ("pw") |ch| lock.key(@enumFromInt(ch), &.{ch}, .{});
    lock.key(@enumFromInt(xkb.Keysym.Return), "", .{});
    try std.testing.expect(lock.busy());
    _ = sock.close(fds[1]);
    greeter.pump();
    try std.testing.expectEqualStrings("Lost contact with login service. Try again.", lock.status);
    try std.testing.expect(!lock.busy() and greeter.client == null);
    try std.testing.expect(server.shutting_down);
    for (greeter.pending) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "greeter raster shows account arrows and the session chooser" {
    var users = [_]greeter_mod.User{
        .{ .name = "alexmorgan", .real = "Alex Morgan", .home = "", .uid = 1000 },
        .{ .name = "sam", .real = "", .home = "", .uid = 1001 },
    };
    var sessions = [_]greeter_mod.Session{
        .{ .id = "rediwm", .name = "RediWM", .exec = "", .desktops = "" },
        .{ .id = "sway", .name = "Sway", .exec = "", .desktops = "" },
    };
    var greeter = Greeter{ .arena = .init(gpa), .io = undefined, .loop = undefined, .users = &users, .sessions = &sessions };
    defer greeter.arena.deinit();
    var lock = Lock{ .server = undefined, .timer = undefined, .greeter = &greeter, .focus = focus_session };
    lock.status = lock.idleStatus();
    @memcpy(lock.name[0..11], "Alex Morgan");
    @memcpy(lock.user[0..10], "alexmorgan");
    const width = 1672;
    const height = 941;
    const buf = try Buffer.create(width, height, 1);
    defer buf.base.drop();
    @memset(buf.pixels, 0xff090b12);
    var renderer = ui.paint.Renderer{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = 1 };
    _ = paint(&renderer, &lock, width, height, false);
    const geo = Geometry.init(width, height);
    // Something is drawn in the session corner and beside the picture.
    const lit = struct {
        fn any(b: *Buffer, x0: f32, y0: f32, x1: f32, y1: f32) bool {
            var y: usize = @intFromFloat(y0);
            while (y < @as(usize, @intFromFloat(y1))) : (y += 1) {
                var x: usize = @intFromFloat(x0);
                while (x < @as(usize, @intFromFloat(x1))) : (x += 1) {
                    if (b.pixels[y * @as(usize, @intCast(b.width)) + x] & 0xff != 0x12) return true;
                }
            }
            return false;
        }
    };
    try std.testing.expect(lit.any(buf, 30 * geo.s, height - 90 * geo.s, 120 * geo.s, height - 60 * geo.s));
    try std.testing.expect(lit.any(buf, width / 2 - 130 * geo.s, geo.top + 244 * geo.s, width / 2 - 90 * geo.s, geo.top + 304 * geo.s));
    const env = @cImport({
        @cInclude("stdlib.h");
    });
    if (env.getenv("REDIWM_GREETER_PREVIEW")) |path| {
        const bytes = try @import("../screenshot/encode.zig").encodePng(std.testing.allocator, @intCast(buf.width), @intCast(buf.height), buf.pixels, @intCast(buf.width));
        defer std.testing.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = std.mem.span(path), .data = bytes });
    }
    Buffer.drainPool();
}
