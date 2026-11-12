//! Appearance wallpaper strip: tiles, folder choice, thumbnails and teardown.

const i18n = @import("i18n");
const std = @import("std");
const Server = @import("../../Server.zig");
const layout = @import("ui").layout;
const theme = @import("ui").theme;
const scrollbar = @import("ui").widgets.scrollbar;
const Widget = layout.Widget;
const main = @import("../../main.zig");
const panel = @import("../panel.zig");
const setting_save = @import("config").setting_save;
const wallpapers = @import("../../wallpapers.zig");
const wallpaper_strip = @import("../../wallpaper_strip.zig");
const folder_picker = @import("../folder_picker.zig");
const wl = @import("wayland").server.wl;
const section = @import("appearance_dock.zig").section;
const segmented_width = @import("appearance.zig").segmented_width;
const Section = @import("appearance.zig").Section;
const labelWidget = @import("appearance.zig").labelWidget;
const strip_index = @import("appearance.zig").strip_index;

pub const tile_w: f32 = wallpaper_strip.thumb_width / 2;
pub const tile_h: f32 = wallpaper_strip.thumb_height / 2;
pub const tile_pad: f32 = 3;
pub const tile_extent = tile_w + 2 * tile_pad;
pub const strip_gap: f32 = 8;
pub const check_size: f32 = 18;

/// A folder picked with "Choose folder" this session, gpa-owned.
pub var chosen_dir: ?[]u8 = null;

/// The folder the strip shows: the chosen one, else where a wallpaper set by
/// path lives. Null means the wallpaper directories' own images.
pub fn stripFolder(arena: std.mem.Allocator, io: std.Io, configured: []const u8) ?[]const u8 {
    if (chosen_dir) |dir| return dir;
    if (!wallpapers.isPath(configured)) return null;
    const path = wallpapers.resolve(arena, io, configured) catch return null;
    const dir = std.fs.path.dirname(path) orelse return null;
    for ([_]?[]const u8{ wallpapers.userDir(arena) catch null, wallpapers.bundledDir(arena, io) catch null }) |own| {
        if (own) |o| if (std.mem.eql(u8, o, dir)) return null;
    }
    return dir;
}

/// `/home/me/x` as `~/x`.
pub fn tildePath(arena: std.mem.Allocator, path: []const u8) []const u8 {
    const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "";
    if (home.len > 1 and std.mem.startsWith(u8, path, home) and path.len > home.len and path[home.len] == '/')
        return std.fmt.allocPrint(arena, "~{s}", .{path[home.len..]}) catch path;
    return path;
}

pub fn stopStrip(out: *Section) void {
    if (out.strip_source) |source| source.remove();
    out.strip_source = null;
    if (out.strip) |strip| strip.deinit();
    out.strip = null;
}

pub fn deinit(out: *Section) void {
    stopStrip(out);
    if (out.theme_pending_path) |p| main.gpa.free(p);
    out.theme_pending_path = null;
}

/// Thumbnails arrive one by one; each goes into its tile in the shown strip
/// and repaints that tile alone. A later build reads them from the strip.
pub fn stripWake(_: c_int, _: wl.EventMask, out: *Section) c_int {
    const strip = out.strip orelse return 0;
    strip.drain();
    const cc = out.cc.server.input.open_control_center orelse return 0;
    if (cc != out.cc or cc.page != .appearance or !out.strip_built) return 0;
    const container = &out.wallpaper_children[strip_index];
    if (container.kind != .scroll_container) return 0;
    for (container.children, 0..) |*tile, i| {
        const image = &tile.children[0];
        if (image.kind != .image or image.kind.image.pixels != null) continue;
        image.kind.image.pixels = strip.thumb(i) orelse continue;
        image.markPaintDirty();
    }
    cc.requestWidgetRepaint();
    return 0;
}

pub fn restartStrip(out: *Section, server: *@import("../../Server.zig")) void {
    stopStrip(out);
    if (out.strip_entries.len == 0) return;
    const strip = wallpaper_strip.Strip.start(main.gpa, server.io, out.strip_entries) catch |err| {
        std.log.warn("wallpaper strip: {}", .{err});
        return;
    };
    out.strip = strip;
    out.strip_source = server.wl_server.getEventLoop().addFd(*Section, strip.wakeFd(), .{ .readable = true }, stripWake, out) catch |err| {
        std.log.warn("could not register wallpaper strip wake fd: {}", .{err});
        stopStrip(out);
        return;
    };
}

