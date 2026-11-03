//! Config section tests: outputs, night light schedules, animations, polkit, canvas, input methods, sandboxes, the mini map, workspaces and theme layering.

const std = @import("std");
const theme_mod = @import("ui").theme;
const keybinds = @import("keybinds.zig");
const Action = keybinds.Action;
const default_file = @import("default.zig");
const anim = @import("ui").anim;
const output_transform = @import("output_transform.zig");
const schedule_mod = @import("schedule.zig");
const ScheduleMode = schedule_mod.ScheduleMode;
const output_rules = @import("loader_fields.zig").output_rules;
const fieldHint = @import("loader_fields.zig").fieldHint;
const themeEql = @import("loader_compare.zig").themeEql;
const OutputConfig = @import("loader.zig").OutputConfig;
const loadFromBytes = @import("loader.zig").loadFromBytes;
const parse = @import("loader.zig").parse;

test "output policy parses enabled and unique primary" {
    var cfg = try parse(std.testing.allocator,
        \\[[outputs]]
        \\name = "DP-1"
        \\primary = true
        \\enabled = false
        \\
        \\[[outputs]]
        \\name = "DP-2"
    , "output_policy");
    defer cfg.deinit();
    try std.testing.expectEqual(false, cfg.outputs[0].enabled);
    try std.testing.expectEqual(true, cfg.outputs[0].primary);
    try std.testing.expectEqual(true, cfg.outputs[1].enabled);
    try std.testing.expectEqual(false, cfg.outputs[1].primary);

    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator,
        \\[[outputs]]
        \\name = "DP-1"
        \\primary = true
        \\
        \\[[outputs]]
        \\name = "DP-2"
        \\primary = true
    , "ambiguous_primary"));
}

test "outputs fields parse through the rule table" {
    const a = std.testing.allocator;
    var cfg = try parse(a,
        \\[[outputs]]
        \\name = "DP-1"
        \\width = 2560
        \\height = 1440
        \\refresh_mhz = 144000
        \\x = -2560
        \\y = 0
        \\scale = 1.33
        \\transform = "flipped_90"
        \\night_light = false
        \\gamma = 1.2
        \\
        \\[[outputs]]
        \\name = "DP-2"
        \\scale = "auto"
    , "outputs_fields");
    defer cfg.deinit();
    const o = cfg.outputs[0];
    try std.testing.expectEqualStrings("DP-1", o.name);
    try std.testing.expectEqual(@as(?i32, 2560), o.width);
    try std.testing.expectEqual(@as(?i32, 1440), o.height);
    try std.testing.expectEqual(@as(?i32, 144000), o.refresh_mhz);
    try std.testing.expectEqual(@as(?i32, -2560), o.x);
    try std.testing.expectEqual(@as(?i32, 0), o.y);
    try std.testing.expectEqual(@as(?f32, 160.0 / 120.0), o.scale);
    try std.testing.expectEqual(output_transform.Transform.flipped_90, o.transform);
    try std.testing.expectEqual(false, o.night_light);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), o.gamma, 0.001);
    try std.testing.expectEqual(@as(?f32, null), cfg.outputs[1].scale);

    inline for (.{
        "width = 0",       "height = -1",        "refresh_mhz = 1.5", "x = 1.5",
        "scale = 0.9",     "scale = 3.1",        "scale = \"nan\"",   "scale = auto",
        "transform = 45",  "transform = \"45\"", "enabled = 1",       "name = DP-1",
        "unknown_key = 1",
    }) |line| {
        try std.testing.expectError(error.InvalidConfig, parse(a, "[[outputs]]\n" ++ line ++ "\n", "err"));
    }
    try std.testing.expectEqualStrings("a positive integer", fieldHint(OutputConfig, output_rules, "width"));
    try std.testing.expectEqualStrings("an integer", fieldHint(OutputConfig, output_rules, "x"));
    try std.testing.expectEqualStrings("a number between 0.5 and 2", fieldHint(OutputConfig, output_rules, "gamma"));
}

