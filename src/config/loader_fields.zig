//! Config field rules: the per-section rule tables and the value parsers behind them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const theme_mod = @import("ui").theme;
const types = @import("types.zig");
const window_rules = @import("window_rules.zig");
const output_transform = @import("output_transform.zig");
const schedule_mod = @import("schedule.zig");
const NightLightConfig = schedule_mod.NightLightConfig;
const AccelProfile = types.AccelProfile;
const max_zoom_steps = @import("loader.zig").max_zoom_steps;
const drag_scale_min = @import("loader.zig").drag_scale_min;
const drag_scale_max = @import("loader.zig").drag_scale_max;
const InputConfig = @import("loader.zig").InputConfig;
const RegionConfig = @import("loader.zig").RegionConfig;
const TaskbarItems = @import("loader.zig").TaskbarItems;
const dock_height_min = @import("loader.zig").dock_height_min;
const dock_height_max = @import("loader.zig").dock_height_max;
const dock_hover_zoom_max = @import("loader.zig").dock_hover_zoom_max;
const CompositorConfig = @import("loader.zig").CompositorConfig;
const OutputConfig = @import("loader.zig").OutputConfig;
const PolkitConfig = @import("loader.zig").PolkitConfig;
const IdleConfig = @import("loader.zig").IdleConfig;
const NotificationsConfig = @import("loader.zig").NotificationsConfig;
const DesktopConfig = @import("loader.zig").DesktopConfig;
const IpcConfig = @import("loader.zig").IpcConfig;
const NotificationRule = @import("loader.zig").NotificationRule;

pub const FieldRule = union(enum) {
    taskbar_items,
    boolean,
    string,
    string_list,
    json_string_list,
    uint: struct { min: u32, max: u32 },
    int: struct { min: i32 = std.math.minInt(i32), max: i32 = std.math.maxInt(i32) },
    float: struct { min: f32, max: f32, exclusive_min: bool = false },
    output_scale,
    output_transform,
    zoom_steps,
    accel_profile,
    accel_point,
    /// A bare or quoted enum tag name.
    enumeration,
    derived,
};

// EnumFieldStruct requires a rule for every field, including derived fields
// that must never become independently configurable.
pub const input_rules: std.enums.EnumFieldStruct(std.meta.FieldEnum(InputConfig), FieldRule, null) = .{
    .xkb_layout = .string,
    .xkb_variant = .string,
    .xkb_options = .string,
    .xkb_model = .string,
    .natural_scroll = .boolean,
    .invert_scroll = .boolean,
    .pointer_speed = .{ .float = .{ .min = -1, .max = 1 } },
    .pointer_speed_touchpad = .{ .float = .{ .min = -1, .max = 1 } },
    .accel_profile = .accel_profile,
    .accel_p1 = .accel_point,
    .accel_p2 = .accel_point,
    .accel_max_speed = .{ .float = .{ .min = 0.0, .max = 10_000.0, .exclusive_min = true } },
    .pan_speed = .{ .float = .{ .min = 1.0, .max = 4.0 } },
    .pan_modifier = .enumeration,
    .middle_button_pan = .boolean,
    .wheel_acceleration = .{ .float = .{ .min = 0.0, .max = 4.0 } },
    .wheel_acceleration_max = .{ .float = .{ .min = 1.0, .max = 20.0 } },
    .wheel_acceleration_exclude = .string_list,
    .smooth_scroll = .boolean,
    .smooth_scroll_exclude = .string_list,
    .wheel_debounce_ms = .{ .uint = .{ .min = 0, .max = 200 } },
    .left_handed = .boolean,
    .tap_to_click = .boolean,
    .tap_drag = .boolean,
    .disable_while_typing = .boolean,
    .disable_while_typing_touchpad = .boolean,
    .key_repeat_delay = .{ .uint = .{ .min = 1, .max = 5000 } },
    .key_repeat_rate = .{ .uint = .{ .min = 1, .max = 200 } },
    .cursor_theme = .string,
    .cursor_size = .{ .uint = .{ .min = 1, .max = 256 } },
    // 0 is meaningful for all three (blink off / never time out / no glide),
    // so these ranges start there rather than at 1.
    .caret_blink_ms = .{ .uint = .{ .min = 0, .max = 10_000 } },
    .caret_blink_timeout = .{ .uint = .{ .min = 0, .max = 3600 } },
    .caret_motion_ms = .{ .uint = .{ .min = 0, .max = 2000 } },
};

