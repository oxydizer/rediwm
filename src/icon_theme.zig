// XDG icon theme lookup (freedesktop.org Icon Theme Specification), trimmed
// to what a taskbar needs: given an icon name (an app_id, by convention) and
// a target device-pixel size, walk the configured theme's Inherits chain,
// then the mandatory "hicolor" fallback theme, then the flat /usr/share/
// pixmaps directory, and return the first (or size-closest) matching file.
//
// No rasterization happens here — see icon_cache.zig for that. This module
// only touches the filesystem to probe candidate paths and read
// `index.theme` files, both of which need an explicit `std.Io` value on this
// Zig toolchain (there is no ambient/global env or file-I/O accessor).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const pthread = std.posix.system;
var index_mutex: pthread.pthread_mutex_t = pthread.PTHREAD_MUTEX_INITIALIZER;

/// Bumped by `invalidateInstalled` when icons may have been installed or
/// removed at runtime. `find` compares it, under `index_mutex`, with the
/// generation its indexes were built for and drops them lazily, so the caller
/// (the compositor thread) neither waits for the lock nor re-indexes.
var installed_generation = std.atomic.Value(u64).init(0);
var indexed_generation: u64 = 0; // guarded by index_mutex

pub const Config = struct {
    theme_name: []const u8,
    override_root: []const u8 = "",
    generation: u64 = 0,
    base_dirs: []const []const u8,
};

const icon_theme_env = "REDIWM_ICON_THEME";
const default_theme = "Adwaita";

// Called once from main.zig. `base_dirs` are icon-theme *root* directories
// (each expected to contain `<theme>/index.theme` subdirectories), built
// from $XDG_DATA_HOME/icons, $HOME/.icons, and $XDG_DATA_DIRS/icons entries.
// No file I/O here, only string-building, so no `Io` parameter is needed.
pub fn resolveConfig(allocator: Allocator, environ: std.process.Environ) !Config {
    const theme_name = environ.getPosix(icon_theme_env) orelse default_theme;

    var dirs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (dirs.items) |d| allocator.free(d);
        dirs.deinit(allocator);
    }

    if (environ.getPosix("XDG_DATA_HOME")) |data_home| {
        const trimmed = std.mem.trimEnd(u8, data_home, "/");
        try dirs.append(allocator, try std.fmt.allocPrint(allocator, "{s}/icons", .{trimmed}));
    } else if (environ.getPosix("HOME")) |home| {
        const trimmed = std.mem.trimEnd(u8, home, "/");
        try dirs.append(allocator, try std.fmt.allocPrint(allocator, "{s}/.local/share/icons", .{trimmed}));
    }

    if (environ.getPosix("HOME")) |home| {
        const trimmed = std.mem.trimEnd(u8, home, "/");
        try dirs.append(allocator, try std.fmt.allocPrint(allocator, "{s}/.icons", .{trimmed}));
    }

    const data_dirs = environ.getPosix("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = std.mem.splitScalar(u8, data_dirs, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const trimmed = std.mem.trimEnd(u8, dir, "/");
        try dirs.append(allocator, try std.fmt.allocPrint(allocator, "{s}/icons", .{trimmed}));
    }

    return .{ .theme_name = theme_name, .base_dirs = try dirs.toOwnedSlice(allocator) };
}

pub const Found = struct {
    // Null-terminated: librsvg's C API wants a plain C string, and a slice
    // coerces fine everywhere else (readFileAlloc, allocator.free, ...).
    path: [:0]u8,
    svg: bool,
    pack: bool = false,
};

const IconExt = enum { png, svg };

fn extName(ext: IconExt) []const u8 {
    return switch (ext) {
        .png => "png",
        .svg => "svg",
    };
}

const SubdirKind = enum { fixed, scalable, threshold };

const Subdir = struct {
    path: []const u8, // owned, theme-relative, e.g. "48x48/apps"
    size: i32,
    scale: i32,
    min_size: i32,
    max_size: i32,
    threshold: i32,
    kind: SubdirKind,
};

const Theme = struct {
    name: []const u8, // owned
    inherits: []const []const u8, // owned
    dirs: []const Subdir, // owned

    fn deinit(self: Theme, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.inherits) |s| allocator.free(s);
        allocator.free(self.inherits);
        for (self.dirs) |d| allocator.free(d.path);
        allocator.free(self.dirs);
    }
};

