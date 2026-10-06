//! Follow the compositor's persisted theme without blocking the UI thread.
//! Stat once per second; read only after changes, including atomic replacement.
//! Shared by the Files, Images and PDF clients.
const std = @import("std");
const c = @import("c.zig").api;
const anim = @import("ui").anim;
const anim_config = @import("config").animations;
const theme = @import("ui").theme;
const text = @import("ui").text;
const config = @import("config").loader;

/// Owns the string tokens while a theme travels from the worker to the UI.
pub const ThemeUpdate = struct {
    value: theme.Theme,
    allocator: std.mem.Allocator,
    region: config.RegionConfig = .{},

    fn init(a: std.mem.Allocator, t: theme.Theme, prefs: config.RegionConfig) !ThemeUpdate {
        var value = t;
        value.font = try a.dupe(u8, t.font);
        errdefer a.free(value.font);
        value.mono_font = try a.dupe(u8, t.mono_font);
        errdefer a.free(value.mono_font);
        value.start_button_icon = try a.dupe(u8, t.start_button_icon);
        errdefer a.free(value.start_button_icon);
        var owned = prefs;
        owned.timezone = try a.dupe(u8, prefs.timezone);
        errdefer a.free(owned.timezone);
        owned.language = try a.dupe(u8, prefs.language);
        errdefer a.free(owned.language);
        owned.formats = try a.dupe(u8, prefs.formats);
        return .{ .value = value, .allocator = a, .region = owned };
    }

    pub fn deinit(self: ThemeUpdate) void {
        self.allocator.free(self.value.font);
        self.allocator.free(self.value.mono_font);
        self.allocator.free(self.value.start_button_icon);
        self.allocator.free(self.region.timezone);
        self.allocator.free(self.region.language);
        self.allocator.free(self.region.formats);
    }

    /// Transfers ownership to the UI thread. Never call from a worker.
    pub fn apply(self: ThemeUpdate) void {
        theme.global = self.value;
        region = self.region;
        text.setPreferredFamilies(self.value.font, self.value.mono_font);
        if (applied_theme) |old| old.deinit();
        applied_theme = self;
    }
};

var applied_theme: ?ThemeUpdate = null;
var region: config.RegionConfig = .{};

pub fn deinitTheme() void {
    theme.global = .{};
    region = .{};
    if (applied_theme) |t| t.deinit();
    applied_theme = null;
}

pub const Settings = struct {
    config_path: ?[:0]const u8 = null,
    theme_path: ?[:0]const u8 = null,
    stamps: [2]?Stamp = .{ null, null },
    animations: anim.Settings = .{},
    region: config.RegionConfig = .{},
    initialized: bool = false,
    last_second: i64 = -1,

    const Stamp = struct { ino: u64, size: i64, sec: i64, nsec: i64 };

    pub fn init(a: std.mem.Allocator, env: std.process.Environ) !Settings {
        const path = @import("config").path.resolvePath(env, a) catch null;
        defer if (path) |p| a.free(p);
        var self: Settings = .{};
        errdefer self.deinit(a);
        if (path) |p| self.config_path = try a.dupeZ(u8, p);
        if (theme.resolvePath(env)) |p| self.theme_path = try a.dupeZ(u8, p);
        return self;
    }

    pub fn deinit(self: *Settings, a: std.mem.Allocator) void {
        if (self.config_path) |p| a.free(p);
        if (self.theme_path) |p| a.free(p);
    }

    /// The merged `[theme]` of the config and `REDIWM_THEME` files, when
    /// either changed. The caller must apply or deinit the returned update.
    pub fn poll(self: *Settings, a: std.mem.Allocator, io: std.Io) ?ThemeUpdate {
        var now: c.struct_timespec = undefined;
        if (c.clock_gettime(c.CLOCK_MONOTONIC, &now) != 0) return null;
        if (self.initialized and now.tv_sec == self.last_second) return null;
        self.last_second = now.tv_sec;
        const paths = [_]?[:0]const u8{ self.config_path, self.theme_path };
        var changed = !self.initialized;
        for (paths, 0..) |path, i| {
            var stamp: ?Stamp = null;
            if (path) |p| {
                var st: c.struct_stat = undefined;
                if (c.stat(p, &st) == 0) stamp = .{ .ino = st.st_ino, .size = st.st_size, .sec = st.st_mtim.tv_sec, .nsec = st.st_mtim.tv_nsec };
            }
            changed = changed or !std.meta.eql(self.stamps[i], stamp);
            self.stamps[i] = stamp;
        }
        self.initialized = true;
        if (!changed) return null;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var t: theme.Theme = .{};
        var prefs: config.RegionConfig = .{};
        self.animations = .{};
        self.region = .{};
        for (paths, 0..) |path, i| {
            const p = path orelse continue;
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, arena.allocator(), .limited(1 << 20)) catch continue;
            if (i == 0) {
                self.animations = parseAnimations(bytes);
                var cfg = config.parse(arena.allocator(), bytes, p) catch null;
                if (cfg) |*value| {
                    defer value.deinit();
                    prefs = value.region;
                    prefs.timezone = arena.allocator().dupe(u8, prefs.timezone) catch return null;
                    prefs.language = arena.allocator().dupe(u8, prefs.language) catch return null;
                    prefs.formats = arena.allocator().dupe(u8, prefs.formats) catch return null;
                }
            }
            var next = t;
            theme.overlay(arena.allocator(), &next, bytes) catch continue;
            t = next;
        }
        // Settings only retains scalar preferences; returned updates own strings.
        self.region.clock_24h = prefs.clock_24h;
        self.region.first_day_of_week = prefs.first_day_of_week;
        return ThemeUpdate.init(a, t, prefs) catch null;
    }
};

