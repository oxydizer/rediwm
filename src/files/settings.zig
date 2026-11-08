//! Follow the compositor's persisted theme without blocking the UI thread.
//! `watch` watches the files' directories so followers sleep until a
//! change; `poll` stats at most once per second and reads only after changes,
//! including atomic replacement. Shared by the Files, Images, PDF and System
//! Monitor clients.
const std = @import("std");
const c = @import("c.zig").api;
const platform = @import("platform");
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
    pack_root: []const u8 = "",
    icon_theme: []const u8 = "",
    io: std.Io,
    single_click_open: bool = true,
    audio_player: bool = true,
    terminal_opacity: ?f32 = null,

    fn init(a: std.mem.Allocator, t: theme.Theme, prefs: config.RegionConfig, root: []const u8, icon_name: []const u8, io: std.Io) !ThemeUpdate {
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
        errdefer a.free(owned.formats);
        const pack_root = try a.dupe(u8, root);
        errdefer a.free(pack_root);
        const icon_theme = try a.dupe(u8, icon_name);
        return .{ .value = value, .allocator = a, .region = owned, .pack_root = pack_root, .icon_theme = icon_theme, .io = io };
    }

    pub fn deinit(self: ThemeUpdate) void {
        self.allocator.free(self.icon_theme);
        self.allocator.free(self.pack_root);
        self.allocator.free(self.value.font);
        self.allocator.free(self.value.mono_font);
        self.allocator.free(self.value.start_button_icon);
        self.allocator.free(self.region.timezone);
        self.allocator.free(self.region.language);
        self.allocator.free(self.region.formats);
    }

    /// Transfers ownership to the UI thread. Never call from a worker.
    pub fn apply(self: ThemeUpdate) void {
        @import("ui").shell_icons.configure(self.io, self.pack_root);
        theme.global = self.value.forApp();
        region = self.region;
        text.setPreferredFamilies(self.value.font, self.value.mono_font);
        if (applied_theme) |old| old.deinit();
        applied_theme = self;
    }
};

var applied_theme: ?ThemeUpdate = null;
var region: config.RegionConfig = .{};

/// Open With uses the same formats preference as directory names. Empty
/// asks newlocale to inherit the process LC_COLLATE environment.
pub fn formatsLocale() []const u8 {
    return region.formats;
}

pub fn deinitTheme() void {
    @import("ui").shell_icons.deinitPack();
    theme.global = .{};
    region = .{};
    if (applied_theme) |t| t.deinit();
    applied_theme = null;
}

