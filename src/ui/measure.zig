// Pass 1 of the UI layout engine: bottom-up intrinsic sizing. See layout.zig
// for the tree model and arrange.zig for the top-down placement pass that
// follows this one.
const std = @import("std");

const layout = @import("layout.zig");
const Widget = layout.Widget;
const Direction = layout.Direction;
const SizeConstraint = layout.SizeConstraint;

const text_mod = @import("text.zig");
const theme = @import("theme.zig");
const field = @import("widgets/field.zig");
const button = @import("widgets/button.zig");
const checkbox = @import("widgets/checkbox.zig");
const toggle = @import("widgets/toggle.zig");

const text_input_min_width: f32 = 120;
const default_icon_size: f32 = 16;
const slider_natural_width: f32 = 120;
const slider_height: f32 = 12;
const swatch_size: f32 = 24;
const segmented_pad_x: f32 = 12;
const segmented_pad_y: f32 = 8;
const stepper_button_width: f32 = 28;
const stepper_value_width: f32 = 56;
const stepper_height: f32 = 28;

pub fn measure(widget: *Widget, available_width: f32, available_height: f32) void {
    measureAtScale(widget, available_width, available_height, 1);
}

/// Hinting changes glyph advances with raster scale. Return logical sizes
/// measured from the same runs the renderer will draw on this output.
pub fn measureAtScale(widget: *Widget, available_width: f32, available_height: f32, scale: f32) void {
    widget.measured_scale = scale;
    if (widget.children.len == 0) {
        measureLeaf(widget, available_width, available_height);
        return;
    }

    const resolved_width = resolveAxis(widget.width, available_width);
    const resolved_height = resolveAxis(widget.height, available_height);
    // A scroll container's viewport is normally handed down by its parent
    // (fixed/percent) rather than shrink-wrapped to its (possibly
    // overflowing) content — see the `is_scroll` branches below.
    const is_scroll = std.meta.activeTag(widget.kind) == .scroll_container;

    const pad = widget.padding;
    const inner_available_w = @max(0, (resolved_width orelse available_width) - pad.left - pad.right);
    const inner_available_h = @max(0, (resolved_height orelse available_height) - pad.top - pad.bottom);

    for (widget.children) |*child| measureAtScale(child, inner_available_w, inner_available_h, scale);

    if (is_scroll) {
        var total: f32 = 0;
        for (widget.children, 0..) |*child, i| {
            total += child.axisMeasured(widget.direction);
            if (i + 1 < widget.children.len) total += widget.gap;
        }
        widget.kind.scroll_container.content_size = @max(total, 0);
    }

    const main_dir = widget.direction;
    const cross_dir = Widget.crossOf(main_dir);

    const content_main = if (is_scroll)
        (if (main_dir == .row) available_width else available_height)
    else
        mainSum(widget, main_dir);
    const content_cross = if (is_scroll)
        (if (cross_dir == .row) available_width else available_height)
    else
        crossMax(widget, cross_dir);

    const main_pad = if (main_dir == .row) pad.left + pad.right else pad.top + pad.bottom;
    const cross_pad = if (cross_dir == .row) pad.left + pad.right else pad.top + pad.bottom;

    const resolved_main = if (main_dir == .row) resolved_width else resolved_height;
    const resolved_cross = if (cross_dir == .row) resolved_width else resolved_height;

    const main_min = if (main_dir == .row) widget.min_width else widget.min_height;
    const main_max = if (main_dir == .row) widget.max_width else widget.max_height;
    const cross_min = if (cross_dir == .row) widget.min_width else widget.min_height;
    const cross_max_c = if (cross_dir == .row) widget.max_width else widget.max_height;

    widget.setAxisMeasured(main_dir, finalize(resolved_main orelse (content_main + main_pad), main_min, main_max));
    widget.setAxisMeasured(cross_dir, finalize(resolved_cross orelse (content_cross + cross_pad), cross_min, cross_max_c));
}

fn mainSum(widget: *const Widget, dir: Direction) f32 {
    var sum: f32 = 0;
    for (widget.children, 0..) |*child, i| {
        sum += child.axisMeasured(dir);
        if (i + 1 < widget.children.len) sum += widget.gap;
    }
    return sum;
}