test "night_light sun and always schedules" {
    var sun_cfg = try parse(std.testing.allocator,
        \\[night_light]
        \\enabled = true
        \\schedule = "sun"
        \\latitude = 51.51
        \\longitude = -0.13
    , "sun");
    defer sun_cfg.deinit();
    try std.testing.expectEqual(ScheduleMode.sun, sun_cfg.night_light.schedule);
    try std.testing.expectApproxEqAbs(@as(f64, 51.51), sun_cfg.night_light.latitude.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -0.13), sun_cfg.night_light.longitude.?, 0.001);

    var always_cfg = try parse(std.testing.allocator,
        \\[night_light]
        \\enabled = true
        \\schedule = "always"
        \\temperature = 2700
    , "always");
    defer always_cfg.deinit();
    try std.testing.expectEqual(ScheduleMode.always, always_cfg.night_light.schedule);
    try std.testing.expectEqual(@as(u32, 2700), always_cfg.night_light.temperature);
}

test "night_light validation errors" {
    const a = std.testing.allocator;

    // Unknown field
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nunknown = 1\n", "err"));

    // Temperature outside 1700-10000
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\ntemperature = 1600\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\ntemperature = 10500\n", "err"));

    // Day temperature outside 1700-10000
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nday_temperature = 1500\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nday_temperature = 11000\n", "err"));

    // Start equals end
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nstart = \"08:00\"\nend = \"08:00\"\n", "err"));

    // Transition minutes > 180
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\ntransition_minutes = 200\n", "err"));

    // Transition minutes not shorter than night or day span (e.g. night span 30m, transition 30m)
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nstart = \"23:00\"\nend = \"23:30\"\ntransition_minutes = 30\n", "err"));

    // Sun schedule missing coordinates
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nschedule = \"sun\"\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nschedule = \"sun\"\nlatitude = 50.0\n", "err"));

    // Sun schedule coordinates out of range
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nschedule = \"sun\"\nlatitude = 95.0\nlongitude = 0.0\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[night_light]\nschedule = \"sun\"\nlatitude = 0.0\nlongitude = -190.0\n", "err"));

    // Output gamma outside 0.5-2.0 or not finite
    try std.testing.expectError(error.InvalidConfig, parse(a, "[[outputs]]\nname = \"DP-1\"\ngamma = 0.4\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[[outputs]]\nname = \"DP-1\"\ngamma = 2.5\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[[outputs]]\nname = \"DP-1\"\ngamma = \"nan\"\n", "err"));
}

test "animations config defaults and overlay" {
    var empty = try parse(std.testing.allocator, "", "mem");
    defer empty.deinit();
    try std.testing.expect(empty.animations.enabled);
    try std.testing.expectEqual(@as(f32, 1.0), empty.animations.speed);
    try std.testing.expectEqual(anim.ReducedMotion.auto, empty.animations.reduced_motion);
    const panel = empty.animations.targets[@backingInt(anim.Target.panel_slide)];
    try std.testing.expectEqual(anim.springs.panel_slide.stiffness, panel.curve.spring.stiffness);

    var cfg = try parse(std.testing.allocator,
        \\[animations]
        \\enabled = true
        \\speed = 0.5
        \\reduced_motion = "on"
        \\
        \\[animations.panel_slide]
        \\spring = { damping_ratio = 0.9, stiffness = 400, epsilon = 0.001 }
        \\
        \\[animations.taskbar_press]
        \\duration_ms = 120
        \\ease = "flip_bezier"
        \\
        \\[animations.camera_pan]
        \\spring = { damping_ratio = 1.0, stiffness = 300 }
        \\decay_rate = 0.99
        \\
        \\[animations.window_open]
        \\off = true
    , "anim");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(f32, 0.5), cfg.animations.speed);
    try std.testing.expectEqual(anim.ReducedMotion.on, cfg.animations.reduced_motion);
    const slide = cfg.animations.targets[@backingInt(anim.Target.panel_slide)].curve.spring;
    try std.testing.expectEqual(@as(f32, 0.9), slide.damping_ratio);
    try std.testing.expectEqual(@as(f32, 400), slide.stiffness);
    try std.testing.expectEqual(@as(f32, 0.001), slide.epsilon);
    const press = cfg.animations.targets[@backingInt(anim.Target.taskbar_press)].curve.duration;
    try std.testing.expectEqual(@as(i64, 120), press.ms);
    try std.testing.expectEqual(anim.Ease.flip_bezier, press.ease);
    const pan = cfg.animations.targets[@backingInt(anim.Target.camera_pan)];
    try std.testing.expectEqual(@as(f32, 300), pan.curve.spring.stiffness);
    try std.testing.expectEqual(@as(f32, 0.5), pan.curve.spring.epsilon);
    try std.testing.expectEqual(@as(f32, 0.99), pan.decay.rate);
    try std.testing.expect(cfg.animations.targets[@backingInt(anim.Target.window_open)].curve == .off);
}

