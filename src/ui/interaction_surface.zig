//! Query-driven interaction state shared by retained and hand-laid UI.
//! Hosts own hit-testing and button enumeration; the surface retains no
//! widget pointers, region collection, or allocated storage.

const std = @import("std");
const button_widget = @import("widgets/button.zig");

pub const Rect = button_widget.Rect;
pub const ProximitySample = button_widget.ProximitySample;

pub const Role = enum {
    button,
    interactive,
    passive,
};

/// A point-query result supplied by the host's own hit-testing implementation.
pub const Hit = struct {
    id: u64,
    rect: Rect,
    clip: Rect,
    role: Role,
    enabled: bool = true,
};

/// The last known visible bounds for an interaction target.
/// This is a damage snapshot, not an authoritative geometry reference.
pub const Target = struct {
    id: u64,
    rect: Rect,
};

pub const Change = struct {
    previous: ?Target,
    current: ?Target,
    hover_changed: bool,

    pub fn changed(self: Change) bool {
        return self.hover_changed;
    }
};

/// Allocation-free interaction state. The host performs hit-testing and
/// enumerates only the buttons relevant to its own proximity sampling.
pub const Surface = struct {
    hovered: ?Target = null,

    /// Applies the host's point-query result. The host is responsible for
    /// returning the topmost hit at the supplied pointer position.
    ///
    /// The cached rectangle is clipped to the visible portion. When the same
    /// ID moves, its snapshot is refreshed, but geometry invalidation remains
    /// the host's responsibility.
    pub fn pointerMotion(self: *Surface, hit: ?Hit) Change {
        const previous = self.hovered;
        const current = targetFromHit(hit);
        self.hovered = current;

        return .{
            .previous = previous,
            .current = current,
            .hover_changed = !sameTargetId(previous, current),
        };
    }

    /// Clears the hover target and returns its last visible rectangle so the
    /// host can invalidate it.
    pub fn pointerLeave(self: *Surface) Change {
        const previous = self.hovered;
        self.hovered = null;
        return .{
            .previous = previous,
            .current = null,
            .hover_changed = previous != null,
        };
    }
};

fn targetFromHit(hit: ?Hit) ?Target {
    const value = hit orelse return null;
    if (!value.enabled or value.role == .passive) return null;

    const visible = button_widget.intersectRect(value.rect, value.clip);
    if (visible.w <= 0 or visible.h <= 0) return null;

    return .{ .id = value.id, .rect = visible };
}

fn sameTargetId(a: ?Target, b: ?Target) bool {
    if (a) |left| {
        if (b) |right| return left.id == right.id;
    }
    return a == null and b == null;
}

/// Samples a button using the shared widget geometry, suppressing changes
/// beyond the configured glow reach. All out-of-reach positions produce the
/// same inactive sample, so distant pointer motion cannot dirty every button.
pub fn sampleButtonProximity(
    rect: Rect,
    pointer_x: f32,
    pointer_y: f32,
    clip: Rect,
    reach: f32,
) ProximitySample {
    const inactive = ProximitySample{
        .distance = std.math.inf(f32),
        .x = 0,
        .y = 0,
    };
    if (reach <= 0) return inactive;

    const sample = button_widget.sampleProximity(rect, pointer_x, pointer_y, clip);
    return if (sample.distance <= reach) sample else inactive;
}

test "surface stores the host hit and returns visible damage bounds" {
    var surface: Surface = .{};
    const change = surface.pointerMotion(.{
        .id = 7,
        .rect = .{ .x = 10, .y = 10, .w = 40, .h = 30 },
        .clip = .{ .x = 20, .y = 15, .w = 20, .h = 10 },
        .role = .interactive,
    });

    try std.testing.expect(change.hover_changed);
    try std.testing.expectEqual(@as(?u64, 7), surface.hovered.?.id);
    try std.testing.expectEqual(Rect{
        .x = 20, .y = 15, .w = 20, .h = 10,
    }, change.current.?.rect);
}

