// Immutable background and retained content for each open panel. Widget
// damage repaints only affected pixels; neither cache borrows a display buffer.
const std = @import("std");
const ui = @import("ui");

/// What a pooled buffer holds: the panel that painted it last, and which of
/// its paints. A buffer anything else painted carries none.
pub const Stamp = struct {
    owner: ?*const Background = null,
    generation: u64 = 0,
};

/// Paint numbers are unique across panels, so a buffer painted by a panel
/// since freed never matches one that took over its address.
var next_generation: u64 = 0;

/// Paints remembered per panel. Panels alternate between two pooled buffers,
/// so a recycled one has usually missed a single paint.
const history_len = 4;

const Repair = union(enum) { all, none, box: ui.paint.ClipRect };

pub const Background = struct {
    pixels: []u32 = &.{},
    pixel_storage: []u32 = &.{},
    content_storage: []u32 = &.{},
    key: ?Key = null,
    clean: bool = false,
    content: []u32 = &.{},
    invalid: bool = true,
    content_scale: f32 = 0,
    content_palette: ?ui.theme.Theme = null,
    /// Logical-pixel damage; null means the entire buffer was painted.
    damage: ?ui.paint.ClipRect = null,
    /// The last paints' generations and damage (null: everything), so a
    /// recycled buffer is repaired only where it missed a change.
    history: [history_len]struct { generation: u64 = 0, damage: ?ui.paint.ClipRect = null } = @splat(.{}),
    painted: u64 = 0,

    const Key = struct {
        width: i32,
        height: i32,
        scale: f32,
        clip: ?ui.paint.ClipRect,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        style: ui.layout.RectStyle,
    };

    pub fn deinit(bg: *Background, allocator: std.mem.Allocator) void {
        allocator.free(bg.content_storage);
        allocator.free(bg.pixel_storage);
        bg.* = .{};
    }

    pub fn invalidate(bg: *Background) void {
        bg.invalid = true;
    }

    /// Own the last complete image independently of the buffers locked by
    /// wlroots. Repair a fresh/recycled buffer from it, and only rasterize the
    /// changed widget bounds. Repair pixels are not new scene damage.
    /// `stamp` is the buffer's (`PanelBuffer.createRetained`): with it, only
    /// what the buffer missed since this panel last painted it is repaired.
    /// Leave it null when something is drawn over the retained image.
    pub fn paintIncremental(bg: *Background, allocator: std.mem.Allocator, root: *ui.layout.Widget, renderer: *ui.paint.Renderer, stamp: ?*Stamp) void {
        const held: Stamp = if (stamp) |s| s.* else .{};
        if (stamp) |s| s.* = .{};
        const full = bg.invalid or bg.content.len != renderer.pixels.len or bg.key == null or
            bg.content_scale != renderer.scale or !std.meta.eql(bg.content_palette, renderer.palette) or
            bg.key.?.width != renderer.width or bg.key.?.height != renderer.height or
            !std.meta.eql(bg.key.?.clip, renderer.clip) or bg.key.?.x != root.computed_x or
            bg.key.?.y != root.computed_y or bg.key.?.w != root.computed_width or bg.key.?.h != root.computed_height or
            root.kind != .rect or !std.meta.eql(bg.key.?.style, root.kind.rect) or
            root.needs_paint;
        bg.damage = null;
        if (!full) {
            var dirty: ?ui.paint.ClipRect = null;
            collectDamage(root, false, &dirty);
            if (dirty) |box| {
                // Integer logical boundaries keep text clipping and fractional
                // output scaling on the same grid as a complete paint.
                // Keep the slider-thumb allowance, but grow it when themed
                // relief shadows extend farther beyond a widget's bounds.
                const palette = renderer.palette orelse ui.theme.global;
                const relief_softness = if (palette.relief_softness > 0)
                    palette.relief_softness
                else
                    palette.relief_depth * 1.5;
                const relief_reach = (
                    @max(palette.relief_depth, 0) * renderer.scale +
                    @max(relief_softness * renderer.scale, 1)
                ) / renderer.scale;
                const margin = @max(@as(f32, 8), relief_reach);
                const x = @max(0, @floor(box.x - margin));
                const y = @max(0, @floor(box.y - margin));
                const right = @min(@as(f32, @floatFromInt(renderer.width)) / renderer.scale, @ceil(box.x + box.w + margin));
                const bottom = @min(@as(f32, @floatFromInt(renderer.height)) / renderer.scale, @ceil(box.y + box.h + margin));
                if (right > x and bottom > y) bg.damage = .{ .x = x, .y = y, .w = right - x, .h = bottom - y };
            }
        }
        if (bg.damage) |damage| {
            switch (bg.missed(held)) {
                .all => @memcpy(renderer.pixels, bg.content),
                .none => {},
                .box => |box| copyBox(renderer, renderer.pixels, bg.content, box),
            }
            copyBox(renderer, renderer.pixels, bg.pixels, damage);
            const previous = renderer.damage_clip;
            renderer.damage_clip = damage;
            renderer.clean = false;
            for (root.children) |*child| ui.paint.paintTree(child, renderer);
            ui.paint.paintOverlays(root, renderer);
            renderer.damage_clip = previous;
        } else {
            bg.paint(allocator, root, renderer);
        }
        // A failed cache allocation simply keeps the full-paint fallback.
        if (bg.content.len != renderer.pixels.len) {
            bg.content = resizeStorage(allocator, &bg.content_storage, renderer.pixels.len) catch {
                bg.invalid = true;
                root.clearPaintDirty();
                return;
            };
        }
        if (bg.damage) |damage| copyBox(renderer, bg.content, renderer.pixels, damage) else @memcpy(bg.content, renderer.pixels);
        bg.invalid = false;
        bg.content_scale = renderer.scale;
        bg.content_palette = renderer.palette;
        root.clearPaintDirty();
        next_generation += 1;
        bg.history[bg.painted % history_len] = .{ .generation = next_generation, .damage = bg.damage };
        bg.painted += 1;
        if (stamp) |s| s.* = .{ .owner = bg, .generation = next_generation };
    }

    /// Where a buffer stamped `held` differs from the retained image: the
    /// union of the paints since its own, or all of it when unknown.
    fn missed(bg: *const Background, held: Stamp) Repair {
        if (held.owner != bg) return .all;
        var result: ?ui.paint.ClipRect = null;
        for (0..@min(bg.painted, history_len)) |back| {
            const entry = bg.history[(bg.painted - 1 - back) % history_len];
            if (entry.generation == held.generation) return if (result) |box| .{ .box = box } else .none;
            const box = entry.damage orelse return .all;
            addDamage(.{ .x = box.x, .y = box.y, .w = box.w, .h = box.h }, &result);
        }
        return .all;
    }

    /// Copies the device pixels under logical `box`, on the grid partial paints use.
    fn copyBox(renderer: *const ui.paint.Renderer, dst: []u32, src: []const u32, box: ui.paint.ClipRect) void {
        const stride: usize = @intCast(renderer.width);
        const x0: usize = @intFromFloat(@floor(box.x * renderer.scale));
        const y0: usize = @intFromFloat(@floor(box.y * renderer.scale));
        const x1: usize = @min(stride, @as(usize, @intFromFloat(@ceil((box.x + box.w) * renderer.scale))));
        const y1: usize = @min(@as(usize, @intCast(renderer.height)), @as(usize, @intFromFloat(@ceil((box.y + box.h) * renderer.scale))));
        if (x0 >= x1) return;
        for (y0..y1) |y| @memcpy(dst[y * stride + x0 .. y * stride + x1], src[y * stride + x0 .. y * stride + x1]);
    }

    fn addDamage(box: ui.layout.Widget.PaintBounds, result: *?ui.paint.ClipRect) void {
        if (box.w <= 0 or box.h <= 0) return;
        if (result.*) |old| {
            const x = @min(old.x, box.x);
            const y = @min(old.y, box.y);
            result.* = .{ .x = x, .y = y, .w = @max(old.x + old.w, box.x + box.w) - x, .h = @max(old.y + old.h, box.y + box.h) - y };
        } else result.* = .{ .x = box.x, .y = box.y, .w = box.w, .h = box.h };
    }

    fn collectDamage(widget: *const ui.layout.Widget, inherited: bool, result: *?ui.paint.ClipRect) void {
        const bounds = widget.paintBounds();
        const moved = if (widget.painted_bounds) |old| !std.meta.eql(old, bounds) else true;
        const dirty = inherited or widget.needs_paint or moved;
        if (dirty) {
            addDamage(bounds, result);
            if (widget.painted_bounds) |old| addDamage(old, result);
        }
        // Dirty scroll containers repaint their viewport, not all offscreen
        // descendants. Scroll changes have already rearranged those children.
        if (dirty and widget.kind == .scroll_container) return;
        for (widget.children) |*child| collectDamage(child, dirty, result);
    }

    /// Initializes every destination pixel, then paints the root's children.
    /// Cache allocation failure falls back to a complete ordinary repaint.
    pub fn paint(bg: *Background, allocator: std.mem.Allocator, root: *const ui.layout.Widget, renderer: *ui.paint.Renderer) void {
        if (root.kind != .rect) {
            bg.deinit(allocator);
            @memset(renderer.pixels, 0);
            renderer.clean = true;
            ui.paint.paint(root, renderer);
            return;
        }
        const key: Key = .{
            .width = renderer.width,
            .height = renderer.height,
            .scale = renderer.scale,
            .clip = renderer.clip,
            .x = root.computed_x,
            .y = root.computed_y,
            .w = root.computed_width,
            .h = root.computed_height,
            .style = root.kind.rect,
        };
        if (bg.key != null and std.meta.eql(bg.key.?, key)) {
            @memcpy(renderer.pixels, bg.pixels);
            renderer.clean = bg.clean;
        } else {
            bg.key = null;
            if (key.clip == null and key.x == 0 and key.y == 0 and
                key.style.radius == 0 and key.style.border_width == 0 and
                @round(key.w * key.scale) == @as(f32, @floatFromInt(key.width)) and
                @round(key.h * key.scale) == @as(f32, @floatFromInt(key.height)))
            {
                // A rectangular panel background fills its raster, including
                // the last pixel when a fractional extent rounds up. Treating
                // that edge as a shape would expose wallpaper at chrome joins.
                @memset(renderer.pixels, @import("color.zig").Straight.fromRgba(key.style.color).argb());
                renderer.clean = false;
            } else {
                @memset(renderer.pixels, 0);
                renderer.clean = true;
                renderer.fillRect(key.x, key.y, key.w, key.h, key.style);
            }
            bg.save(allocator, key, renderer);
        }
        for (root.children) |*child| ui.paint.paintTree(child, renderer);
        ui.paint.paintOverlays(root, renderer);
    }

    /// Keep two private allocations through a resize instead of freeing and
    /// faulting in the background and retained image on every frame.
    fn resizeStorage(allocator: std.mem.Allocator, storage: *[]u32, length: usize) ![]u32 {
        if (storage.len < length) {
            storage.* = try allocator.realloc(storage.*, @max(length, storage.len + storage.len / 2));
        }
        return storage.*[0..length];
    }

    fn save(bg: *Background, allocator: std.mem.Allocator, key: Key, renderer: *const ui.paint.Renderer) void {
        if (bg.pixels.len != renderer.pixels.len) {
            bg.pixels = resizeStorage(allocator, &bg.pixel_storage, renderer.pixels.len) catch return;
        }
        @memcpy(bg.pixels, renderer.pixels);
        bg.clean = renderer.clean;
        bg.key = key;
    }
};

