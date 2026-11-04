// The shell's one scrollbar, as Files draws it: a thumb that sits centred in a
// reserved gutter, thin at rest, widening and tinting toward the accent under
// the pointer, and holding a subtle tint while scrolling. It has no track
// unless the theme sets `scrollbar_track_relief`, which cuts a groove for the
// thumb; `scrollbar_glow = 0` makes the thumb itself flat. Apps
// keep their own scroll mechanics and ask this module for the geometry, the
// paging and drag arithmetic, the look and the feedback animation, so every
// scrollbar behaves alike: Files, Images, PDF and the editor through Cairo
// (`ui/cairo.zig`), Settings and the start menu through `scroll_container.zig`.
const std = @import("std");
const anim = @import("../anim.zig");
const theme = @import("../theme.zig");
const sdf = @import("../sdf.zig");
const text = @import("../text.zig");

pub const Axis = enum { vertical, horizontal };

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(r: Rect, x: f32, y: f32) bool {
        return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
    }
};

/// The thumb never shrinks below this along the scroll axis.
pub const min_thumb: f32 = 24;

/// Scroll tracks and thumbs have flat ends with gently rounded corners.
/// Scale the corners for thin indicators, and cap them for wider scrollbars.
pub fn cornerRadius(thickness: f32) f32 {
    return @min(theme.global.scrollbar_radius, @max(0, thickness) / 4);
}

/// Thickness of the strip a scrollbar owns along the viewport edge, for a
/// configured `scrollbar_width`: the widest thumb plus a margin either side.
/// Pointer presses there belong to the bar and layouts keep content out of it.
pub fn gutter(configured: f32) f32 {
    return @ceil(@max(0, configured)) + 6;
}

fn along(axis: Axis, x: f32, y: f32) f32 {
    return if (axis == .vertical) y else x;
}

fn extent(axis: Axis, r: Rect) f32 {
    return if (axis == .vertical) r.h else r.w;
}

/// Where one bar is, shared by painting and pointer hit testing. `track` is the
/// gutter along the viewport edge; `thumb` spans its full thickness (the hover
/// and grab area), whatever width is painted.
pub const Geometry = struct {
    axis: Axis,
    track: Rect,
    thumb: Rect,
    /// Largest scroll offset; offsets are in the units of `content`.
    max_offset: f32,
    /// What a press on the track beside the thumb scrolls: one viewport.
    page: f32,

    /// Null when there is nothing to scroll. `viewport` and `content` share a
    /// unit (pixels, or items for a strip that scrolls by item); the thumb is
    /// `track` long in proportion `viewport / content`.
    pub fn compute(axis: Axis, track: Rect, viewport: f32, content: f32, offset: f32) ?Geometry {
        const length = extent(axis, track);
        if (length <= 0 or viewport <= 0 or content <= viewport) return null;
        const thumb_length = @min(length, @max(min_thumb, length * viewport / content));
        const max_offset = content - viewport;
        const start = std.math.clamp(offset, 0, max_offset) / max_offset * (length - thumb_length);
        var thumb = track;
        if (axis == .vertical) {
            thumb.y += start;
            thumb.h = thumb_length;
        } else {
            thumb.x += start;
            thumb.w = thumb_length;
        }
        return .{ .axis = axis, .track = track, .thumb = thumb, .max_offset = max_offset, .page = viewport };
    }

    pub fn overThumb(g: Geometry, x: f32, y: f32) bool {
        return g.thumb.contains(x, y);
    }

    pub fn overTrack(g: Geometry, x: f32, y: f32) bool {
        return g.track.contains(x, y);
    }
};

pub const Press = union(enum) {
    /// On the thumb: start a `Drag`.
    grab,
    /// On the track beside it: scroll to this offset, a page toward the pointer.
    page: f32,
};