/// Flat artwork supplied by the active pack, without an installed-theme fallback.
pub fn findPack(allocator: Allocator, io: Io, cfg: Config, icon_name: []const u8) !?Found {
    if (cfg.override_root.len > 0 and @import("config").theme_pack.relative(icon_name) and std.mem.indexOfScalar(u8, icon_name, '/') == null) {
        for ([_][]const u8{ "svg", "png" }) |ext| {
            const rel = try std.fmt.allocPrint(allocator, "icons/{s}.{s}", .{ icon_name, ext });
            defer allocator.free(rel);
            if (@import("config").theme_pack.asset(allocator, io, cfg.override_root, rel)) |path| {
                defer allocator.free(path);
                return .{ .path = try allocator.dupeSentinel(u8, path, 0), .svg = std.mem.eql(u8, ext, "svg"), .pack = true };
            } else |_| {}
        }
    }
    return null;
}

// pack -> theme -> theme's Inherits (recursive, deduped) -> "hicolor"
// (mandatory fallback even if undeclared) -> flat /usr/share/pixmaps.
pub fn find(allocator: Allocator, io: Io, cfg: Config, icon_name: []const u8, target_px: i32) !?Found {
    if (try findPack(allocator, io, cfg, icon_name)) |found| return found;
    _ = pthread.pthread_mutex_lock(&index_mutex);
    defer _ = pthread.pthread_mutex_unlock(&index_mutex);
    const wanted = installed_generation.load(.acquire);
    if (wanted != indexed_generation) {
        dropIndexesLocked(allocator);
        indexed_generation = wanted;
    }
    // Every theme-name string this call ever allocates (Inherits= entries),
    // freed once at the end. `pending`/`visited` below only ever hold slices
    // borrowed from here or from `cfg.theme_name`, so nothing can dangle.
    var owned_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (owned_names.items) |n| allocator.free(n);
        owned_names.deinit(allocator);
    }

    var pending: std.ArrayList([]const u8) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, cfg.theme_name);

    var visited: std.ArrayList([]const u8) = .empty;
    defer visited.deinit(allocator);

    var found_hicolor = false;

    // A configured theme that lacks an icon (a cursor-only "default" index,
    // say) falls back to the built-in default theme and its parents.
    var queued_default = false;
    var head: usize = 0;
    while (true) : (head += 1) {
        if (head == pending.items.len) {
            if (queued_default) break;
            queued_default = true;
            try pending.append(allocator, default_theme);
        }
        const theme_name = pending.items[head];

        var already = false;
        for (visited.items) |v| {
            if (std.mem.eql(u8, v, theme_name)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        try visited.append(allocator, theme_name);
        if (std.mem.eql(u8, theme_name, "hicolor")) found_hicolor = true;

        const theme = (try themeIndex(allocator, io, cfg, theme_name)) orelse continue;

        if (try findInTheme(allocator, io, cfg, theme, icon_name, target_px)) |result| return result;

        for (theme.inherits) |parent| {
            const owned = try allocator.dupe(u8, parent);
            try owned_names.append(allocator, owned);
            try pending.append(allocator, owned);
        }
    }

    if (!found_hicolor) {
        if (try themeIndex(allocator, io, cfg, "hicolor")) |theme| {
            if (try findInTheme(allocator, io, cfg, theme, icon_name, target_px)) |result| return result;
        }
    }

    return findInPixmaps(allocator, io, icon_name);
}

// Parsed `index.theme` files, keyed by theme name; a null value records a
// theme with no readable index so repeated misses don't re-probe every base
// dir. Adwaita's index.theme is tens of KB of subdir sections and `find`
// walks the whole Inherits chain plus hicolor, so parsing per lookup cost
// ~40ms of *render-path* time on every icon-cache miss — that was the start
// menu's stutter as new rows scrolled in. One parse lasts until the theme
// configuration changes (`forgetParsedThemes`) or icons are installed at
// runtime (`invalidateInstalled`).
var parsed_themes: std.StringHashMapUnmanaged(?Theme) = .empty;

/// Borrowed from `parsed_themes`; the caller must not deinit the result.
fn themeIndex(allocator: Allocator, io: Io, cfg: Config, theme_name: []const u8) !?Theme {
    const cache_name = try std.fmt.allocPrint(allocator, "{d}:{s}", .{ cfg.generation, theme_name });
    defer allocator.free(cache_name);
    if (parsed_themes.get(cache_name)) |cached| return cached;

    const key = try allocator.dupe(u8, cache_name);
    errdefer allocator.free(key);
    const parsed = try loadThemeIndex(allocator, io, cfg, theme_name);
    errdefer if (parsed) |theme| theme.deinit(allocator);
    try parsed_themes.put(allocator, key, parsed);
    return parsed;
}

/// Drop every parsed index and file index, after the icon theme
/// configuration changed. Blocks while a lookup holds the index lock.
pub fn forgetParsedThemes(allocator: Allocator) void {
    _ = pthread.pthread_mutex_lock(&index_mutex);
    defer _ = pthread.pthread_mutex_unlock(&index_mutex);
    dropIndexesLocked(allocator);
}

/// Icons may have been installed or removed (an application was added at
/// runtime, with its icons linked into a theme directory): the next `find`
/// re-reads the theme directories. Never blocks; any thread may call it.
pub fn invalidateInstalled() void {
    _ = installed_generation.fetchAdd(1, .release);
}

/// The file indexes hold positions into the parsed indexes' directory lists,
/// so the two are always dropped together. Caller holds `index_mutex`.
fn dropIndexesLocked(allocator: Allocator) void {
    var it = parsed_themes.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        if (entry.value_ptr.*) |theme| theme.deinit(allocator);
    }
    parsed_themes.deinit(allocator);
    parsed_themes = .empty;

    var files_it = theme_files.iterator();
    while (files_it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        var files = entry.value_ptr.*;
        freeThemeFiles(allocator, &files);
    }
    theme_files.deinit(allocator);
    theme_files = .empty;
}

