//! The hover highlight of a list or grid in a retained-Cairo client (Files):
//! it fades in where the pointer lands and, while it is still visible,
//! glides to the next cell instead of hopping. The start menu's result list
//! has the same feel, on the same springs (`start_glide`).
//!
//! Positions are fractional cells of the caller's grid, not pixels, so the
//! highlight follows its rows through scrolling and rebuilds; the caller maps
//! `frame` to a rect when it paints. `step` samples the glide once per loop
//! and says whether what would be drawn changed, so a resting list repaints
//! nothing and, once `animating` is false, needs no timer.
const std = @import("std");
const anim = @import("anim.zig");

/// A grid cell; a plain list uses column 0.
pub const Cell = struct { col: i32, row: i32 };

/// What one paint draws: a position in fractional cells and an opacity.
pub const Frame = struct { col: f32 = 0, row: f32 = 0, alpha: f32 = 0 };

/// Below this the highlight is gone for practical purposes: the next one
/// appears where the pointer is rather than gliding out of the old spot.
const visible_alpha: f32 = 0.01;

pub const Glide = struct {
    col: anim.Anim = .{},
    row: anim.Anim = .{},
    alpha: anim.Anim = .{ .property = .opacity },
    target: ?Cell = null,
    /// What the last `step` sampled, which the caller paints and damages.
    frame: Frame = .{},

    /// Points the highlight at `cell`, or fades it out for null (the pointer
    /// is elsewhere, or the cell draws its own state). Cheap to call every
    /// loop: only a changed target starts anything.
    pub fn setTarget(self: *Glide, now_ms: i64, cell: ?Cell) void {
        if (std.meta.eql(self.target, cell)) return;
        self.target = cell;
        const fade = anim.curveFor(.start_glide_fade);
        const to = cell orelse return self.alpha.retargetTo(now_ms, 0, fade);
        const col: f32 = @floatFromInt(to.col);
        const row: f32 = @floatFromInt(to.row);
        if (self.alpha.value(now_ms) <= visible_alpha) {
            self.col.cancel(col);
            self.row.cancel(row);
        } else {
            const glide = anim.curveFor(.start_glide);
            self.col.retargetTo(now_ms, col, glide);
            self.row.retargetTo(now_ms, row, glide);
        }
        self.alpha.retargetTo(now_ms, 1, fade);
    }

    /// Samples the glide, snapped to the raster: `col_q` and `row_q` are one
    /// device pixel in cells. True when what would be drawn changed; moving
    /// an invisible highlight is not a change.
    pub fn step(self: *Glide, now_ms: i64, col_q: f32, row_q: f32) bool {
        const next: Frame = .{
            .col = quantised(self.col, now_ms, col_q),
            .row = quantised(self.row, now_ms, row_q),
            .alpha = quantised(self.alpha, now_ms, anim.rasterAlphaQuantum()),
        };
        const drawn = self.frame.alpha > 0 or next.alpha > 0;
        const changed = drawn and !std.meta.eql(next, self.frame);
        self.frame = next;
        return changed;
    }

    /// Whether the position or opacity is still in flight at `now_ms`.
    pub fn animating(self: Glide, now_ms: i64) bool {
        return !self.col.settled(now_ms) or !self.row.settled(now_ms) or !self.alpha.settled(now_ms);
    }

    /// Forgets the highlight, for a grid whose cells no longer mean what
    /// they did (columns reflowed, list and grid swapped).
    pub fn reset(self: *Glide) void {
        self.* = .{};
    }

    /// In flight, snapped to `quantum`; at rest, the exact endpoint.
    fn quantised(a: anim.Anim, now_ms: i64, quantum: f32) f32 {
        const v = a.value(now_ms);
        return if (a.settled(now_ms)) v else @round(v / quantum) * quantum;
    }
};