/// What a press at (x, y) does, or null when it misses the bar.
pub fn press(g: Geometry, x: f32, y: f32, offset: f32) ?Press {
    if (!g.overTrack(x, y)) return null;
    if (g.overThumb(x, y)) return .grab;
    const before = along(g.axis, x, y) < along(g.axis, g.thumb.x, g.thumb.y);
    return .{ .page = std.math.clamp(offset + (if (before) -g.page else g.page), 0, g.max_offset) };
}

/// A thumb being dragged. The pointer's travel maps through the thumb's travel
/// ratio, so the thumb stays under the pointer however long the content is.
pub const Drag = struct {
    active: bool = false,
    pointer: f32 = 0,
    offset: f32 = 0,

    pub fn begin(d: *Drag, g: Geometry, x: f32, y: f32, offset: f32) void {
        d.* = .{ .active = true, .pointer = along(g.axis, x, y), .offset = offset };
    }

    /// Starts from a pointer already reduced to its position along the axis.
    pub fn beginAt(d: *Drag, pointer: f32, offset: f32) void {
        d.* = .{ .active = true, .pointer = pointer, .offset = offset };
    }

    pub fn end(d: *Drag) void {
        d.active = false;
    }

    /// The scroll offset for the pointer at (x, y), outside the bar or not.
    pub fn offsetAt(d: Drag, g: Geometry, x: f32, y: f32) f32 {
        return d.offsetFor(g, along(g.axis, x, y));
    }

    /// The same for a pointer already reduced to its position along the axis.
    pub fn offsetFor(d: Drag, g: Geometry, pointer: f32) f32 {
        const travel = extent(g.axis, g.track) - extent(g.axis, g.thumb);
        if (travel <= 0) return d.offset;
        return std.math.clamp(d.offset + (pointer - d.pointer) * g.max_offset / travel, 0, g.max_offset);
    }
};

/// What to draw: the groove (when the theme cuts one), then the thumb's
/// rounded box, colour and illuminated edge.
pub const Look = struct {
    /// The channel the thumb runs in, inside the gutter. Drawn only when
    /// `track_relief` is not `.flat`; its shading comes from the theme's
    /// `relief_*` values, never from the accent or the frame's glow.
    track: Rect,
    track_radius: f32,
    track_color: [4]f32,
    track_relief: theme.Relief = .flat,
    thumb_relief: theme.Relief = .flat,
    rect: Rect,
    radius: f32,
    color: [4]f32,
    axis: Axis = .vertical,
    highlight: [4]f32 = .{ 1, 1, 1, 1 },
    shine: f32 = 0,
    glow: f32 = 1,
};

/// The thumb for `state`: centred in the gutter across its thickness, as wide
/// as `configured` (`scrollbar_width`) makes it right now, tinted toward the
/// palette's accent.
pub fn look(g: Geometry, state: Appearance, configured: f32, palette: theme.Theme) Look {
    const gutter_thickness = if (g.axis == .vertical) g.track.w else g.track.h;
    const thickness = @min(state.width(configured), @max(0, gutter_thickness - 2));
    var rect = g.thumb;
    if (g.axis == .vertical) {
        rect.x += (rect.w - thickness) / 2;
        rect.w = thickness;
    } else {
        rect.y += (rect.h - thickness) / 2;
        rect.h = thickness;
    }
    var color = palette.scrollbar_thumb;
    for (&color, palette.scrollbar_thumb_active orelse palette.accent) |*channel, target| channel.* += (target - channel.*) * state.accent;
    var highlight = palette.border_glow;
    // A pale reflection of the frame's glow reads as light on every palette.
    for (highlight[0..3]) |*channel| channel.* += (1 - channel.*) * 0.55;
    // The groove fills the gutter less a pixel either side, so the thumb, at
    // its widest, still sits inside it with room to spare. Its floor takes the
    // theme's shadow tone; the relief pass shades the edges from `relief_*`.
    const track_thickness: f32 = @max(0, gutter_thickness - 2);
    var track_color = palette.relief_dark;
    track_color[3] = std.math.clamp(track_color[3] * 0.75, 0.12, 0.5);
    var track_rect = g.track;
    if (g.axis == .vertical) {
        track_rect.x += (track_rect.w - track_thickness) / 2;
        track_rect.w = track_thickness;
    } else {
        track_rect.y += (track_rect.h - track_thickness) / 2;
        track_rect.h = track_thickness;
    }
    // Nested corners: the groove's radius is the thumb's plus the margin between.
    const track_radius = @min(cornerRadius(track_thickness) + 1.5, track_thickness / 2);
    return .{ .track = track_rect, .track_radius = track_radius, .track_color = track_color, .track_relief = palette.scrollbar_track_relief, .thumb_relief = palette.scrollbar_thumb_relief, .rect = rect, .radius = cornerRadius(thickness), .color = color, .axis = g.axis, .highlight = highlight, .shine = state.shine, .glow = @max(palette.scrollbar_glow, 0) };
}