fn loadThemeIndex(allocator: Allocator, io: Io, cfg: Config, theme_name: []const u8) !?Theme {
    for (cfg.base_dirs) |base_dir| {
        const index_path = try std.fmt.allocPrint(allocator, "{s}/{s}/index.theme", .{ base_dir, theme_name });
        defer allocator.free(index_path);

        const contents = Io.Dir.cwd().readFileAlloc(io, index_path, allocator, .limited(1 << 20)) catch continue;
        defer allocator.free(contents);

        const parsed = try parseIndexTheme(allocator, contents);
        return Theme{
            .name = try allocator.dupe(u8, theme_name),
            .inherits = parsed.inherits,
            .dirs = parsed.dirs,
        };
    }
    return null;
}

const ParsedIndex = struct {
    inherits: []const []const u8,
    dirs: []const Subdir,
};

fn parseIndexTheme(allocator: Allocator, contents: []const u8) !ParsedIndex {
    var inherits: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (inherits.items) |s| allocator.free(s);
        inherits.deinit(allocator);
    }

    // Borrowed slices into `contents`, in declared order; not owned.
    var dir_names: std.ArrayList([]const u8) = .empty;
    defer dir_names.deinit(allocator);

    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            section = line[1..end];
            continue;
        }
        if (!std.mem.eql(u8, section, "Icon Theme")) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "Inherits")) {
            var it = std.mem.splitScalar(u8, value, ',');
            while (it.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " \t");
                if (trimmed.len == 0) continue;
                try inherits.append(allocator, try allocator.dupe(u8, trimmed));
            }
        } else if (std.mem.eql(u8, key, "Directories") or std.mem.eql(u8, key, "ScaledDirectories")) {
            var it = std.mem.splitScalar(u8, value, ',');
            while (it.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " \t");
                if (trimmed.len == 0) continue;
                try dir_names.append(allocator, trimmed);
            }
        }
    }

    var dirs: std.ArrayList(Subdir) = .empty;
    errdefer {
        for (dirs.items) |d| allocator.free(d.path);
        dirs.deinit(allocator);
    }
    // Index section offsets once. Re-scanning the entire file for every
    // directory makes large themes quadratic, blocking the compositor when
    // the start menu resolves its application icons.
    var sections: std.StringHashMapUnmanaged(usize) = .empty;
    defer sections.deinit(allocator);
    var offset: usize = 0;
    var section_lines = std.mem.splitScalar(u8, contents, '\n');
    while (section_lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len > 0 and line[0] == '[') {
            if (std.mem.indexOfScalar(u8, line, ']')) |end| {
                const entry = try sections.getOrPut(allocator, line[1..end]);
                if (!entry.found_existing) entry.value_ptr.* = offset;
            }
        }
        offset += raw_line.len + 1;
    }
    for (dir_names.items) |name| {
        const start = sections.get(name) orelse continue;
        if (try parseSubdirSection(allocator, contents[start..], name)) |subdir| {
            try dirs.append(allocator, subdir);
        }
    }

    return .{
        .inherits = try inherits.toOwnedSlice(allocator),
        .dirs = try dirs.toOwnedSlice(allocator),
    };
}

