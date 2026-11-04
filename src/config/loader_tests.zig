//! Config loader tests.

const std = @import("std");
const theme_mod = @import("ui").theme;
const Theme = theme_mod.Theme;
const keybinds = @import("keybinds.zig");
const Action = keybinds.Action;
const default_file = @import("default.zig");
const types = @import("types.zig");
const window_rules = @import("window_rules.zig");
const sandbox_allow = @import("sandbox_allow.zig");
const anim = @import("ui").anim;
const output_transform = @import("output_transform.zig");
const schedule_mod = @import("schedule.zig");
const ScheduleMode = schedule_mod.ScheduleMode;
const NightLightConfig = schedule_mod.NightLightConfig;
const AccelProfile = types.AccelProfile;
const PanModifier = types.PanModifier;
const spliceSection = @import("loader_edit.zig").spliceSection;
const output_rules = @import("loader_fields.zig").output_rules;
const fieldHint = @import("loader_fields.zig").fieldHint;
const applyInputKey = @import("loader_fields.zig").applyInputKey;
const applyCompositorKey = @import("loader_fields.zig").applyCompositorKey;
const applyIdleKey = @import("loader_fields.zig").applyIdleKey;
const inputEql = @import("loader_compare.zig").inputEql;
const themeEql = @import("loader_compare.zig").themeEql;
const default_zoom_percents = @import("loader.zig").default_zoom_percents;
const InputConfig = @import("loader.zig").InputConfig;
const CompositorConfig = @import("loader.zig").CompositorConfig;
const OutputConfig = @import("loader.zig").OutputConfig;
const IdleConfig = @import("loader.zig").IdleConfig;
const desktopEnabled = @import("loader.zig").desktopEnabled;
const isDesktopClient = @import("loader.zig").isDesktopClient;
const default = @import("loader.zig").default;
const loadFromBytes = @import("loader.zig").loadFromBytes;
const parse = @import("loader.zig").parse;

test "[taskbar_theme] holds only taskbar tokens and is rewritten without touching its neighbours" {
    const a = std.testing.allocator;
    var cfg = try parse(a, "[theme]\nwindow_fg = \"#102030\"\n[taskbar_theme]\ntaskbar_bg = \"#112233\"\nwindow_fg = \"#445566\"\naccent = \"#ff0000\"\nchip_gap = 30\n[input]\ntap_drag = false\n", "mem");
    defer cfg.deinit();
    const chosen = cfg.taskbar_theme.?;
    try std.testing.expectEqual(theme_mod.parseColor("#112233") catch unreachable, chosen.taskbar_bg);
    try std.testing.expectEqual(theme_mod.parseColor("#445566") catch unreachable, theme_mod.taskbarTokens(chosen).window_fg);
    // Neither the main theme nor the taskbar's other tokens move.
    try std.testing.expectEqual(theme_mod.parseColor("#102030") catch unreachable, cfg.theme.window_fg);
    try std.testing.expectEqual(@as(Theme, .{}).accent, chosen.accent);
    try std.testing.expectEqual(@as(Theme, .{}).chip_gap, chosen.chip_gap);
    // The header alone chooses a taskbar theme; no header means the main one.
    var bare = try parse(a, "[taskbar_theme]\n", "mem");
    defer bare.deinit();
    try std.testing.expect(bare.taskbar_theme != null);
    var none = try parse(a, "[theme]\n", "mem");
    defer none.deinit();
    try std.testing.expect(none.taskbar_theme == null);

    // What the writer saves reads back equal, and `[theme]` is not mistaken for it.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try theme_mod.writeTaskbarInto(a, &body, chosen);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try spliceSection(a, &out, "[theme]\nfont = \"X\"\n\n[input]\ntap_drag = false\n", "[taskbar_theme]", body.items);
    try std.testing.expectEqualStrings("[theme]\nfont = \"X\"\n\n[input]\ntap_drag = false\n[taskbar_theme]\ntaskbar_bg = \"rgba(17,34,51,1.000)\"\nwindow_fg = \"rgba(68,85,102,1.000)\"\n", out.items);
    var reread = try parse(a, out.items, "mem");
    defer reread.deinit();
    try std.testing.expect(theme_mod.taskbarOverrideEql(chosen, reread.taskbar_theme));
    try std.testing.expectEqualStrings("X", reread.theme.font);

    // Replacing it again keeps one copy and no extra blank lines; null removes it.
    var again: std.ArrayList(u8) = .empty;
    defer again.deinit(a);
    try spliceSection(a, &again, out.items, "[taskbar_theme]", "[taskbar_theme]\n");
    try std.testing.expectEqualStrings("[theme]\nfont = \"X\"\n\n[input]\ntap_drag = false\n[taskbar_theme]\n", again.items);
    var removed: std.ArrayList(u8) = .empty;
    defer removed.deinit(a);
    try spliceSection(a, &removed, out.items, "[taskbar_theme]", null);
    try std.testing.expectEqualStrings("[theme]\nfont = \"X\"\n\n[input]\ntap_drag = false\n", removed.items);
}

