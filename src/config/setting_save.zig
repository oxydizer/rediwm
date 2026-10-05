//! Update one [input] or [compositor] setting without replacing unrelated
//! settings or comments.
const std = @import("std");
const Io = std.Io;
const loader = @import("loader.zig");
const theme = @import("ui").theme;

pub fn saveInput(allocator: std.mem.Allocator, io: Io, path: []const u8, comptime key: []const u8, value: @FieldType(loader.InputConfig, key)) !void {
    try save(allocator, io, path, "input", key, value);
}

pub fn saveCompositor(allocator: std.mem.Allocator, io: Io, path: []const u8, comptime key: []const u8, value: @FieldType(loader.CompositorConfig, key)) !void {
    try save(allocator, io, path, "compositor", key, value);
}

pub fn saveRegion(allocator: std.mem.Allocator, io: Io, path: []const u8, comptime key: []const u8, value: @FieldType(loader.RegionConfig, key)) !void {
    try save(allocator, io, path, "region", key, value);
}

pub fn saveNightLight(allocator: std.mem.Allocator, io: Io, path: []const u8, comptime key: []const u8, value: @FieldType(loader.NightLightConfig, key)) !void {
    try save(allocator, io, path, "night_light", key, value);
}

pub fn saveNightLightConfig(allocator: std.mem.Allocator, io: Io, path: []const u8, cfg: loader.NightLightConfig) !void {
    const original = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(original);
    const enabled = try patch(allocator, original, "night_light", "enabled", cfg.enabled);
    defer allocator.free(enabled);
    const result = try patch(allocator, enabled, "night_light", "temperature", cfg.temperature);
    defer allocator.free(result);
    try writeValidated(allocator, io, path, result);
}

pub fn saveAccent(allocator: std.mem.Allocator, io: Io, path: []const u8, color: [4]f32) !void {
    var buf: [64]u8 = undefined;
    const value = try std.fmt.bufPrint(&buf, "rgba({d},{d},{d},{d:.6})", .{
        @as(u8, @intFromFloat(@round(color[0] * 255))),
        @as(u8, @intFromFloat(@round(color[1] * 255))),
        @as(u8, @intFromFloat(@round(color[2] * 255))),
        color[3],
    });
    try save(allocator, io, path, "theme", "accent", @as([]const u8, value));
}

pub fn saveAnimations(allocator: std.mem.Allocator, io: Io, path: []const u8, comptime key: []const u8, value: anytype) !void {
    try save(allocator, io, path, "animations", key, value);
}

fn save(allocator: std.mem.Allocator, io: Io, path: []const u8, comptime section: []const u8, comptime key: []const u8, value: anytype) !void {
    if (path.len == 0) return error.NoConfigPath;
    const original = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(original);
    var old = try loader.parse(allocator, original, path);
    defer old.deinit();
    const result = try patch(allocator, original, section, key, value);
    defer allocator.free(result);
    try writeValidated(allocator, io, path, result);
}

pub fn saveCanvas(allocator: std.mem.Allocator, io: Io, path: []const u8, columns: u32, rows: u32) !void {
    if (path.len == 0) return error.NoConfigPath;
    const original = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(original);
    var old = try loader.parse(allocator, original, path);
    defer old.deinit();
    const horizontal = try patch(allocator, original, "compositor", "canvas_columns", columns);
    defer allocator.free(horizontal);
    const result = try patch(allocator, horizontal, "compositor", "canvas_rows", rows);
    defer allocator.free(result);
    try writeValidated(allocator, io, path, result);
}

fn writeValidated(allocator: std.mem.Allocator, io: Io, path: []const u8, result: []const u8) !void {
    var checked = try loader.parse(allocator, result, path);
    defer checked.deinit();
    const stat = try Io.Dir.cwd().statFile(io, path, .{});
    const temporary = try std.fmt.allocPrint(allocator, "{s}.setting-save.tmp", .{path});
    defer allocator.free(temporary);
    const file = try Io.Dir.cwd().createFile(io, temporary, .{ .exclusive = true, .permissions = stat.permissions });
    defer file.close(io);
    defer Io.Dir.cwd().deleteFile(io, temporary) catch {};
    try file.writeStreamingAll(io, result);
    try file.sync(io);
    try Io.Dir.rename(.cwd(), temporary, .cwd(), path, io);
}

