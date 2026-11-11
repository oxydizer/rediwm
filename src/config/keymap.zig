const std = @import("std");
const xkb = @import("xkbcommon");
const input_sources = @import("input_sources.zig");

/// Empty names deliberately defer to XKB_DEFAULT_* and xkbcommon defaults.
pub fn compile(allocator: std.mem.Allocator, cfg: anytype) !*xkb.Keymap {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const context = xkb.Context.new(.no_flags) orelse return error.InvalidKeymap;
    defer context.unref();
    // X11, Xwayland and older clients know four groups; later layouts are dropped.
    var layout_names: []const u8 = cfg.xkb_layout;
    var variant_names: []const u8 = cfg.xkb_variant;
    const sources = input_sources.split(cfg);
    if (sources.dropped > 0) {
        std.log.scoped(.config).warn("only the first {d} keyboard layouts are used; {d} more ignored", .{ input_sources.max_layouts, sources.dropped });
        const joined = try input_sources.join(a, sources.slice());
        layout_names = joined.layout;
        variant_names = joined.variant;
    }
    const names = xkb.RuleNames{
        .rules = null,
        .layout = try name(a, layout_names),
        .variant = try name(a, variant_names),
        .options = try name(a, cfg.xkb_options),
        .model = try name(a, cfg.xkb_model),
    };
    return xkb.Keymap.newFromNames(context, &names, .no_flags) orelse error.InvalidKeymap;
}

fn name(a: std.mem.Allocator, value: []const u8) !?[*:0]const u8 {
    if (value.len == 0) return null;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidKeymap;
    return (try a.dupeSentinel(u8, value, 0)).ptr;
}

/// Preserve an explicitly bound active-layout symbol before trying layout zero.
/// Only shortcut lookup uses this; text entry always uses the original state.
pub fn bindingSyms(config: anytype, state: *xkb.State, key: xkb.Keycode, mods: anytype) []const xkb.Keysym {
    const active = state.keyGetSyms(key);
    for (active) |sym| if (config.lookupKeybind(mods, sym) != null) return active;
    const layout = state.keyGetLayout(key);
    if (layout == std.math.maxInt(u32)) return active;
    const level = state.keyGetLevel(key, layout);
    if (level == std.math.maxInt(u32)) return active;
    const shifted_fallback = state.getKeymap().keyGetSymsByLevel(key, 0, level);
    if (layout != 0) for (shifted_fallback) |sym| {
        if (config.lookupKeybind(mods, sym) != null) return shifted_fallback;
    };
    // Shift+number bindings name the number row, although XKB emits !/@/….
    // Prefer an explicit shifted-symbol binding; then try the unshifted key
    // while retaining the full modifier mask. Text still uses active XKB state.
    if (mods.shift) {
        const base = state.getKeymap().keyGetSymsByLevel(key, layout, 0);
        for (base) |sym| if (config.lookupKeybind(mods, sym) != null) return base;
        const fallback = state.getKeymap().keyGetSymsByLevel(key, 0, 0);
        for (fallback) |sym| if (config.lookupKeybind(mods, sym) != null) return fallback;
    }
    // A Cyrillic-only keymap has no Latin group to fall back to. Resolve
    // modifier-letter shortcuts by the XKB physical key name in that case;
    // never add a text layout or change the active state's keysyms.
    if (mods.logo or mods.ctrl or mods.alt) {
        if (latinLetterSyms(state.getKeymap(), key, mods.shift)) |latin| {
            if (config.lookupKeybind(mods, latin[0]) != null) return latin;
            if (mods.shift) if (latinLetterSyms(state.getKeymap(), key, false)) |base| {
                if (config.lookupKeybind(mods, base[0]) != null) return base;
            };
        }
    }
    if (layout == 0) return active;
    return shifted_fallback;
}

const latin_lower = letterSyms("qwertyuiopasdfghjklzxcvbnm");
const latin_upper = letterSyms("QWERTYUIOPASDFGHJKLZXCVBNM");

fn letterSyms(comptime letters: []const u8) [letters.len]xkb.Keysym {
    var syms: [letters.len]xkb.Keysym = undefined;
    for (letters, 0..) |letter, i| syms[i] = @enumFromInt(letter);
    return syms;
}

fn latinLetterSyms(map: *xkb.Keymap, key: xkb.Keycode, shifted: bool) ?[]const xkb.Keysym {
    // Preserve the user's physical Latin layout (AZERTY, Dvorak, etc.) when
    // one exists. This fallback is only for a key without any Latin group.
    for (0..map.numLayoutsForKey(key)) |layout| {
        for (map.keyGetSymsByLevel(key, @intCast(layout), 0)) |sym| {
            const value = @intFromEnum(sym);
            if ((value >= 'a' and value <= 'z') or (value >= 'A' and value <= 'Z')) return null;
        }
    }
    const physical = std.mem.span(map.keyGetName(key) orelse return null);
    if (physical.len != 4 or physical[2] != '0' or physical[3] < '1' or physical[3] > '9') {
        // The tenth key in the top letter row is P.
        if (!std.mem.eql(u8, physical, "AD10")) return null;
        return if (shifted) latin_upper[9..10] else latin_lower[9..10];
    }
    const column: usize = physical[3] - '1';
    const index = if (std.mem.eql(u8, physical[0..2], "AD")) column else if (std.mem.eql(u8, physical[0..2], "AC")) column + 10 else if (std.mem.eql(u8, physical[0..2], "AB") and column < 7) column + 19 else return null;
    return if (shifted) latin_upper[index .. index + 1] else latin_lower[index .. index + 1];
}

