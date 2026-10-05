// Keybind and action parsers plus the press-time lookup table.
const std = @import("std");
const Allocator = std.mem.Allocator;
/// XKB modifier bits used by serialized key bindings.
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
const xkb = @import("xkbcommon");

const log = std.log.scoped(.config);

pub const Action = union(enum) {
    noop,
    volume_up,
    volume_down,
    volume_mute,
    mic_mute,
    brightness_up,
    brightness_down,
    power_profile_cycle,
    spawn: []const u8,
    close_window,
    toggle_fullscreen,
    toggle_maximize,
    /// Half/quarter-screen tiles, stepped per `snap.step`.
    tile_left,
    tile_right,
    tile_up,
    tile_down,
    toggle_start_menu,
    set_depth: u8,
    zoom_in,
    zoom_out,
    zoom_reset,
    camera_zoom_in,
    camera_zoom_out,
    camera_zoom_reset,
    pan_left,
    pan_right,
    pan_up,
    pan_down,
    focus_next,
    focus_prev,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    lock_screen,
    quit,
    poweroff,
    reboot,
    @"suspend",
    poweroff_auto,
    reboot_auto,
    suspend_auto,
    restart_shell,
    screenshot_region,
    screenshot_output,
    save_layout: []const u8,
    restore_layout: []const u8,
    undo,
    /// Takes bindings back from a client inhibiting shortcuts; otherwise
    /// the key reaches clients.
    restore_shortcuts,
};

/// Only these built-in device controls bypass menus and the session lock.
pub fn isHardwareAction(action: Action) bool {
    return switch (action) {
        .volume_up, .volume_down, .volume_mute, .mic_mute, .brightness_up, .brightness_down => true,
        else => false,
    };
}

pub fn repeats(action: Action) bool {
    return switch (action) {
        .volume_up, .volume_down, .brightness_up, .brightness_down => true,
        else => false,
    };
}

pub const Keybind = struct {
    modifiers: ModifierMask = .{},
    sym: xkb.Keysym,
    action: Action,
};

pub fn parseAction(str: []const u8, allocator: Allocator) !Action {
    const trimmed = std.mem.trim(u8, str, " \t\r");
    if (trimmed.len == 0) {
        log.warn("unknown action string: '{s}'", .{str});
        return error.UnknownAction;
    }
    const space = std.mem.indexOfScalar(u8, trimmed, ' ');
    const name = if (space) |i| trimmed[0..i] else trimmed;
    const arg = if (space) |i| std.mem.trim(u8, trimmed[i + 1 ..], " \t") else "";

    // Deprecated spelling: `force_shutdown` once wrote "poweroff" straight to
    // /sys/power/state. It now means the same normal, policy-respecting
    // poweroff as the `poweroff` action — never a bypass.
    if (std.mem.eql(u8, name, "force_shutdown")) {
        if (arg.len != 0) {
            log.warn("unknown action string: '{s}'", .{trimmed});
            return error.UnknownAction;
        }
        log.warn("'force_shutdown' is deprecated; use 'poweroff' instead", .{});
        return .poweroff;
    }

    inline for (std.meta.fields(Action)) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            return switch (field.type) {
                void => blk: {
                    if (arg.len != 0) {
                        log.warn("unknown action string: '{s}'", .{trimmed});
                        return error.UnknownAction;
                    }
                    break :blk @unionInit(Action, field.name, {});
                },
                []const u8 => blk: {
                    if (arg.len == 0) {
                        log.warn(field.name ++ " requires " ++ argumentHelp(field.name, "an argument"), .{});
                        return error.UnknownAction;
                    }
                    break :blk @unionInit(Action, field.name, try allocator.dupe(u8, arg));
                },
                u8 => blk: {
                    const n = std.fmt.parseInt(u8, arg, 10) catch {
                        log.warn(field.name ++ " requires " ++ argumentHelp(field.name, "an integer 0-255") ++ ", got '{s}'", .{arg});
                        return error.UnknownAction;
                    };
                    break :blk @unionInit(Action, field.name, n);
                },
                else => @compileError("no action parser for " ++ field.name ++ ": " ++ @typeName(field.type)),
            };
        }
    }

    log.warn("unknown action string: '{s}'", .{trimmed});
    return error.UnknownAction;
}

