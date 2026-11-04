// State transitions for a `.toggle` widget — identical shape to
// checkbox.zig's `toggle`, kept separate since the two carry unrelated
// visuals (a pill thumb vs. a checked square; see layout.zig's ToggleData).
const std = @import("std");
const layout = @import("../layout.zig");
const Widget = layout.Widget;

const Renderer = @import("../paint.zig").Renderer;
const ReliefBox = @import("../paint.zig").ReliefBox;
const anim = @import("../anim.zig");
const theme = @import("../theme.zig");
const Rect = @import("field.zig").Rect;
const sdf = @import("../sdf.zig");
const text = @import("../text.zig");

/// Natural switch size, shared by widget trees (measure.zig) and hand-laid panels.
pub const width: f32 = 36;
pub const height: f32 = 20;

/// How long the knob takes to travel from one end to the other.
pub const slide_ms: i64 = 280;

pub const Options = struct {
    on: bool,
    /// Where the knob is, 0 (off) to 1 (on). Null rests at the end `on` names;
    /// hand-laid panels that keep no animation state leave it so.
    position: ?f32 = null,
    style: @FieldType(layout.ToggleData, "style") = .standard,
    focused: bool = false,
    disabled: bool = false,
};

/// Shared switch painter for widget trees and hand-laid panels.
pub fn paint(r: *Renderer, box: Rect, opts: Options) void {
    const t = r.palette orelse theme.global;
    if (t.toggle_shaded) return paintShaded(r, box, opts, t);
    const radius: f32 = if (opts.style == .settings) t.toggle_radius else box.h / 2;
    var track = trackColor(t, opts);
    var thumb = t.toggle_thumb orelse t.control_thumb;
    if (opts.disabled) {
        track[3] *= 0.5;
        thumb[3] *= 0.5;
    }
    r.fillRect(box.x, box.y, box.w, box.h, .{
        .relief = if (opts.disabled) .flat else t.toggle_track_relief,
        .color = track,
        .radius = radius,
        .border_width = if (opts.focused and !opts.disabled) 2 else 0,
        .border_color = t.controlFocusColor(),
    });
    const inset: f32 = 2;
    const side = @max(0, box.h - inset * 2);
    const x = box.x + inset + (box.w - 2 * inset - side) * restPosition(opts);
    r.fillRect(x, box.y + inset, side, side, .{ .relief = if (opts.disabled) .flat else t.toggle_thumb_relief, .color = thumb, .radius = if (opts.style == .settings) t.toggle_thumb_radius else side / 2 });
}

