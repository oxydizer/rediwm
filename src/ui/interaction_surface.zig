//! Widget-independent interaction regions for retained and hand-laid UI.
//! The caller owns region storage and rebuilds it with each layout pass.

const std = @import("std");

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return self.w > 0 and self.h > 0 and
            x >= self.x and x < self.x + self.w and
            y >= self.y and y < self.y + self.h;
    }
};

pub const Role = enum {
    button,
    interactive,
    passive,
};

pub const ProximitySample = struct {
    distance: f32 = std.math.inf(f32),
    x: f32 = 0,
    y: f32 = 0,
};

pub const Region = struct {
    id: u64,
    rect: Rect,
    clip: Rect,
    role: Role,
    enabled: bool = true,
    proximity: ProximitySample = .{},
    /// Set by pointer updates when this region needs visual repainting.
    visual_changed: bool = false,
};

pub const Change = struct {
    previous_hover: ?u64,
    hovered: ?u64,
    hover_changed: bool,
    proximity_changed: bool,

    pub fn changed(self: Change) bool {
        return self.hover_changed or self.proximity_changed;
    }
};

/// A non-owning interaction surface. The caller supplies a fresh region
/// buffer for each layout pass; no region or application pointer is retained.
pub const Surface = struct {
    storage: []Region = &.{},
    count: usize = 0,
    hovered: ?u64 = null,

    /// Starts a layout pass using caller-owned storage.
    pub fn begin(self: *Surface, storage: []Region) void {
        self.storage = storage;
        self.count = 0;
    }

    /// Adds a region. Returns false if the buffer is full or its ID is
    /// already present in this layout pass.
    pub fn addRegion(self: *Surface, region: Region) bool {
        if (self.count == self.storage.len or self.regionById(region.id) != null)
            return false;
        var added = region;
        added.visual_changed = false;
        self.storage[self.count] = added;
        self.count += 1;
        return true;
    }

    pub fn regionCount(self: *const Surface) usize {
        return self.count;
    }

    pub fn regionAt(self: *const Surface, index: usize) ?*const Region {
        if (index >= self.count) return null;
        return &self.storage[index];
    }

    pub fn regionById(self: *const Surface, id: u64) ?*Region {
        for (self.storage[0..self.count]) |*region| {
            if (region.id == id) return region;
        }
        return null;
    }

    /// Samples proximity for every enabled button and resolves the topmost
    /// eligible hit region. Later-emitted regions are considered topmost.
    pub fn pointerMotion(self: *Surface, x: f32, y: f32) Change {
        const previous = self.hovered;
        var next: ?u64 = null;
        var proximity_changed = false;

        for (self.storage[0..self.count]) |*region| {
            region.visual_changed = false;

            if (region.role == .button) {
                const sample = if (region.enabled)
                    sampleProximity(region.rect, x, y, region.clip)
                else
                    ProximitySample{};

                if (!sameSample(region.proximity, sample)) {
                    region.proximity = sample;
                    region.visual_changed = true;
                    proximity_changed = true;
                }
            }

            if (region.enabled and region.role != .passive and
                region.rect.contains(x, y) and region.clip.contains(x, y))
            {
                next = region.id;
            }
        }

        self.hovered = next;
        const hover_changed = previous != next;
        if (hover_changed) {
            if (previous) |id| {
                if (self.regionById(id)) |region| region.visual_changed = true;
            }
            if (next) |id| {
                if (self.regionById(id)) |region| region.visual_changed = true;
            }
        }

        return .{
            .previous_hover = previous,
            .hovered = next,
            .hover_changed = hover_changed,
            .proximity_changed = proximity_changed,
        };
    }

    /// Clears hover and button proximity without retaining the last pointer.
    pub fn pointerLeave(self: *Surface) Change {
        const previous = self.hovered;
        var proximity_changed = false;
        self.hovered = null;

        for (self.storage[0..self.count]) |*region| {
            region.visual_changed = false;
            if (region.role != .button) continue;
            const cleared = ProximitySample{};
            if (!sameSample(region.proximity, cleared)) {
                region.proximity = cleared;
                region.visual_changed = true;
                proximity_changed = true;
            }
        }

        if (previous) |id| {
            if (self.regionById(id)) |region| region.visual_changed = true;
        }

        return .{
            .previous_hover = previous,
            .hovered = null,
            .hover_changed = previous != null,
            .proximity_changed = proximity_changed,
        };
    }
};