/// Whether `l`'s thumb gets the lit-edge raster. A flat thumb (`scrollbar_glow`
/// of 0) or an unlit one is a plain rounded fill, in the widget tree and Cairo alike.
pub fn lit(l: Look) bool {
    return l.shine > 0 and l.glow > 0;
}

/// The groove; nothing at all while the theme leaves the track flat. It stays
/// inside the track's own box, so the gutter's damage covers it.
pub fn paintTrack(r: *@import("../paint.zig").Renderer, l: Look) void {
    if (l.track_relief == .flat or l.track.w <= 0 or l.track.h <= 0) return;
    r.fillRect(l.track.x, l.track.y, l.track.w, l.track.h, .{
        .color = l.track_color,
        .radius = l.track_radius,
        .relief = l.track_relief,
    });
}

/// The groove, then the thumb. Cairo clients use this same painter through
/// `ui/cairo.zig`'s `drawScrollbar`.
pub fn paint(r: *@import("../paint.zig").Renderer, l: Look) void {
    paintTrack(r, l);
    paintThumb(r, l);
}

/// The light stays inside the thumb, so ordinary scrollbar damage erases it.
pub fn paintThumb(r: *@import("../paint.zig").Renderer, l: Look) void {
    if (!lit(l)) {
        r.fillRect(l.rect.x, l.rect.y, l.rect.w, l.rect.h, .{ .color = l.color, .radius = l.radius });
        paintThumbRelief(r, l);
        return;
    }
    const box = l.rect;
    if (box.w <= 0 or box.h <= 0) return;
    const s = r.scale;
    var left = box.x * s;
    var top = box.y * s;
    var right = (box.x + box.w) * s;
    var bottom = (box.y + box.h) * s;
    if (r.effectiveClip()) |clip| {
        left = @max(left, clip.x * s);
        top = @max(top, clip.y * s);
        right = @min(right, (clip.x + clip.w) * s);
        bottom = @min(bottom, (clip.y + clip.h) * s);
    }
    const x0: i32 = @intFromFloat(@floor(@max(0, left)));
    const y0: i32 = @intFromFloat(@floor(@max(0, top)));
    const x1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.width)), right)));
    const y1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.height)), bottom)));
    r.clean = false;
    var py = y0;
    while (py < y1) : (py += 1) {
        const y = (@as(f32, @floatFromInt(py)) + 0.5) / s - box.y;
        var px = x0;
        while (px < x1) : (px += 1) {
            const x = (@as(f32, @floatFromInt(px)) + 0.5) / s - box.x;
            const distance = sdf.sdRoundedBox(x, y, 0, 0, box.w, box.h, l.radius);
            const coverage = sdf.coverage(distance * s);
            if (coverage <= 0) continue;
            const length = if (l.axis == .vertical) box.h else box.w;
            const thickness = if (l.axis == .vertical) box.w else box.h;
            const u = (if (l.axis == .vertical) y else x) / length;
            const v = (if (l.axis == .vertical) x else y) / thickness;
            const along_light = (u - 0.38) / 0.62;
            const falloff = @max(0, 1 - along_light * along_light);
            const light = falloff * falloff;
            const edge = 1 - std.math.clamp(-distance / 1.1, 0, 1);
            const face = @max(0, 1 - @abs(v - 0.30) / 0.65);
            const strength = @min(1, l.shine * l.glow * l.highlight[3] * light * (0.24 * face + 0.68 * edge));
            var color = l.color;
            for (color[0..3], l.highlight[0..3]) |*channel, target| channel.* += (target - channel.*) * strength;
            text.blendPixel(&r.pixels[@intCast(py * r.width + px)], .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] }, coverage);
        }
    }
    paintThumbRelief(r, l);
}

