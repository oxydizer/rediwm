const std = @import("std");

const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const Output = @import("Output.zig");
const Server = @import("Server.zig");
const gpa = @import("main.zig").gpa;

const Keyboard = @This();

const log = std.log.scoped(.keyboard);
const keybinds = @import("config").keybinds;
const ControlCenter = @import("control_center/panel.zig").ControlCenter;
const StartMenu = @import("start_menu/panel.zig").StartMenu;

server: *Server,
link: wl.list.Link = undefined,
device: *wlr.InputDevice,
synthetic: bool = false,
layout_idx: ?u32 = null,

consuming_escape: bool = false,
polkit_consumed: [768]bool = @splat(false),
tray_consumed: [768]bool = @splat(false),
battery_consumed: [768]bool = @splat(false),
screenshot_consumed: [768]bool = @splat(false),
switcher_consumed: [768]bool = @splat(false),
switcher_timer: ?*wl.EventSource = null,
switcher_code: ?u32 = null,
shortcut_consumed: [768]bool = @splat(false),
hardware_consumed: [768]bool = @splat(false),
repeat_timer: ?*wl.EventSource = null,
repeat_code: ?u32 = null,
/// Key repeat for compositor-drawn UI, which has no client to repeat keys
/// itself: the held key and the shell target that took its press.
shell_timer: ?*wl.EventSource = null,
shell_repeat: ?ShellRepeat = null,
caps: bool = false,
client_pressed: [768]bool = @splat(false),
grab_pressed: [768]u64 = @splat(0),

keymap: wl.Listener(*wlr.Keyboard) = .init(handleKeymap),
modifiers: wl.Listener(*wlr.Keyboard) = .init(handleModifiers),
key: wl.Listener(*wlr.Keyboard.event.Key) = .init(handleKey),
destroy: wl.Listener(*wlr.InputDevice) = .init(handleDestroy),

pub fn create(server: *Server, device: *wlr.InputDevice) !void {
    return createInternal(server, device, false);
}

pub fn createSynthetic(server: *Server, device: *wlr.InputDevice) !void {
    return createInternal(server, device, true);
}

fn createInternal(server: *Server, device: *wlr.InputDevice, synthetic: bool) !void {
    const keyboard = try gpa.create(Keyboard);
    errdefer gpa.destroy(keyboard);

    keyboard.* = .{
        .server = server,
        .device = device,
        .synthetic = synthetic,
    };

    const wlr_keyboard = device.toKeyboard();
    const virtual = @import("input/text_input.zig").isVirtual(device);
    if (!virtual and wlr_keyboard.keymap == null) {
        const keymap = server.config.keyboard_keymap orelse return error.KeyboardInitFailed;
        if (!wlr_keyboard.setKeymap(keymap)) return error.KeyboardInitFailed;
    }
    const repeat = server.config.input;
    wlr_keyboard.setRepeatInfo(@intCast(repeat.key_repeat_rate), @intCast(repeat.key_repeat_delay));
    keyboard.caps = capsActive(wlr_keyboard);

    wlr_keyboard.events.keymap.add(&keyboard.keymap);
    wlr_keyboard.events.modifiers.add(&keyboard.modifiers);
    wlr_keyboard.events.key.add(&keyboard.key);
    device.events.destroy.add(&keyboard.destroy);

    if (!virtual) server.input.seat.setKeyboard(wlr_keyboard);
    server.input.keyboards.append(keyboard);
    if (!virtual) @import("input/layouts.zig").activate(keyboard);
}

fn handleKeymap(listener: *wl.Listener(*wlr.Keyboard), _: *wlr.Keyboard) void {
    const keyboard: *Keyboard = @fieldParentPtr("keymap", listener);
    @import("input/layouts.zig").changed(keyboard, true);
}

