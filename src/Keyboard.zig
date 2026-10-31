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
const ui_compose = @import("ui").compose;

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
mode_consumed: [768]bool = @splat(false),
repeat_timer: ?*wl.EventSource = null,
repeat_code: ?u32 = null,
/// Key repeat for compositor-drawn UI, which has no client to repeat keys
/// itself: the held key and the shell target that took its press.
shell_timer: ?*wl.EventSource = null,
shell_repeat: ?ShellRepeat = null,
/// Dead keys and Compose sequences for compositor-drawn fields (clients
/// compose their own), and the shell target a half-typed one belongs to.
compose: ui_compose.Compose = .{},
compose_target: ?ShellTarget = null,
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

fn updateDragAction(seat: *wlr.Seat, ctrl: bool) void {
    const drag = seat.drag orelse return;
    const source = seat.drag_source orelse return;

    const Enum = wl.DataDeviceManager.DndAction.Enum;
    const copy_bit: u32 = @intFromEnum(Enum.copy);
    const move_bit: u32 = @intFromEnum(Enum.move);
    const both_bits = copy_bit | move_bit;

    // Only change the action for sources that explicitly support both.
    if (source.actions < 0) return;
    const source_actions: u32 = @bitCast(source.actions);
    if ((source_actions & both_bits) != both_bits) return;

    source.compositor_action = if (ctrl) copy_bit else move_bit;

    const focus_client = drag.focus_client orelse return;
    var offers = seat.drag_offers.iterator(.forward);
    while (offers.next()) |offer| {
        if (offer.type != .drag or offer.source != source) continue;
        if (offer.resource.getClient() != focus_client.client) continue;

        const version = offer.resource.getVersion();
        const offer_actions: u32 = if (version >= 3) offer.actions else copy_bit;
        const preferred_bits: u32 = if (version >= 3)
            @as(u32, @intCast(@intFromEnum(offer.preferred_action)))
        else
            0;
        const available = offer_actions & source_actions;

        const compositor_bits = source.compositor_action & available;
        const action_bits = if (compositor_bits != 0)
            compositor_bits
        else if ((preferred_bits & available) != 0)
            preferred_bits & available
        else
            available & (~available +% 1);

        const action: Enum = @enumFromInt(action_bits);

        // wlroots tracks one current action per source, shared by its offers.
        if (source.current_dnd_action == action) return;

        if (offer.in_ask) {
            source.current_dnd_action = action;
            return;
        }

        source.dndAction(action);
        if (version >= 3) {
            offer.resource.sendAction(@bitCast(action_bits));
        }
        return;
    }
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
    const seat = keyboard.server.input.seat;
    seat.setKeyboard(wlr_keyboard);
    updateDragAction(seat, mods.ctrl);
    // wlroots' DnD keyboard grab does not forward modifier events.
    // Keep the focused source client synchronized while the drag is active.
    if (seat.drag != null) seat.keyboardSendModifiers(&wlr_keyboard.modifiers);
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
pub fn switchVt(keyboard: *Keyboard, syms: []const xkb.Keysym) bool {
    const session = keyboard.server.session orelse return false;
    for (syms) |sym| {
        const value = @intFromEnum(sym);
        const first = @intFromEnum(xkb.Keysym.XF86Switch_VT_1);
        if (value < first or value > @intFromEnum(xkb.Keysym.XF86Switch_VT_12)) continue;
        session.changeVt(value - first + 1) catch log.warn("could not switch to VT {d}", .{value - first + 1});
        return true;
    }
    return false;
}

pub fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
    const keyboard: *Keyboard = @fieldParentPtr("key", listener);
    keyboard.processKey(event.time_msec, event.keycode, event.state);
}

/// Focus enters must contain only keys delivered to clients. A raw hardware
/// snapshot also includes shell shortcuts (e.g. Tab still held when Alt is
/// released); their swallowed releases would leave them stuck in Xwayland.
pub fn enter(server: *Server, surface: *wlr.Surface) void {
    const seat = server.input.seat;
    const wlr_keyboard = seat.getKeyboard() orelse return;
    var owner: ?*Keyboard = null;
    var keyboards = server.input.keyboards.iterator(.forward);
    while (keyboards.next()) |keyboard| {
        if (keyboard.device == &wlr_keyboard.base) {
            owner = keyboard;
            break;
        }
    }
    var keys: [32]u32 = undefined;
    var count: usize = 0;
    for (wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes]) |code| {
        if (owner) |keyboard| {
            if (code < keyboard.client_pressed.len and
                (!keyboard.client_pressed[code] or keyboard.polkit_consumed[code])) continue;
        }
        if (count < keys.len) {
            keys[count] = code;
            count += 1;
        }
    }
    seat.keyboardNotifyEnter(surface, keys[0..count], &wlr_keyboard.modifiers);
}

const keyboard_process = @import("keyboard/process.zig");
pub const processKey = keyboard_process.processKey;
const handleDestroy = keyboard_process.handleDestroy;
pub const stopRepeat = keyboard_process.stopRepeat;
pub const cancelHardware = keyboard_process.cancelHardware;
const capsActive = keyboard_process.capsActive;
pub const stopSwitcherRepeat = keyboard_process.stopSwitcherRepeat;
pub const bindingSyms = keyboard_process.bindingSyms;

const keyboard_shell = @import("keyboard/shell.zig");
pub const ShellTarget = keyboard_shell.ShellTarget;
pub const composeShell = keyboard_shell.composeShell;
const ShellRepeat = keyboard_shell.ShellRepeat;
pub const currentShellTarget = keyboard_shell.currentShellTarget;
pub const shellKeyRepeats = keyboard_shell.shellKeyRepeats;
pub const deliverShell = keyboard_shell.deliverShell;
pub const deliverStartMenu = keyboard_shell.deliverStartMenu;
pub const armShellRepeat = keyboard_shell.armShellRepeat;
pub const forgetShellTarget = keyboard_shell.forgetShellTarget;
pub const stopShellRepeat = keyboard_shell.stopShellRepeat;
pub const noteShellKey = keyboard_shell.noteShellKey;
pub const cancelModeRepeats = keyboard_shell.cancelModeRepeats;
