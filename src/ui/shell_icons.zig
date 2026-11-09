//! Embedded monochrome SVG glyphs. Cache alpha at the device-pixel size;
//! tinting happens at paint time, so hover/selection never rerasterizes SVGs.
const std = @import("std");
const IconId = @import("layout.zig").IconId;
const c = @import("c_gfx");
/// The start-button logo; not an `IconId` glyph because it keeps its own colours.
pub const redi_logo = @embedFile("redi-logo");
/// The Settings app's colour icon (`settings_icon_name`), for when neither the
/// active pack nor an installed icon theme has one.
pub const settings_icon_png = @embedFile("rediwm-settings-icon");
pub const settings_icon_name = "rediwm-settings";

const Handle = opaque {};
const GError = opaque {};
const Rectangle = extern struct { x: f64 = 0, y: f64 = 0, width: f64, height: f64 };
extern fn rsvg_handle_new_from_data([*]const u8, usize, *?*GError) ?*Handle;
extern fn rsvg_handle_render_document(*Handle, *c.cairo_t, *const Rectangle, *?*GError) c_int;
extern fn g_object_unref(*anyopaque) void;
extern fn g_error_free(*GError) void;

pub const Mask = struct {
    alpha: []u8,
    size: i32,

    pub fn sample(mask: Mask, x: f32, y: f32) f32 {
        const ix: i32 = @intFromFloat(@floor(x));
        const iy: i32 = @intFromFloat(@floor(y));
        const fx = x - @floor(x);
        const fy = y - @floor(y);
        return (mask.at(ix, iy) * (1 - fx) + mask.at(ix + 1, iy) * fx) * (1 - fy) +
            (mask.at(ix, iy + 1) * (1 - fx) + mask.at(ix + 1, iy + 1) * fx) * fy;
    }

    fn at(mask: Mask, x: i32, y: i32) f32 {
        if (x < 0 or y < 0 or x >= mask.size or y >= mask.size) return 0;
        return @as(f32, @floatFromInt(mask.alpha[@intCast(y * mask.size + x)])) / 255;
    }
};

const Entry = struct { id: IconId, mask: Mask };
var cache: [64]?Entry = @splat(null);
var next: usize = 0;

var overrides: [@typeInfo(IconId).@"enum".field_names.len]?[]u8 = @splat(null);
var pack_root: []const u8 = "";
var source_mutex: std.posix.system.pthread_mutex_t = .{};

pub fn configure(io: std.Io, root: []const u8) void {
    _ = std.posix.system.pthread_mutex_lock(&source_mutex);
    defer _ = std.posix.system.pthread_mutex_unlock(&source_mutex);
    clearPack();
    pack_root = if (root.len > 0) std.heap.c_allocator.dupe(u8, root) catch "" else "";
    if (root.len == 0) return;
    inline for (.{
        .{ IconId.git_branch, "git-branch" },
        .{ IconId.home, "home" },
        .{ IconId.folder, "folder" },
        .{ IconId.terminal, "terminal" },
        .{ IconId.edit, "edit" },
        .{ IconId.keyboard, "keyboard" },
        .{ IconId.settings, "settings" },
        .{ IconId.mouse, "mouse" },
        .{ IconId.touchpad, "touchpad" },
        .{ IconId.trackball, "trackball" },
        .{ IconId.display, "display" },
        .{ IconId.headphones, "headphones" },
        .{ IconId.music, "music" },
        .{ IconId.wifi, "wifi" },
        .{ IconId.ethernet, "ethernet" },
        .{ IconId.globe, "globe" },
        .{ IconId.bluetooth, "bluetooth" },
        .{ IconId.battery, "battery" },
        .{ IconId.notification, "notification-bell" },
        .{ IconId.volume_low, "speaker" },
        .{ IconId.volume_muted, "speaker-xmark" },
        .{ IconId.clock, "clock" },
        .{ IconId.cpu, "cpu" },
        .{ IconId.ram, "ram" },
        .{ IconId.lock, "lock" },
        .{ IconId.logout, "logout" },
        .{ IconId.reboot, "restart" },
        .{ IconId.power, "power-button" },
        .{ IconId.eye, "eye" },
        .{ IconId.eye_off, "eye-off" },
        .{ IconId.refresh, "refresh" },
        .{ IconId.cut, "cut" },
        .{ IconId.copy, "copy" },
        .{ IconId.paste, "paste" },
        .{ IconId.trash, "trash-outline" },
        .{ IconId.trash_can, "trash" },
        .{ IconId.view_grid, "view-grid" },
        .{ IconId.view_list, "view-list" },
        .{ IconId.sort, "sort" },
        .{ IconId.filter, "filter" },
        .{ IconId.zoom_in, "zoom-in" },
        .{ IconId.zoom_out, "zoom-out" },
        .{ IconId.rotate, "rotate" },
        .{ IconId.crop, "crop" },
        .{ IconId.undo, "undo" },
        .{ IconId.save, "save" },
        .{ IconId.fit, "fit" },
        .{ IconId.print, "print" },
        .{ IconId.open, "open" },
        .{ IconId.usb_stick, "usb-stick" },
        .{ IconId.drive, "drive" },
        .{ IconId.eject, "eject" },
        .{ IconId.users, "users" },
        .{ IconId.squares, "squares" },
        .{ IconId.divide, "divide" },
    }) |pair| {
        loadOverride(io, root, pair[0], pair[1]);
    }
}

