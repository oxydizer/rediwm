//! Geometry and retained-pixel painting for the chrome's compact taskbar chips.
const i18n = @import("i18n");
const std = @import("std");
const theme = @import("ui").theme;
const ui = @import("ui").paint;
const button = @import("ui").widgets.button;
const style = @import("taskbar/chip_style.zig");
const icon_service = @import("icon_service.zig");
const chrome = @import("chrome.zig");
const window_chrome = @import("ui").window_chrome;
const Rect = button.Rect;

const title_tabs = @import("ui").widgets.title_tabs;
// The model, geometry, hit testing and hashing live in the shared toolkit
// (`ui/widgets/title_tabs.zig`); this file keeps the compositor's painter.
pub const Tab = title_tabs.Tab;
pub const Strip = title_tabs.Strip;
pub const Hit = title_tabs.Hit;
pub const key = title_tabs.key;
pub const Geometry = title_tabs.Geometry;
pub const geometry = title_tabs.geometry;
pub const hit = title_tabs.hit;
pub const hash = title_tabs.hash;
pub const layoutHash = title_tabs.layoutHash;

pub fn paint(comptime C: type, pixels: []u32, width: i32, height: i32, logical_width: i32, density: f32, scale: f32, strip: Strip, icon: ?icon_service.Entry, clip: ?chrome.Rect) void {
    if (strip.tabs.len == 0) return;
    const g = geometry(logical_width, density, strip);
    const band: f32 = @floatFromInt((window_chrome.Metrics{ .density = density }).titlebarHeight());
    var renderer = ui.Renderer.init(pixels, width, height, scale);
    if (clip) |c| renderer.damage_clip = .{ .x = @floatFromInt(c.x), .y = @floatFromInt(c.y), .w = @floatFromInt(c.w), .h = @floatFromInt(c.h) };
    const clip_left: usize = if (clip) |c| @intFromFloat(@max(0, @round(@as(f32, @floatFromInt(c.x)) * scale))) else 0;
    const clip_right: usize = if (clip) |c| @intFromFloat(@max(0, @round(@as(f32, @floatFromInt(c.x + c.w)) * scale))) else @intCast(width);
    // The tab being dragged is painted last, over its neighbours.
    for ([_]bool{ false, true }) |dragged_pass| for (strip.tabs[g.first..][0..g.count], 0..) |t, i| {
        if ((strip.drag.dragging() and t.id == strip.drag.id) != dragged_pass) continue;
        const rect = strip.drag.rect(g, i);
        const radius = window_chrome.cornerRadius(theme.global.chrome_round_buttons, rect.w, rect.h, theme.global.radius * density * 0.8);
        // The selected tab is the window's content colour, grown down into the
        // content with an accent line, so it reads as the open page; the others
        // are bare text that lights up under the pointer.
        const hovered = strip.hover == key(.{ .tab = t.id });
        const clear: C = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const fill: C = if (t.active) C.fromRgba(theme.global.app_bg) else if (hovered) C.fromRgba(theme.global.taskbar_hover).scaled(2.0) else clear;
        const border: C = if (t.attention) C.fromRgba(theme.global.danger).scaled(2.5) else fill;
        var shape = rect;
        if (t.active) shape.h = band - rect.y + radius;
        const x0: usize = @max(clip_left, @as(usize, @intFromFloat(@max(0, @floor(rect.x * scale)))));
        const x1: usize = @min(clip_right, @as(usize, @intFromFloat(@min(@as(f32, @floatFromInt(width)), @ceil((rect.x + rect.w) * scale)))));
        const y0: usize = @intFromFloat(@max(0, @floor(rect.y * scale)));
        const y1: usize = @intFromFloat(@min(@as(f32, @floatFromInt(height)), @ceil(@min(shape.y + shape.h, band) * scale)));
        if (x1 > x0 and y1 > y0) for (y0..y1) |y| for (x0..x1) |x| {
            const index = y * @as(usize, @intCast(width)) + x;
            const c = style.pixel(C, (@as(f32, @floatFromInt(x)) + 0.5) / scale, (@as(f32, @floatFromInt(y)) + 0.5) / scale, shape.x, shape.y, shape.w, shape.h, radius, scale, fill, border);
            pixels[index] = c.over(C.fromPremultiplied(pixels[index])).argb();
        };
        if (t.active) {
            const accent = C.fromRgba(theme.shellPalette().accent);
            const ux0: usize = @max(clip_left, @as(usize, @intFromFloat(@max(0, @floor((rect.x + 8 * density) * scale)))));
            const ux1: usize = @min(clip_right, @as(usize, @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(width)), @ceil((rect.x + rect.w - 8 * density) * scale))))));
            const uy1: usize = @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(height)), @floor(band * scale))));
            const uy0: usize = uy1 -| @as(usize, @intFromFloat(@max(1, @round(2 * scale))));
            if (ux1 > ux0) for (uy0..uy1) |y| for (ux0..ux1) |x| {
                const index = y * @as(usize, @intCast(width)) + x;
                pixels[index] = accent.over(C.fromPremultiplied(pixels[index])).argb();
            };
        }
        const size = @min(20 * density, rect.h - 6);
        var left = rect.x + 6 * density;
        if (icon) |image| {
            renderer.drawImageCover(left, rect.y + (rect.h - size) / 2, size, size, 0, .{ .pixels = image.pixels, .width = image.size, .height = image.size });
        } else renderer.drawIcon(left, rect.y + (rect.h - size) / 2, size, size, .{ .id = .generic, .color = theme.global.window_fg });
        left += size + 6 * density;
        var close = g.close(i);
        close.x += rect.x - g.tab(i).x;
        renderer.drawText(left, rect.y, @max(0, close.x - left - 3), rect.h, .{
            .content = if (t.active and strip.notice != .none) (if (strip.notice == .opening) "Opening…" else "No new window; retry +") else t.title,
            .font_size = theme.global.taskbar_title_size * density,
            .color = if (t.active) theme.global.window_fg else theme.global.window_dim,
        });
        button.paint(&renderer, close, .{ .variant = .chrome, .size = .sm, .icon = .close, .icon_scale = 0.39, .label = i18n.tr("Close tab") }, .{ .pointer = if (strip.hover == key(.{ .close = t.id })) .hover else .idle });
    };
    if (g.leading) |r| {
        button.paint(&renderer, r, .{ .variant = .ghost, .size = .sm, .radius = navigationRadius(r) }, .{ .pointer = if (strip.hover == key(.leading)) .hover else .idle });
        const side = @min(20 * density, r.h - 6);
        if (icon) |image| {
            renderer.drawImageCover(r.x + (r.w - side) / 2, r.y + (r.h - side) / 2, side, side, 0, .{ .pixels = image.pixels, .width = image.size, .height = image.size });
        } else renderer.drawIcon(r.x + (r.w - side) / 2, r.y + (r.h - side) / 2, side, side, .{ .id = .generic, .color = theme.global.window_fg });
    }
    button.paint(&renderer, g.plus, .{ .variant = .ghost, .size = .sm, .icon = .plus, .label = i18n.tr("New tab"), .radius = navigationRadius(g.plus) }, .{ .pointer = if (strip.notice == .opening) .disabled else if (strip.hover == key(.plus)) .hover else .idle });
    if (g.previous) |r| button.paint(&renderer, r, .{ .variant = .ghost, .size = .sm, .icon = .chevron_left, .radius = navigationRadius(r) }, .{ .pointer = if (strip.hover == key(.previous)) .hover else .idle });
    if (g.next) |r| button.paint(&renderer, r, .{ .variant = .ghost, .size = .sm, .icon = .chevron_right, .radius = navigationRadius(r) }, .{ .pointer = if (strip.hover == key(.next)) .hover else .idle });
}

fn navigationRadius(rect: Rect) f32 {
    return window_chrome.cornerRadius(theme.global.chrome_round_buttons, rect.w, rect.h, theme.global.radius);
}
