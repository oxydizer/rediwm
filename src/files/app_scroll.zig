//! Files scrolling: wheel glide, scrollbars, edge shadows and reveal.

const std = @import("std");
const App = @import("app.zig").App;
const scrollbar = @import("ui").widgets.scrollbar;
const anim = @import("ui").anim;
const c = @import("c.zig").api;
const shell_ui = @import("ui").cairo;
const ui_theme = @import("ui").theme;
const properties = @import("properties.zig");
const nowMs = @import("app_draw.zig").nowMs;

pub fn maxHorizontalScroll(self: *App) f64 {
    if (self.transfer_view.active or !self.list_view) return 0;
    var total: f64 = 0;
    for (self.listWidths()) |width| total += width;
    const overflow = total - @as(f64, @floatFromInt(self.cellWidth() - 20));
    return if (overflow > 0.001) overflow else 0;
}

pub fn horizontalOffset(self: *App) f64 {
    return std.math.clamp(self.scroll_x, 0, self.maxHorizontalScroll());
}

pub fn contentBottom(self: *App) i32 {
    return self.h - self.footerHeight() - self.terminalHeight() - (if (self.maxHorizontalScroll() > 0) self.scrollbarGutter() else @as(i32, 0));
}

pub fn horizontalScrollbar(self: *App) ?scrollbar.Geometry {
    if (self.maxHorizontalScroll() <= 0) return null;
    const viewport: f32 = @floatFromInt(self.w - self.sidebarWidth() - self.scrollbarGutter());
    const track: scrollbar.Rect = .{ .x = @floatFromInt(self.sidebarWidth()), .y = @floatFromInt(self.contentBottom()), .w = viewport, .h = @floatFromInt(self.scrollbarGutter()) };
    return scrollbar.Geometry.compute(.horizontal, track, viewport, viewport + @as(f32, @floatCast(self.maxHorizontalScroll())), @floatCast(self.horizontalOffset()));
}

/// The file view's bar, along the window's right edge below the header.
pub fn scrollbarGeometry(self: *App) ?scrollbar.Geometry {
    const viewport: f32 = @floatFromInt(@max(0, self.contentBottom() - self.viewTop()));
    const gutter: f32 = @floatFromInt(self.scrollbarGutter());
    const track: scrollbar.Rect = .{ .x = @as(f32, @floatFromInt(self.w)) - gutter, .y = @floatFromInt(self.viewTop()), .w = gutter, .h = viewport };
    return scrollbar.Geometry.compute(.vertical, track, viewport, @floatFromInt(self.contentHeight()), @floatFromInt(self.scroll_y));
}

pub fn clampScroll(self: *App) void {
    self.scroll_x = self.horizontalOffset();
    const max_scroll = self.maxScroll();
    self.scroll_y = std.math.clamp(self.scroll_y, 0, max_scroll);
}

pub fn maxScroll(self: *App) i32 {
    const total_h = self.contentHeight();
    const viewport_h = self.contentBottom() - self.viewTop();
    return @max(0, total_h - viewport_h);
}

pub fn revealIndex(self: *App, idx: usize) void {
    const row = @divTrunc(@as(i32, @intCast(idx)), self.columns());
    const row_top = if (row == 0) 0 else self.itemInset() + row * self.rowHeight();
    const row_bottom = self.itemInset() + row * self.rowHeight() + self.cardHeight();
    const viewport_h = self.contentBottom() - self.viewTop();

    if (row_top < self.scroll_y) {
        self.scroll_y = row_top;
    } else if (row_bottom > self.scroll_y + viewport_h) {
        self.scroll_y = row_bottom - viewport_h;
    }
    self.clampScroll();
    self.invalidate();
}

pub fn cancelWheel(self: *App) void {
    self.wheel_glide.cancel(@floatFromInt(if (self.wheel_sidebar) self.sidebar_scroll else self.scroll_y));
}

pub fn wheelMax(self: *App) i32 {
    return if (self.wheel_sidebar) @max(0, self.sidebarExtent() - (self.h - self.sidebarFooter())) else self.maxScroll();
}

