// Shell UI for the client apps that render with Cairo (Files, Images, the
// share picker, the desktop): text through text.zig instead of Cairo's toy
// font API, and the shared components (paint.zig, widgets/) through an
// offscreen layer composited by Cairo, so its clip and transform still apply.
// Contexts cross as `*anyopaque`, keeping cairo types out of the interface.
const std = @import("std");
const c = @import("c_gfx");
const paint = @import("paint.zig");
const theme = @import("theme.zig");
const text = @import("text.zig");
const scrollbar = @import("widgets/scrollbar.zig");
const button = @import("widgets/button.zig");
const splitter = @import("widgets/splitter.zig");

pub const Rect = @import("widgets/field.zig").Rect;
pub const Point = struct { x: f64, y: f64 };
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

/// File and process rows share the same rounded hover/selection card.
/// Keep double-precision geometry for Cairo's fractional raster positions.
pub const ItemBox = struct { x: f64, y: f64, w: f64, h: f64 };

pub fn drawItemHighlight(cr_any: *anyopaque, box: ItemBox, selected: bool, fill_alpha: f32, border_alpha: f32) void {
    if (box.w <= 0 or box.h <= 0 or (fill_alpha <= 0 and border_alpha <= 0)) return;
    const cr: *c.cairo_t = @ptrCast(cr_any);
    @import("widgets/highlight.zig").path(cr, box.x, box.y, box.w, box.h, 6);
    if (fill_alpha > 0) {
        var fill = if (selected) theme.global.app_item_selected else theme.global.app_item_hover;
        fill[3] *= fill_alpha;
        setSource(cr, fill);
        c.cairo_fill_preserve(cr);
    }
    var border = if (selected) theme.shellPalette().accent else theme.global.app_item_border;
    border[3] *= border_alpha;
    setSource(cr, border);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
}

/// Paints the shared proximity glow inside a Cairo-rendered interactive
/// surface. Pointer coordinates are in the caller's user space. `clip`, when
/// supplied, limits both proximity sampling and the pixels painted.
pub fn drawProximityGlow(
    cr_any: *anyopaque,
    box: Rect,
    radius: f32,
    pointer: ?Point,
    clip: ?Rect,
) void {
    const p = pointer orelse return;
    const t = &theme.global;
    // Callers paint this for every card or row on every repaint, so every
    // reason it would paint nothing is settled before a layer is allocated.
    if (!button.proximityGlowVisible(t.*)) return;
    const cr: *c.cairo_t = @ptrCast(cr_any);
    const clipping = clip orelse box;
    var visible = button.intersectRect(box, clipping);
    // A partial repaint clips most items away entirely.
    var cx0: f64 = 0;
    var cy0: f64 = 0;
    var cx1: f64 = 0;
    var cy1: f64 = 0;
    c.cairo_clip_extents(cr, &cx0, &cy0, &cx1, &cy1);
    visible = button.intersectRect(visible, .{
        .x = @floatCast(cx0),
        .y = @floatCast(cy0),
        .w = @floatCast(cx1 - cx0),
        .h = @floatCast(cy1 - cy0),
    });
    if (visible.w <= 0 or visible.h <= 0) return;

    const sample = button.sampleProximity(
        box,
        @floatCast(p.x),
        @floatCast(p.y),
        clipping,
    );
    if (sample.distance >= std.math.inf(f32)) return;
    if (!button.proximityGlowLit(box.w, box.h, radius, sample.x, sample.y, t.border_glow_reach)) return;

    // The layer covers only the visible part of the box, starting a whole
    // number of device pixels into it, so each pixel keeps the position it
    // would have in a layer over the whole box.
    const s: f64 = scaleOf(cr);
    var bx: f64 = box.x;
    var by: f64 = box.y;
    c.cairo_user_to_device(cr, &bx, &by);
    var vx: f64 = visible.x;
    var vy: f64 = visible.y;
    c.cairo_user_to_device(cr, &vx, &vy);
    const full_w = @ceil(box.w * s);
    const full_h = @ceil(box.h * s);
    const k0x = std.math.clamp(@floor(vx - @round(bx)), 0, full_w);
    const k0y = std.math.clamp(@floor(vy - @round(by)), 0, full_h);
    const k1x = std.math.clamp(@ceil(vx + visible.w * s - @round(bx)), k0x, full_w);
    const k1y = std.math.clamp(@ceil(vy + visible.h * s - @round(by)), k0y, full_h);
    if (k1x <= k0x or k1y <= k0y) return;
    const sub: Rect = .{
        .x = @floatCast(box.x + k0x / s),
        .y = @floatCast(box.y + k0y / s),
        .w = @floatCast((k1x - k0x) / s),
        .h = @floatCast((k1y - k0y) / s),
    };

    var layer = Layer.begin(cr_any, sub) orelse return;
    layer.renderer.clip = .{
        .x = visible.x - sub.x,
        .y = visible.y - sub.y,
        .w = visible.w,
        .h = visible.h,
    };
    button.paintProximityGlowAt(
        &layer.renderer,
        .{ .x = box.x - sub.x, .y = box.y - sub.y, .w = box.w, .h = box.h },
        radius,
        sample.distance,
        sample.x,
        sample.y,
    );
    layer.finish();
}