test "empty config keeps built-in zoom steps and default keybinds" {
    var cfg = try parse(std.testing.allocator, "", "mem");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u8, 4), cfg.compositor.zoom_step_count);
    try std.testing.expectEqual(@as(u8, 100), cfg.compositor.zoom_percents[0]);
    try std.testing.expect(cfg.autostart.len == 0);
    const monitor = try keybinds.parseKeybind("Ctrl+Alt+Delete");
    try std.testing.expectEqual(Action.open_system_monitor, cfg.lookupKeybind(monitor.modifiers, monitor.sym).?);
    try std.testing.expect(cfg.keybinds.len > 0);
    const spec = try keybinds.parseKeybind("super+t");
    const action = cfg.lookupKeybind(spec.modifiers, spec.sym) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("default-terminal", action.spawn);
}

test "System Monitor defaults preserve explicit canvas and workspace shortcut overrides" {
    const binding = try keybinds.parseKeybind("Ctrl+Alt+Delete");
    for ([_][]const u8{
        "[keybinds]\n",
        "[keybinds]\n\"Super+q\" = \"close_window\"\n\"Ctrl+Alt+Shift+Delete\" = \"poweroff\"\n",
    }) |source| {
        var existing = try parse(std.testing.allocator, source, "mem");
        defer existing.deinit();
        try std.testing.expectEqual(Action.open_system_monitor, existing.lookupKeybind(binding.modifiers, binding.sym).?);
        existing.compositor.desktop_mode = .workspaces;
        try std.testing.expectEqual(Action.open_system_monitor, existing.lookupKeybind(binding.modifiers, binding.sym).?);
    }
    var cfg = try parse(std.testing.allocator, "[keybinds]\n\"Ctrl+Alt+Delete\" = \"poweroff\"\n[keybinds.workspace]\n\"Ctrl+Alt+Delete\" = \"noop\"\n", "mem");
    defer cfg.deinit();
    try std.testing.expectEqual(Action.poweroff, cfg.lookupKeybind(binding.modifiers, binding.sym).?);
    cfg.compositor.desktop_mode = .workspaces;
    try std.testing.expectEqual(Action.noop, cfg.lookupKeybind(binding.modifiers, binding.sym).?);
    var disabled_cfg = try parse(std.testing.allocator, "[keybinds]\n\"Ctrl+Alt+Delete\" = \"noop\"\n", "mem");
    defer disabled_cfg.deinit();
    try std.testing.expectEqual(Action.noop, disabled_cfg.lookupKeybind(binding.modifiers, binding.sym).?);
}