pub fn handleWheel(self: *App, delta_px: f64, now: i64) void {
    if (@import("app_audio_playlist.zig").wheel(self, delta_px)) return;
    if (delta_px != 0 and self.terminalWheel(delta_px)) return;
    if (self.shift and self.dialog == null and self.mouse_x >= @as(f64, @floatFromInt(self.sidebarWidth()))) {
        self.handleHorizontalScroll(delta_px);
        return;
    }
    if (self.dialog) |*dlg| {
        if (dlg.properties) |*props| {
            props.wheel(delta_px, self.w, self.h);
            self.invalidate();
        }
        if (dlg.applications) |*apps| {
            apps.wheel(delta_px, self.w, self.h);
            self.invalidate();
        }
        return;
    }
    if (delta_px == 0) return;
    self.menu = null;
    const sidebar = self.mouse_x < @as(f64, @floatFromInt(self.sidebarWidth())) and self.mouse_y >= @as(f64, @floatFromInt(self.contentTop()));
    if (sidebar != self.wheel_sidebar) self.cancelWheel();
    self.wheel_sidebar = sidebar;
    if (!self.wheel_glide.active()) self.cancelWheel();
    const current = self.wheel_glide.value(now);
    const step: f32 = @floatCast(delta_px);
    if ((self.wheel_glide.to - current) * step < 0) self.wheel_glide.cancel(current);
    const target = std.math.clamp(self.wheel_glide.to + step, 0, @as(f32, @floatFromInt(self.wheelMax())));
    self.wheel_glide.retargetTo(now, target, anim.curveFor(.wheel_scroll));
    if (self.wheel_glide.settled(now)) {
        if (sidebar) self.sidebar_scroll = @intFromFloat(@round(target)) else self.scroll_y = @intFromFloat(@round(target));
        self.wheel_glide.cancel(target);
        self.invalidate();
    } else self.stepWheel(now);
}

pub fn stepWheel(self: *App, now: i64) void {
    if (!self.wheel_glide.active()) return;
    const value = std.math.clamp(self.wheel_glide.value(now), 0, @as(f32, @floatFromInt(self.wheelMax())));
    const offset = if (self.wheel_sidebar) &self.sidebar_scroll else &self.scroll_y;
    const next: i32 = @intFromFloat(@round(value));
    if (offset.* != next) {
        offset.* = next;
        self.invalidate();
    }
    if (self.wheel_glide.settled(now)) self.wheel_glide.cancel(value);
}

pub fn handleScroll(self: *App, delta_px: f64) void {
    if (delta_px != 0 and self.terminalWheel(delta_px)) return;
    if (self.shift and self.dialog == null and self.mouse_x >= @as(f64, @floatFromInt(self.sidebarWidth()))) {
        self.handleHorizontalScroll(delta_px);
        return;
    }
    if (self.dialog != null) {
        self.handleWheel(delta_px, nowMs());
        return;
    }
    self.cancelWheel();
    self.menu = null;
    const step: i32 = @intFromFloat(delta_px);
    if (self.mouse_x < @as(f64, @floatFromInt(self.sidebarWidth())) and self.mouse_y >= @as(f64, @floatFromInt(self.contentTop()))) {
        const max_sidebar = @max(0, self.sidebarExtent() - (self.h - self.sidebarFooter()));
        const next = std.math.clamp(self.sidebar_scroll + step, 0, max_sidebar);
        if (next != self.sidebar_scroll) self.invalidate();
        self.sidebar_scroll = next;
        return;
    }
    self.scroll_y = std.math.clamp(self.scroll_y + step, 0, self.maxScroll());
    self.invalidate();
}

pub fn handleHorizontalScroll(self: *App, delta_px: f64) void {
    if (self.terminalHeight() > 0 and self.terminalRect().contains(self.mouse_x, self.mouse_y)) return;
    if (delta_px == 0 or self.dialog != null or self.mouse_x < @as(f64, @floatFromInt(self.sidebarWidth()))) return;
    self.cancelWheel();
    self.menu = null;
    const next = std.math.clamp(self.horizontalOffset() + delta_px, 0, self.maxHorizontalScroll());
    if (next == self.scroll_x) return;
    self.scroll_x = next;
    self.invalidate();
}

