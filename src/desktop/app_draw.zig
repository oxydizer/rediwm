//! Desktop drawing helpers: icon raster caches, names and labels.

const std = @import("std");
const App = @import("app.zig").App;
const appearance_theme = @import("ui").theme;
const shell_cairo = @import("ui").cairo;
const c = @import("c.zig").api;
const grid = @import("grid.zig");
const watcher = @import("watcher.zig");
const text = @import("ui").text;
const a = std.heap.c_allocator;
const Icon = @import("app.zig").Icon;
const deinit = App.deinit;

pub fn iconPattern(cr: *c.cairo_t, ic: *Icon, key: IconRaster.Key, name: []const u8, cached: bool) ?*c.cairo_pattern_t {
    if (cached and ic.raster.pattern != null and std.meta.eql(ic.raster.key, key) and
        (key.renaming or (ic.name_cache.surface != null and std.mem.eql(u8, ic.name_cache.name, name))))
    {
        return c.cairo_pattern_reference(ic.raster.pattern);
    }
    const r = key.rect;
    // Cells stretch to fill the output; the icon and label keep the size they
    // were designed at (a 96px cell) and stay centred in whatever the cell got.
    const ox = r.x + @divTrunc(r.w - grid.width, 2);
    c.cairo_save(cr);
    // Unbounded groups allocate/clear/composite an output-sized image
    // for *every icon*. Retain the group for identical alpha blending,
    // but restrict its storage to this icon's bounds. Its raster clip
    // is independent of damage: clipping a rounded arc part-way across
    // the icon also changes Cairo's coverage rounding at scale 2.
    c.cairo_reset_clip(cr);
    c.cairo_rectangle(cr, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
    c.cairo_clip(cr);
    c.cairo_push_group(cr);
    if (ic.selection_amount > 0 or ic.hover_amount > 0) {
        rounded(cr, r.x, r.y, r.w, if (key.renaming) 68 else r.h, 8);
        const t = appearance_theme.global;
        const selected = t.desktopSelectedColor();
        var fill: [4]f32 = undefined;
        for (0..3) |i| fill[i] = @floatCast(t.desktop_hover[i] + (selected[i] - t.desktop_hover[i]) * ic.selection_amount);
        fill[3] = @floatCast(selected[3] * ic.selection_amount + t.desktop_hover[3] * ic.hover_amount * (1 - ic.selection_amount));
        shell_cairo.setSource(cr, fill);
        c.cairo_fill(cr);
    }
    c.cairo_save(cr);
    if (key.pulse != 1) {
        c.cairo_translate(cr, @floatFromInt(ox + 48), @floatFromInt(r.y + 36));
        c.cairo_scale(cr, key.pulse, key.pulse);
        c.cairo_translate(cr, @floatFromInt(-ox - 48), @floatFromInt(-r.y - 36));
    }
    if (ic.item.icon) |icon| {
        const surface = c.cairo_image_surface_create_for_data(@ptrCast(@constCast(icon.pixels.ptr)), c.CAIRO_FORMAT_ARGB32, icon.size, icon.size, icon.size * 4);
        defer c.cairo_surface_destroy(surface);
        // An icon loaded for this density (not pulsing) is copied 1:1.
        const raster = RasterScale.of(cr);
        if (raster.aligned and raster.pixels(56) == icon.size) {
            if (surface) |image| paintRaster(cr, image, ox + 20, r.y + 8, raster);
        } else {
            c.cairo_save(cr);
            c.cairo_translate(cr, @floatFromInt(ox + 20), @floatFromInt(r.y + 8));
            c.cairo_scale(cr, 56.0 / @as(f64, @floatFromInt(icon.size)), 56.0 / @as(f64, @floatFromInt(icon.size)));
            c.cairo_set_source_surface(cr, surface, 0, 0);
            c.cairo_paint(cr);
            c.cairo_restore(cr);
        }
    } else {
        rounded(cr, ox + 20, r.y + 8, 56, 56, 12);
        const grad = c.cairo_pattern_create_linear(0, @floatFromInt(r.y), 0, @floatFromInt(r.y + 64));
        const start = appearance_theme.global.desktop_icon_start;
        const end = appearance_theme.global.desktop_icon_end;
        c.cairo_pattern_add_color_stop_rgba(grad, 0, start[0], start[1], start[2], start[3]);
        c.cairo_pattern_add_color_stop_rgba(grad, 1, end[0], end[1], end[2], end[3]);
        c.cairo_set_source(cr, grad);
        c.cairo_fill(cr);
        c.cairo_pattern_destroy(grad);
        const n = if (ic.item.name.len > 0) std.unicode.utf8ByteSequenceLength(ic.item.name[0]) catch 1 else 0;
        label(cr, ic.item.name[0..@min(n, ic.item.name.len)], ox + 20, r.y + 20, 56, 26, false);
    }
    c.cairo_restore(cr);
    if (ic.selection_amount > 0 and !key.renaming) {
        rounded(cr, ox + 4, r.y + 71, 88, 34, 3);
        var fill = appearance_theme.global.desktopSelectionColor();
        fill[3] *= @floatCast(ic.selection_amount);
        shell_cairo.setSource(cr, fill);
        c.cairo_fill(cr);
    }
    if (!key.renaming) ic.name_cache.draw(cr, name, ox + 4, r.y + 72);
    const group = c.cairo_pop_group(cr);
    c.cairo_restore(cr);
    if (cached and c.cairo_pattern_status(group) == c.CAIRO_STATUS_SUCCESS) {
        ic.raster.deinit();
        ic.raster.pattern = c.cairo_pattern_reference(group);
        ic.raster.key = key;
    }
    return group;
}

pub fn sameImage(current: ?@import("wallpaper.zig").Image, next: ?@import("wallpaper.zig").Image) bool {
    const x = current orelse return next == null;
    const y = next orelse return false;
    return x.w == y.w and x.h == y.h and x.mode == y.mode and std.mem.eql(u32, x.pixels, y.pixels);
}

pub fn copyItem(item: watcher.Item) !watcher.Item {
    var out = item;
    out.path = try a.dupe(u8, item.path);
    errdefer a.free(out.path);
    out.name = try a.dupe(u8, item.name);
    errdefer a.free(out.name);
    out.exec = try a.dupe(u8, item.exec);
    return out;
}
pub fn freeItem(item: watcher.Item) void {
    a.free(item.path);
    a.free(item.name);
    a.free(item.exec);
}
pub fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1000000);
}
pub fn rounded(cr: *c.cairo_t, x: i32, y: i32, w: i32, h: i32, r: f64) void {
    const xx: @TypeOf(r) = @floatFromInt(x);
    const yy: @TypeOf(r) = @floatFromInt(y);
    const ww: @TypeOf(r) = @floatFromInt(w);
    const hh: @TypeOf(r) = @floatFromInt(h);
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, xx + ww - r, yy + r, r, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, xx + ww - r, yy + hh - r, r, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, xx + r, yy + hh - r, r, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, xx + r, yy + r, r, std.math.pi, 3 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
}
/// One bounded raster per icon, including its selection/hover decoration. A
/// frame's damage can cross an icon repeatedly without rebuilding its curves,
/// icon texture and label; settled icons keep the same raster across frames.
pub const IconRaster = struct {
    pattern: ?*c.cairo_pattern_t = null,
    key: Key = undefined,

    pub const Context = struct {
        matrix: c.cairo_matrix_t,
        size: [2]i32,
        device_scale: [2]f64,
        device_offset: [2]f64,

        pub fn from(cr: *c.cairo_t) Context {
            const target = c.cairo_get_group_target(cr);
            var result: Context = undefined;
            c.cairo_get_matrix(cr, &result.matrix);
            result.size = .{ c.cairo_image_surface_get_width(target), c.cairo_image_surface_get_height(target) };
            c.cairo_surface_get_device_scale(target, &result.device_scale[0], &result.device_scale[1]);
            c.cairo_surface_get_device_offset(target, &result.device_offset[0], &result.device_offset[1]);
            return result;
        }
    };
    pub const Key = struct {
        context: Context,
        rect: grid.Rect,
        hover: f64,
        selection: f64,
        pulse: f64,
        renaming: bool,
    };

    pub fn deinit(self: *IconRaster) void {
        if (self.pattern) |pattern| c.cairo_pattern_destroy(pattern);
        self.pattern = null;
    }
};

