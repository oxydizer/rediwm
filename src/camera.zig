// Pure world/layout camera geometry. Layout = O + zoom * (world - O - C).
// Source geometry remains integral; the presentation adapter rounds projected
// endpoints once, retaining fractional camera motion between input events.
const std = @import("std");
const anim = @import("ui").anim;

pub const Offset = struct {
    x: i32,
    y: i32,
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const RevealDelta = struct {
    dx: i32,
    dy: i32,
};

/// Accumulated fractional camera offset (not yet rounded to the scene tree).
pub const default_zoom_levels = [_]u8{ 100, 85, 70, 55 };
/// Live zoom table. Defaults to `default_zoom_levels`; config hot-reload may
/// point this at a longer or shorter slice owned by the current Config arena.
pub var zoom_levels: []const u8 = &default_zoom_levels;
pub const Vec = struct { x: f64, y: f64 };

pub const FocusZoom = @import("config").types.FocusZoom;

/// A temporary presentation scale; the window's saved zoom stays unchanged.
pub fn boostedScale(window: f64, desktop: f64, mix: f64) f64 {
    const amount = std.math.clamp(mix, 0, 1);
    return window * (1 - amount) + amount / desktop;
}

/// Camera zoom never magnifies beyond 100%, even with custom window steps.
pub fn zoomPercentAtIndex(index: usize) u8 {
    if (zoom_levels.len == 0) return 100;
    return @min(100, zoom_levels[@min(index, zoom_levels.len - 1)]);
}

/// Discrete camera zoom as a scale factor. Empty tables are treated as 1×.
pub fn zoomAtIndex(index: usize) f64 {
    return @as(f64, @floatFromInt(zoomPercentAtIndex(index))) / 100;
}

/// Closest discrete zoom table entry to a continuous scale. Ties keep the
/// earlier (typically larger) step so a pinch that lands halfway snaps out.
pub fn nearestIndex(z: f64) usize {
    if (zoom_levels.len == 0) return 0;
    var best: usize = 0;
    var best_d: f64 = std.math.inf(f64);
    for (zoom_levels, 0..) |pct, i| {
        const step = @as(f64, @floatFromInt(@min(pct, 100))) / 100;
        const d = @abs(z - step);
        if (d < best_d) {
            best = i;
            best_d = d;
        }
    }
    return best;
}

pub const Limits = struct {
    lo_x: f64,
    hi_x: f64,
    lo_y: f64,
    hi_y: f64,
};

/// Offset range that keeps the expanded world reachable at `zoom`.
pub fn offsetLimits(bounds: Bounds, zoom: f64) Limits {
    const z = if (zoom > 1e-6) zoom else 1;
    return .{
        .lo_x = -bounds.max_x,
        .hi_x = bounds.max_x - bounds.width * (1 / z - 1),
        .lo_y = -bounds.max_y,
        .hi_y = bounds.max_y - bounds.height * (1 / z - 1),
    };
}

/// Apple-style rubber band in camera-offset space. `dimension` is the
/// viewport size along that axis (`bounds.width` / `bounds.height`).
pub fn rubberBand(value: f64, lo: f64, hi: f64, dimension: f64) f64 {
    const c: f64 = anim.rubber_c;
    const d = if (dimension > 0) dimension else 1;
    if (value < lo) {
        const x = lo - value;
        return lo - (1.0 - 1.0 / (x * c / d + 1.0)) * d;
    }
    if (value > hi) {
        const x = value - hi;
        return hi + (1.0 - 1.0 / (x * c / d + 1.0)) * d;
    }
    return value;
}

pub const Camera = struct {
    offset_x: f64 = 0,
    offset_y: f64 = 0,
    zoom_index: usize = 0,
    /// Continuous visual zoom. Defaults to 1× so `Camera{}` matches index 0.
    zoom_value: f64 = 1,
    /// Only explicit camera focus permits magnification. Keep the old limit
    /// during the transition back to ordinary desktop zoom.
    zoom_limit: f64 = 1,
    focus_zoom: ?f64 = null,

    pub fn targetZoom(self: Camera) f64 {
        return self.focus_zoom orelse zoomAtIndex(self.zoom_index);
    }

    pub fn targetPercent(self: Camera) u16 {
        return @intFromFloat(@round(self.targetZoom() * 100));
    }

    pub fn zoom(self: Camera) f64 {
        return if (self.zoom_value > 0) @min(self.zoom_value, self.zoom_limit) else self.targetZoom();
    }
    pub fn toLayout(self: Camera, bounds: Bounds, x: f64, y: f64) Vec {
        return .{ .x = bounds.origin_x + self.zoom() * (x - bounds.origin_x - self.offset_x), .y = bounds.origin_y + self.zoom() * (y - bounds.origin_y - self.offset_y) };
    }
    pub fn toWorld(self: Camera, bounds: Bounds, x: f64, y: f64) Vec {
        return .{ .x = bounds.origin_x + self.offset_x + (x - bounds.origin_x) / self.zoom(), .y = bounds.origin_y + self.offset_y + (y - bounds.origin_y) / self.zoom() };
    }
    pub fn setZoom(self: *Camera, bounds: Bounds, index: usize, anchor: Vec) void {
        const point = self.toWorld(bounds, anchor.x, anchor.y);
        self.focus_zoom = null;
        self.zoom_limit = 1;
        self.zoom_index = @min(index, zoom_levels.len -| 1);
        self.placeZoom(bounds, zoomAtIndex(self.zoom_index), point, anchor);
    }
    /// Keep `world_point` under `anchor` at `zoom`, then clamp.
    pub fn placeZoom(self: *Camera, bounds: Bounds, zoom_scale: f64, world_point: Vec, anchor: Vec) void {
        const z = if (zoom_scale > 1e-6) @min(zoom_scale, self.zoom_limit) else 1;
        self.zoom_value = z;
        self.offset_x = world_point.x - bounds.origin_x - (anchor.x - bounds.origin_x) / z;
        self.offset_y = world_point.y - bounds.origin_y - (anchor.y - bounds.origin_y) / z;
        self.clamp(bounds);
    }
    pub fn clamp(self: *Camera, bounds: Bounds) void {
        const limits = offsetLimits(bounds, self.zoom());
        self.offset_x = clampAxis(self.offset_x, limits.lo_x, limits.hi_x);
        self.offset_y = clampAxis(self.offset_y, limits.lo_y, limits.hi_y);
    }
};

/// Reveal a mostly hidden window in the work area. Large frames keep their
/// title and left edge reachable; ordinary frames are centered, like the
/// prototype. A small visible sliver is not enough to skip navigation.
pub fn focusOffset(cam: Camera, bounds: Bounds, origin: Vec, size: Vec, usable: Vec, area: Vec, force: bool) ?Vec {
    if (size.x <= 0 or size.y <= 0 or area.x <= 0 or area.y <= 0) return null;
    const a = cam.toLayout(bounds, origin.x, origin.y);
    const w = size.x * cam.zoom();
    const h = size.y * cam.zoom();
    const overlap_x = @max(0, @min(a.x + w, usable.x + area.x) - @max(a.x, usable.x));
    const overlap_y = @max(0, @min(a.y + h, usable.y + area.y) - @max(a.y, usable.y));
    if (!force and overlap_x * overlap_y >= 0.35 * @min(w * h, area.x * area.y)) return null;
    const x = usable.x + @max(0, (area.x - w) / 2);
    const y = usable.y + @max(0, (area.y - h) / 2);
    var result = cam;
    result.offset_x += (a.x - x) / cam.zoom();
    result.offset_y += (a.y - y) / cam.zoom();
    result.clamp(bounds);
    return .{ .x = result.offset_x, .y = result.offset_y };
}
fn clampAxis(value: f64, lo: f64, hi: f64) f64 {
    return if (hi < lo) (lo + hi) / 2 else std.math.clamp(value, lo, hi);
}
/// Minimum world extents are origin-max through origin+layout_size+max.
pub const Bounds = struct {
    max_x: f64 = 0,
    max_y: f64 = 0,
    origin_x: f64 = 0,
    origin_y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
};

/// Scroll normalization shared by physical and synthetic input. Discrete values
/// are Wayland v120 units; continuous finger motion uses 40 logical units.
pub const ZoomScroll = struct {
    remainder: f64 = 0,
    source: ?u32 = null,
    pub fn reset(self: *ZoomScroll) void {
        self.* = .{};
    }
    pub fn feed(self: *ZoomScroll, discrete: i32, delta: f64, source: u32) i32 {
        if (delta == 0 and discrete == 0) {
            self.reset();
            return 0;
        }
        const amount = if (discrete != 0) @as(f64, @floatFromInt(discrete)) / 120 else delta / 40;
        if (!std.math.isFinite(amount)) return 0;
        if (self.source != source or self.remainder * amount < 0) self.remainder = 0;
        self.source = source;
        self.remainder += amount;
        const steps: i32 = @intFromFloat(std.math.clamp(@trunc(self.remainder), -3, 3));
        self.remainder -= @as(f64, @floatFromInt(steps));
        return steps;
    }
};

/// World-space bounds multiplier. 3 → one extra screen-width in each
/// direction, so the camera range is ±W on x and ±H on y.
pub const default_multiplier: f64 = 3;

/// Compute camera bounds for the given output layout rectangle.
///
/// World bounds: (lx - W*(m-1)/2, ly - H*(m-1)/2, W*m, H*m)
/// Camera offset ranges: x ∈ [-W*(m-1)/2, W*(m-1)/2], y ∈ [-H*(m-1)/2, H*(m-1)/2]
///
/// For the default multiplier of 3 this gives one full extra screen in each
/// cardinal direction (range [-W, W], [-H, H]).
pub fn computeBounds(
    layout_x: i32,
    layout_y: i32,
    layout_w: i32,
    layout_h: i32,
    multiplier: f64,
) Bounds {
    const w: f64 = @floatFromInt(@max(0, layout_w));
    const h: f64 = @floatFromInt(@max(0, layout_h));
    const extra = @max(0.0, (multiplier - 1.0) / 2.0);
    return .{
        .origin_x = @floatFromInt(layout_x),
        .origin_y = @floatFromInt(layout_y),
        .width = w,
        .height = h,
        .max_x = w * extra,
        .max_y = h * extra,
    };
}

/// Camera offset along one axis for keyboard desktop switching. The grid holds
/// `count` desktops of `size` (the layout extent) centred on the original
/// layout. Starts from the desktop nearest the viewport centre at `offset`, so a
/// drag-panned camera snaps back onto the grid, then moves `step` desktops and
/// stops at the edge. At `zoom` < 1 the chosen desktop is centred.
pub fn desktopOffset(offset: f64, size: f64, count: u32, zoom: f64, step: i32) f64 {
    if (size <= 0) return offset;
    const z = if (zoom > 1e-6) zoom else 1;
    const last: f64 = @floatFromInt(@max(count, 1) - 1);
    const first = -size * last / 2 - size * (1 / z - 1) / 2;
    const current = std.math.clamp(@round((offset - first) / size), 0, last);
    const next = std.math.clamp(current + @as(f64, @floatFromInt(step)), 0, last);
    return first + next * size;
}

test "desktopOffset steps between grid cells and stops at the edges" {
    // 3 columns of 1000: desktops at -1000, 0, 1000.
    try std.testing.expectEqual(@as(f64, 1000), desktopOffset(0, 1000, 3, 1, 1));
    try std.testing.expectEqual(@as(f64, 1000), desktopOffset(1000, 1000, 3, 1, 1));
    try std.testing.expectEqual(@as(f64, -1000), desktopOffset(-1000, 1000, 3, 1, -1));
    // A drag left the camera between desktops: snap, then step.
    try std.testing.expectEqual(@as(f64, 0), desktopOffset(-620, 1000, 3, 1, 1));
    try std.testing.expectEqual(@as(f64, 0), desktopOffset(310, 1000, 3, 1, 0));
    // Beyond the grid (bounds grown to reach a window) counts as the edge desktop.
    try std.testing.expectEqual(@as(f64, 0), desktopOffset(4000, 1000, 3, 1, -1));
    // Even counts sit on half cells.
    try std.testing.expectEqual(@as(f64, 500), desktopOffset(-500, 1000, 2, 1, 1));
    try std.testing.expectEqual(@as(f64, 0), desktopOffset(123, 1000, 1, 1, 1));
}

test "desktopOffset centres the desktop when zoomed out" {
    // At 0.5x the view is 2000 wide; centring the right desktop
    // (world 1000..2000) puts the view's left edge at 500.
    try std.testing.expectEqual(@as(f64, 500), desktopOffset(-500, 1000, 3, 0.5, 1));
}

/// Independent screen counts, centred on the original output layout.
pub fn computeGridBounds(x: i32, y: i32, width: i32, height: i32, columns: u32, rows: u32) Bounds {
    var bounds = computeBounds(x, y, width, height, @floatFromInt(columns));
    bounds.max_y = bounds.height * @as(f64, @floatFromInt(rows -| 1)) / 2;
    return bounds;
}

test "rectangular canvas sizes include even counts and a single screen" {
    const b = computeGridBounds(-200, 100, 1000, 700, 10, 2);
    try std.testing.expectEqual(@as(f64, 4500), b.max_x);
    try std.testing.expectEqual(@as(f64, 350), b.max_y);
    const single = computeGridBounds(0, 0, 1000, 700, 1, 1);
    try std.testing.expectEqual(@as(f64, 0), single.max_x);
    try std.testing.expectEqual(@as(f64, 0), single.max_y);
}

/// Grow `bounds.max_*` so a frame at (wx, wy, w, h) stays reachable by panning
/// the camera across `usable`. No-op when the usable viewport is empty.
pub fn expandToFrame(
    bounds: *Bounds,
    wx: i32,
    wy: i32,
    w: i32,
    h: i32,
    usable_x: i32,
    usable_y: i32,
    usable_w: i32,
    usable_h: i32,
) void {
    if (usable_w <= 0 or usable_h <= 0) return;

    const ox1 = wx - usable_x;
    const ox2 = wx + w - (usable_x + usable_w);
    const oy1 = wy - usable_y;
    const oy2 = wy + h - (usable_y + usable_h);

    // Only edges outside the viewport need more pan range. Taking absolute
    // distances also counts the empty space beside an already visible window,
    // expanding even a single-screen canvas when its settings are reapplied.
    const needed_max_x: f64 = @floatFromInt(@max(0, -ox1, ox2));
    const needed_max_y: f64 = @floatFromInt(@max(0, -oy1, oy2));

    if (needed_max_x > bounds.max_x) bounds.max_x = needed_max_x;
    if (needed_max_y > bounds.max_y) bounds.max_y = needed_max_y;
}

/// Returned by applyMotion — carries both the f64 delta that was actually
/// consumed and the new integer-rounded camera offset.
pub const MotionResult = struct {
    applied_dx: f64,
    applied_dy: f64,
    offset_x: i32,
    offset_y: i32,
};

/// Clamp each axis independently. When the camera is at a boundary and the
/// caller requests more motion in the same direction it is silently dropped.
/// When the caller reverses direction the overshoot is not deducted — motion
/// starts immediately from the boundary.
///
/// `dx` and `dy` are the delta to add to `camera.offset_x` and `camera.offset_y`.
/// Note: to follow the hand when dragging by pointer delta (pdx, pdy),
/// the camera offset delta is (-pdx, -pdy).
///
/// Updates `camera` in-place and returns what was actually applied plus the
/// new rounded offset.
pub fn applyMotion(
    camera: *Camera,
    dx: f64,
    dy: f64,
    bounds: Bounds,
) MotionResult {
    const limits = offsetLimits(bounds, camera.zoom());
    const new_x = clampAxis(camera.offset_x + dx, limits.lo_x, limits.hi_x);
    const new_y = clampAxis(camera.offset_y + dy, limits.lo_y, limits.hi_y);

    const applied_dx = new_x - camera.offset_x;
    const applied_dy = new_y - camera.offset_y;

    camera.offset_x = new_x;
    camera.offset_y = new_y;

    return .{
        .applied_dx = applied_dx,
        .applied_dy = applied_dy,
        .offset_x = @intFromFloat(@round(camera.offset_x)),
        .offset_y = @intFromFloat(@round(camera.offset_y)),
    };
}

/// Like `applyMotion`, but past `Limits` the surface follows with falling
/// gain instead of stopping. `raw_x`/`raw_y` accumulate the unconstrained
/// gesture offset; the camera stores the rubber-banded visual.
pub fn applyMotionRubber(
    camera: *Camera,
    dx: f64,
    dy: f64,
    bounds: Bounds,
    raw_x: *f64,
    raw_y: *f64,
) MotionResult {
    raw_x.* += dx;
    raw_y.* += dy;
    const limits = offsetLimits(bounds, camera.zoom());
    const dim_x = if (bounds.width > 0) bounds.width else 1;
    const dim_y = if (bounds.height > 0) bounds.height else 1;
    const new_x = rubberBand(raw_x.*, limits.lo_x, limits.hi_x, dim_x);
    const new_y = rubberBand(raw_y.*, limits.lo_y, limits.hi_y, dim_y);

    const applied_dx = new_x - camera.offset_x;
    const applied_dy = new_y - camera.offset_y;

    camera.offset_x = new_x;
    camera.offset_y = new_y;

    return .{
        .applied_dx = applied_dx,
        .applied_dy = applied_dy,
        .offset_x = @intFromFloat(@round(camera.offset_x)),
        .offset_y = @intFromFloat(@round(camera.offset_y)),
    };
}

/// Rounded offset for the existing integer IPC representation. Rendering uses f64.
pub fn appliedOffset(camera: Camera) Offset {
    return .{
        .x = @intFromFloat(@round(camera.offset_x)),
        .y = @intFromFloat(@round(camera.offset_y)),
    };
}

/// Convert a layout (screen) position to world coordinates.
pub fn layoutToWorld(
    lx: i32,
    ly: i32,
    offset: Offset,
) Point {
    return .{
        .x = lx + offset.x,
        .y = ly + offset.y,
    };
}

/// Convert a world position to layout (screen) coordinates.
pub fn worldToLayout(
    wx: i32,
    wy: i32,
    offset: Offset,
) Point {
    return .{
        .x = wx - offset.x,
        .y = wy - offset.y,
    };
}

/// Compute the camera offset delta needed to bring the frame (wx,wy,w,h) into
/// the usable output area (usable_x,usable_y,usable_w,usable_h).
///
/// Prioritises making the top-left corner of the frame visible (titlebar and
/// controls). Maximized windows are aligned directly to the usable origin.
/// The returned delta is clamped so the resulting offset stays within `bounds`.
///
/// Returns a `RevealDelta` { dx, dy } to add to the camera offset.
pub fn reveal(
    wx: i32,
    wy: i32,
    w: i32,
    h: i32,
    usable_x: i32,
    usable_y: i32,
    usable_w: i32,
    usable_h: i32,
    current_offset: Offset,
    bounds: Bounds,
    is_maximized: bool,
) RevealDelta {
    // Current frame position in layout space
    const lx = wx - current_offset.x;
    const ly = wy - current_offset.y;
    const lx2 = lx + w;
    const ly2 = ly + h;

    const ux2 = usable_x + usable_w;
    const uy2 = usable_y + usable_h;

    var target_ox = current_offset.x;
    var target_oy = current_offset.y;

    if (is_maximized) {
        // Maximized windows align directly to usable origin
        target_ox = wx - usable_x;
        target_oy = wy - usable_y;
    } else {
        var shift_lx: i32 = 0;
        var shift_ly: i32 = 0;

        // X axis: prioritize top-left
        if (lx < usable_x) {
            shift_lx = usable_x - lx;
        } else if (lx2 > ux2) {
            shift_lx = ux2 - lx2;
            if (lx + shift_lx < usable_x) {
                shift_lx = usable_x - lx;
            }
        }

        // Y axis: prioritize top-left
        if (ly < usable_y) {
            shift_ly = usable_y - ly;
        } else if (ly2 > uy2) {
            shift_ly = uy2 - ly2;
            if (ly + shift_ly < usable_y) {
                shift_ly = usable_y - ly;
            }
        }

        // lx_new = lx + shift_lx => target_ox = current_ox - shift_lx
        target_ox = current_offset.x - shift_lx;
        target_oy = current_offset.y - shift_ly;
    }

    // Clamp target offset to bounds
    const max_x: i32 = @intFromFloat(bounds.max_x);
    const max_y: i32 = @intFromFloat(bounds.max_y);
    const new_ox = std.math.clamp(target_ox, -max_x, max_x);
    const new_oy = std.math.clamp(target_oy, -max_y, max_y);

    return .{
        .dx = new_ox - current_offset.x,
        .dy = new_oy - current_offset.y,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "computeBounds default multiplier" {
    const b = computeBounds(0, 0, 1920, 1080, default_multiplier);
    try std.testing.expectEqual(@as(f64, 1920), b.max_x);
    try std.testing.expectEqual(@as(f64, 1080), b.max_y);
}

test "computeBounds multiplier 5" {
    const b = computeBounds(0, 0, 1920, 1080, 5);
    try std.testing.expectEqual(@as(f64, 3840), b.max_x);
    try std.testing.expectEqual(@as(f64, 2160), b.max_y);
}

test "computeBounds non-zero layout origin" {
    const b = computeBounds(100, 200, 1920, 1080, default_multiplier);
    try std.testing.expectEqual(@as(f64, 1920), b.max_x);
    try std.testing.expectEqual(@as(f64, 1080), b.max_y);
}

test "computeBounds zero size" {
    const b = computeBounds(0, 0, 0, 0, default_multiplier);
    try std.testing.expectEqual(@as(f64, 0), b.max_x);
    try std.testing.expectEqual(@as(f64, 0), b.max_y);
}

test "expandToFrame grows bounds to reach a window" {
    var b = computeBounds(0, 0, 1920, 1080, default_multiplier);
    // Pan only far enough to bring the outside edge into the viewport.
    expandToFrame(&b, -2500, 0, 400, 300, 0, 0, 1920, 1080);
    try std.testing.expectEqual(@as(f64, 2500), b.max_x);
    try std.testing.expectEqual(@as(f64, 1080), b.max_y);

    b = computeBounds(0, 0, 1920, 1080, default_multiplier);
    expandToFrame(&b, 5000, 0, 400, 300, 0, 0, 1920, 1080);
    try std.testing.expectEqual(@as(f64, 3480), b.max_x);
}

test "visible windows do not expand a resized canvas" {
    for ([_]u32{ 1, 2, 3 }) |count| {
        var b = computeGridBounds(-1920, -200, 1920, 1080, count, count);
        const before = b;
        expandToFrame(&b, -1820, -100, 400, 300, -1920, -200, 1920, 1080);
        try std.testing.expectEqual(before, b);
    }
}

test "single-screen canvas retains access to every outside frame edge" {
    var b = computeGridBounds(-1920, -200, 1920, 1080, 1, 1);
    expandToFrame(&b, -2020, -250, 2220, 1200, -1920, -200, 1920, 1080);
    try std.testing.expectEqual(@as(f64, 200), b.max_x);
    try std.testing.expectEqual(@as(f64, 70), b.max_y);
}

test "expandToFrame no-op when window already reachable" {
    var b = computeBounds(0, 0, 1920, 1080, default_multiplier);
    expandToFrame(&b, 100, 100, 400, 300, 0, 0, 1920, 1080);
    try std.testing.expectEqual(@as(f64, 1920), b.max_x);
    try std.testing.expectEqual(@as(f64, 1080), b.max_y);
}

test "expandToFrame skips empty usable area" {
    var b = computeBounds(0, 0, 0, 0, default_multiplier);
    expandToFrame(&b, 100, 100, 400, 300, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(f64, 0), b.max_x);
    try std.testing.expectEqual(@as(f64, 0), b.max_y);
}

test "applyMotion basic pan" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    var cam: Camera = .{};

    const r = applyMotion(&cam, 100, 50, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, 100), r.applied_dx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 50), r.applied_dy, 1e-9);
    try std.testing.expectEqual(@as(i32, 100), r.offset_x);
    try std.testing.expectEqual(@as(i32, 50), r.offset_y);
    try std.testing.expectApproxEqAbs(@as(f64, 100), cam.offset_x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 50), cam.offset_y, 1e-9);
}