pub fn parseKeybind(key_str: []const u8) !struct { modifiers: ModifierMask, sym: xkb.Keysym } {
    const trimmed = std.mem.trim(u8, key_str, " \t\r");
    if (trimmed.len == 0) return error.InvalidKeybind;

    var mods: ModifierMask = .{};
    const last_plus = std.mem.lastIndexOfScalar(u8, trimmed, '+');
    const last = std.mem.trim(u8, if (last_plus) |i| trimmed[i + 1 ..] else trimmed, " \t");
    if (last.len == 0) return error.InvalidKeybind;

    if (last_plus) |end| {
        var it = std.mem.splitScalar(u8, trimmed[0..end], '+');
        while (it.next()) |raw| {
            const tok = std.mem.trim(u8, raw, " \t");
            if (tok.len == 0) return error.InvalidKeybind;
            if (eqlIgnoreCase(tok, "super") or eqlIgnoreCase(tok, "mod") or eqlIgnoreCase(tok, "logo")) {
                mods.logo = true;
            } else if (eqlIgnoreCase(tok, "ctrl") or eqlIgnoreCase(tok, "control")) {
                mods.ctrl = true;
            } else if (eqlIgnoreCase(tok, "alt")) {
                mods.alt = true;
            } else if (eqlIgnoreCase(tok, "shift")) {
                mods.shift = true;
            } else {
                log.warn("unknown modifier '{s}' in keybind '{s}'", .{ tok, key_str });
                return error.InvalidKeybind;
            }
        }
    }

    var name_buf: [64]u8 = undefined;
    if (last.len >= name_buf.len) return error.InvalidKeybind;
    @memcpy(name_buf[0..last.len], last);
    name_buf[last.len] = 0;
    const name_z: [:0]const u8 = name_buf[0..last.len :0];
    const sym = xkb.Keysym.fromName(name_z.ptr, .case_insensitive);
    if (sym == .NoSymbol) {
        log.warn("unknown key '{s}' in keybind '{s}'", .{ last, key_str });
        return error.InvalidKeybind;
    }
    return .{ .modifiers = mods, .sym = normalizeSym(sym) };
}

pub fn lookupKey(
    binds: []const Keybind,
    table: std.AutoHashMapUnmanaged(u64, usize),
    mods: anytype,
    sym: xkb.Keysym,
) ?Action {
    const key = pack(relevantMods(mods), normalizeSym(sym));
    if (table.get(key)) |idx| return binds[idx].action;
    return null;
}

pub fn pack(mods: anytype, sym: xkb.Keysym) u64 {
    const bits: u32 = @bitCast(ModifierMask{
        .shift = if (@hasField(@TypeOf(mods), "shift")) mods.shift else false,
        .ctrl = if (@hasField(@TypeOf(mods), "ctrl")) mods.ctrl else false,
        .alt = if (@hasField(@TypeOf(mods), "alt")) mods.alt else false,
        .logo = if (@hasField(@TypeOf(mods), "logo")) mods.logo else false,
    });
    return (@as(u64, bits) << 32) | @intFromEnum(sym);
}

pub fn relevantMods(mods: anytype) ModifierMask {
    return .{
        .shift = if (@hasField(@TypeOf(mods), "shift")) mods.shift else false,
        .ctrl = if (@hasField(@TypeOf(mods), "ctrl")) mods.ctrl else false,
        .alt = if (@hasField(@TypeOf(mods), "alt")) mods.alt else false,
        .logo = if (@hasField(@TypeOf(mods), "logo")) mods.logo else false,
    };
}

pub fn normalizeSym(sym: xkb.Keysym) xkb.Keysym {
    const lower = xkb.Keysym.toLower(sym);
    const raw = @intFromEnum(lower);
    if (raw == xkb.Keysym.plus) return @enumFromInt(xkb.Keysym.equal);
    if (raw == xkb.Keysym.underscore) return @enumFromInt(xkb.Keysym.minus);
    if (raw == xkb.Keysym.ISO_Left_Tab) return @enumFromInt(xkb.Keysym.Tab);
    if (raw == xkb.Keysym.Sys_Req) return @enumFromInt(xkb.Keysym.Print);
    return lower;
}

// Preserve the existing config diagnostics without duplicating the parser.
const argument_help = .{
    .spawn = "a command",
    .set_depth = "an integer 0-4",
    .save_layout = "a name",
    .restore_layout = "a name",
};

fn argumentHelp(comptime name: []const u8, comptime fallback: []const u8) []const u8 {
    return if (@hasField(@TypeOf(argument_help), name)) @field(argument_help, name) else fallback;
}

pub fn actionEql(a: Action, b: Action) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    inline for (std.meta.fields(Action)) |field| {
        if (std.meta.activeTag(a) == @field(std.meta.Tag(Action), field.name)) {
            return switch (field.type) {
                void => true,
                []const u8 => std.mem.eql(u8, @field(a, field.name), @field(b, field.name)),
                u8 => @field(a, field.name) == @field(b, field.name),
                else => @compileError("no action equality for " ++ field.name),
            };
        }
    }
    unreachable;
}

