const std = @import("std");
const xkb = @import("xkbcommon");

/// Empty names deliberately defer to XKB_DEFAULT_* and xkbcommon defaults.
pub fn compile(allocator: std.mem.Allocator, cfg: anytype) !*xkb.Keymap {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const context = xkb.Context.new(.no_flags) orelse return error.InvalidKeymap;
    defer context.unref();
    const names = xkb.RuleNames{
        .rules = null,
        .layout = try name(a, cfg.xkb_layout),
        .variant = try name(a, cfg.xkb_variant),
        .options = try name(a, cfg.xkb_options),
        .model = try name(a, cfg.xkb_model),
    };
    return xkb.Keymap.newFromNames(context, &names, .no_flags) orelse error.InvalidKeymap;
}

fn name(a: std.mem.Allocator, value: []const u8) !?[*:0]const u8 {
    if (value.len == 0) return null;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidKeymap;
    return (try a.dupeZ(u8, value)).ptr;
}

/// Preserve an explicitly bound active-layout symbol before trying layout zero.
/// Only shortcut lookup uses this; text entry always uses the original state.
pub fn bindingSyms(config: anytype, state: *xkb.State, key: xkb.Keycode, mods: anytype) []const xkb.Keysym {
    const active = state.keyGetSyms(key);
    for (active) |sym| if (config.lookupKeybind(mods, sym) != null) return active;
    const layout = state.keyGetLayout(key);
    if (layout == 0 or layout == std.math.maxInt(u32)) return active;
    const level = state.keyGetLevel(key, layout);
    if (level == std.math.maxInt(u32)) return active;
    return state.getKeymap().keyGetSymsByLevel(key, 0, level);
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
    try std.testing.expectEqual(@as(u32, xkb.Keysym.Cyrillic_ie), @intFromEnum(active[0]));
    const fallback = bindingSyms(&cfg, state, 28, @import("keybinds.zig").ModifierMask{ .logo = true });
    try std.testing.expectEqual(@as(u32, xkb.Keysym.t), @intFromEnum(fallback[0]));
    _ = state.updateMask(1, 0, 0, 0, 0, 1); // Shift
    const shifted = bindingSyms(&cfg, state, 28, @import("keybinds.zig").ModifierMask{ .logo = true, .shift = true });
    try std.testing.expectEqual(@as(u32, xkb.Keysym.T), @intFromEnum(shifted[0]));

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
    try std.testing.expectEqual(@as(u32, xkb.Keysym.Cyrillic_ie), @intFromEnum(preferred[0]));
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
