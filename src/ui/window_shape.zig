//! A window's outline as a polygon, written in a theme as
//! `window_shape = "0 12, 18 0, -40 0, ..."`: up to sixteen points, each an
//! `x y` pair, separated by commas. A coordinate is
//!
//!   * `12`   logical px from the left (x) or top (y) edge,
//!   * `-12`  logical px from the right or bottom edge (`-0` is the edge itself),
//!   * `40%`  a fraction of the width or height (`-40%` from the far side).
//!
//! so one outline fits a window of any size, and a notch keeps its depth. Pure
//! arithmetic, no compositor: the points are resolved against the live frame by
//! `resolve` and handed to the projection (`projection.ClipSpec.poly`), whose
//! shader and C code use the same distance function as `sdPolygon`.
const std = @import("std");

pub const max_points = 16;

pub const Error = error{InvalidShape};

const Anchor = struct {
    value: f32,
    percent: bool,
    far: bool,

    fn resolve(a: Anchor, length: f64, density: f64) f64 {
        const along: f64 = if (a.percent) @as(f64, a.value) / 100.0 * length else @as(f64, a.value) * density;
        return std.math.clamp(if (a.far) length - along else along, 0, length);
    }
};

pub const Outline = struct {
    count: usize = 0,
    points: [max_points][2]Anchor = undefined,
};

pub const Resolved = struct {
    count: usize = 0,
    points: [max_points][2]f64 = @splat(.{ 0, 0 }),
};

/// Null for an empty text (no polygon: the rounded rectangle). An outline of
/// fewer than three or more than `max_points` points, a malformed coordinate, or
/// one whose edges cross is `InvalidShape`.
pub fn parse(text: []const u8) Error!?Outline {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;
    var outline: Outline = .{};
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |part| {
        if (outline.count == max_points) return error.InvalidShape;
        var words = std.mem.tokenizeAny(u8, part, " \t");
        const x = words.next() orelse return error.InvalidShape;
        const y = words.next() orelse return error.InvalidShape;
        if (words.next() != null) return error.InvalidShape;
        outline.points[outline.count] = .{ try parseAnchor(x), try parseAnchor(y) };
        outline.count += 1;
    }
    if (outline.count < 3) return error.InvalidShape;
    // Checked at a nominal size: the points keep their order and sides, so a
    // sensible outline does not start crossing itself at another one.
    const nominal = resolve(outline, 800, 600, 1);
    if (!simple(nominal)) return error.InvalidShape;
    return outline;
}

fn parseAnchor(word: []const u8) Error!Anchor {
    var text = word;
    const percent = text.len > 0 and text[text.len - 1] == '%';
    if (percent) text = text[0 .. text.len - 1];
    const value = std.fmt.parseFloat(f32, text) catch return error.InvalidShape;
    if (!std.math.isFinite(value) or (percent and @abs(value) > 100)) return error.InvalidShape;
    return .{ .value = @abs(value), .percent = percent, .far = std.math.signbit(value) };
}

/// The points in a frame of `width` x `height` logical px, `density` scaling the
/// px coordinates (a percent keeps its fraction). Inside the frame, clamped.
pub fn resolve(outline: Outline, width: f64, height: f64, density: f64) Resolved {
    var out: Resolved = .{ .count = outline.count };
    for (outline.points[0..outline.count], 0..) |p, i| {
        out.points[i] = .{ p[0].resolve(width, density), p[1].resolve(height, density) };
    }
    return out;
}

/// What the projection takes: at least three points, none the same as the next
/// (an edge needs a direction), no edges crossing (a window too narrow for its
/// outline folds it over itself). False falls back to the rounded rectangle.
pub fn usable(r: Resolved) bool {
    if (r.count < 3) return false;
    for (0..r.count) |i| {
        const a = r.points[i];
        const b = r.points[(i + 1) % r.count];
        if (a[0] == b[0] and a[1] == b[1]) return false;
    }
    return simple(r);
}