/// A strip of the images to choose from and the folder chooser.
pub fn buildWallpaper(out: *Section, arena: std.mem.Allocator) void {
    const pal = panel.palette();
    const server = out.cc.server;
    const ordinary = wallpapers.list(arena, server.io) catch &.{};
    const pack_images = if (server.config.theme_pack) |p| (if (p.root.len > 0) wallpapers.listDir(arena, server.io, std.fs.path.join(arena, &.{ p.root, "wallpapers" }) catch "") catch &.{} else &.{}) else &.{};
    out.wallpapers = std.mem.concat(arena, wallpapers.Entry, &.{ pack_images, ordinary }) catch ordinary;
    const configured = server.config.compositor.wallpaper;
    var labels: [][]const u8 = &.{};
    if (arena.alloc([]const u8, out.wallpapers.len)) |l| {
        for (out.wallpapers, l) |entry, *dst| dst.* = entry.label;
        labels = l;
    } else |_| {}
    out.wallpaper_row_children = .{
        labelWidget(i18n.tr("Image")),
        .{
            .name = "wallpaper",
            .kind = .{
                .select = .{
                    .labels = labels,
                    .selected = wallpapers.indexOf(out.wallpapers, configured),
                    // A path outside the wallpaper directories.
                    .placeholder = if (configured.len > 0) std.fs.path.basename(configured) else "RediWM",
                    .disabled = labels.len == 0,
                    .owner = out,
                    .on_change = &onWallpaperPicked,
                },
            },
            .width = .{ .fixed = segmented_width },
        },
    };

    const folder: ?[]const u8 = stripFolder(arena, server.io, configured);
    out.strip_entries = if (folder) |dir| (wallpapers.listDir(arena, server.io, dir) catch &.{}) else out.wallpapers;
    var fresh = false;
    if (out.strip == null or !out.strip.?.matches(out.strip_entries)) {
        restartStrip(out, server);
        fresh = true;
    }
    const resolved = @import("../../config_runtime/theme_pack.zig").wallpaperPath(server, arena) catch "";
    var current_tile: ?usize = null;
    for (out.strip_entries, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.path, resolved)) current_tile = i;
    }
    var state: layout.ScrollState = .{};
    if (!fresh and out.strip_built and out.wallpaper_children[strip_index].kind == .scroll_container) {
        const prev = out.wallpaper_children[strip_index].kind.scroll_container;
        state.scroll_offset = prev.scroll_offset;
        state.glide = prev.glide;
        state.bar = prev.bar;
        state.bar_observed = prev.bar_observed;
    } else if (current_tile) |i| {
        // Show the current one, with a couple of its neighbours before it.
        state.scroll_offset = @max(0, (@as(f32, @floatFromInt(i)) - 2) * (tile_extent + strip_gap));
    }
    const bar = scrollbar.gutter(theme.global.scrollbar_width);
    out.wallpaper_children[strip_index] = buildStrip(out, arena, pal, current_tile, state, bar);
    out.strip_built = true;

    const dir = wallpapers.userDir(arena) catch "";
    const hint = if (folder) |f|
        i18n.allocPrint(arena, i18n.tr("Images in {folder}"), .{ .folder = tildePath(arena, f) }) catch i18n.tr("Images in the chosen folder")
    else
        i18n.allocPrint(arena, i18n.tr("Add your own images to {folder}"), .{ .folder = tildePath(arena, dir) }) catch i18n.tr("Add your own images");
    out.wallpaper_footer_children = .{
        .{ .kind = .{ .text = .{ .content = hint, .font_size = theme.global.settings_description_size, .color = pal.dim } }, .width = .{ .flex = 1 } },
        .{
            .name = "wallpaper_folder",
            .kind = .{ .button = .{ .label = i18n.tr("Choose folder"), .owner = out, .on_click = &onChooseWallpaperFolder, .state = if (folder_picker.running()) .disabled else .idle } },
            .width = .auto,
            .min_width = 124,
            .height = .{ .fixed = 30 },
        },
    };
    out.wallpaper_children[0] = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.wallpaper_row_children };
    out.wallpaper_children[2] = .{ .kind = .container, .direction = .row, .gap = 8, .@"align" = .center, .children = &out.wallpaper_footer_children };
}

