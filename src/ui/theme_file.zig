//! Theme files: locating, loading, parsing and overlaying them, applying keys, colour syntax and writing them back.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.theme);
const theme = @import("theme.zig");
const window_shape = @import("window_shape.zig");
const Theme = theme.Theme;
pub const Relief = theme.Relief;
const TaskbarToken = theme.TaskbarToken;

/// `REDIWM_THEME`, matching this project's existing env-var config
/// conventions (`REDIWM_SCALE`, `REDIWM_ICON_THEME` in icon_theme.zig).
/// Unset means "use the built-in defaults above", not an error.
pub fn resolvePath(environ: std.process.Environ) ?[]const u8 {
    return environ.getPosix("REDIWM_THEME");
}

/// Best-effort: logs and falls back to defaults on any failure (missing
/// file, malformed TOML) rather than failing compositor startup over a
/// theme file.
pub fn loadGlobal(allocator: Allocator, io: Io, path: []const u8) void {
    theme.global = load(allocator, io, path) catch |err| blk: {
        log.warn("loadGlobal: failed to load '{s}': {}, using defaults", .{ path, err });
        break :blk .{};
    };
}

pub fn load(allocator: Allocator, io: Io, path: []const u8) !Theme {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(bytes);
    return parse(allocator, bytes);
}

// Derive supported keys from Theme so a field cannot be exposed through IPC
// but silently omitted by TOML parsing or Appearance's save.
pub fn keysOf(comptime T: type) []const []const u8 {
    const keys = comptime blk: {
        var count: usize = 0;
        for (@typeInfo(Theme).@"struct".field_names) |field_name| if (@FieldType(Theme, field_name) == T) {
            count += 1;
        };
        var names: [count][]const u8 = undefined;
        var i: usize = 0;
        for (@typeInfo(Theme).@"struct".field_names) |field_name| {
            if (@FieldType(Theme, field_name) == T) {
                names[i] = field_name;
                i += 1;
            }
        }
        break :blk names;
    };
    return &keys;
}

pub const color_keys = keysOf([4]f32);

pub const number_keys = keysOf(f32);

pub const boolean_keys = keysOf(bool);

pub const optional_color_keys = keysOf(?[4]f32);

pub const string_keys = keysOf([]const u8);
pub const relief_keys = keysOf(Relief);

pub fn parseRelief(s: []const u8) ?Relief {
    return std.meta.stringToEnum(Relief, s);
}

/// Parses theme file bytes. String fields (`font`, `mono_font`) are duped
/// with `allocator` and, like `icon_theme.resolveConfig`'s paths, meant to
/// live for the process lifetime — pass a persistent allocator, not an
/// arena that gets torn down.
pub fn parse(allocator: Allocator, bytes: []const u8) !Theme {
    var t: Theme = .{};
    try overlay(allocator, &t, bytes);
    return t;
}

/// Applies `[theme]` keys from `bytes` onto an existing theme, leaving
/// unspecified fields untouched. Used to merge `REDIWM_THEME` over the
/// compositor config's `[theme]` section.
pub fn overlay(allocator: Allocator, t: *Theme, bytes: []const u8) !void {
    var in_theme_section = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = stripComment(std.mem.trim(u8, raw_line, " \t\r"));
        if (line.len == 0) continue;
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            in_theme_section = std.mem.eql(u8, line[1..close], "theme");
            continue;
        }
        if (!in_theme_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        try applyKey(allocator, t, key, value);
    }
}

/// Drops a `#` comment that is not inside a quoted string.
pub fn stripComment(line: []const u8) []const u8 {
    var in_string = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (ch == '"' and (i == 0 or line[i - 1] != '\\')) in_string = !in_string;
        if (ch == '#' and !in_string) return std.mem.trimEnd(u8, line[0..i], " \t");
    }
    return line;
}