fn paintThumbRelief(r: *@import("../paint.zig").Renderer, l: Look) void {
    r.paintShapeRelief(l.thumb_relief, .{
        .x = l.rect.x,
        .y = l.rect.y,
        .w = l.rect.w,
        .h = l.rect.h,
        .radius = l.radius,
    }, .{
        .within = .{
            .x = l.track.x,
            .y = l.track.y,
            .w = l.track.w,
            .h = l.track.h,
            .radius = l.track_radius,
        },
    });
}

/// Presentation only: callers retain their scroll mechanics and fixed hit area.
/// Sleep until `deadline` during the hold; request frames only while animating.
pub const Appearance = struct {
    tint: anim.Anim = .{},
    expansion: anim.Anim = .{},
    illumination: anim.Anim = .{},
    accent: f32 = 0,
    wide: f32 = 0,
    shine: f32 = 0,
    deadline: ?i64 = null,
    active: bool = false,

    pub fn step(self: *Appearance, now: i64, moved: bool, hovered: bool, dragging: bool, overflowing: bool) bool {
        const old_accent = self.accent;
        const old_wide = self.wide;
        const old_shine = self.shine;
        if (moved and overflowing) self.deadline = now + 400;
        if (!overflowing or (self.deadline != null and now >= self.deadline.?)) self.deadline = null;
        const engaged = overflowing and (hovered or dragging);
        // Scrolling only tints; hover and drag own expansion independently.
        const target: f32 = if (engaged) 1 else if (self.deadline != null) 0.35 else 0;
        const light: f32 = if (!overflowing) 0 else if (dragging or self.deadline != null) 1 else if (hovered) 0.38 else 0;
        const static = anim.reducedMotion() or !anim.enabled();
        if (static) {
            self.tint.cancel(target);
            self.expansion.cancel(0);
            self.illumination.cancel(light);
        } else {
            if (self.tint.to != target) self.tint.retarget(now, target, 180, .out_cubic);
            const expand: f32 = if (engaged) 1 else 0;
            if (self.expansion.to != expand) self.expansion.retarget(now, expand, 180, .out_cubic);
            if (self.illumination.to != light) self.illumination.retarget(now, light, 180, .out_cubic);
        }
        self.accent = self.tint.value(now);
        self.wide = self.expansion.value(now);
        self.shine = self.illumination.value(now);
        self.active = !self.tint.settled(now) or !self.expansion.settled(now) or !self.illumination.settled(now);
        return self.accent != old_accent or self.wide != old_wide or self.shine != old_shine;
    }

    /// Resting width is 0.75 of `configured`; hover and drag grow it to 1.125.
    pub fn width(self: Appearance, configured: f32) f32 {
        return configured * (theme.global.scrollbar_rest_width + (theme.global.scrollbar_active_width - theme.global.scrollbar_rest_width) * self.wide);
    }
};