fn patch(allocator: std.mem.Allocator, original: []const u8, comptime section: []const u8, comptime key: []const u8, value: anytype) ![]u8 {
    const list_value = if (@TypeOf(value) == []const []const u8) try serializeStrings(allocator, value) else "";
    defer if (@TypeOf(value) == []const []const u8) allocator.free(list_value);
    const taskbar_value = if (@TypeOf(value) == loader.TaskbarItems) try value.serialize(allocator) else "";
    defer if (@TypeOf(value) == loader.TaskbarItems) allocator.free(taskbar_value);
    const field = if (@TypeOf(value) == []const []const u8)
        try std.fmt.allocPrint(allocator, key ++ " = {s}\n", .{list_value})
    else if (@TypeOf(value) == loader.TaskbarItems)
        try std.fmt.allocPrint(allocator, key ++ " = {s}\n", .{taskbar_value})
    else if (@TypeOf(value) == bool)
        try std.fmt.allocPrint(allocator, key ++ " = {}\n", .{value})
    else if (@typeInfo(@TypeOf(value)) == .@"enum")
        try std.fmt.allocPrint(allocator, key ++ " = \"{s}\"\n", .{@tagName(value)})
    else if (@TypeOf(value) == [2]f32)
        try std.fmt.allocPrint(allocator, key ++ " = [{d}, {d}]\n", .{ value[0], value[1] })
    else if (@TypeOf(value) == []const u8) blk: {
        // Plain names only: nothing that would need TOML escaping.
        if (std.mem.indexOfAny(u8, value, "\"\\\n\r") != null) return error.InvalidValue;
        break :blk try std.fmt.allocPrint(allocator, key ++ " = \"{s}\"\n", .{value});
    } else try std.fmt.allocPrint(allocator, key ++ " = {d}\n", .{value});
    defer allocator.free(field);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var in_section = false;
    var found_section = false;
    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, original, '\n');
    while (lines.next()) |raw| {
        const end = @min(original.len, offset + raw.len + 1);
        const line = theme.stripComment(std.mem.trim(u8, raw, " \t\r"));
        if (std.mem.startsWith(u8, line, "[")) {
            in_section = std.mem.eql(u8, line, "[" ++ section ++ "]");
            if (in_section) {
                found_section = true;
                try result.appendSlice(allocator, original[offset..end]);
                if (result.items[result.items.len - 1] != '\n') try result.append(allocator, '\n');
                try result.appendSlice(allocator, field);
                offset = end;
                continue;
            }
        }
        const eq = std.mem.indexOfScalar(u8, line, '=');
        const matches = in_section and if (eq) |i| std.mem.eql(u8, std.mem.trim(u8, line[0..i], " \t\""), key) else false;
        if (!matches) {
            try result.appendSlice(allocator, original[offset..end]);
        } else if (std.mem.indexOfScalar(u8, raw, '#')) |comment| {
            try result.appendSlice(allocator, raw[comment..]);
            try result.append(allocator, '\n');
        }
        offset = end;
    }
    if (!found_section) {
        try result.appendSlice(allocator, "\n[" ++ section ++ "]\n");
        try result.appendSlice(allocator, field);
    }
    return result.toOwnedSlice(allocator);
}

test "input changes survive parsing while preserving other settings and comments" {
    const a = std.testing.allocator;
    const original = "# user config\n[input]\n\"pointer_speed\" = -0.3 # mouse\ntap_drag = false\n[theme]\nfont = \"Example\"\n[[outputs]]\nname = \"HEADLESS-1\"\nscale = 1.5\n";
    const updated = try patch(a, original, "input", "pointer_speed", @as(f32, 0.7));
    defer a.free(updated);
    const repeated = try patch(a, updated, "input", "pointer_speed", @as(f32, 0.2));
    defer a.free(repeated);
    const touchpad = try patch(a, repeated, "input", "disable_while_typing_touchpad", false);
    defer a.free(touchpad);
    var cfg = try loader.parse(a, touchpad, "test");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(f32, 0.2), cfg.input.pointer_speed);
    try std.testing.expect(!cfg.input.disable_while_typing_touchpad);
    try std.testing.expect(!cfg.input.tap_drag);
    try std.testing.expectEqualStrings("Example", cfg.theme.font);
    try std.testing.expectEqual(@as(?f32, 1.5), cfg.outputs[0].scale);
    try std.testing.expect(std.mem.indexOf(u8, touchpad, "# mouse") != null);
}

test "input save handles missing sections and missing final newline" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "", "[input]", "[theme]\nfont = \"Example\"" }) |original| {
        const updated = try patch(a, original, "input", "key_repeat_delay", @as(u32, 650));
        defer a.free(updated);
        var cfg = try loader.parse(a, updated, "test");
        defer cfg.deinit();
        try std.testing.expectEqual(@as(u32, 650), cfg.input.key_repeat_delay);
    }
}