pub const Settings = struct {
    env: ?std.process.Environ = null,
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
        var self: Settings = .{ .env = env };
        errdefer self.deinit(a);
        if (path) |p| self.config_path = try a.dupeSentinel(u8, p, 0);
        if (theme.resolvePath(env)) |p| self.theme_path = try a.dupeSentinel(u8, p, 0);
        return self;
    }

    pub fn deinit(self: *Settings, a: std.mem.Allocator) void {
        if (self.config_path) |p| a.free(p);
        if (self.theme_path) |p| a.free(p);
    }

    /// Watches the directories holding the config and theme files, so atomic
    /// saves are seen too. A missing directory is replaced by its nearest
    /// existing parent: call again after events, so a created directory gets
    /// its own watch (re-adding a watch is harmless).
    pub fn watch(self: *const Settings, watcher: platform.watch.Watcher) void {
        for ([_]?[:0]const u8{ self.config_path, self.theme_path }) |maybe_path| {
            const parent = std.fs.path.dirname(maybe_path orelse continue) orelse continue;
            _ = watcher.addOrParent(parent, .{ .written = true, .moved_to = true, .created = true, .deleted = true });
        }
    }

    /// `poll` without its once-a-second pacing, for after `watch` saw events.
    pub fn reload(self: *Settings, a: std.mem.Allocator, io: std.Io) ?ThemeUpdate {
        self.last_second = -1;
        return self.poll(a, io);
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
        var icon_name: []const u8 = "";
        var root: []const u8 = "";
        var prefs: config.RegionConfig = .{};
        var single_click_open = true;
        var audio_player = true;
        var terminal_opacity: ?f32 = null;
        self.animations = .{};
        self.region = .{};
        for (paths, 0..) |path, i| {
            const p = path orelse continue;
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, p, arena.allocator(), .limited(1 << 20)) catch continue;
            if (i == 0) {
                self.animations = parseAnimations(bytes);
                var cfg = if (self.env) |env| config.loadFromBytes(arena.allocator(), bytes, p, env, io) catch null else config.parse(arena.allocator(), bytes, p) catch null;
                if (cfg) |*value| {
                    defer value.deinit();
                    icon_name = value.compositor.icon_theme;
                    if (value.theme_pack) |pack| if (pack.icon_theme.len > 0) {
                        icon_name = pack.icon_theme;
                    };
                    icon_name = arena.allocator().dupe(u8, icon_name) catch return null;
                    t = value.theme;
                    single_click_open = value.compositor.files_single_click_open;
                    audio_player = value.compositor.files_audio_player;
                    terminal_opacity = value.compositor.terminal_opacity;
                    if (value.theme_pack) |pack| root = arena.allocator().dupe(u8, pack.root) catch return null;
                    inline for (.{ "font", "mono_font", "start_button_icon" }) |field| @field(t, field) = arena.allocator().dupe(u8, @field(t, field)) catch return null;
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
        var update = ThemeUpdate.init(a, t, prefs, root, icon_name, io) catch return null;
        update.single_click_open = single_click_open;
        update.audio_player = audio_player;
        update.terminal_opacity = terminal_opacity;
        return update;
    }
};

/// Applies the current theme once, before a client's first frame.
pub fn loadTheme(a: std.mem.Allocator, io: std.Io, env: std.process.Environ) void {
    var settings = Settings.init(a, env) catch return;
    defer settings.deinit(a);
    if (settings.poll(a, io)) |t| t.apply();
}

pub fn terminalOpacity() ?f32 {
    return if (applied_theme) |t| t.terminal_opacity else null;
}

/// File timestamps use the same clock preference as the shell.
pub fn dateTime(timestamp: i64, buf: []u8) []const u8 {
    return formatDateTime(timestamp, buf, region);
}

fn formatDateTime(timestamp: i64, buf: []u8, prefs: config.RegionConfig) []const u8 {
    var seconds: c.time_t = @intCast(timestamp);
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&seconds, &tm) == null) return @import("i18n").tr("Unavailable");
    const date_len = c.strftime(buf.ptr, buf.len, "%Y-%m-%d ", &tm);
    if (date_len == 0) return @import("i18n").tr("Unavailable");
    var time_buf: [64]u8 = undefined;
    const time_len = c.strftime(&time_buf, time_buf.len, prefs.timeFormat(), &tm);
    if (time_len == 0) return @import("i18n").tr("Unavailable");
    const time = std.mem.trimStart(u8, time_buf[0..time_len], " ");
    if (date_len + time.len > buf.len) return @import("i18n").tr("Unavailable");
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
    try std.testing.expect(update0.single_click_open);
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
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = &config_path, .data = "[compositor]\nfiles_single_click_open = false\n[theme]\nscrollbar_width = 4\n[region]\nclock_24h = true\ntimezone = \"Pacific/Auckland\"\nlanguage = \"C.utf8\"\nformats = \"en_NZ.utf8\"\n" });
    settings.last_second = -1;
    const update3 = settings.poll(a, io).?;
    defer update3.deinit();
    try std.testing.expectEqual(@as(f32, 4), update3.value.scrollbar_width);
    try std.testing.expectEqualStrings((theme.Theme{}).font, update3.value.font);
    try std.testing.expect(update3.region.clock_24h);
    try std.testing.expect(!update3.single_click_open);
    _ = c.unlink(&config_path);
    settings.last_second = -1;
    const update4 = settings.poll(a, io).?;
    defer update4.deinit();
    try std.testing.expect(update4.single_click_open);
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
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = &theme_path, .data = "[theme]\nfont = \"Inter\"\napp_bg = \"#102030\"\napp_surface_hover = \"rgba(229,214,195,0.96)\"\napp_sidebar_hover = \"rgba(116,92,72,0.96)\"\n" });
    var settings = Settings{ .theme_path = &theme_path };
    const t = settings.poll(std.testing.allocator, io).?;
    defer t.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 0x20) / 255.0, t.value.app_bg[1], 1e-6);
    try std.testing.expectEqualStrings("Inter", t.value.font);
    try std.testing.expectEqualStrings((theme.Theme{}).mono_font, t.value.mono_font);
    try std.testing.expectEqual(t.value.app_surface_hover.?, t.value.forApp().surface_hover);
    try std.testing.expectEqual(t.value.app_sidebar_hover.?, t.value.sidebarHover());
    try std.testing.expectEqual((theme.Theme{}).app_item_hover, (theme.Theme{}).sidebarHover());
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

pub fn iconRoot() []const u8 {
    return if (applied_theme) |t| t.pack_root else "";
}
pub fn iconTheme() []const u8 {
    return if (applied_theme) |t| t.icon_theme else "";
}

pub fn audioPlayer() bool {
    return if (applied_theme) |t| t.audio_player else true;
}

pub fn singleClickOpen() bool {
    return if (applied_theme) |t| t.single_click_open else true;
}