pub const region_rules: std.enums.EnumFieldStruct(std.meta.FieldEnum(RegionConfig), FieldRule, null) = .{
    .timezone = .string,
    .language = .string,
    .formats = .string,
    .clock_24h = .boolean,
    .clock_show_seconds = .boolean,
    .clock_show_day = .boolean,
    .first_day_of_week = .enumeration,
};

pub const compositor_rules: std.enums.EnumFieldStruct(std.meta.FieldEnum(CompositorConfig), FieldRule, null) = .{
    .desktop_mode = .enumeration,
    .floating_apps = .json_string_list,
    .dock_enabled = .boolean,
    .dock_position = .enumeration,
    .dock_height = .{ .uint = .{ .min = dock_height_min, .max = dock_height_max } },
    .dock_hover_zoom = .{ .float = .{ .min = 1, .max = dock_hover_zoom_max } },
    .dock_auto_hide = .boolean,
    .dock_opacity = .{ .float = .{ .min = 0, .max = 1 } },
    .dock_active_highlight = .boolean,
    .dock_show_trash = .boolean,
    .dock_hidden_shortcuts = .json_string_list,
    .dock_pinned_apps = .json_string_list,
    .taskbar_items = .taskbar_items,
    .taskbar_position = .enumeration,
    .taskbar_alignment = .enumeration,
    .icon_theme = .string,
    .window_tab_apps = .json_string_list,
    .default_file_manager = .string,
    .default_terminal = .string,
    .focus_follows_mouse = .boolean,
    .canvas_columns = .{ .uint = .{ .min = 1, .max = 10 } },
    .canvas_rows = .{ .uint = .{ .min = 1, .max = 10 } },
    .desktop_switch_ms = .{ .uint = .{ .min = 100, .max = 3000 } },
    .desktop_icons_fixed = .boolean,
    .mini_map_enabled = .boolean,
    .mini_map_position = .enumeration,
    .mini_map_hide_ms = .{ .uint = .{ .min = 500, .max = 10000 } },
    .canvas_width = .{ .uint = .{ .min = 1, .max = 100_000 } },
    .canvas_height = .{ .uint = .{ .min = 1, .max = 100_000 } },
    .zoom_steps = .zoom_steps,
    .zoom_step_count = .derived,
    .zoom_percents = .derived,
    .camera_zoom_min = .{ .float = .{ .min = 0, .max = 8, .exclusive_min = true } },
    .camera_zoom_max = .{ .float = .{ .min = 0, .max = 8, .exclusive_min = true } },
    .focus_zoom = .enumeration,
    .window_gap = .{ .uint = .{ .min = 0, .max = 512 } },
    .snap_to_edges = .boolean,
    .drag_feedback = .boolean,
    .drag_scale = .{ .float = .{ .min = drag_scale_min, .max = drag_scale_max } },
    .dodge_file_drags = .boolean,
    .files_single_click_open = .boolean,
    .inactive_opacity = .{ .float = .{ .min = 0, .max = 1 } },
    .terminal_opacity = .{ .float = .{ .min = 0, .max = 1 } },
    .inactive_dim = .boolean,
    .inactive_dim_amount = .{ .float = .{ .min = 0, .max = 0.5 } },
    .switcher_opacity = .{ .float = .{ .min = 0, .max = 1 } },
    .border_radius = .{ .uint = .{ .min = 0, .max = 128 } },
    .allow_tearing = .boolean,
    .xwayland = .boolean,
    .xwayland_native_scaling = .boolean,
    .xwayland_scale = .{ .float = .{ .min = 0, .max = 4 } },
    .dark_mode = .boolean,
    .placeholder_delay_ms = .{ .uint = .{ .min = 0, .max = 10_000 } },
    .wallpaper = .string,
    .sound_theme = .string,
    .sound_enabled = .boolean,
    .sound_disabled_events = .json_string_list,
    .lid_close = .enumeration,
    .lock_on_suspend = .boolean,
};

pub const idle_rules: std.enums.EnumFieldStruct(std.meta.FieldEnum(IdleConfig), FieldRule, null) = .{
    .enabled = .boolean,
    .blank_after_seconds = .{ .uint = .{ .min = 0, .max = std.math.maxInt(u32) } },
    .suspend_after_seconds = .{ .uint = .{ .min = 0, .max = std.math.maxInt(u32) } },
};