test "string settings save quoted and reject values needing escapes" {
    const a = std.testing.allocator;
    const result = try patch(a, "[input]\ncursor_theme = \"default\" # theme\n", "input", "cursor_theme", @as([]const u8, "phinger-cursors-light"));
    defer a.free(result);
    var parsed = try loader.parse(a, result, "test.toml");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("phinger-cursors-light", parsed.input.cursor_theme);
    try std.testing.expectError(error.InvalidValue, patch(a, "", "input", "cursor_theme", @as([]const u8, "bad\"name")));
}

test "touchpad speed persists independently of mouse speed" {
    const a = std.testing.allocator;
    const updated = try patch(a, "[input]\npointer_speed = 0.7\n", "input", "pointer_speed_touchpad", @as(f32, -0.6));
    defer a.free(updated);
    var cfg = try loader.parse(a, updated, "test");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(f32, 0.7), cfg.input.pointer_speed);
    try std.testing.expectEqual(@as(f32, -0.6), cfg.input.pointer_speed_touchpad);
}

test "compositor dark_mode saves beside other compositor keys and matching key names in other sections" {
    const a = std.testing.allocator;
    const original = "[input]\ntap_drag = false\n[compositor]\nwindow_gap = 12\ndark_mode = false # apps\n";
    const updated = try patch(a, original, "compositor", "dark_mode", true);
    defer a.free(updated);
    var cfg = try loader.parse(a, updated, "test");
    defer cfg.deinit();
    try std.testing.expect(cfg.compositor.dark_mode);
    try std.testing.expectEqual(@as(u32, 12), cfg.compositor.window_gap);
    try std.testing.expect(!cfg.input.tap_drag);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, updated, "dark_mode"));
    try std.testing.expect(std.mem.indexOf(u8, updated, "# apps") != null);

    for ([_][]const u8{ "", "[input]\nnatural_scroll = false" }) |bare| {
        const added = try patch(a, bare, "compositor", "dark_mode", true);
        defer a.free(added);
        var added_cfg = try loader.parse(a, added, "test");
        defer added_cfg.deinit();
        try std.testing.expect(added_cfg.compositor.dark_mode);
    }
}

test "global Xwayland factor persists without changing display scale or native policy" {
    const a = std.testing.allocator;
    const original = "[compositor]\nxwayland_native_scaling = true\nxwayland_scale = 0 # render density\n[[outputs]]\nname = \"DP-1\"\nscale = 1.5\n";
    for ([_]f64{ 0, 1, 1.1, 1.5, 1.9, 2, 3.7, 4 }) |factor| {
        const updated = try patch(a, original, "compositor", "xwayland_scale", factor);
        defer a.free(updated);
        var cfg = try loader.parse(a, updated, "test");
        defer cfg.deinit();
        try std.testing.expectEqual(factor, cfg.compositor.xwayland_scale);
        try std.testing.expect(cfg.compositor.xwayland_native_scaling);
        try std.testing.expectEqual(@as(?f32, 1.5), cfg.outputs[0].scale);
        try std.testing.expect(std.mem.indexOf(u8, updated, "# render density") != null);
    }
    for ([_][]const u8{ "-1", "5", "0.5", "nan", "inf" }) |invalid| {
        const config = try std.fmt.allocPrint(a, "[compositor]\nxwayland_scale = {s}\n", .{invalid});
        defer a.free(config);
        try std.testing.expectError(error.InvalidConfig, loader.parse(a, config, "invalid"));
    }
}

test "taskbar item order and visibility save without changing other settings" {
    const a = std.testing.allocator;
    const original = "[compositor]\nwindow_gap = 12 # keep\n";
    var items: loader.TaskbarItems = .{};
    items.move(3, false);
    items.visible[0] = false;
    const updated = try patch(a, original, "compositor", "taskbar_items", items);
    defer a.free(updated);
    var cfg = try loader.parse(a, updated, "test");
    defer cfg.deinit();
    try std.testing.expectEqualDeep(items, cfg.compositor.taskbar_items);
    try std.testing.expectEqual(@as(u32, 12), cfg.compositor.window_gap);
    try std.testing.expect(std.mem.indexOf(u8, updated, "# keep") != null);
}

