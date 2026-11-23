//! The titlebar tab strip: model, geometry, hit testing, the damage hash and
//! the drag-reorder arithmetic. No painting and no compositor imports: the
//! compositor paints the strip into its retained chrome (`chrome_tabs.zig`),
//! and a self-decorated app can paint the same geometry through Cairo.
//! Tab ids are non-zero: `Strip.hover` and `Drag.id` use 0 for "none".
const std = @import("std");
const theme = @import("../theme.zig");
const window_chrome = @import("../window_chrome.zig");
const button = @import("button.zig");
const Rect = button.Rect;

/// What the strip says about a "+" that is still being served.
pub const Notice = enum { none, opening, failed };

pub const Tab = struct { id: u64, title: []const u8, active: bool, attention: bool };
pub const Strip = struct {
    tabs: []const Tab = &.{},
    first: usize = 0,
    hover: u64 = 0,
    notice: Notice = .none,
    /// A button before the first tab: the application's icon, opening its menu.
    leading: bool = false,
    /// A reorder in progress; the painter follows it (`Drag.rect`).
    drag: Drag = .{},
};
pub const Hit = union(enum) { none, tab: u64, close: u64, plus, previous, next, leading };
pub fn key(target: Hit) u64 {
    return switch (target) {
        .none => 0,
        .tab => |id| id * 4,
        .close => |id| id * 4 + 1,
        .plus => 1,
        .previous => 2,
        .next => 3,
        // Tabs are id * 4 and their close buttons id * 4 + 1.
        .leading => 6,
    };
}
pub const Geometry = struct {
    x: f32,
    y: f32,
    height: f32,
    width: f32,
    first: usize,
    count: usize,
    plus: Rect,
    previous: ?Rect,
    next: ?Rect,
    leading: ?Rect = null,
    pub fn tab(g: Geometry, i: usize) Rect {
        return .{ .x = g.x + @as(f32, @floatFromInt(i)) * (g.width + 4), .y = g.y, .w = g.width, .h = g.height };
    }
    pub fn close(g: Geometry, i: usize) Rect {
        const r = g.tab(i);
        const size = @min(22, g.height - 4);
        return .{ .x = r.x + r.w - size - 3, .y = r.y + (r.h - size) / 2, .w = size, .h = size };
    }
};

pub fn geometry(width: i32, density: f32, strip: Strip) Geometry {
    const height: f32 = @floatFromInt((window_chrome.Metrics{ .density = density }).titlebarHeight());
    const h = @max(18, height - 12 * density);
    const right = @as(f32, @floatFromInt(window_chrome.controlRectScaled(width, .minimize, density).x)) - 10 * density;
    var left: f32 = 8 * density;
    const leading: ?Rect = if (strip.leading) .{ .x = left, .y = (height - h) / 2, .w = h, .h = h } else null;
    if (leading != null) left += h + 4 * density;
    const plus_size = @min(26 * density, h);
    const available = @max(0, right - left - plus_size - 8);
    if (available < 50 * density) return .{ .x = left, .y = (height - h) / 2, .height = h, .width = 0, .first = 0, .count = 0, .plus = .{ .x = left, .y = (height - plus_size) / 2, .w = @max(0, @min(plus_size, right - left)), .h = plus_size }, .previous = null, .next = null, .leading = leading };
    const overflow = @as(f32, @floatFromInt(strip.tabs.len)) * (85 * density + 4) > available;
    const arrow_size = if (overflow) @min(22 * density, h) else 0;
    const space = @max(1, available - 2 * arrow_size);
    const count = @min(strip.tabs.len, @max(1, @as(usize, @intFromFloat(@floor(space / @max(1, 85 * density + 4))))));
    const first = @min(strip.first, strip.tabs.len -| count);
    const tab_width = @max(1, @min(170 * density, space / @as(f32, @floatFromInt(@max(1, count))) - 4));
    const y = (height - h) / 2;
    const previous: ?Rect = if (overflow) .{ .x = left, .y = y, .w = arrow_size, .h = h } else null;
    left += arrow_size;
    const end = left + @as(f32, @floatFromInt(count)) * (tab_width + 4);
    return .{ .x = left, .y = y, .height = h, .width = tab_width, .first = first, .count = count, .previous = previous, .next = if (overflow) .{ .x = end, .y = y, .w = arrow_size, .h = h } else null, .plus = .{ .x = end + arrow_size, .y = (height - plus_size) / 2, .w = plus_size, .h = plus_size }, .leading = leading };
}
fn contains(r: Rect, x: f64, y: f64) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}
pub fn hit(width: i32, density: f32, strip: Strip, x: f64, y: f64) Hit {
    if (strip.tabs.len == 0) return .none;
    const g = geometry(width, density, strip);
    if (g.leading) |r| if (contains(r, x, y)) return .leading;
    if (contains(g.plus, x, y)) return .plus;
    if (g.previous) |r| if (contains(r, x, y)) return .previous;
    if (g.next) |r| if (contains(r, x, y)) return .next;
    for (strip.tabs[g.first..][0..g.count], 0..) |t, i| {
        if (contains(g.close(i), x, y)) return .{ .close = t.id };
        if (contains(g.tab(i), x, y)) return .{ .tab = t.id };
    }
    return .none;
}

