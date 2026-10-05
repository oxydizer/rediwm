// Scroll mechanics of a `.scroll_container` widget, and its scrollbar: the
// shared one from `scrollbar.zig`, laid along the container's edge.
const std = @import("std");
const layout = @import("../layout.zig");
const Widget = layout.Widget;
const arrange = @import("../arrange.zig");
const anim = @import("../anim.zig");
const wheel = @import("../wheel.zig");
const scrollbar = @import("scrollbar.zig");
const slider = @import("slider.zig");

const theme = @import("../theme.zig");

pub const wheel_step_px: f32 = 40;
// wlroots `wlr_pointer_axis_event.delta_discrete` is in 120ths of a detent
// (`WLR_POINTER_AXIS_DISCRETE_STEP`).
const discrete_step: f32 = 120;

pub const Rect = scrollbar.Rect;

/// Null when the container isn't overflowing (nothing to grab) or the
/// widget isn't a scroll container at all. A row-direction container scrolls
/// sideways with its bar along the bottom edge; a column's is along the right.
/// Padding counts toward the content, so the thumb spans exactly the offsets
/// `arrange` allows.
pub fn geometry(widget: *const Widget) ?scrollbar.Geometry {
    const state = switch (widget.kind) {
        .scroll_container => |state| state,
        else => return null,
    };
    const pad = widget.padding;
    const strip = scrollbar.gutter(theme.global.scrollbar_width);
    if (widget.direction == .row) {
        const thickness = @min(widget.computed_height, strip);
        const track: Rect = .{ .x = widget.computed_x, .y = widget.computed_y + widget.computed_height - thickness, .w = widget.computed_width, .h = thickness };
        return scrollbar.Geometry.compute(.horizontal, track, widget.computed_width, state.content_size + pad.left + pad.right, state.scroll_offset);
    }
    const thickness = @min(widget.computed_width, strip);
    const track: Rect = .{ .x = widget.computed_x + widget.computed_width - thickness, .y = widget.computed_y, .w = thickness, .h = widget.computed_height };
    return scrollbar.Geometry.compute(.vertical, track, widget.computed_height, state.content_size + pad.top + pad.bottom, state.scroll_offset);
}

pub fn hitTestThumb(widget: *const Widget, x: f32, y: f32) bool {
    const g = geometry(widget) orelse return false;
    return g.overThumb(x, y);
}

fn visibleMain(widget: *const Widget) f32 {
    const pad = widget.padding;
    return if (widget.direction == .row)
        @max(0, widget.computed_width - pad.left - pad.right)
    else
        @max(0, widget.computed_height - pad.top - pad.bottom);
}

pub fn canScroll(widget: *const Widget, delta: f32) bool {
    const state = switch (widget.kind) {
        .scroll_container => |s| s,
        else => return false,
    };
    const offset = restingOffset(widget);
    return if (delta < 0) offset > 0 else if (delta > 0) offset < maxOffset(widget, state.content_size) else false;
}

fn maxOffset(widget: *const Widget, content_size: f32) f32 {
    return @max(0, content_size - visibleMain(widget));
}

fn setOffset(widget: *Widget, state: *layout.ScrollState, offset: f32) void {
    const clamped = std.math.clamp(offset, 0, maxOffset(widget, state.content_size));
    if (clamped == state.scroll_offset) return;
    state.scroll_offset = clamped;
    arrange.rearrange(widget);
    widget.markDirty();
}

/// Convert a wlroots pointer-axis event into logical pixels. Discrete
/// wheel notches (v120 units) become `wheel_step_px` per detent; finger
/// / continuous motion uses `delta` as pixels. Prefer discrete when both
/// are present so a detented wheel is one row-step per click rather than
/// whatever pixel value the backend attached.
pub fn axisDeltaPx(delta: f64, delta_discrete: i32) f32 {
    if (delta_discrete != 0) {
        return @as(f32, @floatFromInt(delta_discrete)) / discrete_step * wheel_step_px;
    }
    return @as(f32, @floatCast(delta));
}

