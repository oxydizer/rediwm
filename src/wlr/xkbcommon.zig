//! Minimal facade over the part of xkbcommon this compositor actually calls:
//! building a keymap from RMLVO names, tracking modifier/layout state, and
//! looking up keysyms. Adapted from zig-xkbcommon; see LICENSE.zig-xkbcommon.
//! `Context`/`Keymap`/`State` are opaque handles (pointers only, never
//! embedded by value), so unlike pixman's `Region32` they need no layout
//! check to cross the wlroots boundary via `abi.bind` (src/wlr/keyboard.zig).
//! Extend this file rather than reintroducing the package if more of the
//! API is needed.

pub const Keycode = u32;
pub const LayoutIndex = u32;
pub const LevelIndex = u32;
pub const ModIndex = u32;
pub const ModMask = u32;
pub const LED_Index = u32;

pub const mod_invalid = 0xffff_ffff;

pub const RuleNames = extern struct {
    rules: ?[*:0]const u8,
    model: ?[*:0]const u8,
    layout: ?[*:0]const u8,
    variant: ?[*:0]const u8,
    options: ?[*:0]const u8,
};

pub const Context = opaque {
    pub const Flags = enum(c_int) {
        no_flags = 0,
    };

    extern fn xkb_context_new(flags: Flags) ?*Context;
    pub const new = xkb_context_new;

    extern fn xkb_context_unref(context: *Context) void;
    pub const unref = xkb_context_unref;
};

pub const Keymap = opaque {
    pub const CompileFlags = enum(c_int) {
        no_flags = 0,
    };

    extern fn xkb_keymap_new_from_names(context: *Context, names: ?*const RuleNames, flags: CompileFlags) ?*Keymap;
    pub const newFromNames = xkb_keymap_new_from_names;

    extern fn xkb_keymap_unref(keymap: *Keymap) void;
    pub const unref = xkb_keymap_unref;

    extern fn xkb_keymap_min_keycode(keymap: *Keymap) Keycode;
    pub const minKeycode = xkb_keymap_min_keycode;

    extern fn xkb_keymap_max_keycode(keymap: *Keymap) Keycode;
    pub const maxKeycode = xkb_keymap_max_keycode;

    extern fn xkb_keymap_key_get_name(keymap: *Keymap, key: Keycode) ?[*:0]const u8;
    pub const keyGetName = xkb_keymap_key_get_name;

    extern fn xkb_keymap_key_by_name(keymap: *Keymap, name: [*:0]const u8) Keycode;
    pub const keyByName = xkb_keymap_key_by_name;

    extern fn xkb_keymap_mod_get_index(keymap: *Keymap, name: [*:0]const u8) ModIndex;
    pub const modGetIndex = xkb_keymap_mod_get_index;

    extern fn xkb_keymap_num_layouts(keymap: *Keymap) LayoutIndex;
    pub const numLayouts = xkb_keymap_num_layouts;

    extern fn xkb_keymap_layout_get_name(keymap: *Keymap, idx: LayoutIndex) ?[*:0]const u8;
    pub const layoutGetName = xkb_keymap_layout_get_name;

    extern fn xkb_keymap_num_layouts_for_key(keymap: *Keymap, key: Keycode) LayoutIndex;
    pub const numLayoutsForKey = xkb_keymap_num_layouts_for_key;

    extern fn xkb_keymap_num_levels_for_key(keymap: *Keymap, key: Keycode, layout: LayoutIndex) LevelIndex;
    pub const numLevelsForKey = xkb_keymap_num_levels_for_key;

    extern fn xkb_keymap_key_get_syms_by_level(keymap: *Keymap, key: Keycode, layout: LayoutIndex, level: LevelIndex, syms_out: *?[*]const Keysym) c_int;
    pub fn keyGetSymsByLevel(keymap: *Keymap, key: Keycode, layout: LayoutIndex, level: LevelIndex) []const Keysym {
        var ptr: ?[*]const Keysym = undefined;
        const len = xkb_keymap_key_get_syms_by_level(keymap, key, layout, level, &ptr);
        return if (len == 0) &[0]Keysym{} else ptr.?[0..@intCast(len)];
    }

    extern fn xkb_keymap_key_repeats(keymap: *Keymap, key: Keycode) c_int;
    pub const keyRepeats = xkb_keymap_key_repeats;
};

pub const State = opaque {
    pub const Component = enum(c_int) {
        _,
        pub const layout_effective = 1 << 7;
    };

    extern fn xkb_state_new(keymap: *Keymap) ?*State;
    pub const new = xkb_state_new;

    extern fn xkb_state_unref(state: *State) void;
    pub const unref = xkb_state_unref;

    extern fn xkb_state_get_keymap(state: *State) *Keymap;
    pub const getKeymap = xkb_state_get_keymap;

    extern fn xkb_state_update_mask(
        state: *State,
        depressed_mods: ModMask,
        latched_mods: ModMask,
        locked_mods: ModMask,
        depressed_layout: LayoutIndex,
        latched_layout: LayoutIndex,
        locked_layout: LayoutIndex,
    ) Component;
    pub const updateMask = xkb_state_update_mask;

    extern fn xkb_state_update_latched_locked(
        state: *State,
        affect_latched_mods: ModMask,
        latched_mods: ModMask,
        affect_latched_layout: bool,
        latched_layout: i32,
        affect_locked_mods: ModMask,
        locked_mods: ModMask,
        affect_locked_layout: bool,
        locked_layout: i32,
    ) Component;
    pub const updateLatchedLocked = xkb_state_update_latched_locked;

    extern fn xkb_state_key_get_syms(state: *State, key: Keycode, syms_out: *?[*]const Keysym) c_int;
    pub fn keyGetSyms(state: *State, key: Keycode) []const Keysym {
        var ptr: ?[*]const Keysym = undefined;
        const len = xkb_state_key_get_syms(state, key, &ptr);
        return if (len == 0) &[0]Keysym{} else ptr.?[0..@intCast(len)];
    }

    extern fn xkb_state_key_get_utf8(state: *State, key: Keycode, buffer: [*]u8, size: usize) c_int;
    pub fn keyGetUtf8(state: *State, key: Keycode, buffer: []u8) usize {
        return @intCast(xkb_state_key_get_utf8(state, key, buffer.ptr, buffer.len));
    }

    extern fn xkb_state_key_get_one_sym(state: *State, key: Keycode) Keysym;
    pub const keyGetOneSym = xkb_state_key_get_one_sym;

    extern fn xkb_state_key_get_layout(state: *State, key: Keycode) LayoutIndex;
    pub const keyGetLayout = xkb_state_key_get_layout;

    extern fn xkb_state_key_get_level(state: *State, key: Keycode, layout: LayoutIndex) LevelIndex;
    pub const keyGetLevel = xkb_state_key_get_level;

    extern fn xkb_state_serialize_layout(state: *State, components: Component) LayoutIndex;
    pub const serializeLayout = xkb_state_serialize_layout;

    extern fn xkb_state_led_name_is_active(state: *State, name: [*:0]const u8) c_int;
    pub const ledNameIsActive = xkb_state_led_name_is_active;
};

