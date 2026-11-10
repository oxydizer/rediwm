//! Optional angled label behind a single window title. Tabs keep their own look.
const std = @import("std");
const chrome = @import("chrome.zig");
const gpa = @import("main.zig").gpa;
const theme = @import("ui").theme;
const shape = @import("ui").window_shape;

/// Retained chrome must include every plate geometry input in its cache key.
pub fn geometry(t: theme.Theme) [5]f32 {
    return .{ t.window_title_plate_inset, t.window_title_plate_bevel, t.window_title_plate_slant, t.window_title_plate_control_gap, t.window_title_plate_text_padding };
}

pub fn width(frame_width: i32, state: chrome.ChromeState) f32 {
    const t = theme.global;
    if (state.tabs.tabs.len > 0 or t.window_title_plate[3] <= 0) return 0;
    const controls = chrome.controlRectScaled(state.controlsWidth(frame_width), .minimize, state.density);
    return @max(0, @min(t.window_title_plate_width * state.density, @as(f32, @floatFromInt(controls.x)) - t.window_title_plate_control_gap * state.density));
}

pub fn titleRight(frame_width: i32, state: chrome.ChromeState) ?i32 {
    const p = polygon(frame_width, state) orelse return null;
    return @intFromFloat(@floor(p.points[3][0] - theme.global.window_title_plate_text_padding * state.density));
}

pub fn polygon(frame_width: i32, state: chrome.ChromeState) ?shape.Resolved {
    const w = width(frame_width, state);
    if (w <= 0) return null;
    const t = theme.global;
    const d = state.density;
    const h = t.chrome_height * d;
    const inset = t.window_title_plate_inset * d;
    // An outline's cut corner is followed by `distance`, at the same margin
    // as the top; without one the plate keeps clear of the control insets.
    const left = (if (state.outline != null) 0 else @as(f32, @floatFromInt(state.inset_left))) + inset;
    if (w <= left or h <= 2 * inset) return null;
    // Clamp opposing cuts to the available space so narrow windows and large
    // configured bevels cannot produce crossing edges.
    const bevel = @min(t.window_title_plate_bevel * d, @min((w - left) / 2, h - 2 * inset));
    const slant = @min(t.window_title_plate_slant * h, w - left - bevel);
    var result: shape.Resolved = .{ .count = 5 };
    result.points[0..5].* = .{
        .{ left, h - inset },  .{ left, inset + bevel }, .{ left + bevel, inset },
        .{ w - slant, inset }, .{ w, h - inset },
    };
    return result;
}

/// The plate's right end, at its bottom edge.
pub fn right(p: shape.Resolved) f32 {
    return @floatCast(p.points[4][0]);
}

/// Signed distance to the plate (negative inside): its own polygon, cut by the
/// window outline moved in by the inset, so a chamfer or step in the outline is
/// followed at the same even margin as the plate's straight edges.
pub fn distance(p: shape.Resolved, state: chrome.ChromeState, px: f32, py: f32) f64 {
    return cut(shape.sdPolygon(p, px, py), state, px, py);
}

fn cut(own: f64, state: chrome.ChromeState, px: f32, py: f32) f64 {
    const outline = state.outline orelse return own;
    return @max(own, shape.sdPolygon(outline, px, py) + theme.global.window_title_plate_inset * state.density);
}

/// The plate's coverage of each device pixel at the titlebar's left end. Every
/// titlebar with this plate, scale and outline shows the same one whatever its
/// width or title, and working it out was most of a raster: the last one is
/// kept, so a resize or a title change reads it instead.
pub const Mask = struct {
    key: u64 = 0,
    width: usize = 0,
    height: usize = 0,
    coverage: []f32 = &.{},

    pub fn at(m: *const Mask, x: usize, y: usize) f32 {
        return if (x < m.width and y < m.height) m.coverage[y * m.width + x] else 0;
    }
};

var kept: Mask = .{};

pub fn mask(p: shape.Resolved, frame_width: i32, state: chrome.ChromeState, height: usize) !*const Mask {
    const scale = state.scale;
    const columns: usize = @intFromFloat(@ceil(right(p) * scale));
    var hasher = std.hash.Wyhash.init(outlineKey(frame_width, state));
    hasher.update(std.mem.sliceAsBytes(p.points[0..p.count]));
    hasher.update(std.mem.asBytes(&[2]f32{ scale, theme.global.window_title_plate_inset * state.density }));
    hasher.update(std.mem.asBytes(&[2]usize{ columns, height }));
    const key = hasher.final() | 1;
    if (kept.key == key) return &kept;
    kept.key = 0;
    kept.coverage = try gpa.realloc(kept.coverage, columns * height);
    kept.width = columns;
    kept.height = height;
    for (0..height) |y| {
        const py = (@as(f32, @floatFromInt(y)) + 0.5) / scale;
        const row = kept.coverage[y * columns ..][0..columns];
        var x: usize = 0;
        while (x < columns) {
            const px = (@as(f32, @floatFromInt(x)) + 0.5) / scale;
            // Outside the plate's own outline the window's cannot matter. A
            // distance changes by at most one per pixel, so the pixels after
            // this one are as covered as it is for as far as an edge is away.
            const own = shape.sdPolygon(p, px, py);
            const d = @as(f32, @floatCast(if (own * scale >= 0.5 + 1e-3) own else cut(own, state, px, py))) * scale;
            const run = @min(columns - x, 1 + shape.saturatedRun(d));
            @memset(row[x..][0..run], @import("ui").sdf.coverage(d));
            x += run;
        }
    }
    kept.key = key;
    return &kept;
}

/// Frees the kept mask at shutdown.
pub fn deinit() void {
    gpa.free(kept.coverage);
    kept = .{};
}

/// What the plate takes from the outline, for the titlebar memo: 0 without one.
/// Only the edges that pass within the inset of the plate cut it, so a frame
/// resized away from the plate keeps its key (and its titlebar raster).
pub fn outlineKey(frame_width: i32, state: chrome.ChromeState) u64 {
    const outline = state.outline orelse return 0;
    const p = polygon(frame_width, state) orelse return 0;
    const reach = theme.global.window_title_plate_inset * state.density + 1;
    return shape.localKey(outline, 0, 0, right(p), theme.global.chrome_height * state.density, reach) | 1;
}

pub fn color() @import("chrome_paint.zig").Color {
    return @import("chrome_paint.zig").Color.fromRgba(theme.global.window_title_plate_fg orelse theme.global.window_fg);
}
