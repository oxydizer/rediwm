// Pass 2 of the UI layout engine: top-down placement. Runs after
// measure.zig has filled in every widget's intrinsic (auto/flex-as-auto)
// size; this pass is authoritative for the final `computed_*` rect,
// including resolving `.flex` (which measure.zig treats as `.auto`).
const std = @import("std");

const layout = @import("layout.zig");
const Widget = layout.Widget;
const Direction = layout.Direction;
const Align = layout.Align;

const measure = @import("measure.zig").measure;

pub fn arrange(widget: *Widget, origin_x: f32, origin_y: f32, given_width: f32, given_height: f32) void {
    widget.computed_x = origin_x + widget.margin.left;
    widget.computed_y = origin_y + widget.margin.top;
    widget.computed_width = clamp(@max(0, given_width - widget.margin.left - widget.margin.right), widget.min_width, widget.max_width);
    widget.computed_height = clamp(@max(0, given_height - widget.margin.top - widget.margin.bottom), widget.min_height, widget.max_height);

    if (widget.children.len == 0) return;

    const pad = widget.padding;
    const inner_x = widget.computed_x + pad.left;
    const inner_y = widget.computed_y + pad.top;
    const inner_w = @max(0, widget.computed_width - pad.left - pad.right);
    const inner_h = @max(0, widget.computed_height - pad.top - pad.bottom);

    if (std.meta.activeTag(widget.kind) == .scroll_container) {
        arrangeScrollChildren(widget, inner_x, inner_y, inner_w, inner_h);
    } else {
        arrangeFlexChildren(widget, inner_x, inner_y, inner_w, inner_h);
    }
}

/// Re-run placement from the widget's current computed rect. Scroll
/// mutations use this so children move with `scroll_offset` without a
/// full tree measure.
pub fn rearrange(widget: *Widget) void {
    arrange(
        widget,
        widget.computed_x - widget.margin.left,
        widget.computed_y - widget.margin.top,
        widget.computed_width + widget.margin.left + widget.margin.right,
        widget.computed_height + widget.margin.top + widget.margin.bottom,
    );
}

fn clamp(value: f32, min: ?f32, max: ?f32) f32 {
    var v = value;
    if (min) |lo| v = @max(v, lo);
    if (max) |hi| v = @min(v, hi);
    return v;
}

fn mainContribution(child: *const Widget, dir: Direction, main_size: f32) f32 {
    return switch (child.axisConstraint(dir)) {
        .fixed => |v| v,
        .percent => |p| p * main_size,
        .auto => child.axisMeasured(dir),
        .flex => 0,
    };
}

fn flexWeight(child: *const Widget, dir: Direction) f32 {
    return switch (child.axisConstraint(dir)) {
        .flex => |w| w,
        else => 0,
    };
}

fn finalMainSize(child: *const Widget, dir: Direction, main_size: f32, flex_unit: f32) f32 {
    return switch (child.axisConstraint(dir)) {
        .fixed => |v| v,
        .percent => |p| p * main_size,
        .auto => child.axisMeasured(dir),
        .flex => |w| w * flex_unit,
    };
}

fn crossSize(child: *const Widget, dir: Direction, align_mode: Align, cross_size: f32) f32 {
    const cross_dir = Widget.crossOf(dir);
    const constraint = child.axisConstraint(cross_dir);
    return switch (constraint) {
        .fixed => |v| v,
        .percent => |p| p * cross_size,
        .auto, .flex => if (align_mode == .stretch) cross_size else child.axisMeasured(cross_dir),
    };
}

fn crossOffset(align_mode: Align, cross_size: f32, child_cross: f32) f32 {
    return switch (align_mode) {
        .start, .stretch => 0,
        .center => (cross_size - child_cross) / 2,
        .end => cross_size - child_cross,
    };
}

fn place(child: *Widget, dir: Direction, inner_x: f32, inner_y: f32, pen: f32, cross_off: f32, main: f32, cross: f32) void {
    const x = if (dir == .row) inner_x + pen else inner_x + cross_off;
    const y = if (dir == .row) inner_y + cross_off else inner_y + pen;
    const w = if (dir == .row) main else cross;
    const h = if (dir == .row) cross else main;
    arrange(child, x, y, w, h);
}