test "scrollbar feedback holds, reverses, and respects reduced motion" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    anim.applySettings(.{ .reduced_motion = .off });
    var state: Appearance = .{};
    try std.testing.expect(!state.step(-1, false, false, false, true));
    try std.testing.expect(!state.active and state.deadline == null);
    _ = state.step(0, true, false, false, true);
    _ = state.step(180, false, false, false, true);
    try std.testing.expectEqual(@as(f32, 0.35), state.accent);
    try std.testing.expectEqual(@as(f32, 1), state.shine);
    try std.testing.expectEqual(@as(f32, 6), state.width(8));
    try std.testing.expect(!state.active);
    _ = state.step(400, false, false, false, true);
    _ = state.step(490, true, true, false, true);
    _ = state.step(670, false, false, true, true);
    try std.testing.expectEqual(@as(f32, 1), state.accent);
    try std.testing.expectEqual(@as(f32, 9), state.width(8));
    _ = state.step(680, false, false, false, true);
    _ = state.step(890, false, false, false, true);
    _ = state.step(1070, false, false, false, true);
    try std.testing.expectEqual(@as(f32, 0), state.accent);
    try std.testing.expectEqual(@as(f32, 0), state.shine);
    anim.applySettings(.{ .reduced_motion = .on });
    _ = state.step(900, true, true, true, true);
    try std.testing.expectEqual(@as(f32, 1), state.accent);
    try std.testing.expectEqual(@as(f32, 1), state.shine);
    try std.testing.expectEqual(@as(f32, 6), state.width(8));
    try std.testing.expect(!state.active);
    _ = state.step(901, false, false, false, false);
    try std.testing.expectEqual(@as(f32, 0), state.accent);
    try std.testing.expectEqual(@as(f32, 0), state.shine);
    try std.testing.expect(state.deadline == null);
}

test "scrolling after drag release retains only a subtle tint" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    anim.applySettings(.{ .reduced_motion = .off });
    var state: Appearance = .{};
    _ = state.step(0, false, true, false, true);
    _ = state.step(180, false, true, false, true);
    try std.testing.expectEqual(@as(f32, 9), state.width(8));
    try std.testing.expectEqual(@as(f32, 0.38), state.shine);
    _ = state.step(200, true, false, true, true);
    try std.testing.expectEqual(@as(f32, 9), state.width(8));
    // Release outside the thumb while further wheel/trackpad/key input arrives.
    _ = state.step(220, true, false, false, true);
    _ = state.step(400, true, false, false, true);
    try std.testing.expectEqual(@as(f32, 0.35), state.accent);
    try std.testing.expectEqual(@as(f32, 1), state.shine);
    try std.testing.expectEqual(@as(f32, 6), state.width(8));
    try std.testing.expect(!state.active);
    _ = state.step(600, true, false, false, true);
    try std.testing.expectEqual(@as(f32, 0.35), state.accent);
    try std.testing.expectEqual(@as(f32, 6), state.width(8));
    anim.applySettings(.{ .reduced_motion = .on });
    _ = state.step(610, true, false, false, true);
    try std.testing.expectEqual(@as(f32, 0.35), state.accent);
    try std.testing.expectEqual(@as(f32, 6), state.width(8));
    try std.testing.expect(!state.active);
}

test "geometry sizes and places the thumb, and is null when nothing overflows" {
    const track: Rect = .{ .x = 90, .y = 10, .w = 14, .h = 100 };
    try std.testing.expect(Geometry.compute(.vertical, track, 100, 100, 0) == null);
    try std.testing.expect(Geometry.compute(.vertical, .{ .x = 0, .y = 0, .w = 14, .h = 0 }, 0, 50, 0) == null);
    const top = Geometry.compute(.vertical, track, 100, 400, 0).?;
    try std.testing.expectEqual(@as(f32, 25), top.thumb.h);
    try std.testing.expectEqual(@as(f32, 10), top.thumb.y);
    try std.testing.expectEqual(track.w, top.thumb.w);
    try std.testing.expectEqual(@as(f32, 300), top.max_offset);
    const bottom = Geometry.compute(.vertical, track, 100, 400, 300).?;
    try std.testing.expectEqual(@as(f32, 110), bottom.thumb.y + bottom.thumb.h);
    // A tiny viewport keeps a grabbable thumb.
    try std.testing.expectEqual(min_thumb, Geometry.compute(.vertical, track, 10, 4000, 0).?.thumb.h);
    // Along the other axis the thumb spans the gutter's height.
    const across = Geometry.compute(.horizontal, .{ .x = 0, .y = 90, .w = 200, .h = 14 }, 50, 100, 25).?;
    try std.testing.expectEqual(@as(f32, 100), across.thumb.w);
    try std.testing.expectEqual(@as(f32, 50), across.thumb.x);
    try std.testing.expectEqual(@as(f32, 14), across.thumb.h);
    // Offsets past the end don't push the thumb out of its track.
    const past = Geometry.compute(.vertical, track, 100, 400, 9000).?;
    try std.testing.expectEqual(@as(f32, 110), past.thumb.y + past.thumb.h);
}