/// Recessed track and raised knob, contained in the control's damage bounds.
fn paintShaded(r: *Renderer, box: Rect, opts: Options, t: theme.Theme) void {
    if (box.w <= 0 or box.h <= 0) return;
    r.clean = false;
    const scale = r.scale;
    var left = box.x * scale;
    var top = box.y * scale;
    var right = (box.x + box.w) * scale;
    var bottom = (box.y + box.h) * scale;
    if (r.effectiveClip()) |clip| {
        left = @max(left, clip.x * scale);
        top = @max(top, clip.y * scale);
        right = @min(right, (clip.x + clip.w) * scale);
        bottom = @min(bottom, (clip.y + clip.h) * scale);
    }
    const x0: i32 = @intFromFloat(@floor(@max(0, left)));
    const y0: i32 = @intFromFloat(@floor(@max(0, top)));
    const x1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.width)), right)));
    const y1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.height)), bottom)));
    const radius = if (opts.style == .settings) t.toggle_radius else box.h / 2;
    const inset = box.h * 0.14;
    const side = box.h - 2 * inset;
    const thumb_x = inset + (box.w - 2 * inset - side) * restPosition(opts);
    const thumb_radius = if (opts.style == .settings) t.toggle_thumb_radius else side / 2;
    const track = trackColor(t, opts);
    const thumb = t.toggle_thumb orelse t.control_thumb;
    const opacity: f32 = if (opts.disabled) 0.5 else 1;
    // Neumorphic relief, when the theme asks for it, takes over the hand-made
    // lighting it would double: the track's rim and the knob's cast shadow.
    const track_relief: layout.Relief = if (opts.disabled) .flat else t.toggle_track_relief;
    const thumb_relief: layout.Relief = if (opts.disabled) .flat else t.toggle_thumb_relief;
    const rim_weight: f32 = if (r.reliefActive(track_relief)) 0 else 1;
    const cast_weight: f32 = if (r.reliefActive(thumb_relief)) 0 else 1;
    var py = y0;
    while (py < y1) : (py += 1) {
        const y = (@as(f32, @floatFromInt(py)) + 0.5) / scale - box.y;
        const vertical = std.math.clamp(y / box.h, 0, 1);
        var px = x0;
        while (px < x1) : (px += 1) {
            const x = (@as(f32, @floatFromInt(px)) + 0.5) / scale - box.x;
            const distance = sdf.sdRoundedBox(x, y, 0, 0, box.w, box.h, radius);
            const coverage = sdf.coverage(distance * scale);
            if (coverage <= 0) continue;
            // Dark upper lip fades into the track; the lower lip catches light.
            const rim = 1 - std.math.clamp(-distance / 1.4, 0, 1);
            var color = shade(track, -0.07 + 0.10 * vertical + rim * rim_weight * (-0.22 + 0.32 * vertical));
            // The knob casts a short, soft shadow down into the recess.
            const shadow_distance = sdf.sdRoundedBox(x, y, thumb_x, inset + 0.8, side, side, thumb_radius);
            const shadow = std.math.clamp(1 - shadow_distance / 1.6, 0, 1);
            color = shade(color, -0.24 * cast_weight * shadow * shadow);
            if (opts.focused and !opts.disabled) {
                const focus = sdf.coverage((distance + 2) * scale);
                color = mix(color, t.controlFocusColor(), 1 - focus);
            }
            const knob_distance = sdf.sdRoundedBox(x, y, thumb_x, inset, side, side, thumb_radius);
            const knob_coverage = sdf.coverage(knob_distance * scale);
            const knob_y = std.math.clamp((y - inset) / side, 0, 1);
            const knob_rim = 1 - std.math.clamp(-knob_distance / 0.7, 0, 1);
            const knob = shade(thumb, 0.10 * (1 - knob_y) - 0.04 * knob_y - 0.09 * knob_rim * knob_y);
            // Mix premultiplied layers before applying disabled opacity once.
            const alpha = knob[3] * knob_coverage;
            const out_alpha = alpha + color[3] * (1 - alpha);
            if (out_alpha <= 0) continue;
            text.blendPixel(&r.pixels[@intCast(py * r.width + px)], .{
                .r = (knob[0] * alpha + color[0] * color[3] * (1 - alpha)) / out_alpha,
                .g = (knob[1] * alpha + color[1] * color[3] * (1 - alpha)) / out_alpha,
                .b = (knob[2] * alpha + color[2] * color[3] * (1 - alpha)) / out_alpha,
                .a = out_alpha * opacity,
            }, coverage);
        }
    }
    // Relief goes on last. The groove's shadows skip the knob; the knob's stay
    // inside the track, so they cannot outlive the control's own damage.
    const track_box: ReliefBox = .{ .x = box.x, .y = box.y, .w = box.w, .h = box.h, .radius = radius };
    const knob_box: ReliefBox = .{ .x = box.x + thumb_x, .y = box.y + inset, .w = side, .h = side, .radius = thumb_radius };
    r.paintShapeRelief(track_relief, track_box, .{ .outside = knob_box });
    r.paintShapeRelief(thumb_relief, knob_box, .{ .within = track_box });
}

fn restPosition(opts: Options) f32 {
    return opts.position orelse if (opts.on) 1 else 0;
}