test "animations config rejects unknown targets and illegal combinations" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations.window_opne]\nspring = { stiffness = 800 }\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations]\nspeed = -1\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations]\nreduced_motion = \"maybe\"\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations.panel_slide]\nspring = { damping_ratio = 1.0, stiffness = 900 }\nduration_ms = 90\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations.panel_slide]\noff = true\nspring = { stiffness = 800 }\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations.panel_slide]\nspring = { wobble = 1 }\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations.camera_pan]\nspring = { damping_ratio = 1.0, stiffness = 500, epsilon = 0.0001 }\n", "err"));
    try std.testing.expectError(error.InvalidConfig, parse(a, "[animations]\nunknown = true\n", "err"));
}

test "documented default still parses with commented animations block" {
    var cfg = try parse(std.testing.allocator, default_file.source, "default");
    defer cfg.deinit();
    try std.testing.expect(cfg.animations.enabled);
    try std.testing.expectEqual(anim.ReducedMotion.auto, cfg.animations.reduced_motion);
}

test "polkit defaults and strict configuration validation" {
    var defaults_cfg = try parse(std.testing.allocator, "", "polkit-defaults");
    defer defaults_cfg.deinit();
    try std.testing.expect(defaults_cfg.polkit.enable);
    try std.testing.expectEqualStrings("/run/polkit/agent-helper.socket", defaults_cfg.polkit.helper_socket);
    var custom = try parse(std.testing.allocator, "[polkit]\nenable = false\nhelper_socket = \"/tmp/test-helper\"\n", "polkit-custom");
    defer custom.deinit();
    try std.testing.expect(!custom.polkit.enable);
    try std.testing.expectEqualStrings("/tmp/test-helper", custom.polkit.helper_socket);
    for ([_][]const u8{ "enable = 1", "enabled = true", "helper_socket = \"\"", "helper_socket = \"relative/path\"", "unknown = false" }) |line| {
        const content = try std.fmt.allocPrint(std.testing.allocator, "[polkit]\n{s}\n", .{line});
        defer std.testing.allocator.free(content);
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, content, "polkit-invalid"));
    }
    const long_path = "[polkit]\nhelper_socket = \"/" ++ @as([107]u8, @splat('a')) ++ "\"\n";
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, long_path, "polkit-overlong"));
}

test "canvas screen counts default to three and reject values outside one to ten" {
    const a = std.testing.allocator;
    var defaults = try parse(a, "", "mem");
    defer defaults.deinit();
    try std.testing.expectEqual(@as(u32, 3), defaults.compositor.canvas_columns);
    try std.testing.expectEqual(@as(u32, 3), defaults.compositor.canvas_rows);
    var rectangular = try parse(a, "[compositor]\ncanvas_columns = 10\ncanvas_rows = 1\n", "mem");
    defer rectangular.deinit();
    try std.testing.expectEqual(@as(u32, 10), rectangular.compositor.canvas_columns);
    try std.testing.expectEqual(@as(u32, 1), rectangular.compositor.canvas_rows);
    inline for (.{ "canvas_columns", "canvas_rows" }) |key| {
        inline for (.{ "0", "11", "-1", "1.5" }) |value| {
            try std.testing.expectError(error.InvalidConfig, parse(a, "[compositor]\n" ++ key ++ " = " ++ value ++ "\n", "err"));
        }
    }
}

