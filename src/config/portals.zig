//! xdg-desktop-portal reads the first matching file, not a merge. Seed a
//! per-user override from the effective config and preserve unrelated keys.
const std = @import("std");
const a = std.heap.c_allocator;
pub const defaults = "[preferred]\ndefault=gtk\norg.freedesktop.impl.portal.ScreenCast=wlr\norg.freedesktop.impl.portal.Settings=rediwm;gtk\norg.freedesktop.impl.portal.FileChooser=rediwm;gtk\n";
pub const chooser_key = "org.freedesktop.impl.portal.FileChooser";

pub fn userPath(allocator: std.mem.Allocator, env: std.process.Environ) ![]u8 {
    if (env.getPosix("XDG_CONFIG_HOME")) |dir| if (std.fs.path.isAbsolute(dir)) return std.fmt.allocPrint(allocator, "{s}/xdg-desktop-portal/rediwm-portals.conf", .{dir});
    const home = env.getPosix("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/xdg-desktop-portal/rediwm-portals.conf", .{home});
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, env: std.process.Environ) ![]u8 {
    const path = try userPath(allocator, env);
    defer allocator.free(path);
    const config_home = std.fs.path.dirname(std.fs.path.dirname(path).?).?;
    const local_share = try std.fmt.allocPrint(allocator, "{s}/.local/share", .{env.getPosix("HOME") orelse "/"});
    defer allocator.free(local_share);
    const dirs = [_][]const u8{ config_home, env.getPosix("XDG_CONFIG_DIRS") orelse "/etc/xdg", env.getPosix("XDG_DATA_HOME") orelse local_share, env.getPosix("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share" };
    for (dirs) |list| {
        var split = std.mem.splitScalar(u8, list, ':');
        while (split.next()) |dir| {
            if (!std.fs.path.isAbsolute(dir)) continue;
            for ([_][]const u8{ "rediwm-portals.conf", "portals.conf" }) |name| {
                const candidate = try std.fmt.allocPrint(allocator, "{s}/xdg-desktop-portal/{s}", .{ dir, name });
                defer allocator.free(candidate);
                const content = std.Io.Dir.cwd().readFileAlloc(io, candidate, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                return content;
            }
        }
    }
    return allocator.dupe(u8, defaults);
}

pub fn get(content: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var preferred = false;
    var result: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "[")) preferred = std.mem.eql(u8, line, "[preferred]");
        if (!preferred) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) result = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
    }
    return result;
}

pub fn patch(allocator: std.mem.Allocator, content: []const u8, key: []const u8, value: []const u8) ![]u8 {
    if (!std.mem.eql(u8, key, "default") and !std.mem.eql(u8, key, chooser_key)) return error.InvalidKey;
    if (std.mem.indexOfAny(u8, value, "\n\r\x00") != null) return error.InvalidValue;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var preferred = false;
    var found = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "[")) {
            preferred = std.mem.eql(u8, line, "[preferred]");
            if (preferred) {
                try result.appendSlice(allocator, raw);
                try result.append(allocator, '\n');
                if (!found) {
                    try result.appendSlice(allocator, key);
                    try result.append(allocator, '=');
                    try result.appendSlice(allocator, value);
                    try result.append(allocator, '\n');
                    found = true;
                }
                continue;
            }
        }
        if (preferred) if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) continue;
        };
        if (raw.len == 0 and lines.index == null) break;
        try result.appendSlice(allocator, raw);
        try result.append(allocator, '\n');
    }
    if (!found) {
        try result.appendSlice(allocator, "[preferred]\n");
        try result.appendSlice(allocator, key);
        try result.append(allocator, '=');
        try result.appendSlice(allocator, value);
        try result.append(allocator, '\n');
    }
    return result.toOwnedSlice(allocator);
}

pub fn save(io: std.Io, env: std.process.Environ, key: []const u8, value: []const u8) !void {
    const original = try load(a, io, env);
    defer a.free(original);
    const result = try patch(a, original, key, value);
    defer a.free(result);
    const path = try userPath(a, env);
    defer a.free(path);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    const temp = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
    defer a.free(temp);
    const file = try std.Io.Dir.cwd().createFile(io, temp, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, temp) catch {};
    try file.writeStreamingAll(io, result);
    try file.sync(io);
    try std.Io.Dir.rename(.cwd(), temp, .cwd(), path, io);
}

test "portal override preserves unrelated preferences and sections" {
    const original = "# custom\n[preferred]\ndefault=gtk\norg.freedesktop.impl.portal.ScreenCast=wlr\n[other]\ndefault=keep\n";
    const result = try patch(std.testing.allocator, original, "default", "kde");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("kde", get(result, "default").?);
    try std.testing.expectEqualStrings("wlr", get(result, "org.freedesktop.impl.portal.ScreenCast").?);
    try std.testing.expect(std.mem.indexOf(u8, result, "[other]\ndefault=keep") != null);
}