pub fn hash(strip: Strip) u64 {
    return hashImpl(strip, true);
}
pub fn layoutHash(strip: Strip) u64 {
    return hashImpl(strip, false);
}
fn hashImpl(strip: Strip, include_titles: bool) u64 {
    if (strip.tabs.len == 0) return 0;
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&strip.first));
    h.update(std.mem.asBytes(&strip.hover));
    h.update(std.mem.asBytes(&strip.notice));
    h.update(std.mem.asBytes(&strip.leading));
    // Only a drag that has begun changes what is painted.
    const dragging = strip.drag.dragging();
    h.update(std.mem.asBytes(&dragging));
    if (dragging) {
        h.update(std.mem.asBytes(&strip.drag.id));
        h.update(std.mem.asBytes(&strip.drag.x));
    }
    for (strip.tabs) |t| {
        h.update(std.mem.asBytes(&t.id));
        if (include_titles) h.update(t.title);
        h.update(std.mem.asBytes(&t.active));
        h.update(std.mem.asBytes(&t.attention));
    }
    // The shared painter's palette is independent of the chrome palette.
    inline for (.{ "taskbar_surface", "taskbar_hover", "taskbar_border", "surface_hover", "danger", "window_fg", "radius", "taskbar_title_size", "chrome_round_buttons" }) |field| h.update(std.mem.asBytes(&@field(theme.global, field)));
    return h.final();
}

/// A press on a tab that may become a reorder. The owner feeds it the pointer
/// (`press`, `motion`, `release`) and paints each visible tab at `rect`, so the
/// dragged tab follows the pointer and its neighbours step aside. Nothing is
/// reordered until `release` returns the final index; the owner then moves the
/// tab (a window group, or an app told over the protocol).
pub const Drag = struct {
    /// Pointer travel, in logical pixels, before a press becomes a drag.
    pub const threshold: f32 = 4;
    pub const Move = struct { id: u64, index: usize };

    /// The pressed tab; 0 while idle.
    id: u64 = 0,
    /// Its index among all tabs when pressed.
    from: usize = 0,
    press_x: f32 = 0,
    /// Pointer x minus the tab's left edge at the press.
    grab: f32 = 0,
    x: f32 = 0,
    moved: bool = false,

    pub fn pressed(d: Drag) bool {
        return d.id != 0;
    }
    /// True once the pointer has travelled past the threshold.
    pub fn dragging(d: Drag) bool {
        return d.id != 0 and d.moved;
    }

    /// Starts tracking a press on tab `id`, which must be one of the visible
    /// tabs of `g`; returns false and tracks nothing otherwise.
    pub fn press(d: *Drag, strip: Strip, g: Geometry, id: u64, x: f32) bool {
        d.* = .{};
        for (strip.tabs[g.first..][0..g.count], 0..) |t, i| {
            if (t.id != id) continue;
            d.* = .{ .id = id, .from = g.first + i, .press_x = x, .grab = x - g.tab(i).x, .x = x };
            return true;
        }
        return false;
    }

    /// Follows the pointer; true when the preview changed and needs a repaint.
    pub fn motion(d: *Drag, x: f32, density: f32) bool {
        if (d.id == 0) return false;
        d.x = x;
        if (!d.moved) {
            if (@abs(x - d.press_x) < threshold * density) return false;
            d.moved = true;
        }
        return true;
    }

    /// The index, among all tabs, where the dragged tab would land now.
    pub fn target(d: Drag, g: Geometry) usize {
        if (g.count == 0) return d.from;
        const pitch = g.width + 4;
        const centre = d.x - d.grab + g.width / 2;
        const slot = @floor((centre - g.x) / pitch);
        const last: f32 = @floatFromInt(g.count - 1);
        return g.first + @as(usize, @intFromFloat(std.math.clamp(slot, 0, last)));
    }

    /// Where to paint visible tab `i` (an index into the visible tabs): the
    /// dragged tab under the pointer, the tabs it passes one step aside.
    pub fn rect(d: Drag, g: Geometry, i: usize) Rect {
        var r = g.tab(i);
        if (!d.dragging() or g.count == 0) return r;
        const pitch = g.width + 4;
        const index = g.first + i;
        const to = d.target(g);
        if (index == d.from) {
            const last: f32 = @floatFromInt(g.count - 1);
            r.x = std.math.clamp(d.x - d.grab, g.x, g.x + last * pitch);
        } else if (d.from < to and index > d.from and index <= to) {
            r.x -= pitch;
        } else if (to < d.from and index >= to and index < d.from) {
            r.x += pitch;
        }
        return r;
    }

    /// Ends the press. The move to make, or null for a click, a drag that
    /// ended where it began, or no press at all.
    pub fn release(d: *Drag, g: Geometry) ?Move {
        defer d.* = .{};
        if (d.id == 0 or !d.moved) return null;
        const to = d.target(g);
        if (to == d.from) return null;
        return .{ .id = d.id, .index = to };
    }

    pub fn cancel(d: *Drag) void {
        d.* = .{};
    }
};

test {
    _ = @import("title_tabs_tests.zig");
}
