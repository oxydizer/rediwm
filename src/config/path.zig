const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn resolvePath(environ: std.process.Environ, allocator: Allocator) ![]const u8 {
    if (environ.getPosix("REDIWM_CONFIG")) |p| {
        if (p.len > 0) return allocator.dupe(u8, p);
    }
    if (environ.getPosix("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) return std.fmt.allocPrint(allocator, "{s}/rediwm/config.toml", .{xdg});
    }
    const home = environ.getPosix("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/rediwm/config.toml", .{home});
}