/// The track fades between its off and on colours as the knob travels.
fn trackColor(t: theme.Theme, opts: Options) [4]f32 {
    const off = t.toggle_track;
    const on = t.toggle_on orelse t.accent;
    const at = std.math.clamp(restPosition(opts), 0, 1);
    if (at <= 0) return off;
    if (at >= 1) return on;
    return mix(off, on, at);
}

fn mix(a: [4]f32, b: [4]f32, amount: f32) [4]f32 {
    var result: [4]f32 = undefined;
    for (&result, a, b) |*out, start, end| out.* = start + (end - start) * amount;
    return result;
}

fn shade(color: [4]f32, amount: f32) [4]f32 {
    const light: f32 = if (amount > 0) 1 else 0;
    return mix(color, .{ light, light, light, color[3] }, @abs(amount));
}

/// Advances one switch's knob toward the end `on` names and repaints when its
/// drawn position changed, so an idle switch costs nothing. Returns whether a
/// slide is still in flight and the host must keep stepping. A switch no frame
/// has seen yet, or any switch while animations are off, sits at its end.
pub fn step(widget: *Widget, now_ms: i64) bool {
    const data = switch (widget.kind) {
        .toggle => |*data| data,
        else => return false,
    };
    const target: f32 = if (data.on) 1 else 0;
    const first = std.math.isNan(data.shown);
    if (first or anim.reducedMotion() or !anim.enabled()) {
        data.knob.cancel(target);
    } else if (data.knob.to != target) {
        data.knob.retarget(now_ms, target, slide_ms, .out_cubic);
    }
    const position = data.knob.value(now_ms);
    if (position != data.shown) {
        // A switch at rest already looks right: its first step paints nothing.
        if (!first) {
            widget.markPaintDirty();
            anim.observeNoteChanged();
        }
        data.shown = position;
    }
    const moving = !data.knob.settled(now_ms);
    if (moving) anim.observeNoteActive(now_ms, now_ms);
    return moving;
}

/// What a rebuilt tree needs to keep a slide going: a switch's change often
/// rebuilds its page before the first frame has moved the knob. Named by hash
/// because the old names may live in an arena the rebuild resets.
pub const Saved = struct {
    pub const capacity = 48;
    count: usize = 0,
    names: [capacity]u64 = undefined,
    knob: [capacity]anim.Anim = undefined,
    shown: [capacity]f32 = undefined,
};

fn nameKey(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0, name);
}

/// Records the knob of every named switch under `root`. Unnamed switches have
/// nothing to be matched by and start at rest.
pub fn capture(root: *const Widget, saved: *Saved) void {
    switch (root.kind) {
        .toggle => |data| if (root.name) |name| {
            if (saved.count < Saved.capacity and !std.math.isNan(data.shown)) {
                const i = saved.count;
                saved.count += 1;
                saved.names[i] = nameKey(name);
                saved.knob[i] = data.knob;
                saved.shown[i] = data.shown;
            }
        },
        else => {},
    }
    for (root.children) |*child| capture(child, saved);
}

/// Hands the recorded knobs to the switches of a freshly built `root` with the
/// same name; their next `step` carries on from where the old one stood.
pub fn restore(root: *Widget, saved: *const Saved) void {
    switch (root.kind) {
        .toggle => |*data| if (root.name) |name| {
            const key = nameKey(name);
            for (saved.names[0..saved.count], 0..) |old, i| {
                if (old != key) continue;
                data.knob = saved.knob[i];
                data.shown = saved.shown[i];
                break;
            }
        },
        else => {},
    }
    for (root.children) |*child| restore(child, saved);
}

pub fn toggle(widget: *Widget) void {
    switch (widget.kind) {
        .toggle => |*data| {
            if (data.disabled) return;
            data.on = !data.on;
            widget.markDirty();
            data.on_change(data.owner, data.id, data.on);
        },
        else => {},
    }
}