/// Signed distance, negative inside, to the polygon: the nearest edge, signed
/// by an even-odd crossing count. The same walk as `rediwm_sd_polygon`.
pub fn sdPolygon(r: Resolved, px: f64, py: f64) f64 {
    var d = (px - r.points[0][0]) * (px - r.points[0][0]) + (py - r.points[0][1]) * (py - r.points[0][1]);
    var s: f64 = 1;
    for (0..r.count) |i| {
        const a = r.points[i];
        // Not `% r.count`: a division per edge was a third of a raster's time.
        const b = r.points[if (i + 1 == r.count) 0 else i + 1];
        const ex = b[0] - a[0];
        const ey = b[1] - a[1];
        const wx = px - a[0];
        const wy = py - a[1];
        const len2 = ex * ex + ey * ey;
        const h = std.math.clamp((wx * ex + wy * ey) / @max(len2, 1e-4), 0, 1);
        const bx = wx - ex * h;
        const by = wy - ey * h;
        d = @min(d, bx * bx + by * by);
        const c0 = py >= a[1];
        const c1 = py < b[1];
        const c2 = ex * wy > ey * wx;
        if ((c0 and c1 and c2) or (!c0 and !c1 and !c2)) s = -s;
    }
    return s * @sqrt(d);
}

/// How many device pixels after this one, along a row or column, keep a
/// saturated coverage (wholly inside or wholly outside), given this pixel's
/// signed distance in device pixels. A distance changes by at most one per
/// pixel, so a raster asks for the next distance only where an edge can be.
pub fn saturatedRun(device_distance: f32) usize {
    const clear = @abs(device_distance) - 0.5 - 1e-3;
    return if (clear >= 1) @intFromFloat(clear) else 0;
}

/// What the outline looks like inside the box (`x`, `y`, `w`, `h`) grown by
/// `margin`: the edges that reach it, clipped to it and measured from its
/// origin, and whether its centre is inside. A raster of the outline within
/// `margin` of the box, drawn from the box's origin, is the same while this is:
/// a corner keeps its key when the frame is resized, as far-edge anchors move
/// with the corner.
pub fn localKey(r: Resolved, x: f64, y: f64, w: f64, h: f64, margin: f64) u64 {
    var hasher = std.hash.Wyhash.init(r.count);
    const lo = [2]f64{ x - margin, y - margin };
    const hi = [2]f64{ x + w + margin, y + h + margin };
    for (0..r.count) |i| {
        const a = r.points[i];
        const b = r.points[(i + 1) % r.count];
        var t0: f64 = 0;
        var t1: f64 = 1;
        var reaches = true;
        for (0..2) |axis| {
            const d = b[axis] - a[axis];
            if (d == 0) {
                if (a[axis] < lo[axis] or a[axis] > hi[axis]) reaches = false;
                continue;
            }
            const ta = (lo[axis] - a[axis]) / d;
            const tb = (hi[axis] - a[axis]) / d;
            t0 = @max(t0, @min(ta, tb));
            t1 = @min(t1, @max(ta, tb));
        }
        if (!reaches or t0 > t1) continue;
        // Whole 1/1024ths of a pixel: the same edge at another frame size must
        // not differ by the rounding of its far-edge anchor.
        const ends = [4]i64{
            quantize(a[0] + (b[0] - a[0]) * t0 - x), quantize(a[1] + (b[1] - a[1]) * t0 - y),
            quantize(a[0] + (b[0] - a[0]) * t1 - x), quantize(a[1] + (b[1] - a[1]) * t1 - y),
        };
        hasher.update(std.mem.asBytes(&ends));
    }
    hasher.update(&.{@intFromBool(sdPolygon(r, x + w / 2, y + h / 2) < 0)});
    return hasher.final();
}

fn quantize(v: f64) i64 {
    return @intFromFloat(@round(std.math.clamp(v, -1e9, 1e9) * 1024));
}

pub const Insets = struct { left: i32 = 0, right: i32 = 0 };