pub const desktop_rules: std.enums.EnumFieldStruct(std.meta.FieldEnum(DesktopConfig), FieldRule, null) = .{
    .enabled = .boolean,
};

pub const ipc_rules: std.enums.EnumFieldStruct(std.meta.FieldEnum(IpcConfig), FieldRule, null) = .{
    .automation = .boolean,
};

pub const output_rules: std.enums.EnumFieldStruct(std.meta.FieldEnum(OutputConfig), FieldRule, null) = .{
    .width = .{ .int = .{ .min = 1 } },
    .height = .{ .int = .{ .min = 1 } },
    .refresh_mhz = .{ .int = .{ .min = 1 } },
    .name = .string,
    .x = .{ .int = .{} },
    .y = .{ .int = .{} },
    .scale = .output_scale,
    .enabled = .boolean,
    .primary = .boolean,
    .transform = .output_transform,
    .night_light = .boolean,
    .gamma = .{ .float = .{ .min = 0.5, .max = 2.0 } },
};

/// Describes the values `rule` accepts, for "<field> must be ..." errors.
pub fn ruleHint(comptime rule: FieldRule) []const u8 {
    return switch (rule) {
        .boolean => "a boolean",
        .string => "a quoted string",
        .string_list => "a quoted string or an array of them",
        .json_string_list => "an array of quoted app IDs",
        .uint => |r| std.fmt.comptimePrint("an integer between {d} and {d}", .{ r.min, r.max }),
        .int => |r| if (r.min == 1 and r.max == std.math.maxInt(i32))
            "a positive integer"
        else if (r.min == std.math.minInt(i32) and r.max == std.math.maxInt(i32))
            "an integer"
        else
            std.fmt.comptimePrint("an integer between {d} and {d}", .{ r.min, r.max }),
        .float => |r| std.fmt.comptimePrint("a number between {d} and {d}", .{ r.min, r.max }),
        .output_scale => "a number between 1 and 3, or quoted auto",
        .output_transform => "normal, 90, 180, 270, flipped, flipped_90, flipped_180, or flipped_270",
        .enumeration => "a documented name",
        .taskbar_items, .zoom_steps, .accel_profile, .accel_point, .derived => "valid",
    };
}

pub fn enumHint(comptime T: type) []const u8 {
    const names = std.meta.fieldNames(T);
    var hint: []const u8 = "";
    for (names, 0..) |name, i| {
        const separator = if (i == 0) "" else if (i + 1 == names.len) " or " else ", ";
        hint = hint ++ separator ++ "\"" ++ name ++ "\"";
    }
    return hint;
}

pub fn fieldHint(comptime T: type, comptime rules: anytype, key: []const u8) []const u8 {
    inline for (@typeInfo(T).@"struct".field_names) |field_name| {
        if (std.mem.eql(u8, key, field_name)) {
            if (comptime @field(rules, field_name) == .enumeration) return comptime enumHint(@FieldType(T, field_name));
            return comptime ruleHint(@field(rules, field_name));
        }
    }
    return "valid";
}

pub fn applyField(target: anytype, allocator: Allocator, comptime rules: anytype, key: []const u8, value: []const u8) !bool {
    inline for (@typeInfo(@TypeOf(target.*)).@"struct".field_names) |field_name| {
        const rule = comptime @field(rules, field_name);
        if (rule != .derived and std.mem.eql(u8, key, field_name)) {
            switch (comptime rule) {
                .taskbar_items => @field(target, field_name) = try TaskbarItems.parse(value),
                .boolean => @field(target, field_name) = try parseBool(value),
                .string => @field(target, field_name) = try parseString(allocator, value),
                .string_list => @field(target, field_name) = try window_rules.parseStringOrArray(allocator, value),
                .json_string_list => @field(target, field_name) = try std.json.parseFromSliceLeaky([]const []const u8, allocator, value, .{ .allocate = .alloc_always }),
                .uint => |range| @field(target, field_name) = try parseU32Range(value, range.min, range.max),
                .int => |range| @field(target, field_name) = try parseI32Range(value, range.min, range.max),
                .output_scale => @field(target, field_name) = try parseOutputScale(value),
                .output_transform => @field(target, field_name) = try output_transform.parse(value),
                .float => |range| {
                    const Float = if (@typeInfo(@FieldType(@TypeOf(target.*), field_name)) == .optional) @typeInfo(@FieldType(@TypeOf(target.*), field_name)).optional.child else @FieldType(@TypeOf(target.*), field_name);
                    const v = try std.fmt.parseFloat(Float, value);
                    if (!std.math.isFinite(v) or v < range.min or v > range.max or
                        (range.exclusive_min and v == range.min)) return error.InvalidValue;
                    @field(target, field_name) = v;
                },
                .zoom_steps => try parseZoomSteps(target, value),
                .accel_profile => @field(target, field_name) = try parseAccelProfile(value),
                .accel_point => @field(target, field_name) = try parseVec2(value),
                .enumeration => @field(target, field_name) = try parseEnum(@FieldType(@TypeOf(target.*), field_name), value),
                .derived => unreachable,
            }
            return true;
        }
    }
    return false;
}

