//! View geometry: resizing, the viewport and scrollbar, scrolling, caret rectangles and revealing the caret.

const std = @import("std");
const ui = @import("ui").cairo;
const theme = @import("ui").theme;
const scrollbar = @import("ui").widgets.scrollbar;
const p = @import("pango.zig");
const view = @import("view.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const top = app_mod.top;
const status_h = app_mod.status_h;
const far = app_mod.far;

pub fn resize(self: *App, w: i32, h: i32) void {
    self.w = w;
    self.h = h;
    self.menu_open = false;
    self.changed();
}

pub fn viewTop(self: *App) f64 {
    return top + if (self.find_open) @as(f64, if (self.replace_open) 80 else 40) else 0;
}

pub fn viewHeight(self: *App) f64 {
    return @max(1, @as(f64, @floatFromInt(self.h)) - self.viewTop() - status_h - 8);
}

pub fn cancelDrag(self: *App) void {
    self.dragging = false;
    self.drag_word = null;
    self.scroll_drag.end();
}

pub fn cursorName(self: *App) [*:0]const u8 {
    if (self.close_tab != null or self.menu_open) return "default";
    if (self.find_open) if (self.searchHit(self.px, self.py)) |control| {
        return if (control == .query or control == .replacement) "text" else "default";
    };
    return if (self.px >= 0 and self.py >= self.viewTop() and self.py < @as(f64, @floatFromInt(self.h)) - status_h and self.px < @as(f64, @floatFromInt(self.w)) - 16) "text" else "default";
}

/// The current tab's bar, along the right edge of the text view; null
/// while the document fits.
pub fn scrollbarGeometry(self: *App) ?scrollbar.Geometry {
    if (self.tabs.items.len == 0) return null;
    const strip = scrollbar.gutter(theme.global.scrollbar_width);
    const track: scrollbar.Rect = .{ .x = @as(f32, @floatFromInt(self.w)) - strip, .y = @floatCast(self.viewTop()), .w = strip, .h = @floatCast(self.viewHeight()) };
    const e = self.port().extent(&self.current().measure);
    return scrollbar.Geometry.compute(.vertical, track, @floatCast(e.viewport), @floatCast(e.content), @floatCast(e.offset));
}

/// The current tab's scroll offset in the scrollbar's units.
pub fn scrollOffset(self: *App) f32 {
    return @floatCast(self.port().extent(&self.current().measure).offset);
}

pub fn seekScroll(self: *App, offset: f32) void {
    self.port().seek(&self.current().measure, offset);
}

/// The current tab as something to scroll, lay out and hit-test.
pub fn port(self: *App) view.Port {
    const t = self.current();
    self.layouts.configure(theme.global.mono_font, ui.textSize(), if (self.wrap) self.w - 40 else null, self.scale);
    return .{ .doc = &t.doc, .layouts = &self.layouts, .height = self.viewHeight(), .dy = &t.dy };
}

/// Advances the scrollbar's hover and scroll feedback.
pub fn stepBar(self: *App, now: i64) void {
    if (self.tabs.items.len == 0) return;
    const tab = self.current();
    const bar = self.scrollbarGeometry();
    const position = @as(f64, @floatFromInt(tab.doc.top)) * 1024 + tab.dy;
    if (self.bar_tab != tab) {
        self.bar_tab = tab;
        self.bar_observed = position;
    }
    const hovered = !self.menu_open and self.close_tab == null and if (bar) |b| b.overThumb(@floatCast(self.px), @floatCast(self.py)) else false;
    if (self.bar_appearance.step(now, position != self.bar_observed, hovered, self.scroll_drag.active, bar != null)) self.dirty = true;
    self.bar_observed = position;
}

/// How long the event loop may sleep before the scrollbar needs a frame.
pub fn barTimeout(self: *const App, now: i64) ?u32 {
    if (self.bar_appearance.active) return 16;
    if (self.bar_appearance.deadline) |deadline| return @intCast(std.math.clamp(deadline - now, 0, 60_000));
    return null;
}

pub fn handleScroll(self: *App, amount: f64) void {
    if (self.close_tab != null or self.menu_open) return;
    if (self.py >= 0 and self.py < top) {
        self.scrollTabs(amount * 3);
    } else if (self.shift and !self.wrap) {
        self.current().scroll_x = @max(0, self.current().scroll_x + amount * 3);
    } else {
        self.port().scrollBy(amount * 3);
    }
    self.dirty = true;
}

/// The cursor's rectangle in Pango units, with `y` measured from the top
/// of the text view. A cursor too far away to measure without scrolling
/// is reported well outside the view, above or below it.
pub fn caretRect(self: *App) p.Rectangle {
    const d = self.document();
    const row = self.port().locate(d.cursor) orelse return .{ .x = 0, .y = if (d.cursor < d.top) -far else far, .width = 0, .height = 18 * 1024 };
    var r: p.Rectangle = undefined;
    p.pango_layout_get_cursor_pos(row.line.layout, row.line.index(d.cursor), &r, null);
    r.y += @intFromFloat(row.y * 1024);
    return r;
}

/// Like `caretRect`, but first scrolls to a cursor that is far away.
pub fn caretRectNear(self: *App) p.Rectangle {
    var r = self.caretRect();
    if (r.y <= -far / 2 or r.y >= far / 2) {
        self.port().jumpTo(self.document().cursor);
        r = self.caretRect();
    }
    return r;
}

pub fn inputRectangle(self: *App) p.Rectangle {
    const r = self.caretRect();
    return .{ .x = @intFromFloat(@as(f64, @floatFromInt(r.x)) / 1024 + 16 - self.current().scroll_x), .y = @intFromFloat(@as(f64, @floatFromInt(r.y)) / 1024 + self.viewTop()), .width = 2, .height = @max(1, @divTrunc(r.height, 1024)) };
}

pub fn reveal(self: *App) void {
    const r = self.caretRectNear();
    const t = self.current();
    const y = @as(f64, @floatFromInt(r.y)) / 1024;
    const h = @as(f64, @floatFromInt(r.height)) / 1024;
    const pt = self.port();
    if (y < 0) pt.scrollBy(y) else if (y + h > pt.height) pt.scrollBy(y + h - pt.height);
    if (!self.wrap) {
        const x = @as(f64, @floatFromInt(r.x)) / 1024;
        t.scroll_x = @max(0, @max(x - @as(f64, @floatFromInt(self.w)) + 48, @min(t.scroll_x, x)));
    }
    self.changed();
}