test "desktop switch duration sets the camera_desktop curve unless animations override it" {
    const a = std.testing.allocator;
    const idx = @backingInt(anim.Target.camera_desktop);
    var defaults = try parse(a, "", "mem");
    defer defaults.deinit();
    try std.testing.expectEqual(anim.desktopSwitchCurve(anim.default_desktop_switch_ms), defaults.animations.targets[idx].curve);
    var slow = try parse(a, "[compositor]\ndesktop_switch_ms = 1500\n", "mem");
    defer slow.deinit();
    try std.testing.expectEqual(anim.desktopSwitchCurve(1500), slow.animations.targets[idx].curve);
    var explicit = try parse(a, "[compositor]\ndesktop_switch_ms = 1500\n[animations.camera_desktop]\nduration_ms = 300\n", "mem");
    defer explicit.deinit();
    try std.testing.expectEqual(@as(i64, 300), explicit.animations.targets[idx].curve.duration.ms);
    inline for (.{ "99", "3001" }) |value| {
        try std.testing.expectError(error.InvalidConfig, parse(a, "[compositor]\ndesktop_switch_ms = " ++ value ++ "\n", "err"));
    }
}

test "input method environment validates supported names" {
    for ([_][]const u8{ "none", "fcitx", "ibus" }) |name| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "[input_method]\nenv = \"{s}\"\n", .{name});
        defer std.testing.allocator.free(source);
        var cfg = try parse(std.testing.allocator, source, "ime-env");
        defer cfg.deinit();
        try std.testing.expectEqualStrings(name, @tagName(cfg.input_method.env));
    }
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, "[input_method]\nenv = \"unknown\"", "bad-ime-env"));
}

test "sandbox_allow TOML parsing and resolution" {
    const toml =
        \\[[sandbox_allow]]
        \\app_id = "com.obsproject.Studio"
        \\engine = "org.flatpak"
        \\allow = ["capture", "windows"]
        \\
        \\[[sandbox_allow]]
        \\app_id = "org.example.App"
        \\allow = ["clipboard", "unknown_group"]
    ;
    var cfg = try parse(std.testing.allocator, toml, "sandbox-test");
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 2), cfg.sandbox_allow.len);

    const obs = cfg.sandboxAllowGroups("com.obsproject.Studio", "org.flatpak");
    try std.testing.expect(obs.contains(.capture));
    try std.testing.expect(obs.contains(.windows));
    try std.testing.expect(!obs.contains(.clipboard));

    const obs_wrong_engine = cfg.sandboxAllowGroups("com.obsproject.Studio", "other.engine");
    try std.testing.expect(obs_wrong_engine.count() == 0);

    const app = cfg.sandboxAllowGroups("org.example.App", "any.engine");
    try std.testing.expect(app.contains(.clipboard));
    try std.testing.expect(!app.contains(.capture));

    try std.testing.expect(cfg.sandboxAllowGroups(null, null).count() == 0);

    const bad_toml =
        \\[[sandbox_allow]]
        \\allow = ["clipboard"]
    ;
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, bad_toml, "bad-sandbox"));
}

test "mini map defaults and validated configuration" {
    const a = std.testing.allocator;
    var defaults = try parse(a, "", "mem");
    defer defaults.deinit();
    try std.testing.expect(defaults.compositor.mini_map_enabled);
    try std.testing.expectEqual(.bottom_right, defaults.compositor.mini_map_position);
    try std.testing.expectEqual(@as(u32, 1500), defaults.compositor.mini_map_hide_ms);
    var custom = try parse(a, "[compositor]\nmini_map_enabled = false\nmini_map_position = \"bottom_center\"\nmini_map_hide_ms = 2000\n", "mem");
    defer custom.deinit();
    try std.testing.expect(!custom.compositor.mini_map_enabled);
    try std.testing.expectEqual(.bottom_center, custom.compositor.mini_map_position);
    try std.testing.expectEqual(@as(u32, 2000), custom.compositor.mini_map_hide_ms);
    inline for (.{ "mini_map_position = \"top\"", "mini_map_hide_ms = 0", "mini_map_hide_ms = 10001", "mini_map_enabled = 1" }) |line| {
        try std.testing.expectError(error.InvalidConfig, parse(a, "[compositor]\n" ++ line ++ "\n", "invalid"));
    }
}