test "applyMotion negative direction" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    var cam: Camera = .{};

    const r = applyMotion(&cam, -300, -200, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, -300), r.applied_dx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -200), r.applied_dy, 1e-9);
    try std.testing.expectEqual(@as(i32, -300), r.offset_x);
    try std.testing.expectEqual(@as(i32, -200), r.offset_y);
}

test "applyMotion clamps at positive boundary" {
    const bounds: Bounds = .{ .max_x = 500, .max_y = 500 };
    var cam: Camera = .{};

    const r = applyMotion(&cam, 600, 600, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, 500), r.applied_dx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 500), r.applied_dy, 1e-9);
    try std.testing.expectEqual(@as(i32, 500), r.offset_x);
    try std.testing.expectEqual(@as(i32, 500), r.offset_y);
    try std.testing.expectApproxEqAbs(@as(f64, 500), cam.offset_x, 1e-9);
}

test "applyMotion clamps at negative boundary" {
    const bounds: Bounds = .{ .max_x = 500, .max_y = 500 };
    var cam: Camera = .{};

    const r = applyMotion(&cam, -700, -700, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, -500), r.applied_dx, 1e-9);
    try std.testing.expectEqual(@as(i32, -500), r.offset_x);
}

test "applyMotion boundary reversal moves immediately" {
    const bounds: Bounds = .{ .max_x = 500, .max_y = 500 };
    var cam: Camera = .{};

    // Drive to positive boundary
    _ = applyMotion(&cam, 1000, 0, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, 500), cam.offset_x, 1e-9);

    // More in same direction → no movement
    const r1 = applyMotion(&cam, 50, 0, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, 0), r1.applied_dx, 1e-9);

    // Reverse → should start moving immediately
    const r2 = applyMotion(&cam, -10, 0, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, -10), r2.applied_dx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 490), cam.offset_x, 1e-9);
}