/// Moves the offset at once, dropping any wheel glide in flight.
pub fn scrollBy(widget: *Widget, delta_px: f32) void {
    switch (widget.kind) {
        .scroll_container => |*state| {
            state.glide.cancel(state.scroll_offset);
            setOffset(widget, state, state.scroll_offset + delta_px);
        },
        else => {},
    }
}

/// A mouse-wheel notch: glides `delta_px` past where any glide in flight was
/// heading, so quick notches build speed instead of restarting from wherever
/// the offset happens to be. Jumps when the `wheel_scroll` curve is off or
/// motion is reduced. Returns whether the caller must drive `stepGlides`.
pub fn glideBy(widget: *Widget, delta_px: f32, now_ms: i64) bool {
    switch (widget.kind) {
        .scroll_container => |*state| {
            const in_flight = state.glide.active() and !state.glide.settled(now_ms);
            // Anything else may have moved the offset since the last glide
            // (drag, keyboard, a rebuild), so an idle glide restarts from it.
            if (!in_flight) state.glide.cancel(state.scroll_offset);
            // Reversing mid-glide turns around from where the content is,
            // without the old momentum: carrying it reads as lag.
            const now = state.glide.value(now_ms);
            if ((state.glide.to - now) * delta_px < 0) state.glide.cancel(now);
            const step = delta_px * state.wheel.multiplier(delta_px / wheel_step_px, now_ms);
            const target = std.math.clamp(state.glide.to + step, 0, maxOffset(widget, state.content_size));
            state.glide.retargetTo(now_ms, target, anim.curveFor(.wheel_scroll));
            if (!state.glide.settled(now_ms)) return true;
            state.glide.cancel(target);
            setOffset(widget, state, target);
            return false;
        },
        else => return false,
    }
}

/// Advances every wheel glide under `root`, snapping mid-flight offsets to
/// `quantum` (one device pixel) so a frame that moves nothing visible paints
/// nothing. Returns whether any glide still needs frames.
pub fn stepGlides(root: *Widget, now_ms: i64, quantum: f32) bool {
    var pending = false;
    switch (root.kind) {
        .scroll_container => |*state| if (state.glide.active()) {
            const before = state.scroll_offset;
            if (anim.observeUnsettled(state.glide, now_ms)) {
                const q = if (quantum > 0) quantum else 1;
                setOffset(root, state, @round(state.glide.value(now_ms) / q) * q);
                pending = true;
            } else {
                const rest = state.glide.to;
                state.glide.cancel(rest);
                setOffset(root, state, rest);
            }
            if (state.scroll_offset != before) anim.observeNoteChanged();
        },
        else => {},
    }
    for (root.children) |*child| {
        if (stepGlides(child, now_ms, quantum)) pending = true;
    }
    return pending;
}

/// Where the offset is heading: a glide's target, else the offset itself.
/// Tree rebuilds carry this over so a glide cut short lands where it aimed.
pub fn restingOffset(widget: *const Widget) f32 {
    return switch (widget.kind) {
        .scroll_container => |state| if (state.glide.active()) state.glide.to else state.scroll_offset,
        else => 0,
    };
}

fn pointerMain(widget: *const Widget, x: f32, y: f32) f32 {
    return if (widget.direction == .row) x else y;
}

pub fn beginDrag(widget: *Widget, pointer_main: f32) void {
    switch (widget.kind) {
        .scroll_container => |*state| {
            state.glide.cancel(state.scroll_offset);
            state.drag.beginAt(pointer_main, state.scroll_offset);
        },
        else => {},
    }
}

/// Maps the pointer delta through the thumb's travel ratio so the thumb
/// stays under the cursor (a literal 1:1 `scroll_offset += delta` would
/// make the thumb outrun the pointer whenever content_size > track height).
pub fn dragTo(widget: *Widget, pointer_main: f32) void {
    switch (widget.kind) {
        .scroll_container => |*state| {
            if (!state.drag.active) return;
            const g = geometry(widget) orelse return;
            setOffset(widget, state, state.drag.offsetFor(g, pointer_main));
        },
        else => {},
    }
}

