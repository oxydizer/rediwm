//! Key processing: the priority pipeline from lock and switcher through panels and bindings to clients, and hardware and switcher key repeat.

const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const Output = @import("../Output.zig");
const gpa = @import("../main.zig").gpa;
const log = std.log.scoped(.keyboard);
const keybinds = @import("config").keybinds;
const Keyboard = @import("../Keyboard.zig");
const ShellTarget = Keyboard.ShellTarget;

pub fn processKey(keyboard: *Keyboard, time_msec: u32, event_keycode: u32, state: wl.Keyboard.KeyState) void {
    if (event_keycode < keyboard.mode_consumed.len and keyboard.mode_consumed[event_keycode]) {
        if (state == .pressed) return;
        keyboard.mode_consumed[event_keycode] = false;
        if (!keyboard.client_pressed[event_keycode]) {
            keyboard.shortcut_consumed[event_keycode] = false;
            keyboard.switcher_consumed[event_keycode] = false;
            keyboard.hardware_consumed[event_keycode] = false;
            return;
        }
    }
    keyboard.noteShellKey(event_keycode, state);
    if (keyboard.server.locker != null and @import("../input/text_input.zig").isVirtual(keyboard.device)) return;
    @import("../startup.zig").markFirstInput();

    if (keyboard.server.idle) |idle_mgr| {
        if (idle_mgr.interceptWakeKey(event_keycode, state)) {
            return;
        }
        idle_mgr.notifyActivity(.keyboard);
    }

    const wlr_keyboard = keyboard.device.toKeyboard();
    const keycode = event_keycode + 8;

    const xkb_state = wlr_keyboard.xkb_state orelse {
        log.err("processKey: keyboard has no xkb state", .{});
        return;
    };

    if (state == .released and event_keycode < keyboard.polkit_consumed.len and keyboard.polkit_consumed[event_keycode]) {
        keyboard.polkit_consumed[event_keycode] = false;
        return;
    }
    if (keyboard.server.polkit_dialog != null) {
        if (@import("../input/text_input.zig").isVirtual(keyboard.device)) return;
        if (keyboard.server.virtual_input) |vi| if (keyboard.device == &vi.keyboard.wlr_kbd.base) return;
        if (event_keycode < keyboard.polkit_consumed.len) keyboard.polkit_consumed[event_keycode] = state == .pressed;
        keyboard.stopRepeat();
        keyboard.server.input.seat.setKeyboard(wlr_keyboard);
        @import("../input/layouts.zig").activate(keyboard);
        if (state == .pressed) {
            // Before the key: it may be the Return that ends the dialog.
            const repeats = keyboard.shellKeyRepeats(event_keycode, .polkit);
            keyboard.deliverShell(.polkit, event_keycode);
            if (repeats) keyboard.armShellRepeat(event_keycode, .polkit);
        }
        return;
    }
    // Synthetic input retains the lock's existing denial policy. Only the
    // built-in device actions below bypass the ordinary menu/lock routing.
    if (keyboard.server.locker != null) {
        if (keyboard.server.virtual_input) |vi| {
            if (keyboard.device == &vi.keyboard.wlr_kbd.base) return;
        }
    }
    // Route releases to the recipient of the press, even if focus/grab policy
    // changed. Never expose a release to a replacement input-method grab.
    if (state == .released and event_keycode < keyboard.client_pressed.len) {
        const client = keyboard.client_pressed[event_keycode];
        const generation = keyboard.grab_pressed[event_keycode];
        keyboard.client_pressed[event_keycode] = false;
        keyboard.grab_pressed[event_keycode] = 0;
        if (keyboard.server.locker == null) {
            if (client) {
                keyboard.server.input.seat.setKeyboard(wlr_keyboard);
                @import("../input/layouts.zig").activate(keyboard);
                keyboard.server.input.seat.keyboardNotifyKey(time_msec, event_keycode, state);
                return;
            }
            if (generation != 0) {
                if (keyboard.server.text_input) |relay| {
                    if (relay.grab_generation == generation) {
                        if (relay.keyboardGrab(wlr_keyboard)) |grab| grab.sendKey(time_msec, event_keycode, state);
                    }
                }
                return;
            }
        }
    }
    // Capture before hardware actions so editing volume/brightness keys is inert.
    if (keyboard.server.locker == null) {
        if (keyboard.server.input.open_control_center) |cc| {
            if (cc.hasKeyboardFocus() and cc.page == .shortcuts and cc.shortcuts.editing != null and keyboard.server.input.open_start_menu == null) {
                keyboard.stopRepeat();
                if (event_keycode < keyboard.hardware_consumed.len) keyboard.hardware_consumed[event_keycode] = state == .pressed;
                if (state == .pressed) {
                    for (xkb_state.keyGetSyms(keycode)) |sym| cc.shortcuts.capture(cc, event_keycode, sym, wlr_keyboard.getModifiers());
                } else {
                    cc.shortcuts.release(event_keycode);
                }
                return;
            }
        }
    }
    if (event_keycode < keyboard.hardware_consumed.len) {
        if (state == .released and keyboard.hardware_consumed[event_keycode]) {
            keyboard.hardware_consumed[event_keycode] = false;
            if (keyboard.repeat_code == event_keycode) keyboard.stopRepeat();
            return;
        }
        if (state == .pressed) {
            if (keyboard.hardware_consumed[event_keycode]) return;
            if (keyboard.switchVt(xkb_state.keyGetSyms(keycode))) {
                keyboard.stopRepeat();
                keyboard.hardware_consumed[event_keycode] = true;
                return;
            }
            for (keyboard.bindingSyms(keycode)) |sym| {
                const action = keyboard.server.config.lookupKeybind(wlr_keyboard.getModifiers(), sym) orelse continue;
                if (!keybinds.isHardwareAction(action)) continue;
                keyboard.stopRepeat();
                keyboard.hardware_consumed[event_keycode] = true;
                keyboard.server.executeAction(action);
                if (keybinds.repeats(action) and keyboard.server.config.input.key_repeat_rate > 0) {
                    if (keyboard.repeat_timer == null) keyboard.repeat_timer = keyboard.server.wl_server.getEventLoop().addTimer(*Keyboard, repeatHardware, keyboard) catch null;
                    if (keyboard.repeat_timer) |timer| {
                        keyboard.repeat_code = event_keycode;
                        timer.timerUpdate(@intCast(@max(1, keyboard.server.config.input.key_repeat_delay))) catch keyboard.stopRepeat();
                    }
                }
                return;
            }
        }
    }

    if (keyboard.server.locker) |lock| {
        if (keyboard.server.virtual_input) |vi| {
            if (keyboard.device == &vi.keyboard.wlr_kbd.base) return;
        }
        keyboard.server.input.seat.setKeyboard(wlr_keyboard);
        @import("../input/layouts.zig").activate(keyboard);
        // An ext-session-lock client reads the password itself.
        if (lock.client) |client| if (client.focused != null) {
            keyboard.server.input.seat.keyboardNotifyKey(time_msec, event_keycode, state);
            return;
        };
        if (state == .pressed) {
            const repeats = keyboard.shellKeyRepeats(event_keycode, .lock);
            keyboard.deliverShell(.lock, event_keycode);
            if (repeats) keyboard.armShellRepeat(event_keycode, .lock);
        }
        return;
    }

    if (event_keycode < keyboard.battery_consumed.len and state == .released and keyboard.battery_consumed[event_keycode]) {
        keyboard.battery_consumed[event_keycode] = false;
        return;
    }
    if (event_keycode < keyboard.tray_consumed.len and state == .released and keyboard.tray_consumed[event_keycode]) {
        keyboard.tray_consumed[event_keycode] = false;
        return;
    }
    if (event_keycode < keyboard.screenshot_consumed.len and state == .released and keyboard.screenshot_consumed[event_keycode]) {
        keyboard.screenshot_consumed[event_keycode] = false;
        return;
    }
    if (keyboard.server.screenshot_selector.output != null and state == .pressed) {
        if (event_keycode < keyboard.screenshot_consumed.len) keyboard.screenshot_consumed[event_keycode] = true;
        for (xkb_state.keyGetSyms(keycode)) |sym| {
            if (sym == xkb.Keysym.Escape) keyboard.server.screenshot_selector.cancel();
        }
        return;
    }

    if (event_keycode < keyboard.switcher_consumed.len and state == .released and keyboard.switcher_consumed[event_keycode]) {
        keyboard.switcher_consumed[event_keycode] = false;
        if (keyboard.switcher_code == event_keycode) keyboard.stopSwitcherRepeat();
        return;
    }
    if (state == .released and event_keycode < keyboard.shortcut_consumed.len and keyboard.shortcut_consumed[event_keycode]) {
        keyboard.shortcut_consumed[event_keycode] = false;
        return;
    }

    // A VM or remote desktop inhibiting shortcuts gets every binding below
    // (shell panels it didn't open still take their keys) except the one
    // that takes them back. Hardware keys and VT switching were handled above.
    const inhibit = &keyboard.server.input.shortcuts_inhibit;
    const inhibited = inhibit.inhibiting();
    if (inhibited and state == .pressed) {
        for (keyboard.bindingSyms(keycode)) |sym| {
            const action = keyboard.server.config.lookupKeybind(wlr_keyboard.getModifiers(), sym) orelse continue;
            if (action != .restore_shortcuts) continue;
            keyboard.stopRepeat();
            if (event_keycode < keyboard.shortcut_consumed.len) keyboard.shortcut_consumed[event_keycode] = true;
            _ = inhibit.revoke();
            return;
        }
    }

    if (state == .pressed) {
        const mods = wlr_keyboard.getModifiers();
        for (keyboard.bindingSyms(keycode)) |sym| {
            const action = keyboard.server.config.lookupKeybind(mods, sym);
            const cycle = if (action) |a| a == .focus_next or a == .focus_prev else false;
            // Only a switcher already open keeps cycling under an inhibitor.
            if ((mods.alt or mods.ctrl) and cycle and (!inhibited or keyboard.server.switcher.active())) {
                const input = &keyboard.server.input;
                if (input.cursor_mode == .pan) {
                    input.endPan();
                    input.pan_session = null;
                }
                if (input.cursor_mode != .passthrough or input.active_buttons != 0) return;
                if (keyboard.server.input.open_start_menu) |sm| if (Output.fromWlr(sm.wlr_output)) |out| out.closeStartMenu();
                if (keyboard.server.input.open_power_menu) |pm| if (Output.fromWlr(pm.wlr_output)) |out| out.closePowerMenu();
                keyboard.server.switcher.step(keyboard.server, action.? == .focus_prev, if (mods.alt) .alt else .ctrl);
                if (keyboard.server.switcher.active() and keyboard.server.config.input.key_repeat_rate > 0) {
                    if (keyboard.switcher_timer == null) keyboard.switcher_timer = keyboard.server.wl_server.getEventLoop().addTimer(*Keyboard, repeatSwitcher, keyboard) catch null;
                    if (keyboard.switcher_timer) |timer| {
                        keyboard.switcher_code = event_keycode;
                        timer.timerUpdate(@intCast(@max(1, keyboard.server.config.input.key_repeat_delay))) catch keyboard.stopSwitcherRepeat();
                    }
                }
                if (event_keycode < keyboard.switcher_consumed.len) keyboard.switcher_consumed[event_keycode] = true;
                return;
            }
            if (keyboard.server.switcher.active()) {
                keyboard.stopSwitcherRepeat();
                if (sym == xkb.Keysym.Escape) keyboard.server.switcher.cancel();
                if (sym == xkb.Keysym.Return) keyboard.server.switcher.accept(keyboard.server);
                if (event_keycode < keyboard.switcher_consumed.len) keyboard.switcher_consumed[event_keycode] = true;
                return;
            }
        }
    }

    // Screenshot shortcuts work over shell panels without dismissing them or
    // feeding the shortcut into a search field. Consume the matching release.
    if (state == .pressed and !inhibited) {
        for (keyboard.bindingSyms(keycode)) |sym| {
            const action = keyboard.server.config.lookupKeybind(wlr_keyboard.getModifiers(), sym) orelse continue;
            if (action != .screenshot_region and action != .screenshot_output) continue;
            if (event_keycode < keyboard.screenshot_consumed.len) keyboard.screenshot_consumed[event_keycode] = true;
            keyboard.server.executeAction(action);
            return;
        }
    }

    // Escape drops a pinned dock icon being dragged, whichever shell panel has the
    // keyboard; its release is ours too.
    if (state == .pressed and keyboard.server.input.dock_drag.reordering()) {
        for (xkb_state.keyGetSyms(keycode)) |sym| {
            if (sym != xkb.Keysym.Escape) continue;
            _ = keyboard.server.input.cancelDrag();
            keyboard.consuming_escape = true;
            return;
        }
    } else if (state == .released and keyboard.consuming_escape) {
        for (xkb_state.keyGetSyms(keycode)) |sym| {
            if (sym != xkb.Keysym.Escape) continue;
            keyboard.consuming_escape = false;
            return;
        }
    }

    if (keyboard.server.input.window_menu.node != null and keyboard.server.screenshot_selector.output == null) {
        if (state == .pressed) {
            if (event_keycode < keyboard.tray_consumed.len) keyboard.tray_consumed[event_keycode] = true;
            for (xkb_state.keyGetSyms(keycode)) |sym| keyboard.server.input.window_menu.key(@backingInt(sym));
        }
        return;
    }
    if (keyboard.server.tray) |tray| {
        if (tray.menu_item != 0 and state == .pressed and keyboard.server.screenshot_selector.output == null) {
            if (event_keycode < keyboard.tray_consumed.len) keyboard.tray_consumed[event_keycode] = true;
            for (xkb_state.keyGetSyms(keycode)) |sym| tray.key(@backingInt(sym));
            return;
        }
    }
    if (keyboard.server.input.open_wifi) |popup| {
        if (state == .pressed) {
            if (event_keycode < keyboard.battery_consumed.len) keyboard.battery_consumed[event_keycode] = true;
            const target: ShellTarget = .{ .wifi = popup };
            const repeats = keyboard.shellKeyRepeats(event_keycode, target);
            keyboard.deliverShell(target, event_keycode);
            if (repeats) keyboard.armShellRepeat(event_keycode, target);
        }
        return;
    }
    if (keyboard.server.input.open_battery) |popup| {
        if (state == .pressed) {
            if (event_keycode < keyboard.battery_consumed.len) keyboard.battery_consumed[event_keycode] = true;
            for (xkb_state.keyGetSyms(keycode)) |sym| {
                switch (sym) {
                    xkb.Keysym.Escape => {
                        popup.output.closeBattery();
                        return;
                    },
                    xkb.Keysym.Up, xkb.Keysym.Left, xkb.Keysym.ISO_Left_Tab => popup.navigate(true),
                    xkb.Keysym.Down, xkb.Keysym.Right, xkb.Keysym.Tab => popup.navigate(false),
                    xkb.Keysym.Return, xkb.Keysym.KP_Enter, xkb.Keysym.space => {
                        popup.activate();
                        return;
                    },
                    else => {},
                }
            }
        }
        return;
    }
    if (keyboard.server.input.open_calendar) |calendar| {
        if (state == .pressed) {
            for (xkb_state.keyGetSyms(keycode)) |sym| {
                switch (sym) {
                    xkb.Keysym.Escape => {
                        calendar.output.closeCalendar();
                        return;
                    },
                    xkb.Keysym.Left => calendar.navigate(-1),
                    xkb.Keysym.Right => calendar.navigate(1),
                    else => {},
                }
            }
        }
        return;
    }

    if (keyboard.server.input.open_power_menu) |pm| {
        if (state == .pressed) {
            for (xkb_state.keyGetSyms(keycode)) |sym| {
                switch (sym) {
                    xkb.Keysym.Escape => if (Output.fromWlr(pm.wlr_output)) |output| output.closePowerMenu(),
                    xkb.Keysym.Left => pm.navigate(false),
                    xkb.Keysym.Right => pm.navigate(true),
                    xkb.Keysym.Return, xkb.Keysym.KP_Enter => pm.activateFocused(),
                    else => {},
                }
            }
        }
        return;
    }

    if (keyboard.server.input.open_control_center) |cc| {
        if (cc.hasKeyboardFocus() and keyboard.server.input.open_start_menu == null) {
            // A window like any other: compositor bindings come first.
            if (state == .pressed and !inhibited) {
                const mods = wlr_keyboard.getModifiers();
                for (keyboard.bindingSyms(keycode)) |sym| {
                    if (keyboard.server.input.handleKeybind(mods, sym)) {
                        if (event_keycode < keyboard.shortcut_consumed.len) keyboard.shortcut_consumed[event_keycode] = true;
                        return;
                    }
                }
            }
            if (state == .pressed) {
                const repeats = keyboard.shellKeyRepeats(event_keycode, .{ .control_center = cc });
                keyboard.deliverShell(.{ .control_center = cc }, event_keycode);
                if (repeats) keyboard.armShellRepeat(event_keycode, .{ .control_center = cc });
            }
            return;
        }
    }

    if (keyboard.server.input.open_start_menu) |sm| {
        // Escape abandons an application dragged out of the menu, not the menu.
        if (state == .pressed and keyboard.server.input.dock_drag.active()) for (xkb_state.keyGetSyms(keycode)) |sym| {
            if (sym == xkb.Keysym.Escape) {
                _ = keyboard.server.input.cancelDrag();
                keyboard.consuming_escape = true;
                return;
            }
        };
        if (state == .pressed) for (keyboard.bindingSyms(keycode)) |sym| {
            if (keyboard.server.input.isToggleStartMenu(wlr_keyboard.getModifiers(), sym)) {
                if (event_keycode < keyboard.shortcut_consumed.len) keyboard.shortcut_consumed[event_keycode] = true;
                if (Output.fromWlr(sm.wlr_output)) |output| output.closeStartMenu();
                return;
            }
        };
        // Compositor bindings take precedence over the menu's search field.
        // Otherwise a Super chord can be consumed as text (or navigation)
        // before normal keybind dispatch is reached below.
        if (state == .pressed) {
            const mods = wlr_keyboard.getModifiers();
            for (keyboard.bindingSyms(keycode)) |sym| {
                if (keyboard.server.input.handleKeybind(mods, sym)) {
                    if (event_keycode < keyboard.shortcut_consumed.len) keyboard.shortcut_consumed[event_keycode] = true;
                    return;
                }
            }
        }
        for (xkb_state.keyGetSyms(keycode)) |sym| {
            if (state == .pressed and keyboard.server.input.isToggleStartMenu(wlr_keyboard.getModifiers(), sym)) {
                if (Output.fromWlr(sm.wlr_output)) |output| output.closeStartMenu();
                return;
            }
            break;
        }
        const repeats = state == .pressed and keyboard.shellKeyRepeats(event_keycode, .{ .start_menu = sm });
        // Keys the search box doesn't understand (e.g. compositor
        // keybinds like screenshot) fall through to normal dispatch
        // below instead of being silently swallowed by the menu.
        if (keyboard.deliverStartMenu(sm, event_keycode, state)) {
            if (repeats) keyboard.armShellRepeat(event_keycode, .{ .start_menu = sm });
            return;
        }
    }

    // Escape during a drag-and-drop cancels it; during pan it ends the pan and
    // inhibits it until the trigger is released. Either way the release is ours.
    if (state == .pressed) {
        for (xkb_state.keyGetSyms(keycode)) |sym| {
            if (sym == xkb.Keysym.Escape) {
                const input = &keyboard.server.input;
                if (input.cancelDrag()) {
                    keyboard.consuming_escape = true;
                    return;
                }
                if (input.cursor_mode == .pan) {
                    const trig = if (input.pan_session) |s| s.trigger else .super_key;
                    const dev = if (input.pan_session) |s| s.initiating_device else null;
                    input.endPan();
                    input.pan_session = .{
                        .trigger = trig,
                        .initiating_device = dev,
                        .last_x = input.cursor.x,
                        .last_y = input.cursor.y,
                        .button_consumed = false,
                        .inhibited = true,
                    };
                    keyboard.consuming_escape = true;
                    return;
                }
                break;
            }
        }
    } else if (state == .released) {
        if (keyboard.consuming_escape) {
            for (xkb_state.keyGetSyms(keycode)) |sym| {
                if (sym == xkb.Keysym.Escape) {
                    keyboard.consuming_escape = false;
                    return;
                }
            }
        }
    }

    var handled = false;
    if (state == .pressed and !inhibited) {
        const mods = wlr_keyboard.getModifiers();
        for (keyboard.bindingSyms(keycode)) |sym| {
            if (keyboard.server.input.handleKeybind(mods, sym)) {
                handled = true;
                if (event_keycode < keyboard.shortcut_consumed.len) keyboard.shortcut_consumed[event_keycode] = true;
                const input = &keyboard.server.input;
                if (input.cursor_mode == .pan and input.pan_session != null and input.pan_session.?.trigger == .super_key) {
                    input.endPan();
                    input.pan_session = null;
                }
                break;
            }
        }
    }

    if (!handled) {
        // The compositor-drawn desktop is shell UI: after compositor
        // bindings, ahead of input-method grabs and client delivery.
        if (keyboard.server.desktop) |desktop| if (desktop.keyboard_focused and keyboard.server.locker == null) {
            if (state == .pressed) {
                const repeats = keyboard.shellKeyRepeats(event_keycode, .desktop);
                keyboard.deliverShell(.desktop, event_keycode);
                if (repeats) keyboard.armShellRepeat(event_keycode, .desktop);
            }
            return;
        };
        keyboard.server.input.seat.setKeyboard(wlr_keyboard);
        @import("../input/layouts.zig").activate(keyboard);
        const grab = if (keyboard.server.text_input) |relay| relay.keyboardGrab(wlr_keyboard) else null;
        if (grab) |im_grab| {
            im_grab.sendKey(time_msec, event_keycode, state);
            if (state == .pressed and event_keycode < keyboard.grab_pressed.len)
                keyboard.grab_pressed[event_keycode] = keyboard.server.text_input.?.grab_generation;
        } else {
            keyboard.server.input.seat.keyboardNotifyKey(time_msec, event_keycode, state);
            if (state == .pressed and event_keycode < keyboard.client_pressed.len)
                keyboard.client_pressed[event_keycode] = true;
        }
    }
}

