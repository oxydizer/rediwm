//! Scrolling strip geometry, independent of compositor objects and focus order.
//! A strip is an ordered list of columns on an endless main axis; a column
//! stacks one or more members across it. Positions are worked out along the
//! main and cross axes, which `Direction` maps to x and y: a horizontal strip
//! has columns side by side, a vertical one full-width rows stacked down.
//! Widths are fractions of the viewport, so they survive a new resolution,
//! display or direction. `view` is the strip coordinate at the viewport's
//! leading edge; a member's rectangle is `viewport + strip position - view`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const auto = @import("auto_layout.zig");
pub const Box = auto.Box;
pub const Key = auto.Key;
pub const Member = auto.Member;

pub const Direction = enum { horizontal, vertical };
/// When focus scrolls a column into view (niri's names).
pub const Center = enum { never, on_overflow, always };
/// Along the strip (columns) or across it (within a column).
pub const Step = enum { previous_column, next_column, previous_member, next_member };
pub const Side = enum { before, after };

/// Where a dragged member lands: a column of its own beside the column
/// holding `anchor` (an empty strip has none), or into that column beside it.
pub const Drop = union(enum) {
    column: struct { anchor: ?Key = null, side: Side = .after },
    join: struct { anchor: Key, side: Side },
};

/// A view a gesture settles on, and the column that view shows.
pub const Snap = struct { view: f64, column: usize };

pub const Options = struct {
    direction: Direction = .horizontal,
    /// A new column's width.
    width: f64 = 0.5,
};

pub const min_fraction = 0.05;
const min_weight = 0.05;
const max_weight = 20;

pub const Cell = struct {
    member: Member,
    /// Its share of the column's cross extent, against its neighbours.
    weight: f64 = 1,
    rect: ?Box = null,
};

pub const Column = struct {
    /// Fraction of the viewport's main extent.
    width: f64,
    cells: std.ArrayList(Cell) = .empty,
    /// Strip coordinate of its leading edge and its size, from `arrange`; a
    /// column without an active member takes no room.
    start: i32 = 0,
    size: i32 = 0,
    /// Added in the current `sync`; later arrivals queue behind it.
    fresh: bool = false,

    fn deinit(column: *Column, allocator: Allocator) void {
        column.cells.deinit(allocator);
    }
    fn find(column: *const Column, key: Key) ?usize {
        for (column.cells.items, 0..) |cell, index| if (std.meta.eql(cell.member.key, key)) return index;
        return null;
    }
    pub fn activeCount(column: *const Column) usize {
        var n: usize = 0;
        for (column.cells.items) |cell| n += @intFromBool(cell.member.active);
        return n;
    }
};

const Axes = struct {
    horizontal: bool,

    fn of(direction: Direction) Axes {
        return .{ .horizontal = direction == .horizontal };
    }
    fn main(axes: Axes, box: Box) i32 {
        return if (axes.horizontal) box.x else box.y;
    }
    fn cross(axes: Axes, box: Box) i32 {
        return if (axes.horizontal) box.y else box.x;
    }
    fn mainLen(axes: Axes, box: Box) i32 {
        return if (axes.horizontal) box.width else box.height;
    }
    fn crossLen(axes: Axes, box: Box) i32 {
        return if (axes.horizontal) box.height else box.width;
    }
    fn make(axes: Axes, main_pos: i32, cross_pos: i32, main_len: i32, cross_len: i32) Box {
        return if (axes.horizontal)
            .{ .x = main_pos, .y = cross_pos, .width = main_len, .height = cross_len }
        else
            .{ .x = cross_pos, .y = main_pos, .width = cross_len, .height = main_len };
    }
    fn minMain(axes: Axes, m: Member) i32 {
        return @max(1, if (axes.horizontal) m.min_width else m.min_height);
    }
    fn minCross(axes: Axes, m: Member) i32 {
        return @max(1, if (axes.horizontal) m.min_height else m.min_width);
    }
    fn maxMain(axes: Axes, m: Member) i32 {
        return if (axes.horizontal) m.max_width else m.max_height;
    }
    fn maxCross(axes: Axes, m: Member) i32 {
        return if (axes.horizontal) m.max_height else m.max_width;
    }
};

