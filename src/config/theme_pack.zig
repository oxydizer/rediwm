//! Theme directories and legacy TOML presets. All returned memory belongs to
//! the caller's arena. Discovery is explicit: startup, reload, or picker open.
const std = @import("std");
const theme = @import("ui").theme;
const presets = @import("ui").theme_presets;
const A = std.mem.Allocator;
const Io = std.Io;
const TaskbarItems = @import("taskbar_items.zig").Config;

/// Only appearance-related layout defaults belong to packs. User overrides
/// remain in [compositor]; packs cannot inject other compositor settings.
pub const Layout = struct {
    taskbar_position: ?@import("types.zig").TaskbarPosition = null,
    taskbar_alignment: ?@import("types.zig").TaskbarAlignment = null,
    /// Which section (left, centre or right) each taskbar item sits in, in
    /// what order and whether it shows: the `[compositor]` list's own syntax.
    taskbar_items: ?TaskbarItems = null,
    dock_enabled: ?bool = null,
    dock_position: ?@import("types.zig").DockPosition = null,
    dock_height: ?u32 = null,
    dock_hover_zoom: ?f32 = null,

    pub const keys = .{ "taskbar_position", "taskbar_alignment", "taskbar_items", "dock_enabled", "dock_position", "dock_height", "dock_hover_zoom" };

    pub fn apply(self: Layout, compositor: anytype) void {
        inline for (keys) |key| if (@field(self, key)) |value| {
            @field(compositor, key) = value;
        };
    }

    fn parseKey(self: *Layout, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, key, "taskbar_position")) {
            self.taskbar_position = std.meta.stringToEnum(@import("types.zig").TaskbarPosition, try theme.unquote(value)) orelse return error.InvalidLayout;
        } else if (std.mem.eql(u8, key, "taskbar_alignment")) {
            self.taskbar_alignment = std.meta.stringToEnum(@import("types.zig").TaskbarAlignment, try theme.unquote(value)) orelse return error.InvalidLayout;
        } else if (std.mem.eql(u8, key, "taskbar_items")) {
            self.taskbar_items = TaskbarItems.parse(value) catch return error.InvalidLayout;
        } else if (std.mem.eql(u8, key, "dock_enabled")) {
            self.dock_enabled = if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else return error.InvalidLayout;
        } else if (std.mem.eql(u8, key, "dock_position")) {
            self.dock_position = std.meta.stringToEnum(@import("types.zig").DockPosition, try theme.unquote(value)) orelse return error.InvalidLayout;
        } else if (std.mem.eql(u8, key, "dock_height")) {
            const height = std.fmt.parseInt(u32, value, 10) catch return error.InvalidLayout;
            if (height < 48 or height > 96) return error.InvalidLayout;
            self.dock_height = height;
        } else if (std.mem.eql(u8, key, "dock_hover_zoom")) {
            const zoom = std.fmt.parseFloat(f32, value) catch return error.InvalidLayout;
            if (!std.math.isFinite(zoom) or zoom < 1 or zoom > 1.5) return error.InvalidLayout;
            self.dock_hover_zoom = zoom;
        } else return error.InvalidLayout;
    }

    pub fn write(a: A, bytes: *std.ArrayList(u8), compositor: anytype) !void {
        const items = try compositor.taskbar_items.serialize(a);
        defer a.free(items);
        const text = try std.fmt.allocPrint(a, "[layout]\ntaskbar_position = \"{s}\"\ntaskbar_alignment = \"{s}\"\ntaskbar_items = {s}\ndock_enabled = {}\ndock_position = \"{s}\"\ndock_height = {d}\ndock_hover_zoom = {d}\n", .{
            @tagName(compositor.taskbar_position), @tagName(compositor.taskbar_alignment), items, compositor.dock_enabled, @tagName(compositor.dock_position), compositor.dock_height, compositor.dock_hover_zoom,
        });
        defer a.free(text);
        try bytes.appendSlice(a, text);
    }
};