pub fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    const keyboard: *Keyboard = @fieldParentPtr("destroy", listener);
    if (keyboard.repeat_timer) |timer| timer.remove();
    if (keyboard.switcher_timer) |timer| timer.remove();
    if (keyboard.shell_timer) |timer| timer.remove();

    keyboard.server.switcher.cancel();
    keyboard.link.remove();
    @import("../input/layouts.zig").removed(keyboard);
    _ = keyboard.server.world.peekTarget();
    keyboard.server.scheduleFrames();

    keyboard.keymap.link.remove();
    keyboard.modifiers.link.remove();
    keyboard.key.link.remove();
    keyboard.destroy.link.remove();

    // A modifier pan ends unless a remaining keyboard still holds the modifier.
    const input = &keyboard.server.input;
    if (input.cursor_mode == .pan and input.pan_session != null and input.pan_session.?.trigger == .super_key) {
        if (!input.isPanModifierHeld()) {
            input.zoom_scroll.reset();
            input.endPan();
            input.pan_session = null;
        }
    }

    keyboard.compose.deinit();
    gpa.destroy(keyboard);
}

pub fn stopRepeat(keyboard: *Keyboard) void {
    keyboard.repeat_code = null;
    if (keyboard.repeat_timer) |timer| timer.timerUpdate(0) catch {};
}

