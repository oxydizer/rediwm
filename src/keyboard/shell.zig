//! Keys for compositor panels: shell targets, compose, delivery and the shell key repeat.

const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const Server = @import("../Server.zig");
const ControlCenter = @import("../control_center/panel.zig").ControlCenter;
const StartMenu = @import("../start_menu/panel.zig").StartMenu;
const ui = @import("ui");
const ui_compose = @import("ui").compose;
const Keyboard = @import("../Keyboard.zig");

/// Compositor-drawn UI that takes keys straight from `processKey`.
pub const ShellTarget = union(enum) {
    polkit,
    /// The built-in lock screen, not an ext-session-lock client.
    lock,
    control_center: *ControlCenter,
    start_menu: *StartMenu,
    wifi: *@import("../network/popup.zig").Popup,
    desktop,

    fn eql(a: ShellTarget, b: ShellTarget) bool {
        return switch (a) {
            .wifi => |p| b == .wifi and b.wifi == p,
            .control_center => |cc| b == .control_center and b.control_center == cc,
            .start_menu => |sm| b == .start_menu and b.start_menu == sm,
            else => std.meta.activeTag(a) == std.meta.activeTag(b),
        };
    }

    /// Whether this target is the freeable panel at `panel`'s address.
    fn isPanel(target: ShellTarget, panel: anytype) bool {
        return switch (target) {
            .control_center => |cc| @intFromPtr(cc) == @intFromPtr(panel),
            .start_menu => |sm| @intFromPtr(sm) == @intFromPtr(panel),
            .wifi => |popup| @intFromPtr(popup) == @intFromPtr(panel),
            else => false,
        };
    }
};

/// What a shell press types once dead keys and Compose sequences resolve.
/// `sym` is the key's own, or none for composed text.
pub const Typed = struct { sym: xkb.Keysym, utf8: []const u8, composed: bool };

pub fn composeLocale(server: *Server) []const u8 {
    // The setting reaches only the apps we launch; the compositor reads it
    // itself, and falls back to the session's own environment.
    if (server.config.region.language.len != 0) return server.config.region.language;
    return ui_compose.localeFromEnviron(server.environ);
}

/// Null when the press only advanced a sequence (a dead key, or a key that
/// cancelled one) and types nothing. Composed text lands in `out`, which the
/// caller scrubs like the other key scratch: lock and polkit keys are
/// secrets. A shortcut modifier abandons a half-typed sequence, and so does
/// a press for another target: a sequence belongs to the panel it began in.
pub fn composeShell(keyboard: *Keyboard, target: ShellTarget, sym: xkb.Keysym, mods: wlr.Keyboard.ModifierMask, utf8: []const u8, out: *[64]u8) ?Typed {
    const plain: Typed = .{ .sym = sym, .utf8 = utf8, .composed = false };
    if (mods.ctrl or mods.alt or mods.logo) {
        keyboard.compose.reset();
        return plain;
    }
    if (keyboard.compose_target) |owner| if (!owner.eql(target)) keyboard.compose.reset();
    keyboard.compose_target = target;
    const text = keyboard.compose.feed(composeLocale(keyboard.server), @intFromEnum(sym), out) orelse return plain;
    if (text.len == 0) return null;
    return .{ .sym = @fromBackingInt(@intCast(0)), .utf8 = text, .composed = true };
}

pub const ShellRepeat = struct { code: u32, target: ShellTarget };

/// The shell target a press would reach now, in `processKey`'s order; null
/// when something ahead of it (a lock client, the screenshot selector, the
/// switcher, a tray menu, the calendar or power menu, shortcut capture) or a
/// client would take the key instead. Pointers are compared, never
/// dereferenced, so a repeat outliving its menu cannot touch freed memory.
pub fn currentShellTarget(keyboard: *Keyboard) ?ShellTarget {
    const server = keyboard.server;
    const virtual_input = if (server.virtual_input) |vi| keyboard.device == &vi.keyboard.wlr_kbd.base else false;
    if (server.polkit_dialog != null) {
        if (virtual_input or @import("../input/text_input.zig").isVirtual(keyboard.device)) return null;
        return .polkit;
    }
    if (server.locker) |lock| {
        if (virtual_input) return null;
        if (lock.client) |client| if (client.focused != null) return null;
        return .lock;
    }
    if (server.screenshot_selector.output != null or server.switcher.active()) return null;
    if (server.tray) |tray| if (tray.menu_item != 0) return null;
    const input = &server.input;
    if (input.window_menu.node != null) return null;
    if (input.open_wifi) |popup| return .{ .wifi = popup };
    if (input.open_transfers != null or input.open_battery != null or input.open_calendar != null or input.open_power_menu != null) return null;
    if (input.open_control_center) |cc| if (cc.hasKeyboardFocus() and input.open_start_menu == null) {
        if (cc.page == .shortcuts and cc.shortcuts.editing != null) return null;
        return .{ .control_center = cc };
    };
    if (input.open_start_menu) |sm| return .{ .start_menu = sm };
    if (server.desktop) |desktop| if (desktop.keyboard_focused) return .{ .desktop = {} };
    return null;
}