fn parseSubdirSection(allocator: Allocator, contents: []const u8, name: []const u8) !?Subdir {
    var found = false;
    var size: i32 = 0;
    var scale: i32 = 1;
    var min_size: i32 = -1;
    var max_size: i32 = -1;
    var threshold: i32 = 2;
    var kind: SubdirKind = .threshold;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            if (found) break; // a new section ends ours
            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            found = std.mem.eql(u8, line[1..end], name);
            continue;
        }
        if (!found) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "Size")) {
            size = std.fmt.parseInt(i32, value, 10) catch size;
        } else if (std.mem.eql(u8, key, "Scale")) {
            scale = std.fmt.parseInt(i32, value, 10) catch scale;
        } else if (std.mem.eql(u8, key, "MinSize")) {
            min_size = std.fmt.parseInt(i32, value, 10) catch min_size;
        } else if (std.mem.eql(u8, key, "MaxSize")) {
            max_size = std.fmt.parseInt(i32, value, 10) catch max_size;
        } else if (std.mem.eql(u8, key, "Threshold")) {
            threshold = std.fmt.parseInt(i32, value, 10) catch threshold;
        } else if (std.mem.eql(u8, key, "Type")) {
            if (std.mem.eql(u8, value, "Fixed"))
                kind = .fixed
            else if (std.mem.eql(u8, value, "Scalable"))
                kind = .scalable
            else
                kind = .threshold;
        }
    }
    if (!found) return null;
    if (min_size < 0) min_size = size;
    if (max_size < 0) max_size = size;

    return .{
        .path = try allocator.dupe(u8, name),
        .size = size,
        .scale = if (scale <= 0) 1 else scale,
        .min_size = min_size,
        .max_size = max_size,
        .threshold = threshold,
        .kind = kind,
    };
}

fn matchesSize(subdir: Subdir, target_px: i32) bool {
    return switch (subdir.kind) {
        .fixed => subdir.size * subdir.scale == target_px,
        .scalable => target_px >= subdir.min_size * subdir.scale and target_px <= subdir.max_size * subdir.scale,
        .threshold => {
            const diff = subdir.size * subdir.scale - target_px;
            const adiff = if (diff < 0) -diff else diff;
            return adiff <= subdir.threshold * subdir.scale;
        },
    };
}

fn sizeDistance(subdir: Subdir, target_px: i32) i32 {
    const effective_min = (if (subdir.kind == .scalable) subdir.min_size else subdir.size) * subdir.scale;
    const effective_max = (if (subdir.kind == .scalable) subdir.max_size else subdir.size) * subdir.scale;
    if (target_px < effective_min) return effective_min - target_px;
    if (target_px > effective_max) return target_px - effective_max;
    return 0;
}

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

/// Where one icon file sits inside a theme: which of the theme's declared
/// subdirectories holds it, which base dir that subdirectory came from, and
/// whether it is the .svg or the .png. Indices, not strings, so the whole
/// index for a theme stays small.
const Candidate = struct {
    dir: u32,
    base: u32,
    svg: bool,

    /// The order `findInTheme` used to probe in: theme-declared subdirectory
    /// order first, then .png before .svg, then base-dir order. Ranking the
    /// candidates by it picks exactly the file the probe loop would have.
    fn before(a: Candidate, b: Candidate) bool {
        if (a.dir != b.dir) return a.dir < b.dir;
        if (a.svg != b.svg) return !a.svg;
        return a.base < b.base;
    }
};