test "workspace preset is independent, overrides include noop, and mode preserves canvas bindings" {
    var cfg = try parse(std.testing.allocator, "[keybinds]\n\"Super+q\" = \"spawn custom-canvas\"\n" ++
        "[keybinds.workspace]\n\"Super+c\" = \"noop\"\n\"Super+F12\" = \"workspace 8\"\n", "test");
    defer cfg.deinit();
    const q = try keybinds.parseKeybind("Super+q");
    const c = try keybinds.parseKeybind("Super+c");
    const two = try keybinds.parseKeybind("Super+2");
    try std.testing.expectEqualStrings("custom-canvas", cfg.lookupKeybind(q.modifiers, q.sym).?.spawn);
    cfg.compositor.desktop_mode = .workspaces;
    const monitor = try keybinds.parseKeybind("Ctrl+Alt+Delete");
    try std.testing.expectEqual(Action.open_system_monitor, cfg.lookupKeybind(monitor.modifiers, monitor.sym).?);
    try std.testing.expectEqualStrings("default-terminal", cfg.lookupKeybind(q.modifiers, q.sym).?.spawn);
    try std.testing.expectEqual(Action.noop, cfg.lookupKeybind(c.modifiers, c.sym).?);
    try std.testing.expectEqual(@as(u8, 2), cfg.lookupKeybind(two.modifiers, two.sym).?.workspace);
    const v = try keybinds.parseKeybind("Super+v");
    const rotate = try keybinds.parseKeybind("Super+j");
    const swap = try keybinds.parseKeybind("Super+Shift+Right");
    const split = try keybinds.parseKeybind("Super+Ctrl+Right");
    try std.testing.expectEqual(Action.toggle_floating, cfg.lookupKeybind(v.modifiers, v.sym).?);
    try std.testing.expectEqual(Action.toggle_split, cfg.lookupKeybind(rotate.modifiers, rotate.sym).?);
    try std.testing.expectEqual(Action.swap_right, cfg.lookupKeybind(swap.modifiers, swap.sym).?);
    try std.testing.expectEqual(Action.resize_split_right, cfg.lookupKeybind(split.modifiers, split.sym).?);
    cfg.compositor.desktop_mode = .canvas;
    try std.testing.expectEqual(@as(?Action, null), cfg.lookupKeybind(v.modifiers, v.sym));
    try std.testing.expectEqualStrings("custom-canvas", cfg.lookupKeybind(q.modifiers, q.sym).?.spawn);
    try std.testing.expectEqual(@as(?Action, null), cfg.lookupKeybind(two.modifiers, two.sym));
}

test "no base preserves legacy themes and embedded base layers config overrides" {
    const a = std.testing.allocator;
    const bytes = "[theme]\naccent = \"#123456\"\nfont_size = 14\n";
    var old = try parse(a, bytes, "legacy");
    defer old.deinit();
    var loaded = try loadFromBytes(a, bytes, "legacy", .empty, std.testing.io);
    defer loaded.deinit();
    try std.testing.expect(themeEql(old.theme, loaded.theme));
    var based = try loadFromBytes(a, "[theme]\nbase = \"rediwm-light\"\nfont_size = 14\n", "based", .empty, std.testing.io);
    defer based.deinit();
    try std.testing.expectEqualStrings("rediwm-light", based.theme_base);
    try std.testing.expectEqual(@as(f32, 14), based.theme.font_size);
    try std.testing.expect(themeEql(based.theme_defaults, based.theme_pack.?.tokens));
    try std.testing.expectEqual(based.theme_defaults.accent, based.theme.accent);

    var gold = try loadFromBytes(a, "[theme]\nbase = \"gold\"\n", "gold", .empty, std.testing.io);
    defer gold.deinit();
    try std.testing.expectEqual(.top, gold.compositor.taskbar_position);
    try std.testing.expect(gold.compositor.dock_enabled);
    try std.testing.expectEqual(@as(u32, 76), gold.compositor.dock_height);
    var customized = try loadFromBytes(a, "[theme]\nbase = \"gold\"\n[compositor]\ntaskbar_position = \"bottom\"\ndock_enabled = false\ndock_height = 52\n", "gold", .empty, std.testing.io);
    defer customized.deinit();
    try std.testing.expectEqual(.bottom, customized.compositor.taskbar_position);
    try std.testing.expect(!customized.compositor.dock_enabled);
    try std.testing.expectEqual(@as(u32, 52), customized.compositor.dock_height);
}