fn expectOrdinaryPaint(bg: *Background, allocator: std.mem.Allocator, root: *ui.layout.Widget, width: i32, height: i32, scale: f32, clip: ?ui.paint.ClipRect) !void {
    var actual: [64 * 64]u32 = @splat(0xdeadbeef);
    var expected: [64 * 64]u32 = @splat(0);
    const len: usize = @intCast(width * height);
    var renderer = ui.paint.Renderer.init(actual[0..len], width, height, scale);
    renderer.clip = clip;
    bg.paint(allocator, root, &renderer);
    var reference = ui.paint.Renderer.init(expected[0..len], width, height, scale);
    reference.clip = clip;
    reference.clean = true;
    ui.paint.paint(root, &reference);
    try std.testing.expectEqualSlices(u32, expected[0..len], actual[0..len]);
}

test "panel cache preserves exact pixels and invalidates geometry scale and style" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var bg: Background = .{};
    defer bg.deinit(allocator);
    var children = [_]ui.layout.Widget{.{
        .kind = .{ .rect = .{ .color = .{ 0.8, 0.2, 0.1, 0.4 }, .radius = 2 } },
        .computed_x = 7,
        .computed_y = 5,
        .computed_width = 8,
        .computed_height = 8,
    }};
    var root = ui.layout.Widget{
        .kind = .{ .rect = .{ .color = .{ 0.1, 0.2, 0.3, 0.8 }, .radius = 6, .border_width = 1, .border_color = .{ 0.9, 0.8, 0.7, 0.2 } } },
        .computed_width = 30,
        .computed_height = 24,
        .children = &children,
    };
    try expectOrdinaryPaint(&bg, allocator, &root, 40, 32, 1, null);
    const key = bg.key.?;
    const cached = try std.testing.allocator.dupe(u32, bg.pixels);
    defer std.testing.allocator.free(cached);
    failing.fail_index = failing.alloc_index; // Warm paints must allocate nothing.
    children[0].computed_x += 5;
    try expectOrdinaryPaint(&bg, allocator, &root, 40, 32, 1, null);
    try std.testing.expect(std.meta.eql(key, bg.key.?));
    try std.testing.expectEqualSlices(u32, cached, bg.pixels); // Child ink is never cached.
    try std.testing.expect(!failing.has_induced_failure);
    // These changes have the same buffer size: dimension-only keys would reuse
    // stale corners, colours or scaling and fail the exact-pixel comparison.
    root.kind.rect.color[0] = 0.6;
    try expectOrdinaryPaint(&bg, allocator, &root, 40, 32, 1, null);
    root.kind.rect.radius = 3;
    root.kind.rect.border_width = 2;
    root.kind.rect.border_color[3] = 0.7;
    try expectOrdinaryPaint(&bg, allocator, &root, 40, 32, 1, null);
    root.computed_x = 1.3;
    root.computed_width = 25;
    try expectOrdinaryPaint(&bg, allocator, &root, 40, 32, 1, null);
    try expectOrdinaryPaint(&bg, allocator, &root, 40, 32, 1.25, null);
    try expectOrdinaryPaint(&bg, allocator, &root, 40, 32, 1.25, .{ .x = 3.2, .y = 2, .w = 20, .h = 18 });
    failing.fail_index = std.math.maxInt(usize);
    try expectOrdinaryPaint(&bg, allocator, &root, 60, 48, 1.5, null);
    try std.testing.expectEqual(@as(usize, 60 * 48), bg.pixels.len);
    try expectOrdinaryPaint(&bg, allocator, &root, 64, 64, 2, null);
    root.kind = .container;
    try expectOrdinaryPaint(&bg, allocator, &root, 64, 64, 2, null);
    try std.testing.expect(bg.key == null and bg.pixels.len == 0);
}

