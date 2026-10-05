// Named, wholesale theme bundles for the Control Center's Appearance picker.
// A preset is just raw `[theme]` TOML, parsed with theme.parse like any
// REDIWM_THEME file; picking one replaces theme.global's fields all at once
// instead of one slider/swatch at a time.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Preset = struct {
    name: []const u8,
    bytes: []const u8,
};

const bundled = [_]Preset{
    .{ .name = "RediWM Dark", .bytes = @embedFile("theme-rediwm-dark") },
    .{ .name = "RediWM Light", .bytes = @embedFile("theme-rediwm-light") },
    .{ .name = "Redi Blue", .bytes = @embedFile("theme-redi-blue") },
};

/// Bundled presets, followed by every `*.toml` file found in
/// `dirname(config_path)/themes/` (stem = display name). Best-effort like the
/// rest of this codebase's file IO: a missing config path or unreadable
/// directory just yields the bundled list. Returned slice is allocated from
/// `allocator`, meant to be a caller-owned arena reset each time the panel
/// that calls this rebuilds.
pub fn list(allocator: Allocator, io: Io, config_path: []const u8) []const Preset {
    var out: std.ArrayList(Preset) = .empty;
    out.appendSlice(allocator, &bundled) catch return &bundled;

    const dir_path = std.fs.path.dirname(config_path) orelse return out.items;
    var themes_dir_buf: [std.posix.PATH_MAX]u8 = undefined;
    const themes_path = std.fmt.bufPrint(&themes_dir_buf, "{s}/themes", .{dir_path}) catch return out.items;
    var dir = Io.Dir.cwd().openDir(io, themes_path, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
        var path_buf: [std.posix.PATH_MAX]u8 = undefined;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ themes_path, entry.name }) catch continue;
        const bytes = Io.Dir.cwd().readFileAlloc(io, full, allocator, .limited(1 << 20)) catch continue;
        const name = allocator.dupe(u8, entry.name[0 .. entry.name.len - ".toml".len]) catch continue;
        out.append(allocator, .{ .name = name, .bytes = bytes }) catch continue;
    }
    return out.items;
}