test "external overlay wins over a referenced pack without pinning inherited tokens" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const mem = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", mem);
    const path = try std.fs.path.join(mem, &.{ root, "overlay.toml" });
    try tmp.dir.writeFile(io, .{ .sub_path = "overlay.toml", .data = "[theme]\nfont_size = 16\n" });
    const entry = try std.fmt.allocPrintSentinel(mem, "REDIWM_THEME={s}", .{path}, 0);
    const entries = [_:null]?[*:0]const u8{entry.ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = &entries } };
    var cfg = try loadFromBytes(a, "[theme]\nbase = \"rediwm-light\"\nfont_size = 14\n", "test", env, io);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(f32, 16), cfg.theme.font_size);
    try std.testing.expectEqual(@as(f32, 14), cfg.theme_config.font_size);
    var edited = cfg.theme;
    edited.font_size = 17;
    try theme_mod.saveOverlay(a, io, path, edited, cfg.theme_config);
    const saved = try tmp.dir.readFileAlloc(io, "overlay.toml", a, .limited(4096));
    defer a.free(saved);
    try std.testing.expectEqualStrings("[theme]\nfont_size = 17\n", saved);
}

test "optional ribbon presets default off, parse and reject invalid settings" {
    const a = std.testing.allocator;
    var defaults = try parse(a, "", "test");
    defer defaults.deinit();
    try std.testing.expect(!defaults.effects.window_move.enabled);
    try std.testing.expect(!defaults.effects.minimize().enabled);
    try std.testing.expect(!defaults.effects.resize().enabled);
    try std.testing.expectEqual(@as(u32, 3000), defaults.effects.find("soft_flame").?.lifetime_ms);
    var custom = try parse(a, "[effects.window_move]\nenabled = true\npreset = \"blue\"\n" ++
        "[effects.presets.blue]\ntype = \"flame_ribbon\"\ncolor = \"#0088ff\"\n" ++
        "lifetime_ms = 10000\nquality = \"high\"\nwidth_px = 12\n", "test");
    defer custom.deinit();
    try std.testing.expect(custom.effects.window_move.enabled);
    try std.testing.expect(custom.effects.minimize().enabled);
    try std.testing.expectEqualStrings("blue", custom.effects.minimize().preset);
    try std.testing.expect(custom.effects.resize().enabled);
    try std.testing.expectEqualStrings("blue", custom.effects.resize().preset);
    var separate = try parse(a, "[effects.window_move]\nenabled = true\n" ++
        "[effects.window_minimize]\nenabled = false\n[effects.window_resize]\nenabled = false\n", "test");
    defer separate.deinit();
    try std.testing.expect(!separate.effects.minimize().enabled);
    try std.testing.expect(!separate.effects.resize().enabled);
    var resize_only = try parse(a, "[effects.window_resize]\nenabled = true\n", "test");
    defer resize_only.deinit();
    try std.testing.expect(resize_only.effects.resize().enabled and !resize_only.effects.window_move.enabled);
    try std.testing.expectEqual(@as(u32, 10000), custom.effects.find("blue").?.lifetime_ms);
    try std.testing.expectEqual(@as(f32, 12), custom.effects.find("blue").?.width_px);
    for ([_][]const u8{
        "[effects.window_move]\npreset = \"missing\"\n",
        "[effects.window_minimize]\npreset = \"missing\"\n",
        "[effects.window_resize]\npreset = \"missing\"\n",
        "[effects.window_mvoe]\nenabled = true\n",
        "[effects.presets.bad]\nwidth_px = nan\n",
        "[effects.presets.bad]\nlifetime_ms = 100000\n",
        "[effects.presets.bad]\nlifetime_ms = 10001\n",
        "[effects.presets.bad]\nquality = \"ultra\"\n",
        "[effects.presets.bad]\nunknown = 1\n",
        "[effects.presets.a]\n[effects.presets.a]\n",
    }) |bad| try std.testing.expectError(error.InvalidConfig, parse(a, bad, "test"));
}