test "panel cache allocation failure still produces a fully initialized repaint" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    var bg: Background = .{};
    defer bg.deinit(allocator);
    var root = ui.layout.Widget{
        .kind = .{ .rect = .{ .color = .{ 0.2, 0.4, 0.6, 0.3 }, .radius = 5 } },
        .computed_width = 30,
        .computed_height = 24,
    };
    try expectOrdinaryPaint(&bg, allocator, &root, 40, 32, 1, null);
    try std.testing.expect(bg.key == null);
    failing.fail_index = std.math.maxInt(usize);
    try expectOrdinaryPaint(&bg, allocator, &root, 40, 32, 1, null);
    try std.testing.expect(bg.key != null);
    failing.fail_index = failing.alloc_index;
    try expectOrdinaryPaint(&bg, allocator, &root, 60, 48, 1.5, null);
    try std.testing.expect(bg.key == null);
    // Failed growth retains the old allocation, but never treats it as valid
    // for the larger image. Shrinking can reuse it even with allocation disabled.
    try std.testing.expectEqual(@as(usize, 40 * 32), bg.pixels.len);
    try expectOrdinaryPaint(&bg, allocator, &root, 32, 24, 1, null);
    try std.testing.expect(bg.key != null);
}

test "partial panel paint repairs recycled buffers with exact fractional-scale pixels" {
    const allocator = std.testing.allocator;
    const relief_theme = ui.theme.Theme{
        .relief_depth = 6,
        .relief_softness = 5,
        .button_relief = .raised,
        .button_pressed_relief = .inset,
    };
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        var bg: Background = .{};
        defer bg.deinit(allocator);
        var children = [_]ui.layout.Widget{
            .{ .kind = .{ .button = .{ .label = "Hover me" } }, .computed_x = 10, .computed_y = 12, .computed_width = 100, .computed_height = 30 },
            .{ .kind = .{ .rect = .{ .color = .{ 0.5, 0.1, 0.2, 0.4 }, .radius = 4, .replace = true } }, .computed_x = 95, .computed_y = 25, .computed_width = 30, .computed_height = 35 },
        };
        var root: ui.layout.Widget = .{ .kind = .{ .rect = .{ .color = .{ 0.1, 0.2, 0.3, 0.6 }, .radius = 12 } }, .computed_width = 160, .computed_height = 90, .children = &children };
        root.linkParents();
        const width: i32 = @intFromFloat(160 * scale);
        const height: i32 = @intFromFloat(90 * scale);
        const pixels = try allocator.alloc(u32, @intCast(width * height));
        defer allocator.free(pixels);
        const expected = try allocator.alloc(u32, pixels.len);
        defer allocator.free(expected);
        for ([_]ui.layout.ButtonState{ .idle, .hover, .press, .disabled, .idle }) |state| {
            children[0].kind.button.state = state;
            children[0].markDirty();
            @memset(pixels, 0xdeadbeef);
            var renderer = ui.paint.Renderer.init(pixels, width, height, scale);
            renderer.palette = relief_theme;
            bg.paintIncremental(allocator, &root, &renderer, null);
            @memset(expected, 0);
            var reference = ui.paint.Renderer.init(expected, width, height, scale);
            reference.palette = relief_theme;
            reference.clean = true;
            ui.paint.paint(&root, &reference);
            try std.testing.expectEqualSlices(u32, expected, pixels);
            if (state == .hover) {
                try std.testing.expect(bg.damage != null);
                try std.testing.expect(bg.damage.?.w * bg.damage.?.h < 160 * 90 * 3 / 4);
            }
        }

        // Moving a raised button must clear its old shadow footprint and paint
        // the new one, including the relief overhang at fractional scales.
        children[0].kind.button.state = .hover;
        children[0].computed_x += 18;
        children[0].markPaintDirty();
        @memset(pixels, 0xdeadbeef);
        var moved = ui.paint.Renderer.init(pixels, width, height, scale);
        moved.palette = relief_theme;
        bg.paintIncremental(allocator, &root, &moved, null);
        @memset(expected, 0);
        var moved_reference = ui.paint.Renderer.init(expected, width, height, scale);
        moved_reference.palette = relief_theme;
        moved_reference.clean = true;
        ui.paint.paint(&root, &moved_reference);
        try std.testing.expectEqualSlices(u32, expected, pixels);

        children[1].kind.rect.color[0] = 0.8;
        children[1].computed_x -= 25;
        children[1].markPaintDirty();
        @memset(pixels, 0xdeadbeef);
        var partial = ui.paint.Renderer.init(pixels, width, height, scale);
        bg.paintIncremental(allocator, &root, &partial, null);
        @memset(expected, 0);
        var reference = ui.paint.Renderer.init(expected, width, height, scale);
        reference.clean = true;
        ui.paint.paint(&root, &reference);
        try std.testing.expectEqualSlices(u32, expected, pixels);

        // Two stamped buffers taking turns are repaired only where each
        // missed a change: the button and the rect change on alternate paints,
        // apart, so a missed one lies outside the current damage. Buffer 1
        // misses two paints, then carries a stamp of another panel.
        const other = try allocator.alloc(u32, pixels.len);
        defer allocator.free(other);
        const stranger: Background = .{};
        var stamps: [2]Stamp = .{ .{}, .{} };
        const buffers = [2][]u32{ pixels, other };
        children[1].computed_x = 125;
        children[1].markPaintDirty();
        for ([_]usize{ 0, 1, 0, 0, 1, 1 }, 0..) |turn, i| {
            if (i % 2 == 0) {
                children[0].kind.button.state = if (children[0].kind.button.state == .hover) .idle else .hover;
                children[0].markDirty();
            } else {
                children[1].kind.rect.color[1] += 0.1;
                children[1].markPaintDirty();
            }
            if (i == 5) stamps[turn].owner = &stranger;
            var stamped = ui.paint.Renderer.init(buffers[turn], width, height, scale);
            bg.paintIncremental(allocator, &root, &stamped, &stamps[turn]);
            @memset(expected, 0);
            var whole = ui.paint.Renderer.init(expected, width, height, scale);
            whole.clean = true;
            ui.paint.paint(&root, &whole);
            try std.testing.expectEqualSlices(u32, expected, buffers[turn]);
        }
    }
}