test "applyMotion fractional accumulation" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    var cam: Camera = .{};

    _ = applyMotion(&cam, 0.3, 0, bounds);
    _ = applyMotion(&cam, 0.3, 0, bounds);
    _ = applyMotion(&cam, 0.3, 0, bounds);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), cam.offset_x, 1e-9);
    const off = appliedOffset(cam);
    try std.testing.expectEqual(@as(i32, 1), off.x);
}

test "appliedOffset rounding" {
    const cam: Camera = .{ .offset_x = 2.5, .offset_y = -3.6 };
    const off = appliedOffset(cam);
    try std.testing.expectEqual(@as(i32, 3), off.x);
    try std.testing.expectEqual(@as(i32, -4), off.y);
}

test "layoutToWorld and worldToLayout round-trip" {
    const offset: Offset = .{ .x = 100, .y = -50 };
    const world = layoutToWorld(200, 300, offset);
    try std.testing.expectEqual(@as(i32, 300), world.x);
    try std.testing.expectEqual(@as(i32, 250), world.y);

    const back = worldToLayout(world.x, world.y, offset);
    try std.testing.expectEqual(@as(i32, 200), back.x);
    try std.testing.expectEqual(@as(i32, 300), back.y);
}

test "reveal window already visible" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    const offset: Offset = .{ .x = 0, .y = 0 };
    const d = reveal(100, 100, 400, 300, 0, 0, 1920, 1080, offset, bounds, false);
    try std.testing.expectEqual(@as(i32, 0), d.dx);
    try std.testing.expectEqual(@as(i32, 0), d.dy);
}