/// Sidebar hover: the theme's highlight outline filled at `alpha`.
pub fn drawSidebarHover(cr_any: *anyopaque, box: Rect, alpha: f32) void {
    if (box.w <= 0 or box.h <= 0 or alpha <= 0) return;
    const cr: *c.cairo_t = @ptrCast(cr_any);
    sidebarRowPath(cr, box);
    var fill = theme.global.sidebarHover();
    fill[3] *= alpha;
    setSource(cr, fill);
    c.cairo_fill(cr);
}

/// The selected sidebar row: its fill and an accent bar, or with
/// `app_sidebar_selected_marker` an illuminated leading edge. Everything stays
/// inside the row, so the row's own damage covers it.
pub fn drawSidebarSelected(cr_any: *anyopaque, box: Rect) void {
    if (box.w <= 0 or box.h <= 0) return;
    const cr: *c.cairo_t = @ptrCast(cr_any);
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    const x: f64 = box.x;
    const y: f64 = box.y;
    const w: f64 = box.w;
    const h: f64 = box.h;
    sidebarRowPath(cr, box);
    setSource(cr, theme.global.sidebarSelected());
    c.cairo_fill_preserve(cr);
    c.cairo_clip(cr);
    const accent = theme.shellPalette().accent;
    const marker = theme.global.app_sidebar_selected_marker orelse {
        c.cairo_new_path(cr);
        const bar_h = @min(24, h);
        roundedPath(cr, x, y + (h - bar_h) / 2, 3, bar_h, 1.5);
        setSource(cr, accent);
        c.cairo_fill(cr);
        return;
    };
    const glow = c.cairo_pattern_create_linear(x, 0, x + @min(w, 28), 0) orelse return;
    defer c.cairo_pattern_destroy(glow);
    c.cairo_pattern_add_color_stop_rgba(glow, 0, accent[0], accent[1], accent[2], accent[3] * 0.85);
    c.cairo_pattern_add_color_stop_rgba(glow, 0.25, accent[0], accent[1], accent[2], accent[3] * 0.40);
    c.cairo_pattern_add_color_stop_rgba(glow, 1, accent[0], accent[1], accent[2], 0);
    c.cairo_set_source(cr, glow);
    c.cairo_paint(cr);
    c.cairo_set_source_rgba(cr, marker[0], marker[1], marker[2], marker[3]);
    c.cairo_set_line_width(cr, 3);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_move_to(cr, x + 2.5, y + 5);
    c.cairo_line_to(cr, x + 2.5, y + h - 5);
    c.cairo_stroke(cr);
}

fn sidebarRowPath(cr: *c.cairo_t, box: Rect) void {
    const radius = @min(theme.global.app_sidebar_item_radius, @min(box.w, box.h) / 2);
    @import("widgets/highlight.zig").path(cr, box.x, box.y, box.w, box.h, radius);
}

fn roundedPath(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + w - radius, y + radius, radius, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, x + w - radius, y + h - radius, radius, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, x + radius, y + h - radius, radius, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, x + radius, y + radius, radius, std.math.pi, 3 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
}

pub fn drawSplitter(cr_any: *anyopaque, geometry: splitter.Geometry, engaged: bool) void {
    const cr: *c.cairo_t = @ptrCast(cr_any);
    const rect = geometry.line(engaged);
    setSource(cr, splitter.color(engaged));
    c.cairo_rectangle(cr, rect.x, rect.y, rect.w, rect.h);
    c.cairo_fill(cr);
}