pub fn stepScrollbar(self: *App, now: i64) void {
    const bar = self.scrollbarGeometry();
    const idle = self.menu == null and self.dialog == null;
    const hovered = if (bar) |b| idle and b.overThumb(@floatCast(self.mouse_x), @floatCast(self.mouse_y)) else false;
    if (self.scroll_appearance.step(now, self.scroll_y != self.scroll_observed, hovered, self.scroll_drag.active, bar != null)) {
        const viewport: f64 = @floatFromInt(@max(0, self.contentBottom() - self.viewTop()));
        self.addDamage(.{ .x = @floatFromInt(self.w - self.scrollbarGutter()), .y = @floatFromInt(self.viewTop()), .w = @floatFromInt(self.scrollbarGutter()), .h = viewport });
    }
    self.scroll_observed = self.scroll_y;
    const side = self.sidebarScrollbar();
    const side_hovered = if (side) |b| idle and b.overThumb(@floatCast(self.mouse_x), @floatCast(self.mouse_y)) else false;
    if (self.sidebar_scroll_appearance.step(now, self.sidebar_scroll != self.sidebar_scroll_observed, side_hovered, self.sidebar_scroll_drag.active, side != null)) {
        if (side) |b| self.addDamage(.{ .x = b.track.x, .y = b.track.y, .w = b.track.w, .h = b.track.h });
    }
    self.sidebar_scroll_observed = self.sidebar_scroll;
    const horizontal = self.horizontalScrollbar();
    const horizontal_hovered = if (horizontal) |b| idle and b.overThumb(@floatCast(self.mouse_x), @floatCast(self.mouse_y)) else false;
    const offset = self.horizontalOffset();
    if (self.horizontal_appearance.step(now, offset != self.horizontal_observed, horizontal_hovered, self.horizontal_drag.active, horizontal != null)) {
        if (horizontal) |b| self.addDamage(.{ .x = b.track.x, .y = b.track.y, .w = b.track.w, .h = b.track.h });
    }
    self.horizontal_observed = offset;
}

pub fn renderScrollEdges(self: *App, cr: *c.cairo_t, viewport_h: i32) void {
    if (viewport_h <= 0 or self.maxScroll() == 0) return;
    const depth: f64 = @min(12, @as(f64, @floatFromInt(viewport_h)) / 2);
    for ([_]bool{ true, false }) |top| {
        if (if (top) self.scroll_y <= 0 else self.scroll_y >= self.maxScroll()) continue;
        const edge: f64 = @floatFromInt(if (top) self.viewTop() else self.contentBottom());
        const inner = edge + if (top) depth else -depth;
        const gradient = c.cairo_pattern_create_linear(0, edge, 0, inner) orelse continue;
        defer c.cairo_pattern_destroy(gradient);
        c.cairo_pattern_add_color_stop_rgba(gradient, 0, 0, 0, 0, 0.16);
        c.cairo_pattern_add_color_stop_rgba(gradient, 1, 0, 0, 0, 0);
        c.cairo_set_source(cr, gradient);
        c.cairo_rectangle(cr, @floatFromInt(self.sidebarWidth()), @min(edge, inner), @floatFromInt(@max(0, self.w - self.sidebarWidth() - self.scrollbarGutter())), depth);
        c.cairo_fill(cr);
    }
}

pub fn renderScrollbar(self: *App, cr: *c.cairo_t) void {
    if (self.horizontalScrollbar()) |bar| {
        shell_ui.drawScrollbar(cr, scrollbar.look(bar, self.horizontal_appearance, self.scrollbar_width, ui_theme.shellPalette()));
    }
    const bar = self.scrollbarGeometry() orelse return;
    shell_ui.drawScrollbar(cr, scrollbar.look(bar, self.scroll_appearance, self.scrollbar_width, ui_theme.shellPalette()));
}