pub fn cancelHardware(keyboard: *Keyboard) void {
    keyboard.stopRepeat();
    keyboard.stopShellRepeat();
    @memset(&keyboard.hardware_consumed, false);
}

pub fn capsActive(keyboard: *wlr.Keyboard) bool {
    const state = keyboard.xkb_state orelse return false;
    return state.ledNameIsActive("Caps Lock") == 1;
}

pub fn repeatHardware(keyboard: *Keyboard) c_int {
    const code = keyboard.repeat_code orelse return 0;
    if (keyboard.server.locker != null and keyboard.server.virtual_input != null and keyboard.device == &keyboard.server.virtual_input.?.keyboard.wlr_kbd.base) {
        keyboard.stopRepeat();
        return 0;
    }
    const kb = keyboard.device.toKeyboard();
    _ = kb.xkb_state orelse return 0;
    const rate = keyboard.server.config.input.key_repeat_rate;
    if (rate > 0) for (keyboard.bindingSyms(code + 8)) |sym| {
        const action = keyboard.server.config.lookupKeybind(kb.getModifiers(), sym) orelse continue;
        if (!keybinds.repeats(action)) continue;
        keyboard.server.executeAction(action);
        keyboard.repeat_timer.?.timerUpdate(@intCast(@max(1, 1000 / rate))) catch keyboard.stopRepeat();
        return 0;
    };
    keyboard.stopRepeat();
    return 0;
}