pub const Strip = struct {
    columns: std.ArrayList(Column) = .empty,
    view: f64 = 0,
    /// From the last `arrange`: the viewport, the gap, the content extent
    /// between the outer gaps, and the strip's own length.
    viewport: Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    direction: Direction = .horizontal,
    gap: i32 = 0,
    content: i32 = 0,
    extent: i32 = 0,

    pub fn deinit(strip: *Strip, allocator: Allocator) void {
        for (strip.columns.items) |*column| column.deinit(allocator);
        strip.columns.deinit(allocator);
        strip.* = .{};
    }

    pub fn clone(strip: *const Strip, allocator: Allocator) Allocator.Error!Strip {
        var copy: Strip = strip.*;
        copy.columns = .empty;
        errdefer copy.deinit(allocator);
        try copy.columns.ensureTotalCapacity(allocator, strip.columns.items.len);
        for (strip.columns.items) |column| {
            var cells = try column.cells.clone(allocator);
            errdefer cells.deinit(allocator);
            var duplicate = column;
            duplicate.cells = cells;
            copy.columns.appendAssumeCapacity(duplicate);
        }
        return copy;
    }

    /// Compares placement: keys, widths and weights. The view is navigation,
    /// and geometry and client limits are live state.
    pub fn eql(strip: *const Strip, other: *const Strip) bool {
        if (strip.columns.items.len != other.columns.items.len) return false;
        for (strip.columns.items, other.columns.items) |a, b| {
            if (a.width != b.width or a.cells.items.len != b.cells.items.len) return false;
            for (a.cells.items, b.cells.items) |x, y| {
                if (!std.meta.eql(x.member.key, y.member.key) or x.weight != y.weight) return false;
            }
        }
        return true;
    }

    pub const Location = struct { column: usize, cell: usize };

    pub fn locate(strip: *const Strip, key: Key) ?Location {
        for (strip.columns.items, 0..) |*column, index| {
            if (column.find(key)) |cell| return .{ .column = index, .cell = cell };
        }
        return null;
    }

    pub fn contains(strip: *const Strip, key: Key) bool {
        return strip.locate(key) != null;
    }

    pub fn isEmpty(strip: *const Strip) bool {
        return strip.columns.items.len == 0;
    }

    /// Layout rectangle from the last arrange; null while suspended.
    pub fn rectangle(strip: *const Strip, key: Key) ?Box {
        const at = strip.locate(key) orelse return null;
        return strip.columns.items[at.column].cells.items[at.cell].rect;
    }

    pub fn getMember(strip: *const Strip, key: Key) ?Member {
        const at = strip.locate(key) orelse return null;
        return strip.columns.items[at.column].cells.items[at.cell].member;
    }

    pub fn rename(strip: *Strip, old: Key, new: Key) void {
        if (strip.contains(new)) return;
        const at = strip.locate(old) orelse return;
        strip.columns.items[at.column].cells.items[at.cell].member.key = new;
    }

    /// A column of its own for `member`, beside column `index` (or at an end).
    pub fn insertColumn(strip: *Strip, allocator: Allocator, member: Member, index: usize, width: f64) !void {
        if (strip.contains(member.key)) return;
        var column: Column = .{ .width = clampFraction(width) };
        try column.cells.append(allocator, .{ .member = member });
        errdefer column.deinit(allocator);
        try strip.columns.insert(allocator, @min(index, strip.columns.items.len), column);
    }

    pub fn remove(strip: *Strip, allocator: Allocator, key: Key) void {
        const at = strip.locate(key) orelse return;
        const column = &strip.columns.items[at.column];
        _ = column.cells.orderedRemove(at.cell);
        if (column.cells.items.len == 0) {
            column.deinit(allocator);
            _ = strip.columns.orderedRemove(at.column);
        }
    }

    /// Membership follows `members`, in admission order: missing keys leave,
    /// known ones take fresh limits, and new ones open a column after their
    /// anchor's (or at the end). A column whose members no longer fit across
    /// it sends the newest into a column of its own. Then `arrange`.
    pub fn sync(strip: *Strip, allocator: Allocator, members: []const Member, viewport: Box, requested_gap: u32, options: Options) !void {
        var c = strip.columns.items.len;
        while (c > 0) {
            c -= 1;
            const column = &strip.columns.items[c];
            var i = column.cells.items.len;
            while (i > 0) {
                i -= 1;
                const key = column.cells.items[i].member.key;
                const live = for (members) |m| {
                    if (std.meta.eql(m.key, key)) break m;
                } else null;
                if (live) |m| column.cells.items[i].member = m else _ = column.cells.orderedRemove(i);
            }
            if (column.cells.items.len == 0) {
                column.deinit(allocator);
                _ = strip.columns.orderedRemove(c);
            }
        }
        defer for (strip.columns.items) |*column| {
            column.fresh = false;
        };
        for (members) |member| {
            if (strip.contains(member.key)) continue;
            var index = strip.columns.items.len;
            if (member.anchor) |anchor| if (strip.locate(anchor)) |at| {
                index = at.column + 1;
                while (index < strip.columns.items.len and strip.columns.items[index].fresh) index += 1;
            };
            try strip.insertColumn(allocator, member, index, options.width);
            strip.columns.items[index].fresh = true;
        }
        strip.arrange(viewport, requested_gap, options.direction);
        try strip.expelOverflow(allocator);
    }

    fn expelOverflow(strip: *Strip, allocator: Allocator) !void {
        const axes = Axes.of(strip.direction);
        var moved = false;
        var c: usize = 0;
        while (c < strip.columns.items.len) : (c += 1) {
            while (true) {
                const column = &strip.columns.items[c];
                if (column.activeCount() < 2) break;
                var needed: i32 = -strip.gap;
                var newest: ?usize = null;
                for (column.cells.items, 0..) |cell, i| if (cell.member.active) {
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

    fn crossExtent(strip: *const Strip) i32 {
        return @max(0, Axes.of(strip.direction).crossLen(strip.viewport) - 2 * strip.gap);
    }

    /// A column's main size for `fraction`: n columns of 1/n fill the content.
    pub fn widthPixels(strip: *const Strip, fraction: f64) i32 {
        const span: f64 = @floatFromInt(strip.content + strip.gap);
        return @max(1, @as(i32, @intFromFloat(@round(fraction * span))) - strip.gap);
    }

    fn fractionFor(strip: *const Strip, pixels: i32) f64 {
        const span: f64 = @floatFromInt(@max(1, strip.content + strip.gap));
        return clampFraction(@as(f64, @floatFromInt(pixels + strip.gap)) / span);
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
        for (strip.columns.items) |*column| {
            column.start = pos;
            column.size = 0;
            var widest: i32 = 0;
            for (column.cells.items) |cell| if (cell.member.active) {
                widest = @max(widest, axes.minMain(cell.member));
            };
            if (widest == 0) continue;
            if (any) pos += strip.gap;
            any = true;
            column.start = pos;
            column.size = @max(strip.widthPixels(column.width), widest);
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
            const active = column.activeCount();
            var weights: f64 = 0;
            var remaining_min: i64 = 0;
            for (column.cells.items) |*cell| {
                cell.rect = null;
                if (cell.member.active) {
                    weights += cell.weight;
                    remaining_min += axes.minCross(cell.member);
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
                if (!cell.member.active) continue;
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
                var main_len = column.size;
                var main_at = origin_main + column.start;
                const max_main = axes.maxMain(cell.member);
                if (max_main > 0 and max_main < main_len) {
                    main_len = @max(axes.minMain(cell.member), max_main);
                    main_at += @divTrunc(column.size - main_len, 2);
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

    /// The view range: the leading edge, up to the end of the strip.
    pub fn maxView(strip: *const Strip) f64 {
        return @floatFromInt(@max(0, strip.extent - strip.content));
    }

    pub fn clampView(strip: *Strip) void {
        strip.view = std.math.clamp(strip.view, 0, strip.maxView());
    }

    /// The view that shows the column holding `key`, by `center`'s rule,
    /// within the view limits.
    pub fn revealView(strip: *const Strip, key: Key, center: Center) f64 {
        const at = strip.locate(key) orelse return strip.view;
        const column = strip.columns.items[at.column];
        if (column.size == 0) return strip.view;
        const start: f64 = @floatFromInt(column.start);
        const size: f64 = @floatFromInt(column.size);
        const content: f64 = @floatFromInt(strip.content);
        var view = strip.view;
        const centered = start + size / 2 - content / 2;
        switch (center) {
            .always => view = centered,
            .on_overflow, .never => {
                if (size > content) {
                    // A column wider than the view that already fills it
                    // stays where a gesture left it.
                    if (!strip.columnCovers(at.column, view)) view = if (center == .on_overflow) centered else start;
                } else if (start < view) {
                    view = start;
                } else if (start + size > view + content) {
                    view = start + size - content;
                }
            },
        }
        return std.math.clamp(view, 0, strip.maxView());
    }

    /// Moves the view to show `key` and places members there.
    pub fn reveal(strip: *Strip, key: Key, center: Center) void {
        strip.view = strip.revealView(key, center);
        strip.place();
    }

    /// The next member in strip order: the nearest active member of the next
    /// column with one (by cross position), or the next one in the column.
    pub fn neighbor(strip: *const Strip, key: Key, step: Step) ?Key {
        return strip.neighborWhere(key, step, {}, struct {
            fn none(_: void, _: Key) bool {
                return false;
            }
        }.none);
    }

    /// `neighbor`, also stopping at inactive members that `reachable`
    /// accepts: a maximized window takes no room but can take focus. A
    /// column's active members come first.
    pub fn neighborWhere(strip: *const Strip, key: Key, step: Step, context: anytype, comptime reachable: fn (@TypeOf(context), Key) bool) ?Key {
        const at = strip.locate(key) orelse return null;
        const columns = strip.columns.items;
        switch (step) {
            .previous_member, .next_member => {
                const cells = columns[at.column].cells.items;
                var i = at.cell;
                while (true) {
                    if (step == .previous_member) {
                        if (i == 0) return null;
                        i -= 1;
                    } else {
                        i += 1;
                        if (i >= cells.len) return null;
                    }
                    if (cells[i].member.active or reachable(context, cells[i].member.key)) return cells[i].member.key;
                }
            },
            .previous_column, .next_column => {
                const source = columns[at.column].cells.items[at.cell].rect;
                var c = at.column;
                while (true) {
                    if (step == .previous_column) {
                        if (c == 0) return null;
                        c -= 1;
                    } else {
                        c += 1;
                        if (c >= columns.len) return null;
                    }
                    if (strip.memberNear(c, source)) |found| return found;
                    for (columns[c].cells.items) |cell| if (reachable(context, cell.member.key)) return cell.member.key;
                }
            },
        }
    }

    /// The active member of column `c` nearest `source` across the strip,
    /// or its first one without a source.
    pub fn memberNear(strip: *const Strip, c: usize, source: ?Box) ?Key {
        const axes = Axes.of(strip.direction);
        var best: ?Key = null;
        var distance: u64 = std.math.maxInt(u64);
        for (strip.columns.items[c].cells.items) |cell| {
            if (!cell.member.active) continue;
            const rect = cell.rect orelse continue;
            const d: u64 = if (source) |s| @abs(crossCenter(axes, rect) - crossCenter(axes, s)) else 0;
            if (d < distance) {
                distance = d;
                best = cell.member.key;
            }
        }
        return best;
    }

    fn crossCenter(axes: Axes, rect: Box) i64 {
        return @as(i64, axes.cross(rect)) * 2 + axes.crossLen(rect);
    }

    /// Swaps the column holding `key` with the next one that takes room on
    /// `side`. False at the end of the strip.
    pub fn moveColumn(strip: *Strip, key: Key, side: Side) bool {
        const at = strip.locate(key) orelse return false;
        const other = strip.nextShown(at.column, side) orelse return false;
        std.mem.swap(Column, &strip.columns.items[at.column], &strip.columns.items[other]);
        return true;
    }

    /// Swaps a member with its neighbour in the column.
    pub fn moveInColumn(strip: *Strip, key: Key, side: Side) bool {
        const at = strip.locate(key) orelse return false;
        const cells = strip.columns.items[at.column].cells.items;
        var i = at.cell;
        while (true) {
            if (side == .before) {
                if (i == 0) return false;
                i -= 1;
            } else {
                i += 1;
                if (i >= cells.len) return false;
            }
            if (cells[i].member.active) break;
        }
        std.mem.swap(Cell, &cells[at.cell], &cells[i]);
        return true;
    }

    fn nextShown(strip: *const Strip, from: usize, side: Side) ?usize {
        var c = from;
        while (true) {
            if (side == .before) {
                if (c == 0) return null;
                c -= 1;
            } else {
                c += 1;
                if (c >= strip.columns.items.len) return null;
            }
            if (strip.columns.items[c].activeCount() > 0) return c;
        }
    }

    /// niri's consume-or-expel: a member alone in its column joins the next
    /// column on `side`; one sharing a column leaves it for a column of its
    /// own on that side. False when there is nothing to do.
    pub fn consume(strip: *Strip, allocator: Allocator, key: Key, side: Side) !bool {
        const at = strip.locate(key) orelse return false;
        const column = &strip.columns.items[at.column];
        if (column.cells.items.len > 1) {
            var lone: Column = .{ .width = column.width };
            errdefer lone.deinit(allocator);
            try lone.cells.append(allocator, column.cells.items[at.cell]);
            lone.cells.items[0].weight = 1;
            try strip.columns.insert(allocator, if (side == .before) at.column else at.column + 1, lone);
            const source = &strip.columns.items[if (side == .before) at.column + 1 else at.column];
            _ = source.cells.orderedRemove(at.cell);
            return true;
        }
        const target = strip.nextShown(at.column, side) orelse return false;
        var cell = column.cells.items[0];
        cell.weight = 1;
        try strip.columns.items[target].cells.append(allocator, cell);
        column.deinit(allocator);
        _ = strip.columns.orderedRemove(at.column);
        return true;
    }

    pub fn widthOf(strip: *const Strip, key: Key) ?f64 {
        const at = strip.locate(key) orelse return null;
        return strip.columns.items[at.column].width;
    }

    pub fn setWidth(strip: *Strip, key: Key, fraction: f64) void {
        if (!std.math.isFinite(fraction)) return;
        const at = strip.locate(key) orelse return;
        strip.columns.items[at.column].width = clampFraction(fraction);
    }

    /// A manual width: `pixels` wider (or narrower) than the column is drawn.
    pub fn stepWidth(strip: *Strip, key: Key, pixels: i32) void {
        const at = strip.locate(key) orelse return;
        const column = &strip.columns.items[at.column];
        const drawn = if (column.size > 0) column.size else strip.widthPixels(column.width);
        column.width = strip.fractionFor(drawn + pixels);
    }

    /// The next preset above the current width, wrapping to the first.
    pub fn cycleWidth(strip: *Strip, key: Key, presets: []const f64) void {
        if (presets.len == 0) return;
        const at = strip.locate(key) orelse return;
        const column = &strip.columns.items[at.column];
        var next = presets[0];
        var found = false;
        for (presets) |preset| if (preset > column.width + 1e-3 and (!found or preset < next)) {
            next = preset;
            found = true;
        };
        if (!found) {
            for (presets) |preset| next = @min(next, preset);
        }
        column.width = clampFraction(next);
    }

    /// Grows (or shrinks) a member across its column by about `pixels`; the
    /// others keep their proportions.
    pub fn stepWeight(strip: *Strip, key: Key, pixels: i32) void {
        const rect = strip.rectangle(key) orelse return;
        strip.setCrossSize(key, Axes.of(strip.direction).crossLen(rect) + pixels);
    }

    /// A member about `pixels` across its column; the others keep their
    /// proportions. A member alone in its column fills it.
    pub fn setCrossSize(strip: *Strip, key: Key, pixels: i32) void {
        const at = strip.locate(key) orelse return;
        const column = &strip.columns.items[at.column];
        const cell = &column.cells.items[at.cell];
        if (column.activeCount() < 2 or !cell.member.active) return;
        var total: f64 = 0;
        for (column.cells.items) |other| if (other.member.active) {
            total += other.weight;
        };
        const gaps: i32 = strip.gap * @as(i32, @intCast(column.activeCount() - 1));
        const available: f64 = @floatFromInt(@max(2, strip.crossExtent() - gaps));
        const size = std.math.clamp(@as(f64, @floatFromInt(pixels)), 1, available - 1);
        const rest = total - cell.weight;
        cell.weight = std.math.clamp(size * rest / (available - size), min_weight, max_weight);
    }

    /// A manual width: the column `pixels` long along the strip.
    pub fn setWidthPixels(strip: *Strip, key: Key, pixels: i32) void {
        const at = strip.locate(key) orelse return;
        strip.columns.items[at.column].width = strip.fractionFor(@max(1, pixels));
    }

    /// The drawn size along the strip of the column holding `key`.
    pub fn columnSize(strip: *const Strip, key: Key) ?i32 {
        const at = strip.locate(key) orelse return null;
        return strip.columns.items[at.column].size;
    }

    /// The members active in the column holding `key`.
    pub fn columnCount(strip: *const Strip, key: Key) usize {
        const at = strip.locate(key) orelse return 0;
        return strip.columns.items[at.column].activeCount();
    }

    pub fn setWeight(strip: *Strip, key: Key, weight: f64) void {
        if (!std.math.isFinite(weight)) return;
        const at = strip.locate(key) orelse return;
        strip.columns.items[at.column].cells.items[at.cell].weight = std.math.clamp(weight, min_weight, max_weight);
    }

    /// The strip overview's scale: the whole strip fits along the viewport,
    /// at most 0.9 so a short strip still reads as an overview.
    pub fn overviewScale(strip: *const Strip) f64 {
        if (strip.extent <= 0) return 0.9;
        return @min(0.9, @as(f64, @floatFromInt(strip.content)) / @as(f64, @floatFromInt(strip.extent)));
    }

    /// Where layout point (x, y), at the current view, lands in the strip
    /// overview: the strip scaled about its start and centred both ways.
    pub fn overviewPoint(strip: *const Strip, x: f64, y: f64) [2]f64 {
        const axes = Axes.of(strip.direction);
        const s = strip.overviewScale();
        const gap: f64 = @floatFromInt(strip.gap);
        const main0 = @as(f64, @floatFromInt(axes.main(strip.viewport))) + gap;
        const cross0 = @as(f64, @floatFromInt(axes.cross(strip.viewport))) + gap;
        const content: f64 = @floatFromInt(strip.content);
        const across: f64 = @floatFromInt(strip.crossExtent());
        const extent: f64 = @floatFromInt(strip.extent);
        const along = (if (axes.horizontal) x else y) - main0 + strip.view;
        const main = main0 + (content - extent * s) / 2 + along * s;
        const cross = cross0 + across * (1 - s) / 2 + ((if (axes.horizontal) y else x) - cross0) * s;
        return if (axes.horizontal) .{ main, cross } else .{ cross, main };
    }

    /// Whether all of column `index` shows when the view is at `view`.
    pub fn columnFits(strip: *const Strip, index: usize, view: f64) bool {
        const column = strip.columns.items[index];
        if (column.size == 0) return false;
        const start: f64 = @floatFromInt(column.start);
        const end = start + @as(f64, @floatFromInt(column.size));
        return start >= view - 0.5 and end <= view + @as(f64, @floatFromInt(strip.content)) + 0.5;
    }

    /// Whether column `index` shows as much of itself as it can at `view`:
    /// all of it, or, when wider than the viewport, across the whole viewport.
    pub fn columnCovers(strip: *const Strip, index: usize, view: f64) bool {
        if (strip.columnFits(index, view)) return true;
        const column = strip.columns.items[index];
        if (column.size <= strip.content) return false;
        const start: f64 = @floatFromInt(column.start);
        const end = start + @as(f64, @floatFromInt(column.size));
        return start <= view + 0.5 and end >= view + @as(f64, @floatFromInt(strip.content)) - 0.5;
    }

    /// The view a gesture settles on near `projected`: a column's leading
    /// or trailing edge at the viewport's, or, with `always` (and
    /// `on_overflow` for a column wider than the view), the centred column;
    /// within the view limits.
    pub fn snapView(strip: *const Strip, projected: f64, center: Center) ?Snap {
        const content: f64 = @floatFromInt(strip.content);
        const limit = strip.maxView();
        var best: ?Snap = null;
        var distance = std.math.inf(f64);
        for (strip.columns.items, 0..) |column, index| {
            if (column.size == 0) continue;
            const start: f64 = @floatFromInt(column.start);
            const size: f64 = @floatFromInt(column.size);
            const centered = start + size / 2 - content / 2;
            const edges = [2]f64{ start, start + size - content };
            const centres = [2]f64{ centered, centered };
            const candidates = if (center == .always or (center == .on_overflow and size > content)) centres else edges;
            for (candidates) |raw| {
                const view = std.math.clamp(raw, 0, limit);
                const d = @abs(view - projected);
                if (d < distance) {
                    distance = d;
                    best = .{ .view = view, .column = index };
                }
            }
        }
        return best;
    }

    /// Where `moving` lands when dropped at layout point (x, y): near a
    /// column's leading or trailing edge (or past either end of the strip),
    /// a column of its own there; over the middle, into that column before
    /// or after the member under the point. A column holding only `moving`
    /// counts as gone already. Null over `moving` itself.
    pub fn dropAt(strip: *const Strip, x: i32, y: i32, moving: ?Key) ?Drop {
        const axes = Axes.of(strip.direction);
        const p = if (axes.horizontal) x else y;
        const q = if (axes.horizontal) y else x;
        const origin = axes.main(strip.viewport) + strip.gap - @as(i32, @intFromFloat(@round(strip.view)));
        var last: ?Key = null;
        for (strip.columns.items) |column| {
            if (column.size == 0) continue;
            const anchor = for (column.cells.items) |cell| {
                if (cell.member.active and !(moving != null and std.meta.eql(cell.member.key, moving.?))) break cell.member.key;
            } else continue;
            const start = origin + column.start;
            const end = start + column.size;
            const zone = std.math.clamp(@divTrunc(column.size, 5), 24, 120);
            if (p < start + zone) return .{ .column = .{ .anchor = anchor, .side = .before } };
            if (p < end - zone) {
                var nearest: ?Cell = null;
                var distance: u64 = std.math.maxInt(u64);
                for (column.cells.items) |cell| {
                    if (!cell.member.active) continue;
                    const rect = cell.rect orelse continue;
                    const d = @abs(@as(i64, q) * 2 - crossCenter(axes, rect));
                    if (d < distance) {
                        distance = d;
                        nearest = cell;
                    }
                }
                const cell = nearest orelse return null;
                if (moving != null and std.meta.eql(cell.member.key, moving.?)) return null;
                const rect = cell.rect.?;
                const side: Side = if (@as(i64, q) * 2 < crossCenter(axes, rect)) .before else .after;
                return .{ .join = .{ .anchor = cell.member.key, .side = side } };
            }
            if (p < end) return .{ .column = .{ .anchor = anchor, .side = .after } };
            last = anchor;
        }
        return .{ .column = .{ .anchor = last, .side = .after } };
    }

    /// Places `member`, not in the strip, where `drop` says; a new column
    /// gets `width`. False when its anchor is gone.
    pub fn insertDrop(strip: *Strip, allocator: Allocator, member: Member, drop: Drop, width: f64) !bool {
        if (strip.contains(member.key)) return false;
        switch (drop) {
            .column => |d| {
                var index: usize = if (d.side == .after) strip.columns.items.len else 0;
                if (d.anchor) |anchor| {
                    const at = strip.locate(anchor) orelse return false;
                    index = if (d.side == .before) at.column else at.column + 1;
                }
                try strip.insertColumn(allocator, member, index, width);
            },
            .join => |d| {
                const at = strip.locate(d.anchor) orelse return false;
                const cells = &strip.columns.items[at.column].cells;
                try cells.insert(allocator, if (d.side == .before) at.cell else at.cell + 1, .{ .member = member });
            },
        }
        return true;
    }

    /// Arranges again in the same viewport, then moves members that no
    /// longer fit across their column into columns of their own.
    pub fn rearrange(strip: *Strip, allocator: Allocator) !void {
        strip.arrange(strip.viewport, @intCast(strip.gap), strip.direction);
        try strip.expelOverflow(allocator);
    }

    /// Whether any of the column holding `key` shows in the viewport.
    pub fn columnShown(strip: *const Strip, key: Key) bool {
        const at = strip.locate(key) orelse return false;
        const column = strip.columns.items[at.column];
        if (column.size == 0) return false;
        const start = @as(f64, @floatFromInt(column.start)) - strip.view;
        const content: f64 = @floatFromInt(strip.content);
        // The outer gaps belong to the viewport too.
        const gap: f64 = @floatFromInt(strip.gap);
        return start + @as(f64, @floatFromInt(column.size)) > -gap and start < content + gap;
    }
};

pub fn clampFraction(fraction: f64) f64 {
    if (!std.math.isFinite(fraction)) return 0.5;
    return std.math.clamp(fraction, min_fraction, 1);
}

test {
    _ = @import("scroll_layout_tests.zig");
}
