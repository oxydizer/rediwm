const std = @import("std");
const shape = @import("window_shape.zig");
const Outline = shape.Outline;
const Insets = shape.Insets;
const parse = shape.parse;
const resolve = shape.resolve;
const sdPolygon = shape.sdPolygon;
const rowInsets = shape.rowInsets;
const localKey = shape.localKey;
const saturatedRun = shape.saturatedRun;

test "fixed title steps fall back before overtaking the opposite corner" {
    const outline = (try parse("0 14, 14 0, 282.5 0, 289.5 7, -14 7, -0 21, -0 -12, -12 -0, 12 -0, 0 -12")).?;
    for ([_]f64{ 0.75, 1, 1.25, 1.5 }) |density| {
        for ([_]f64{ 210, 250, 270, 286, 300, 303, 303.5 }) |width| {
            try std.testing.expect(shape.resolveFitting(outline, width * density, 400 * density, density) == null);
        }
        for ([_]f64{ 304, 320, 360, 800 }) |width| {
            const resolved = shape.resolveFitting(outline, width * density, 400 * density, density).?;
            try std.testing.expectEqualDeep(resolve(outline, width * density, 400 * density, density), resolved);
        }
        try std.testing.expect(shape.resolveFitting(outline, 800 * density, 32 * density, density) == null);
    }
    // The old edge-intersection check alone accepts this backwards step.
    try std.testing.expect(shape.usable(resolve(outline, 300, 400, 1)));
}

test "fitting allows independent cuts and percentage outlines" {
    const cuts = (try parse("0 0, 280 0, -0 30, -0 -0, -280 -0, 0 -30")).?;
    try std.testing.expect(shape.resolveFitting(cuts, 300, 200, 1) != null);
    try std.testing.expect(shape.resolveFitting(cuts, 279, 200, 1) == null);
    const percent = (try parse("0 0, 100% 0, 100% 100%, 0 100%")).?;
    try std.testing.expect(shape.resolveFitting(percent, 1, 1, 1.5) != null);
    try std.testing.expect(shape.resolveFitting(percent, 0, 1, 1) == null);
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
