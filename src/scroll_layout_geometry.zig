//! Measuring columns and placing cells in layout coordinates.

const std = @import("std");
const Allocator = std.mem.Allocator;
const auto = @import("auto_layout.zig");
const Box = auto.Box;
const scroll_layout_mod = @import("scroll_layout.zig");
const Strip = scroll_layout_mod.Strip;
const Direction = scroll_layout_mod.Direction;
const Column = scroll_layout_mod.Column;
const Axes = scroll_layout_mod.Axes;

fn coverBox(strip: *const Strip, cover: auto.Cover) Box {
    return if (cover == .fullscreen) strip.fullscreen_box orelse strip.viewport else strip.viewport;
}

pub fn expelOverflow(strip: *Strip, allocator: Allocator) !void {
    const axes = Axes.of(strip.direction);
    var moved = false;
    var c: usize = 0;
    while (c < strip.columns.items.len) : (c += 1) {
        while (true) {
            const column = &strip.columns.items[c];
            if (column.stackCount() < 2) break;
            var needed: i32 = -strip.gap;
            var newest: ?usize = null;
            for (column.cells.items, 0..) |cell, i| if (cell.member.active and cell.member.cover == .none) {
                needed +|= axes.minCross(cell.member) +| strip.gap;
                if (newest == null or cell.member.order > column.cells.items[newest.?].member.order) newest = i;
            };
            if (needed <= strip.crossExtent()) break;
            const cell = column.cells.items[newest.?];
            var lone: Column = .{ .width = column.width };
            errdefer lone.deinit(allocator);
            try lone.cells.append(allocator, .{ .member = cell.member });
            try strip.columns.insert(allocator, c + 1, lone);
            _ = strip.columns.items[c].cells.orderedRemove(newest.?);
            moved = true;
        }
    }
    if (moved) strip.arrange(strip.viewport, @intCast(strip.gap), strip.direction);
}

/// Measures every column and places every member at the current view.
/// A new main length (another display or resolution, or a transposed
/// strip) scales the view with the columns, whose widths are fractions
/// of it, so the same stretch of the strip stays in view.
pub fn arrange(strip: *Strip, viewport: Box, requested_gap: u32, direction: Direction) void {
    const axes = Axes.of(direction);
    const old_span = strip.content + strip.gap;
    strip.viewport = viewport;
    strip.direction = direction;
    strip.gap = @intCast(@min(requested_gap, @as(u32, @intCast(@max(0, @divTrunc(@min(viewport.width, viewport.height) - 1, 2))))));
    strip.content = @max(0, axes.mainLen(viewport) - 2 * strip.gap);
    const span = strip.content + strip.gap;
    if (old_span > 0 and span > 0 and span != old_span) {
        const scaled = strip.view * @as(f64, @floatFromInt(span)) / @as(f64, @floatFromInt(old_span));
        // Unrounded, so going back restores the view; snap the float noise.
        strip.view = if (@abs(scaled - @round(scaled)) < 1e-6) @round(scaled) else scaled;
    }
    var pos: i32 = 0;
    var any = false;
    var trailing: i32 = 0;
    for (strip.columns.items) |*column| {
        column.start = pos;
        column.size = 0;
        column.tile_size = 0;
        column.cover = .none;
        var widest: i32 = 0;
        for (column.cells.items) |cell| if (cell.member.active) {
            switch (cell.member.cover) {
                .none => widest = @max(widest, axes.minMain(cell.member)),
                .fullscreen => column.cover = .fullscreen,
                .maximized => if (column.cover == .none) {
                    column.cover = .maximized;
                },
            }
        };
        if (widest == 0 and column.cover == .none) continue;
        if (widest > 0) column.tile_size = @max(strip.widthPixels(column.width), widest);
        column.size = column.tile_size;
        var leading: i32 = 0;
        var extra_trailing: i32 = 0;
        if (column.cover != .none) {
            column.size = @max(strip.content, column.tile_size);
            const area = coverBox(strip, column.cover);
            // The cover paints through the outer gaps and, in fullscreen,
            // across the reserved panels. Keep that space between columns.
            leading = @max(0, axes.main(viewport) + strip.gap - axes.main(area));
            extra_trailing = @max(0, axes.main(area) + axes.mainLen(area) - axes.main(viewport) - strip.gap - column.size);
        }
        if (any) pos += strip.gap + trailing + leading;
        any = true;
        trailing = extra_trailing;
        column.start = pos;
        pos += column.size;
    }
    strip.extent = pos;
    strip.place();
}

/// Positions members from the measured columns and the current view.
pub fn place(strip: *Strip) void {
    const axes = Axes.of(strip.direction);
    const origin_main = axes.main(strip.viewport) + strip.gap - @as(i32, @intFromFloat(@round(strip.view)));
    const origin_cross = axes.cross(strip.viewport) + strip.gap;
    const across = strip.crossExtent();
    for (strip.columns.items) |*column| {
        const active = column.stackCount();
        var weights: f64 = 0;
        var remaining_min: i64 = 0;
        for (column.cells.items) |*cell| {
            cell.rect = null;
            if (!cell.member.active) continue;
            if (cell.member.cover == .none) {
                weights += cell.weight;
                remaining_min += axes.minCross(cell.member);
            } else {
                const area = coverBox(strip, cell.member.cover);
                const offset = column.start + origin_main - axes.main(strip.viewport) - strip.gap;
                cell.rect = axes.make(axes.main(area) + offset, axes.cross(area), axes.mainLen(area), axes.crossLen(area));
            }
        }
        if (active == 0) continue;
        const gaps: i32 = strip.gap * @as(i32, @intCast(active - 1));
        const available = @max(0, across - gaps);
        // `used` counts member sizes only; `offset` adds the gaps.
        var used: i32 = 0;
        var offset: i32 = 0;
        var seen: usize = 0;
        var used_weight: f64 = 0;
        for (column.cells.items) |*cell| {
            if (!cell.member.active or cell.member.cover != .none) continue;
            seen += 1;
            used_weight += cell.weight;
            // Cumulative rounding: the last member ends exactly at the edge.
            const end: i32 = if (seen == active) available else @intFromFloat(@round(@as(f64, @floatFromInt(available)) * used_weight / weights));
            const minimum = axes.minCross(cell.member);
            remaining_min -= minimum;
            // Leave enough room for later members' minimum sizes, even
            // when a keyboard resize gives this member most of the weight.
            const budget: i32 = @intCast(@max(0, available - used - remaining_min));
            const size = @max(minimum, @min(end - used, budget));
            used += size;
            var main_len = column.tile_size;
            var main_at = origin_main + column.start;
            const max_main = axes.maxMain(cell.member);
            if (max_main > 0 and max_main < main_len) {
                main_len = @max(axes.minMain(cell.member), max_main);
                main_at += @divTrunc(column.tile_size - main_len, 2);
            }
            var cross_len = size;
            var cross_at = origin_cross + offset;
            const max_cross = axes.maxCross(cell.member);
            if (max_cross > 0 and max_cross < cross_len) {
                cross_len = @max(axes.minCross(cell.member), max_cross);
                cross_at += @divTrunc(size - cross_len, 2);
            }
            cell.rect = axes.make(main_at, cross_at, main_len, cross_len);
            offset += size + strip.gap;
        }
    }
}