test "the highlight appears in place and fades in without moving" {
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .reduced_motion = .off });

    var glide: Glide = .{};
    glide.setTarget(1000, .{ .col = 2, .row = 3 });
    // Nothing is drawn until the fade has started.
    try std.testing.expect(!glide.step(1000, 0.1, 0.1));
    try std.testing.expectEqual(@as(f32, 0), glide.frame.alpha);
    try std.testing.expect(glide.animating(1000));
    try std.testing.expect(glide.step(1040, 0.1, 0.1));
    try std.testing.expect(glide.frame.alpha > 0 and glide.frame.alpha < 1);
    try std.testing.expectEqual(@as(f32, 2), glide.frame.col);
    try std.testing.expectEqual(@as(f32, 3), glide.frame.row);
    try std.testing.expect(glide.step(3000, 0.1, 0.1));
    try std.testing.expectEqual(@as(f32, 1), glide.frame.alpha);
    try std.testing.expect(!glide.animating(3000));
}

test "a visible highlight glides between cells, then rests without repainting" {
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .reduced_motion = .off });

    var glide: Glide = .{};
    glide.setTarget(1000, .{ .col = 0, .row = 0 });
    _ = glide.step(3000, 0.1, 0.1);
    glide.setTarget(3000, .{ .col = 3, .row = 2 });
    try std.testing.expect(glide.step(3060, 0.01, 0.01));
    try std.testing.expect(glide.frame.col > 0 and glide.frame.col < 3);
    try std.testing.expect(glide.frame.row > 0 and glide.frame.row < 2);
    try std.testing.expectEqual(@as(f32, 1), glide.frame.alpha);
    try std.testing.expect(glide.animating(3060));
    // The endpoint is published exactly, and then nothing changes.
    try std.testing.expect(glide.step(6000, 0.01, 0.01));
    try std.testing.expectEqual(@as(f32, 3), glide.frame.col);
    try std.testing.expectEqual(@as(f32, 2), glide.frame.row);
    try std.testing.expect(!glide.animating(6000));
    try std.testing.expect(!glide.step(6500, 0.01, 0.01));
    // Re-asserting the same target starts nothing.
    glide.setTarget(7000, .{ .col = 3, .row = 2 });
    try std.testing.expect(!glide.animating(7000));
}

test "leaving fades out in place and the next highlight appears where the pointer is" {
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .reduced_motion = .off });

    var glide: Glide = .{};
    glide.setTarget(1000, .{ .col = 1, .row = 1 });
    _ = glide.step(3000, 0.1, 0.1);
    glide.setTarget(3000, null);
    try std.testing.expect(glide.step(3060, 0.1, 0.1));
    try std.testing.expect(glide.frame.alpha < 1);
    try std.testing.expectEqual(@as(f32, 1), glide.frame.col);
    try std.testing.expect(glide.step(6000, 0.1, 0.1));
    try std.testing.expectEqual(@as(f32, 0), glide.frame.alpha);
    try std.testing.expect(!glide.animating(6000));
    // Invisible and settled: a new target jumps there rather than gliding,
    // and positioning something nobody can see is not a repaint.
    glide.setTarget(7000, .{ .col = 4, .row = 5 });
    try std.testing.expect(!glide.step(7000, 0.1, 0.1));
    try std.testing.expectEqual(@as(f32, 4), glide.frame.col);
    try std.testing.expectEqual(@as(f32, 5), glide.frame.row);
}

test "with animations off the highlight snaps" {
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .enabled = false, .reduced_motion = .off });

    var glide: Glide = .{};
    glide.setTarget(1000, .{ .col = 0, .row = 0 });
    try std.testing.expect(glide.step(1000, 0.1, 0.1));
    try std.testing.expectEqual(@as(f32, 1), glide.frame.alpha);
    try std.testing.expect(!glide.animating(1000));
    glide.setTarget(1000, .{ .col = 2, .row = 1 });
    try std.testing.expect(glide.step(1000, 0.1, 0.1));
    try std.testing.expectEqual(@as(f32, 2), glide.frame.col);
}