/// Every icon file in one theme, keyed by name without extension. Built by
/// reading each of the theme's subdirectories once.
///
/// An icon that isn't in the current theme has to be looked for in every
/// subdirectory of every theme in the Inherits chain, and hicolor alone is
/// ~700 directories here — as one access() per candidate path that was
/// thousands of syscalls per icon, and even as a cached directory listing it
/// was thousands of hash lookups. Indexing the theme once turns any lookup,
/// hit or miss, into a single one. That was the last of the start menu's
/// scroll stutter: every newly revealed row is a fresh icon name.
///
/// Same lifetime as `parsed_themes`, and dropped with it: icons installed
/// while the compositor runs appear only after `invalidateInstalled`.
const ThemeFiles = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Candidate));
var theme_files: std.StringHashMapUnmanaged(ThemeFiles) = .empty;

fn themeIndex_(allocator: Allocator, io: Io, cfg: Config, theme: Theme) !ThemeFiles {
    if (theme_files.get(theme.name)) |cached| return cached;

    var files: ThemeFiles = .empty;
    errdefer freeThemeFiles(allocator, &files);

    var dir_buf: [std.posix.PATH_MAX]u8 = undefined;
    for (theme.dirs, 0..) |subdir, dir_index| {
        for (cfg.base_dirs, 0..) |base_dir, base_index| {
            const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/{s}/{s}", .{ base_dir, theme.name, subdir.path }) catch continue;
            var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(io);

            var it = dir.iterate();
            while (it.next(io) catch null) |entry| {
                const svg = std.mem.endsWith(u8, entry.name, ".svg");
                if (!svg and !std.mem.endsWith(u8, entry.name, ".png")) continue;
                const stem = entry.name[0 .. entry.name.len - 4];

                const gop = try files.getOrPut(allocator, stem);
                if (!gop.found_existing) {
                    gop.key_ptr.* = allocator.dupe(u8, stem) catch {
                        _ = files.remove(stem);
                        continue;
                    };
                    gop.value_ptr.* = .empty;
                }
                try gop.value_ptr.append(allocator, .{
                    .dir = @intCast(dir_index),
                    .base = @intCast(base_index),
                    .svg = svg,
                });
            }
        }
    }

    const key = try allocator.dupe(u8, theme.name);
    errdefer allocator.free(key);
    try theme_files.put(allocator, key, files);
    return files;
}

fn freeThemeFiles(allocator: Allocator, files: *ThemeFiles) void {
    var it = files.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    files.deinit(allocator);
}

fn findInTheme(allocator: Allocator, io: Io, cfg: Config, theme: Theme, icon_name: []const u8, target_px: i32) !?Found {
    const files = try themeIndex_(allocator, io, cfg, theme);
    const candidates = files.get(icon_name) orelse return null;

    // A size match wins outright, exactly as the probe loop's early return
    // did; failing that the closest size wins, ties going to whichever the
    // probe order would have reached first.
    var sized: ?Candidate = null;
    var nearest: ?Candidate = null;
    var nearest_distance: i32 = std.math.maxInt(i32);

    for (candidates.items) |candidate| {
        const subdir = theme.dirs[candidate.dir];
        if (matchesSize(subdir, target_px)) {
            if (sized == null or candidate.before(sized.?)) sized = candidate;
            continue;
        }
        const distance = sizeDistance(subdir, target_px);
        if (distance < nearest_distance or (distance == nearest_distance and nearest != null and candidate.before(nearest.?))) {
            nearest = candidate;
            nearest_distance = distance;
        }
    }

    const chosen = sized orelse nearest orelse return null;
    const subdir = theme.dirs[chosen.dir];
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}/{s}/{s}.{s}", .{
        cfg.base_dirs[chosen.base],
        theme.name,
        subdir.path,
        icon_name,
        if (chosen.svg) "svg" else "png",
    }, 0);
    return Found{ .path = path, .svg = chosen.svg };
}

// Spec fallback of last resort: a single flat directory, no size matching.
fn findInPixmaps(allocator: Allocator, io: Io, icon_name: []const u8) !?Found {
    for ([_]IconExt{ .png, .svg }) |ext| {
        const candidate = try std.fmt.allocPrintSentinel(allocator, "/usr/share/pixmaps/{s}.{s}", .{ icon_name, extName(ext) }, 0);
        if (fileExists(io, candidate)) return Found{ .path = candidate, .svg = ext == .svg };
        allocator.free(candidate);
    }
    return null;
}

