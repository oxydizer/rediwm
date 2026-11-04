//! What part of a recycled shm buffer needs repainting, for app clients
//! (Images, PDF) whose pointer effects repaint only what changed.
//!
//! A frame's own damage (`Region`) is what changed since the frame before it,
//! which is what the surface is told. A buffer last painted several frames ago
//! also missed those frames' damage: every frame adds its damage to the other
//! buffers' `stale`, and a buffer repaints its stale region plus the frame's.
//! Rects are in whole logical pixels (the clients use integer buffer scales),
//! a handful at most: past that they merge into bounding boxes.
const std = @import("std");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    /// The whole logical pixels covering a fractional box, one pixel wider
    /// on each side for antialiased edges.
    pub fn around(x: f64, y: f64, w: f64, h: f64) Rect {
        const x0: i32 = @intFromFloat(@floor(x) - 1);
        const y0: i32 = @intFromFloat(@floor(y) - 1);
        const x1: i32 = @intFromFloat(@ceil(x + w) + 1);
        const y1: i32 = @intFromFloat(@ceil(y + h) + 1);
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    fn empty(r: Rect) bool {
        return r.w <= 0 or r.h <= 0;
    }

    fn join(a: Rect, b: Rect) Rect {
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        return .{ .x = x0, .y = y0, .w = @max(a.x + a.w, b.x + b.w) - x0, .h = @max(a.y + a.h, b.y + b.h) - y0 };
    }

    fn touches(a: Rect, b: Rect) bool {
        return a.x <= b.x + b.w and b.x <= a.x + a.w and a.y <= b.y + b.h and b.y <= a.y + a.h;
    }

    fn area(r: Rect) i64 {
        return @as(i64, r.w) * r.h;
    }
};

pub const Region = struct {
    pub const capacity = 6;

    full: bool = false,
    len: usize = 0,
    rects: [capacity]Rect = undefined,

    pub const whole: Region = .{ .full = true };

    pub fn isEmpty(self: *const Region) bool {
        return !self.full and self.len == 0;
    }

    pub fn clear(self: *Region) void {
        self.* = .{};
    }

    pub fn add(self: *Region, rect: Rect) void {
        if (self.full or rect.empty()) return;
        var r = rect;
        // Fold in every rect it touches, repeating as the union grows.
        var i: usize = 0;
        while (i < self.len) {
            if (self.rects[i].touches(r)) {
                r = r.join(self.rects[i]);
                self.len -= 1;
                self.rects[i] = self.rects[self.len];
                i = 0;
            } else i += 1;
        }
        if (self.len < capacity) {
            self.rects[self.len] = r;
            self.len += 1;
            return;
        }
        // Full: merge with the rect whose union grows least.
        var best: usize = 0;
        var growth: i64 = std.math.maxInt(i64);
        for (self.rects[0..self.len], 0..) |other, j| {
            const g = r.join(other).area() - other.area();
            if (g < growth) {
                growth = g;
                best = j;
            }
        }
        const merged = r.join(self.rects[best]);
        self.len -= 1;
        self.rects[best] = self.rects[self.len];
        self.add(merged);
    }

    pub fn merge(self: *Region, other: *const Region) void {
        if (other.full) {
            self.full = true;
            self.len = 0;
            return;
        }
        for (other.rects[0..other.len]) |r| self.add(r);
    }

    pub fn slice(self: *const Region) []const Rect {
        return self.rects[0..self.len];
    }

    /// Whether the rects cover at least `fraction` of a `w`×`h` surface (by
    /// their summed areas): a repaint that large might as well be full.
    pub fn covers(self: *const Region, w: i32, h: i32, fraction: f64) bool {
        if (self.full) return true;
        var sum: i64 = 0;
        for (self.slice()) |r| sum += r.area();
        return @as(f64, @floatFromInt(sum)) >= fraction * @as(f64, @floatFromInt(@as(i64, w) * h));
    }
};

test "touching rects merge and disjoint ones stay apart" {
    var r: Region = .{};
    r.add(.{ .x = 0, .y = 0, .w = 10, .h = 10 });
    r.add(.{ .x = 10, .y = 0, .w = 10, .h = 10 });
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 20, .h = 10 }, r.rects[0]);
    r.add(.{ .x = 100, .y = 100, .w = 5, .h = 5 });
    try std.testing.expectEqual(@as(usize, 2), r.len);
    // Bridging both folds all three together.
    r.add(.{ .x = 15, .y = 5, .w = 90, .h = 96 });
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 105, .h = 105 }, r.rects[0]);
}

test "a full region absorbs everything and overflow keeps every pixel" {
    var r: Region = .{};
    for (0..Region.capacity + 3) |i| r.add(.{ .x = @intCast(i * 50), .y = 0, .w = 10, .h = 10 });
    try std.testing.expectEqual(@as(usize, Region.capacity), r.len);
    for (0..Region.capacity + 3) |i| {
        const x: i32 = @intCast(i * 50);
        var covered = false;
        for (r.slice()) |q| covered = covered or (q.x <= x and x + 10 <= q.x + q.w);
        try std.testing.expect(covered);
    }
    var all: Region = .{};
    all.merge(&r);
    all.merge(&Region.whole);
    try std.testing.expect(all.full and all.len == 0);
    all.add(.{ .x = 0, .y = 0, .w = 1, .h = 1 });
    try std.testing.expect(all.covers(10, 10, 1));
    try std.testing.expect(!r.covers(1000, 1000, 0.5));
}

test "around covers a fractional box with a pixel of margin" {
    try std.testing.expectEqual(Rect{ .x = 9, .y = 4, .w = 13, .h = 8 }, Rect.around(10.5, 5, 10.2, 5.5));
}