/// How far in from the left and right edges of a frame `width` wide the outline
/// is over the rows `top` to `bottom`: for each of nine rows the first and last
/// point inside, the greatest of them. Content laid out over those rows (a
/// titlebar's icon and controls) that starts this far in stays inside the
/// outline. A row the outline does not reach near an end (a notch) is left out
/// rather than pushing the content off, as is one that is entirely outside.
pub fn rowInsets(r: Resolved, width: f64, top: f64, bottom: f64) Insets {
    const reach: f64 = 160;
    var out: Insets = .{};
    const rows = 8;
    for (0..rows + 1) |row| {
        const y = top + (bottom - top) * @as(f64, @floatFromInt(row)) / rows;
        var xs: [max_points]f64 = undefined;
        var count: usize = 0;
        for (0..r.count) |i| {
            const a = r.points[i];
            const b = r.points[(i + 1) % r.count];
            if ((a[1] <= y) != (b[1] <= y)) {
                xs[count] = a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1]);
                count += 1;
            }
        }
        if (count < 2) continue;
        std.mem.sort(f64, xs[0..count], {}, std.sort.asc(f64));
        if (xs[0] < reach) out.left = @max(out.left, @as(i32, @intFromFloat(@ceil(xs[0]))));
        const from_right = width - xs[count - 1];
        if (from_right < reach) out.right = @max(out.right, @as(i32, @intFromFloat(@ceil(from_right))));
    }
    return out;
}

/// No two edges that do not share a vertex cross.
fn simple(r: Resolved) bool {
    for (0..r.count) |i| {
        var j = i + 2;
        while (j < r.count) : (j += 1) {
            if (i == 0 and j == r.count - 1) continue;
            if (cross(r.points[i], r.points[(i + 1) % r.count], r.points[j], r.points[(j + 1) % r.count])) return false;
        }
    }
    return true;
}

fn orient(a: [2]f64, b: [2]f64, c: [2]f64) f64 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

fn cross(a: [2]f64, b: [2]f64, c: [2]f64, d: [2]f64) bool {
    const o1 = orient(a, b, c);
    const o2 = orient(a, b, d);
    const o3 = orient(c, d, a);
    const o4 = orient(c, d, b);
    return ((o1 > 0) != (o2 > 0) and o1 != 0 and o2 != 0) and ((o3 > 0) != (o4 > 0) and o3 != 0 and o4 != 0);
}

test "parse reads px, far-side and percent coordinates" {
    const outline = (try parse("0 12, 18 0, -40 0%, -0 -12")).?;
    try std.testing.expectEqual(@as(usize, 4), outline.count);
    const r = resolve(outline, 200, 100, 1);
    try std.testing.expectEqual([2]f64{ 0, 12 }, r.points[0]);
    try std.testing.expectEqual([2]f64{ 18, 0 }, r.points[1]);
    try std.testing.expectEqual([2]f64{ 160, 0 }, r.points[2]);
    try std.testing.expectEqual([2]f64{ 200, 88 }, r.points[3]);
}

test "percent keeps its fraction and px scale with density" {
    const outline = (try parse("0 0, 50% 0, 50% 10, 0 10")).?;
    const r = resolve(outline, 200, 100, 0.5);
    try std.testing.expectEqual([2]f64{ 100, 0 }, r.points[1]);
    try std.testing.expectEqual([2]f64{ 100, 5 }, r.points[2]);
}

test "an empty text is no polygon, a malformed or crossing one is refused" {
    try std.testing.expectEqual(@as(?Outline, null), try parse("  "));
    try std.testing.expectError(error.InvalidShape, parse("0 0, 10 10"));
    try std.testing.expectError(error.InvalidShape, parse("0 0, 10 x, 20 20"));
    try std.testing.expectError(error.InvalidShape, parse("0 0, 10 10 5, 20 20"));
    try std.testing.expectError(error.InvalidShape, parse("0 0, 100% 100%, 100% 0, 0 100%"));
}

test "too many points are refused" {
    const text = "0 0, 1 0, 2 0, 3 0, 4 0, 5 0, 6 0, 7 0, 8 0, 9 0, 10 0, 11 0, 12 0, 13 0, 14 0, 15 0, 16 0, 16 5";
    try std.testing.expectError(error.InvalidShape, parse(text));
}

