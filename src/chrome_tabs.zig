//! Geometry and retained-pixel painting for the chrome's compact taskbar chips.
const std = @import("std");
const theme = @import("ui").theme;
const ui = @import("ui").paint;
const button = @import("ui").widgets.button;
const style = @import("taskbar/chip_style.zig");
const icon_service = @import("icon_service.zig");
const chrome = @import("chrome.zig");
const window_chrome = @import("ui").window_chrome;
const Rect = button.Rect;

pub const Tab = struct { id: u64, title: []const u8, active: bool, attention: bool };
pub const Strip = struct {
    tabs: []const Tab = &.{},
    first: usize = 0,
    hover: u64 = 0,
    notice: @import("window_tabs.zig").Notice = .none,
};
pub const Hit = union(enum) { none, tab: u64, close: u64, plus, previous, next };
pub fn key(target: Hit) u64 {
    return switch (target) {
        .none => 0,
        .tab => |id| id * 4,
        .close => |id| id * 4 + 1,
        .plus => 1,
        .previous => 2,
        .next => 3,
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
    const height: f32 = @floatFromInt((chrome.Metrics{ .density = density }).titlebarHeight());
    const h = @max(18, height - 12 * density);
    const right = @as(f32, @floatFromInt(chrome.controlRectScaled(width, .minimize, density).x)) - 10 * density;
    var left: f32 = 8 * density;
    const plus_size = @min(26 * density, h);
    const available = @max(0, right - left - plus_size - 8);
    if (available < 50 * density) return .{ .x = left, .y = (height - h) / 2, .height = h, .width = 0, .first = 0, .count = 0, .plus = .{ .x = left, .y = (height - plus_size) / 2, .w = @max(0, @min(plus_size, right - left)), .h = plus_size }, .previous = null, .next = null };
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
    return .{ .x = left, .y = y, .height = h, .width = tab_width, .first = first, .count = count, .previous = previous, .next = if (overflow) .{ .x = end, .y = y, .w = arrow_size, .h = h } else null, .plus = .{ .x = end + arrow_size, .y = (height - plus_size) / 2, .w = plus_size, .h = plus_size } };
}
fn contains(r: Rect, x: f64, y: f64) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}
pub fn hit(width: i32, density: f32, strip: Strip, x: f64, y: f64) Hit {
    if (strip.tabs.len == 0) return .none;
    const g = geometry(width, density, strip);
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

pub fn paint(comptime C: type, pixels: []u32, width: i32, height: i32, logical_width: i32, density: f32, scale: f32, strip: Strip, icon: ?icon_service.Entry, clip: ?chrome.Rect) void {
    if (strip.tabs.len == 0) return;
    const g = geometry(logical_width, density, strip);
    var renderer = ui.Renderer.init(pixels, width, height, scale);
    if (clip) |c| renderer.damage_clip = .{ .x = @floatFromInt(c.x), .y = @floatFromInt(c.y), .w = @floatFromInt(c.w), .h = @floatFromInt(c.h) };
    const clip_left: usize = if (clip) |c| @intFromFloat(@max(0, @round(@as(f32, @floatFromInt(c.x)) * scale))) else 0;
    const clip_right: usize = if (clip) |c| @intFromFloat(@max(0, @round(@as(f32, @floatFromInt(c.x + c.w)) * scale))) else @intCast(width);
    for (strip.tabs[g.first..][0..g.count], 0..) |t, i| {
        const rect = g.tab(i);
        const radius = window_chrome.cornerRadius(theme.global.chrome_round_buttons, rect.w, rect.h, theme.global.radius * density * 0.8);
        const look = style.look(C, t.active, t.attention, if (strip.hover == key(.{ .tab = t.id })) 1 else 0, 0);
        const x0: usize = @max(clip_left, @as(usize, @intFromFloat(@max(0, @floor(rect.x * scale)))));
        const x1: usize = @min(clip_right, @as(usize, @intFromFloat(@min(@as(f32, @floatFromInt(width)), @ceil((rect.x + rect.w) * scale)))));
        const y0: usize = @intFromFloat(@max(0, @floor(rect.y * scale)));
        const y1: usize = @intFromFloat(@min(@as(f32, @floatFromInt(height)), @ceil((rect.y + rect.h) * scale)));
        if (x1 > x0 and y1 > y0) for (y0..y1) |y| for (x0..x1) |x| {
            const index = y * @as(usize, @intCast(width)) + x;
            const c = style.pixel(C, (@as(f32, @floatFromInt(x)) + 0.5) / scale, (@as(f32, @floatFromInt(y)) + 0.5) / scale, rect.x, rect.y, rect.w, rect.h, radius, scale, look.fill, look.border);
            pixels[index] = c.over(C.fromPremultiplied(pixels[index])).argb();
        };
        const size = @min(20 * density, rect.h - 6);
        var left = rect.x + 6 * density;
        if (icon) |image| {
            renderer.drawImageCover(left, rect.y + (rect.h - size) / 2, size, size, 0, .{ .pixels = image.pixels, .width = image.size, .height = image.size });
        } else renderer.drawIcon(left, rect.y + (rect.h - size) / 2, size, size, .{ .id = .generic, .color = theme.global.window_fg });
        left += size + 6 * density;
        const close = g.close(i);
        renderer.drawText(left, rect.y, @max(0, close.x - left - 3), rect.h, .{
            .content = if (t.active and strip.notice != .none) (if (strip.notice == .opening) "Opening…" else "No new window; retry +") else t.title,
            .font_size = theme.global.taskbar_title_size * density,
            .color = theme.global.window_fg,
        });
        button.paint(&renderer, close, .{ .variant = .chrome, .size = .sm, .icon = .close, .icon_scale = 0.39, .label = "Close tab" }, .{ .pointer = if (strip.hover == key(.{ .close = t.id })) .hover else .idle });
    }
    button.paint(&renderer, g.plus, .{ .variant = .ghost, .size = .sm, .icon = .plus, .label = "New tab", .radius = navigationRadius(g.plus) }, .{ .pointer = if (strip.notice == .opening) .disabled else if (strip.hover == key(.plus)) .hover else .idle });
    if (g.previous) |r| button.paint(&renderer, r, .{ .variant = .ghost, .size = .sm, .icon = .chevron_left, .radius = navigationRadius(r) }, .{ .pointer = if (strip.hover == key(.previous)) .hover else .idle });
    if (g.next) |r| button.paint(&renderer, r, .{ .variant = .ghost, .size = .sm, .icon = .chevron_right, .radius = navigationRadius(r) }, .{ .pointer = if (strip.hover == key(.next)) .hover else .idle });
}

fn navigationRadius(rect: Rect) f32 {
    return window_chrome.cornerRadius(theme.global.chrome_round_buttons, rect.w, rect.h, theme.global.radius);
}
