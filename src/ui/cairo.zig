// Shell UI for the client apps that render with Cairo (Files, Images, the
// share picker, the desktop): text through text.zig instead of Cairo's toy
// font API, and the shared components (paint.zig, widgets/) through an
// offscreen layer composited by Cairo, so its clip and transform still apply.
// Each app has its own `@cImport` of cairo.h, so contexts cross as
// `*anyopaque`.
const std = @import("std");
const c = @cImport(@cInclude("cairo.h"));
const paint = @import("paint.zig");
const theme = @import("theme.zig");
const text = @import("text.zig");
const scrollbar = @import("widgets/scrollbar.zig");
const splitter = @import("widgets/splitter.zig");

pub const Rect = @import("widgets/field.zig").Rect;
const allocator = std.heap.c_allocator;

/// Text sizes of the Cairo client apps (Files, Images, PDF): one body size for
/// labels, rows, menus, fields and dialog copy, a touch smaller for column and
/// section headings, and a smaller one for status lines. Window chrome keeps
/// its own title size. Text is `window_fg` throughout: no muted tint.
pub fn textSize() f32 {
    return theme.global.app_text_size;
}
pub fn headingSize() f32 {
    return theme.global.app_heading_size;
}
pub fn statusSize() f32 {
    return theme.global.app_status_size;
}

/// Device pixels per user unit (the matrix's x scale; no rotation or skew).
pub fn scaleOf(cr_any: *anyopaque) f32 {
    const cr: *c.cairo_t = @ptrCast(cr_any);
    var m: c.cairo_matrix_t = undefined;
    c.cairo_get_matrix(cr, &m);
    return @floatCast(@max(@abs(m.xx), 0.01));
}

fn fontOf(bold: bool) text.Font {
    return if (bold) .manrope_bold else .manrope;
}

/// Advance width of `str` in user units, measured at the context's device
/// scale so it matches what `drawText` rasterizes.
pub fn measureText(cr: *anyopaque, str: []const u8, size: f64, bold: bool) f64 {
    return text.measureWidthF(str, fontOf(bold), @floatCast(size), scaleOf(cr)) catch 0;
}

pub const FontMetrics = struct { ascent: f64, descent: f64 };

pub fn fontMetrics(cr: *anyopaque, size: f64) FontMetrics {
    const m = text.verticalMetrics(.manrope, @floatCast(size), scaleOf(cr)) catch
        return .{ .ascent = size * 0.8, .descent = size * 0.2 };
    return .{ .ascent = m.ascent, .descent = m.descent };
}

/// Sets a straight-alpha theme colour as the context's source.
pub fn setSource(cr_any: *anyopaque, color: [4]f32) void {
    c.cairo_set_source_rgba(@ptrCast(cr_any), color[0], color[1], color[2], color[3]);
}

pub fn drawSplitter(cr_any: *anyopaque, geometry: splitter.Geometry, engaged: bool) void {
    const cr: *c.cairo_t = @ptrCast(cr_any);
    const rect = geometry.line(engaged);
    setSource(cr, splitter.color(engaged));
    c.cairo_rectangle(cr, rect.x, rect.y, rect.w, rect.h);
    c.cairo_fill(cr);
}

/// Fills a scrollbar thumb: `scrollbar.look` through Cairo, the counterpart of
/// `scrollbar.paint` for the widget tree.
pub fn drawScrollbar(cr_any: *anyopaque, look: scrollbar.Look) void {
    const cr: *c.cairo_t = @ptrCast(cr_any);
    const x: f64 = look.rect.x;
    const y: f64 = look.rect.y;
    const w: f64 = look.rect.w;
    const h: f64 = look.rect.h;
    if (w <= 0 or h <= 0) return;
    const r: f64 = @min(look.radius, @min(w, h) / 2);
    setSource(cr, look.color);
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + w - r, y + r, r, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, x + w - r, y + h - r, r, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, x + r, y + h - r, r, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, x + r, y + r, r, std.math.pi, 3 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
    c.cairo_fill(cr);
}