pub fn applyKey(allocator: Allocator, t: *Theme, name_in: []const u8, value: []const u8) !void {
    @setEvalBranchQuota(10000);
    // The marker once lit hovers; saved looks may still use that name.
    const key = if (std.mem.eql(u8, name_in, "app_sidebar_hover_marker")) "app_sidebar_selected_marker" else name_in;
    inline for (boolean_keys) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(t, name) = if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else return error.InvalidBoolean;
            return;
        }
    }
    inline for (relief_keys) |name| {
        if (std.mem.eql(u8, key, name)) {
            const text = try unquote(value);
            @field(t, name) = parseRelief(text) orelse return error.InvalidRelief;
            return;
        }
    }
    inline for (string_keys) |name| {
        if (std.mem.eql(u8, key, name)) {
            const text = try unquote(value);
            if (comptime std.mem.eql(u8, name, "start_button_icon")) {
                if (text.len > 0 and !std.fs.path.isAbsolute(text)) return error.InvalidIconPath;
            }
            if (comptime std.mem.eql(u8, name, "window_shape") or std.mem.eql(u8, name, "taskbar_shape")) {
                _ = try window_shape.parse(text);
            }
            @field(t, name) = try allocator.dupe(u8, text);
            return;
        }
    }
    if (std.mem.eql(u8, key, "taskbar_height")) {
        const number = try std.fmt.parseFloat(f32, value);
        if (!std.math.isFinite(number) or number < 0 or number > 4096) return error.InvalidSize;
        t.taskbar_size = number;
        return;
    }
    inline for (number_keys) |name| {
        if (std.mem.eql(u8, key, name)) {
            const number = try std.fmt.parseFloat(f32, value);
            if (!std.math.isFinite(number) or number < 0 or number > 4096) return error.InvalidSize;
            if (comptime std.mem.eql(u8, name, "scrollbar_width")) {
                if (number < 4 or number > 24) return error.InvalidSize;
            }
            if (comptime std.mem.eql(u8, name, "chip_width")) {
                if (number < 64 or number > 400) return error.InvalidSize;
            }
            if (comptime std.mem.eql(u8, name, "chrome_height")) {
                if (number < 28 or number > 84) return error.InvalidSize;
            }
            if (comptime std.mem.eql(u8, name, "chrome_control_gap")) {
                if (number > 24) return error.InvalidSize;
            }
            if (comptime std.mem.eql(u8, name, "taskbar_length")) {
                if (number < 20 or number > 100) return error.InvalidSize;
            }
            if (comptime std.mem.eql(u8, name, "taskbar_outline_width")) {
                if (number > 8) return error.InvalidSize;
            }
            if (comptime std.mem.endsWith(u8, name, "_alpha") or std.mem.endsWith(u8, name, "_opacity") or std.mem.eql(u8, name, "dialog_glyph_lift")) {
                if (number > 1) return error.InvalidSize;
            }
            if (comptime std.mem.eql(u8, name, "image_checker_size")) {
                if (number < 1 or number > 128) return error.InvalidSize;
            }
            if (comptime std.mem.eql(u8, name, "scrollbar_rest_width") or std.mem.eql(u8, name, "scrollbar_active_width")) {
                if (number < 0.25 or number > 1.125) return error.InvalidSize;
            }
            @field(t, name) = number;
            return;
        }
    }
    inline for (optional_color_keys) |name| {
        if (std.mem.eql(u8, key, name)) {
            const text = try unquote(value);
            @field(t, name) = if (std.mem.eql(u8, text, "inherit")) null else try parseColor(text);
            return;
        }
    }
    inline for (color_keys) |name| {
        if (std.mem.eql(u8, key, name)) {
            @field(t, name) = try parseColor(try unquote(value));
            return;
        }
    }
    // Unknown key: ignore, so a newer theme file with extra tokens still
    // loads under an older build.
}