/// Applies the current theme once, before a client's first frame.
pub fn loadTheme(a: std.mem.Allocator, io: std.Io, env: std.process.Environ) void {
    var settings = Settings.init(a, env) catch return;
    defer settings.deinit(a);
    if (settings.poll(a, io)) |t| t.apply();
}

/// File timestamps use the same clock preference as the shell.
pub fn dateTime(timestamp: i64, buf: []u8) []const u8 {
    return formatDateTime(timestamp, buf, region);
}

fn formatDateTime(timestamp: i64, buf: []u8, prefs: config.RegionConfig) []const u8 {
    var seconds: c.time_t = @intCast(timestamp);
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&seconds, &tm) == null) return "Unavailable";
    const date_len = c.strftime(buf.ptr, buf.len, "%Y-%m-%d ", &tm);
    if (date_len == 0) return "Unavailable";
    var time_buf: [64]u8 = undefined;
    const time_len = c.strftime(&time_buf, time_buf.len, prefs.timeFormat(), &tm);
    if (time_len == 0) return "Unavailable";
    const time = std.mem.trimStart(u8, time_buf[0..time_len], " ");
    if (date_len + time.len > buf.len) return "Unavailable";
    @memcpy(buf[date_len..][0..time.len], time);
    return buf[0 .. date_len + time.len];
}