test "reveal window off-screen to the right" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    const offset: Offset = .{ .x = 0, .y = 0 };
    // Window at world x=1800, width=400. In layout space: 1800..2200. Screen: 0..1920.
    // Shift layout by -280 to bring right edge to 1920.
    // target_ox = 0 - (-280) = +280.
    const d = reveal(1800, 100, 400, 300, 0, 0, 1920, 1080, offset, bounds, false);
    try std.testing.expectEqual(@as(i32, 280), d.dx);
    try std.testing.expectEqual(@as(i32, 0), d.dy);
}

test "reveal window off-screen to the left" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    const offset: Offset = .{ .x = 0, .y = 0 };
    // Window at world x=-200. Layout x=-200. Shift layout by +200 so left edge is at 0.
    // target_ox = 0 - 200 = -200.
    const d = reveal(-200, 100, 400, 300, 0, 0, 1920, 1080, offset, bounds, false);
    try std.testing.expectEqual(@as(i32, -200), d.dx);
    try std.testing.expectEqual(@as(i32, 0), d.dy);
}

test "reveal window off-screen to the top" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    const offset: Offset = .{ .x = 0, .y = 0 };
    const d = reveal(100, -300, 400, 300, 0, 0, 1920, 1080, offset, bounds, false);
    try std.testing.expectEqual(@as(i32, 0), d.dx);
    try std.testing.expectEqual(@as(i32, -300), d.dy);
}

