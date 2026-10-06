//! Settings operations shared by IPC; independent of an open Settings window.
const std = @import("std");
const Server = @import("../Server.zig");
const protocol = @import("protocol.zig");
const theme = @import("ui").theme;
const save = @import("config").setting_save;
const wallpapers = @import("../wallpapers.zig");
const gpa = @import("../main.zig").gpa;

pub fn services(server: *Server, a: std.mem.Allocator) !protocol.Response {
    const client = server.getSystemd() catch return .{ .err = "ServicesUnavailable" };
    client.open();
    if (!client.busy() and !client.awaitingList() and !client.analyzed) client.analyze();
    const units = client.snapshot.units.items;
    const result = try a.alloc(protocol.ServiceData, units.len);
    for (units, result) |u, *row| row.* = .{
        .name = u.name,
        .description = u.description,
        .active = u.active,
        .sub = u.sub,
        .startup = u.startup,
        .trigger = u.trigger,
        .activation_us = u.time_us,
        .editable = u.editable(),
    };
    return .{ .ok = .{ .services = .{
        .available = client.available(),
        .loading = client.awaitingList() or client.loading,
        .analyzing = client.analyzing,
        .timing_available = client.analyzed,
        .action_pending = client.action_pending,
        .boot_us = client.boot_us,
        .status = client.status(),
        .services = result,
    } } };
}

pub fn wallpaper(server: *Server, a: std.mem.Allocator) !protocol.Response {
    return .{ .ok = .{ .wallpaper = .{
        .configured = server.config.compositor.wallpaper,
        .resolved_path = wallpapers.resolve(a, server.io, server.config.compositor.wallpaper) catch null,
        .displayed_path = server.wallpaper_displayed_path,
        .loading = server.wallpaper_loader != null,
        .failed = server.wallpaper_failed,
        .width = if (server.wallpaper) |w| @intCast(w.base.width) else null,
        .height = if (server.wallpaper) |w| @intCast(w.base.height) else null,
    } } };
}

pub fn setWallpaper(server: *Server, path: []const u8, persist: bool) !void {
    // Validate existence before saving; decode remains on the wallpaper worker.
    const resolved = try wallpapers.resolve(gpa, server.io, path);
    defer gpa.free(resolved);
    const stat = try std.Io.Dir.cwd().statFile(server.io, resolved, .{});
    if (stat.kind != .file) return error.InvalidWallpaper;
    const owned = try server.config.arena.allocator().dupe(u8, path);
    if (persist) try save.saveCompositor(gpa, server.io, server.config.path, "wallpaper", path);
    server.config.compositor.wallpaper = owned;
    server.reloadWallpaper();
    if (server.input.open_control_center) |cc| cc.refresh();
}

pub fn setAccent(server: *Server, color: [4]f32, persist: bool) !void {
    if (persist) try save.saveAccent(gpa, server.io, server.theme_path orelse server.config.path, color);
    theme.global.accent = color;
    @import("../control_center/sections/appearance.zig").refreshTheme(server, false);
    if (server.input.open_control_center) |cc| cc.refresh();
}

pub fn setNightLight(server: *Server, enabled: ?bool, temperature: ?u16, persist: bool) !void {
    var cfg = server.config.night_light;
    if (enabled) |v| cfg.enabled = v;
    if (temperature) |v| cfg.temperature = v;
    if (persist) try save.saveNightLightConfig(gpa, server.io, server.config.path, cfg);
    server.config.night_light = cfg;
    server.night_light.reconfigure(cfg);
    if (server.input.open_control_center) |cc| cc.refresh();
}

pub fn getTheme(server: *Server, a: std.mem.Allocator) !protocol.Response {
    const fields = std.meta.fields(theme.Theme);
    const entries = try a.alloc(protocol.ThemeToken, fields.len);
    inline for (fields, 0..) |field, i| {
        entries[i] = .{ .name = field.name };
        const value = @field(theme.global, field.name);
        if (field.type == [4]f32 or field.type == ?[4]f32) entries[i].color = value else if (field.type == []const u8) entries[i].text = value else if (field.type == bool) entries[i].boolean = value else if (@typeInfo(field.type) == .float) entries[i].number = value else @compileError("unhandled theme token " ++ field.name);
    }
    return .{ .ok = .{ .theme = .{ .tokens = .{ .entries = entries }, .path = server.theme_path, .dark_mode = server.config.compositor.dark_mode } } };
}