/// Fills a scrollbar, groove and thumb through Cairo. The existing form
/// leaves proximity lighting off; callers with pointer coordinates use
/// `drawScrollbarAt`.
pub fn drawScrollbar(cr_any: *anyopaque, look: scrollbar.Look) void {
    drawScrollbarAt(cr_any, look, null);
}

/// The pointer-aware Cairo scrollbar painter. The groove glow is painted
/// between the groove and thumb, so the thumb always stays visually clear.
pub fn drawScrollbarAt(cr_any: *anyopaque, look: scrollbar.Look, pointer: ?Point) void {
    const cr: *c.cairo_t = @ptrCast(cr_any);

    const track = look.track;
    const thumb = look.rect;
    const needs_track_layer = scrollbar.hasTrack(look) or look.thumb_relief == .raised;
    const left = if (needs_track_layer) @min(track.x, thumb.x) else thumb.x;
    const top = if (needs_track_layer) @min(track.y, thumb.y) else thumb.y;
    const right = if (needs_track_layer) @max(track.x + track.w, thumb.x + thumb.w) else thumb.x + thumb.w;
    const bottom = if (needs_track_layer) @max(track.y + track.h, thumb.y + thumb.h) else thumb.y + thumb.h;
    if (right <= left or bottom <= top) return;

    const s = scaleOf(cr);
    var dx: f64 = left;
    var dy: f64 = top;
    c.cairo_user_to_device(cr, &dx, &dy);
    const inset_x: f32 = @floatCast((dx - @floor(dx)) / s);
    const inset_y: f32 = @floatCast((dy - @floor(dy)) / s);

    var layer = Layer.begin(cr, .{
        .x = left - inset_x,
        .y = top - inset_y,
        .w = right - left + inset_x,
        .h = bottom - top + inset_y,
    }) orelse return;

    var local = look;
    local.track.x = track.x - left + inset_x;
    local.track.y = track.y - top + inset_y;
    local.rect.x = thumb.x - left + inset_x;
    local.rect.y = thumb.y - top + inset_y;

    scrollbar.paintTrack(&layer.renderer, local);

    if (pointer) |p| {
        if (local.track_relief != .flat) {
            const groove: button.Rect = .{
                .x = local.track.x,
                .y = local.track.y,
                .w = local.track.w,
                .h = local.track.h,
            };
            const sample = button.sampleProximity(
                groove,
                @floatCast(p.x - left + inset_x),
                @floatCast(p.y - top + inset_y),
                groove,
            );
            button.paintProximityGlowAt(
                &layer.renderer,
                groove,
                local.track_radius,
                sample.distance,
                sample.x,
                sample.y,
            );
        }
    }

    scrollbar.paintThumb(&layer.renderer, local);
    layer.finish();
}

/// Draws `str` with its pen at `x` and baseline at `y`, like
/// `cairo_show_text`, in the context's current (solid) source colour.
pub fn drawText(cr_any: *anyopaque, str: []const u8, x: f64, y: f64, size: f64, bold: bool) void {
    drawTextFont(cr_any, str, x, y, size, fontOf(bold));
}

/// Explicit face for terminal cells; uses the same shaping/fallback and
/// device-pixel placement as ordinary client text.
pub fn drawTextFont(cr_any: *anyopaque, str: []const u8, x: f64, y: f64, size: f64, font: text.Font) void {
    drawStyledText(cr_any, str, x, y, size, font, false);
}

pub fn drawStyledText(cr_any: *anyopaque, str: []const u8, x: f64, y: f64, size: f64, font: text.Font, italic: bool) void {
    if (str.len == 0) return;
    const cr: *c.cairo_t = @ptrCast(cr_any);
    const s = scaleOf(cr);
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
        .italic = italic,
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

/// Whether any of `box` (user space) lies inside the context's clip.
pub fn clipTouches(cr_any: *anyopaque, box: Rect) bool {
    var x0: f64 = 0;
    var y0: f64 = 0;
    var x1: f64 = 0;
    var y1: f64 = 0;
    c.cairo_clip_extents(@ptrCast(cr_any), &x0, &y0, &x1, &y1);
    return box.w > 0 and box.h > 0 and box.x < x1 and box.x + box.w > x0 and box.y < y1 and box.y + box.h > y0;
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

    /// `begin`, or null when the context's clip leaves none of `box`
    /// visible. For components that only paint: a partial repaint then
    /// skips rasterizing everything outside its clip.
    pub fn beginVisible(cr_any: *anyopaque, box: Rect) ?Layer {
        if (!clipTouches(cr_any, box)) return null;
        return begin(cr_any, box);
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

test "Cairo proximity glow respects the visible clip" {
    const saved_theme = theme.global;
    defer theme.global = saved_theme;

    var glowing = theme.global;
    glowing.button_hover_glow_enabled = true;
    glowing.border_glow = .{ 1, 0, 0, 0.8 };
    glowing.border_glow_reach = 20;
    glowing.border_glow_length = 32;
    glowing.border_glow_depth = 3;
    theme.global = glowing;

    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 80, 40) orelse return error.Cairo;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return error.Cairo;
    defer c.cairo_destroy(cr);

    drawProximityGlow(
        cr,
        .{ .x = 10, .y = 10, .w = 40, .h = 20 },
        4,
        .{ .x = 30, .y = 7 },
        .{ .x = 20, .y = 10, .w = 20, .h = 20 },
    );
    c.cairo_surface_flush(surface);

    const pixels: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(surface)));
    try std.testing.expect(pixels[10 * 80 + 30] != 0);
    try std.testing.expectEqual(@as(u32, 0), pixels[10 * 80 + 15]);
    try std.testing.expectEqual(@as(u32, 0), pixels[10 * 80 + 45]);
}