pub fn stopSwitcherRepeat(keyboard: *Keyboard) void {
    keyboard.switcher_code = null;
    if (keyboard.switcher_timer) |timer| timer.timerUpdate(0) catch {};
}

pub fn repeatSwitcher(keyboard: *Keyboard) c_int {
    const code = keyboard.switcher_code orelse return 0;
    const kb = keyboard.device.toKeyboard();
    const mods = kb.getModifiers();
    const rate = keyboard.server.config.input.key_repeat_rate;
    if (keyboard.server.switcher.active() and keyboard.server.locker == null and keyboard.server.switcher.triggerHeld(keyboard.server) and rate > 0) {
        if (kb.xkb_state != null) for (keyboard.bindingSyms(code + 8)) |sym| {
            const action = keyboard.server.config.lookupKeybind(mods, sym) orelse continue;
            if (action != .focus_next and action != .focus_prev) continue;
            keyboard.server.switcher.step(keyboard.server, action == .focus_prev, keyboard.server.switcher.trigger);
            keyboard.switcher_timer.?.timerUpdate(@intCast(@max(1, 1000 / rate))) catch keyboard.stopSwitcherRepeat();
            return 0;
        };
    }
    keyboard.stopSwitcherRepeat();
    return 0;
}

pub fn bindingSyms(keyboard: *Keyboard, key: xkb.Keycode) []const xkb.Keysym {
    const kb = keyboard.device.toKeyboard();
    const state = kb.xkb_state orelse return &.{};
    return @import("config").keymap.bindingSyms(&keyboard.server.config, state, key, kb.getModifiers());
}
