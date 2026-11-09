// The shell's one button look, and state transitions for a `.button`
// widget. `paint` is what the widget tree's `.button` draws and what screens
// laid out by hand (lock, polkit) call directly. The hovered/pressed
// bookkeeping lives in input.zig's dispatcher; this module only moves a single
// button between states and fires its callback.
const chrome = @import("../window_chrome.zig");
const std = @import("std");
const layout = @import("../layout.zig");
const theme = @import("../theme.zig");
const paint_mod = @import("../paint.zig");
const Renderer = paint_mod.Renderer;
const Widget = layout.Widget;
const ButtonState = layout.ButtonState;
const IconId = layout.IconId;

pub const Rect = @import("field.zig").Rect;

pub const ProximitySample = struct {
    distance: f32,
    x: f32,
    y: f32,
};

/// Intersects two logical-pixel rectangles.
pub fn intersectRect(a: Rect, b: Rect) Rect {
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

/// Samples pointer proximity to the visible portion of a button.
/// Returned x/y coordinates are local to the original button rectangle.
pub fn sampleProximity(box: Rect, pointer_x: f32, pointer_y: f32, clip: Rect) ProximitySample {
    const visible = intersectRect(box, clip);
    if (visible.w <= 0 or visible.h <= 0) {
        return .{
            .distance = std.math.inf(f32),
            .x = pointer_x - box.x,
            .y = pointer_y - box.y,
        };
    }

    const right = visible.x + visible.w;
    const bottom = visible.y + visible.h;
    const dx = if (pointer_x < visible.x) visible.x - pointer_x else if (pointer_x > right) pointer_x - right else 0;
    const dy = if (pointer_y < visible.y) visible.y - pointer_y else if (pointer_y > bottom) pointer_y - bottom else 0;

    return .{
        .distance = @sqrt(dx * dx + dy * dy),
        .x = pointer_x - box.x,
        .y = pointer_y - box.y,
    };
}

test {
    _ = @import("button_glow_tests.zig");
}

test "proximity sampling respects clipping and returns button-local coordinates" {
    const box: Rect = .{ .x = 20, .y = 10, .w = 40, .h = 20 };
    const clip: Rect = .{ .x = 30, .y = 15, .w = 20, .h = 10 };

    const near = sampleProximity(box, 30, 10, clip);
    try std.testing.expectEqual(@as(f32, 5), near.distance);
    try std.testing.expectEqual(@as(f32, 10), near.x);
    try std.testing.expectEqual(@as(f32, 0), near.y);

    const inside = sampleProximity(box, 35, 20, clip);
    try std.testing.expectEqual(@as(f32, 0), inside.distance);

    const invisible_clip: Rect = .{ .x = 70, .y = 15, .w = 20, .h = 10 };
    const outside = sampleProximity(box, 10, 20, invisible_clip);
    try std.testing.expect(std.math.isInf(outside.distance));
}

/// `primary` is the accent fill (the start menu's selected category chip);
/// `secondary` a quiet surface with a hairline border; `ghost` shows only on
/// hover; `chrome` is a window-style close button, red on hover.
pub const Variant = enum { primary, secondary, ghost, chrome };

pub const Size = enum { sm, md, lg };
pub const Alignment = enum { center, left };

pub const Options = struct {
    variant: Variant = .secondary,
    size: Size = .md,
    label: []const u8 = "",
    /// Paints this glyph centred instead of `label` (an icon-only button);
    /// the label stays its accessible name.
    icon: ?IconId = null,
    /// Icon size as a fraction of the button's shorter side.
    icon_scale: f32 = 0.5,
    /// A glyph before the label, centred together with it ("▭ Region").
    leading_icon: ?IconId = null,
    /// A glyph at the right end, after a centred label (the lock's "Unlock ›").
    trailing_icon: ?IconId = null,
    /// `leading_icon` above the label rather than beside it: a tile, like the
    /// lock's Power and Restart.
    stacked: bool = false,
    alignment: Alignment = .center,
    /// A danger-colored outline and label for a destructive secondary action.
    destructive: bool = false,
    /// Override for chrome's tab navigation buttons, which use the ghost look.
    radius: ?f32 = null,
};

pub const State = struct {
    pointer: ButtonState = .idle,
    /// Toggled on (a view mode, an active filter): an accent tint behind a
    /// non-primary button.
    selected: bool = false,
    /// Keyboard focus: a ring inside the button's bounds, so a widget tree's
    /// damage still covers it.
    focused: bool = false,
    proximity_distance: f32 = std.math.inf(f32),
    proximity_x: f32 = 0,
    proximity_y: f32 = 0,
    /// Retained hover-elevation progress, from 0 at rest to 1 at full hover.
    hover_elevation: f32 = 0,
};

pub const Metrics = struct {
    height: f32,
    font_size: f32,
    pad_x: f32,
    icon: f32,
    radius: f32,
};

pub fn metrics(size: Size, t: theme.Theme) Metrics {
    return switch (size) {
        .sm => .{ .height = 28, .font_size = t.button_font_size, .pad_x = 10, .icon = 14, .radius = t.radius },
        .md => .{ .height = 34, .font_size = t.button_font_size, .pad_x = 13, .icon = 16, .radius = t.radius },
        // Matches the large text field it usually sits under.
        .lg => .{ .height = 52, .font_size = t.button_font_size + 5.5, .pad_x = 20, .icon = 20, .radius = t.field_radius + 2 },
    };
}

/// Natural size for a label `label_w` wide, for measure.zig.
pub fn naturalSize(opts: Options, t: theme.Theme, label_w: f32) struct { w: f32, h: f32 } {
    const m = metrics(opts.size, t);
    if (opts.icon != null) return .{ .w = m.height, .h = m.height };
    if (opts.stacked) {
        const icon = stackedIcon(m);
        return .{ .w = @max(label_w, icon) + m.pad_x * 2, .h = icon + stack_gap + m.font_size * 1.4 + m.pad_x };
    }
    const leading: f32 = if (opts.leading_icon != null) m.icon + iconGap(m) else 0;
    const trailing: f32 = if (opts.trailing_icon != null) m.icon + m.pad_x / 2 else 0;
    return .{ .w = label_w + m.pad_x * 2 + 2 + leading + trailing, .h = m.height };
}

const stack_gap: f32 = 6;

fn stackedIcon(m: Metrics) f32 {
    return m.icon * 1.5;
}

fn iconGap(m: Metrics) f32 {
    return m.icon / 2;
}

pub fn optionsOf(data: layout.ButtonData) Options {
    return .{
        .variant = data.variant,
        .size = data.size,
        .label = data.label,
        .icon = data.icon,
        .icon_scale = data.icon_scale,
        .leading_icon = data.leading_icon,
        .trailing_icon = data.trailing_icon,
        .stacked = data.stacked,
        .alignment = data.alignment,
        .destructive = data.destructive,
    };
}

pub fn paint(r: *Renderer, box: Rect, opts: Options, state: State) void {
    paintBackground(r, box, opts, state);
    paintContent(r, box, opts, state);
}

/// Separate passes let toolbars place a moving hover chip beneath the ink.
pub fn paintBackground(r: *Renderer, box: Rect, opts: Options, state: State) void {
    const t = r.palette orelse theme.global;
    const m = metrics(opts.size, t);
    const disabled = state.pointer == .disabled;
    const hovered = state.pointer == .hover or state.pointer == .press;
    const adaptive_hover = opts.variant == .secondary and
        !state.selected and !disabled and !state.focused and
        state.pointer != .press and r.reliefActive(t.button_relief) and
        (state.pointer == .hover or state.hover_elevation > 0);
    const clear: [4]f32 = .{ 0, 0, 0, 0 };
    var bg: [4]f32 = switch (opts.variant) {
        .primary => t.accent,
        .secondary => if (hovered and !adaptive_hover) t.surface_hover else t.surface,
        .ghost => if (hovered) t.surface_hover else clear,
        .chrome => if (hovered) t.window_close_hover else clear,
    };
    if (opts.variant == .chrome) bg[3] *= t.window_close_hover_alpha;
    if (opts.destructive and opts.variant == .secondary) bg = .{ t.danger[0], t.danger[1], t.danger[2], t.danger[3] * @as(f32, if (hovered) 0.16 else 0.06) };
    if (opts.variant == .primary and hovered) for (0..3) |i| {
        bg[i] = @min(1, bg[i] * t.button_hover_brightness);
    };
    if (state.selected and opts.variant != .primary) bg = .{ t.accent[0], t.accent[1], t.accent[2], t.accent[3] * @as(f32, if (hovered) t.button_selected_hover_alpha else t.button_selected_alpha) };
    if (disabled) bg[3] *= t.button_disabled_alpha;
    const ring = state.focused and !disabled;
    const border_w: f32 = if (ring) 2 else if (opts.variant == .secondary) 1 else 0;
    const relief: layout.Relief = if (disabled or (opts.variant != .primary and opts.variant != .secondary)) .flat else if (state.pointer == .press or state.selected) t.button_pressed_relief else t.button_relief;
    const radius = opts.radius orelse if (opts.variant == .chrome) chrome.cornerRadius(t.chrome_round_buttons, box.w, box.h, chrome.control_radius) else m.radius;
    if (bg[3] > 0 or border_w > 0) {
        r.fillRect(box.x, box.y, box.w, box.h, .{
            .relief = if (adaptive_hover) .flat else relief,
            .color = bg,
            .radius = radius,
            .border_width = border_w,
            .border_color = if (ring) t.controlFocusColor() else if (opts.destructive and !disabled) t.danger else if (hovered) t.border else t.border_soft,
        });
        if (adaptive_hover) {
            paintAdaptiveRelief(r, box, radius, t.button_relief, state.hover_elevation, t);
        }
    }

    // Directional lighting gives quiet graphite buttons a subtle raised feel.
    // Preserve selected, disabled, primary, ghost, and chrome treatments.
    if (opts.variant == .secondary and !state.selected and !disabled and !state.focused and !r.reliefActive(relief) and box.w > 0 and box.h >= 6) {
        const inset = @min(m.radius, @min(box.w, box.h) / 3);
        const strip_w = box.w - inset * 2;
        if (strip_w > 0) {
            const highlight_alpha: f32 = if (hovered) 0.055 else 0.085;
            r.fillRect(box.x + inset, box.y + 1.5, strip_w, 1, .{
                .color = .{ t.fg[0], t.fg[1], t.fg[2], highlight_alpha },
                .radius = 0.5,
            });
            r.fillRect(box.x + inset, box.y + box.h - 2.5, strip_w, 1, .{
                .color = .{ 0, 0, 0, if (hovered) 0.12 else 0.18 },
                .radius = 0.5,
            });
        }
    }

    paintProximityGlow(r, box, radius, state);
}

/// Crossfades an inset groove into raised relief, or gives an already-raised
/// button a little more lift. The temporary renderer palettes keep the
/// transition local to this button and leave the shared theme untouched.
fn paintAdaptiveRelief(
    r: *Renderer,
    box: Rect,
    radius: f32,
    base: layout.Relief,
    progress: f32,
    palette: theme.Theme,
) void {
    const amount = std.math.clamp(progress, 0, 1);
    const shape: paint_mod.ReliefBox = .{
        .x = box.x,
        .y = box.y,
        .w = box.w,
        .h = box.h,
        .radius = radius,
    };

    switch (base) {
        .inset => {
            var inset_palette = palette;
            inset_palette.relief_dark[3] *= 1 - amount;
            inset_palette.relief_light[3] *= 1 - amount;
            var inset_renderer = r.*;
            inset_renderer.palette = inset_palette;
            inset_renderer.paintShapeRelief(.inset, shape, .{});

            var raised_palette = palette;
            raised_palette.relief_dark[3] *= amount;
            raised_palette.relief_light[3] *= amount;
            raised_palette.relief_depth *= 1 + 0.18 * amount;
            var raised_renderer = r.*;
            raised_renderer.palette = raised_palette;
            raised_renderer.paintShapeRelief(.raised, shape, .{});
        },
        .raised => {
            var raised_palette = palette;
            raised_palette.relief_depth *= 1 + 0.18 * amount;
            var raised_renderer = r.*;
            raised_renderer.palette = raised_palette;
            raised_renderer.paintShapeRelief(.raised, shape, .{});
        },
        .flat => {},
    }
}

/// Smoothly fades an edge contribution by pointer distance.
fn glowNear(px: f32, py: f32, edge_x: f32, edge_y: f32, reach: f32) f32 {
    const distance = std.math.hypot(px - edge_x, py - edge_y);
    if (!(distance < reach)) return 0;
    const n = 1 - distance / reach;
    return n * n * (3 - 2 * n);
}

/// Paints independent pointer-facing highlights on every nearby button edge.
/// Overlapping edge contributions use their maximum, keeping corners controlled.
fn paintProximityGlow(r: *Renderer, box: Rect, radius: f32, state: State) void {
    if (state.pointer == .disabled) return;
    paintProximityGlowAt(
        r,
        box,
        radius,
        state.proximity_distance,
        state.proximity_x,
        state.proximity_y,
    );
}

/// Whether `paintProximityGlowAt` can draw anything with theme `t`. Hosts
/// skip proximity sampling (and the repaints it causes) when it cannot.
pub fn proximityGlowVisible(t: theme.Theme) bool {
    return t.button_hover_glow_enabled and t.border_glow[3] > 0 and
        t.border_glow_reach > 0 and t.border_glow_length > 0 and t.border_glow_depth > 0;
}

/// Whether `paintProximityGlowAt` lights any edge of a `w`×`h` box for a
/// box-local pointer (the same edge anchors and falloff). Callers that paint
/// through an offscreen layer test this first and skip the layer otherwise.
pub fn proximityGlowLit(w: f32, h: f32, radius: f32, pointer_x: f32, pointer_y: f32, reach: f32) bool {
    if (w <= 0 or h <= 0) return false;
    const corner_radius = std.math.clamp(radius, 0, 0.5 * @min(w, h));
    const ax = std.math.clamp(pointer_x, corner_radius, w - corner_radius);
    const ay = std.math.clamp(pointer_y, corner_radius, h - corner_radius);
    return glowNear(pointer_x, pointer_y, ax, 0, reach) > 0 or
        glowNear(pointer_x, pointer_y, w, ay, reach) > 0 or
        glowNear(pointer_x, pointer_y, ax, h, reach) > 0 or
        glowNear(pointer_x, pointer_y, 0, ay, reach) > 0;
}

/// Shared edge-light painter for buttons and other interactive surfaces.
/// Pointer coordinates are local to `box`.
pub fn paintProximityGlowAt(
    r: *Renderer,
    box: Rect,
    radius: f32,
    proximity_distance: f32,
    proximity_x: f32,
    proximity_y: f32,
) void {
    const t = r.palette orelse theme.global;
    if (!proximityGlowVisible(t) or proximity_distance >= std.math.inf(f32) or
        box.w <= 0 or box.h <= 0)
        return;

    const corner_radius = std.math.clamp(radius, 0, 0.5 * @min(box.w, box.h));
    const reach = t.border_glow_reach;
    const pointer_x = proximity_x;
    const pointer_y = proximity_y;

    const Edge = struct {
        x: f32,
        y: f32,
        near: f32,
        /// The edge runs vertically, so its falloff is measured along y.
        vertical: bool,
        /// The edge is the left or top edge.
        negative: bool,
    };

    const edges = [_]Edge{
        .{
            .x = std.math.clamp(pointer_x, corner_radius, box.w - corner_radius),
            .y = 0,
            .near = glowNear(
                pointer_x, pointer_y,
                std.math.clamp(pointer_x, corner_radius, box.w - corner_radius), 0, reach,
            ),
            .vertical = false,
            .negative = true,
        },
        .{
            .x = box.w,
            .y = std.math.clamp(pointer_y, corner_radius, box.h - corner_radius),
            .near = glowNear(
                pointer_x, pointer_y, box.w,
                std.math.clamp(pointer_y, corner_radius, box.h - corner_radius), reach,
            ),
            .vertical = true,
            .negative = false,
        },
        .{
            .x = std.math.clamp(pointer_x, corner_radius, box.w - corner_radius),
            .y = box.h,
            .near = glowNear(
                pointer_x, pointer_y,
                std.math.clamp(pointer_x, corner_radius, box.w - corner_radius), box.h, reach,
            ),
            .vertical = false,
            .negative = false,
        },
        .{
            .x = 0,
            .y = std.math.clamp(pointer_y, corner_radius, box.h - corner_radius),
            .near = glowNear(
                pointer_x, pointer_y, 0,
                std.math.clamp(pointer_y, corner_radius, box.h - corner_radius), reach,
            ),
            .vertical = true,
            .negative = true,
        },
    };

    var active = false;
    for (edges) |edge| {
        if (edge.near > 0) {
            active = true;
            break;
        }
    }
    if (!active) return;

    const s = r.scale;
    var dx0 = box.x * s;
    var dy0 = box.y * s;
    var dx1 = (box.x + box.w) * s;
    var dy1 = (box.y + box.h) * s;
    if (r.effectiveClip()) |clip| {
        dx0 = @max(dx0, clip.x * s);
        dy0 = @max(dy0, clip.y * s);
        dx1 = @min(dx1, (clip.x + clip.w) * s);
        dy1 = @min(dy1, (clip.y + clip.h) * s);
    }

    const x0: i32 = @intFromFloat(@floor(@max(0, dx0)));
    const y0: i32 = @intFromFloat(@floor(@max(0, dy0)));
    const x1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.width)), dx1)));
    const y1: i32 = @intFromFloat(@ceil(@min(@as(f32, @floatFromInt(r.height)), dy1)));
    if (x0 >= x1 or y0 >= y1) return;

    const length = t.border_glow_length;
    const depth = t.border_glow_depth;
    const red = paint_mod.toColor(t.border_glow);
    const dark = paint_mod.toColor(.{ 0, 0, 0, t.border_glow[3] * 0.35 });
    const shape = .{
        .x = box.x * s,
        .y = box.y * s,
        .w = box.w * s,
        .h = box.h * s,
        .radius = radius * s,
    };

    // Every edge term is (falloff along the edge) * (falloff by depth), each
    // a function of one axis only. The top and bottom edges share their
    // along-x falloff, left and right their along-y one, so a column needs
    // three exponentials and a row three, instead of eight per pixel. The
    // products keep the per-pixel order (near * along * depth * coverage),
    // so the result is bit-identical; an unlit edge contributes 0.
    const top = edges[0].near;
    const right = edges[1].near;
    const bottom = edges[2].near;
    const left = edges[3].near;
    const anchor_x = edges[0].x;
    const anchor_y = edges[1].y;
    const chunk = 256;
    var top_along: [chunk]f32 = undefined;
    var bottom_along: [chunk]f32 = undefined;
    var from_left: [chunk]f32 = undefined;
    var from_right: [chunk]f32 = undefined;

    // `blendPixel` moves a channel by at most alpha * a * max(channel, 1),
    // and rounds to bytes: below a quarter of a byte step nothing changes, so
    // skipping such faint blends (most of a large surface) is exact. Scaling
    // by coverage <= 1 is monotonic, so it is applied after the test.
    const near_min = 0.25 / (255 * red.a * @max(1, @max(red.r, @max(red.g, red.b))));
    const far_min = 0.25 / (255 * dark.a);

    r.clean = false;
    var cx0 = x0;
    while (cx0 < x1) : (cx0 += chunk) {
        const cx1 = @min(x1, cx0 + chunk);
        var max_top: f32 = 0;
        var max_bottom: f32 = 0;
        var max_left: f32 = 0;
        var max_right: f32 = 0;
        for (0..@intCast(cx1 - cx0)) |i| {
            const sx = @as(f32, @floatFromInt(cx0 + @as(i32, @intCast(i)))) + 0.5;
            const logical_x = sx / s;
            const along_ratio = (logical_x - box.x - anchor_x) / length;
            const along_falloff = @exp(-2 * along_ratio * along_ratio);
            top_along[i] = top * along_falloff;
            bottom_along[i] = bottom * along_falloff;
            from_left[i] = @exp(-@max(0, logical_x - box.x) / depth);
            from_right[i] = @exp(-@max(0, box.x + box.w - logical_x) / depth);
            max_top = @max(max_top, top_along[i]);
            max_bottom = @max(max_bottom, bottom_along[i]);
            max_left = @max(max_left, from_left[i]);
            max_right = @max(max_right, from_right[i]);
        }

        var py = y0;
        while (py < y1) : (py += 1) {
            const sy = @as(f32, @floatFromInt(py)) + 0.5;
            const logical_y = sy / s;
            const along_ratio = (logical_y - box.y - anchor_y) / length;
            const along_falloff = @exp(-2 * along_ratio * along_ratio);
            const right_along = right * along_falloff;
            const left_along = left * along_falloff;
            const from_top = @exp(-@max(0, logical_y - box.y) / depth);
            const from_bottom = @exp(-@max(0, box.y + box.h - logical_y) / depth);
            // Upper bounds of this row's alphas: skip it when both are faint.
            const row_near = @max(@max(max_top * from_top, right_along * max_right), @max(max_bottom * from_bottom, left_along * max_left));
            const row_far = @max(@max(max_top * from_bottom, right_along * max_left), @max(max_bottom * from_top, left_along * max_right));
            if (row_near < near_min and row_far < far_min) continue;
            const row: usize = @intCast(py * r.width);

            var px = cx0;
            while (px < cx1) : (px += 1) {
                const i: usize = @intCast(px - cx0);
                const near_raw = @max(
                    @max(top_along[i] * from_top, right_along * from_right[i]),
                    @max(bottom_along[i] * from_bottom, left_along * from_left[i]),
                );
                const far_raw = @max(
                    @max(top_along[i] * from_bottom, right_along * from_left[i]),
                    @max(bottom_along[i] * from_top, left_along * from_right[i]),
                );
                if (near_raw < near_min and far_raw < far_min) continue;

                const sx = @as(f32, @floatFromInt(px)) + 0.5;
                const coverage = paint_mod.sdf.coverage(paint_mod.sdf.sdRoundedBox(
                    sx, sy, shape.x, shape.y, shape.w, shape.h, shape.radius,
                ));
                if (coverage <= 0) continue;
                const near_alpha = near_raw * coverage;
                const far_alpha = far_raw * coverage;

                const index = row + @as(usize, @intCast(px));
                if (near_alpha >= near_min) paint_mod.blendPixel(&r.pixels[index], red, near_alpha);
                if (far_alpha >= far_min) paint_mod.blendPixel(&r.pixels[index], dark, far_alpha);
            }
        }
    }
}