test "reveal clamped to bounds" {
    const bounds: Bounds = .{ .max_x = 100, .max_y = 100 };
    const offset: Offset = .{ .x = 0, .y = 0 };
    // Window at x=-500, needs ox=-500, but clamped to -100
    const d = reveal(-500, 100, 400, 300, 0, 0, 1920, 1080, offset, bounds, false);
    try std.testing.expectEqual(@as(i32, -100), d.dx);
}

test "reveal with non-zero camera offset" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    const offset: Offset = .{ .x = 200, .y = 0 };
    // Window at world x=300, layout x = 300 - 200 = 100 (visible)
    const d = reveal(300, 100, 400, 300, 0, 0, 1920, 1080, offset, bounds, false);
    try std.testing.expectEqual(@as(i32, 0), d.dx);
    try std.testing.expectEqual(@as(i32, 0), d.dy);
}

test "reveal maximized window" {
    const bounds: Bounds = .{ .max_x = 1920, .max_y = 1080 };
    const offset: Offset = .{ .x = 0, .y = 0 };
    // Maximized window placed at world (400, 200)
    const d = reveal(400, 200, 1920, 1040, 0, 0, 1920, 1040, offset, bounds, true);
    try std.testing.expectEqual(@as(i32, 400), d.dx);
    try std.testing.expectEqual(@as(i32, 200), d.dy);
}