test "Cairo proximity glow under a context clip matches the unclipped pixels" {
    const saved_theme = theme.global;
    defer theme.global = saved_theme;
    var glowing = theme.global;
    glowing.button_hover_glow_enabled = true;
    glowing.border_glow = .{ 1, 0, 0, 0.8 };
    glowing.border_glow_reach = 56;
    glowing.border_glow_length = 72;
    glowing.border_glow_depth = 3;
    theme.global = glowing;

    const W = 300;
    const H = 240;
    var images: [2]*c.cairo_surface_t = undefined;
    for (&images, 0..) |*image, pass| {
        image.* = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, W, H) orelse return error.Cairo;
        const cr = c.cairo_create(image.*) orelse return error.Cairo;
        defer c.cairo_destroy(cr);
        c.cairo_scale(cr, 1.5, 1.5);
        c.cairo_translate(cr, 0, 7);
        // The second pass repaints only a band across the lit top edge.
        if (pass == 1) {
            c.cairo_rectangle(cr, 30, 30, 100, 30);
            c.cairo_clip(cr);
        }
        drawProximityGlow(cr, .{ .x = 20.3, .y = 25.6, .w = 150, .h = 110 }, 7, .{ .x = 60, .y = 22 }, null);
        // A pointer far outside the reach paints nothing.
        drawProximityGlow(cr, .{ .x = 20.3, .y = 25.6, .w = 30, .h = 20 }, 7, .{ .x = 190, .y = 140 }, null);
        c.cairo_surface_flush(image.*);
    }
    defer for (images) |image| c.cairo_surface_destroy(image);
    const full: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(images[0])));
    const part: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(images[1])));
    var lit: usize = 0;
    for (0..H) |y| for (0..W) |x| {
        const i = y * W + x;
        // Device pixels wholly inside the clip: x 45..195, y 55.5..100.5.
        const inside = x >= 45 and x < 195 and y >= 56 and y < 100;
        if (!inside) {
            if (y < 55 or y > 100 or x < 45 or x >= 195) try std.testing.expectEqual(@as(u32, 0), part[i]);
            continue;
        }
        if (part[i] != 0) lit += 1;
        inline for (.{ 0, 8, 16, 24 }) |shift| {
            const a: i32 = @intCast((full[i] >> shift) & 0xff);
            const b: i32 = @intCast((part[i] >> shift) & 0xff);
            try std.testing.expect(@abs(a - b) <= 1);
        }
    };
    try std.testing.expect(lit > 0);
}