pub fn paintContent(r: *Renderer, box: Rect, opts: Options, state: State) void {
    const t = r.palette orelse theme.global;
    const m = metrics(opts.size, t);
    const disabled = state.pointer == .disabled;
    const fg = if (disabled) t.faint else if (opts.variant == .primary) t.on_accent else if (opts.destructive) t.danger else t.fg;
    if (opts.icon) |id| {
        if (opts.variant == .chrome and id == .close) {
            paintClose(r, box, opts, state);
            return;
        }
        const side = @min(box.w, box.h) * opts.icon_scale;
        r.drawIcon(box.x + (box.w - side) / 2, box.y + (box.h - side) / 2, side, side, .{ .id = id, .color = fg });
        return;
    }
    const label_style: layout.TextStyle = .{ .content = opts.label, .font_size = m.font_size, .weight = 600, .color = fg };
    // A left-aligned label starts at the edge, so a long one would otherwise
    // run under the trailing glyph.
    const trailing_room: f32 = if (opts.alignment == .left and opts.trailing_icon != null) m.icon + m.pad_x + iconGap(m) else 0;
    if (opts.stacked) {
        const icon = stackedIcon(m);
        const line = m.font_size * 1.4;
        const top = box.y + (box.h - (icon + stack_gap + line)) / 2;
        if (opts.leading_icon) |id| r.drawIcon(box.x + (box.w - icon) / 2, top, icon, icon, .{ .id = id, .color = fg });
        const tx = paint_mod.centeredTextX(box.x, box.w, opts.label, m.font_size);
        r.drawText(tx, top + icon + stack_gap, box.x + box.w - tx, line, label_style);
        return;
    }
    if (opts.leading_icon) |id| {
        // Icon and label centred as one group.
        const label_w = paint_mod.labelWidth(opts.label, m.font_size);
        const group = m.icon + iconGap(m) + label_w;
        const left = box.x + (if (opts.alignment == .left) m.pad_x else @max(0, (box.w - group) / 2));
        r.drawIcon(left, box.y + (box.h - m.icon) / 2, m.icon, m.icon, .{ .id = id, .color = fg });
        const tx = left + m.icon + iconGap(m);
        r.drawText(tx, box.y, @max(0, box.x + box.w - tx - trailing_room), box.h, label_style);
    } else {
        const tx = if (opts.alignment == .left) box.x + m.pad_x else paint_mod.centeredTextX(box.x, box.w, opts.label, m.font_size);
        r.drawText(tx, box.y, @max(0, box.x + box.w - tx - trailing_room), box.h, label_style);
    }
    if (opts.trailing_icon) |id| {
        r.drawIcon(box.x + box.w - m.pad_x - m.icon, box.y + (box.h - m.icon) / 2, m.icon, m.icon, .{ .id = id, .color = fg });
    }
}