fn controlCenterKey(sym: xkb.Keysym, mods: wlr.Keyboard.ModifierMask, utf8: []const u8) ?ui.input.Key {
    const Keysym = xkb.Keysym;
    if (mods.ctrl and !mods.alt and !mods.logo) switch (sym) {
        Keysym.a, Keysym.A => return .select_all,
        Keysym.c, Keysym.C => return .copy,
        Keysym.x, Keysym.X => return .cut,
        Keysym.v, Keysym.V => return .{ .paste = "" },
        else => {},
    };
    return switch (sym) {
        Keysym.Escape => .escape,
        Keysym.Return, Keysym.KP_Enter => .enter,
        Keysym.BackSpace => .backspace,
        Keysym.Delete => .delete,
        Keysym.Left => .left,
        Keysym.Right => .right,
        Keysym.Up => .up,
        Keysym.Down => .down,
        Keysym.Home => .home,
        Keysym.End => .end,
        Keysym.Page_Up => .page_up,
        Keysym.Page_Down => .page_down,
        Keysym.Tab, Keysym.ISO_Left_Tab => .tab,
        else => if (!mods.ctrl and !mods.alt and !mods.logo and utf8.len > 0 and utf8[0] >= 32 and utf8[0] != 127)
            .{ .char = utf8 }
        else
            null,
    };
}

pub fn offerControlCenterText(keyboard: *Keyboard, event_keycode: u32) bool {
    const target = keyboard.currentShellTarget() orelse return false;
    if (target != .control_center or target.control_center.focusedTextField() == null) return false;
    const server = keyboard.server;
    const wlr_keyboard = keyboard.device.toKeyboard();
    const mods = wlr_keyboard.getModifiers();
    if (mods.alt or mods.logo) return false;
    const keycode = event_keycode + 8;
    const state = wlr_keyboard.xkb_state orelse return false;
    const sym = state.keyGetOneSym(keycode);
    if (sym == xkb.Keysym.Escape and server.input.dock_drag.reordering()) return false;
    if (server.input.shortcuts_inhibit.inhibiting()) {
        for (keyboard.bindingSyms(keycode)) |binding_sym| {
            const action = server.config.lookupKeybind(mods, binding_sym) orelse continue;
            if (action == .restore_shortcuts) return false;
        }
    }

    var buf: [64]u8 = @splat(0);
    defer @import("../session/lock.zig").clearKeyScratch(&buf);
    const n = state.keyGetUtf8(keycode, &buf);
    const utf8 = if (n > 0 and n < buf.len) buf[0..@intCast(n)] else "";
    const composing = !mods.ctrl and (ui_compose.startsSequence(@backingInt(sym)) or
        (keyboard.compose_target != null and keyboard.compose_target.?.eql(target) and keyboard.compose.pending()));
    const find = mods.ctrl and (sym == xkb.Keysym.f or sym == xkb.Keysym.F);
    if (!composing and !find) {
        const key = controlCenterKey(sym, mods, utf8) orelse return false;
        // Modified Tab and Enter remain available to application switching
        // and other shortcuts.
        if (mods.ctrl and (key == .tab or key == .enter or key == .escape)) return false;
    }

    const repeats = keyboard.shellKeyRepeats(event_keycode, target);
    if (event_keycode < keyboard.shortcut_consumed.len) keyboard.shortcut_consumed[event_keycode] = true;
    keyboard.deliverShell(target, event_keycode);
    if (repeats) keyboard.armShellRepeat(event_keycode, target);
    return true;
}