pub fn endDrag(widget: *Widget) void {
    switch (widget.kind) {
        .scroll_container => |*state| state.drag.end(),
        else => {},
    }
}

pub const BarPress = enum { none, grabbed, paged };

/// A primary press at (x, y): on the thumb it starts a drag, on the bar beside
/// it it pages toward the pointer, anywhere else it is not the bar's.
pub fn pressBar(widget: *Widget, x: f32, y: f32) BarPress {
    const g = geometry(widget) orelse return .none;
    const state = switch (widget.kind) {
        .scroll_container => |*state| state,
        else => return .none,
    };
    const action = scrollbar.press(g, x, y, state.scroll_offset) orelse return .none;
    switch (action) {
        .grab => {
            beginDrag(widget, pointerMain(widget, x, y));
            return .grabbed;
        },
        .page => |offset| {
            state.glide.cancel(state.scroll_offset);
            setOffset(widget, state, offset);
            return .paged;
        },
    }
}

/// What a host needs to keep the scrollbars' feedback animating.
pub const BarStep = struct {
    /// A fade or widening is in flight: frames are needed until it settles.
    active: bool = false,
    /// The scroll hold ends then; nothing to draw before it.
    deadline: ?i64 = null,

    pub fn pending(step: BarStep) bool {
        return step.active or step.deadline != null;
    }
};

/// Advances the scrollbar feedback of every container under `root` and repaints
/// each whose drawn thumb changed. Sliders share the feedback (`slider.stepFeedback`),
/// so hosts drive both with this one call. Edge-triggered on what is painted,
/// so an idle container or slider costs nothing.
pub fn stepBars(root: *Widget, now_ms: i64) BarStep {
    var result: BarStep = .{};
    switch (root.kind) {
        .scroll_container => |*state| {
            const overflowing = geometry(root) != null;
            const moved = state.scroll_offset != state.bar_observed;
            state.bar_observed = state.scroll_offset;
            if (state.bar.step(now_ms, moved, state.thumb_hover, state.drag.active, overflowing)) {
                root.markPaintDirty();
                anim.observeNoteChanged();
            }
            if (state.bar.active) {
                result.active = true;
                anim.observeNoteActive(now_ms, now_ms);
            }
            result.deadline = state.bar.deadline;
        },
        .slider => {
            const step = slider.stepFeedback(root, now_ms);
            result.active = step.active;
            result.deadline = step.deadline;
        },
        else => {},
    }
    for (root.children) |*child| {
        const step = stepBars(child, now_ms);
        result.active = result.active or step.active;
        if (step.deadline) |at| result.deadline = if (result.deadline) |old| @min(old, at) else at;
    }
    return result;
}

pub fn ensureVisible(widget: *Widget, target_start: f32, target_extent: f32) void {
    switch (widget.kind) {
        .scroll_container => |*state| {
            const viewport_extent = visibleMain(widget);
            const target_end = target_start + target_extent;
            state.glide.cancel(state.scroll_offset);
            var new_offset = state.scroll_offset;
            if (target_start < new_offset) {
                new_offset = target_start;
            } else if (target_end > new_offset + viewport_extent) {
                new_offset = target_end - viewport_extent;
            }
            setOffset(widget, state, new_offset);
        },
        else => {},
    }
}

pub fn ensureVisibleChild(widget: *Widget, child: *const Widget) void {
    switch (widget.kind) {
        .scroll_container => |state| {
            const dir = widget.direction;
            const inner_origin = if (dir == .row) widget.computed_x + widget.padding.left else widget.computed_y + widget.padding.top;
            const child_computed = if (dir == .row) child.computed_x else child.computed_y;
            const child_size = if (dir == .row) child.computed_width else child.computed_height;
            const target_start = (child_computed - inner_origin) + state.scroll_offset;
            ensureVisible(widget, target_start, child_size);
        },
        else => {},
    }
}

