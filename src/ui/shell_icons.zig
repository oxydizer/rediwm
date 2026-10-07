//! Embedded monochrome SVG glyphs. Cache alpha at the device-pixel size;
//! tinting happens at paint time, so hover/selection never rerasterizes SVGs.
const std = @import("std");
const IconId = @import("layout.zig").IconId;
const c = @cImport({
    @cInclude("cairo.h");
});
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

fn source(id: IconId) ?[]const u8 {
    return switch (id) {
        .git_branch => @embedFile("shell-icon-git-branch"),
        .home => @embedFile("shell-icon-home"),
        .folder => @embedFile("shell-icon-folder"),
        .edit => @embedFile("shell-icon-edit"),
        .keyboard => @embedFile("shell-icon-keyboard"),
        .settings => @embedFile("shell-icon-settings"),
        .mouse => @embedFile("shell-icon-mouse"),
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
        else => null,
    };
}

pub fn get(id: IconId, requested_size: i32) ?Mask {
    const svg = source(id) orelse return null;
    const size = std.math.clamp(requested_size, 1, 256);
    for (cache) |entry| if (entry) |e| {
        if (e.id == id and e.mask.size == size) return e.mask;
    };
    const mask = rasterize(svg, size) orelse return null;
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
    for ([_]IconId{ .print, .usb_stick, .drive, .eject, .home, .settings, .mouse, .display, .music, .headphones, .wifi, .bluetooth, .battery, .notification, .volume, .volume_muted, .power, .clock, .lock, .logout, .reboot }) |id| {
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