pub fn describeAction(action: Action, buf: []u8) []const u8 {
    inline for (std.meta.fields(Action)) |field| {
        if (std.meta.activeTag(action) == @field(std.meta.Tag(Action), field.name)) {
            return switch (field.type) {
                void => field.name,
                []const u8 => std.fmt.bufPrint(buf, field.name ++ " {s}", .{@field(action, field.name)}) catch field.name,
                u8 => std.fmt.bufPrint(buf, field.name ++ " {d}", .{@field(action, field.name)}) catch field.name,
                else => @compileError("no action description for " ++ field.name),
            };
        }
    }
    unreachable;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "force_shutdown is a deprecated alias for poweroff, not a separate action" {
    try std.testing.expectEqual(Action.poweroff, try parseAction("force_shutdown", std.testing.allocator));
    try std.testing.expectError(error.UnknownAction, parseAction("force_shutdown now", std.testing.allocator));
}

test "poweroff, reboot and suspend parse and round-trip through describeAction" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqual(Action.poweroff, try parseAction("poweroff", std.testing.allocator));
    try std.testing.expectEqual(Action.reboot, try parseAction("reboot", std.testing.allocator));
    try std.testing.expectEqual(Action.@"suspend", try parseAction("suspend", std.testing.allocator));
    try std.testing.expectEqual(Action.poweroff_auto, try parseAction("poweroff_auto", std.testing.allocator));
    try std.testing.expectEqual(Action.reboot_auto, try parseAction("reboot_auto", std.testing.allocator));
    try std.testing.expectEqual(Action.suspend_auto, try parseAction("suspend_auto", std.testing.allocator));
    try std.testing.expectEqualStrings("suspend", describeAction(.@"suspend", &buf));
    try std.testing.expectEqualStrings("poweroff_auto", describeAction(.poweroff_auto, &buf));
}

test "parseAction splits on first space" {
    const spawn = try parseAction("spawn foot -e htop", std.testing.allocator);
    defer std.testing.allocator.free(spawn.spawn);
    try std.testing.expectEqualStrings("foot -e htop", spawn.spawn);

    try std.testing.expectEqual(@as(u8, 2), (try parseAction("set_depth 2", std.testing.allocator)).set_depth);

    const save = try parseAction("save_layout home", std.testing.allocator);
    defer std.testing.allocator.free(save.save_layout);
    try std.testing.expectEqualStrings("home", save.save_layout);

    try std.testing.expectEqual(Action.close_window, try parseAction("close_window", std.testing.allocator));
    try std.testing.expectError(error.UnknownAction, parseAction("nope", std.testing.allocator));
    try std.testing.expectError(error.UnknownAction, parseAction("spawn", std.testing.allocator));
}

test "parseKeybind maps modifiers and is case insensitive" {
    const a = try parseKeybind("super+t");
    try std.testing.expect(a.modifiers.logo);
    try std.testing.expect(!a.modifiers.shift);
    try std.testing.expectEqual(@as(u32, xkb.Keysym.t), @intFromEnum(a.sym));

    const b = try parseKeybind("SUPER+SHIFT+S");
    try std.testing.expect(b.modifiers.logo and b.modifiers.shift);
    try std.testing.expectEqual(@as(u32, xkb.Keysym.s), @intFromEnum(b.sym));

    const c = try parseKeybind("alt+tab");
    try std.testing.expect(c.modifiers.alt);
    try std.testing.expectEqual(@as(u32, xkb.Keysym.Tab), @intFromEnum(c.sym));

    const d = try parseKeybind("ctrl+alt+delete");
    try std.testing.expect(d.modifiers.ctrl and d.modifiers.alt);
    try std.testing.expectEqual(@as(u32, xkb.Keysym.Delete), @intFromEnum(d.sym));

    const e = try parseKeybind("mod+F1");
    try std.testing.expect(e.modifiers.logo);
    try std.testing.expectEqual(@as(u32, xkb.Keysym.F1), @intFromEnum(e.sym));

    try std.testing.expectError(error.InvalidKeybind, parseKeybind("super+notakey"));
    try std.testing.expectError(error.InvalidKeybind, parseKeybind("hyper+t"));
}

test "every action round trips and compares its payload" {
    inline for (std.meta.fields(Action)) |field| {
        const original = @unionInit(Action, field.name, switch (field.type) {
            void => {},
            []const u8 => "example with spaces",
            u8 => 4,
            else => @compileError("add an action fixture for " ++ field.name),
        });
        var buf: [128]u8 = undefined;
        const parsed = try parseAction(describeAction(original, &buf), std.testing.allocator);
        defer if (field.type == []const u8) std.testing.allocator.free(@field(parsed, field.name));
        try std.testing.expect(actionEql(original, parsed));
        var short: [0]u8 = .{};
        try std.testing.expectEqualStrings(field.name, describeAction(original, &short));
        if (field.type != void) {
            const different = @unionInit(Action, field.name, if (field.type == u8) 3 else "different");
            try std.testing.expect(!actionEql(original, different));
            try std.testing.expectError(error.UnknownAction, parseAction(field.name, std.testing.allocator));
        } else {
            try std.testing.expectError(error.UnknownAction, parseAction(field.name ++ " extra", std.testing.allocator));
        }
    }
    try std.testing.expect(!actionEql(.close_window, .quit));
    // Depth clamping belongs to execution; parsing has always accepted all u8s.
    try std.testing.expectEqual(@as(u8, 255), (try parseAction("set_depth 255", std.testing.allocator)).set_depth);
    inline for (.{ "set_depth 256", "set_depth -1", "set_depth nope", "Close_window" }) |invalid| {
        try std.testing.expectError(error.UnknownAction, parseAction(invalid, std.testing.allocator));
    }
}