// The same SDF cross and neutral resting ink as server-side decorations.
fn paintClose(r: *Renderer, box: Rect, opts: Options, state: State) void {
    const t = r.palette orelse theme.global;
    const hovered = state.pointer == .hover or state.pointer == .press;
    const dim = t.window_dim;
    const luma = dim[0] * 0.2126 + dim[1] * 0.7152 + dim[2] * 0.0722;
    const ink = if (hovered) @import("../text.zig").Color{ .r = t.window_close_fg[0], .g = t.window_close_fg[1], .b = t.window_close_fg[2], .a = t.window_close_fg[3] } else @import("../text.zig").Color{ .r = luma, .g = luma, .b = luma, .a = dim[3] * @as(f32, if (state.pointer == .disabled) 0.5 else 1) };
    const cx = box.x + box.w / 2;
    const cy = box.y + box.h / 2;
    const glyph_scale = chrome.button_glyph_scale * opts.icon_scale / 0.5;
    if (glyph_scale <= 0) return;
    const clip = r.effectiveClip();
    const left: i32 = @intFromFloat(@max(0, @floor(box.x * r.scale)));
    const top: i32 = @intFromFloat(@max(0, @floor(box.y * r.scale)));
    const right: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(r.width)), @ceil((box.x + box.w) * r.scale)));
    const bottom: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(r.height)), @ceil((box.y + box.h) * r.scale)));
    r.clean = false;
    var y = top;
    while (y < bottom) : (y += 1) {
        var x = left;
        while (x < right) : (x += 1) {
            const px = (@as(f32, @floatFromInt(x)) + 0.5) / r.scale;
            const py = (@as(f32, @floatFromInt(y)) + 0.5) / r.scale;
            if (clip) |c| if (px < c.x or py < c.y or px >= c.x + c.w or py >= c.y + c.h) continue;
            const cov = chrome.closeIconCoverage((px - cx) / glyph_scale, (py - cy) / glyph_scale, .{ .x = -1, .y = -1, .w = 2, .h = 2 }, @sqrt(@as(f32, 0.5)), r.scale * glyph_scale);
            paint_mod.blendPixel(&r.pixels[@intCast(y * r.width + x)], ink, cov);
        }
    }
}

