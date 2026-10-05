//! Layout state follows the last keyboard used for ordinary input. The IPC
//! synthetic keyboard never replaces it, including during synthetic input.
const std = @import("std");
const xkb = @import("xkbcommon");
const Server = @import("../Server.zig");
const Keyboard = @import("../Keyboard.zig");
const protocol = @import("../ipc/protocol.zig");
const events = @import("../ipc/events.zig");

pub fn current(keyboard: *Keyboard) ?u32 {
    const state = keyboard.device.toKeyboard().xkb_state orelse return null;
    const idx = state.serializeLayout(@enumFromInt(xkb.State.Component.layout_effective));
    return if (idx < state.getKeymap().numLayouts()) idx else null;
}

pub fn inspect(server: *Server, allocator: std.mem.Allocator) !protocol.KeyboardLayoutsData {
    const keyboard = server.layout_keyboard orelse return .{};
    const map = keyboard.device.toKeyboard().keymap orelse return .{};
    const names = try allocator.alloc([]const u8, map.numLayouts());
    for (names, 0..) |*name, i| name.* = if (map.layoutGetName(@intCast(i))) |ptr| std.mem.span(ptr) else "";
    return .{ .names = names, .current_idx = current(keyboard) };
}

pub fn activate(keyboard: *Keyboard) void {
    if (keyboard.synthetic) return;
    const server = keyboard.server;
    if (server.layout_keyboard != keyboard) {
        server.layout_keyboard = keyboard;
        keyboard.layout_idx = current(keyboard);
        events.onKeyboardLayoutsChanged(server);
    } else changed(keyboard, false);
}

pub fn changed(keyboard: *Keyboard, keymap: bool) void {
    const idx = current(keyboard);
    const previous = keyboard.layout_idx;
    keyboard.layout_idx = idx;
    if (keyboard.server.layout_keyboard != keyboard) return;
    if (keymap) events.onKeyboardLayoutsChanged(keyboard.server) else if (idx != previous) {
        if (idx) |value| events.onKeyboardLayoutSwitched(keyboard.server, value);
    }
}

pub fn removed(keyboard: *Keyboard) void {
    const server = keyboard.server;
    if (server.layout_keyboard != keyboard) return;
    server.layout_keyboard = null;
    // Do not activate an unused protocol virtual keyboard on hot-unplug.
    var it = server.input.keyboards.iterator(.forward);
    while (it.next()) |candidate| {
        if (!candidate.synthetic and !@import("text_input.zig").isVirtual(candidate.device)) {
            activate(candidate);
            return;
        }
    }
    events.onKeyboardLayoutsChanged(server);
}

pub fn switchLayout(server: *Server, target: protocol.LayoutTarget) !void {
    const keyboard = server.layout_keyboard orelse return error.NoKeyboard;
    const kb = keyboard.device.toKeyboard();
    const state = kb.xkb_state orelse return error.NoKeyboard;
    const count = state.getKeymap().numLayouts();
    const idx = current(keyboard) orelse return error.NoKeyboard;
    const next = switch (target) {
        .next => (idx + 1) % count,
        .prev => if (idx == 0) count - 1 else idx - 1,
        .index => |value| if (value < count) value else return error.InvalidLayoutIndex,
    };
    if (next == idx) return;
    // wlroots applies this through XKB and emits modifiers, preserving held,
    // latched and locked modifiers and normal client/IME routing.
    var mods = kb.modifiers;
    mods.group = next;
    kb.notifyModifiers(mods);
}
