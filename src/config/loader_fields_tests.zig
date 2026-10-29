//! Config field tests: ranges and derived zoom state, idle rules, window rules, laptop controls and night light.

const std = @import("std");
const keybinds = @import("keybinds.zig");
const Action = keybinds.Action;
const types = @import("types.zig");
const window_rules = @import("window_rules.zig");
const schedule_mod = @import("schedule.zig");
const ScheduleMode = schedule_mod.ScheduleMode;
const NightLightConfig = schedule_mod.NightLightConfig;
const AccelProfile = types.AccelProfile;
const applyInputKey = @import("loader_fields.zig").applyInputKey;
const applyCompositorKey = @import("loader_fields.zig").applyCompositorKey;
const applyIdleKey = @import("loader_fields.zig").applyIdleKey;
const default_zoom_percents = @import("loader.zig").default_zoom_percents;
const InputConfig = @import("loader.zig").InputConfig;
const CompositorConfig = @import("loader.zig").CompositorConfig;
const IdleConfig = @import("loader.zig").IdleConfig;
const default = @import("loader.zig").default;
const parse = @import("loader.zig").parse;

test "config field parsing preserves ranges and derived zoom state" {
    var input = InputConfig{};
    const a = std.testing.allocator;
    inline for (.{
        .{ "key_repeat_delay", "1", "5000", "0", "5001" },
        .{ "key_repeat_rate", "1", "200", "0", "201" },
        .{ "cursor_size", "1", "256", "0", "257" },
    }) |fixture| {
        try applyInputKey(&input, a, fixture[0], fixture[1]);
        try std.testing.expectEqual(try std.fmt.parseInt(u32, fixture[1], 10), @field(input, fixture[0]));
        try applyInputKey(&input, a, fixture[0], fixture[2]);
        try std.testing.expectEqual(try std.fmt.parseInt(u32, fixture[2], 10), @field(input, fixture[0]));
        try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, fixture[0], fixture[3]));
        try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, fixture[0], fixture[4]));
    }
    try applyInputKey(&input, a, "pointer_speed", "-1");
    try std.testing.expectEqual(@as(f32, -1), input.pointer_speed);
    try applyInputKey(&input, a, "pointer_speed", "1");
    try std.testing.expectEqual(@as(f32, 1), input.pointer_speed);
    try applyInputKey(&input, a, "pointer_speed_touchpad", "-1");
    try std.testing.expectEqual(@as(f32, -1), input.pointer_speed_touchpad);
    try applyInputKey(&input, a, "pointer_speed_touchpad", "1");
    try std.testing.expectEqual(@as(f32, 1), input.pointer_speed_touchpad);
    try applyInputKey(&input, a, "disable_while_typing_touchpad", "true");
    try std.testing.expect(input.disable_while_typing_touchpad);
    try applyInputKey(&input, a, "disable_while_typing_touchpad", "false");
    try std.testing.expect(!input.disable_while_typing_touchpad);
    inline for (.{ "-1.01", "1.01", "nan", "inf" }) |v| {
        try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "pointer_speed", v));
    }
    inline for (.{ "-1.01", "1.01", "nan", "inf" }) |v| {
        try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "pointer_speed_touchpad", v));
    }
    inline for (.{ "natural_scroll", "invert_scroll", "left_handed", "tap_to_click", "tap_drag", "disable_while_typing" }) |key| {
        try applyInputKey(&input, a, key, "false");
        try std.testing.expect(!@field(input, key));
        try applyInputKey(&input, a, key, "true");
        try std.testing.expect(@field(input, key));
    }
    try applyInputKey(&input, a, "cursor_theme", "\"custom\"");
    defer a.free(input.cursor_theme);
    try std.testing.expectEqualStrings("custom", input.cursor_theme);

    try applyInputKey(&input, a, "accel_profile", "\"flat\"");
    try std.testing.expectEqual(AccelProfile.flat, input.accel_profile);
    try applyInputKey(&input, a, "accel_profile", "bezier");
    try std.testing.expectEqual(AccelProfile.bezier, input.accel_profile);
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_profile", "\"nope\""));

    try applyInputKey(&input, a, "accel_p1", "[0.0, 0.0]");
    try std.testing.expectEqual([2]f32{ 0.0, 0.0 }, input.accel_p1);
    try applyInputKey(&input, a, "accel_p2", "[ 0.15 , 1.0 ]");
    try std.testing.expectEqual([2]f32{ 0.15, 1.0 }, input.accel_p2);
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_p1", "[-0.1, 0.0]"));
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_p1", "[1.1, 0.0]"));
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_p1", "[0.0]"));
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_p1", "[0.0, 0.0, 0.0]"));
    try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_p1", "bad"));

    try applyInputKey(&input, a, "accel_max_speed", "10.0");
    try std.testing.expectEqual(@as(f32, 10.0), input.accel_max_speed);
    try applyInputKey(&input, a, "accel_max_speed", "25.5");
    try std.testing.expectEqual(@as(f32, 25.5), input.accel_max_speed);
    inline for (.{ "0", "-1", "nan", "inf" }) |v| {
        try std.testing.expectError(error.InvalidValue, applyInputKey(&input, a, "accel_max_speed", v));
    }

    var c = CompositorConfig{};
    try std.testing.expectEqual(types.TaskbarAlignment.center, c.taskbar_alignment);
    inline for (.{ "left", "center", "right" }) |value| {
        try applyCompositorKey(&c, a, "taskbar_alignment", "\"" ++ value ++ "\"");
        try std.testing.expectEqualStrings(value, @tagName(c.taskbar_alignment));
    }
    try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, "taskbar_alignment", "top"));
    try std.testing.expectEqual(types.DockPosition.bottom, c.dock_position);
    inline for (.{ "top", "bottom", "left", "right" }) |value| {
        try applyCompositorKey(&c, a, "dock_position", value);
        try std.testing.expectEqual(std.meta.stringToEnum(types.DockPosition, value).?, c.dock_position);
    }
    try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, "dock_position", "center"));
    try std.testing.expectEqual(@as(u32, 0), c.windowGap());
    c.desktop_mode = .workspaces;
    try std.testing.expectEqual(@as(u32, 8), c.windowGap());
    try applyCompositorKey(&c, a, "window_gap", "0");
    try std.testing.expectEqual(@as(u32, 0), c.windowGap());
    c.desktop_mode = .canvas;
    inline for (.{
        .{ "canvas_width", "1", "100000", "0", "100001" },
        .{ "canvas_height", "1", "100000", "0", "100001" },
        .{ "window_gap", "0", "512", "513", "514" },
        .{ "border_radius", "0", "128", "129", "130" },
        .{ "dock_height", "48", "96", "47", "97" },
    }) |fixture| {
        try applyCompositorKey(&c, a, fixture[0], fixture[1]);
        try std.testing.expectEqual(@as(@TypeOf(@field(c, fixture[0])), try std.fmt.parseInt(u32, fixture[1], 10)), @field(c, fixture[0]));
        try applyCompositorKey(&c, a, fixture[0], fixture[2]);
        try std.testing.expectEqual(@as(@TypeOf(@field(c, fixture[0])), try std.fmt.parseInt(u32, fixture[2], 10)), @field(c, fixture[0]));
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, fixture[0], fixture[3]));
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, fixture[0], fixture[4]));
    }
    inline for (.{ "1", "1.05", "1.5" }) |value| {
        try applyCompositorKey(&c, a, "dock_hover_zoom", value);
        try std.testing.expectEqual(try std.fmt.parseFloat(f32, value), c.dock_hover_zoom);
    }
    inline for (.{ "nan", "inf", "0.99", "1.51" }) |value| {
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, "dock_hover_zoom", value));
    }
    inline for (.{ "camera_zoom_min", "camera_zoom_max", "inactive_opacity" }) |key| {
        try applyCompositorKey(&c, a, key, "0.5");
        try std.testing.expectEqual(@as(f32, 0.5), @field(c, key));
        inline for (.{ "nan", "inf", "-0.1", "8.1" }) |v| {
            try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, key, v));
        }
    }
    inline for (.{ "camera_zoom_min", "camera_zoom_max" }) |key| {
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, key, "0"));
        try applyCompositorKey(&c, a, key, "8");
        try std.testing.expectEqual(@as(f32, 8), @field(c, key));
    }
    try applyCompositorKey(&c, a, "inactive_opacity", "0");
    try std.testing.expectEqual(@as(f32, 0), c.inactive_opacity);
    try applyCompositorKey(&c, a, "inactive_opacity", "1");
    try std.testing.expectEqual(@as(f32, 1), c.inactive_opacity);
    try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, "inactive_opacity", "1.01"));
    try std.testing.expectEqual(@as(?f32, null), c.terminal_opacity);
    try applyCompositorKey(&c, a, "terminal_opacity", "0.85");
    try std.testing.expectEqual(@as(?f32, 0.85), c.terminal_opacity);
    inline for (.{ "nan", "-0.1", "1.01" }) |v| {
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, "terminal_opacity", v));
    }
    try std.testing.expectEqual(@as(?f32, null), c.dock_opacity);
    try std.testing.expect(!c.dock_active_highlight);
    try applyCompositorKey(&c, a, "dock_opacity", "0.6");
    try std.testing.expectEqual(@as(?f32, 0.6), c.dock_opacity);
    inline for (.{ "nan", "-0.1", "1.01" }) |v| {
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, "dock_opacity", v));
    }
    try applyCompositorKey(&c, a, "dock_active_highlight", "true");
    try std.testing.expect(c.dock_active_highlight);
    try std.testing.expect(c.inactive_dim);
    try std.testing.expectEqual(@as(f32, 0.08), c.inactive_dim_amount);
    try applyCompositorKey(&c, a, "inactive_dim", "false");
    try std.testing.expect(!c.inactive_dim);
    try applyCompositorKey(&c, a, "inactive_dim_amount", "0.5");
    try std.testing.expectEqual(@as(f32, 0.5), c.inactive_dim_amount);
    inline for (.{ "nan", "inf", "-0.1", "0.51" }) |v| {
        try std.testing.expectError(error.InvalidValue, applyCompositorKey(&c, a, "inactive_dim_amount", v));
    }
    try applyCompositorKey(&c, a, "focus_follows_mouse", "true");
    try std.testing.expect(c.focus_follows_mouse);
    try applyCompositorKey(&c, a, "xwayland", "false");
    try std.testing.expect(!c.xwayland);
    try applyCompositorKey(&c, a, "zoom_steps", "[1, 0.75]");
    try std.testing.expectEqual(@as(u8, 2), c.zoom_step_count);
    try std.testing.expectEqualSlices(f32, &.{ 1, 0.75 }, c.zoom_steps[0..2]);
    try applyCompositorKey(&c, a, "zoom_step_count", "7");
    try applyCompositorKey(&c, a, "zoom_percents", "[20]");
    try std.testing.expectEqual(@as(u8, 2), c.zoom_step_count);
    try std.testing.expectEqualSlices(u8, &default_zoom_percents, c.zoom_percents);
    try applyInputKey(&input, a, "unknown", "ignored");
    try applyCompositorKey(&c, a, "unknown", "ignored");
}