/// Serializes `t` back into this file's tiny TOML dialect, replacing the
/// whole `[theme]` section, and writes it to `path`. Round-trips every value
/// but reformats colors as `rgba(...)` regardless of how the file originally
/// spelled them — this reader has no comments or alternate spellings worth
/// preserving, just the values themselves. Values equal to the defaults are
/// left out, so changing a default reaches everyone who never changed that
/// key. Best-effort: logs
/// and returns without touching the file on any failure, matching
/// `loadGlobal`'s "never crash over a theme file" stance; does not update
/// `global` itself — call `loadGlobal` afterward to do that via the same
/// path malformed-file errors already take.
pub fn save(allocator: Allocator, io: Io, path: []const u8, t: Theme) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    writeInto(allocator, &buf, t) catch |err| {
        log.warn("save: failed to format '{s}': {}", .{ path, err });
        return;
    };
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items }) catch |err| {
        log.warn("save: failed to write '{s}': {}", .{ path, err });
    };
}

pub fn appendLine(allocator: Allocator, buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    var line: [160]u8 = undefined;
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&line, fmt, args));
}

/// A colour as written: 8-bit channels and alpha to three decimals.
pub fn quantize(c: [4]f32) [4]u32 {
    var q: [4]u32 = undefined;
    for (0..3) |i| q[i] = @intFromFloat(@round(std.math.clamp(c[i], 0, 1) * 255));
    q[3] = @intFromFloat(@round(std.math.clamp(c[3], 0, 1) * 1000));
    return q;
}

pub fn appendColor(allocator: Allocator, buf: *std.ArrayList(u8), key: []const u8, c: [4]f32) !void {
    const q = quantize(c);
    try appendLine(allocator, buf, "{s} = \"rgba({d},{d},{d},{d:.3})\"\n", .{ key, q[0], q[1], q[2], std.math.clamp(c[3], 0, 1) });
}

pub fn knownKey(key: []const u8) bool {
    inline for (@typeInfo(Theme).@"struct".field_names) |field_name| if (std.mem.eql(u8, key, field_name)) return true;
    return std.mem.eql(u8, key, "taskbar_height");
}

pub fn writeInto(allocator: Allocator, buf: *std.ArrayList(u8), t: Theme) !void {
    return writeOverrides(allocator, buf, t, .{}, "");
}

pub fn writeOverrides(allocator: Allocator, buf: *std.ArrayList(u8), t: Theme, defaults: Theme, base: []const u8) !void {
    return writeDiff(allocator, buf, t, defaults, base, base.len == 0);
}

pub fn saveOverlay(allocator: Allocator, io: Io, path: []const u8, t: Theme, below: Theme) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try writeDiff(allocator, &buf, t, below, "", false);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
}

pub fn writeDiff(allocator: Allocator, buf: *std.ArrayList(u8), t: Theme, defaults: Theme, base: []const u8, force_radius: bool) !void {
    try buf.appendSlice(allocator, "[theme]\n");
    if (base.len > 0) try appendLine(allocator, buf, "base = \"{s}\"\n", .{base});
    inline for (boolean_keys) |name| {
        if (@field(t, name) != @field(defaults, name)) try appendLine(allocator, buf, "{s} = {}\n", .{ name, @field(t, name) });
    }
    inline for (relief_keys) |name| {
        if (@field(t, name) != @field(defaults, name)) {
            try appendLine(allocator, buf, "{s} = \"{s}\"\n", .{ name, @tagName(@field(t, name)) });
        }
    }
    inline for (string_keys) |name| {
        if (!std.mem.eql(u8, @field(t, name), @field(defaults, name))) {
            try buf.appendSlice(allocator, name ++ " = \"");
            try buf.appendSlice(allocator, @field(t, name));
            try buf.appendSlice(allocator, "\"\n");
        }
    }
    inline for (number_keys) |name| {
        // Keep the frame radius explicit even at Default, so a legacy
        // compositor.border_radius cannot reappear after saving the theme.
        if (comptime std.mem.eql(u8, name, "radius_lg")) {
            if (force_radius) try appendLine(allocator, buf, "{s} = {d}\n", .{ name, @field(t, name) });
        }
        if ((!force_radius or !std.mem.eql(u8, name, "radius_lg")) and @field(t, name) != @field(defaults, name)) try appendLine(allocator, buf, "{s} = {d}\n", .{ name, @field(t, name) });
    }
    inline for (color_keys) |name| {
        if (!std.meta.eql(quantize(@field(t, name)), quantize(@field(defaults, name)))) try appendColor(allocator, buf, name, @field(t, name));
    }
    // Written only when set: an emitted value would pin these to the accent of
    // whichever palette happened to be current, turning "follow the accent"
    // into a fixed colour on the first save.
    inline for (optional_color_keys) |name| {
        const actual = @field(t, name);
        const original = @field(defaults, name);
        const equal = if (actual) |value| (if (original) |other| std.meta.eql(quantize(value), quantize(other)) else false) else original == null;
        if (!equal) {
            if (@field(t, name)) |color| try appendColor(allocator, buf, name, color) else try appendLine(allocator, buf, "{s} = \"inherit\"\n", .{name});
        }
    }
}

