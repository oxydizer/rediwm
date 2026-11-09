//! Optional angled label behind a single window title. Tabs keep their own look.
const std = @import("std");
const chrome = @import("chrome.zig");
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
    const own = shape.sdPolygon(p, px, py);
    const outline = state.outline orelse return own;
    return @max(own, shape.sdPolygon(outline, px, py) + theme.global.window_title_plate_inset * state.density);
}

/// What the plate takes from the outline, for the titlebar memo: 0 without one.
pub fn outlineKey(state: chrome.ChromeState) u64 {
    const outline = state.outline orelse return 0;
    if (state.tabs.tabs.len > 0 or theme.global.window_title_plate[3] <= 0) return 0;
    return std.hash.Wyhash.hash(outline.count, std.mem.sliceAsBytes(outline.points[0..outline.count])) | 1;
}

pub fn color() @import("chrome_paint.zig").Color {
    return @import("chrome_paint.zig").Color.fromRgba(theme.global.window_title_plate_fg orelse theme.global.window_fg);
}
