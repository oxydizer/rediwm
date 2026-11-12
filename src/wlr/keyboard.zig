//! Adapted from zig-wlroots (MIT); see LICENSE.zig-wlroots.
//! Layout and function signatures are checked against the installed headers.
const c = @import("c.zig").c;
const abi = @import("abi.zig");
const wlr = @import("wlr.zig");

const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.server.wl;

const xkb = @import("xkbcommon");

pub const Keyboard = extern struct {
    comptime {
        abi.assertLayout(@This(), c.wlr_keyboard);
    }

    pub const led_count = c.WLR_LED_COUNT;
    pub const led = struct {
        pub const num_lock = c.WLR_LED_NUM_LOCK;
        pub const caps_lock = c.WLR_LED_CAPS_LOCK;
        pub const scroll_lock = c.WLR_LED_SCROLL_LOCK;
        pub const compose = c.WLR_LED_COMPOSE;
        pub const kana = c.WLR_LED_KANA;
    };

    pub const modifier_count = c.WLR_MODIFIER_COUNT;
    pub const ModifierMask = packed struct(u32) {
        shift: bool = false,
        caps: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        mod2: bool = false,
        mod3: bool = false,
        logo: bool = false,
        mod5: bool = false,
        _: u24 = 0,
    };

    pub const Modifiers = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_keyboard_modifiers);
        }

        depressed: xkb.ModMask,
        latched: xkb.ModMask,
        locked: xkb.ModMask,
        group: xkb.LayoutIndex,
    };

    pub const event = struct {
        pub const Key = extern struct {
            comptime {
                abi.assertLayout(@This(), c.wlr_keyboard_key_event);
            }

            time_msec: u32,
            keycode: u32,
            update_state: bool,
            state: wl.Keyboard.KeyState,
        };
    };

    pub const Impl = extern struct {
        comptime {
            abi.assertLayout(@This(), c.wlr_keyboard_impl);
        }

        name: [*:0]const u8,
        led_update: ?*const fn (keyboard: *Keyboard, leds: u32) callconv(.c) void = null,
    };

    base: wlr.InputDevice,

    impl: *const Impl,
    group: ?*wlr.KeyboardGroup,

    keymap_string: [*:0]u8,
    keymap_size: usize,
    keymap_fd: c_int,
    keymap: ?*xkb.Keymap,
    xkb_state: ?*xkb.State,
    led_indexes: [led_count]xkb.LED_Index,
    mod_indexes: [modifier_count]xkb.ModIndex,

    leds: u32,
    keycodes: [c.WLR_KEYBOARD_KEYS_CAP]u32,
    num_keycodes: usize,
    modifiers: Modifiers,

    repeat_info: extern struct {
        rate: i32,
        delay: i32,
    },

    events: extern struct {
        key: wl.Signal(*event.Key),
        modifiers: wl.Signal(*Keyboard),
        keymap: wl.Signal(*Keyboard),
        repeat_info: wl.Signal(*Keyboard),
    },

    data: ?*anyopaque,

    const wlr_keyboard_init = abi.bind(fn (keyboard: *Keyboard, impl: *const Impl, name: [*:0]const u8) callconv(.c) void, c.wlr_keyboard_init);
    pub const init = wlr_keyboard_init;

    const wlr_keyboard_finish = abi.bind(fn (keyboard: *Keyboard) callconv(.c) void, c.wlr_keyboard_finish);
    pub const finish = wlr_keyboard_finish;

    const wlr_keyboard_set_keymap = abi.bind(fn (keyboard: *Keyboard, keymap: ?*xkb.Keymap) callconv(.c) bool, c.wlr_keyboard_set_keymap);
    pub const setKeymap = wlr_keyboard_set_keymap;

    const wlr_keyboard_keymaps_match = abi.bind(fn (km1: ?*xkb.Keymap, km2: ?*xkb.Keymap) callconv(.c) bool, c.wlr_keyboard_keymaps_match);
    pub const keymapsMatch = wlr_keyboard_keymaps_match;

    const wlr_keyboard_set_repeat_info = abi.bind(fn (keyboard: *Keyboard, rate: i32, delay: i32) callconv(.c) void, c.wlr_keyboard_set_repeat_info);
    pub const setRepeatInfo = wlr_keyboard_set_repeat_info;

    const wlr_keyboard_led_update = abi.bind(fn (keyboard: *Keyboard, leds: u32) callconv(.c) void, c.wlr_keyboard_led_update);
    pub const ledUpdate = wlr_keyboard_led_update;

    const wlr_keyboard_get_modifiers = abi.bind(fn (keyboard: *Keyboard) callconv(.c) u32, c.wlr_keyboard_get_modifiers);
    pub fn getModifiers(keyboard: *Keyboard) ModifierMask {
        return @as(ModifierMask, @bitCast(wlr_keyboard_get_modifiers(keyboard)));
    }

    const wlr_keyboard_notify_key = abi.bind(fn (keyboard: *Keyboard, event: *event.Key) callconv(.c) void, c.wlr_keyboard_notify_key);
    pub const notifyKey = wlr_keyboard_notify_key;

    const wlr_keyboard_notify_modifiers = abi.bind(fn (
        keyboard: *Keyboard,
        mods_depressed: u32,
        mods_latched: u32,
        mods_locked: u32,
        group: u32,
    ) callconv(.c) void, c.wlr_keyboard_notify_modifiers);
    pub fn notifyModifiers(keyboard: *Keyboard, modifiers: Modifiers) void {
        wlr_keyboard_notify_modifiers(
            keyboard,
            modifiers.depressed,
            modifiers.latched,
            modifiers.locked,
            modifiers.group,
        );
    }

    /// Change the locked XKB layout without round-tripping server state
    /// through xkb_state_update_mask(). Keep wlroots' cached group in sync
    /// and emit its normal modifier signal for seat/client notification.
    pub fn setLayoutGroup(keyboard: *Keyboard, group: xkb.LayoutIndex) void {
        const state = keyboard.xkb_state orelse return;
        _ = xkb.State.updateLatchedLocked(
            state,
            0,
            0,
            false,
            0,
            0,
            0,
            true,
            @intCast(group),
        );

        const effective = state.serializeLayout(@enumFromInt(xkb.State.Component.layout_effective));
        if (keyboard.modifiers.group == effective) return;
        keyboard.modifiers.group = effective;
        keyboard.events.modifiers.emit(keyboard);
    }
};