/// Draws `str` with its pen at `x` and baseline at `y`, like
/// `cairo_show_text`, in the context's current (solid) source colour.
pub fn drawText(cr_any: *anyopaque, str: []const u8, x: f64, y: f64, size: f64, bold: bool) void {
    if (str.len == 0) return;
    const cr: *c.cairo_t = @ptrCast(cr_any);
    const s = scaleOf(cr);
    const font = fontOf(bold);
    const size_f: f32 = @floatCast(size);
    const m = text.verticalMetrics(font, size_f, s) catch return;
    const advance = text.measureWidthF(str, font, size_f, s) catch return;
    // Room for glyphs that overhang their pen box on either side.
    const pad: i32 = @max(2, @as(i32, @intFromFloat(@ceil(size_f / 4))));
    const w_logical: i32 = @as(i32, @intFromFloat(@ceil(advance))) + 2 * pad;
    const h_logical: i32 = @as(i32, @intFromFloat(@ceil(m.ascent + m.descent))) + 2 * pad;
    const w_dev: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(w_logical)) * s));
    const h_dev: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(h_logical)) * s));
    if (w_dev <= 0 or h_dev <= 0 or w_dev > 16384 or h_dev > 4096) return;
    const baseline: i32 = @intFromFloat(@round((@as(f32, @floatFromInt(pad)) + m.ascent) * s));

    var red: f64 = 1;
    var green: f64 = 1;
    var blue: f64 = 1;
    var alpha: f64 = 1;
    _ = c.cairo_pattern_get_rgba(c.cairo_get_source(cr), &red, &green, &blue, &alpha);

    const pixels = allocator.alloc(u32, @intCast(w_dev * h_dev)) catch return;
    defer allocator.free(pixels);
    @memset(pixels, 0);
    text.drawOpts(pixels, w_dev, h_dev, str, .{ .r = @floatCast(red), .g = @floatCast(green), .b = @floatCast(blue), .a = @floatCast(alpha) }, s, font, size_f, .{
        .rect = .{ .x = pad, .y = 0, .w = w_logical - pad, .h = h_logical },
        .clip = .{ .x = 0, .y = 0, .w = w_logical, .h = h_logical },
        .ellipsize = false,
        .baseline = baseline,
    }) catch return;

    // Pen and baseline onto whole device pixels, so the raster lands 1:1.
    var dx = x;
    var dy = y;
    c.cairo_user_to_device(cr, &dx, &dy);
    composite(cr, pixels, w_dev, h_dev, @round(dx) - @as(f64, @floatFromInt(pad)) * s, @round(dy) - @as(f64, @floatFromInt(baseline)));
}

fn composite(cr: *c.cairo_t, pixels: []u32, w: i32, h: i32, device_x: f64, device_y: f64) void {
    const surface = c.cairo_image_surface_create_for_data(@ptrCast(pixels.ptr), c.CAIRO_FORMAT_ARGB32, w, h, w * 4) orelse return;
    defer c.cairo_surface_destroy(surface);
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_identity_matrix(cr);
    c.cairo_set_source_surface(cr, surface, device_x, device_y);
    c.cairo_paint(cr);
}