fn arrangeFlexChildren(widget: *Widget, inner_x: f32, inner_y: f32, inner_w: f32, inner_h: f32) void {
    const dir = widget.direction;
    const n = widget.children.len;
    if (n == 0) return;
    const main_size = if (dir == .row) inner_w else inner_h;
    const cross_size = if (dir == .row) inner_h else inner_w;

    var fixed_main_total: f32 = 0;
    var flex_total: f32 = 0;
    for (widget.children) |*child| {
        fixed_main_total += mainContribution(child, dir, main_size);
        flex_total += flexWeight(child, dir);
    }

    const gap_total = widget.gap * @as(f32, @floatFromInt(if (n > 1) n - 1 else 0));
    const remaining_after_fixed = @max(0, main_size - fixed_main_total - gap_total);
    const flex_unit = if (flex_total > 0) remaining_after_fixed / flex_total else 0;

    var content_main: f32 = 0;
    for (widget.children) |*child| content_main += finalMainSize(child, dir, main_size, flex_unit);
    const remaining = @max(0, main_size - content_main);

    var pen: f32 = 0;
    var item_gap = widget.gap;
    switch (widget.justify) {
        .start => {},
        .center => pen = @max(0, remaining - gap_total) / 2,
        .end => pen = @max(0, remaining - gap_total),
        .space_between => item_gap = if (n > 1) remaining / @as(f32, @floatFromInt(n - 1)) else 0,
        .space_around => {
            item_gap = remaining / @as(f32, @floatFromInt(n));
            pen = item_gap / 2;
        },
    }

    for (widget.children, 0..) |*child, i| {
        const child_main = finalMainSize(child, dir, main_size, flex_unit);
        const child_cross = crossSize(child, dir, widget.@"align", cross_size);
        const cross_off = crossOffset(widget.@"align", cross_size, child_cross);
        place(child, dir, inner_x, inner_y, pen, cross_off, child_main, child_cross);
        pen += child_main;
        if (i + 1 < n) pen += item_gap;
    }
}

// A scroll container's content is not distributed to fill the viewport —
// children keep the size measure.zig gave them (their own fixed/percent/auto
// resolution) and are simply packed back-to-back along `direction`, shifted
// by `-scroll_offset`. paint.zig clips the overflow.
fn arrangeScrollChildren(widget: *Widget, inner_x: f32, inner_y: f32, inner_w: f32, inner_h: f32) void {
    const dir = widget.direction;
    const main_visible = if (dir == .row) inner_w else inner_h;
    const cross_size = if (dir == .row) inner_h else inner_w;

    const state = &widget.kind.scroll_container;
    state.scroll_offset = std.math.clamp(state.scroll_offset, 0, @max(0, state.content_size - main_visible));

    var pen: f32 = -state.scroll_offset;
    for (widget.children) |*child| {
        const child_main = child.axisMeasured(dir);
        const child_cross = crossSize(child, dir, widget.@"align", cross_size);
        const cross_off = crossOffset(widget.@"align", cross_size, child_cross);
        place(child, dir, inner_x, inner_y, pen, cross_off, child_main, child_cross);
        pen += child_main + widget.gap;
    }
}

test "row flex distributes remaining space by weight" {
    var kids = [_]Widget{
        .{ .kind = .container, .width = .{ .fixed = 40 } },
        .{ .kind = .container, .width = .{ .flex = 1 } },
        .{ .kind = .container, .width = .{ .flex = 3 } },
    };
    var root = Widget{ .kind = .container, .direction = .row, .gap = 10, .children = &kids };
    root.linkParents();
    measure(&root, 400, 100);
    arrange(&root, 0, 0, 400, 100);

    // main_size 400, minus fixed 40, minus 2 gaps of 10 = 340 for flex, split 1:3.
    try std.testing.expectEqual(@as(f32, 0), root.children[0].computed_x);
    try std.testing.expectEqual(@as(f32, 40), root.children[0].computed_width);
    try std.testing.expectEqual(@as(f32, 50), root.children[1].computed_x);
    try std.testing.expectApproxEqAbs(@as(f32, 85), root.children[1].computed_width, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 145), root.children[2].computed_x, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 255), root.children[2].computed_width, 1e-3);
}

