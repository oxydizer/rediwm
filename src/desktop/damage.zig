//! Logical-pixel damage, accumulated until a buffer is drawn. Each reusable
//! buffer keeps its own copy so alternating buffers never revive stale pixels.
const std = @import("std");
pub const Rect = @import("grid.zig").Rect;
/// Corner radius of the selection band (at most; App shrinks it for tiny bands).
pub const rubberband_radius = 4;

pub const Damage = struct {
    full: bool = true,
    rects: [64]Rect = undefined,
    len: usize = 0,

    pub fn clear(self: *Damage) void {
        self.full = false;
        self.len = 0;
    }

    pub fn all(self: *Damage) void {
        self.full = true;
        self.len = 0;
    }

    pub fn add(self: *Damage, rect: Rect) void {
        if (self.full or rect.w <= 0 or rect.h <= 0) return;
        // Containment is common when several pointer events arrive before the
        // next frame. Avoid coalescing intersecting strips into a large box:
        // the unchanged middle of a rubberband must remain undamaged.
        var i: usize = 0;
        while (i < self.len) {
            if (contains(self.rects[i], rect)) return;
            if (contains(rect, self.rects[i])) {
                self.len -= 1;
                self.rects[i] = self.rects[self.len];
            } else i += 1;
        }
        if (self.len == self.rects.len) return self.all();
        self.rects[self.len] = rect;
        self.len += 1;
    }

    pub fn accumulate(self: *Damage, other: *const Damage) void {
        if (other.full) return self.all();
        for (other.rects[0..other.len]) |r| self.add(r);
    }

    pub fn intersects(self: *const Damage, r: Rect) bool {
        if (self.full) return true;
        for (self.rects[0..self.len]) |damaged| if (damaged.intersects(r)) return true;
        return false;
    }

    /// Cairo strokes straddle the rectangle edge. Damage the changed fill and
    /// both old/new antialiased outlines, retaining the identical inner fill.
    /// The band's corners are rounded (`rubberband_radius`), so a corner that
    /// moves inside the other band also changes pixels within that fill.
    pub fn rubberband(self: *Damage, old: ?Rect, new: ?Rect) void {
        if (old != null and new != null and std.meta.eql(old.?, new.?)) return;
        if (old) |r| self.subtract(expand(r, 1), if (new) |n| expand(n, -1) else null);
        if (new) |r| self.subtract(expand(r, 1), if (old) |o| expand(o, -1) else null);
        if (old) |r| self.corners(expand(r, 1));
        if (new) |r| self.corners(expand(r, 1));
    }

    fn corners(self: *Damage, r: Rect) void {
        // The arc plus its outline and antialiasing, clamped for small bands.
        const size = @min(rubberband_radius + 2, @divTrunc(r.w + 1, 2), @divTrunc(r.h + 1, 2));
        if (size <= 0) return;
        self.add(.{ .x = r.x, .y = r.y, .w = size, .h = size });
        self.add(.{ .x = r.x + r.w - size, .y = r.y, .w = size, .h = size });
        self.add(.{ .x = r.x, .y = r.y + r.h - size, .w = size, .h = size });
        self.add(.{ .x = r.x + r.w - size, .y = r.y + r.h - size, .w = size, .h = size });
    }

    fn subtract(self: *Damage, r: Rect, retained: ?Rect) void {
        const keep = retained orelse return self.add(r);
        if (keep.w <= 0 or keep.h <= 0 or !r.intersects(keep)) return self.add(r);
        const left = @max(r.x, keep.x);
        const top = @max(r.y, keep.y);
        const right = @min(r.x + r.w, keep.x + keep.w);
        const bottom = @min(r.y + r.h, keep.y + keep.h);
        self.add(.{ .x = r.x, .y = r.y, .w = r.w, .h = top - r.y });
        self.add(.{ .x = r.x, .y = bottom, .w = r.w, .h = r.y + r.h - bottom });
        self.add(.{ .x = r.x, .y = top, .w = left - r.x, .h = bottom - top });
        self.add(.{ .x = right, .y = top, .w = r.x + r.w - right, .h = bottom - top });
    }
};

pub fn expand(r: Rect, amount: i32) Rect {
    return .{ .x = r.x - amount, .y = r.y - amount, .w = r.w + 2 * amount, .h = r.h + 2 * amount };
}

fn contains(outer: Rect, inner: Rect) bool {
    return outer.x <= inner.x and outer.y <= inner.y and outer.x + outer.w >= inner.x + inner.w and outer.y + outer.h >= inner.y + inner.h;
}

test "rubberband damage keeps unchanged fill and includes old and new edges" {
    var damage = Damage{};
    damage.clear();
    damage.rubberband(.{ .x = 10, .y = 10, .w = 100, .h = 100 }, .{ .x = 10, .y = 10, .w = 120, .h = 120 });
    try std.testing.expect(!damage.full);
    try std.testing.expect(!damage.intersects(.{ .x = 30, .y = 30, .w = 50, .h = 50 }));
    try std.testing.expect(damage.intersects(.{ .x = 109, .y = 40, .w = 2, .h = 2 }));
    try std.testing.expect(damage.intersects(.{ .x = 129, .y = 40, .w = 2, .h = 2 }));
    try std.testing.expect(damage.intersects(.{ .x = 119, .y = 40, .w = 2, .h = 2 }));
    damage.clear();
    damage.rubberband(.{ .x = 10, .y = 10, .w = 100, .h = 100 }, null);
    try std.testing.expect(damage.intersects(.{ .x = 30, .y = 30, .w = 50, .h = 50 }));
}

test "a shrinking rubberband damages its rounded corners inside the old fill" {
    var damage = Damage{};
    damage.clear();
    // Old band contains the new one; the new top-left corner lies in the old fill.
    damage.rubberband(.{ .x = 0, .y = 0, .w = 200, .h = 200 }, .{ .x = 50, .y = 50, .w = 100, .h = 100 });
    try std.testing.expect(damage.intersects(.{ .x = 51, .y = 51, .w = 1, .h = 1 }));
    try std.testing.expect(damage.intersects(.{ .x = 148, .y = 148, .w = 1, .h = 1 }));
    // The middle of the retained fill stays undamaged.
    try std.testing.expect(!damage.intersects(.{ .x = 90, .y = 90, .w = 20, .h = 20 }));
}

test "buffer damage accumulates intervening frames and overflow falls back to full" {
    var older = Damage{};
    var frame = Damage{};
    older.clear();
    frame.clear();
    older.add(.{ .x = 0, .y = 0, .w = 5, .h = 5 });
    frame.add(.{ .x = 10, .y = 0, .w = 5, .h = 5 });
    older.accumulate(&frame);
    try std.testing.expect(older.intersects(.{ .x = 0, .y = 0, .w = 1, .h = 1 }));
    try std.testing.expect(older.intersects(.{ .x = 10, .y = 0, .w = 1, .h = 1 }));
    for (0..65) |i| older.add(.{ .x = @intCast(i * 10), .y = 10, .w = 1, .h = 1 });
    try std.testing.expect(older.full);
}