test "scrollBy clamps to [0, content_size - visible_height]" {
    var widget = Widget{
        .kind = .{ .scroll_container = .{ .content_size = 200 } },
        .direction = .column,
        .height = .{ .fixed = 100 },
    };
    widget.computed_height = 100;

    scrollBy(&widget, 1000);
    try std.testing.expectEqual(@as(f32, 100), widget.kind.scroll_container.scroll_offset);

    scrollBy(&widget, -1000);
    try std.testing.expectEqual(@as(f32, 0), widget.kind.scroll_container.scroll_offset);

    scrollBy(&widget, wheel_step_px);
    try std.testing.expectEqual(@as(f32, wheel_step_px), widget.kind.scroll_container.scroll_offset);
}

test "drag keeps the thumb under the pointer" {
    var widget = Widget{ .kind = .{ .scroll_container = .{ .content_size = 300 } }, .direction = .column };
    widget.computed_x = 0;
    widget.computed_y = 0;
    widget.computed_width = 20;
    widget.computed_height = 100;

    // track_h 100, thumb_h = (100/300)*100 = 33.3, travel = 66.6, max_offset = 200.
    beginDrag(&widget, 0);
    dragTo(&widget, 33.3);
    try std.testing.expectApproxEqAbs(@as(f32, 100), widget.kind.scroll_container.scroll_offset, 1.0);
    endDrag(&widget);
    try std.testing.expect(!widget.kind.scroll_container.drag.active);
}

test "ensureVisible adjusts scroll_offset to reveal target" {
    var widget = Widget{
        .kind = .{ .scroll_container = .{ .content_size = 500 } },
        .height = .{ .fixed = 100 },
    };
    widget.computed_height = 100;
    widget.direction = .column;

    // Target at y=250..300. Initially offset is 0, so target is below viewport [0, 100].
    ensureVisible(&widget, 250, 50);
    // Viewport needs to shift so bottom (300) is visible: offset = 300 - 100 = 200.
    try std.testing.expectEqual(@as(f32, 200), widget.kind.scroll_container.scroll_offset);

    // Target at y=50..100. Target is above viewport [200, 300].
    ensureVisible(&widget, 50, 50);
    // Viewport shifts up to 50.
    try std.testing.expectEqual(@as(f32, 50), widget.kind.scroll_container.scroll_offset);
}

test "scrollBy rearranges children so paint/hit-test see the new offset" {
    var rows = [_]Widget{
        .{ .kind = .container, .width = .{ .fixed = 50 }, .height = .{ .fixed = 80 } },
        .{ .kind = .container, .width = .{ .fixed = 50 }, .height = .{ .fixed = 120 } },
    };
    var widget = Widget{
        .kind = .{ .scroll_container = .{} },
        .direction = .column,
        .height = .{ .fixed = 100 },
        .width = .{ .fixed = 50 },
        .children = &rows,
    };
    widget.linkParents();
    const measure = @import("../measure.zig").measure;
    measure(&widget, 50, 100);
    arrange.arrange(&widget, 0, 0, widget.computed_width, widget.computed_height);

    const y0 = widget.children[0].computed_y;
    const y1 = widget.children[1].computed_y;
    scrollBy(&widget, 40);
    try std.testing.expectEqual(@as(f32, 40), widget.kind.scroll_container.scroll_offset);
    try std.testing.expectEqual(y0 - 40, widget.children[0].computed_y);
    try std.testing.expectEqual(y1 - 40, widget.children[1].computed_y);
}

test "axisDeltaPx prefers discrete notches and falls back to pixel delta" {
    try std.testing.expectEqual(wheel_step_px, axisDeltaPx(15, 120));
    try std.testing.expectEqual(@as(f32, -wheel_step_px), axisDeltaPx(-15, -120));
    try std.testing.expectEqual(@as(f32, 24), axisDeltaPx(24, 0));
    try std.testing.expectEqual(@as(f32, 0), axisDeltaPx(0, 0));
}