fn crossMax(widget: *const Widget, dir: Direction) f32 {
    var max_v: f32 = 0;
    for (widget.children) |*child| max_v = @max(max_v, child.axisMeasured(dir));
    return max_v;
}

fn resolveAxis(constraint: SizeConstraint, available: f32) ?f32 {
    return switch (constraint) {
        .fixed => |v| v,
        .percent => |p| p * available,
        .auto, .flex => null,
    };
}

fn finalize(value: f32, min: ?f32, max: ?f32) f32 {
    var v = value;
    if (min) |lo| v = @max(v, lo);
    if (max) |hi| v = @min(v, hi);
    return @max(v, 0);
}

fn measureLeaf(widget: *Widget, available_width: f32, available_height: f32) void {
    const natural = naturalSize(widget, widget.measured_scale);
    widget.computed_width = finalize(resolveAxis(widget.width, available_width) orelse natural.w, widget.min_width, widget.max_width);
    widget.computed_height = finalize(resolveAxis(widget.height, available_height) orelse natural.h, widget.min_height, widget.max_height);
}

const Natural = struct { w: f32, h: f32 };

fn naturalSize(widget: *const Widget, scale: f32) Natural {
    return switch (widget.kind) {
        .rect, .container, .row => .{ .w = 0, .h = 0 },
        .arrangement => .{ .w = @import("widgets/arrangement.zig").natural_width, .h = @import("widgets/arrangement.zig").natural_height },
        .battery => |spec| .{ .w = @import("widgets/battery.zig").width, .h = spec.height },
        .avatar => .{ .w = 38, .h = 38 },
        .text => |style| blk: {
            const natural = textNaturalAtScale(style.content, style.family, style.weight, style.font_size, scale);
            if (!style.pill) break :blk natural;
            break :blk .{ .w = natural.w + layout.pill_pad_x * 2, .h = natural.h + layout.pill_pad_y * 2 };
        },
        .icon => .{ .w = default_icon_size, .h = default_icon_size },
        .image => |data| .{
            .w = if (data.width > 0) @floatFromInt(data.width) else 38,
            .h = if (data.height > 0) @floatFromInt(data.height) else 38,
        },
        .button => |data| blk: {
            const opts = button.optionsOf(data);
            const font_size = button.metrics(opts.size, theme.global).font_size;
            const natural = button.naturalSize(opts, theme.global, textNaturalAtScale(data.label, .sans, 600, font_size, scale).w);
            break :blk .{ .w = natural.w, .h = natural.h };
        },
        .checkbox => |data| blk: {
            const label = textNaturalAtScale(data.label, .sans, 400, theme.global.font_size, scale);
            break :blk .{
                .w = checkbox.box_size + checkbox.gap + label.w + (if (data.icon != null) checkbox.box_size + checkbox.gap else @as(f32, 0)),
                .h = @max(checkbox.box_size, label.h),
            };
        },
        .text_input => |data| blk: {
            const sample = if (data.value.len > 0) data.value else data.placeholder;
            const font_size = field.metrics(data.field.size, theme.global).font_size;
            const natural = field.naturalSize(data.field, theme.global, textNaturalAtScale(sample, .sans, 400, font_size, scale).w);
            break :blk .{ .w = @max(text_input_min_width, natural.w), .h = natural.h };
        },
        .secret_input => |data| blk: {
            const font_size = field.metrics(data.field.size, theme.global).font_size;
            const natural = field.naturalSize(data.field, theme.global, textNaturalAtScale(data.placeholder, .sans, 400, font_size, scale).w);
            break :blk .{ .w = @max(text_input_min_width, natural.w), .h = natural.h };
        },
        .scroll_container => .{ .w = 0, .h = 0 },
        .toggle => .{ .w = toggle.width, .h = toggle.height },
        .slider => |data| .{ .w = slider_natural_width, .h = if (data.style == .settings) 24 else slider_height },
        .swatch => .{ .w = swatch_size, .h = swatch_size },
        .select => |data| blk: {
            var width = textNaturalAtScale(data.placeholder, .sans, 600, theme.global.font_size, scale).w;
            for (data.labels, 0..) |label, i| width = @max(width, textNaturalAtScale(label, .sans, 600, theme.global.font_size, scale).w + (if (i < data.icons.len) @as(f32, 24) else 0));
            break :blk .{ .w = @max(160, width + 52), .h = @max(38, theme.global.font_size * 1.2 + 20) };
        },
        .segmented => |data| blk: {
            var max_label_w: f32 = 0;
            for (data.labels) |label| {
                const measured = textNaturalAtScale(label, .sans, 600, theme.global.font_size, scale);
                max_label_w = @max(max_label_w, measured.w);
            }
            const label_h = textNaturalAtScale("Mg", .sans, 600, theme.global.font_size, scale).h;
            const count: f32 = @floatFromInt(data.labels.len);
            break :blk .{
                .w = (max_label_w + segmented_pad_x * 2) * count,
                .h = label_h + segmented_pad_y * 2,
            };
        },
        .stepper => .{ .w = stepper_button_width * 2 + stepper_value_width, .h = stepper_height },
    };
}