test "justify space_between and align center" {
    var kids = [_]Widget{
        .{ .kind = .container, .width = .{ .fixed = 20 }, .height = .{ .fixed = 10 } },
        .{ .kind = .container, .width = .{ .fixed = 20 }, .height = .{ .fixed = 10 } },
        .{ .kind = .container, .width = .{ .fixed = 20 }, .height = .{ .fixed = 10 } },
    };
    var root = Widget{
        .kind = .container,
        .direction = .row,
        .justify = .space_between,
        .@"align" = .center,
        .children = &kids,
    };
    root.linkParents();
    measure(&root, 100, 40);
    arrange(&root, 0, 0, 100, 40);

    // 3 items of 20 = 60 content, 40 remaining split into 2 gaps of 20.
    try std.testing.expectEqual(@as(f32, 0), root.children[0].computed_x);
    try std.testing.expectEqual(@as(f32, 40), root.children[1].computed_x);
    try std.testing.expectEqual(@as(f32, 80), root.children[2].computed_x);
    // Centered on a 40px cross axis with a 10px child: (40-10)/2 = 15.
    try std.testing.expectEqual(@as(f32, 15), root.children[0].computed_y);
}

test "scroll container packs children and clamps scroll_offset" {
    var rows = [_]Widget{
        .{ .kind = .container, .width = .{ .fixed = 50 }, .height = .{ .fixed = 80 } },
        .{ .kind = .container, .width = .{ .fixed = 50 }, .height = .{ .fixed = 120 } },
    };
    var scroll = Widget{
        .kind = .{ .scroll_container = .{ .scroll_offset = 1000 } },
        .direction = .column,
        .height = .{ .fixed = 100 },
        .width = .{ .fixed = 50 },
        .children = &rows,
    };
    scroll.linkParents();
    measure(&scroll, 200, 200);
    // A root call is seeded with the widget's own already-resolved size
    // (what a real caller does with `root.computed_width/height` after
    // `measure`) — `arrange` itself never re-resolves `width`/`height`,
    // only its children's, which is why this isn't just (0, 0, 200, 200).
    arrange(&scroll, 0, 0, scroll.computed_width, scroll.computed_height);

    // content_size 200, visible 100 -> max scroll 100, clamped down from 1000.
    try std.testing.expectEqual(@as(f32, 100), scroll.kind.scroll_container.scroll_offset);
    try std.testing.expectEqual(@as(f32, -100), scroll.children[0].computed_y);
    try std.testing.expectEqual(@as(f32, -20), scroll.children[1].computed_y);
}

test "acceptance: taskbar-shaped tree lays out correctly and dumps" {
    // row, gap 8, a mix of fixed and flex widths — the shape called out by
    // the layout engine's acceptance criteria.
    var kids = [_]Widget{
        .{ .kind = .{ .rect = .{ .color = .{ 0, 0, 0, 1 } } }, .width = .{ .fixed = 42 }, .height = .{ .fixed = 42 } },
        .{ .kind = .container, .width = .{ .flex = 1 } },
        .{ .kind = .{ .rect = .{ .color = .{ 0, 0, 0, 1 } } }, .width = .{ .fixed = 120 }, .height = .{ .fixed = 42 } },
    };
    var root = Widget{
        .kind = .container,
        .direction = .row,
        .gap = 8,
        .@"align" = .stretch,
        .width = .{ .fixed = 800 },
        .height = .{ .fixed = 64 },
        .children = &kids,
    };
    root.linkParents();
    measure(&root, 800, 64);
    arrange(&root, 0, 0, root.computed_width, root.computed_height);

    try std.testing.expectEqual(@as(f32, 800), root.computed_width);
    try std.testing.expectEqual(@as(f32, 64), root.computed_height);
    try std.testing.expectEqual(@as(f32, 0), root.children[0].computed_x);
    try std.testing.expectEqual(@as(f32, 42), root.children[0].computed_width);
    try std.testing.expectEqual(@as(f32, 50), root.children[1].computed_x);
    // 800 - 42 - 120 - 2 gaps(8) = 622 for the single flex child.
    try std.testing.expectApproxEqAbs(@as(f32, 622), root.children[1].computed_width, 1e-3);
    // align: stretch fills the 64px cross axis even for the fixed-height siblings' gap.
    try std.testing.expectEqual(@as(f32, 64), root.children[1].computed_height);
    try std.testing.expectApproxEqAbs(@as(f32, 680), root.children[2].computed_x, 1e-3);
    try std.testing.expectEqual(@as(f32, 120), root.children[2].computed_width);

    const dumped = try root.dump(std.testing.allocator);
    defer std.testing.allocator.free(dumped);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "container [0,0 800x64]") != null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "rect [0,0 42x42]") != null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "container [50,0 622x64]") != null);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "rect [680,0 120x42]") != null);
}