test "pressing the track pages toward the pointer and the thumb grabs" {
    const g = Geometry.compute(.vertical, .{ .x = 90, .y = 0, .w = 14, .h = 100 }, 100, 400, 100).?;
    try std.testing.expectEqual(@as(?Press, null), press(g, 50, 50, 100));
    try std.testing.expectEqual(Press.grab, press(g, 95, g.thumb.y + 1, 100).?);
    try std.testing.expectEqual(@as(f32, 200), press(g, 95, 99, 100).?.page);
    try std.testing.expectEqual(@as(f32, 0), press(g, 95, 0, 100).?.page);
    // Paging stops at the end.
    try std.testing.expectEqual(@as(f32, 300), press(g, 95, 99, 250).?.page);
}

test "a drag keeps the thumb under the pointer, inside or outside the bar" {
    var g = Geometry.compute(.vertical, .{ .x = 90, .y = 0, .w = 14, .h = 100 }, 100, 400, 0).?;
    var drag: Drag = .{};
    drag.begin(g, 95, 10, 0);
    try std.testing.expect(drag.active);
    // Thumb 25 long, 75 of travel for 300 of offset: 4 units per pixel.
    try std.testing.expectEqual(@as(f32, 100), drag.offsetAt(g, 95, 35));
    // The pointer may leave the gutter sideways without losing the grab.
    try std.testing.expectEqual(@as(f32, 100), drag.offsetAt(g, 400, 35));
    try std.testing.expectEqual(@as(f32, 300), drag.offsetAt(g, 95, 9000));
    try std.testing.expectEqual(@as(f32, 0), drag.offsetAt(g, 95, -9000));
    g = Geometry.compute(.horizontal, .{ .x = 0, .y = 90, .w = 200, .h = 14 }, 50, 100, 0).?;
    drag.begin(g, 20, 95, 0);
    try std.testing.expectEqual(@as(f32, 25), drag.offsetAt(g, 70, 0));
    drag.end();
    try std.testing.expect(!drag.active);
}

test "the thumb is centred in its gutter, widens and tints with feedback" {
    const g = Geometry.compute(.vertical, .{ .x = 86, .y = 0, .w = gutter(8), .h = 100 }, 100, 400, 0).?;
    var palette = theme.shellPalette();
    palette.scrollbar_thumb = .{ 0.2, 0.2, 0.2, 1 };
    palette.accent = .{ 1, 0, 0, 1 };
    var state: Appearance = .{};
    const rest = look(g, state, 8, palette);
    try std.testing.expectEqual(@as(f32, 6), rest.rect.w);
    try std.testing.expectEqual(@as(f32, 86 + 4), rest.rect.x);
    try std.testing.expectEqual(palette.scrollbar_thumb, rest.color);
    try std.testing.expectEqual(cornerRadius(6), rest.radius);
    // The groove is the gutter less a pixel either side, and off unless asked for.
    try std.testing.expectEqual(@as(f32, 12), rest.track.w);
    try std.testing.expectEqual(@as(f32, 87), rest.track.x);
    try std.testing.expectEqual(theme.Relief.flat, rest.track_relief);
    try std.testing.expectEqual(theme.Relief.flat, rest.thumb_relief);
    try std.testing.expect(rest.track_color[3] > 0);
    state.wide = 1;
    state.accent = 1;
    const hot = look(g, state, 8, palette);
    try std.testing.expectEqual(@as(f32, 9), hot.rect.w);
    try std.testing.expectEqual(@as(f32, 86 + 2.5), hot.rect.x);
    try std.testing.expectEqual(palette.accent, hot.color);
    // A gutter narrower than the animated width clamps it.
    const narrow = Geometry.compute(.vertical, .{ .x = 0, .y = 0, .w = 8, .h = 100 }, 100, 400, 0).?;
    try std.testing.expectEqual(@as(f32, 6), look(narrow, state, 8, palette).rect.w);
}