/// `xkb_keysym_t`: a 32-bit symbol code, not just the named values below —
/// `keyGetSyms`/`keyGetOneSym` return arbitrary runtime values, hence `_`.
pub const Keysym = enum(u32) {
    NoSymbol = 0x000000,
    _,

    pub const BackSpace: Keysym = @enumFromInt(0xff08);
    pub const Tab: Keysym = @enumFromInt(0xff09);
    pub const Return: Keysym = @enumFromInt(0xff0d);
    pub const Sys_Req: Keysym = @enumFromInt(0xff15);
    pub const Escape: Keysym = @enumFromInt(0xff1b);
    pub const Delete: Keysym = @enumFromInt(0xffff);
    pub const Home: Keysym = @enumFromInt(0xff50);
    pub const Left: Keysym = @enumFromInt(0xff51);
    pub const Up: Keysym = @enumFromInt(0xff52);
    pub const Right: Keysym = @enumFromInt(0xff53);
    pub const Down: Keysym = @enumFromInt(0xff54);
    pub const Page_Up: Keysym = @enumFromInt(0xff55);
    pub const Page_Down: Keysym = @enumFromInt(0xff56);
    pub const End: Keysym = @enumFromInt(0xff57);
    pub const Print: Keysym = @enumFromInt(0xff61);
    pub const Num_Lock: Keysym = @enumFromInt(0xff7f);
    pub const KP_Enter: Keysym = @enumFromInt(0xff8d);
    pub const F1: Keysym = @enumFromInt(0xffbe);
    pub const Shift_L: Keysym = @enumFromInt(0xffe1);
    pub const Shift_R: Keysym = @enumFromInt(0xffe2);
    pub const Control_L: Keysym = @enumFromInt(0xffe3);
    pub const Control_R: Keysym = @enumFromInt(0xffe4);
    pub const Caps_Lock: Keysym = @enumFromInt(0xffe5);
    pub const Alt_L: Keysym = @enumFromInt(0xffe9);
    pub const Alt_R: Keysym = @enumFromInt(0xffea);
    pub const Super_L: Keysym = @enumFromInt(0xffeb);
    pub const Super_R: Keysym = @enumFromInt(0xffec);
    pub const ISO_Left_Tab: Keysym = @enumFromInt(0xfe20);
    pub const space: Keysym = @enumFromInt(0x0020);
    pub const plus: Keysym = @enumFromInt(0x002b);
    pub const minus: Keysym = @enumFromInt(0x002d);
    pub const equal: Keysym = @enumFromInt(0x003d);
    pub const A: Keysym = @enumFromInt(0x0041);
    pub const C: Keysym = @enumFromInt(0x0043);
    pub const F: Keysym = @enumFromInt(0x0046);
    pub const T: Keysym = @enumFromInt(0x0054);
    pub const V: Keysym = @enumFromInt(0x0056);
    pub const X: Keysym = @enumFromInt(0x0058);
    pub const underscore: Keysym = @enumFromInt(0x005f);
    pub const a: Keysym = @enumFromInt(0x0061);
    pub const c: Keysym = @enumFromInt(0x0063);
    pub const f: Keysym = @enumFromInt(0x0066);
    pub const s: Keysym = @enumFromInt(0x0073);
    pub const t: Keysym = @enumFromInt(0x0074);
    pub const u: Keysym = @enumFromInt(0x0075);
    pub const v: Keysym = @enumFromInt(0x0076);
    pub const x: Keysym = @enumFromInt(0x0078);
    pub const eacute: Keysym = @enumFromInt(0x00e9);
    pub const Cyrillic_ie: Keysym = @enumFromInt(0x06c5);
    pub const XF86Switch_VT_1: Keysym = @enumFromInt(0x1008fe01);
    pub const XF86Switch_VT_12: Keysym = @enumFromInt(0x1008fe0c);

    pub const Flags = enum(c_int) {
        no_flags = 0,
        case_insensitive = 1 << 0,
    };

    extern fn xkb_keysym_from_name(name: [*:0]const u8, flags: Flags) Keysym;
    pub const fromName = xkb_keysym_from_name;

    extern fn xkb_utf32_to_keysym(ucs: u32) Keysym;
    pub const fromUTF32 = xkb_utf32_to_keysym;

    extern fn xkb_keysym_to_lower(ks: Keysym) Keysym;
    pub const toLower = xkb_keysym_to_lower;
};