test "surface rejects disabled passive and fully clipped hits" {
    var surface: Surface = .{};

    const bounds = Rect{ .x = 0, .y = 0, .w = 20, .h = 20 };
    const disabled = surface.pointerMotion(.{
        .id = 1, .rect = bounds, .clip = bounds,
        .role = .interactive, .enabled = false,
    });
    try std.testing.expect(disabled.current == null);

    const passive = surface.pointerMotion(.{
        .id = 2, .rect = bounds, .clip = bounds, .role = .passive,
    });
    try std.testing.expect(passive.current == null);

    const clipped = surface.pointerMotion(.{
        .id = 3,
        .rect = bounds,
        .clip = .{ .x = 30, .y = 30, .w = 10, .h = 10 },
        .role = .interactive,
    });
    try std.testing.expect(clipped.current == null);
    try std.testing.expect(surface.hovered == null);
}

test "surface reports old and new targets when hover changes" {
    var surface: Surface = .{};
    const first = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const second = Rect{ .x = 20, .y = 0, .w = 10, .h = 10 };

    _ = surface.pointerMotion(.{
        .id = 1, .rect = first, .clip = first, .role = .interactive,
    });
    const change = surface.pointerMotion(.{
        .id = 2, .rect = second, .clip = second, .role = .interactive,
    });

    try std.testing.expect(change.hover_changed);
    try std.testing.expectEqual(@as(?u64, 1), change.previous.?.id);
    try std.testing.expectEqual(first, change.previous.?.rect);
    try std.testing.expectEqual(@as(?u64, 2), change.current.?.id);
    try std.testing.expectEqual(second, change.current.?.rect);
}

test "same target refreshes its damage snapshot without a hover transition" {
    var surface: Surface = .{};
    const first = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const moved = Rect{ .x = 5, .y = 0, .w = 10, .h = 10 };

    _ = surface.pointerMotion(.{
        .id = 9, .rect = first, .clip = first, .role = .interactive,
    });
    const change = surface.pointerMotion(.{
        .id = 9, .rect = moved, .clip = moved, .role = .interactive,
    });

    try std.testing.expect(!change.hover_changed);
    try std.testing.expectEqual(first, change.previous.?.rect);
    try std.testing.expectEqual(moved, change.current.?.rect);
    try std.testing.expectEqual(moved, surface.hovered.?.rect);
}

test "pointer leave returns the previous target for invalidation" {
    var surface: Surface = .{};
    const bounds = Rect{ .x = 4, .y = 5, .w = 20, .h = 10 };

    _ = surface.pointerMotion(.{
        .id = 12, .rect = bounds, .clip = bounds, .role = .button,
    });
    const change = surface.pointerLeave();

    try std.testing.expect(change.hover_changed);
    try std.testing.expectEqual(@as(?u64, 12), change.previous.?.id);
    try std.testing.expectEqual(bounds, change.previous.?.rect);
    try std.testing.expect(change.current == null);
    try std.testing.expect(surface.hovered == null);

    const repeated = surface.pointerLeave();
    try std.testing.expect(!repeated.hover_changed);
}

test "proximity sampling reuses button geometry and respects glow reach" {
    const rect = Rect{ .x = 20, .y = 10, .w = 40, .h = 20 };
    const clip = Rect{ .x = 30, .y = 15, .w = 20, .h = 10 };

    const near = sampleButtonProximity(rect, 30, 10, clip, 5);
    try std.testing.expectEqual(@as(f32, 5), near.distance);
    try std.testing.expectEqual(@as(f32, 10), near.x);
    try std.testing.expectEqual(@as(f32, 0), near.y);

    const outside = sampleButtonProximity(rect, 30, 10, clip, 4);
    try std.testing.expect(std.math.isInf(outside.distance));

    const no_reach = sampleButtonProximity(rect, 30, 10, clip, 0);
    try std.testing.expect(std.math.isInf(no_reach.distance));
}

test "all pointer positions beyond glow reach produce the same inactive sample" {
    const rect = Rect{ .x = 0, .y = 0, .w = 20, .h = 20 };

    const first = sampleButtonProximity(rect, 100, 10, rect, 56);
    const second = sampleButtonProximity(rect, 500, 300, rect, 56);

    try std.testing.expect(std.math.isInf(first.distance));
    try std.testing.expectEqual(first, second);
}