pub const NameCache = struct {
    surface: ?*c.cairo_surface_t = null,
    name: []const u8 = &.{},
    scale: RasterScale = .{ .value = 0, .aligned = false },

    pub fn deinit(self: *NameCache) void {
        if (self.surface) |surface| c.cairo_surface_destroy(surface);
        a.free(self.name);
        self.* = .{};
    }

    pub fn draw(self: *NameCache, cr: *c.cairo_t, name: []const u8, x: i32, y: i32) void {
        const scale = RasterScale.of(cr);
        if (self.surface == null or !std.meta.eql(self.scale, scale) or !std.mem.eql(u8, self.name, name)) {
            self.deinit();
            const owned = a.dupe(u8, name) catch return drawName(cr, name, x, y);
            const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, scale.pixels(88), scale.pixels(32)) orelse {
                a.free(owned);
                return drawName(cr, name, x, y);
            };
            if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
                c.cairo_surface_destroy(surface);
                a.free(owned);
                return drawName(cr, name, x, y);
            }
            const cached_cr = c.cairo_create(surface).?;
            c.cairo_scale(cached_cr, scale.value, scale.value);
            drawName(cached_cr, name, 0, 0);
            c.cairo_destroy(cached_cr);
            self.* = .{ .surface = surface, .name = owned, .scale = scale };
        }
        paintRaster(cr, self.surface.?, x, y, self.scale);
    }
};