test "zoom anchor and world geometry round trip on negative layout" {
    const bounds = computeBounds(-1920, -200, 3200, 1080, 3);
    var camera: Camera = .{ .offset_x = -100, .offset_y = -100 };
    const anchor: Vec = .{ .x = -500, .y = 300 };
    const point = camera.toWorld(bounds, anchor.x, anchor.y);
    for ([_]usize{ 1, 2, 3, 2, 1, 0 }) |index| {
        camera.setZoom(bounds, index, anchor);
        const projected = camera.toLayout(bounds, point.x, point.y);
        try std.testing.expectApproxEqAbs(anchor.x, projected.x, 0.000001);
        try std.testing.expectApproxEqAbs(anchor.y, projected.y, 0.000001);
        const inverse = camera.toWorld(bounds, projected.x, projected.y);
        try std.testing.expectApproxEqAbs(point.x, inverse.x, 0.000001);
        try std.testing.expectApproxEqAbs(point.y, inverse.y, 0.000001);
    }
    try std.testing.expectApproxEqAbs(@as(f64, -100), camera.offset_x, 0.000001);
}
test "pan preserves screen distance at all zoom levels and reverses at bounds" {
    const bounds = computeBounds(0, 0, 1000, 700, 3);
    for (0..zoom_levels.len) |index| {
        var camera: Camera = .{ .zoom_index = index, .zoom_value = zoomAtIndex(index) };
        const before = camera.toLayout(bounds, 200, 200);
        _ = applyMotion(&camera, -100 / camera.zoom(), -20 / camera.zoom(), bounds);
        const after = camera.toLayout(bounds, 200, 200);
        try std.testing.expectApproxEqAbs(@as(f64, 100), after.x - before.x, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 20), after.y - before.y, 0.000001);
        _ = applyMotion(&camera, -100000, 0, bounds);
        const reverse = applyMotion(&camera, 1, 0, bounds);
        try std.testing.expectEqual(@as(f64, 1), reverse.applied_dx);
    }
}
test "zoom bounds contain full expanded viewport and handle undersized worlds" {
    const bounds = computeBounds(-1000, 0, 1000, 700, 3);
    var camera: Camera = .{ .offset_x = 10000, .offset_y = 10000, .zoom_index = 3, .zoom_value = zoomAtIndex(3) };
    camera.clamp(bounds);
    const edge = camera.toWorld(bounds, 0, 700);
    try std.testing.expectApproxEqAbs(@as(f64, 1000), edge.x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1400), edge.y, 0.000001);
    const small = computeBounds(0, 0, 1000, 700, 1);
    camera.clamp(small);
    const center = camera.toWorld(small, 500, 350);
    try std.testing.expectApproxEqAbs(@as(f64, 500), center.x, 0.000001);
}
test "wheel v120 accumulation and continuous direction reversal" {
    var scroll: ZoomScroll = .{};
    try std.testing.expectEqual(@as(i32, 0), scroll.feed(60, 5, 0));
    try std.testing.expectEqual(@as(i32, 1), scroll.feed(60, 5, 0));
    try std.testing.expectEqual(@as(i32, 0), scroll.feed(0, 25, 1));
    try std.testing.expectEqual(@as(i32, -1), scroll.feed(0, -40, 1));
    _ = scroll.feed(0, 20, 1);
    _ = scroll.feed(0, 0, 1);
    try std.testing.expectEqual(@as(f64, 0), scroll.remainder);
}