test "theme section index preserves declared order and first duplicate" {
    const allocator = std.testing.allocator;
    const parsed = try parseIndexTheme(allocator,
        \\[Icon Theme]
        \\Directories=large,missing,small
        \\[small]
        \\Size=16
        \\Type=Fixed
        \\[large]
        \\Size=48
        \\Type=Scalable
        \\MinSize=32
        \\MaxSize=64
        \\[large]
        \\Size=128
    );
    defer {
        for (parsed.inherits) |name| allocator.free(name);
        allocator.free(parsed.inherits);
        for (parsed.dirs) |dir| allocator.free(dir.path);
        allocator.free(parsed.dirs);
    }
    try std.testing.expectEqual(@as(usize, 2), parsed.dirs.len);
    try std.testing.expectEqualStrings("large", parsed.dirs[0].path);
    try std.testing.expectEqual(@as(i32, 48), parsed.dirs[0].size);
    try std.testing.expectEqual(@as(i32, 32), parsed.dirs[0].min_size);
    try std.testing.expectEqual(@as(i32, 64), parsed.dirs[0].max_size);
    try std.testing.expectEqualStrings("small", parsed.dirs[1].path);
    try std.testing.expectEqual(@as(i32, 16), parsed.dirs[1].size);
}

/// Installed icon-theme names for the explicit Appearance picker.
pub fn listNames(a: Allocator, io: Io, cfg: Config) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(a, "");
    for (cfg.base_dirs) |base| {
        var dir = Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory or !@import("config").theme_pack.relative(entry.name)) continue;
            var found = false;
            for (out.items) |name| if (std.mem.eql(u8, name, entry.name)) {
                found = true;
            };
            if (found) continue;
            const index = try std.fs.path.join(a, &.{ base, entry.name, "index.theme" });
            Io.Dir.cwd().access(io, index, .{}) catch continue;
            try out.append(a, try a.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, out.items[1..], {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(x, y);
        }
    }.less);
    return out.toOwnedSlice(a);
}

/// XDG special-directory identity, shared by Files and the desktop. Call at
/// scan time so reading user-dirs.dirs never enters the paint path.
pub fn folderName(a: Allocator, io: Io, env: std.process.Environ, path: []const u8) []const u8 {
    const home = env.getPosix("HOME") orelse return "folder";
    if (std.mem.eql(u8, path, home)) return "user-home";
    const data = env.getPosix("XDG_DATA_HOME") orelse (std.fs.path.join(a, &.{ home, ".local/share" }) catch return "folder");
    const trash = std.fs.path.join(a, &.{ data, "Trash/files" }) catch return "folder";
    if (std.mem.eql(u8, path, trash)) return "user-trash";
    const config_home = env.getPosix("XDG_CONFIG_HOME") orelse (std.fs.path.join(a, &.{ home, ".config" }) catch return "folder");
    const file = std.fs.path.join(a, &.{ config_home, "user-dirs.dirs" }) catch return "folder";
    const bytes = Io.Dir.cwd().readFileAlloc(io, file, a, .limited(64 * 1024)) catch "";
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = @import("ui").theme.unquote(std.mem.trim(u8, line[eq + 1 ..], " \t")) catch continue;
        const full = if (std.mem.startsWith(u8, value, "$HOME/")) (std.fs.path.join(a, &.{ home, value[6..] }) catch continue) else value;
        if (!std.mem.eql(u8, path, full)) continue;
        const keys = [_][]const u8{ "XDG_DESKTOP_DIR", "XDG_DOCUMENTS_DIR", "XDG_DOWNLOAD_DIR", "XDG_MUSIC_DIR", "XDG_PICTURES_DIR", "XDG_VIDEOS_DIR", "XDG_TEMPLATES_DIR", "XDG_PUBLICSHARE_DIR" };
        const names = [_][]const u8{ "user-desktop", "folder-documents", "folder-download", "folder-music", "folder-pictures", "folder-videos", "folder-templates", "folder-publicshare" };
        for (keys, names) |k, name| if (std.mem.eql(u8, key, k)) return name;
    }
    return "folder";
}