test "Files follows config edits, theme overrides and file removal" {
    var config_path = "/tmp/rediwm-scrollbar-config-XXXXXX".*;
    const config_fd = c.mkstemp(&config_path);
    try std.testing.expect(config_fd >= 0);
    defer _ = c.close(config_fd);
    defer _ = c.unlink(&config_path);
    var theme_path = "/tmp/rediwm-scrollbar-theme-XXXXXX".*;
    const theme_fd = c.mkstemp(&theme_path);
    try std.testing.expect(theme_fd >= 0);
    defer _ = c.close(theme_fd);
    defer _ = c.unlink(&theme_path);
    var settings = Settings{ .config_path = &config_path, .theme_path = &theme_path };
    const io = std.testing.io;
    const a = std.testing.allocator;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = &config_path, .data = "[theme]\nscrollbar_width = 12\nfont = \"Noto Sans\"\nmono_font = \"Noto Sans Mono\"\n" });
    const update0 = settings.poll(a, io).?;
    defer update0.deinit();
    try std.testing.expectEqual(@as(f32, 12), update0.value.scrollbar_width);
    try std.testing.expectEqualStrings("Noto Sans", update0.value.font);
    try std.testing.expectEqualStrings("Noto Sans Mono", update0.value.mono_font);
    try std.testing.expect(!update0.region.clock_24h);
    settings.last_second = -1;
    try std.testing.expect(settings.poll(a, io) == null);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = &theme_path, .data = "[theme]\nscrollbar_width = 24\nfont = \"Liberation Sans\"\n" });
    settings.last_second = -1;
    const update1 = settings.poll(a, io).?;
    defer update1.deinit();
    try std.testing.expectEqual(@as(f32, 24), update1.value.scrollbar_width);
    try std.testing.expectEqualStrings("Liberation Sans", update1.value.font);
    try std.testing.expectEqualStrings("Noto Sans Mono", update1.value.mono_font);
    _ = c.unlink(&theme_path);
    settings.last_second = -1;
    const update2 = settings.poll(a, io).?;
    defer update2.deinit();
    try std.testing.expectEqual(@as(f32, 12), update2.value.scrollbar_width);
    try std.testing.expectEqualStrings("Noto Sans", update2.value.font);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = &config_path, .data = "[theme]\nscrollbar_width = 4\n[region]\nclock_24h = true\ntimezone = \"Pacific/Auckland\"\nlanguage = \"C.utf8\"\nformats = \"en_NZ.utf8\"\n" });
    settings.last_second = -1;
    const update3 = settings.poll(a, io).?;
    defer update3.deinit();
    try std.testing.expectEqual(@as(f32, 4), update3.value.scrollbar_width);
    try std.testing.expectEqualStrings((theme.Theme{}).font, update3.value.font);
    try std.testing.expect(update3.region.clock_24h);
    // The config's preference travels with the worker update, independently
    // of theme overrides; verify both clock formats in local time.
    var tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
    tm.tm_year = 124;
    tm.tm_mon = 2;
    tm.tm_mday = 14;
    tm.tm_min = 24;
    tm.tm_isdst = -1;
    var buf: [64]u8 = undefined;
    for ([_]c_int{ 0, 12, 15 }, [_][]const u8{ "12:24 AM", "12:24 PM", "3:24 PM" }, [_][]const u8{ "00:24", "12:24", "15:24" }) |hour, time12, time24| {
        tm.tm_hour = hour;
        const timestamp = c.mktime(&tm);
        try std.testing.expectEqualStrings(time12, formatDateTime(timestamp, &buf, update0.region)[11..]);
        try std.testing.expectEqualStrings(time24, formatDateTime(timestamp, &buf, update3.region)[11..]);
    }
    try std.testing.expectEqualStrings("Unavailable", formatDateTime(0, buf[0..4], update3.region));
    try std.testing.expectEqualStrings("Pacific/Auckland", update3.region.timezone);
    try std.testing.expectEqualStrings("C.utf8", update3.region.language);
    try std.testing.expectEqualStrings("en_NZ.utf8", update3.region.formats);
    // Outstanding worker updates retain their strings across later polls.
    try std.testing.expectEqualStrings("Liberation Sans", update1.value.font);
}

test "Files keeps theme colours and font names alive after parsing" {
    var theme_path = "/tmp/rediwm-colour-theme-XXXXXX".*;
    const fd = c.mkstemp(&theme_path);
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    defer _ = c.unlink(&theme_path);
    const io = std.testing.io;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = &theme_path, .data = "[theme]\nfont = \"Inter\"\napp_bg = \"#102030\"\n" });
    var settings = Settings{ .theme_path = &theme_path };
    const t = settings.poll(std.testing.allocator, io).?;
    defer t.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 0x20) / 255.0, t.value.app_bg[1], 1e-6);
    try std.testing.expectEqualStrings("Inter", t.value.font);
    try std.testing.expectEqualStrings((theme.Theme{}).mono_font, t.value.mono_font);
}

// Reuse the shell's value parsers, without importing compositor dependencies
// into the standalone client. Only the global and wheel animation tables apply.
fn parseAnimations(bytes: []const u8) anim.Settings {
    var settings: anim.Settings = .{};
    var flags: anim_config.TargetFlags = .{};
    var section: enum { other, global, wheel } = .other;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            section = if (std.mem.eql(u8, line, "[animations]")) .global else if (std.mem.eql(u8, line, "[animations.wheel_scroll]")) .wheel else .other;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        switch (section) {
            .global => anim_config.applyGlobalKey(&settings, key, value) catch {},
            .wheel => anim_config.applyTargetKey(&settings, .wheel_scroll, &flags, key, value) catch {},
            .other => {},
        }
    }
    return settings;
}

test "Files reads the shell wheel animation and reduced motion settings" {
    const settings = parseAnimations("[animations]\nenabled = false\nspeed = 1.5\nreduced_motion = \"on\"\n[animations.wheel_scroll]\noff = true\n");
    try std.testing.expect(!settings.enabled);
    try std.testing.expectEqual(@as(f32, 1.5), settings.speed);
    try std.testing.expectEqual(anim.ReducedMotion.on, settings.reduced_motion);
    try std.testing.expect(settings.targets[@intFromEnum(anim.Target.wheel_scroll)].curve == .off);
}