test "idle field rules preserve optional enabled and strict unknown keys" {
    const a = std.testing.allocator;
    var idle = IdleConfig{};
    try std.testing.expectEqual(@as(?bool, null), idle.enabled);
    try applyIdleKey(&idle, a, "enabled", "false");
    try std.testing.expectEqual(@as(?bool, false), idle.enabled);
    try applyIdleKey(&idle, a, "enabled", "true");
    try std.testing.expectEqual(@as(?bool, true), idle.enabled);
    try std.testing.expectError(error.InvalidValue, applyIdleKey(&idle, a, "enabled", "null"));
    inline for (.{ "blank_after_seconds", "suspend_after_seconds" }) |key| {
        try applyIdleKey(&idle, a, key, "0");
        try std.testing.expectEqual(@as(u32, 0), @field(idle, key));
        try applyIdleKey(&idle, a, key, "4294967295");
        try std.testing.expectEqual(std.math.maxInt(u32), @field(idle, key));
        try std.testing.expectError(error.Overflow, applyIdleKey(&idle, a, key, "4294967296"));
    }
    try std.testing.expectError(error.InvalidField, applyIdleKey(&idle, a, "unknown", "ignored"));
}

test "window_rules TOML parsing and validation" {
    const toml =
        \\[[window_rules]]
        \\app_id = "org.telegram.desktop"
        \\exclude_title = "Media viewer"
        \\output = "DP-2"
        \\center = true
        \\width = 900
        \\height = 700
        \\
        \\[[window_rules]]
        \\app_id = ["firefox", "chromium"]
        \\title = "Picture-in-Picture"
        \\opacity = 0.9
        \\skip_taskbar = true
        \\focus = false
        \\
        \\[[window_rules]]
        \\x11_class = "Steam"
        \\dialog = false
        \\maximized = true
        \\
        \\[[window_rules]]
        \\app_id = "foot"
        \\decorations = "client"
    ;

    var cfg = try parse(std.testing.allocator, toml, "rules_test");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 4), cfg.window_rules.len);

    const r0 = cfg.window_rules[0];
    try std.testing.expectEqualStrings("org.telegram.desktop", r0.app_id.?[0]);
    try std.testing.expectEqualStrings("Media viewer", r0.exclude_title.?[0]);
    try std.testing.expectEqualStrings("DP-2", r0.output.?);
    try std.testing.expectEqual(@as(?bool, true), r0.center);
    try std.testing.expectEqual(@as(?u32, 900), r0.width);
    try std.testing.expectEqual(@as(?u32, 700), r0.height);

    const r1 = cfg.window_rules[1];
    try std.testing.expectEqual(@as(usize, 2), r1.app_id.?.len);
    try std.testing.expectEqualStrings("firefox", r1.app_id.?[0]);
    try std.testing.expectEqualStrings("chromium", r1.app_id.?[1]);
    try std.testing.expectEqualStrings("Picture-in-Picture", r1.title.?[0]);
    try std.testing.expectEqual(@as(?f32, 0.9), r1.opacity);
    try std.testing.expectEqual(@as(?bool, true), r1.skip_taskbar);
    try std.testing.expectEqual(@as(?bool, false), r1.focus);

    const r2 = cfg.window_rules[2];
    try std.testing.expectEqualStrings("Steam", r2.x11_class.?[0]);
    try std.testing.expectEqual(@as(?bool, false), r2.dialog);
    try std.testing.expectEqual(@as(?bool, true), r2.maximized);

    const r3 = cfg.window_rules[3];
    try std.testing.expectEqualStrings("foot", r3.app_id.?[0]);
    try std.testing.expectEqual(window_rules.DecorationMode.client, r3.decorations.?);

    // Conflict error in TOML
    const bad_toml =
        \\[[window_rules]]
        \\center = true
        \\x = 100
    ;
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, bad_toml, "bad_rule"));

    // Unknown field error
    const bad_key =
        \\[[window_rules]]
        \\unknown_field = "value"
    ;
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, bad_key, "bad_key"));
}