pub fn namesEqual(a: anytype, b: @TypeOf(a)) bool {
    inline for (.{ "xkb_layout", "xkb_variant", "xkb_options", "xkb_model" }) |field| {
        if (!std.mem.eql(u8, @field(a, field), @field(b, field))) return false;
    }
    return true;
}

test "configured layouts and layout-zero shortcuts preserve active bindings and shift" {
    const loader = @import("loader.zig");
    var cfg = try loader.parse(std.testing.allocator,
        \\[input]
        \\xkb_layout = "us,ru"
        \\xkb_variant = ","
        \\xkb_options = "grp:caps_toggle"
        \\[keybinds]
        \\"super+t" = "noop"
        \\"super+shift+T" = "noop"
    , "layout-test");
    defer cfg.deinit();
    const state = xkb.State.new(cfg.keyboard_keymap.?) orelse return error.InvalidKeymap;
    defer state.unref();
    _ = state.updateMask(0, 0, 0, 0, 0, 1);
    const active = state.keyGetSyms(28); // evdev KEY_T + 8
    try std.testing.expectEqual(@intFromEnum(xkb.Keysym.Cyrillic_ie), @intFromEnum(active[0]));
    const fallback = bindingSyms(&cfg, state, 28, @import("keybinds.zig").ModifierMask{ .logo = true });
    try std.testing.expectEqual(@intFromEnum(xkb.Keysym.t), @intFromEnum(fallback[0]));
    _ = state.updateMask(1, 0, 0, 0, 0, 1); // Shift
    const shifted = bindingSyms(&cfg, state, 28, @import("keybinds.zig").ModifierMask{ .logo = true, .shift = true });
    try std.testing.expectEqual(@intFromEnum(xkb.Keysym.T), @intFromEnum(shifted[0]));

    var explicit = try loader.parse(std.testing.allocator,
        \\[input]
        \\xkb_layout = "us,ru"
        \\[keybinds]
        \\"super+Cyrillic_ie" = "noop"
        \\"super+t" = "noop"
    , "active-binding");
    defer explicit.deinit();
    _ = state.updateMask(0, 0, 0, 0, 0, 1);
    const preferred = bindingSyms(&explicit, state, 28, @import("keybinds.zig").ModifierMask{ .logo = true });
    try std.testing.expectEqual(@intFromEnum(xkb.Keysym.Cyrillic_ie), @intFromEnum(preferred[0]));
}

test "invalid layout rejects config and empty layout compiles" {
    const loader = @import("loader.zig");
    try std.testing.expectError(error.InvalidConfig, loader.parse(std.testing.allocator,
        \\[input]
        \\xkb_layout = "rediwm_nonexistent_layout"
    , "bad-layout"));
    const map = try compile(std.testing.allocator, loader.InputConfig{});
    defer map.unref();
}

test "Cyrillic-only keymaps keep Latin modifier shortcuts and Cyrillic text" {
    const loader = @import("loader.zig");
    const ModifierMask = @import("keybinds.zig").ModifierMask;
    inline for (.{ "ru", "ua" }) |layout| {
        var cfg = try loader.parse(
            std.testing.allocator,
            "[input]\nxkb_layout = \"" ++ layout ++ "\"\n" ++
                "[keybinds]\n\"super+t\" = \"noop\"\n\"super+shift+T\" = \"noop\"\n" ++
                "\"ctrl+t\" = \"noop\"\n\"alt+t\" = \"noop\"\n\"t\" = \"noop\"\n",
            "cyrillic-only",
        );
        defer cfg.deinit();
        const map = cfg.keyboard_keymap.?;
        try std.testing.expectEqual(@as(u32, 1), map.numLayouts());
        const state = xkb.State.new(map) orelse return error.InvalidKeymap;
        defer state.unref();
        const key = map.keyByName("AD05");
        for ([_]ModifierMask{ .{ .logo = true }, .{ .ctrl = true }, .{ .alt = true } }) |mods| {
            try std.testing.expectEqual(@intFromEnum(xkb.Keysym.t), @intFromEnum(bindingSyms(&cfg, state, key, mods)[0]));
        }
        try std.testing.expectEqual(@intFromEnum(xkb.Keysym.Cyrillic_ie), @intFromEnum(state.keyGetSyms(key)[0]));
        try std.testing.expectEqual(@intFromEnum(xkb.Keysym.Cyrillic_ie), @intFromEnum(bindingSyms(&cfg, state, key, ModifierMask{})[0]));
        _ = state.updateMask(1, 0, 0, 0, 0, 0);
        try std.testing.expectEqual(@intFromEnum(xkb.Keysym.T), @intFromEnum(bindingSyms(&cfg, state, key, ModifierMask{ .logo = true, .shift = true })[0]));
    }
    var explicit = try loader.parse(std.testing.allocator,
        \\[input]
        \\xkb_layout = "ru"
        \\[keybinds]
        \\"super+Cyrillic_ie" = "noop"
        \\"super+t" = "noop"
    , "explicit-cyrillic");
    defer explicit.deinit();
    const state = xkb.State.new(explicit.keyboard_keymap.?) orelse return error.InvalidKeymap;
    defer state.unref();
    try std.testing.expectEqual(@intFromEnum(xkb.Keysym.Cyrillic_ie), @intFromEnum(bindingSyms(&explicit, state, 28, ModifierMask{ .logo = true })[0]));
}
