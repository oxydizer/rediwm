//! Distinguishes missing capture protocol (compositor-side), wrong portal
//! backend/display, absent chooser, and PipeWire connection failure — the
//! stage 2 diagnostics the plan asks for. Does not log pixels or titles.
const std = @import("std");

const child_env = @import("../child_env.zig");

pub const Check = struct {
    name: []const u8,
    ok: bool,
    detail: []const u8,
};

pub fn findPortalsConf(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !?[]u8 {
    const name = "rediwm-portals.conf";
    if (environ.getPosix("XDG_DATA_HOME")) |home| {
        if (home.len > 0) {
            if (try existing(allocator, io, &.{ home, "xdg-desktop-portal", name })) |path| return path;
        }
    }
    if (environ.getPosix("XDG_DATA_DIRS")) |dirs| {
        var it = std.mem.splitScalar(u8, dirs, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            if (try existing(allocator, io, &.{ dir, "xdg-desktop-portal", name })) |path| return path;
        }
    }
    if (try existing(allocator, io, &.{ "/usr/local/share", "xdg-desktop-portal", name })) |path| return path;
    if (try existing(allocator, io, &.{ "/usr/share", "xdg-desktop-portal", name })) |path| return path;
    return null;
}

pub fn findXdpwConfig(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !?[]u8 {
    const desktop = environ.getPosix("XDG_CURRENT_DESKTOP") orelse child_env.desktop_name;
    const owned_home: ?[]u8 = blk: {
        if (environ.getPosix("XDG_CONFIG_HOME")) |h| if (h.len > 0) break :blk null;
        if (environ.getPosix("HOME")) |h| break :blk try std.fs.path.join(allocator, &.{ h, ".config" });
        break :blk null;
    };
    defer if (owned_home) |p| allocator.free(p);
    const base: ?[]const u8 = blk: {
        if (environ.getPosix("XDG_CONFIG_HOME")) |h| if (h.len > 0) break :blk h;
        break :blk owned_home;
    };

    if (base) |b| {
        var it = std.mem.splitScalar(u8, desktop, ':');
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            if (try existing(allocator, io, &.{ b, "xdg-desktop-portal-wlr", entry })) |path| return path;
        }
        if (try existing(allocator, io, &.{ b, "xdg-desktop-portal-wlr", "config" })) |path| return path;
    }
    var it = std.mem.splitScalar(u8, desktop, ':');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        if (try existing(allocator, io, &.{ "/etc/xdg/xdg-desktop-portal-wlr", entry })) |path| return path;
    }
    if (try existing(allocator, io, &.{ "/etc/xdg/xdg-desktop-portal-wlr", "config" })) |path| return path;
    return null;
}

fn existing(allocator: std.mem.Allocator, io: std.Io, parts: []const []const u8) !?[]u8 {
    const path = try std.fs.path.join(allocator, parts);
    std.Io.Dir.accessAbsolute(io, path, .{}) catch {
        allocator.free(path);
        return null;
    };
    return path;
}

pub fn which(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, name: []const u8) !?[]u8 {
    const path_env = environ.getPosix("PATH") orelse "/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        if (try existing(allocator, io, &.{ dir, name })) |path| return path;
    }
    // Portal helpers often live in libexec, not PATH.
    inline for (.{ "/usr/lib", "/usr/libexec", "/usr/local/lib", "/usr/local/libexec" }) |dir| {
        if (try existing(allocator, io, &.{ dir, name })) |path| return path;
    }
    return null;
}

pub fn findPicker(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !?[]u8 {
    if (try which(allocator, io, environ, "rediwm-share-picker")) |path| return path;
    const dir = std.process.executableDirPathAlloc(io, allocator) catch return null;
    defer allocator.free(dir);
    return existing(allocator, io, &.{ dir, "rediwm-share-picker" });
}

pub fn pipewireSocket(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !?[]u8 {
    const runtime = environ.getPosix("XDG_RUNTIME_DIR") orelse return null;
    if (try existing(allocator, io, &.{ runtime, "pipewire-0" })) |path| return path;
    return null;
}

test "path join for portals.conf uses the desktop-specific filename" {
    const path = try std.fs.path.join(std.testing.allocator, &.{ "/usr/share", "xdg-desktop-portal", "rediwm-portals.conf" });
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/usr/share/xdg-desktop-portal/rediwm-portals.conf", path);
}