test "scrollbar width changes the visible thumb and grab area together" {
    const saved = theme.global;
    defer theme.global = saved;
    var widget = Widget{
        .kind = .{ .scroll_container = .{ .content_size = 300 } },
        .direction = .column,
        .computed_x = 10,
        .computed_y = 20,
        .computed_width = 100,
        .computed_height = 100,
    };
    // The grab area is the whole gutter: the configured width plus its margins.
    theme.global.scrollbar_width = 4;
    try std.testing.expect(!hitTestThumb(&widget, 90, 25));
    try std.testing.expect(hitTestThumb(&widget, 101, 25));
    theme.global.scrollbar_width = 24;
    try std.testing.expectEqual(@as(f32, 80), geometry(&widget).?.thumb.x);
    try std.testing.expect(hitTestThumb(&widget, 90, 25));
    try std.testing.expect(!hitTestThumb(&widget, 79, 25));
    widget.computed_width = 10;
    try std.testing.expectEqual(@as(f32, 10), geometry(&widget).?.thumb.w);
}

test "padding counts toward the content so the thumb spans the real scroll range" {
    var widget = Widget{
        .kind = .{ .scroll_container = .{ .content_size = 200 } },
        .direction = .column,
        .padding = layout.Edges.all(10),
        .computed_width = 100,
        .computed_height = 100,
    };
    // 200 of content in 80 visible pixels: 120 to scroll, 220 over 100 tall.
    const top = geometry(&widget).?;
    try std.testing.expectEqual(@as(f32, 120), top.max_offset);
    widget.kind.scroll_container.scroll_offset = 120;
    const bottom = geometry(&widget).?;
    try std.testing.expectEqual(@as(f32, 100), bottom.thumb.y + bottom.thumb.h);
    // Content that fits inside the padding has nothing to scroll.
    widget.kind.scroll_container.content_size = 80;
    try std.testing.expect(geometry(&widget) == null);
}

test "pressing the bar grabs the thumb, pages beside it and ignores the rest" {
    var widget = Widget{
        .kind = .{ .scroll_container = .{ .content_size = 400 } },
        .direction = .column,
        .computed_width = 100,
        .computed_height = 100,
    };
    const state = &widget.kind.scroll_container;
    try std.testing.expectEqual(BarPress.none, pressBar(&widget, 40, 50));
    try std.testing.expectEqual(BarPress.paged, pressBar(&widget, 95, 90));
    try std.testing.expectEqual(@as(f32, 100), state.scroll_offset);
    try std.testing.expect(!state.drag.active);
    try std.testing.expectEqual(BarPress.paged, pressBar(&widget, 95, 0));
    try std.testing.expectEqual(@as(f32, 0), state.scroll_offset);
    try std.testing.expectEqual(BarPress.grabbed, pressBar(&widget, 95, 5));
    try std.testing.expect(state.drag.active);
    dragTo(&widget, 5 + 25);
    try std.testing.expectEqual(@as(f32, 100), state.scroll_offset);
    endDrag(&widget);
    try std.testing.expect(!state.drag.active);
    // Nothing overflowing, nothing to press.
    state.content_size = 50;
    try std.testing.expectEqual(BarPress.none, pressBar(&widget, 95, 5));
}

test "bar feedback follows hover, scrolling and drags, and settles to nothing" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    anim.applySettings(.{ .reduced_motion = .off });
    var kids = [_]Widget{.{ .kind = .container }};
    var widget = Widget{
        .kind = .{ .scroll_container = .{ .content_size = 400 } },
        .direction = .column,
        .computed_width = 100,
        .computed_height = 100,
        .children = &kids,
    };
    const state = &widget.kind.scroll_container;
    try std.testing.expect(!stepBars(&widget, 0).pending());
    state.thumb_hover = true;
    var step = stepBars(&widget, 10);
    try std.testing.expect(step.active);
    _ = stepBars(&widget, 400);
    try std.testing.expectEqual(@as(f32, 1), state.bar.accent);
    try std.testing.expect(!stepBars(&widget, 400).pending());
    // Scrolling away from the thumb holds a faint tint, then fades it.
    state.thumb_hover = false;
    state.scroll_offset = 50;
    step = stepBars(&widget, 500);
    try std.testing.expect(step.pending());
    _ = stepBars(&widget, 700);
    try std.testing.expect(stepBars(&widget, 700).deadline != null);
    try std.testing.expect(stepBars(&widget, 1000).active);
    _ = stepBars(&widget, 1300);
    try std.testing.expect(!stepBars(&widget, 1300).pending());
    try std.testing.expectEqual(@as(f32, 0), state.bar.accent);
    // Content that fits shows nothing and holds nothing.
    state.content_size = 50;
    state.scroll_offset = 0;
    try std.testing.expect(!stepBars(&widget, 2000).pending());
}