/// An offscreen buffer over `box` (user space), snapped to device pixels.
/// Paint into `renderer` in box-local coordinates (`local()`), then `finish`
/// composites it through the context's clip.
pub const Layer = struct {
    cr: *c.cairo_t,
    pixels: []u32,
    width: i32,
    height: i32,
    device_x: f64,
    device_y: f64,
    box: Rect,
    renderer: paint.Renderer,

    pub fn begin(cr_any: *anyopaque, box: Rect) ?Layer {
        const cr: *c.cairo_t = @ptrCast(cr_any);
        const s = scaleOf(cr);
        var dx: f64 = box.x;
        var dy: f64 = box.y;
        c.cairo_user_to_device(cr, &dx, &dy);
        const w: i32 = @intFromFloat(@ceil(box.w * s));
        const h: i32 = @intFromFloat(@ceil(box.h * s));
        if (w <= 0 or h <= 0 or w > 16384 or h > 16384) return null;
        const pixels = allocator.alloc(u32, @intCast(w * h)) catch return null;
        @memset(pixels, 0);
        var renderer = paint.Renderer.init(pixels, w, h, s);
        renderer.palette = theme.shellPalette();
        return .{ .cr = cr, .pixels = pixels, .width = w, .height = h, .device_x = @round(dx), .device_y = @round(dy), .box = box, .renderer = renderer };
    }

    /// The layer's own box in the coordinates `renderer` paints in.
    pub fn local(self: *const Layer) Rect {
        return .{ .x = 0, .y = 0, .w = self.box.w, .h = self.box.h };
    }

    pub fn finish(self: *Layer) void {
        composite(self.cr, self.pixels, self.width, self.height, self.device_x, self.device_y);
        allocator.free(self.pixels);
        self.pixels = &.{};
    }
};

test "drawText lands its baseline where cairo_show_text would put it" {
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 120, 40) orelse return error.Cairo;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return error.Cairo;
    defer c.cairo_destroy(cr);
    c.cairo_set_source_rgb(cr, 1, 0, 0);
    drawText(cr, "Hx", 10, 30, 16, false);
    c.cairo_surface_flush(surface);
    const data: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(surface)));
    var bottom: usize = 0;
    var left: usize = 120;
    for (0..40) |row| for (0..120) |col| if (data[row * 120 + col] >> 24 > 0x80) {
        bottom = @max(bottom, row);
        left = @min(left, col);
    };
    // "Hx" has no descender: ink stops on the baseline row, starts at the pen.
    try std.testing.expect(bottom >= 28 and bottom <= 30);
    try std.testing.expect(left >= 10 and left <= 13);
    // In the source colour.
    try std.testing.expectEqual(@as(u32, 0), data[29 * 120 + 12] & 0xffff);
}

test "a layer composites a shared component at its box, scaled" {
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 200, 100) orelse return error.Cairo;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return error.Cairo;
    defer c.cairo_destroy(cr);
    c.cairo_scale(cr, 2, 2);
    var layer = Layer.begin(cr, .{ .x = 10, .y = 5, .w = 40, .h = 20 }) orelse return error.Layer;
    layer.renderer.fillRect(0, 0, 40, 20, .{ .color = .{ 0, 0, 1, 1 } });
    layer.finish();
    c.cairo_surface_flush(surface);
    const data: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(surface)));
    try std.testing.expectEqual(@as(u32, 0xff0000ff), data[30 * 200 + 40]);
    try std.testing.expectEqual(@as(u32, 0), data[9 * 200 + 40]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), data[10 * 200 + 20]);
    try std.testing.expectEqual(@as(u32, 0), data[10 * 200 + 19]);
}

test "a scrollbar thumb paints its look through cairo" {
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 40, 60) orelse return error.Cairo;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return error.Cairo;
    defer c.cairo_destroy(cr);
    const g = scrollbar.Geometry.compute(.vertical, .{ .x = 20, .y = 0, .w = 14, .h = 60 }, 60, 120, 0).?;
    var palette = theme.shellPalette();
    palette.scrollbar_thumb = .{ 0, 0, 1, 1 };
    drawScrollbar(cr, scrollbar.look(g, .{}, 8, palette));
    c.cairo_surface_flush(surface);
    const data: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(surface)));
    // Six wide at rest, centred in the 14 wide gutter: x 24..30, top half.
    try std.testing.expectEqual(@as(u32, 0xff0000ff), data[15 * 40 + 27]);
    try std.testing.expectEqual(@as(u32, 0), data[15 * 40 + 22]);
    try std.testing.expectEqual(@as(u32, 0), data[45 * 40 + 27]);
}
