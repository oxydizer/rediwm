//! Authentication and input: PAM results, submitting, account and session choices, focus order, keys and clicks.

const i18n = @import("i18n");
const std = @import("std");
const Child = @import("child.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const Output = @import("../Output.zig");
const gpa = @import("../main.zig").gpa;
const ui = @import("ui");
const anim = @import("ui").anim;
const greeter_mod = @import("greeter.zig");
const lock_controls = @import("lock_controls.zig");
const power_cmd = @import("power.zig");
const Greeter = greeter_mod.Greeter;
const text_field = ui.widgets.field;
const lock_mod = @import("lock.zig");
const Lock = lock_mod.Lock;
const rediwm_auth_start = lock_mod.rediwm_auth_start;
const rediwm_auth_poll = lock_mod.rediwm_auth_poll;
const rediwm_auth_fd = lock_mod.rediwm_auth_fd;
const rediwm_auth_destroy = lock_mod.rediwm_auth_destroy;
const focus_account = lock_mod.focus_account;
const focus_session = lock_mod.focus_session;
const Geometry = lock_mod.Geometry;
const lock_view = @import("lock_view.zig");
const field_options = lock_mod.field_options;
const powerExited = Lock.powerExited;

/// The PAM worker finished: its eventfd became readable.
pub fn authReady(_: c_int, _: wl.EventMask, self: *Lock) c_int {
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
    self.status = i18n.tr("Unable to unlock. Try again.");
    self.retry_at = anim.nowMs() + 1500;
    self.changed();
    return 0;
}

pub fn submit(self: *Lock) void {
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
    self.status = if (self.auth != null) i18n.tr("Checking password…") else i18n.tr("Authentication unavailable. Try again.");
    self.changed();
}

pub fn submitGreeter(self: *Lock, greeter: *Greeter) void {
    if (anim.nowMs() < self.retry_at) return;
    defer self.changed();
    if (greeter.phase == .prompting) {
        greeter.answer(self.field().value()) catch {
            self.status = i18n.tr("Lost contact with login service. Try again.");
        };
        if (greeter.phase == .authenticating) self.status = i18n.tr("Checking…");
        self.clear();
        return;
    }
    if (greeter.busy() or self.input.len == 0) return;
    self.status = greeter.begin(self.field().value()) catch |err| switch (err) {
        error.NoService => i18n.tr("No login service"),
        error.NoAccount => i18n.tr("No user accounts found"),
        error.NoSession => i18n.tr("No sessions installed"),
        else => i18n.tr("Cannot reach login service. Try again."),
    };
    self.clear();
}

/// Greeter: account or session choice changed.
pub fn choose(self: *Lock, target: u8, delta: isize) void {
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
pub fn focusOrder(self: *const Lock, buf: *[7]u8) []const u8 {
    const greeter = self.greeter orelse {
        if (lock_view.layoutButtonShown(self)) {
            buf[0..6].* = .{ 0, 1, 2, lock_mod.focus_layout, 3, 4 };
            return buf[0..6];
        }
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

pub fn moveFocus(self: *Lock, backward: bool) void {
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
        return sym == xkb.Keysym.Left or sym == xkb.Keysym.Right;
    }
    return false;
}

pub fn key(self: *Lock, sym: xkb.Keysym, utf8: []const u8, mods: wlr.Keyboard.ModifierMask) void {
    self.caps = mods.caps;
    self.caret_edit_ms = anim.nowMs();
    defer self.changed();
    if (sym == xkb.Keysym.Escape) {
        self.clear();
        self.confirm = null;
        self.focus = 0;
        if (self.prompting()) {
            self.greeter.?.cancel();
            self.status = i18n.tr("Sign-in cancelled");
        } else if (!self.busy()) self.status = self.idleStatus();
        return;
    }
    if (self.busy()) return;
    switch (sym) {
        xkb.Keysym.Tab, xkb.Keysym.ISO_Left_Tab => self.moveFocus(mods.shift or sym == xkb.Keysym.ISO_Left_Tab),
        xkb.Keysym.Up, xkb.Keysym.Down => if (!self.prompting()) self.choose(focus_account, if (sym == xkb.Keysym.Up) -1 else 1),
        xkb.Keysym.Left, xkb.Keysym.Right => if (self.focus == focus_account or self.focus == focus_session)
            self.choose(self.focus, if (sym == xkb.Keysym.Left) -1 else 1)
        else if (self.focus == 0) {
            if (sym == xkb.Keysym.Left) self.field().left() else self.field().right();
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

pub fn activate(self: *Lock, focus: u8) void {
    switch (focus) {
        0, 2 => self.submit(),
        1 => self.reveal = !self.reveal,
        lock_mod.focus_layout => if (self.server.input_sources) |sources| sources.cycleLayouts(),
        3, 4 => {
            if (self.power_child != null) return;
            const reboot = focus == 4;
            if (self.confirm == null or self.confirm.? != reboot) {
                self.clear();
                self.confirm = reboot;
                self.status = if (reboot) i18n.tr("Restart? Activate Restart again to confirm.") else i18n.tr("Power off? Activate Power again to confirm.");
                return;
            }
            self.confirm = null;
            // systemctl/loginctl delegate to logind/polkit; no privileged
            // syscall or shell interpolation. Never request an interactive
            // auth agent behind the locked screen.
            var argv: [4][]const u8 = undefined;
            const command = power_cmd.commandArgv(&argv, if (reboot) .reboot else .poweroff, false, true) orelse {
                self.status = i18n.tr("Power service unavailable");
                return;
            };
            var child = std.process.spawn(self.server.io, .{ .argv = command }) catch {
                self.status = i18n.tr("Power service unavailable");
                return;
            };
            self.power_child = Child.watch(gpa, self.server.wl_server.getEventLoop(), child.id.?, self, powerExited) catch {
                child.kill(self.server.io);
                self.status = i18n.tr("Power service unavailable");
                return;
            };
            self.status = i18n.tr("Requesting power action…");
        },
        focus_account, focus_session => self.choose(focus, 1),
        else => {},
    }
}

pub fn click(self: *Lock, x: f64, y: f64) void {
    if (self.controlsAt(x, y)) |at| {
        self.showControls(at.hit.kind);
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
    if (lock_view.layoutButtonShown(self)) {
        const button = geo.layoutButton();
        if (dx >= button.x and dx <= button.x + button.w and dy >= button.y and dy <= button.y + button.h) {
            self.focus = lock_mod.focus_layout;
            self.activate(lock_mod.focus_layout);
        }
    }
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