/// Whether holding `event_keycode` should repeat it into `target`: the keymap
/// says the key repeats, repeat is on, no Ctrl, Alt or Super is held (those
/// are commands, not typing), and the target accepts the key where its focus
/// is now.
pub fn shellKeyRepeats(keyboard: *Keyboard, event_keycode: u32, target: ShellTarget) bool {
    if (keyboard.server.config.input.key_repeat_rate <= 0) return false;
    const wlr_keyboard = keyboard.device.toKeyboard();
    const keymap = wlr_keyboard.keymap orelse return false;
    const xkb_state = wlr_keyboard.xkb_state orelse return false;
    const keycode = event_keycode + 8;
    if (keymap.keyRepeats(keycode) == 0) return false;
    const mods = wlr_keyboard.getModifiers();
    if (mods.ctrl or mods.alt or mods.logo) return false;
    const sym = xkb_state.keyGetOneSym(keycode);
    // A dead key types nothing, and the key that completes a sequence types
    // its letter once, not a stream of the bare letter.
    if (keyboard.compose.willConsume(@intFromEnum(sym))) return false;
    // Lock and polkit keys are secrets: scrub the scratch either way.
    var buf: [64]u8 = @splat(0);
    defer @import("../session/lock.zig").clearKeyScratch(&buf);
    const n = xkb_state.keyGetUtf8(keycode, &buf);
    const utf8 = if (n > 0 and n < buf.len) buf[0..@intCast(n)] else "";
    const server = keyboard.server;
    return switch (target) {
        .polkit => if (server.polkit_dialog) |dialog| dialog.keyRepeats(sym, utf8) else false,
        .lock => if (server.locker) |lock| lock.keyRepeats(sym, utf8) else false,
        .control_center => |cc| blk: {
            if (cc.focusedTextField() != null) break :blk @import("../input/repeat_keys.zig").editing(sym, utf8);
            break :blk @import("../input/repeat_keys.zig").navigation(sym);
        },
        .start_menu => |sm| sm.keyRepeats(sym, utf8),
        .wifi => |popup| popup.keyRepeats(sym, utf8),
        .desktop => if (server.desktop) |desktop| desktop.keyRepeats(@intFromEnum(sym), utf8) else false,
    };
}

/// One press of `event_keycode` into `target`, read through the keyboard's
/// current XKB state so a repeat types what a fresh press would.
pub fn deliverShell(keyboard: *Keyboard, target: ShellTarget, event_keycode: u32) void {
    const wlr_keyboard = keyboard.device.toKeyboard();
    const xkb_state = wlr_keyboard.xkb_state orelse return;
    const keycode = event_keycode + 8;
    const mods = wlr_keyboard.getModifiers();
    const server = keyboard.server;
    var buf: [64]u8 = @splat(0);
    defer @import("../session/lock.zig").clearKeyScratch(&buf);
    const n = xkb_state.keyGetUtf8(keycode, &buf);
    const raw = if (n > 0 and n < buf.len) buf[0..@intCast(n)] else "";
    var composed: [64]u8 = @splat(0);
    defer @import("../session/lock.zig").clearKeyScratch(&composed);
    // The start menu composes in `deliverStartMenu`.
    const typed = if (target == .start_menu) Typed{ .sym = xkb_state.keyGetOneSym(keycode), .utf8 = raw, .composed = false } else keyboard.composeShell(target, xkb_state.keyGetOneSym(keycode), mods, raw, &composed) orelse return;
    const utf8 = typed.utf8;
    const composed_syms = [_]xkb.Keysym{typed.sym};
    const syms: []const xkb.Keysym = if (typed.composed) &composed_syms else xkb_state.keyGetSyms(keycode);
    switch (target) {
        .polkit => if (server.polkit_dialog) |dialog| if (syms.len > 0) dialog.key(syms[0], utf8, mods),
        .lock => if (server.locker) |lock| if (syms.len > 0) lock.key(syms[0], utf8, mods),
        .control_center => |cc| for (syms) |sym| {
            if (mods.ctrl and !mods.alt and !mods.logo and (sym == xkb.Keysym.f or sym == xkb.Keysym.F)) {
                cc.focusSearch();
                break;
            }
            if (controlCenterKey(sym, mods, utf8)) |key| {
                if (key == .paste) cc.pasteText() else _ = cc.selectKey(key, mods.shift);
            }
        },
        .wifi => |popup| if (syms.len > 0) popup.key(syms[0], utf8, mods),
        .start_menu => |sm| _ = keyboard.deliverStartMenu(sm, event_keycode, .pressed),
        .desktop => if (server.desktop) |desktop| desktop.key(@intFromEnum(typed.sym), utf8),
    }
}

