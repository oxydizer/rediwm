//! Where Xcursor themes are found, and what spawned clients are told.
//!
//! The build installs the phinger-cursors themes into `share/icons` next to
//! `bin/` (zig-out/ or /usr/local), which is not on libXcursor's default
//! path. `init` prepends it to XCURSOR_PATH for this process (wlroots' and
//! Xwayland's loaders) and remembers the value for children.
const std = @import("std");

/// The config value that follows the system cursor theme.
pub const system_theme = "default";

/// libXcursor's search path when XCURSOR_PATH is unset, plus /usr/local.
const default_path = "~/.local/share/icons:~/.icons:/usr/local/share/icons:/usr/share/icons:/usr/share/pixmaps";

var search_path: ?[:0]u8 = null;
/// RediWM's own `share/icons`; its themes list first in the picker.
var bundled_dir: ?[]u8 = null;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn init(allocator: std.mem.Allocator, io: std.Io) void {
    if (search_path != null) return;
    const exe_dir = std.process.executableDirPathAlloc(io, allocator) catch return;
    defer allocator.free(exe_dir);
    const icons = std.fs.path.resolve(allocator, &.{ exe_dir, "..", "share", "icons" }) catch return;
    if (bundled_dir) |old| allocator.free(old);
    bundled_dir = icons;
    const inherited = if (std.c.getenv("XCURSOR_PATH")) |p| std.mem.span(p) else default_path;
    if (containsDir(inherited, icons)) return;
    const value = std.fmt.allocPrintSentinel(allocator, "{s}:{s}", .{ icons, inherited }, 0) catch return;
    if (setenv("XCURSOR_PATH", value.ptr, 1) != 0) {
        allocator.free(value);
        return;
    }
    search_path = value;
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (search_path) |p| allocator.free(p);
    search_path = null;
    if (bundled_dir) |d| allocator.free(d);
    bundled_dir = null;
}

/// XCURSOR_PATH to hand children, or null to leave theirs alone.
pub fn childSearchPath() ?[]const u8 {
    return search_path;
}

/// The theme name wlroots should load: null means its default search
/// (XCURSOR_THEME, then "default").
pub fn managerTheme(name: []const u8) ?[]const u8 {
    if (name.len == 0 or std.mem.eql(u8, name, system_theme)) return null;
    return name;
}

pub const Theme = struct {
    /// `cursor_theme` value: the theme's directory name.
    id: []const u8,
    /// `Name=` from its index.theme, else the id.
    label: []const u8,
    /// Built with RediWM (share/icons next to the binary).
    bundled: bool = false,
};

/// Installed Xcursor themes (directories on XCURSOR_PATH with a `cursors/`
/// subdirectory): the system entry, then RediWM's bundled themes, then the
/// rest, each group sorted by label. First path
/// wins for a duplicate name, as for the loaders. Allocated in `arena`.
pub fn list(arena: std.mem.Allocator, io: std.Io) ![]Theme {
    var themes: std.ArrayList(Theme) = .empty;
    try themes.append(arena, .{ .id = system_theme, .label = "System default" });
    const path = if (std.c.getenv("XCURSOR_PATH")) |p| std.mem.span(p) else default_path;
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "";
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |raw| {
        if (raw.len == 0) continue;
        const base = if (raw[0] == '~') try std.fmt.allocPrint(arena, "{s}{s}", .{ home, raw[1..] }) else raw;
        const bundled = if (bundled_dir) |d| std.mem.eql(u8, std.mem.trimEnd(u8, base, "/"), d) else false;
        var dir = std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            // "default" is the system alias that the first entry already covers.
            if (std.mem.eql(u8, entry.name, system_theme) or entry.name[0] == '.') continue;
            if (std.mem.indexOfAny(u8, entry.name, "\"\\") != null) continue;
            if (indexOf(themes.items, entry.name) != null) continue;
            const cursors = try std.fmt.allocPrint(arena, "{s}/{s}/cursors", .{ base, entry.name });
            var cursors_dir = std.Io.Dir.cwd().openDir(io, cursors, .{}) catch continue;
            cursors_dir.close(io);
            const id = try arena.dupe(u8, entry.name);
            const index_path = try std.fmt.allocPrint(arena, "{s}/{s}/index.theme", .{ base, entry.name });
            const index = std.Io.Dir.cwd().readFileAlloc(io, index_path, arena, .limited(64 << 10)) catch "";
            try themes.append(arena, .{ .id = id, .label = themeName(index) orelse id, .bundled = bundled });
        }
    }
    std.mem.sort(Theme, themes.items[1..], {}, struct {
        fn lessThan(_: void, a: Theme, b: Theme) bool {
            if (a.bundled != b.bundled) return a.bundled;
            return std.ascii.lessThanIgnoreCase(a.label, b.label);
        }
    }.lessThan);
    return themes.items;
}

pub fn indexOf(themes: []const Theme, id: []const u8) ?usize {
    for (themes, 0..) |theme, i| {
        if (std.mem.eql(u8, theme.id, id)) return i;
    }
    return null;
}

/// `Name=` in the `[Icon Theme]` group.
fn themeName(index: []const u8) ?[]const u8 {
    var in_group = false;
    var lines = std.mem.splitScalar(u8, index, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') {
            in_group = std.mem.eql(u8, line, "[Icon Theme]");
            continue;
        }
        if (!in_group or !std.mem.startsWith(u8, line, "Name")) continue;
        const rest = std.mem.trimStart(u8, line["Name".len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        const name = std.mem.trim(u8, rest[1..], " \t");
        if (name.len > 0) return name;
    }
    return null;
}

fn containsDir(path: []const u8, dir: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |entry| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, entry, "/"), dir)) return true;
    }
    return false;
}

test "system theme keeps wlroots' default lookup" {
    try std.testing.expectEqual(@as(?[]const u8, null), managerTheme("default"));
    try std.testing.expectEqual(@as(?[]const u8, null), managerTheme(""));
    try std.testing.expectEqualStrings("phinger-cursors-dark", managerTheme("phinger-cursors-dark").?);
}

test "search path entries match with or without a trailing slash" {
    try std.testing.expect(containsDir("/a/share/icons/:/usr/share/icons", "/a/share/icons"));
    try std.testing.expect(!containsDir("/a/share/icons2", "/a/share/icons"));
}

test "theme names come from the Icon Theme group only" {
    try std.testing.expectEqualStrings("Phinger Cursors (dark)", themeName("[Icon Theme]\nName=Phinger Cursors (dark)\nComment=x\n").?);
    try std.testing.expectEqualStrings("Real", themeName("[Other]\nName=Wrong\n[Icon Theme]\nName[de]=Nein\nName = Real\n").?);
    try std.testing.expectEqual(@as(?[]const u8, null), themeName("[Icon Theme]\nInherits=Adwaita\n"));
}