fn handleModifiers(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
    const keyboard: *Keyboard = @fieldParentPtr("modifiers", listener);
    if (keyboard.server.locker != null and @import("input/text_input.zig").isVirtual(keyboard.device)) return;
    if (keyboard.server.polkit_dialog != null) return;
    _ = keyboard.server.world.peekTarget();
    keyboard.server.scheduleFrames();
    const mods = wlr_keyboard.getModifiers();
    if (keyboard.server.locker == null) {
        if (keyboard.server.input.open_control_center) |cc| {
            if (cc.hasKeyboardFocus() and cc.page == .shortcuts and cc.shortcuts.editing != null and keyboard.server.input.open_start_menu == null) {
                cc.shortcuts.modifiers(cc, mods);
            }
        }
    }
    if (mods.shift or mods.ctrl or mods.alt or mods.logo) keyboard.stopRepeat();
    const caps = capsActive(wlr_keyboard);
    if (keyboard.caps != caps) {
        keyboard.caps = caps;
        const synthetic_locked = keyboard.server.locker != null and keyboard.server.virtual_input != null and keyboard.device == &keyboard.server.virtual_input.?.keyboard.wlr_kbd.base;
        if (!synthetic_locked) @import("osd.zig").show(keyboard.server, .{ .kind = .caps_lock, .active = caps });
    }
    keyboard.server.input.seat.setKeyboard(wlr_keyboard);
    @import("input/layouts.zig").activate(keyboard);
    if (keyboard.server.locker) |lock| {
        lock.modifiers(wlr_keyboard.getModifiers());
        if (lock.client) |client| if (client.focused != null) keyboard.server.input.seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);
        return;
    }
    const grab = if (keyboard.server.text_input) |relay| relay.keyboardGrab(wlr_keyboard) else null;
    if (grab) |im_grab| im_grab.sendModifiers(&wlr_keyboard.modifiers) else keyboard.server.input.seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);

    // Accept only when the modifier that opened the carousel is released.
    const input = &keyboard.server.input;
    if (keyboard.server.switcher.active() and !keyboard.server.switcher.triggerHeld(keyboard.server)) {
        keyboard.stopSwitcherRepeat();
        keyboard.server.switcher.accept(keyboard.server);
    }
    // If neither Alt key remains held, drop the Alt+wheel zoom gesture.
    if (!input.isAltHeld()) {
        input.zoom_scroll.reset();
    }
    // Once the pan modifier is no longer fully held, end any modifier pan and
    // clear inhibit.
    if (!input.isPanModifierHeld()) {
        if (input.cursor_mode == .pan) {
            if (input.pan_session) |sess| {
                if (sess.trigger == .super_key) {
                    input.endPan();
                    input.pan_session = null;
                }
            }
        } else if (input.pan_session) |sess| {
            if (sess.trigger == .super_key) {
                input.pan_session = null;
            }
        }
    }
}

/// Ctrl+Alt+F<n>. Works while locked and in the greeter, like a text console.
fn switchVt(keyboard: *Keyboard, syms: []const xkb.Keysym) bool {
    const session = keyboard.server.session orelse return false;
    for (syms) |sym| {
        const value = @intFromEnum(sym);
        if (value < xkb.Keysym.XF86Switch_VT_1 or value > xkb.Keysym.XF86Switch_VT_12) continue;
        session.changeVt(value - xkb.Keysym.XF86Switch_VT_1 + 1) catch log.warn("could not switch to VT {d}", .{value - xkb.Keysym.XF86Switch_VT_1 + 1});
        return true;
    }
    return false;
}

fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
    const keyboard: *Keyboard = @fieldParentPtr("key", listener);
    keyboard.processKey(event.time_msec, event.keycode, event.state);
}