pub const Pack = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8 = "",
    author: []const u8 = "",
    license: []const u8 = "",
    description: []const u8 = "",
    root: []const u8 = "",
    bytes: []const u8,
    tokens: theme.Theme = .{},
    taskbar: ?theme.Theme = null,
    layout: Layout = .{},
    wallpaper: []const u8 = "",
    color_scheme: ?bool = null,
    icon_theme: []const u8 = "",
    cursor_theme: []const u8 = "",
    user_installed: bool = false,
};

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| if (!(ch >= 'a' and ch <= 'z') and !(ch >= '0' and ch <= '9') and ch != '-') return false;
    return true;
}

pub fn relative(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfAny(u8, path, "\\\x00\"\n\r\t:") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    return true;
}

/// Reject symlinks in every component, including the pack root.
pub fn asset(a: A, io: Io, root: []const u8, path: []const u8) ![]const u8 {
    if (!relative(path)) return error.UnsafeAssetPath;
    const full = try std.fs.path.join(a, &.{ root, path });
    errdefer a.free(full);
    var i: usize = 1;
    while (i <= full.len) : (i += 1) {
        if (i != full.len and full[i] != '/') continue;
        const stat = try Io.Dir.cwd().statFile(io, full[0..i], .{ .follow_symlinks = false });
        if (stat.kind == .sym_link) return error.UnsafeAssetPath;
    }
    return full;
}

pub fn parse(a: A, bytes: []const u8, fallback_id: []const u8, root: []const u8) !Pack {
    var p: Pack = .{ .id = fallback_id, .name = fallback_id, .root = root, .bytes = bytes };
    var unknown_keys: usize = 0;
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = theme.stripComment(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (line[line.len - 1] != ']') return error.InvalidPack;
            section = line[1 .. line.len - 1];
            if (std.mem.eql(u8, section, "taskbar_theme")) p.taskbar = .{};
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidPack;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, section, "meta")) {
            if (std.mem.eql(u8, key, "format")) {
                if ((std.fmt.parseInt(u32, value, 10) catch return error.InvalidPack) != 1) return error.UnsupportedPackFormat;
            } else inline for (.{ "id", "name", "version", "author", "license", "description" }) |field| {
                if (std.mem.eql(u8, key, field)) {
                    const text = try theme.unquote(value);
                    const limit: usize = if (std.mem.eql(u8, field, "description")) 4096 else 256;
                    if (text.len > limit) return error.InvalidMetadata;
                    if (std.mem.eql(u8, field, "id") and !validId(text)) return error.InvalidPackId;
                    @field(p, field) = try a.dupe(u8, text);
                }
            }
        } else if (std.mem.eql(u8, section, "theme")) {
            if (std.mem.eql(u8, key, "base")) return error.RecursiveThemeBase;
            if (std.mem.eql(u8, key, "start_button_icon") and root.len > 0) {
                const path = try theme.unquote(value);
                if (path.len > 0) {
                    if (!relative(path)) return error.UnsafeAssetPath;
                    p.tokens.start_button_icon = try std.fs.path.join(a, &.{ root, path });
                }
            } else {
                if (!theme.knownKey(key)) {
                    if (unknown_keys < 16) std.log.warn("theme pack '{s}': skipping unknown key '{s}'", .{ p.id, key[0..@min(128, key.len)] });
                    unknown_keys += 1;
                }
                try theme.applyKey(a, &p.tokens, key, value);
            }
        } else if (std.mem.eql(u8, section, "taskbar_theme")) {
            _ = try theme.applyTaskbarKey(a, &p.taskbar.?, key, value);
        } else if (std.mem.eql(u8, section, "layout")) {
            try p.layout.parseKey(key, value);
        } else if (std.mem.eql(u8, section, "assets")) {
            const text = try theme.unquote(value);
            if (std.mem.eql(u8, key, "color_scheme")) {
                p.color_scheme = if (std.mem.eql(u8, text, "dark")) true else if (std.mem.eql(u8, text, "light")) false else return error.InvalidColorScheme;
            } else inline for (.{ "wallpaper", "icon_theme", "cursor_theme" }) |field| {
                if (std.mem.eql(u8, key, field)) {
                    if (text.len > 0 and !relative(text)) return error.UnsafeAssetPath;
                    @field(p, field) = try a.dupe(u8, text);
                }
            }
        }
    }
    if (p.tokens.font.len > 256 or p.tokens.mono_font.len > 256) return error.InvalidFontName;
    if (!validId(p.id) or p.name.len == 0) return error.InvalidPackId;
    return p;
}