fn intersect(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{
        .x = x0,
        .y = y0,
        .w = @max(0, x1 - x0),
        .h = @max(0, y1 - y0),
    };
}

fn sampleProximity(box: Rect, x: f32, y: f32, clip: Rect) ProximitySample {
    const visible = intersect(box, clip);
    if (visible.w <= 0 or visible.h <= 0) {
        return .{ .distance = std.math.inf(f32), .x = x - box.x, .y = y - box.y };
    }

    const right = visible.x + visible.w;
    const bottom = visible.y + visible.h;
    const dx = if (x < visible.x) visible.x - x else if (x > right) x - right else 0;
    const dy = if (y < visible.y) visible.y - y else if (y > bottom) y - bottom else 0;
    return .{ .distance = @sqrt(dx * dx + dy * dy), .x = x - box.x, .y = y - box.y };
}

fn sameSample(a: ProximitySample, b: ProximitySample) bool {
    return a.distance == b.distance and a.x == b.x and a.y == b.y;
}

test "surface resolves the last eligible overlapping region" {
    var storage: [3]Region = undefined;
    var surface: Surface = .{};
    surface.begin(&storage);

    const bounds = Rect{ .x = 0, .y = 0, .w = 20, .h = 20 };
    try std.testing.expect(surface.addRegion(.{
        .id = 1, .rect = bounds, .clip = bounds, .role = .button,
    }));
    try std.testing.expect(surface.addRegion(.{
        .id = 2, .rect = bounds, .clip = bounds, .role = .interactive,
    }));
    try std.testing.expect(surface.addRegion(.{
        .id = 3, .rect = bounds, .clip = bounds, .role = .passive,
    }));

    const change = surface.pointerMotion(10, 10);
    try std.testing.expectEqual(@as(?u64, 2), change.hovered);
    try std.testing.expect(change.hover_changed);
    try std.testing.expect(surface.regionById(1) != null);
}

test "surface respects clipping and disabled regions" {
    var storage: [2]Region = undefined;
    var surface: Surface = .{};
    surface.begin(&storage);

    try std.testing.expect(surface.addRegion(.{
        .id = 1,
        .rect = .{ .x = 0, .y = 0, .w = 30, .h = 30 },
        .clip = .{ .x = 10, .y = 10, .w = 10, .h = 10 },
        .role = .interactive,
    }));
    try std.testing.expect(surface.addRegion(.{
        .id = 2,
        .rect = .{ .x = 10, .y = 10, .w = 10, .h = 10 },
        .clip = .{ .x = 10, .y = 10, .w = 10, .h = 10 },
        .role = .interactive,
        .enabled = false,
    }));

    try std.testing.expectEqual(@as(?u64, null), surface.pointerMotion(5, 5).hovered);
    try std.testing.expectEqual(@as(?u64, 1), surface.pointerMotion(15, 15).hovered);
}

test "button proximity uses the visible clipped rectangle and local coordinates" {
    var storage: [1]Region = undefined;
    var surface: Surface = .{};
    surface.begin(&storage);

    try std.testing.expect(surface.addRegion(.{
        .id = 7,
        .rect = .{ .x = 20, .y = 10, .w = 40, .h = 20 },
        .clip = .{ .x = 30, .y = 15, .w = 20, .h = 10 },
        .role = .button,
    }));

    const change = surface.pointerMotion(30, 10);
    try std.testing.expect(change.proximity_changed);
    const region = surface.regionById(7).?;
    try std.testing.expectEqual(@as(f32, 5), region.proximity.distance);
    try std.testing.expectEqual(@as(f32, 10), region.proximity.x);
    try std.testing.expectEqual(@as(f32, 0), region.proximity.y);
}