test "the desktop follows its section, then a legacy rediwm-desktop autostart" {
    var empty = try parse(std.testing.allocator, "", "empty");
    defer empty.deinit();
    try std.testing.expect(!desktopEnabled(&empty));
    var legacy = try parse(std.testing.allocator, "[[autostart]]\ncmd = \"/usr/local/bin/rediwm-desktop --verbose\"\n", "legacy");
    defer legacy.deinit();
    try std.testing.expect(desktopEnabled(&legacy));
    var off = try parse(std.testing.allocator, "[[autostart]]\ncmd = \"rediwm-desktop\"\n[desktop]\nenabled = false\n", "off");
    defer off.deinit();
    try std.testing.expect(!desktopEnabled(&off));
    try std.testing.expect(!isDesktopClient("rediwm-desktop-helper"));
}

test "documented default parses all sections" {
    var cfg = try parse(std.testing.allocator, default_file.source, "default");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u8, 5), cfg.compositor.zoom_step_count);
    try std.testing.expectEqual(@as(u8, 40), cfg.compositor.zoom_percents[4]);
    try std.testing.expectEqual(@as(usize, 0), cfg.autostart.len);
    try std.testing.expect(desktopEnabled(&cfg));
    try std.testing.expect(cfg.input.natural_scroll);
    try std.testing.expectEqual(@as(u32, 400), cfg.input.key_repeat_delay);
    try std.testing.expectEqual(AccelProfile.bezier, cfg.input.accel_profile);
    try std.testing.expectEqual([2]f32{ 0.0, 0.0 }, cfg.input.accel_p1);
    try std.testing.expectEqual([2]f32{ 0.15, 1.0 }, cfg.input.accel_p2);
    try std.testing.expectEqual(@as(f32, 10.0), cfg.input.accel_max_speed);
    try std.testing.expectEqual(@as(u32, 10), cfg.compositor.border_radius);
    try std.testing.expect(cfg.compositor.xwayland);
    try std.testing.expectEqualStrings("Manrope", cfg.theme.font);

    const q = try keybinds.parseKeybind("super+q");
    try std.testing.expectEqual(Action.close_window, cfg.lookupKeybind(q.modifiers, q.sym).?);

    const depth = try keybinds.parseKeybind("super+3");
    try std.testing.expectEqual(@as(u8, 2), cfg.lookupKeybind(depth.modifiers, depth.sym).?.set_depth);
}

test "syntax error returns InvalidConfig" {
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[input]
        \\pointer_speed = 4.0
    , "bad"));
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[keybinds]
        \\"super+t" = "nope"
    , "bad"));
}

test "xwayland config defaults on and can be disabled" {
    var on = try parse(std.testing.allocator, "", "mem");
    defer on.deinit();
    try std.testing.expect(on.compositor.xwayland);

    var off = try parse(std.testing.allocator,
        \\[compositor]
        \\xwayland = false
    , "off");
    defer off.deinit();
    try std.testing.expect(!off.compositor.xwayland);
}

test "inline comments do not break values" {
    var cfg = try parse(std.testing.allocator,
        \\[input]
        \\pointer_speed = 0.5  # comment
        \\natural_scroll = false
    , "comments");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(f32, 0.5), cfg.input.pointer_speed);
    try std.testing.expect(!cfg.input.natural_scroll);
}

test "accel config parses bezier and flat sections" {
    var bezier_cfg = try parse(std.testing.allocator,
        \\[input]
        \\accel_profile = "bezier"
        \\accel_p1 = [0.1, 0.2]
        \\accel_p2 = [0.3, 0.9]
        \\accel_max_speed = 15.0
    , "bezier");
    defer bezier_cfg.deinit();
    try std.testing.expectEqual(AccelProfile.bezier, bezier_cfg.input.accel_profile);
    try std.testing.expectEqual([2]f32{ 0.1, 0.2 }, bezier_cfg.input.accel_p1);
    try std.testing.expectEqual([2]f32{ 0.3, 0.9 }, bezier_cfg.input.accel_p2);
    try std.testing.expectEqual(@as(f32, 15.0), bezier_cfg.input.accel_max_speed);

    var flat_cfg = try parse(std.testing.allocator,
        \\[input]
        \\accel_profile = "flat"
    , "flat");
    defer flat_cfg.deinit();
    try std.testing.expectEqual(AccelProfile.flat, flat_cfg.input.accel_profile);
}