pub fn processKey(keyboard: *Keyboard, time_msec: u32, event_keycode: u32, state: wl.Keyboard.KeyState) void {
    keyboard.noteShellKey(event_keycode, state);
    if (keyboard.server.locker != null and @import("input/text_input.zig").isVirtual(keyboard.device)) return;
    @import("startup.zig").markFirstInput();

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
        if (@import("input/text_input.zig").isVirtual(keyboard.device)) return;
        if (keyboard.server.virtual_input) |vi| if (keyboard.device == &vi.keyboard.wlr_kbd.base) return;
        if (event_keycode < keyboard.polkit_consumed.len) keyboard.polkit_consumed[event_keycode] = state == .pressed;
        keyboard.stopRepeat();
        keyboard.server.input.seat.setKeyboard(wlr_keyboard);
        @import("input/layouts.zig").activate(keyboard);
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
                @import("input/layouts.zig").activate(keyboard);
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
        @import("input/layouts.zig").activate(keyboard);
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
            if (@intFromEnum(sym) == xkb.Keysym.Escape) keyboard.server.screenshot_selector.cancel();
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
                if (@intFromEnum(sym) == xkb.Keysym.Escape) keyboard.server.switcher.cancel();
                if (@intFromEnum(sym) == xkb.Keysym.Return) keyboard.server.switcher.accept(keyboard.server);
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

    if (keyboard.server.input.window_menu.target != null and keyboard.server.screenshot_selector.output == null) {
        if (state == .pressed) {
            if (event_keycode < keyboard.tray_consumed.len) keyboard.tray_consumed[event_keycode] = true;
            for (xkb_state.keyGetSyms(keycode)) |sym| keyboard.server.input.window_menu.key(@intFromEnum(sym));
        }
        return;
    }
    if (keyboard.server.tray) |tray| {
        if (tray.menu_item != 0 and state == .pressed and keyboard.server.screenshot_selector.output == null) {
            if (event_keycode < keyboard.tray_consumed.len) keyboard.tray_consumed[event_keycode] = true;
            for (xkb_state.keyGetSyms(keycode)) |sym| tray.key(@intFromEnum(sym));
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
                switch (@intFromEnum(sym)) {
                    xkb.Keysym.Escape => {
                        popup.output.closeBattery();
                        return;
                    },
                    xkb.Keysym.Up, xkb.Keysym.Left, xkb.Keysym.ISO_Left_Tab => popup.navigate(true),
                    xkb.Keysym.Down, xkb.Keysym.Right, xkb.Keysym.Tab => popup.navigate(false),
                    xkb.Keysym.Return, xkb.Keysym.KP_Enter, xkb.Keysym.space => popup.activate(),
                    else => {},
                }
            }
        }
        return;
    }
    if (keyboard.server.input.open_calendar) |calendar| {
        if (state == .pressed) {
            for (xkb_state.keyGetSyms(keycode)) |sym| {
                switch (@intFromEnum(sym)) {
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
                switch (@intFromEnum(sym)) {
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
            if (@intFromEnum(sym) == xkb.Keysym.Escape) {
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
                if (@intFromEnum(sym) == xkb.Keysym.Escape) {
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
        @import("input/layouts.zig").activate(keyboard);
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

fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    const keyboard: *Keyboard = @fieldParentPtr("destroy", listener);
    if (keyboard.repeat_timer) |timer| timer.remove();
    if (keyboard.switcher_timer) |timer| timer.remove();
    if (keyboard.shell_timer) |timer| timer.remove();

    keyboard.server.switcher.cancel();
    keyboard.link.remove();
    @import("input/layouts.zig").removed(keyboard);
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

    gpa.destroy(keyboard);
}

fn stopRepeat(keyboard: *Keyboard) void {
    keyboard.repeat_code = null;
    if (keyboard.repeat_timer) |timer| timer.timerUpdate(0) catch {};
}

pub fn cancelHardware(keyboard: *Keyboard) void {
    keyboard.stopRepeat();
    keyboard.stopShellRepeat();
    @memset(&keyboard.hardware_consumed, false);
}

fn capsActive(keyboard: *wlr.Keyboard) bool {
    const state = keyboard.xkb_state orelse return false;
    return state.ledNameIsActive("Caps Lock") == 1;
}

fn repeatHardware(keyboard: *Keyboard) c_int {
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

fn stopSwitcherRepeat(keyboard: *Keyboard) void {
    keyboard.switcher_code = null;
    if (keyboard.switcher_timer) |timer| timer.timerUpdate(0) catch {};
}

fn repeatSwitcher(keyboard: *Keyboard) c_int {
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

fn bindingSyms(keyboard: *Keyboard, key: xkb.Keycode) []const xkb.Keysym {
    const kb = keyboard.device.toKeyboard();
    const state = kb.xkb_state orelse return &.{};
    return @import("config").keymap.bindingSyms(&keyboard.server.config, state, key, kb.getModifiers());
}

/// Compositor-drawn UI that takes keys straight from `processKey`.
const ShellTarget = union(enum) {
    polkit,
    /// The built-in lock screen, not an ext-session-lock client.
    lock,
    control_center: *ControlCenter,
    start_menu: *StartMenu,
    wifi: *@import("network/popup.zig").Popup,
    desktop,

    fn eql(a: ShellTarget, b: ShellTarget) bool {
        return switch (a) {
            .wifi => |p| b == .wifi and b.wifi == p,
            .control_center => |cc| b == .control_center and b.control_center == cc,
            .start_menu => |sm| b == .start_menu and b.start_menu == sm,
            else => std.meta.activeTag(a) == std.meta.activeTag(b),
        };
    }
};

const ShellRepeat = struct { code: u32, target: ShellTarget };

/// The shell target a press would reach now, in `processKey`'s order; null
/// when something ahead of it (a lock client, the screenshot selector, the
/// switcher, a tray menu, the calendar or power menu, shortcut capture) or a
/// client would take the key instead. Pointers are compared, never
/// dereferenced, so a repeat outliving its menu cannot touch freed memory.
fn currentShellTarget(keyboard: *Keyboard) ?ShellTarget {
    const server = keyboard.server;
    const virtual_input = if (server.virtual_input) |vi| keyboard.device == &vi.keyboard.wlr_kbd.base else false;
    if (server.polkit_dialog != null) {
        if (virtual_input or @import("input/text_input.zig").isVirtual(keyboard.device)) return null;
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
    if (input.window_menu.target != null) return null;
    if (input.open_wifi) |popup| return .{ .wifi = popup };
    if (input.open_battery != null or input.open_calendar != null or input.open_power_menu != null) return null;
    if (input.open_control_center) |cc| if (cc.hasKeyboardFocus() and input.open_start_menu == null) {
        if (cc.page == .shortcuts and cc.shortcuts.editing != null) return null;
        return .{ .control_center = cc };
    };
    if (input.open_start_menu) |sm| return .{ .start_menu = sm };
    if (server.desktop) |desktop| if (desktop.keyboard_focused) return .{ .desktop = {} };
    return null;
}

/// Whether holding `event_keycode` should repeat it into `target`: the keymap
/// says the key repeats, repeat is on, no Ctrl, Alt or Super is held (those
/// are commands, not typing), and the target accepts the key where its focus
/// is now.
fn shellKeyRepeats(keyboard: *Keyboard, event_keycode: u32, target: ShellTarget) bool {
    if (keyboard.server.config.input.key_repeat_rate <= 0) return false;
    const wlr_keyboard = keyboard.device.toKeyboard();
    const keymap = wlr_keyboard.keymap orelse return false;
    const xkb_state = wlr_keyboard.xkb_state orelse return false;
    const keycode = event_keycode + 8;
    if (keymap.keyRepeats(keycode) == 0) return false;
    const mods = wlr_keyboard.getModifiers();
    if (mods.ctrl or mods.alt or mods.logo) return false;
    const sym = xkb_state.keyGetOneSym(keycode);
    // Lock and polkit keys are secrets: scrub the scratch either way.
    var buf: [64]u8 = @splat(0);
    defer @import("session/lock.zig").clearKeyScratch(&buf);
    const n = xkb_state.keyGetUtf8(keycode, &buf);
    const utf8 = if (n > 0 and n < buf.len) buf[0..@intCast(n)] else "";
    const server = keyboard.server;
    return switch (target) {
        .polkit => if (server.polkit_dialog) |dialog| dialog.keyRepeats(sym, utf8) else false,
        .lock => if (server.locker) |lock| lock.keyRepeats(sym, utf8) else false,
        .control_center => |cc| blk: {
            if (cc.page == .network) if (@import("ui").input.current.focused) |widget| {
                if (widget.kind == .text_input or widget.kind == .secret_input) break :blk @import("input/repeat_keys.zig").editing(sym, utf8);
            };
            break :blk @import("input/repeat_keys.zig").navigation(sym);
        },
        .start_menu => |sm| sm.keyRepeats(sym, utf8),
        .wifi => |popup| popup.keyRepeats(sym, utf8),
        .desktop => if (server.desktop) |desktop| desktop.keyRepeats(@intFromEnum(sym), utf8) else false,
    };
}

/// One press of `event_keycode` into `target`, read through the keyboard's
/// current XKB state so a repeat types what a fresh press would.
fn deliverShell(keyboard: *Keyboard, target: ShellTarget, event_keycode: u32) void {
    const wlr_keyboard = keyboard.device.toKeyboard();
    const xkb_state = wlr_keyboard.xkb_state orelse return;
    const keycode = event_keycode + 8;
    const mods = wlr_keyboard.getModifiers();
    const server = keyboard.server;
    var buf: [64]u8 = @splat(0);
    defer @import("session/lock.zig").clearKeyScratch(&buf);
    const n = xkb_state.keyGetUtf8(keycode, &buf);
    const utf8 = if (n > 0 and n < buf.len) buf[0..@intCast(n)] else "";
    const syms = xkb_state.keyGetSyms(keycode);
    switch (target) {
        .polkit => if (server.polkit_dialog) |dialog| if (syms.len > 0) dialog.key(syms[0], utf8, mods),
        .lock => if (server.locker) |lock| if (syms.len > 0) lock.key(syms[0], utf8, mods),
        .control_center => |cc| for (syms) |sym| {
            const key: ?@import("ui").input.Key = switch (@intFromEnum(sym)) {
                xkb.Keysym.Escape => .escape,
                xkb.Keysym.Return, xkb.Keysym.KP_Enter => .enter,
                xkb.Keysym.BackSpace => .backspace,
                xkb.Keysym.Delete => .delete,
                xkb.Keysym.Left => .left,
                xkb.Keysym.Right => .right,
                xkb.Keysym.Up => .up,
                xkb.Keysym.Down => .down,
                xkb.Keysym.Home => .home,
                xkb.Keysym.End => .end,
                xkb.Keysym.Page_Up => .page_up,
                xkb.Keysym.Page_Down => .page_down,
                xkb.Keysym.Tab, xkb.Keysym.ISO_Left_Tab => .tab,
                else => if (mods.ctrl and (@intFromEnum(sym) == xkb.Keysym.a or @intFromEnum(sym) == xkb.Keysym.A)) .select_all else if (mods.ctrl and (@intFromEnum(sym) == xkb.Keysym.c or @intFromEnum(sym) == xkb.Keysym.C or @intFromEnum(sym) == xkb.Keysym.x or @intFromEnum(sym) == xkb.Keysym.X or @intFromEnum(sym) == xkb.Keysym.v or @intFromEnum(sym) == xkb.Keysym.V)) null else if (utf8.len > 0) .{ .char = utf8 } else null,
            };
            if (key) |k| _ = cc.selectKey(k, mods.shift);
        },
        .wifi => |popup| if (syms.len > 0) popup.key(syms[0], utf8, mods),
        .start_menu => |sm| _ = keyboard.deliverStartMenu(sm, event_keycode, .pressed),
        .desktop => if (server.desktop) |desktop| desktop.key(@intFromEnum(xkb_state.keyGetOneSym(keycode)), utf8),
    }
}

/// The search box's key, press or release. False for keys it doesn't use.
fn deliverStartMenu(keyboard: *Keyboard, sm: *StartMenu, event_keycode: u32, state: wl.Keyboard.KeyState) bool {
    const wlr_keyboard = keyboard.device.toKeyboard();
    const xkb_state = wlr_keyboard.xkb_state orelse return false;
    const keycode = event_keycode + 8;
    const syms = xkb_state.keyGetSyms(keycode);
    if (syms.len == 0) return false;
    var utf8_buf: [64]u8 = undefined;
    const utf8_len = xkb_state.keyGetUtf8(keycode, &utf8_buf);
    const utf8: ?[]const u8 = if (utf8_len > 0 and utf8_len < utf8_buf.len) utf8_buf[0..@intCast(utf8_len)] else null;
    return sm.handleKey(syms[0], state, utf8, wlr_keyboard.getModifiers());
}

fn armShellRepeat(keyboard: *Keyboard, event_keycode: u32, target: ShellTarget) void {
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
        const held = keyboard.shell_repeat orelse continue;
        const same = switch (held.target) {
            .control_center => |cc| @intFromPtr(cc) == @intFromPtr(panel),
            .start_menu => |sm| @intFromPtr(sm) == @intFromPtr(panel),
            .wifi => |popup| @intFromPtr(popup) == @intFromPtr(panel),
            else => false,
        };
        if (same) keyboard.stopShellRepeat();
    }
}

fn stopShellRepeat(keyboard: *Keyboard) void {
    keyboard.shell_repeat = null;
    if (keyboard.shell_timer) |timer| timer.timerUpdate(0) catch {};
}

/// Releasing the held key ends its repeat, and pressing another key that
/// repeats replaces it (the branch that takes the new press re-arms). A
/// modifier press does neither, so Shift can join a held key mid-repeat.
fn noteShellKey(keyboard: *Keyboard, event_keycode: u32, state: wl.Keyboard.KeyState) void {
    const held = keyboard.shell_repeat orelse return;
    if (state == .released) {
        if (held.code == event_keycode) keyboard.stopShellRepeat();
        return;
    }
    const keymap = keyboard.device.toKeyboard().keymap orelse return keyboard.stopShellRepeat();
    if (keymap.keyRepeats(event_keycode + 8) != 0) keyboard.stopShellRepeat();
}

fn repeatShell(keyboard: *Keyboard) c_int {
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