pub fn drawName(cr: *c.cairo_t, name: []const u8, x: i32, y: i32) void {
    var split: usize = name.len;
    if ((text.measureWidth(name, .manrope_bold, appearance_theme.global.desktop_text_size, 1) catch 0) > 88) {
        var it = std.mem.splitScalar(u8, name, ' ');
        var end: usize = 0;
        while (it.next()) |word| {
            const next = end + word.len;
            if (next > name.len) break;
            if ((text.measureWidth(name[0..next], .manrope_bold, appearance_theme.global.desktop_text_size, 1) catch 0) > 88) break;
            split = next;
            end = next + 1;
        }
    }
    label(cr, name[0..split], x, y, 88, 16, true);
    if (split < name.len) label(cr, std.mem.trimStart(u8, name[split..], " "), x, y + 16, 88, 16, true);
}
/// The scale to rasterize at for `cr`: exactly its device scale when that is
/// uniform (fractional outputs included), so `paintRaster` can copy pixels
/// 1:1; otherwise the next whole scale, resampled.
pub const RasterScale = struct {
    value: f64,
    aligned: bool,

    pub fn of(cr: *c.cairo_t) RasterScale {
        var m: c.cairo_matrix_t = undefined;
        c.cairo_get_matrix(cr, &m);
        if (m.xy == 0 and m.yx == 0 and m.xx == m.yy and m.xx >= 1 and m.xx <= 4) return .{ .value = m.xx, .aligned = true };
        return .{ .value = std.math.clamp(@ceil(@abs(m.xx)), 1, 4), .aligned = false };
    }

    pub fn pixels(self: RasterScale, logical: i32) i32 {
        return @intFromFloat(@ceil(@as(f64, @floatFromInt(logical)) * self.value));
    }
};

/// Paints a raster made at `scale` with its origin at logical (x, y). An
/// aligned raster lands on the nearest whole device pixel with no filtering,
/// so fractional scales stay as sharp as integer ones.
pub fn paintRaster(cr: *c.cairo_t, surface: *c.cairo_surface_t, x: i32, y: i32, scale: RasterScale) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    if (scale.aligned) {
        var dx: f64 = @floatFromInt(x);
        var dy: f64 = @floatFromInt(y);
        c.cairo_user_to_device(cr, &dx, &dy);
        c.cairo_identity_matrix(cr);
        c.cairo_set_source_surface(cr, surface, @round(dx), @round(dy));
    } else {
        c.cairo_translate(cr, @floatFromInt(x), @floatFromInt(y));
        c.cairo_scale(cr, 1.0 / scale.value, 1.0 / scale.value);
        c.cairo_set_source_surface(cr, surface, 0, 0);
    }
    c.cairo_paint(cr);
}

pub fn themeInk(color: [4]f32) text.Color {
    return .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
}

pub fn label(cr: *c.cairo_t, s: []const u8, x: i32, y: i32, w: i32, h: i32, shadow: bool) void {
    if (w <= 0 or h <= 0) return;
    const raster = RasterScale.of(cr);
    const scale: f32 = @floatCast(raster.value);
    const pw = raster.pixels(w);
    const ph = raster.pixels(h);
    const pixels = a.alloc(u32, @intCast(pw * ph)) catch return;
    defer a.free(pixels);
    @memset(pixels, 0);
    const tw = @min(w, text.measureWidth(s, .manrope_bold, appearance_theme.global.desktop_text_size, 1) catch w);
    const tx = @divTrunc(w - tw, 2);
    if (shadow) {
        for ([_]i32{ -1, 0, 1 }) |dx| for ([_]i32{ 0, 1, 2 }) |dy| {
            text.draw(pixels, pw, ph, .{ .x = @max(0, tx + dx), .y = dy, .w = w - @max(0, tx + dx), .h = h }, s, themeInk(appearance_theme.global.desktop_text_shadow), scale, .manrope_bold, appearance_theme.global.desktop_text_size) catch {};
        };
    }
    text.draw(pixels, pw, ph, .{ .x = tx, .y = 0, .w = w - tx, .h = h }, s, themeInk(appearance_theme.global.desktop_fg), scale, .manrope_bold, appearance_theme.global.desktop_text_size) catch {};
    const surface = c.cairo_image_surface_create_for_data(@ptrCast(pixels.ptr), c.CAIRO_FORMAT_ARGB32, pw, ph, pw * 4) orelse return;
    defer c.cairo_surface_destroy(surface);
    paintRaster(cr, surface, x, y, raster);
}