pub fn applyInputKey(input: *InputConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    _ = try applyField(input, allocator, input_rules, key, value);
}

pub fn applyCompositorKey(c: *CompositorConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    _ = try applyField(c, allocator, compositor_rules, key, value);
    if (c.xwayland_scale > 0 and c.xwayland_scale < 1) return error.InvalidValue;
}

pub fn applyPolkitKey(config: *PolkitConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "enable")) {
        config.enable = try parseBool(value);
    } else if (std.mem.eql(u8, key, "helper_socket")) {
        const path = try parseString(allocator, value);
        if (path.len == 0 or path.len >= 108 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidValue;
        config.helper_socket = path;
    } else return error.InvalidField;
}

pub fn applyIdleKey(idle: *IdleConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    // Idle retains its stricter unknown-key policy.
    if (!try applyField(idle, allocator, idle_rules, key, value)) return error.InvalidField;
}

pub fn applyDesktopKey(desktop: *DesktopConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    if (!try applyField(desktop, allocator, desktop_rules, key, value)) return error.InvalidField;
}

pub fn applyIpcKey(ipc: *IpcConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    if (!try applyField(ipc, allocator, ipc_rules, key, value)) return error.InvalidField;
}

pub fn applyNightLightKey(nl: *NightLightConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "enabled")) {
        nl.enabled = try parseBool(value);
    } else if (std.mem.eql(u8, key, "schedule")) {
        const str = try parseString(allocator, value);
        if (std.mem.eql(u8, str, "fixed")) {
            nl.schedule = .fixed;
        } else if (std.mem.eql(u8, str, "sun")) {
            nl.schedule = .sun;
        } else if (std.mem.eql(u8, str, "always")) {
            nl.schedule = .always;
        } else {
            return error.InvalidValue;
        }
    } else if (std.mem.eql(u8, key, "temperature")) {
        nl.temperature = @intCast(try parseU32Range(value, 1700, 10000));
    } else if (std.mem.eql(u8, key, "day_temperature")) {
        nl.day_temperature = @intCast(try parseU32Range(value, 1700, 10000));
    } else if (std.mem.eql(u8, key, "start")) {
        const str = try parseString(allocator, value);
        nl.start = try schedule_mod.parseClock(str);
    } else if (std.mem.eql(u8, key, "end")) {
        const str = try parseString(allocator, value);
        nl.end = try schedule_mod.parseClock(str);
    } else if (std.mem.eql(u8, key, "transition_minutes")) {
        nl.transition_minutes = @intCast(try parseU32Range(value, 0, 180));
    } else if (std.mem.eql(u8, key, "latitude")) {
        const lat = try std.fmt.parseFloat(f64, value);
        if (!std.math.isFinite(lat) or lat < -90.0 or lat > 90.0) return error.InvalidValue;
        nl.latitude = lat;
    } else if (std.mem.eql(u8, key, "longitude")) {
        const lon = try std.fmt.parseFloat(f64, value);
        if (!std.math.isFinite(lon) or lon < -180.0 or lon > 180.0) return error.InvalidValue;
        nl.longitude = lon;
    } else {
        return error.InvalidField;
    }
}

pub fn applyNotificationsKey(n: *NotificationsConfig, allocator: Allocator, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "daemon")) {
        n.daemon = try parseString(allocator, value);
    } else if (std.mem.eql(u8, key, "dnd")) {
        n.dnd = try parseBool(value);
    } else if (std.mem.eql(u8, key, "default_timeout_ms")) {
        n.default_timeout_ms = try parseU32Range(value, 0, std.math.maxInt(u32));
    } else {
        return error.InvalidField;
    }
}