pub fn setState(widget: *Widget, state: ButtonState) void {
    switch (widget.kind) {
        .button => |*data| {
            if (data.state == state) return;
            data.state = state;
            widget.markDirty();
        },
        else => {},
    }
}

/// Fires `on_click`. A no-op on a disabled button or a non-button widget.
pub fn press(widget: *Widget) void {
    switch (widget.kind) {
        .button => |data| if (data.state != .disabled) {
            if (data.on_click) |cb| cb(data.owner, data.id);
        },
        else => {},
    }
}

test "setState is a no-op when unchanged, dirties on real change" {
    var clicked = false;
    const Callback = struct {
        fn call(_: ?*anyopaque, _: usize) void {}
    };
    var widget = Widget{ .kind = .{ .button = .{ .label = "Go", .on_click = &Callback.call } } };
    widget.needs_layout = false;

    setState(&widget, .idle);
    try std.testing.expect(!widget.needs_layout);

    setState(&widget, .hover);
    try std.testing.expect(widget.needs_layout);
    try std.testing.expectEqual(ButtonState.hover, widget.kind.button.state);
    _ = &clicked;
}

test "press ignores disabled buttons" {
    const Counter = struct {
        var count: u32 = 0;
        fn call(_: ?*anyopaque, _: usize) void {
            count += 1;
        }
    };
    var widget = Widget{ .kind = .{ .button = .{ .label = "Go", .on_click = &Counter.call, .state = .disabled } } };
    press(&widget);
    try std.testing.expectEqual(@as(u32, 0), Counter.count);

    setState(&widget, .idle);
    press(&widget);
    try std.testing.expectEqual(@as(u32, 1), Counter.count);
}