test "rubber band resists past the limit and never reaches the viewport size" {
    const bounds = computeBounds(0, 0, 1000, 700, 3);
    var cam: Camera = .{};
    var raw_x: f64 = 0;
    var raw_y: f64 = 0;
    const limits = offsetLimits(bounds, cam.zoom());

    _ = applyMotionRubber(&cam, limits.hi_x + 400, 0, bounds, &raw_x, &raw_y);
    try std.testing.expect(cam.offset_x > limits.hi_x);
    try std.testing.expect(cam.offset_x < limits.hi_x + 400);
    try std.testing.expect(cam.offset_x < limits.hi_x + bounds.width);
    try std.testing.expectApproxEqAbs(rubberBand(raw_x, limits.lo_x, limits.hi_x, bounds.width), cam.offset_x, 1e-9);

    // Interior motion is still 1:1.
    cam = .{};
    raw_x = 0;
    raw_y = 0;
    const inner = applyMotionRubber(&cam, 80, -40, bounds, &raw_x, &raw_y);
    try std.testing.expectApproxEqAbs(@as(f64, 80), inner.applied_dx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -40), inner.applied_dy, 1e-9);
}

test "placeZoom keeps the world point under the layout anchor" {
    const bounds = computeBounds(0, 0, 1920, 1080, 3);
    var cam: Camera = .{ .offset_x = 120, .offset_y = -40 };
    const anchor: Vec = .{ .x = 400, .y = 300 };
    const world = cam.toWorld(bounds, anchor.x, anchor.y);
    cam.placeZoom(bounds, 0.7, world, anchor);
    const projected = cam.toLayout(bounds, world.x, world.y);
    try std.testing.expectApproxEqAbs(anchor.x, projected.x, 1e-6);
    try std.testing.expectApproxEqAbs(anchor.y, projected.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), cam.zoom(), 1e-9);
}