pub fn applyNotificationRuleKey(rule: *NotificationRule, allocator: Allocator, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "app_name") or std.mem.eql(u8, key, "app_id")) {
        rule.app_name = try window_rules.parseStringOrArray(allocator, value);
    } else if (std.mem.eql(u8, key, "desktop_entry")) {
        rule.desktop_entry = try window_rules.parseStringOrArray(allocator, value);
    } else if (std.mem.eql(u8, key, "mute")) {
        rule.mute = try parseBool(value);
    } else if (std.mem.eql(u8, key, "urgency")) {
        const u = try parseU32Range(value, 0, 2);
        rule.urgency = @intCast(u);
    } else if (std.mem.eql(u8, key, "dnd_bypass")) {
        rule.dnd_bypass = try parseBool(value);
    } else {
        return error.InvalidField;
    }
}

pub fn parseZoomSteps(c: *CompositorConfig, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return error.InvalidValue;
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    var count: u8 = 0;
    if (inner.len > 0) {
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |part| {
            if (count >= max_zoom_steps) return error.InvalidValue;
            const n = try std.fmt.parseFloat(f32, std.mem.trim(u8, part, " \t"));
            if (!std.math.isFinite(n) or n <= 0 or n > 8) return error.InvalidValue;
            c.zoom_steps[count] = n;
            count += 1;
        }
    }
    if (count == 0) return error.InvalidValue;
    c.zoom_step_count = count;
}

pub fn parseEnum(comptime T: type, value: []const u8) !T {
    const trimmed = std.mem.trim(u8, value, " \t");
    const s = if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"')
        trimmed[1 .. trimmed.len - 1]
    else
        trimmed;
    return std.meta.stringToEnum(T, s) orelse error.InvalidValue;
}

pub fn parseAccelProfile(value: []const u8) !AccelProfile {
    const trimmed = std.mem.trim(u8, value, " \t");
    const s = if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"')
        trimmed[1 .. trimmed.len - 1]
    else
        trimmed;
    if (std.mem.eql(u8, s, "bezier")) return .bezier;
    if (std.mem.eql(u8, s, "flat")) return .flat;
    return error.InvalidValue;
}

pub fn parseVec2(value: []const u8) ![2]f32 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return error.InvalidValue;
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    var it = std.mem.splitScalar(u8, inner, ',');
    const part0 = it.next() orelse return error.InvalidValue;
    const part1 = it.next() orelse return error.InvalidValue;
    if (it.next() != null) return error.InvalidValue;
    const x = std.fmt.parseFloat(f32, std.mem.trim(u8, part0, " \t")) catch return error.InvalidValue;
    const y = std.fmt.parseFloat(f32, std.mem.trim(u8, part1, " \t")) catch return error.InvalidValue;
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.InvalidValue;
    if (x < 0.0 or x > 1.0) return error.InvalidValue;
    if (y < 0.0 or y > 100.0) return error.InvalidValue;
    return .{ x, y };
}

pub fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidValue;
}

pub fn parseU32Range(value: []const u8, min: u32, max: u32) !u32 {
    const n = try std.fmt.parseInt(u32, value, 10);
    if (n < min or n > max) return error.InvalidValue;
    return n;
}

pub fn parseI32Range(value: []const u8, min: i32, max: i32) !i32 {
    const n = try std.fmt.parseInt(i32, value, 10);
    if (n < min or n > max) return error.InvalidValue;
    return n;
}

/// A scale of 1-3 snapped to the 1/120 steps of wp_fractional_scale, or
/// quoted "auto" (null) for automatic density detection.
pub fn parseOutputScale(value: []const u8) !?f32 {
    if (std.mem.eql(u8, value, "\"auto\"")) return null;
    const scale = try std.fmt.parseFloat(f32, value);
    if (!std.math.isFinite(scale) or scale < 1 or scale > 3) return error.InvalidValue;
    return @round(scale * 120) / 120;
}

pub fn parseString(allocator: Allocator, value: []const u8) ![]const u8 {
    return allocator.dupe(u8, try theme_mod.unquote(value));
}

pub fn unquoteKey(key: []const u8) []const u8 {
    if (key.len >= 2 and key[0] == '"' and key[key.len - 1] == '"') return key[1 .. key.len - 1];
    return key;
}