fn loadOverride(io: std.Io, root: []const u8, id: IconId, name: []const u8) void {
    const path = std.fmt.allocPrint(std.heap.c_allocator, "{s}/glyphs/{s}.svg", .{ root, name }) catch return;
    defer std.heap.c_allocator.free(path);
    var i: usize = 1;
    while (i < path.len) : (i += 1) if (path[i] == '/') {
        const part = std.Io.Dir.cwd().statFile(io, path[0..i], .{ .follow_symlinks = false }) catch return;
        if (part.kind == .sym_link) return;
    };
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return;
    if (stat.kind != .file) return;
    overrides[@backingInt(id)] = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.c_allocator, .limited(64 * 1024)) catch null;
}

pub fn deinitPack() void {
    _ = std.posix.system.pthread_mutex_lock(&source_mutex);
    defer _ = std.posix.system.pthread_mutex_unlock(&source_mutex);
    clearPack();
}

fn clearPack() void {
    deinit();
    for (&overrides) |*entry| {
        if (entry.*) |bytes| std.heap.c_allocator.free(bytes);
        entry.* = null;
    }
    if (pack_root.len > 0) std.heap.c_allocator.free(pack_root);
    pack_root = "";
}

fn source(id: IconId) ?[]const u8 {
    if (overrides[@backingInt(id)]) |bytes| return bytes;
    return builtinSource(id);
}

fn builtinSource(id: IconId) ?[]const u8 {
    return switch (id) {
        .git_branch => @embedFile("shell-icon-git-branch"),
        .home => @embedFile("shell-icon-home"),
        .folder => @embedFile("shell-icon-folder"),
        .terminal => @embedFile("shell-icon-terminal"),
        .edit => @embedFile("shell-icon-edit"),
        .keyboard => @embedFile("shell-icon-keyboard"),
        .settings => @embedFile("shell-icon-settings"),
        .mouse => @embedFile("shell-icon-mouse"),
        .touchpad => @embedFile("shell-icon-touchpad"),
        .trackball => @embedFile("shell-icon-trackball"),
        .display => @embedFile("shell-icon-display"),
        .headphones => @embedFile("shell-icon-headphones"),
        .music => @embedFile("shell-icon-music"),
        .wifi => @embedFile("shell-icon-wifi"),
        .ethernet => @embedFile("shell-icon-ethernet"),
        .globe => @embedFile("shell-icon-globe"),
        .bluetooth => @embedFile("shell-icon-bluetooth"),
        .battery => @embedFile("shell-icon-battery"),
        .notification => @embedFile("shell-icon-notification-bell"),
        .volume, .volume_low => @embedFile("shell-icon-speaker"),
        .volume_muted => @embedFile("shell-icon-speaker-xmark"),
        .clock => @embedFile("shell-icon-clock"),
        .cpu => @embedFile("shell-icon-cpu"),
        .ram => @embedFile("shell-icon-ram"),
        .lock => @embedFile("shell-icon-lock"),
        .logout => @embedFile("shell-icon-logout"),
        .reboot => @embedFile("shell-icon-restart"),
        .power => @embedFile("shell-icon-power-button"),
        .eye => @embedFile("shell-icon-eye"),
        .eye_off => @embedFile("shell-icon-eye-off"),
        .refresh => @embedFile("shell-icon-refresh"),
        .cut => @embedFile("shell-icon-cut"),
        .copy => @embedFile("shell-icon-copy"),
        .paste => @embedFile("shell-icon-paste"),
        .trash => @embedFile("shell-icon-trash-outline"),
        .trash_can => @embedFile("shell-icon-trash"),
        .view_grid => @embedFile("shell-icon-view-grid"),
        .view_list => @embedFile("shell-icon-view-list"),
        .sort => @embedFile("shell-icon-sort"),
        .filter => @embedFile("shell-icon-filter"),
        .zoom_in => @embedFile("shell-icon-zoom-in"),
        .zoom_out => @embedFile("shell-icon-zoom-out"),
        .rotate => @embedFile("shell-icon-rotate"),
        .crop => @embedFile("shell-icon-crop"),
        .undo => @embedFile("shell-icon-undo"),
        .save => @embedFile("shell-icon-save"),
        .fit => @embedFile("shell-icon-fit"),
        .print => @embedFile("shell-icon-print"),
        .open => @embedFile("shell-icon-open"),
        .usb_stick => @embedFile("shell-icon-usb-stick"),
        .drive => @embedFile("shell-icon-drive"),
        .eject => @embedFile("shell-icon-eject"),
        .users => @embedFile("shell-icon-users"),
        .squares => @embedFile("shell-icon-squares"),
        .divide => @embedFile("shell-icon-divide"),
        else => null,
    };
}