test "animations settings save and preserve other settings" {
    const a = std.testing.allocator;
    const anim = @import("ui").anim;
    const original = "[compositor]\nwindow_gap = 8\n[animations]\nenabled = true\nspeed = 1.0\nreduced_motion = \"auto\"\n";
    const patched1 = try patch(a, original, "animations", "enabled", false);
    defer a.free(patched1);
    const patched2 = try patch(a, patched1, "animations", "speed", @as(f32, 1.5));
    defer a.free(patched2);
    const patched3 = try patch(a, patched2, "animations", "reduced_motion", anim.ReducedMotion.on);
    defer a.free(patched3);
    var cfg = try loader.parse(a, patched3, "test");
    defer cfg.deinit();
    try std.testing.expect(!cfg.animations.enabled);
    try std.testing.expectEqual(@as(f32, 1.5), cfg.animations.speed);
    try std.testing.expectEqual(anim.ReducedMotion.on, cfg.animations.reduced_motion);
    try std.testing.expectEqual(@as(u32, 8), cfg.compositor.window_gap);
}

test "window switching modes persist without replacing unrelated configuration" {
    const allocator = std.testing.allocator;
    const FocusZoom = @import("types.zig").FocusZoom;
    const original = "[compositor]\nfocus_zoom = \"boost\" # switching\nwindow_gap = 12\n[input]\npan_speed = 2\n";
    for ([_]FocusZoom{ .keep, .boost, .camera }) |mode| {
        const updated = try patch(allocator, original, "compositor", "focus_zoom", mode);
        defer allocator.free(updated);
        var cfg = try loader.parse(allocator, updated, "test");
        defer cfg.deinit();
        try std.testing.expectEqual(mode, cfg.compositor.focus_zoom);
        try std.testing.expectEqual(@as(u32, 12), cfg.compositor.window_gap);
        try std.testing.expect(std.mem.indexOf(u8, updated, "# switching") != null);
    }
    try std.testing.expectError(error.InvalidConfig, loader.parse(allocator, "[compositor]\nfocus_zoom = \"unknown\"\n", "test"));
}

fn serializeStrings(a: std.mem.Allocator, values: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.append(a, '[');
    for (values, 0..) |value, i| {
        if (i != 0) try out.appendSlice(a, ", ");
        try out.append(a, '"');
        for (value) |ch| switch (ch) {
            '"', '\\' => {
                try out.append(a, '\\');
                try out.append(a, ch);
            },
            0...31, 127 => return error.InvalidValue,
            else => try out.append(a, ch),
        };
        try out.append(a, '"');
    }
    try out.append(a, ']');
    return out.toOwnedSlice(a);
}

test "window tab app list saves escaped identities and preserves unrelated settings" {
    const a = std.testing.allocator;
    const apps: []const []const u8 = &.{ "kitty", "app\\path", "app\"name" };
    const updated = try patch(a, "# keep\n[compositor]\nfocus_follows_mouse = true\n", "compositor", "window_tab_apps", apps);
    defer a.free(updated);
    var cfg = try loader.parse(a, updated, "test");
    defer cfg.deinit();
    try std.testing.expect(cfg.compositor.focus_follows_mouse);
    try std.testing.expectEqual(@as(usize, 3), cfg.compositor.window_tab_apps.len);
    for (apps, cfg.compositor.window_tab_apps) |want, got| try std.testing.expectEqualStrings(want, got);
    const cleared = try patch(a, updated, "compositor", "window_tab_apps", @as([]const []const u8, &.{}));
    defer a.free(cleared);
    var empty = try loader.parse(a, cleared, "test");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.compositor.window_tab_apps.len);
}

test "region preferences preserve unrelated settings and reject invalid weekdays" {
    const a = std.testing.allocator;
    const original = "# keep\n[input]\ntap_drag = false\n[region]\nfirst_day_of_week = \"sunday\" # calendar\n";
    const day = try patch(a, original, "region", "first_day_of_week", @as(@FieldType(loader.RegionConfig, "first_day_of_week"), .monday));
    defer a.free(day);
    const result = try patch(a, day, "region", "clock_24h", true);
    defer a.free(result);
    var cfg = try loader.parse(a, result, "test");
    defer cfg.deinit();
    try std.testing.expect(cfg.region.clock_24h);
    try std.testing.expectEqual(.monday, cfg.region.first_day_of_week);
    try std.testing.expect(!cfg.input.tap_drag);
    try std.testing.expect(std.mem.indexOf(u8, result, "# calendar") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result, "first_day_of_week"));
    try std.testing.expectError(error.InvalidConfig, loader.parse(a, "[region]\nfirst_day_of_week = \"funday\"\n", "invalid"));
    try std.testing.expectError(error.InvalidConfig, loader.parse(a, "[region]\nclock_24h = \"yes\"\n", "invalid"));
}