/// The `[taskbar_theme]` section for `t`'s taskbar tokens. Values equal to the
/// defaults are left out, as `writeInto` does: the section's presence, not its
/// keys, says a taskbar theme is chosen, and it reads back over the defaults.
pub fn writeTaskbarInto(allocator: Allocator, buf: *std.ArrayList(u8), t: Theme) !void {
    const defaults: Theme = .{};
    try buf.appendSlice(allocator, "[taskbar_theme]\n");
    inline for (@typeInfo(TaskbarToken).@"enum".field_names) |field_name| {
        const value = @field(t, field_name);
        if (comptime @TypeOf(value) == bool) {
            if (value != @field(defaults, field_name)) try appendLine(allocator, buf, "{s} = {}\n", .{ field_name, value });
        } else if (comptime @TypeOf(value) == ?[4]f32) {
            if (value) |color| try appendColor(allocator, buf, field_name, color);
        } else if (!std.meta.eql(quantize(value), quantize(@field(defaults, field_name)))) {
            try appendColor(allocator, buf, field_name, value);
        }
    }
}

pub fn unquote(v: []const u8) ![]const u8 {
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') return v[1 .. v.len - 1];
    return error.ExpectedQuotedString;
}

/// Accepts "#rrggbb", "#rrggbbaa", or "rgba(r,g,b,a)" (r/g/b 0-255, a 0-1)
/// and returns straight-alpha RGBA, matching every other `[4]f32` color in
/// this codebase (chrome.Color, Taskbar.Color).
pub fn parseColor(s: []const u8) ![4]f32 {
    if (s.len > 0 and s[0] == '#') return parseHex(s);
    if (std.mem.startsWith(u8, s, "rgba(")) return parseRgba(s);
    return error.InvalidColor;
}

pub fn parseHex(s: []const u8) ![4]f32 {
    if (s.len != 7 and s.len != 9) return error.InvalidColor;
    const r = try std.fmt.parseInt(u8, s[1..3], 16);
    const g = try std.fmt.parseInt(u8, s[3..5], 16);
    const b = try std.fmt.parseInt(u8, s[5..7], 16);
    const a: u8 = if (s.len == 9) try std.fmt.parseInt(u8, s[7..9], 16) else 255;
    return .{
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
        @as(f32, @floatFromInt(a)) / 255.0,
    };
}

pub fn parseRgba(s: []const u8) ![4]f32 {
    if (!std.mem.endsWith(u8, s, ")")) return error.InvalidColor;
    const inner = s["rgba(".len .. s.len - 1];
    var comps: [4]f32 = .{ 0, 0, 0, 1 };
    var it = std.mem.splitScalar(u8, inner, ',');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidColor;
        const v = try std.fmt.parseFloat(f32, std.mem.trim(u8, part, " \t"));
        if (!std.math.isFinite(v) or v < 0 or v > (if (i < 3) @as(f32, 255) else 1)) return error.InvalidColor;
        comps[i] = if (i < 3) v / 255.0 else v;
    }
    if (i < 3) return error.InvalidColor;
    return comps;
}