test "Cairo scrollbar groove glow stays beneath the thumb" {
    const saved_theme = theme.global;
    defer theme.global = saved_theme;

    var palette = theme.global;
    palette.button_hover_glow_enabled = true;
    palette.border_glow = .{ 1, 0, 0, 0.8 };
    palette.border_glow_reach = 24;
    palette.border_glow_length = 64;
    palette.border_glow_depth = 4;
    palette.scrollbar_track_relief = .inset;
    palette.scrollbar_thumb = .{ 0, 0, 1, 1 };
    theme.global = palette;

    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 40, 60) orelse return error.Cairo;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return error.Cairo;
    defer c.cairo_destroy(cr);

    const geometry = scrollbar.Geometry.compute(
        .vertical,
        .{ .x = 20, .y = 0, .w = 14, .h = 60 },
        60,
        120,
        0,
    ).?;
    const look = scrollbar.look(geometry, .{}, 8, palette);

    drawScrollbar(cr, look);
    c.cairo_surface_flush(surface);
    const pixels: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(surface)));
    var baseline: [40 * 60]u32 = undefined;
    @memcpy(baseline[0..], pixels[0..baseline.len]);

    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
    drawScrollbarAt(cr, look, .{ .x = 27, .y = 58 });
    c.cairo_surface_flush(surface);

    const groove_pixel = 58 * 40 + 27;
    const thumb_pixel = 15 * 40 + 27;
    try std.testing.expect(pixels[groove_pixel] != baseline[groove_pixel]);
    try std.testing.expectEqual(baseline[thumb_pixel], pixels[thumb_pixel]);
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
    // No groove unless the theme cuts one: nothing below the thumb.
    try std.testing.expectEqual(@as(u32, 0), data[45 * 40 + 27]);
    // With one, the channel continues below it.
    var needs_track_layer = palette;
    needs_track_layer.scrollbar_track_relief = .inset;
    drawScrollbar(cr, scrollbar.look(g, .{}, 8, needs_track_layer));
    c.cairo_surface_flush(surface);
    try std.testing.expect(data[45 * 40 + 27] != 0);

    // A raised thumb gets a layer large enough for its shadows, even with
    // no groove. The relief remains confined to the channel.
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
    var raised = palette;
    raised.scrollbar_glow = 0;
    raised.scrollbar_thumb_relief = .raised;
    raised.relief_depth = 2;
    raised.relief_softness = 3;
    raised.relief_dark = .{ 0, 0, 0, 0.6 };
    raised.relief_light = .{ 1, 1, 1, 0.6 };

    // The Cairo layer obtains its renderer palette from theme.global.
    const saved_theme = theme.global;
    defer theme.global = saved_theme;
    theme.global = raised;

    drawScrollbar(cr, scrollbar.look(g, .{}, 8, raised));
    c.cairo_surface_flush(surface);
    // The channel starts at x=21; the thumb starts at x=24.
    try std.testing.expect(data[12 * 40 + 23] != 0);
    try std.testing.expectEqual(@as(u32, 0), data[12 * 40 + 20]);
    try std.testing.expectEqual(@as(u32, 0), data[12 * 40 + 33]);

    // Engaged thumbs share the shell raster, including fractional placement,
    // Cairo translation and clipping. The highlight remains inside the thumb.
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
    c.cairo_scale(cr, 1.5, 1.5);
    c.cairo_translate(cr, 0.25, 0.5);
    palette.scrollbar_track = .{ 0.1, 0.1, 0.1, 1 };
    palette.scrollbar_track_stripe = .{ 0.25, 0.25, 0.25, 1 };
    var hot = scrollbar.look(g, .{ .wide = 1, .accent = 1, .shine = 1 }, 8, palette);
    drawScrollbar(cr, hot);
    c.cairo_surface_flush(surface);
    var expected = @as([40 * 60]u32, @splat(0));
    var renderer = paint.Renderer.init(&expected, 40, 60, 1.5);
    hot.track.x += 0.25;
    hot.track.y += 0.5;
    hot.rect.x += 0.25;
    hot.rect.y += 0.5;
    scrollbar.paint(&renderer, hot);
    try std.testing.expectEqualSlices(u32, &expected, data[0..expected.len]);
}

/// A determinate progress ring. Updates follow its data; no frame clock.
pub fn drawProgressRing(cr_any: *anyopaque, box: ItemBox, fraction: f64, color: [4]f32) void {
    const cr: *c.cairo_t = @ptrCast(cr_any);
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    const radius = @max(0, @min(box.w, box.h) / 2 - 3);
    const x = box.x + box.w / 2;
    const y = box.y + box.h / 2;
    c.cairo_set_line_width(cr, 2);
    var track = theme.global.window_fg;
    track[3] *= 0.2;
    setSource(cr, track);
    c.cairo_arc(cr, x, y, radius, 0, 2 * std.math.pi);
    c.cairo_stroke(cr);
    const amount = std.math.clamp(fraction, 0, 1);
    if (amount > 0) {
        setSource(cr, color);
        c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
        c.cairo_arc(cr, x, y, radius, -std.math.pi / 2.0, -std.math.pi / 2.0 + 2 * std.math.pi * amount);
        c.cairo_stroke(cr);
    }
}