/// The desktop's scan worker owns this mask; it never borrows a UI cache entry.
pub fn getOwned(id: IconId, size: i32) ?Mask {
    _ = std.posix.system.pthread_mutex_lock(&source_mutex);
    defer _ = std.posix.system.pthread_mutex_unlock(&source_mutex);
    return rasterize(source(id) orelse return null, size) orelse rasterize(builtinSource(id) orelse return null, size);
}

pub fn get(id: IconId, requested_size: i32) ?Mask {
    const svg = source(id) orelse return null;
    const size = std.math.clamp(requested_size, 1, 256);
    for (cache) |entry| if (entry) |e| {
        if (e.id == id and e.mask.size == size) return e.mask;
    };
    const mask = rasterize(svg, size) orelse rasterize(builtinSource(id) orelse return null, size) orelse return null;
    if (cache[next]) |old| std.heap.c_allocator.free(old.mask.alpha);
    cache[next] = .{ .id = id, .mask = mask };
    next = (next + 1) % cache.len;
    return mask;
}

pub fn deinit() void {
    for (&cache) |*entry| {
        if (entry.*) |e| std.heap.c_allocator.free(e.mask.alpha);
        entry.* = null;
    }
    next = 0;
}

fn rasterize(svg: []const u8, size: i32) ?Mask {
    var err: ?*GError = null;
    defer if (err) |e| g_error_free(e);
    const handle = rsvg_handle_new_from_data(svg.ptr, svg.len, &err) orelse return null;
    defer g_object_unref(handle);
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, size, size);
    defer c.cairo_surface_destroy(surface);
    if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) return null;
    const cr = c.cairo_create(surface) orelse return null;
    defer c.cairo_destroy(cr);
    if (c.cairo_status(cr) != c.CAIRO_STATUS_SUCCESS) return null;
    const viewport = Rectangle{ .width = @floatFromInt(size), .height = @floatFromInt(size) };
    if (rsvg_handle_render_document(handle, cr, &viewport, &err) == 0) return null;
    c.cairo_surface_flush(surface);
    const data = c.cairo_image_surface_get_data(surface) orelse return null;
    const stride: usize = @intCast(c.cairo_image_surface_get_stride(surface));
    const w: usize = @intCast(size);
    const alpha = std.heap.c_allocator.alloc(u8, w * w) catch return null;
    for (0..w) |y| {
        const row: [*]align(4) const u32 = @ptrCast(@alignCast(data + y * stride));
        for (0..w) |x| alpha[y * w + x] = @intCast(row[x] >> 24);
    }
    return .{ .alpha = alpha, .size = size };
}

test "bundled shell SVGs render nonempty transparent masks at fractional scales" {
    defer deinit();
    for ([_]IconId{ .print, .usb_stick, .drive, .eject, .home, .settings, .mouse, .touchpad, .trackball, .display, .music, .headphones, .wifi, .bluetooth, .battery, .notification, .volume, .volume_muted, .power, .clock, .cpu, .ram, .lock, .logout, .reboot, .divide }) |id| {
        for ([_]i32{ 24, 36, 48 }) |size| {
            const mask = get(id, size) orelse return error.InvalidShellIcon;
            var visible = false;
            var transparent = false;
            for (mask.alpha) |a| {
                visible = visible or a > 0;
                transparent = transparent or a == 0;
            }
            try std.testing.expect(visible and transparent);
            try std.testing.expectEqual(mask.alpha.ptr, get(id, size).?.alpha.ptr);
        }
    }
}