test "the distance is negative inside, positive outside, either winding" {
    const outline = (try parse("10 0, -10 0, -0 10, -0 -10, 10 -0, 0 -10")).?;
    const r = resolve(outline, 100, 60, 1);
    try std.testing.expect(sdPolygon(r, 50, 30) < 0);
    try std.testing.expect(sdPolygon(r, 1, 1) > 0); // The cut corner.
    try std.testing.expectApproxEqAbs(@as(f64, 0), sdPolygon(r, 50, 0), 1e-9);
    var reversed = r;
    for (0..r.count) |i| reversed.points[i] = r.points[r.count - 1 - i];
    try std.testing.expectApproxEqAbs(sdPolygon(r, 5, 5), sdPolygon(reversed, 5, 5), 1e-9);
    try std.testing.expect(sdPolygon(reversed, 50, 30) < 0);
}

test "row insets follow the slants and skip a notch" {
    const outline = (try parse("0 -0, 14 0, 300 0, 312 6, -14 6, -0 -0")).?;
    const r = resolve(outline, 1000, 44, 1);
    // Rows 4 to 40: the left slant is 12.7 px in at row 4; the right end is slanted
    // from (986, 6) to (1000, 44), so 14 in at its top, and row 4 above the step is
    // the notch, which has no end to clear.
    const insets = rowInsets(r, 1000, 4, 40);
    try std.testing.expect(insets.left >= 12 and insets.left <= 14);
    try std.testing.expect(insets.right >= 12 and insets.right <= 15);
    // Rows wholly inside a rectangle need nothing.
    const box = resolve((try parse("0 0, -0 0, -0 -0, 0 -0")).?, 1000, 44, 1);
    try std.testing.expectEqual(Insets{}, rowInsets(box, 1000, 4, 40));
}

test "a corner's local key survives a resize and follows its own edges" {
    const outline = (try parse("0 14, 14 0, 282.5 0, 289.5 7, -14 7, -0 21, -0 -12, -12 -0, 12 -0, 0 -12")).?;
    const small = resolve(outline, 700, 500, 1);
    const large = resolve(outline, 913, 641, 1);
    // Each corner's 52 px square, measured from its own origin.
    try std.testing.expectEqual(localKey(small, 0, 0, 52, 52, 5), localKey(large, 0, 0, 52, 52, 5));
    try std.testing.expectEqual(localKey(small, 700 - 52, 0, 52, 52, 5), localKey(large, 913 - 52, 0, 52, 52, 5));
    try std.testing.expectEqual(localKey(small, 0, 500 - 52, 52, 52, 5), localKey(large, 0, 641 - 52, 52, 52, 5));
    try std.testing.expectEqual(localKey(small, 700 - 52, 500 - 52, 52, 52, 5), localKey(large, 913 - 52, 641 - 52, 52, 52, 5));
    // The corners differ from one another, and a narrow frame brings the step
    // of the top edge into the top right corner's square.
    try std.testing.expect(localKey(small, 0, 0, 52, 52, 5) != localKey(small, 700 - 52, 0, 52, 52, 5));
    const narrow = resolve(outline, 320, 500, 1);
    try std.testing.expect(localKey(narrow, 320 - 52, 0, 52, 52, 5) != localKey(small, 700 - 52, 0, 52, 52, 5));
    // Another density moves the cuts.
    const dense = resolve(outline, 700, 500, 1.25);
    try std.testing.expect(localKey(dense, 0, 0, 52, 52, 5) != localKey(small, 0, 0, 52, 52, 5));
}

test "a saturated run never reaches an edge" {
    try std.testing.expectEqual(@as(usize, 0), saturatedRun(0.2));
    try std.testing.expectEqual(@as(usize, 0), saturatedRun(-1.4));
    try std.testing.expectEqual(@as(usize, 1), saturatedRun(-1.6));
    try std.testing.expectEqual(@as(usize, 11), saturatedRun(12.4));
}