test "incremental panel allocation failure falls back to a complete paint" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    var bg: Background = .{};
    defer bg.deinit(allocator);
    var child = [_]ui.layout.Widget{.{ .kind = .{ .rect = .{ .color = .{ 1, 0, 0, 0.4 }, .radius = 3 } }, .computed_x = 10, .computed_y = 8, .computed_width = 12, .computed_height = 12 }};
    var root: ui.layout.Widget = .{ .kind = .{ .rect = .{ .color = .{ 0.1, 0.2, 0.3, 0.5 }, .radius = 5 } }, .computed_width = 40, .computed_height = 32, .children = &child };
    root.linkParents();
    var pixels: [40 * 32]u32 = undefined;
    var expected: [40 * 32]u32 = @splat(0);
    var renderer = ui.paint.Renderer.init(&pixels, 40, 32, 1);
    bg.paintIncremental(allocator, &root, &renderer, null);
    var reference = ui.paint.Renderer.init(&expected, 40, 32, 1);
    reference.clean = true;
    ui.paint.paint(&root, &reference);
    try std.testing.expectEqualSlices(u32, &expected, &pixels);
    try std.testing.expect(bg.invalid);
    failing.fail_index = std.math.maxInt(usize);
    bg.paintIncremental(allocator, &root, &renderer, null);
    try std.testing.expectEqualSlices(u32, &expected, &pixels);
    try std.testing.expect(!bg.invalid);
    failing.fail_index = failing.alloc_index;
    const allocations = failing.alloc_index;
    child[0].computed_x += 4;
    child[0].markPaintDirty();
    bg.paintIncremental(allocator, &root, &renderer, null);
    @memset(&expected, 0);
    reference.clean = true;
    ui.paint.paint(&root, &reference);
    try std.testing.expectEqualSlices(u32, &expected, &pixels);
    try std.testing.expectEqual(allocations, failing.alloc_index);
}