fn glideFixture() Widget {
    var widget = Widget{
        .kind = .{ .scroll_container = .{ .content_size = 1000 } },
        .direction = .column,
        .height = .{ .fixed = 100 },
    };
    widget.computed_height = 100;
    return widget;
}

test "wheel notches accumulate toward one target and settle exactly" {
    var widget = glideFixture();
    const state = &widget.kind.scroll_container;
    try std.testing.expect(glideBy(&widget, 40, 0));
    try std.testing.expect(stepGlides(&widget, 30, 1));
    const first = state.scroll_offset;
    try std.testing.expect(first > 0 and first < 40);
    try std.testing.expectEqual(@round(first), first);
    // A second notch mid-flight aims past the first target, not past `first`.
    try std.testing.expect(glideBy(&widget, 40, 30));
    try std.testing.expectEqual(@as(f32, 80), restingOffset(&widget));
    try std.testing.expect(!stepGlides(&widget, 2000, 1));
    try std.testing.expectEqual(@as(f32, 80), state.scroll_offset);
    try std.testing.expect(!state.glide.active());
}

test "reversing mid-glide turns around from the current offset" {
    var widget = glideFixture();
    _ = glideBy(&widget, 200, 0);
    _ = stepGlides(&widget, 40, 1);
    const at = widget.kind.scroll_container.glide.value(40);
    _ = glideBy(&widget, -40, 40);
    try std.testing.expectApproxEqAbs(at - 40, restingOffset(&widget), 0.001);
    try std.testing.expectEqual(@as(f32, 0), widget.kind.scroll_container.glide.velocity(40));
}

test "glide targets clamp to the scrollable range" {
    var widget = glideFixture();
    _ = glideBy(&widget, -40, 0);
    try std.testing.expectEqual(@as(f32, 0), restingOffset(&widget));
    _ = glideBy(&widget, 5000, 0);
    try std.testing.expectEqual(@as(f32, 900), restingOffset(&widget));
}

test "wheel jumps when the curve is off or motion is reduced" {
    anim.setReducedMotion(true);
    defer anim.setReducedMotion(false);
    var widget = glideFixture();
    try std.testing.expect(!glideBy(&widget, 40, 0));
    try std.testing.expectEqual(@as(f32, 40), widget.kind.scroll_container.scroll_offset);
    try std.testing.expect(!widget.kind.scroll_container.glide.active());
}

test "direct scrolling and thumb drags cancel a glide" {
    var widget = glideFixture();
    widget.computed_width = 20;
    _ = glideBy(&widget, 200, 0);
    _ = stepGlides(&widget, 40, 1);
    scrollBy(&widget, 10);
    try std.testing.expect(!widget.kind.scroll_container.glide.active());
    try std.testing.expect(!stepGlides(&widget, 60, 1));

    _ = glideBy(&widget, 200, 60);
    beginDrag(&widget, 0);
    try std.testing.expect(!stepGlides(&widget, 80, 1));
}

fn notchRun(widget: *Widget, count: usize, interval_ms: i64) f32 {
    var now: i64 = 1000;
    for (0..count) |_| {
        _ = glideBy(widget, wheel_step_px, now);
        now += interval_ms;
    }
    return restingOffset(widget);
}

