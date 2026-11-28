//! Keyboard input for the app-kit window host (`window.zig`): the XKB keymap
//! and modifiers, dead-key compose, and key repeat that follows the App's
//! focus. Methods of `Host(App)`, aliased there.
const std = @import("std");
const ui = @import("ui");
const wl = @import("wayland").client.wl;
const c = @import("c_gfx");
const key_repeat = ui.key_repeat;

pub fn Keyboard(comptime Client: type) type {
    return struct {
        /// One press of evdev `key` through the current XKB state.
        pub fn deliverKey(self: *Client, key: u32) void {
            const state = self.xkb_state orelse return;
            const sym = c.xkb_state_key_get_one_sym(state, key + 8);
            var buf: [64]u8 = undefined;
            const n = c.xkb_state_key_get_utf8(state, key + 8, &buf, buf.len);
            // Dead keys have no text of their own: sequences resolve here, and a
            // shortcut modifier abandons a half-typed one.
            if (!self.app.ctrl and !self.app.alt) {
                var composed: [64]u8 = undefined;
                if (self.compose.feed(self.locale, sym, &composed)) |text| {
                    if (text.len > 0) self.app.handleKey(0, text);
                    return;
                }
            } else self.compose.reset();
            self.app.handleKey(sym, buf[0..@intCast(std.math.clamp(n, 0, 63))]);
        }

        pub fn appRepeats(self: *Client, key: u32) bool {
            if (self.compose.consumed) return false;
            const state = self.xkb_state orelse return false;
            var buf: [64]u8 = undefined;
            const n = c.xkb_state_key_get_utf8(state, key + 8, &buf, buf.len);
            return self.app.keyRepeats(c.xkb_state_key_get_one_sym(state, key + 8), buf[0..@intCast(std.math.clamp(n, 0, 63))]);
        }

        /// A due repeat of the held key, if the app still takes it where its
        /// focus is now (a repeat may have opened a dialog or left a field).
        pub fn repeatDue(self: *Client) void {
            const key = self.key_repeat.due(key_repeat.nowMs()) orelse return;
            if (!self.appRepeats(key)) return self.key_repeat.stop();
            self.deliverKey(key);
        }

        pub fn keyboardEvent(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Client) void {
            switch (event) {
                .enter => {
                    self.app.focused = true;
                    self.app.dirty = true;
                },
                .leave => {
                    self.app.focused = false;
                    self.key_repeat.stop();
                    self.compose.reset();
                    self.app.cancelDrag();
                    self.app.ctrl = false;
                    self.app.shift = false;
                    self.app.alt = false;
                    self.app.dirty = true;
                },
                .keymap => |ev| {
                    defer _ = c.close(ev.fd);
                    self.key_repeat.stop();
                    if (ev.format != .xkb_v1 or ev.size == 0) return;
                    const memory = c.mmap(null, ev.size, c.PROT_READ, c.MAP_PRIVATE, ev.fd, 0);
                    if (memory == c.MAP_FAILED) return;
                    defer _ = c.munmap(memory, ev.size);

                    const bytes: [*]const u8 = @ptrCast(memory);
                    if (bytes[ev.size - 1] != 0) return;

                    if (self.xkb_context == null) self.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
                    const keymap = c.xkb_keymap_new_from_string(
                        self.xkb_context,
                        @ptrCast(memory),
                        c.XKB_KEYMAP_FORMAT_TEXT_V1,
                        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
                    ) orelse return;
                    defer c.xkb_keymap_unref(keymap);

                    if (self.xkb_state) |state| c.xkb_state_unref(state);
                    self.xkb_state = c.xkb_state_new(keymap);
                },
                .modifiers => |ev| {
                    if (self.xkb_state) |state| {
                        _ = c.xkb_state_update_mask(state, ev.mods_depressed, ev.mods_latched, ev.mods_locked, 0, 0, ev.group);
                        self.app.ctrl = c.xkb_state_mod_name_is_active(state, "Control", c.XKB_STATE_MODS_EFFECTIVE) > 0;
                        self.app.shift = c.xkb_state_mod_name_is_active(state, "Shift", c.XKB_STATE_MODS_EFFECTIVE) > 0;
                        self.app.alt = c.xkb_state_mod_name_is_active(state, "Mod1", c.XKB_STATE_MODS_EFFECTIVE) > 0 or
                            c.xkb_state_mod_name_is_active(state, "Alt", c.XKB_STATE_MODS_EFFECTIVE) > 0;
                    }
                },
                .key => |ev| {
                    self.input_serial = ev.serial;
                    if (ev.state == .pressed) {
                        const state = self.xkb_state orelse return;
                        self.deliverKey(ev.key);
                        // Asked after the key, of the state it left: the repeats
                        // go wherever this press put focus.
                        const keymap_repeats = c.xkb_keymap_key_repeats(c.xkb_state_get_keymap(state), ev.key + 8) != 0;
                        self.key_repeat.press(ev.key, keymap_repeats, self.appRepeats(ev.key), key_repeat.nowMs());
                    } else self.key_repeat.release(ev.key);
                },
                .repeat_info => |ev| self.key_repeat.setInfo(ev.rate, ev.delay),
            }
        }
    };
}
