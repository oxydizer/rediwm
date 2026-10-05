//! Follow the compositor's persisted theme without blocking the UI thread.
//! Stat once per second; read only after changes, including atomic replacement.
//! Shared by the Files, Images and PDF clients.
const std = @import("std");
const c = @import("c.zig").api;
const anim = @import("ui").anim;
const anim_config = @import("config").animations;
const theme = @import("ui").theme;
const text = @import("ui").text;

/// Owns the string tokens while a theme travels from the worker to the UI.
pub const ThemeUpdate = struct {
    value: theme.Theme,
    allocator: std.mem.Allocator,

    fn init(a: std.mem.Allocator, t: theme.Theme) !ThemeUpdate {
        var value = t;
        value.font = try a.dupe(u8, t.font);
        errdefer a.free(value.font);
        value.mono_font = try a.dupe(u8, t.mono_font);
        errdefer a.free(value.mono_font);
        value.start_button_icon = try a.dupe(u8, t.start_button_icon);
        return .{ .value = value, .allocator = a };
    }

    pub fn deinit(self: ThemeUpdate) void {
        self.allocator.free(self.value.font);
        self.allocator.free(self.value.mono_font);
        self.allocator.free(self.value.start_button_icon);
    }

    /// Transfers ownership to the UI thread. Never call from a worker.
    pub fn apply(self: ThemeUpdate) void {
        theme.global = self.value;
        text.setPreferredFamilies(self.value.font, self.value.mono_font);
        if (applied_theme) |old| old.deinit();
        applied_theme = self;
    }
};

var applied_theme: ?ThemeUpdate = null;

pub fn deinitTheme() void {
    theme.global = .{};
    if (applied_theme) |t| t.deinit();
    applied_theme = null;
}

pub const Settings = struct {
    config_path: ?[:0]const u8 = null,
    theme_path: ?[:0]const u8 = null,
    stamps: [2]?Stamp = .{ null, null },
    animations: anim.Settings = .{},
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
        self.animations = .{};
        for (paths, 0..) |path, i| {
            const p = path orelse continue;
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, arena.allocator(), .limited(1 << 20)) catch continue;
            if (i == 0) self.animations = parseAnimations(bytes);
            var next = t;
            theme.overlay(arena.allocator(), &next, bytes) catch continue;
            t = next;
        }
        return ThemeUpdate.init(a, t) catch null;
    }
};

/// Applies the current theme once, before a client's first frame.
pub fn loadTheme(a: std.mem.Allocator, io: std.Io, env: std.process.Environ) void {
    var settings = Settings.init(a, env) catch return;
    defer settings.deinit(a);
    if (settings.poll(a, io)) |t| t.apply();
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
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = &config_path, .data = "[theme]\nscrollbar_width = 4\n" });
    settings.last_second = -1;
    const update3 = settings.poll(a, io).?;
    defer update3.deinit();
    try std.testing.expectEqual(@as(f32, 4), update3.value.scrollbar_width);
    try std.testing.expectEqualStrings((theme.Theme{}).font, update3.value.font);
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
