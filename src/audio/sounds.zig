//! On-demand desktop event sounds. No connection, thread or timer at idle.
//! Uses installed stereo sound themes and paplay; never invokes a shell.
const std = @import("std");
const Server = @import("../Server.zig");
const protocol = @import("../ipc/protocol.zig");

pub const events = [_][]const u8{
    "bell",          "dialog-information",  "dialog-warning",      "dialog-error",
    "message",       "message-new-instant", "message-new-email",   "complete",
    "service-login", "service-logout",      "desktop-login",       "desktop-logout",
    "device-added",  "device-removed",      "power-plug",          "power-unplug",
    "battery-low",   "battery-caution",     "audio-volume-change", "window-attention",
};
const player = "/usr/bin/paplay";

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    return true;
}
fn exists(server: *Server, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(server.io, path, .{}) catch return false;
    return stat.kind == .file;
}
fn roots(server: *Server, a: std.mem.Allocator) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    if (server.environ.getPosix("XDG_DATA_HOME")) |data| {
        if (std.fs.path.isAbsolute(data)) try result.append(a, data);
    } else {
        if (server.environ.getPosix("HOME")) |home| try result.append(a, try std.fmt.allocPrint(a, "{s}/.local/share", .{home})) else {}
    }
    const dirs = server.environ.getPosix("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = std.mem.splitScalar(u8, dirs, ':');
    while (it.next()) |dir| if (std.fs.path.isAbsolute(dir)) {
        try result.append(a, dir);
    };
    return result.items;
}

const Match = struct { path: ?[]const u8 = null, disabled: bool = false };
fn lookup(server: *Server, a: std.mem.Allocator, dirs: []const []const u8, theme_name: []const u8, event: []const u8, depth: u8, budget: *usize) !Match {
    if (depth > 8 or budget.* == 0 or !validName(theme_name)) return .{};
    budget.* -= 1;
    // A .disabled marker is authoritative and stops inherited fallbacks.
    for (dirs) |dir| for ([_][]const u8{ "stereo/", "" }) |sub| {
        const base = try std.fmt.allocPrint(a, "{s}/sounds/{s}/{s}{s}", .{ dir, theme_name, sub, event });
        const disabled = try std.fmt.allocPrint(a, "{s}.disabled", .{base});
        if (exists(server, disabled)) return .{ .disabled = true };
        for ([_][]const u8{ ".oga", ".ogg", ".wav" }) |ext| {
            const path = try std.fmt.allocPrint(a, "{s}{s}", .{ base, ext });
            if (exists(server, path)) return .{ .path = path };
        }
    };
    for (dirs) |dir| {
        const index = try std.fmt.allocPrint(a, "{s}/sounds/{s}/index.theme", .{ dir, theme_name });
        const contents = std.Io.Dir.cwd().readFileAlloc(server.io, index, a, .limited(65536)) catch continue;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        var section = false;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "[")) section = std.mem.eql(u8, trimmed, "[Sound Theme]");
            if (!section or !std.mem.startsWith(u8, trimmed, "Inherits=")) continue;
            var parents = std.mem.tokenizeAny(u8, trimmed[9..], ",; ");
            while (parents.next()) |parent| {
                const result = try lookup(server, a, dirs, parent, event, depth + 1, budget);
                if (result.path != null or result.disabled) return result;
            }
        }
        break;
    }
    return .{};
}

pub fn inspect(server: *Server, a: std.mem.Allocator) !protocol.SoundsResult {
    const cfg = server.config.compositor;
    const dirs = try roots(server, a);
    const rows = try a.alloc(protocol.SoundEventData, events.len);
    for (events, rows) |event, *row| {
        var budget: usize = 32;
        var match = try lookup(server, a, dirs, cfg.sound_theme, event, 0, &budget);
        if (match.path == null and !match.disabled and !std.mem.eql(u8, cfg.sound_theme, "freedesktop"))
            match = try lookup(server, a, dirs, "freedesktop", event, 0, &budget);
        var enabled = cfg.sound_enabled and !match.disabled;
        for (cfg.sound_disabled_events) |disabled| if (std.mem.eql(u8, disabled, event)) {
            enabled = false;
        };
        row.* = .{ .name = event, .enabled = enabled, .available = match.path != null, .path = match.path };
    }
    return .{ .theme = cfg.sound_theme, .enabled = cfg.sound_enabled, .player_available = exists(server, player), .events = rows };
}

pub fn play(server: *Server, a: std.mem.Allocator, event: []const u8) !protocol.Response {
    var known = false;
    for (events) |name| if (std.mem.eql(u8, name, event)) {
        known = true;
    };
    if (!known) return error.UnknownSoundEvent;
    const state = try inspect(server, a);
    if (!state.player_available) return error.SoundPlayerUnavailable;
    for (state.events) |row| {
        if (!std.mem.eql(u8, event, row.name)) continue;
        if (!row.enabled) return error.SoundEventDisabled;
        const path = row.path orelse return error.SoundEventUnavailable;
        const manager = server.services orelse return error.SoundPlayerUnavailable;
        var env = try server.environ.createMap(a);
        defer env.deinit();
        try server.applyChildEnv(&env);
        const child = try std.process.spawn(server.io, .{
            .argv = &.{ player, "--client-name=RediWM", "--property=media.role=event", "--", path },
            .environ_map = &env,
        });
        if (child.id) |pid| try manager.trackChild(pid);
        return .{ .ok = .{ .sound_playback = .{ .event = event, .pid = child.id } } };
    }
    return error.UnknownSoundEvent;
}