pub fn userDir(a: A, env: std.process.Environ) ![]const u8 {
    if (env.getPosix("XDG_DATA_HOME")) |path| if (std.fs.path.isAbsolute(path)) return std.fs.path.join(a, &.{ path, "rediwm/themes" });
    return std.fs.path.join(a, &.{ env.getPosix("HOME") orelse return error.NoHome, ".local/share/rediwm/themes" });
}

fn append(out: *std.ArrayList(Pack), a: A, p: Pack) !void {
    for (out.items) |old| if (std.mem.eql(u8, old.id, p.id)) return;
    try out.append(a, p);
}

fn scan(out: *std.ArrayList(Pack), a: A, io: Io, path: []const u8, legacy: bool, user: bool) !void {
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.name[0] == '.') continue;
        if (legacy) {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".toml")) continue;
        } else if (e.kind != .directory) continue;
        try names.append(a, try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    for (names.items) |name| {
        const root = if (legacy) "" else try std.fs.path.join(a, &.{ path, name });
        const file = try std.fs.path.join(a, &.{ path, name, if (legacy) "" else "theme.toml" });
        const bytes = Io.Dir.cwd().readFileAlloc(io, file, a, .limited(1 << 20)) catch continue;
        const stem = if (legacy) name[0 .. name.len - 5] else name;
        const id = if (legacy) try legacyId(a, stem) else name;
        var p = parse(a, bytes, id, root) catch |err| {
            std.log.warn("theme pack '{s}': {s}", .{ file, @errorName(err) });
            continue;
        };
        // Directory identity must agree with metadata for deterministic lookup.
        if (!legacy and !std.mem.eql(u8, p.id, name)) continue;
        if (legacy and std.mem.eql(u8, p.name, id)) p.name = stem;
        p.user_installed = user;
        if (p.tokens.start_button_icon.len > 0 and root.len > 0) {
            const rel = p.tokens.start_button_icon[root.len + 1 ..];
            p.tokens.start_button_icon = asset(a, io, root, rel) catch "";
        }
        try append(out, a, p);
    }
}