test "unchanged pointer samples do not report another change" {
    var storage: [1]Region = undefined;
    var surface: Surface = .{};
    surface.begin(&storage);

    try std.testing.expect(surface.addRegion(.{
        .id = 4,
        .rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .clip = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .role = .button,
    }));

    try std.testing.expect(surface.pointerMotion(10, 10).changed());
    try std.testing.expect(!surface.pointerMotion(10, 10).changed());
}

test "pointer leave clears hover and proximity" {
    var storage: [1]Region = undefined;
    var surface: Surface = .{};
    surface.begin(&storage);

    try std.testing.expect(surface.addRegion(.{
        .id = 9,
        .rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .clip = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .role = .button,
    }));

    _ = surface.pointerMotion(10, 10);
    const change = surface.pointerLeave();
    try std.testing.expect(change.hover_changed);
    try std.testing.expect(change.proximity_changed);
    try std.testing.expectEqual(@as(?u64, null), surface.hovered);
    try std.testing.expect(std.math.isInf(surface.regionById(9).?.proximity.distance));
}

test "disabling a button clears its previous proximity sample" {
    var storage: [1]Region = undefined;
    var surface: Surface = .{};
    surface.begin(&storage);

    try std.testing.expect(surface.addRegion(.{
        .id = 15,
        .rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .clip = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .role = .button,
    }));

    _ = surface.pointerMotion(10, 10);
    try std.testing.expectEqual(@as(f32, 0), storage[0].proximity.distance);

    storage[0].enabled = false;
    const change = surface.pointerMotion(10, 10);

    try std.testing.expect(change.proximity_changed);
    try std.testing.expect(storage[0].visual_changed);
    try std.testing.expect(std.math.isInf(storage[0].proximity.distance));
}

test "layout rebuild preserves hover and reports changed regions" {
    var first_storage: [1]Region = undefined;
    var second_storage: [1]Region = undefined;
    var surface: Surface = .{};
    const bounds = Rect{ .x = 0, .y = 0, .w = 20, .h = 20 };

    surface.begin(&first_storage);
    try std.testing.expect(surface.addRegion(.{
        .id = 12, .rect = bounds, .clip = bounds, .role = .interactive,
    }));
    const initial = surface.pointerMotion(10, 10);
    try std.testing.expect(initial.hover_changed);
    try std.testing.expect(first_storage[0].visual_changed);

    surface.begin(&second_storage);
    try std.testing.expectEqual(@as(?u64, 12), surface.hovered);
    try std.testing.expect(surface.addRegion(.{
        .id = 12, .rect = bounds, .clip = bounds, .role = .interactive,
    }));

    const rebuilt = surface.pointerMotion(10, 10);
    try std.testing.expect(!rebuilt.hover_changed);
    try std.testing.expectEqual(@as(?u64, 12), rebuilt.hovered);
    try std.testing.expect(!second_storage[0].visual_changed);
}

test "hover transitions mark old and new regions for repaint" {
    var storage: [2]Region = undefined;
    var surface: Surface = .{};
    surface.begin(&storage);

    try std.testing.expect(surface.addRegion(.{
        .id = 1,
        .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .clip = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .role = .interactive,
    }));
    try std.testing.expect(surface.addRegion(.{
        .id = 2,
        .rect = .{ .x = 20, .y = 0, .w = 10, .h = 10 },
        .clip = .{ .x = 20, .y = 0, .w = 10, .h = 10 },
        .role = .interactive,
    }));

    _ = surface.pointerMotion(5, 5);
    const change = surface.pointerMotion(25, 5);
    try std.testing.expect(change.hover_changed);
    try std.testing.expect(storage[0].visual_changed);
    try std.testing.expect(storage[1].visual_changed);
}

test "surface rejects duplicate IDs and a full region buffer" {
    var storage: [1]Region = undefined;
    var surface: Surface = .{};
    surface.begin(&storage);
    const region: Region = .{
        .id = 1,
        .rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .clip = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .role = .interactive,
    };
    try std.testing.expect(surface.addRegion(region));
    try std.testing.expect(!surface.addRegion(region));
    try std.testing.expect(!surface.addRegion(.{
        .id = 2, .rect = region.rect, .clip = region.clip, .role = .interactive,
    }));
}
