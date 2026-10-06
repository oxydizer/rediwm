//! Apply a personal timezone to libc clocks without changing system files.
const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("stdlib.h");
    @cInclude("time.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

pub fn applyTimezone(allocator: std.mem.Allocator, zone: []const u8, inherited: ?[]const u8) !void {
    if (zone.len != 0) {
        // Only IANA zone files, never paths supplied by the caller or POSIX rules.
        if (zone.len > 255 or zone[0] == '/' or std.mem.indexOf(u8, zone, "..") != null) return error.InvalidTimezone;
        for (zone) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '/' and ch != '_' and ch != '-' and ch != '+') return error.InvalidTimezone;
        const path = try std.fmt.allocPrintSentinel(allocator, "/usr/share/zoneinfo/{s}", .{zone}, 0);
        defer allocator.free(path);
        const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
        if (fd < 0) return error.InvalidTimezone;
        defer _ = c.close(fd);
        var magic: [4]u8 = undefined;
        if (c.read(fd, &magic, magic.len) != magic.len or !std.mem.eql(u8, &magic, "TZif")) return error.InvalidTimezone;
    }
    const value = if (zone.len != 0) zone else inherited;
    if (value) |name| {
        const z = try allocator.dupeZ(u8, name);
        defer allocator.free(z);
        if (c.setenv("TZ", z, 1) != 0) return error.OutOfMemory;
    } else if (c.unsetenv("TZ") != 0) return error.OutOfMemory;
    c.tzset();
}