test "idle config parsing and validation" {
    var def = try parse(std.testing.allocator, "", "mem");
    defer def.deinit();
    try std.testing.expectEqual(@as(?bool, null), def.idle.enabled);
    try std.testing.expectEqual(@as(u32, 600), def.idle.blank_after_seconds);
    try std.testing.expectEqual(@as(u32, 0), def.idle.suspend_after_seconds);

    var custom = try parse(std.testing.allocator,
        \\[idle]
        \\enabled = true
        \\blank_after_seconds = 300
        \\suspend_after_seconds = 600
    , "custom");
    defer custom.deinit();
    try std.testing.expectEqual(@as(?bool, true), custom.idle.enabled);
    try std.testing.expectEqual(@as(u32, 300), custom.idle.blank_after_seconds);
    try std.testing.expectEqual(@as(u32, 600), custom.idle.suspend_after_seconds);

    // Validation: suspend must be strictly greater than blank when both are non-zero
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[idle]
        \\blank_after_seconds = 600
        \\suspend_after_seconds = 600
    , "equal"));

    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[idle]
        \\blank_after_seconds = 600
        \\suspend_after_seconds = 300
    , "less"));

    // Negative values fail parsing
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[idle]
        \\blank_after_seconds = -1
    , "negative"));
}

test "input and theme reload detect every field and compare strings by content" {
    const original_theme = Theme{};
    inline for (@typeInfo(Theme).@"struct".field_names) |field_name| {
        var changed = original_theme;
        @field(changed, field_name) = switch (@FieldType(Theme, field_name)) {
            bool => !@field(original_theme, field_name),
            f32 => @field(original_theme, field_name) + 1,
            []const u8 => "another theme",
            [4]f32 => .{ 0.1, 0.2, 0.3, 0.4 },
            ?[4]f32 => .{ 0.1, 0.2, 0.3, 0.4 },
            theme_mod.Relief => if (@field(original_theme, field_name) == .flat) .raised else .flat,
            else => @compileError("add a theme change fixture for " ++ field_name),
        };
        try std.testing.expect(!themeEql(original_theme, changed));
        try std.testing.expect(!themeEql(changed, original_theme));
    }
    var theme_copy = original_theme;
    theme_copy.font = try std.testing.allocator.dupe(u8, original_theme.font);
    defer std.testing.allocator.free(theme_copy.font);
    try std.testing.expect(themeEql(original_theme, theme_copy));
    const original = InputConfig{};
    inline for (@typeInfo(InputConfig).@"struct".field_names) |field_name| {
        var changed = original;
        @field(changed, field_name) = switch (@FieldType(InputConfig, field_name)) {
            bool => !@field(original, field_name),
            f32, u32 => @field(original, field_name) + 1,
            []const u8 => "another theme",
            []const []const u8 => if (@field(original, field_name).len == 0) &.{"another"} else &.{},
            AccelProfile => switch (@field(original, field_name)) {
                .bezier => .flat,
                .flat => .bezier,
            },
            PanModifier => switch (@field(original, field_name)) {
                .super => .super_alt,
                .super_alt => .super,
            },
            [2]f32 => .{ @field(original, field_name)[0] + 0.1, @field(original, field_name)[1] + 0.1 },
            else => @compileError("add an input change fixture for " ++ field_name),
        };
        try std.testing.expect(!inputEql(original, changed));
        try std.testing.expect(!inputEql(changed, original));
    }
    var copy = original;
    copy.cursor_theme = try std.testing.allocator.dupe(u8, original.cursor_theme);
    defer std.testing.allocator.free(copy.cursor_theme);
    try std.testing.expect(inputEql(original, copy));
}

test {
    _ = @import("loader_fields_tests.zig");
}

test {
    _ = @import("loader_sections_tests.zig");
}