test "sizes: natural width wraps the label, icon-only buttons are square" {
    const t: theme.Theme = .{};
    const md = naturalSize(.{ .label = "x" }, t, 40);
    try std.testing.expectEqual(@as(f32, 40 + 26 + 2), md.w);
    try std.testing.expectEqual(@as(f32, 34), md.h);
    const lg = naturalSize(.{ .size = .lg, .trailing_icon = .chevron_right }, t, 40);
    try std.testing.expectEqual(@as(f32, 40 + 40 + 2 + 20 + 10), lg.w);
    try std.testing.expectEqual(@as(f32, 52), lg.h);
    const icon = naturalSize(.{ .icon = .power, .size = .sm }, t, 40);
    try std.testing.expectEqual(@as(f32, 28), icon.w);
    const leading = naturalSize(.{ .leading_icon = .region }, t, 40);
    try std.testing.expectEqual(md.w + 16 + 8, leading.w);
    const tile = naturalSize(.{ .leading_icon = .power, .stacked = true, .size = .sm }, t, 40);
    try std.testing.expectEqual(@as(f32, 60), tile.w);
    try std.testing.expect(tile.h > 21 + 6 + 12.5);
}

test "a stacked tile draws its icon above the label" {
    var pixels: [90 * 80]u32 = @splat(0);
    var r = Renderer.init(&pixels, 90, 80, 1);
    var t: theme.Theme = .{};
    t.fg = .{ 1, 1, 1, 1 };
    r.palette = t;
    paint(&r, .{ .x = 0, .y = 0, .w = 90, .h = 80 }, .{ .variant = .ghost, .size = .sm, .stacked = true, .leading_icon = .plus, .label = "Power" }, .{});
    var top_ink: usize = 80;
    var bottom_ink: usize = 0;
    for (0..80) |y| for (0..90) |x| if (pixels[y * 90 + x] >> 24 > 0x80) {
        top_ink = @min(top_ink, y);
        bottom_ink = @max(bottom_ink, y);
    };
    // Ink spans icon and label, centred as a group.
    try std.testing.expect(top_ink > 5 and top_ink < 30);
    try std.testing.expect(bottom_ink > 45 and bottom_ink < 75);
}

