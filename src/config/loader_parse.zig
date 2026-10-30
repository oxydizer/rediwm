//! Parsing config.toml: sections and array tables, keybinds (default, override and workspace), the binding lookup and finishing compositor settings.

const std = @import("std");
const Allocator = std.mem.Allocator;
const theme_mod = @import("ui").theme;
const keybinds = @import("keybinds.zig");
const Keybind = keybinds.Keybind;
const default_file = @import("default.zig");
const types = @import("types.zig");
const window_rules = @import("window_rules.zig");
const WindowRule = window_rules.WindowRule;
const sandbox_allow = @import("sandbox_allow.zig");
const SandboxAllowRule = sandbox_allow.SandboxAllowRule;
const anim = @import("ui").anim;
const anim_cfg = @import("animations.zig");
const loader_fields = @import("loader_fields.zig");
const region_rules = loader_fields.region_rules;
const output_rules = loader_fields.output_rules;
const fieldHint = loader_fields.fieldHint;
const applyField = loader_fields.applyField;
const applyInputKey = loader_fields.applyInputKey;
const applyCompositorKey = loader_fields.applyCompositorKey;
const applyPolkitKey = loader_fields.applyPolkitKey;
const applyIdleKey = loader_fields.applyIdleKey;
const applyDesktopKey = loader_fields.applyDesktopKey;
const applyIpcKey = loader_fields.applyIpcKey;
const applyNightLightKey = loader_fields.applyNightLightKey;
const applyNotificationsKey = loader_fields.applyNotificationsKey;
const applyNotificationRuleKey = loader_fields.applyNotificationRuleKey;
const parseString = loader_fields.parseString;
const unquoteKey = loader_fields.unquoteKey;
const log = std.log.scoped(.config);
const loader = @import("loader.zig");
const max_zoom_steps = loader.max_zoom_steps;
const default_zoom_percents = loader.default_zoom_percents;
const OutputConfig = loader.OutputConfig;
const NotificationRule = loader.NotificationRule;
const Config = loader.Config;
const input_device = @import("input_device.zig");