pub fn list(a: A, io: Io, env: std.process.Environ, config_path: []const u8) ![]Pack {
    var out: std.ArrayList(Pack) = .empty;
    if (userDir(a, env)) |dir| try scan(&out, a, io, dir, false, true) else |_| {}
    if (std.fs.path.dirname(config_path)) |dir| try scan(&out, a, io, try std.fs.path.join(a, &.{ dir, "themes" }), true, false);
    if (std.process.executableDirPathAlloc(io, a)) |exe| try scan(&out, a, io, try std.fs.path.resolve(a, &.{ exe, "../share/rediwm/themes" }), false, false) else |_| {}
    var dirs = std.mem.splitScalar(u8, env.getPosix("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share", ':');
    while (dirs.next()) |dir| if (std.fs.path.isAbsolute(dir)) try scan(&out, a, io, try std.fs.path.join(a, &.{ dir, "rediwm/themes" }), false, false);
    for (presets.bundled) |p| try append(&out, a, try parse(a, p.bytes, p.id, ""));
    // The display names of embedded packs predate metadata.
    for (out.items) |*p| if (p.root.len == 0) {
        for (presets.bundled) |b| if (p.bytes.ptr == b.bytes.ptr) {
            p.name = b.name;
        };
    };
    return out.toOwnedSlice(a);
}

/// Packs that still load (so a config naming one keeps its look) but are not
/// offered in the picker, unless one is the active theme. Uncomment to offer
/// them again.
const picker_hidden = [_][]const u8{
    "redi-mocha",
    "gold",
};

/// `list` minus `picker_hidden`; the active pack always stays so the picker
/// shows what is applied. Lookup (`find`, config load, IPC) is unaffected.
pub fn pickerList(a: A, io: Io, env: std.process.Environ, config_path: []const u8, active: []const u8) ![]Pack {
    var out: std.ArrayList(Pack) = .empty;
    for (try list(a, io, env, config_path)) |p| {
        const hidden = for (picker_hidden) |id| {
            if (std.mem.eql(u8, id, p.id)) break true;
        } else false;
        if (!hidden or std.mem.eql(u8, p.id, active)) try out.append(a, p);
    }
    return out.toOwnedSlice(a);
}

pub fn find(a: A, io: Io, env: std.process.Environ, config_path: []const u8, id: []const u8) !?Pack {
    if (!validId(id)) return error.InvalidPackId;
    for (try list(a, io, env, config_path)) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}

test "pack metadata, future tokens and unsafe paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parse(a, "[meta]\nformat = 1\nname = \"Nord\"\n[theme]\naccent = \"#88c0d0\"\nfuture_token = 42\nstart_button_icon = \"logo.svg\"\n[assets]\ncolor_scheme = \"dark\"\n", "nord", "/tmp/nord");
    try std.testing.expectEqualStrings("Nord", p.name);
    try std.testing.expectEqualStrings("/tmp/nord/logo.svg", p.tokens.start_button_icon);
    try std.testing.expect(p.color_scheme.?);
    try std.testing.expectError(error.UnsupportedPackFormat, parse(a, "[meta]\nformat = 2", "nord", ""));
    try std.testing.expectError(error.UnsafeAssetPath, parse(a, "[theme]\nstart_button_icon = \"../logo.svg\"", "nord", "/tmp/nord"));
    for ([_][]const u8{ "../x", "/x", "x//y", "x/./y", "x\\y" }) |path| try std.testing.expect(!relative(path));
    try std.testing.expect(!validId("../nord"));
    inline for (.{ "top", "bottom", "left", "right" }) |position| {
        const pack = try parse(a, "[layout]\ndock_position = \"" ++ position ++ "\"\n", "test", "");
        var compositor = @import("loader.zig").CompositorConfig{};
        pack.layout.apply(&compositor);
        try std.testing.expectEqualStrings(position, @tagName(compositor.dock_position));
        var bytes: std.ArrayList(u8) = .empty;
        try Layout.write(a, &bytes, compositor);
        const exported = try parse(a, bytes.items, "test", "");
        try std.testing.expectEqual(pack.layout.dock_position, exported.layout.dock_position);
    }
    inline for (.{ "left", "center", "right" }) |alignment| {
        const pack = try parse(a, "[layout]\ntaskbar_alignment = \"" ++ alignment ++ "\"\n", "test", "");
        var compositor = @import("loader.zig").CompositorConfig{};
        pack.layout.apply(&compositor);
        try std.testing.expectEqualStrings(alignment, @tagName(compositor.taskbar_alignment));
        var bytes: std.ArrayList(u8) = .empty;
        try Layout.write(a, &bytes, compositor);
        const exported = try parse(a, bytes.items, "test", "");
        try std.testing.expectEqual(pack.layout.taskbar_alignment, exported.layout.taskbar_alignment);
    }
    {
        // A pack arranges the taskbar's items, and an export carries them.
        const pack = try parse(a, "[layout]\ntaskbar_items = [\"left:start\", \"left:windows\", \"-center:tray\", \"right:battery\", \"right:network\", \"right:volume\", \"center:clock\"]\n", "test", "");
        const arranged = pack.layout.taskbar_items.?;
        try std.testing.expectEqual(@import("taskbar_items.zig").Section.left, arranged.section(.windows));
        try std.testing.expectEqual(@import("taskbar_items.zig").Section.center, arranged.section(.clock));
        try std.testing.expect(!arranged.shown(.tray));
        var compositor = @import("loader.zig").CompositorConfig{};
        pack.layout.apply(&compositor);
        try std.testing.expectEqualDeep(arranged, compositor.taskbar_items);
        var bytes: std.ArrayList(u8) = .empty;
        try Layout.write(a, &bytes, compositor);
        const exported = try parse(a, bytes.items, "test", "");
        try std.testing.expectEqualDeep(arranged, exported.layout.taskbar_items.?);
        // No list leaves the user's own arrangement alone.
        try std.testing.expectEqual(@as(?TaskbarItems, null), (try parse(a, "[layout]\ntaskbar_position = \"top\"\n", "test", "")).layout.taskbar_items);
    }
    for ([_][]const u8{ "taskbar_items = []", "taskbar_items = [\"left:start\"]", "taskbar_items = [\"middle:start\", \"windows\", \"tray\", \"battery\", \"network\", \"volume\", \"clock\"]", "taskbar_items = \"left:start\"" }) |line| {
        const bytes = try std.fmt.allocPrint(a, "[layout]\n{s}\n", .{line});
        try std.testing.expectError(error.InvalidLayout, parse(a, bytes, "test", ""));
    }
    for ([_][]const u8{ "dock_height = 47", "dock_height = 97", "dock_hover_zoom = 0.99", "dock_hover_zoom = 1.51", "dock_hover_zoom = nan", "dock_enabled = 1", "dock_position = \"center\"", "taskbar_position = \"left\"", "xwayland = true" }) |line| {
        const bytes = try std.fmt.allocPrint(a, "[layout]\n{s}\n", .{line});
        try std.testing.expectError(error.InvalidLayout, parse(a, bytes, "test", ""));
    }
}