test "primary fills with the accent and a focus ring shows only when enabled" {
    var pixels: [80 * 40]u32 = @splat(0);
    var r = Renderer.init(&pixels, 80, 40, 1);
    var t: theme.Theme = .{};
    t.accent = .{ 1, 0, 0, 1 };
    t.fg = .{ 1, 1, 1, 1 };
    r.palette = t;
    const box: Rect = .{ .x = 0, .y = 0, .w = 80, .h = 40 };
    paint(&r, box, .{ .variant = .primary }, .{});
    // Middle of the top edge, and a pixel inside that edge.
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[40]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[80 + 40]);

    paint(&r, box, .{ .variant = .primary }, .{ .focused = true });
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[40]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[80 + 40]);

    @memset(&pixels, 0);
    paint(&r, box, .{ .variant = .primary }, .{ .focused = true, .pointer = .disabled });
    // Half-alpha fill, no ring.
    try std.testing.expect(pixels[40] >> 24 < 0xc0);
    try std.testing.expectEqual(pixels[40] & 0xff, 0);
}

test "ghost and chrome buttons draw nothing until hovered" {
    var pixels: [40 * 40]u32 = @splat(0);
    var r = Renderer.init(&pixels, 40, 40, 1);
    const box: Rect = .{ .x = 0, .y = 0, .w = 40, .h = 40 };
    paint(&r, box, .{ .variant = .ghost, .icon = .close, .icon_scale = 0.01 }, .{});
    paint(&r, box, .{ .variant = .chrome, .icon = .close, .icon_scale = 0.01 }, .{});
    try std.testing.expectEqual(@as(u32, 0), pixels[5 * 40 + 20]);
    paint(&r, box, .{ .variant = .chrome, .icon = .close, .icon_scale = 0.01 }, .{ .pointer = .hover });
    try std.testing.expectEqual(@as(u32, 217), pixels[5 * 40 + 20] >> 24);
    try std.testing.expect(pixels[2 * 40 + 2] >> 24 > 0);
    @memset(&pixels, 0);
    var t = theme.global;
    t.chrome_round_buttons = true;
    r.palette = t;
    paint(&r, box, .{ .variant = .chrome, .icon = .close, .icon_scale = 0.01 }, .{ .pointer = .hover });
    try std.testing.expectEqual(@as(u32, 0), pixels[2 * 40 + 2]);
    try std.testing.expectEqual(@as(u32, 217), pixels[5 * 40 + 20] >> 24);
}