test "nearestIndex picks the closest discrete zoom step" {
    try std.testing.expectEqual(@as(usize, 0), nearestIndex(1.0));
    try std.testing.expectEqual(@as(usize, 0), nearestIndex(0.96));
    try std.testing.expectEqual(@as(usize, 1), nearestIndex(0.90));
    try std.testing.expectEqual(@as(usize, 1), nearestIndex(0.85));
    try std.testing.expectEqual(@as(usize, 3), nearestIndex(0.40));
    try std.testing.expectEqual(@as(usize, 3), nearestIndex(0.0));
}

test "camera zoom caps custom steps and continuous magnification at 100 percent" {
    const previous = zoom_levels;
    defer zoom_levels = previous;
    zoom_levels = &.{ 150, 100, 70, 55 };
    const bounds = computeBounds(0, 0, 1280, 720, 3);
    var cam: Camera = .{};
    const anchor: Vec = .{ .x = 320, .y = 240 };
    cam.setZoom(bounds, 0, anchor);
    try std.testing.expectEqual(@as(f64, 1), cam.zoom());
    try std.testing.expectEqual(@as(u8, 100), zoomPercentAtIndex(0));
    cam.placeZoom(bounds, 2, anchor, anchor);
    try std.testing.expectEqual(@as(f64, 1), cam.zoom_value);
    try std.testing.expectEqual(anchor, cam.toWorld(bounds, anchor.x, anchor.y));
    cam.setZoom(bounds, 2, anchor);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), cam.zoom(), 1e-9);
    try std.testing.expectApproxEqAbs(anchor.x, cam.toWorld(bounds, anchor.x, anchor.y).x, 1e-9);
    try std.testing.expectApproxEqAbs(anchor.y, cam.toWorld(bounds, anchor.x, anchor.y).y, 1e-9);
}

test "temporary boost compensates desktop zoom without changing the saved window scale" {
    for ([_]f64{ 1, 0.85, 0.55, 0.25 }) |desktop| {
        for ([_]f64{ 1, 0.7, 0.4 }) |window| {
            try std.testing.expectApproxEqAbs(window, boostedScale(window, desktop, 0), 1e-9);
            try std.testing.expectApproxEqAbs(@as(f64, 1), boostedScale(window, desktop, 1) * desktop, 1e-9);
            const half = boostedScale(window, desktop, 0.5) * desktop;
            try std.testing.expect(half >= window * desktop and half <= 1);
        }
    }
}

test "focus reveal ignores a visible sliver and centers the destination" {
    const bounds = computeBounds(0, 0, 1280, 720, 3);
    const cam = Camera{};
    const area = Vec{ .x = 1280, .y = 660 };
    const size = Vec{ .x = 400, .y = 300 };
    try std.testing.expectEqual(@as(?Vec, null), focusOffset(cam, bounds, .{ .x = 100, .y = 100 }, size, .{ .x = 0, .y = 0 }, area, false));
    const offset = focusOffset(cam, bounds, .{ .x = 1279, .y = 100 }, size, .{ .x = 0, .y = 0 }, area, false).?;
    try std.testing.expectEqual(@as(f64, 839), offset.x);
    try std.testing.expectEqual(@as(f64, -80), offset.y);
    const oversized = focusOffset(cam, bounds, .{ .x = -200, .y = -100 }, .{ .x = 1800, .y = 1400 }, .{ .x = 0, .y = 0 }, area, true).?;
    try std.testing.expectEqual(@as(f64, -200), oversized.x);
    try std.testing.expectEqual(@as(f64, -100), oversized.y);
}

test "camera focus supports reciprocal depths and percentages above 255" {
    const bounds = computeBounds(-1280, 0, 2560, 720, 3);
    var cam = Camera{ .zoom_limit = 4, .focus_zoom = 4 };
    const anchor = Vec{ .x = -600, .y = 200 };
    const point = cam.toWorld(bounds, anchor.x, anchor.y);
    cam.placeZoom(bounds, 4, point, anchor);
    try std.testing.expectEqual(@as(u16, 400), cam.targetPercent());
    try std.testing.expectEqual(@as(f64, 4), cam.zoom());
    const screen = cam.toLayout(bounds, point.x, point.y);
    try std.testing.expectApproxEqAbs(anchor.x, screen.x, 1e-9);
    try std.testing.expectApproxEqAbs(anchor.y, screen.y, 1e-9);
    cam.setZoom(bounds, 0, anchor);
    try std.testing.expectEqual(@as(f64, 1), cam.zoom());
    try std.testing.expectEqual(@as(?f64, null), cam.focus_zoom);
}