fn legacyId(a: A, name: []const u8) ![]const u8 {
    const id = try a.dupe(u8, name);
    for (id) |*ch| {
        ch.* = std.ascii.toLower(ch.*);
        if (!(ch.* >= 'a' and ch.* <= 'z') and !(ch.* >= '0' and ch.* <= '9')) ch.* = '-';
    }
    return id;
}

test "embedded packs retain their palettes and saving keeps only overrides" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for (presets.bundled) |b| {
        const p = try parse(arena.allocator(), b.bytes, b.id, "");
        try std.testing.expect(@import("loader.zig").themeEql(try theme.parse(arena.allocator(), b.bytes), p.tokens));
        var edited = p.tokens;
        edited.font_size += 1;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try theme.writeOverrides(a, &out, edited, p.tokens, p.id);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "base =") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "font_size =") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "accent =") == null);
        var restored = p.tokens;
        try theme.overlay(arena.allocator(), &restored, out.items);
        try std.testing.expect(@import("loader.zig").themeEql(edited, restored));
    }
}

test "discovery order deduplicates IDs and legacy filenames keep display names" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.createDirPath(io, "data/rediwm/themes/collision");
    try tmp.dir.createDirPath(io, "config/themes");
    try tmp.dir.createDirPath(io, "system/rediwm/themes/collision");
    try tmp.dir.writeFile(io, .{ .sub_path = "data/rediwm/themes/collision/theme.toml", .data = "[meta]\nname = \"User\"\n[theme]\nfont_size = 14\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "config/themes/collision.toml", .data = "[theme]\nfont_size = 15\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "config/themes/My Theme.toml", .data = "[theme]\nfont_size = 16\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "system/rediwm/themes/collision/theme.toml", .data = "[theme]\nfont_size = 17\n" });
    const data = try std.fmt.allocPrintSentinel(a, "XDG_DATA_HOME={s}/data", .{root}, 0);
    const system = try std.fmt.allocPrintSentinel(a, "XDG_DATA_DIRS={s}/system", .{root}, 0);
    const entries = [_:null]?[*:0]const u8{ data.ptr, system.ptr };
    const env: std.process.Environ = .{ .block = .{ .slice = &entries } };
    const config_path = try std.fs.path.join(a, &.{ root, "config/config.toml" });
    const items = try list(a, io, env, config_path);
    var count: usize = 0;
    for (items) |p| {
        if (std.mem.eql(u8, p.id, "collision")) {
            count += 1;
            try std.testing.expectEqual(@as(f32, 14), p.tokens.font_size);
        }
        if (std.mem.eql(u8, p.id, "my-theme")) try std.testing.expectEqualStrings("My Theme", p.name);
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    const legacy = (try find(a, io, env, config_path, "my-theme")).?;
    try std.testing.expectEqual(@as(f32, 16), legacy.tokens.font_size);
}

test "asset resolution refuses symlinks and frees failed paths" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "logo.svg", .data = "svg" });
    try tmp.dir.symLink(io, "logo.svg", "alias.svg", .{});
    try std.testing.expectError(error.UnsafeAssetPath, asset(a, io, root, "alias.svg"));
    try std.testing.expectError(error.FileNotFound, asset(a, io, root, "missing.svg"));
    const path = try asset(a, io, root, "logo.svg");
    defer a.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/logo.svg"));
}
