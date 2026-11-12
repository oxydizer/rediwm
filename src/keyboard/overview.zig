//! Overview owns new presses, while processKey routes pre-existing releases
//! back to their recipients and keeps hardware, lock/auth and Monitor priority.
const Keyboard = @import("../Keyboard.zig");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");

pub fn process(keyboard: *Keyboard, code: u32, state: wl.Keyboard.KeyState) bool {
    const world = &keyboard.server.world;
    const mods = keyboard.device.toKeyboard().getModifiers();
    if (!world.overview.active()) {
        if (state != .pressed or keyboard.server.input.shortcuts_inhibit.inhibiting()) return false;
        // The configured shortcut also works over shell panels. Shortcut
        // recording, lock/auth and hardware routing have already run.
        for (keyboard.bindingSyms(code + 8)) |sym| {
            const action = keyboard.server.config.lookupKeybind(mods, sym) orelse continue;
            if (action != .toggle_overview) continue;
            if (code < keyboard.shortcut_consumed.len) keyboard.shortcut_consumed[code] = true;
            world.overview.toggle(world);
            return true;
        }
        return false;
    }
    if (state != .pressed) return true;
    if (code < keyboard.shortcut_consumed.len) keyboard.shortcut_consumed[code] = true;
    for (keyboard.bindingSyms(code + 8)) |sym| {
        if (keyboard.server.config.lookupKeybind(mods, sym)) |action| {
            if (action == .toggle_overview) {
                world.overview.dismiss(world);
                return true;
            }
            if (action == .lock_screen) {
                keyboard.server.executeAction(action);
                return true;
            }
        }
        switch (sym) {
            xkb.Keysym.Escape => world.overview.dismiss(world),
            xkb.Keysym.Return, xkb.Keysym.KP_Enter => world.overview.accept(world),
            xkb.Keysym.Left => world.overview.navigate(world, -1, 0),
            xkb.Keysym.Right => world.overview.navigate(world, 1, 0),
            xkb.Keysym.Up => world.overview.navigate(world, 0, -1),
            xkb.Keysym.Down => world.overview.navigate(world, 0, 1),
            else => {},
        }
    }
    return true;
}