/// One scrolling row: each image with a tick box inside it, ticked for the
/// wallpaper in use. A tile and its box both select it.
pub fn buildStrip(out: *Section, arena: std.mem.Allocator, pal: theme.Theme, current_tile: ?usize, state: layout.ScrollState, bar: f32) Widget {
    const n = out.strip_entries.len;
    if (n == 0) {
        const note = arena.alloc(Widget, 1) catch return .{ .kind = .container };
        note[0] = .{ .kind = .{ .text = .{ .content = i18n.tr("No images in this folder"), .font_size = theme.global.settings_description_size, .color = pal.dim } } };
        return .{ .name = "wallpaper_strip_empty", .kind = .container, .direction = .row, .children = note };
    }
    const tiles = arena.alloc(Widget, n) catch return .{ .kind = .container };
    const images = arena.alloc([1]Widget, n) catch return .{ .kind = .container };
    const checks = arena.alloc([1]Widget, n) catch return .{ .kind = .container };
    const none: [4]f32 = .{ 0, 0, 0, 0 };
    for (0..n) |i| {
        const is_current = current_tile == i;
        const ring: layout.RectStyle = .{ .color = none, .radius = 8, .border_width = 2, .border_color = pal.accent };
        const hover: layout.RectStyle = .{ .color = none, .radius = 8, .border_width = 2, .border_color = pal.border_soft };
        images[i] = .{.{
            .kind = .{ .image = .{
                .pixels = if (out.strip) |strip| strip.thumb(i) else null,
                .width = wallpaper_strip.thumb_width,
                .height = wallpaper_strip.thumb_height,
                .radius = 6,
                .fallback_color = pal.bg,
                .fallback_icon = null,
            } },
            .width = .{ .fixed = tile_w },
            .height = .{ .fixed = tile_h },
            .padding = layout.Edges.all(8),
            .justify = .end,
            .@"align" = .end,
            .children = &checks[i],
        }};
        checks[i] = .{.{
            .name = std.fmt.allocPrint(arena, "wallpaper_check_{d}", .{i}) catch "wallpaper_check",
            .kind = .{ .checkbox = .{ .label = "", .checked = is_current, .owner = out, .on_change = &onStripCheck, .id = i } },
            .width = .{ .fixed = check_size },
            .height = .{ .fixed = check_size },
        }};
        tiles[i] = .{
            .name = std.fmt.allocPrint(arena, "wallpaper_tile_{d}", .{i}) catch "wallpaper_tile",
            .kind = .{ .row = .{
                .background = if (is_current) ring else .{ .color = none },
                .hover_background = if (is_current) ring else hover,
                .press_background = if (is_current) ring else hover,
                .selected = is_current,
                .owner = out,
                .on_click = &onStripTile,
                .id = i,
            } },
            .padding = layout.Edges.all(tile_pad),
            .width = .{ .fixed = tile_extent },
            .height = .{ .fixed = tile_h + 2 * tile_pad },
            .children = &images[i],
        };
    }
    return .{
        .name = "wallpaper_strip",
        .kind = .{ .scroll_container = state },
        .direction = .row,
        .gap = strip_gap,
        .padding = .{ .bottom = bar },
        .width = .{ .percent = 1 },
        .height = .{ .fixed = tile_h + 2 * tile_pad + bar },
        .children = tiles,
    };
}

pub fn onStripTile(owner: ?*anyopaque, id: usize) void {
    pickStripEntry(section(owner), id);
}

pub fn onStripCheck(owner: ?*anyopaque, id: usize, _: bool) void {
    pickStripEntry(section(owner), id);
}

pub fn pickStripEntry(s: *Section, index: usize) void {
    if (index >= s.strip_entries.len) return;
    applyWallpaper(s, s.strip_entries[index]);
    // Moves the tick, and re-ticks a box that was just unticked.
    {
        const server = s.cc.server;
        if (server.input.open_control_center) |cc| cc.refresh();
    }
}

/// Live first, then saved: the config watcher's reload then finds the same
/// wallpaper and loads nothing. The bundled default saves as "", so a moved
/// install keeps finding it.
pub fn onWallpaperPicked(owner: ?*anyopaque, _: usize, index: usize) void {
    const s = section(owner);
    if (index >= s.wallpapers.len) return;
    applyWallpaper(section(owner), s.wallpapers[index]);
}

pub fn applyWallpaper(s: *Section, entry: wallpapers.Entry) void {
    const server = s.cc.server;
    const value = if (entry.bundled and std.mem.eql(u8, entry.name, wallpapers.default_name)) "" else entry.name;
    if (std.mem.eql(u8, server.config.compositor.wallpaper, value)) return;
    // Config strings live in its arena, freed with it on the next reload.
    server.config.compositor.wallpaper = server.config.arena.allocator().dupe(u8, value) catch return;
    server.reloadWallpaper();
    setting_save.saveCompositor(main.gpa, server.io, server.config.path, "wallpaper", value) catch |err| {
        std.log.warn("could not save wallpaper: {}", .{err});
    };
}

/// Opens Files as a folder chooser, starting in the folder the strip shows
/// (or the user's wallpaper directory, created if needed).
pub fn onChooseWallpaperFolder(owner: ?*anyopaque, _: usize) void {
    const server = section(owner).cc.server;
    var scratch = std.heap.ArenaAllocator.init(main.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const start = stripFolder(a, server.io, server.config.compositor.wallpaper) orelse blk: {
        const dir = wallpapers.userDir(a) catch break :blk "";
        std.Io.Dir.cwd().createDirPath(server.io, dir) catch |err| {
            std.log.warn("could not create {s}: {}", .{ dir, err });
            break :blk "";
        };
        break :blk dir;
    };
    folder_picker.start(server, i18n.tr("Choose wallpaper folder"), start, server, &onFolderChosen) catch |err| {
        std.log.warn("could not open the folder chooser: {}", .{err});
        return;
    };
    // The button reads as busy until the chooser closes.
    if (server.input.open_control_center) |cc| cc.refresh();
}

pub fn onFolderChosen(owner: ?*anyopaque, path: ?[]const u8) void {
    if (path) |picked| pick: {
        // A folder path is saved as a plain TOML string (setting_save.zig).
        if (std.mem.indexOfAny(u8, picked, "\"\\\n\r") != null) break :pick;
        const copy = main.gpa.dupe(u8, picked) catch break :pick;
        if (chosen_dir) |old| main.gpa.free(old);
        chosen_dir = copy;
    }
    const server: *Server = @ptrCast(@alignCast(owner orelse return));
    if (server.input.open_control_center) |cc| cc.refresh();
}