test "raised thumb relief stays within its channel" {
    const Renderer = @import("../paint.zig").Renderer;
    var palette: theme.Theme = .{};
    palette.scrollbar_thumb = .{ 0.4, 0.4, 0.4, 1 };
    palette.scrollbar_glow = 0;
    palette.scrollbar_thumb_relief = .raised;
    palette.relief_depth = 2;
    palette.relief_softness = 3;
    palette.relief_dark = .{ 0, 0, 0, 0.6 };
    palette.relief_light = .{ 1, 1, 1, 0.6 };

    const g = Geometry.compute(.vertical, .{ .x = 0, .y = 0, .w = gutter(8), .h = 100 }, 100, 400, 0).?;
    var pixels = @as([14 * 100]u32, @splat(0));
    var r = Renderer.init(&pixels, 14, 100, 1);
    r.palette = palette;
    paint(&r, look(g, .{}, 8, palette));

    // The thumb begins at x=4. Its raised edge shades the channel beside it.
    try std.testing.expect(pixels[12 * 14 + 3] != 0);
    // The channel is inset one pixel from the gutter's outer edges.
    try std.testing.expectEqual(@as(u32, 0), pixels[12 * 14]);
    try std.testing.expectEqual(@as(u32, 0), pixels[12 * 14 + 13]);
}

test "the groove shades from the theme's relief and a flat thumb carries no stripe" {
    const Renderer = @import("../paint.zig").Renderer;
    var palette: theme.Theme = .{};
    palette.scrollbar_thumb = .{ 0.4, 0.4, 0.4, 1 };
    // A red accent and glow must not reach either part of the bar.
    palette.accent = .{ 1, 0, 0, 1 };
    palette.border_glow = .{ 1, 0, 0, 1 };
    palette.scrollbar_glow = 0;
    palette.scrollbar_track_relief = .inset;
    palette.relief_depth = 2;
    palette.relief_softness = 3;
    palette.relief_dark = .{ 0, 0, 0, 0.6 };
    palette.relief_light = .{ 1, 1, 1, 0.6 };
    const g = Geometry.compute(.vertical, .{ .x = 0, .y = 0, .w = gutter(8), .h = 100 }, 100, 400, 0).?;
    var pixels = @as([14 * 100]u32, @splat(0));
    var r = Renderer.init(&pixels, 14, 100, 1);
    r.palette = palette;
    // Fully lit state: with a glow of 0 the thumb still paints as one colour.
    paint(&r, look(g, .{ .shine = 1 }, 8, palette));
    const row = 12 * 14;
    for (5..9) |x| {
        try std.testing.expectEqual(pixels[row + 5], pixels[row + x]);
        try std.testing.expectEqual((pixels[row + x] >> 16) & 0xff, pixels[row + x] & 0xff);
    }
    // Below the thumb the groove is dark where it faces the light and lit on
    // the far side, and neutral throughout.
    const groove = 60 * 14;
    try std.testing.expect((pixels[groove + 2] & 0xff) < (pixels[groove + 11] & 0xff));
    for ([_]usize{ 2, 7, 11 }) |x| try std.testing.expectEqual((pixels[groove + x] >> 16) & 0xff, pixels[groove + x] & 0xff);
    // Flat, as every theme but a neumorphic one leaves it: no channel at all.
    palette.scrollbar_track_relief = .flat;
    @memset(&pixels, 0);
    paint(&r, look(g, .{}, 8, palette));
    try std.testing.expectEqual(@as(u32, 0), pixels[groove + 7]);
    try std.testing.expect(pixels[row + 7] != 0);
}