/// The search box's key, press or release. False for keys it doesn't use.
pub fn deliverStartMenu(keyboard: *Keyboard, sm: *StartMenu, event_keycode: u32, state: wl.Keyboard.KeyState) bool {
    const wlr_keyboard = keyboard.device.toKeyboard();
    const xkb_state = wlr_keyboard.xkb_state orelse return false;
    const keycode = event_keycode + 8;
    const syms = xkb_state.keyGetSyms(keycode);
    if (syms.len == 0) return false;
    var utf8_buf: [64]u8 = undefined;
    const utf8_len = xkb_state.keyGetUtf8(keycode, &utf8_buf);
    const raw: []const u8 = if (utf8_len > 0 and utf8_len < utf8_buf.len) utf8_buf[0..@intCast(utf8_len)] else "";
    const mods = wlr_keyboard.getModifiers();
    // Only presses compose. A key that merely advanced a sequence is ours:
    // returning false would hand the dead key to the keys behind the menu.
    var composed: [64]u8 = undefined;
    const typed = if (state == .pressed) keyboard.composeShell(.{ .start_menu = sm }, syms[0], mods, raw, &composed) orelse return true else Typed{ .sym = syms[0], .utf8 = raw, .composed = false };
    return sm.handleKey(typed.sym, state, if (typed.utf8.len > 0) typed.utf8 else null, mods);
}

pub fn armShellRepeat(keyboard: *Keyboard, event_keycode: u32, target: ShellTarget) void {
    // The press may have closed or replaced the target (Return launching
    // from the start menu); only a target still taking keys repeats.
    const current = keyboard.currentShellTarget() orelse return;
    if (!current.eql(target)) return;
    if (keyboard.shell_timer == null) keyboard.shell_timer = keyboard.server.wl_server.getEventLoop().addTimer(*Keyboard, repeatShell, keyboard) catch return;
    keyboard.shell_repeat = .{ .code = event_keycode, .target = target };
    keyboard.shell_timer.?.timerUpdate(@intCast(@max(1, keyboard.server.config.input.key_repeat_delay))) catch keyboard.stopShellRepeat();
}

/// Called as a menu or control center is freed: a repeat compares target
/// pointers, and a panel reopened at the same address is a new target that
/// never saw the press.
pub fn forgetShellTarget(server: *Server, panel: anytype) void {
    var it = server.input.keyboards.iterator(.forward);
    while (it.next()) |keyboard| {
        if (keyboard.compose_target) |owner| if (owner.isPanel(panel)) {
            keyboard.compose.reset();
            keyboard.compose_target = null;
        };
        const held = keyboard.shell_repeat orelse continue;
        if (held.target.isPanel(panel)) keyboard.stopShellRepeat();
    }
}

pub fn stopShellRepeat(keyboard: *Keyboard) void {
    keyboard.shell_repeat = null;
    if (keyboard.shell_timer) |timer| timer.timerUpdate(0) catch {};
}

/// Releasing the held key ends its repeat, and pressing another key that
/// repeats replaces it (the branch that takes the new press re-arms). A
/// modifier press does neither, so Shift can join a held key mid-repeat.
pub fn noteShellKey(keyboard: *Keyboard, event_keycode: u32, state: wl.Keyboard.KeyState) void {
    const held = keyboard.shell_repeat orelse return;
    if (state == .released) {
        if (held.code == event_keycode) keyboard.stopShellRepeat();
        return;
    }
    const keymap = keyboard.device.toKeyboard().keymap orelse return keyboard.stopShellRepeat();
    if (keymap.keyRepeats(event_keycode + 8) != 0) keyboard.stopShellRepeat();
}

pub fn repeatShell(keyboard: *Keyboard) c_int {
    const held = keyboard.shell_repeat orelse return 0;
    // Whatever took the keyboard since the press (a dialog, the lock, a
    // client) or moved the target's focus off a repeating field ends it.
    const current = keyboard.currentShellTarget();
    if (current == null or !current.?.eql(held.target) or !keyboard.shellKeyRepeats(held.code, held.target)) {
        keyboard.stopShellRepeat();
        return 0;
    }
    keyboard.deliverShell(held.target, held.code);
    // The key may have ended the repeat (a lock engaging cancels it).
    if (keyboard.shell_repeat == null) return 0;
    const rate = keyboard.server.config.input.key_repeat_rate;
    keyboard.shell_timer.?.timerUpdate(@intCast(@max(1, @divTrunc(1000, @max(1, rate))))) catch keyboard.stopShellRepeat();
    return 0;
}

/// End repeats without losing consumed releases when changing desktop modes.
pub fn cancelModeRepeats(keyboard: *Keyboard) void {
    const kb = keyboard.device.toKeyboard();
    for (kb.keycodes[0..kb.num_keycodes]) |code| {
        if (code < keyboard.mode_consumed.len) keyboard.mode_consumed[code] = true;
    }
    keyboard.stopRepeat();
    keyboard.stopSwitcherRepeat();
    keyboard.stopShellRepeat();
}