test "slow wheel clicks do not accelerate" {
    var widget = glideFixture();
    widget.kind.scroll_container.content_size = 100_000;
    try std.testing.expectEqual(@as(f32, 10 * wheel_step_px), notchRun(&widget, 10, 150));
}

test "a fast run of notches accelerates up to the cap" {
    var widget = glideFixture();
    widget.kind.scroll_container.content_size = 100_000;
    const fast = notchRun(&widget, 10, 30);
    try std.testing.expect(fast > 20 * wheel_step_px);
    // Once the rate is established every notch sits at the cap.
    var capped = glideFixture();
    capped.kind.scroll_container.content_size = 100_000;
    _ = notchRun(&capped, 30, 5);
    const before = restingOffset(&capped);
    _ = glideBy(&capped, wheel_step_px, 1000 + 30 * 5);
    try std.testing.expectApproxEqAbs(wheel.accel.max * wheel_step_px, restingOffset(&capped) - before, 0.01);
}

test "a detent split into high-resolution quarters counts as one notch" {
    var widget = glideFixture();
    widget.kind.scroll_container.content_size = 100_000;
    var now: i64 = 1000;
    for (0..10) |_| {
        for (0..4) |_| {
            _ = glideBy(&widget, wheel_step_px / 4, now);
            now += 3;
        }
        now += 150 - 12;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 10 * wheel_step_px), restingOffset(&widget), 0.01);
}

test "reversing or disabling acceleration steps one notch" {
    var widget = glideFixture();
    widget.kind.scroll_container.content_size = 100_000;
    _ = notchRun(&widget, 20, 20);
    const t = 1000 + 20 * 20;
    const at = widget.kind.scroll_container.glide.value(t);
    _ = glideBy(&widget, -wheel_step_px, t);
    try std.testing.expectApproxEqAbs(at - wheel_step_px, restingOffset(&widget), 0.01);

    const saved = wheel.accel;
    defer wheel.accel = saved;
    wheel.accel.gain = 0;
    var flat = glideFixture();
    flat.kind.scroll_container.content_size = 100_000;
    try std.testing.expectEqual(@as(f32, 20 * wheel_step_px), notchRun(&flat, 20, 20));
}

test "a fast high-resolution spin still accelerates" {
    var widget = glideFixture();
    widget.kind.scroll_container.content_size = 100_000;
    var now: i64 = 1000;
    // Quarter notches every 8 ms: ~31 notches/s with no gaps between detents.
    for (0..40) |_| {
        _ = glideBy(&widget, wheel_step_px / 4, now);
        now += 8;
    }
    try std.testing.expect(restingOffset(&widget) > 20 * wheel_step_px);
}

test "a row-direction container scrolls sideways with its bar along the bottom" {
    var widget = Widget{
        .kind = .{ .scroll_container = .{ .content_size = 400, .scroll_offset = 100 } },
        .direction = .row,
        .computed_x = 10,
        .computed_y = 20,
        .computed_width = 200,
        .computed_height = 50,
    };
    const thumb = geometry(&widget).?.thumb;
    const strip = scrollbar.gutter(theme.global.scrollbar_width);
    try std.testing.expectEqual(@as(f32, 100), thumb.w);
    try std.testing.expectEqual(@as(f32, 10 + 50), thumb.x);
    try std.testing.expectEqual(strip, thumb.h);
    try std.testing.expectEqual(@as(f32, 20 + 50 - strip), thumb.y);
    try std.testing.expect(hitTestThumb(&widget, thumb.x + 1, thumb.y + 1));
    try std.testing.expect(!hitTestThumb(&widget, thumb.x + 1, 20));

    // Dragging the thumb by its own width moves the content by the overflow.
    beginDrag(&widget, thumb.x);
    dragTo(&widget, thumb.x + 100);
    try std.testing.expectEqual(@as(f32, 200), widget.kind.scroll_container.scroll_offset);
    widget.kind.scroll_container.content_size = 150;
    try std.testing.expect(geometry(&widget) == null);
}