const ParseState = struct {
    seen_keybinds: bool = false,
    seen_frame_radius: bool = false,
    autostart_list: std.ArrayListUnmanaged([]const u8) = .empty,
    bind_list: std.ArrayListUnmanaged(Keybind) = .empty,
    workspace_binds: std.ArrayListUnmanaged(Keybind) = .empty,
    outputs_list: std.ArrayListUnmanaged(OutputConfig) = .empty,
    current_output: OutputConfig = .{},
    have_current_output: bool = false,
    rule_list: std.ArrayListUnmanaged(WindowRule) = .empty,
    current_rule: WindowRule = .{},
    have_current_rule: bool = false,
    notif_rule_list: std.ArrayListUnmanaged(NotificationRule) = .empty,
    current_notif_rule: NotificationRule = .{},
    have_current_notif_rule: bool = false,
    sandbox_allow_list: std.ArrayListUnmanaged(SandboxAllowRule) = .empty,
    current_sandbox_allow: SandboxAllowRule = .{},
    have_current_sandbox_allow: bool = false,
    section: Section = .none,
    pointer_records: input_device.Parser = .{},
    target_flags: [anim.Target.count]anim_cfg.TargetFlags = @splat(.{}),

    fn apply(state: *ParseState, cfg: *Config, path: []const u8, line_no: usize, key: []const u8, value: []const u8) !void {
        switch (state.section) {
            .none => {},
            .theme => {
                if (std.mem.eql(u8, key, "base")) {
                    const id = try theme_mod.unquote(value);
                    if (id.len > 0 and !@import("theme_pack.zig").validId(id)) return error.InvalidConfig;
                    cfg.theme_base = try cfg.arena.allocator().dupe(u8, id);
                    return;
                }
                theme_mod.applyKey(cfg.arena.allocator(), &cfg.theme, key, value) catch |err| {
                    fail(path, line_no, "invalid theme field '{s}': {s}", .{ key, @errorName(err) });
                    return error.InvalidConfig;
                };
                if (std.mem.eql(u8, key, "radius_lg")) state.seen_frame_radius = true;
            },
            .taskbar_theme => {
                // Other theme keys are ignored, so a whole theme file's body can be pasted in.
                _ = theme_mod.applyTaskbarKey(cfg.arena.allocator(), &cfg.taskbar_theme.?, key, value) catch |err| {
                    fail(path, line_no, "invalid taskbar_theme field '{s}': {s}", .{ key, @errorName(err) });
                    return error.InvalidConfig;
                };
            },
            .input_method => {
                if (!std.mem.eql(u8, key, "env")) return error.InvalidConfig;
                const text = theme_mod.unquote(value) catch return error.InvalidConfig;
                cfg.input_method.env = std.meta.stringToEnum(types.InputMethod, text) orelse return error.InvalidConfig;
            },
            .input => applyInputKey(&cfg.input, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid input field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .input_device => state.pointer_records.apply(cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid input_device field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .compositor => applyCompositorKey(&cfg.compositor, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid compositor field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .region => {
                const known = applyField(&cfg.region, cfg.arena.allocator(), region_rules, key, value) catch return error.InvalidConfig;
                if (!known) return error.InvalidConfig;
            },
            .autostart => {
                if (std.mem.eql(u8, key, "cmd")) {
                    const cmd = parseString(cfg.arena.allocator(), value) catch {
                        fail(path, line_no, "autostart cmd must be a quoted string", .{});
                        return error.InvalidConfig;
                    };
                    state.autostart_list.append(cfg.arena.allocator(), cmd) catch {
                        return error.OutOfMemory;
                    };
                }
            },
            .outputs => {
                state.have_current_output = true;
                const known = applyField(&state.current_output, cfg.arena.allocator(), output_rules, key, value) catch {
                    fail(path, line_no, "outputs {s} must be {s}", .{ key, fieldHint(OutputConfig, output_rules, key) });
                    return error.InvalidConfig;
                };
                if (!known) {
                    fail(path, line_no, "unknown outputs field '{s}'", .{key});
                    return error.InvalidConfig;
                }
            },
            .window_rules => {
                state.have_current_rule = true;
                window_rules.applyRuleKey(&state.current_rule, cfg.arena.allocator(), key, value) catch |err| {
                    fail(path, line_no, "invalid window_rules field '{s}': {s}", .{ key, @errorName(err) });
                    return error.InvalidConfig;
                };
            },
            .sandbox_allow => {
                state.have_current_sandbox_allow = true;
                sandbox_allow.applyKey(&state.current_sandbox_allow, cfg.arena.allocator(), key, value, path, line_no) catch |err| {
                    fail(path, line_no, "invalid sandbox_allow field '{s}': {s}", .{ key, @errorName(err) });
                    return error.InvalidConfig;
                };
            },
            .polkit => applyPolkitKey(&cfg.polkit, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid polkit field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .idle => applyIdleKey(&cfg.idle, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid idle field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .power => @import("power.zig").apply(&cfg.power, key, value) catch return error.InvalidConfig,
            .power_battery => @import("power.zig").applyProfile(&cfg.power.on_battery, key, value) catch return error.InvalidConfig,
            .power_plugged => @import("power.zig").applyProfile(&cfg.power.plugged_in, key, value) catch return error.InvalidConfig,
            .desktop => applyDesktopKey(&cfg.desktop, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid desktop field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .ipc => applyIpcKey(&cfg.ipc, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid ipc field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .night_light => applyNightLightKey(&cfg.night_light, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid night_light field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .keybinds, .workspace_keybinds => {
                const spec = keybinds.parseKeybind(key) catch {
                    fail(path, line_no, "invalid keybind '{s}'", .{key});
                    return error.InvalidConfig;
                };
                const action_str = theme_mod.unquote(value) catch {
                    fail(path, line_no, "keybind action must be a quoted string", .{});
                    return error.InvalidConfig;
                };
                const action = keybinds.parseAction(action_str, cfg.arena.allocator()) catch {
                    fail(path, line_no, "invalid action '{s}'", .{action_str});
                    return error.InvalidConfig;
                };
                const list = if (state.section == .workspace_keybinds) &state.workspace_binds else &state.bind_list;
                list.append(cfg.arena.allocator(), .{
                    .modifiers = spec.modifiers,
                    .sym = spec.sym,
                    .action = action,
                }) catch return error.OutOfMemory;
            },
            .notifications => applyNotificationsKey(&cfg.notifications, cfg.arena.allocator(), key, value) catch |err| {
                fail(path, line_no, "invalid notifications field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .notification_rules => {
                state.have_current_notif_rule = true;
                applyNotificationRuleKey(&state.current_notif_rule, cfg.arena.allocator(), key, value) catch |err| {
                    fail(path, line_no, "invalid notification_rules field '{s}': {s}", .{ key, @errorName(err) });
                    return error.InvalidConfig;
                };
            },
            .animations => anim_cfg.applyGlobalKey(&cfg.animations, key, value) catch |err| {
                fail(path, line_no, "invalid animations field '{s}': {s}", .{ key, @errorName(err) });
                return error.InvalidConfig;
            },
            .animation_target => |target| {
                anim_cfg.applyTargetKey(&cfg.animations, target, &state.target_flags[@backingInt(target)], key, value) catch |err| {
                    fail(path, line_no, "invalid animations.{s} field '{s}': {s}", .{ @tagName(target), key, @errorName(err) });
                    return error.InvalidConfig;
                };
            },
        }
    }

    fn finish(state: *ParseState, cfg: *Config, allocator: Allocator, path: []const u8, line_no: usize) !void {
        // Legacy frame geometry is a fallback; theme numbers take precedence,
        // including a REDIWM_THEME overlay applied after this parse.
        if (!state.seen_frame_radius) cfg.theme.radius_lg = @floatFromInt(cfg.compositor.border_radius);
        if (state.section == .input_device) try flushInputDevices(&state.pointer_records, cfg, path, line_no);
        cfg.input_devices = state.pointer_records.records.items;

        try flushArrayTables(cfg, path, line_no, state.section, &state.outputs_list, &state.current_output, &state.have_current_output, &state.rule_list, &state.current_rule, &state.have_current_rule, &state.notif_rule_list, &state.current_notif_rule, &state.have_current_notif_rule, &state.sandbox_allow_list, &state.current_sandbox_allow, &state.have_current_sandbox_allow);

        if (cfg.idle.blank_after_seconds > 0 and cfg.idle.suspend_after_seconds > 0 and cfg.idle.suspend_after_seconds <= cfg.idle.blank_after_seconds) {
            fail(path, line_no, "suspend_after_seconds must be greater than blank_after_seconds", .{});
            return error.InvalidConfig;
        }

        if (cfg.night_light.start == cfg.night_light.end) {
            fail(path, line_no, "night_light start cannot equal end", .{});
            return error.InvalidConfig;
        }

        const nl_night_span = @mod(@as(i32, cfg.night_light.end) - @as(i32, cfg.night_light.start) + 1440, 1440);
        const nl_day_span = 1440 - nl_night_span;
        if (cfg.night_light.transition_minutes >= nl_night_span or cfg.night_light.transition_minutes >= nl_day_span) {
            fail(path, line_no, "night_light transition_minutes must be shorter than both night and day spans", .{});
            return error.InvalidConfig;
        }

        if (cfg.night_light.schedule == .sun) {
            if (cfg.night_light.latitude == null or cfg.night_light.longitude == null) {
                fail(path, line_no, "night_light schedule 'sun' requires both latitude and longitude", .{});
                return error.InvalidConfig;
            }
        }

        if (state.seen_keybinds) {
            // Keep laptop controls, System Monitor, nested-session switching and
            // the way out of an inhibiting client available in existing configs too.
            // Explicit bindings (including noop) always take precedence.
            const defaults = try parseKeybindsOnly(cfg.arena.allocator(), default_file.source);
            for (defaults) |bind| {
                const nested_switcher = bind.modifiers.ctrl and (bind.action == .focus_next or bind.action == .focus_prev);
                if (!keybinds.isHardwareAction(bind.action) and !nested_switcher and bind.action != .restore_shortcuts and bind.action != .open_system_monitor) continue;
                const key = keybinds.pack(bind.modifiers, bind.sym);
                var overridden = false;
                for (state.bind_list.items) |custom| {
                    if (keybinds.pack(custom.modifiers, custom.sym) == key) {
                        overridden = true;
                        break;
                    }
                }
                if (!overridden) try state.bind_list.append(cfg.arena.allocator(), bind);
            }
            cfg.keybinds = state.bind_list.items;
        } else {
            try applyDefaultKeybinds(cfg);
        }
        try applyWorkspaceKeybinds(cfg, state.workspace_binds);
        cfg.autostart = state.autostart_list.items;
        cfg.outputs = state.outputs_list.items;
        var have_primary = false;
        for (cfg.outputs) |output| {
            if (!output.primary) continue;
            if (have_primary) {
                fail(path, line_no, "outputs may contain only one primary monitor", .{});
                return error.InvalidConfig;
            }
            have_primary = true;
        }
        cfg.window_rules = state.rule_list.items;
        cfg.notification_rules = state.notif_rule_list.items;
        cfg.sandbox_allow = state.sandbox_allow_list.items;
        try rebuildLookup(cfg);
        finishCompositor(cfg);
        // An explicit [animations.camera_desktop] table wins over the settings value.
        if (std.meta.eql(state.target_flags[@backingInt(anim.Target.camera_desktop)], anim_cfg.TargetFlags{})) {
            cfg.animations.targets[@backingInt(anim.Target.camera_desktop)].curve = anim.desktopSwitchCurve(cfg.compositor.desktop_switch_ms);
        }
        cfg.keyboard_keymap = @import("keymap.zig").compile(allocator, cfg.input) catch return error.InvalidConfig;
    }
};

pub fn parse(allocator: Allocator, bytes: []const u8, path: []const u8) !Config {
    var cfg = try initEmpty(allocator);
    errdefer cfg.deinit();
    cfg.path = try cfg.arena.allocator().dupe(u8, path);

    var state: ParseState = .{};
    var line_no: usize = 0;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = theme_mod.stripComment(std.mem.trim(u8, raw_line, " \t\r"));
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (state.section == .input_device) try flushInputDevices(&state.pointer_records, &cfg, path, line_no);
            try flushArrayTables(&cfg, path, line_no, state.section, &state.outputs_list, &state.current_output, &state.have_current_output, &state.rule_list, &state.current_rule, &state.have_current_rule, &state.notif_rule_list, &state.current_notif_rule, &state.have_current_notif_rule, &state.sandbox_allow_list, &state.current_sandbox_allow, &state.have_current_sandbox_allow);
            state.section = parseSection(line) catch |err| {
                if (err == error.UnknownAnimationTarget) {
                    const close = std.mem.indexOfScalar(u8, line, ']') orelse line.len;
                    const name = if (line.len > 1 and close > 1) line[1..close] else line;
                    const target = if (std.mem.startsWith(u8, name, "animations.")) name["animations.".len..] else name;
                    fail(path, line_no, "unknown animation target '{s}'", .{target});
                } else {
                    fail(path, line_no, "invalid section header", .{});
                }
                return error.InvalidConfig;
            };
            if (state.section == .keybinds) state.seen_keybinds = true;
            // Its presence alone chooses a taskbar theme, even with no keys.
            if (state.section == .taskbar_theme and cfg.taskbar_theme == null) cfg.taskbar_theme = .{};
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            fail(path, line_no, "expected key = value", .{});
            return error.InvalidConfig;
        };
        const key = unquoteKey(std.mem.trim(u8, line[0..eq], " \t"));
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        try state.apply(&cfg, path, line_no, key, value);
    }
    try state.finish(&cfg, allocator, path, line_no);
    return cfg;
}

fn flushInputDevices(parser: *input_device.Parser, cfg: *Config, path: []const u8, line_no: usize) !void {
    parser.flush(cfg.arena.allocator()) catch |err| {
        fail(path, line_no, "invalid input_device record: {s}", .{@errorName(err)});
        return error.InvalidConfig;
    };
}

pub const Section = union(enum) {
    none,
    theme,
    taskbar_theme,
    input,
    input_device,
    input_method,
    compositor,
    region,
    autostart,
    outputs,
    keybinds,
    workspace_keybinds,
    polkit,
    idle,
    power,
    power_battery,
    power_plugged,
    window_rules,
    sandbox_allow,
    night_light,
    notifications,
    notification_rules,
    desktop,
    ipc,
    animations,
    animation_target: anim.Target,
};

pub fn flushArrayTables(
    cfg: *Config,
    path: []const u8,
    line_no: usize,
    section: Section,
    outputs_list: *std.ArrayListUnmanaged(OutputConfig),
    current_output: *OutputConfig,
    have_current_output: *bool,
    rule_list: *std.ArrayListUnmanaged(WindowRule),
    current_rule: *WindowRule,
    have_current_rule: *bool,
    notif_rule_list: *std.ArrayListUnmanaged(NotificationRule),
    current_notif_rule: *NotificationRule,
    have_current_notif_rule: *bool,
    sandbox_allow_list: *std.ArrayListUnmanaged(SandboxAllowRule),
    current_sandbox_allow: *SandboxAllowRule,
    have_current_sandbox_allow: *bool,
) !void {
    if (section == .outputs and have_current_output.*) {
        if ((current_output.width == null) != (current_output.height == null) or
            (current_output.refresh_mhz != null and current_output.width == null)) return error.InvalidConfig;
        outputs_list.append(cfg.arena.allocator(), current_output.*) catch return error.OutOfMemory;
        current_output.* = .{};
        have_current_output.* = false;
    } else if (section == .window_rules and have_current_rule.*) {
        if (rule_list.items.len >= window_rules.max_rules) {
            fail(path, line_no, "too many window rules (max {d})", .{window_rules.max_rules});
            return error.InvalidConfig;
        }
        if (current_rule.hasMatchers() and !current_rule.hasProperties()) {
            log.warn("{s}:{d}: (warn): window rule has matchers but no properties", .{ path, line_no });
        }
        rule_list.append(cfg.arena.allocator(), current_rule.*) catch return error.OutOfMemory;
        current_rule.* = .{};
        have_current_rule.* = false;
    } else if (section == .notification_rules and have_current_notif_rule.*) {
        notif_rule_list.append(cfg.arena.allocator(), current_notif_rule.*) catch return error.OutOfMemory;
        current_notif_rule.* = .{};
        have_current_notif_rule.* = false;
    } else if (section == .sandbox_allow and have_current_sandbox_allow.*) {
        if (current_sandbox_allow.app_id.len == 0) {
            fail(path, line_no, "sandbox_allow requires app_id", .{});
            return error.InvalidConfig;
        }
        sandbox_allow_list.append(cfg.arena.allocator(), current_sandbox_allow.*) catch return error.OutOfMemory;
        current_sandbox_allow.* = .{};
        have_current_sandbox_allow.* = false;
    }
}

pub fn parseSection(line: []const u8) !Section {
    if (std.mem.startsWith(u8, line, "[[")) {
        inline for (.{ .autostart, .outputs, .window_rules, .notification_rules, .sandbox_allow, .input_device }) |tag| {
            if (std.mem.eql(u8, line, "[[" ++ @tagName(tag) ++ "]]")) return tag;
        }
        return error.InvalidConfig;
    }
    const close = std.mem.indexOfScalar(u8, line, ']') orelse return error.InvalidConfig;
    const name = line[1..close];
    if (std.mem.eql(u8, name, "input_device")) return error.InvalidConfig;
    if (std.mem.eql(u8, name, "keybinds.workspace")) return .workspace_keybinds;
    if (std.mem.eql(u8, name, "power.on_battery")) return .power_battery;
    if (std.mem.eql(u8, name, "power.plugged_in")) return .power_plugged;
    // Array tables and internal tags are deliberately not accepted here.
    inline for (.{ .theme, .taskbar_theme, .input, .input_method, .compositor, .region, .keybinds, .polkit, .idle, .power, .night_light, .notifications, .desktop, .ipc, .animations }) |tag| {
        if (std.mem.eql(u8, name, @tagName(tag))) return tag;
    }
    if (std.mem.startsWith(u8, name, "animations.")) {
        const rest = name["animations.".len..];
        return .{ .animation_target = anim.Target.parse(rest) orelse return error.UnknownAnimationTarget };
    }
    return .none;
}

pub fn initEmpty(allocator: Allocator) !Config {
    return .{
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
}

pub fn applyDefaultKeybinds(cfg: *Config) !void {
    const parsed = try parseKeybindsOnly(cfg.arena.allocator(), default_file.source);
    cfg.keybinds = parsed;
    try rebuildLookup(cfg);
}

pub fn parseKeybindsOnly(allocator: Allocator, bytes: []const u8) ![]Keybind {
    var list: std.ArrayListUnmanaged(Keybind) = .empty;
    var in_keybinds = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = theme_mod.stripComment(std.mem.trim(u8, raw_line, " \t\r"));
        if (line.len == 0) continue;
        if (line[0] == '[') {
            in_keybinds = std.mem.eql(u8, line, "[keybinds]");
            continue;
        }
        if (!in_keybinds) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = unquoteKey(std.mem.trim(u8, line[0..eq], " \t"));
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        const spec = try keybinds.parseKeybind(key);
        const action_str = try theme_mod.unquote(value);
        const action = try keybinds.parseAction(action_str, allocator);
        try list.append(allocator, .{
            .modifiers = spec.modifiers,
            .sym = spec.sym,
            .action = action,
        });
    }
    return list.items;
}

pub fn applyWorkspaceKeybinds(cfg: *Config, overrides: std.ArrayListUnmanaged(Keybind)) !void {
    const a = cfg.arena.allocator();
    var list = overrides;
    const defaults = try parseKeybindsOnly(a, @import("workspace_defaults.zig").source);
    const canvas = try parseKeybindsOnly(a, default_file.source);
    for ([_][]Keybind{ defaults, canvas }, 0..) |binds, source| for (binds) |bind| {
        if (source == 1 and !keybinds.isHardwareAction(bind.action) and bind.action != .restore_shortcuts) continue;
        const key = keybinds.pack(bind.modifiers, bind.sym);
        const overridden = for (list.items) |custom| {
            if (keybinds.pack(custom.modifiers, custom.sym) == key) break true;
        } else false;
        if (!overridden) try list.append(a, bind);
    };
    cfg.workspace_keybinds = list.items;
    cfg.workspace_lookup = .empty;
    for (list.items, 0..) |bind, i| try cfg.workspace_lookup.put(a, keybinds.pack(bind.modifiers, bind.sym), i);
}

pub fn rebuildLookup(cfg: *Config) !void {
    cfg.lookup = .empty;
    const a = cfg.arena.allocator();
    for (cfg.keybinds, 0..) |bind, i| {
        const packed_key = keybinds.pack(bind.modifiers, bind.sym);
        try cfg.lookup.put(a, packed_key, i);
    }
}

pub fn finishCompositor(cfg: *Config) void {
    const count = @min(cfg.compositor.zoom_step_count, max_zoom_steps);
    cfg.compositor.zoom_step_count = @max(1, count);
    var percents: [max_zoom_steps]u8 = undefined;
    var i: u8 = 0;
    while (i < cfg.compositor.zoom_step_count) : (i += 1) {
        const step = std.math.clamp(cfg.compositor.zoom_steps[i], 0.01, 4.0);
        percents[i] = @intFromFloat(@round(step * 100.0));
        if (percents[i] == 0) percents[i] = 1;
    }
    cfg.compositor.zoom_percents = cfg.arena.allocator().dupe(u8, percents[0..cfg.compositor.zoom_step_count]) catch {
        cfg.compositor.zoom_percents = &default_zoom_percents;
        cfg.compositor.zoom_step_count = 4;
        return;
    };
}

pub fn fail(path: []const u8, line: usize, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    log.warn("{s}:{d}: {s}", .{ path, line, msg });
}