pub fn textNatural(content: []const u8, family: layout.TextFamily, weight: u32, font_size: f32) Natural {
    return textNaturalAtScale(content, family, weight, font_size, 1);
}

pub fn textNaturalAtScale(content: []const u8, family: layout.TextFamily, weight: u32, font_size: f32, scale: f32) Natural {
    const font = fontFor(family, weight);
    const w = text_mod.measureWidth(content, font, font_size, scale) catch 0;
    const h = text_mod.lineHeight(font, font_size, scale) catch font_size * 1.2;
    const pad: i32 = if (content.len > 0) 1 else 0;
    return .{ .w = @floatFromInt(w + pad), .h = h };
}

pub fn fontFor(family: layout.TextFamily, weight: u32) text_mod.Font {
    return switch (family) {
        .sans => if (weight >= 700) .manrope_heavy else if (weight >= 600) .manrope_bold else .manrope,
        .mono => if (weight >= 600) .mono_bold else .mono,
    };
}

test "fixed and percent short-circuit measure" {
    var kids = [_]Widget{.{ .kind = .container, .width = .{ .fixed = 40 }, .height = .{ .percent = 0.5 } }};
    var root = Widget{ .kind = .container, .children = &kids };
    root.linkParents();
    measure(&root.children[0], 200, 200);
    try std.testing.expectEqual(@as(f32, 40), root.children[0].computed_width);
    try std.testing.expectEqual(@as(f32, 100), root.children[0].computed_height);
}

test "row container shrink-wraps auto children with gap" {
    var kids = [_]Widget{
        .{ .kind = .container, .width = .{ .fixed = 10 }, .height = .{ .fixed = 20 } },
        .{ .kind = .container, .width = .{ .fixed = 30 }, .height = .{ .fixed = 5 } },
    };
    var root = Widget{ .kind = .container, .direction = .row, .gap = 8, .padding = layout.Edges.all(2), .children = &kids };
    root.linkParents();
    measure(&root, 1000, 1000);
    // 10 + 8(gap) + 30 + 2*2(padding) = 52
    try std.testing.expectEqual(@as(f32, 52), root.computed_width);
    // cross max(20,5) + 2*2 padding = 24
    try std.testing.expectEqual(@as(f32, 24), root.computed_height);
}

test "scroll container content_size sums children regardless of viewport" {
    var rows = [_]Widget{
        .{ .kind = .container, .width = .{ .fixed = 50 }, .height = .{ .fixed = 80 } },
        .{ .kind = .container, .width = .{ .fixed = 50 }, .height = .{ .fixed = 120 } },
    };
    var scroll = Widget{
        .kind = .{ .scroll_container = .{} },
        .direction = .column,
        .height = .{ .fixed = 100 },
        .width = .{ .fixed = 50 },
        .children = &rows,
    };
    scroll.linkParents();
    measure(&scroll, 200, 200);
    try std.testing.expectEqual(@as(f32, 200), scroll.kind.scroll_container.content_size);
    try std.testing.expectEqual(@as(f32, 100), scroll.computed_height);
}

test {
    _ = @import("measure_tests.zig");
}