test "toggle routes changes to its own context and ID" {
    const Recorder = struct {
        last: bool = false,
        calls: u32 = 0,
        id: usize = 0,
        fn call(owner: ?*anyopaque, id: usize, value: bool) void {
            const self: *@This() = @ptrCast(@alignCast(owner.?));
            self.last = value;
            self.calls += 1;
            self.id = id;
        }
    };
    var first = Recorder{};
    var second = Recorder{};
    var one = Widget{ .kind = .{ .toggle = .{ .on = false, .owner = &first, .id = 12, .on_change = Recorder.call } } };
    var two = Widget{ .kind = .{ .toggle = .{ .on = false, .owner = &second, .id = 34, .on_change = Recorder.call } } };
    one.needs_layout = false;
    toggle(&one);
    toggle(&two);
    toggle(&one);
    try std.testing.expect(!one.kind.toggle.on);
    try std.testing.expect(one.needs_layout);
    try std.testing.expectEqual(@as(u32, 2), first.calls);
    try std.testing.expectEqual(@as(usize, 12), first.id);
    try std.testing.expect(!first.last);
    try std.testing.expectEqual(@as(u32, 1), second.calls);
    try std.testing.expectEqual(@as(usize, 34), second.id);
    try std.testing.expect(second.last);
    two.kind.toggle.disabled = true;
    toggle(&two);
    try std.testing.expect(two.kind.toggle.on);
    try std.testing.expectEqual(@as(u32, 1), second.calls);
}

test "toggle slides to its new end and rests there" {
    const Sink = struct {
        fn call(_: ?*anyopaque, _: usize, _: bool) void {}
    };
    var widget = Widget{ .kind = .{ .toggle = .{ .on = false, .on_change = Sink.call } } };
    try std.testing.expect(!step(&widget, 0));
    try std.testing.expectEqual(@as(f32, 0), widget.kind.toggle.shown);

    toggle(&widget);
    // The frame that starts the slide has not moved the knob yet.
    try std.testing.expect(step(&widget, 10));
    widget.needs_paint = false;
    try std.testing.expect(step(&widget, 10 + slide_ms / 2));
    try std.testing.expect(widget.needs_paint);
    const middle = widget.kind.toggle.shown;
    try std.testing.expect(middle > 0 and middle < 1);
    try std.testing.expect(!step(&widget, 10 + slide_ms + 50));
    try std.testing.expectEqual(@as(f32, 1), widget.kind.toggle.shown);

    // Back the other way from mid-slide: it reverses from where it stands.
    toggle(&widget);
    _ = step(&widget, 1000);
    _ = step(&widget, 1000 + slide_ms / 4);
    const going_back = widget.kind.toggle.shown;
    try std.testing.expect(going_back < 1 and going_back > 0);
    toggle(&widget);
    _ = step(&widget, 1000 + slide_ms / 4);
    try std.testing.expect(widget.kind.toggle.knob.to == 1);
    try std.testing.expect(@abs(widget.kind.toggle.knob.value(1000 + slide_ms / 4) - going_back) < 0.01);
}

test "a rebuilt switch carries its slide over by name" {
    const Sink = struct {
        fn call(_: ?*anyopaque, _: usize, _: bool) void {}
    };
    var old = Widget{ .name = "dark_mode", .kind = .{ .toggle = .{ .on = false, .on_change = Sink.call } } };
    _ = step(&old, 0);
    old.kind.toggle.on = true;
    _ = step(&old, 100);
    _ = step(&old, 160);

    var saved: Saved = .{};
    capture(&old, &saved);
    var fresh = Widget{ .name = "dark_mode", .kind = .{ .toggle = .{ .on = true, .on_change = Sink.call } } };
    restore(&fresh, &saved);
    try std.testing.expect(step(&fresh, 170));
    try std.testing.expect(fresh.kind.toggle.shown > 0 and fresh.kind.toggle.shown < 1);
}