test "existing configs inherit laptop controls and can override or disable them" {
    var cfg = try parse(std.testing.allocator,
        \\[keybinds]
        \\"super+t" = "spawn foot"
        \\"XF86AudioMute" = "noop"
    , "hardware");
    defer cfg.deinit();
    const up = try keybinds.parseKeybind("XF86AudioRaiseVolume");
    try std.testing.expectEqual(Action.volume_up, cfg.lookupKeybind(up.modifiers, up.sym).?);
    const mute = try keybinds.parseKeybind("XF86AudioMute");
    try std.testing.expectEqual(Action.noop, cfg.lookupKeybind(mute.modifiers, mute.sym).?);
}

test "night_light config parsing and defaults" {
    var def = try default(std.testing.allocator);
    defer def.deinit();

    try std.testing.expectEqual(true, def.night_light.enabled);
    try std.testing.expectEqual(ScheduleMode.always, def.night_light.schedule);
    try std.testing.expectEqual(@as(u32, 5000), def.night_light.temperature);
    try std.testing.expectEqual(@as(u32, 6500), def.night_light.day_temperature);
    try std.testing.expectEqual(@as(u16, 21 * 60), def.night_light.start);
    try std.testing.expectEqual(@as(u16, 7 * 60), def.night_light.end);
    try std.testing.expectEqual(@as(u16, 30), def.night_light.transition_minutes);
    try std.testing.expectEqual(@as(?f64, null), def.night_light.latitude);
    try std.testing.expectEqual(@as(?f64, null), def.night_light.longitude);

    // Snapshot survives deinit (holds only scalars)
    var snapshot: NightLightConfig = undefined;
    {
        var custom = try parse(std.testing.allocator,
            \\[night_light]
            \\enabled = true
            \\schedule = "fixed"
            \\temperature = 3400
            \\day_temperature = 6000
            \\start = "22:00"
            \\end = "06:30"
            \\transition_minutes = 45
            \\
            \\[[outputs]]
            \\name = "DP-2"
            \\night_light = false
            \\gamma = 1.2
        , "custom");
        snapshot = custom.night_light;
        try std.testing.expectEqual(true, custom.outputs[0].night_light == false);
        try std.testing.expectApproxEqAbs(@as(f32, 1.2), custom.outputs[0].gamma, 0.001);
        custom.deinit();
    }
    try std.testing.expectEqual(true, snapshot.enabled);
    try std.testing.expectEqual(ScheduleMode.fixed, snapshot.schedule);
    try std.testing.expectEqual(@as(u32, 3400), snapshot.temperature);
    try std.testing.expectEqual(@as(u32, 6000), snapshot.day_temperature);
    try std.testing.expectEqual(@as(u16, 22 * 60), snapshot.start);
    try std.testing.expectEqual(@as(u16, 6 * 60 + 30), snapshot.end);
    try std.testing.expectEqual(@as(u16, 45), snapshot.transition_minutes);
}
