//! Shared geometry for the tab controls and their hover feedback.
const std = @import("std");
const c = @import("../files/c.zig").api;
const ui = @import("ui").cairo;
const theme = @import("ui").theme;
const button = @import("ui").widgets.button;
const Rect = @import("ui").context_menu.Rect;
const app = @import("app.zig");
const App = app.App;
const SearchControl = @import("app_search.zig").Control;

/// The strip is the width left of the new-tab button. Tabs share it, none
/// wider than `tab_max` or narrower than `tab_min`; a strip holding more than
/// fit at `tab_min` scrolls by pixels, so the tab cut off at its edge shows
/// that there is more.
pub fn tabWidth(self: *const App) f64 {
    const count: f64 = @floatFromInt(@max(1, self.tabs.items.len));
    return std.math.clamp(self.tabRight() / count, app.tab_min, app.tab_max);
}

/// Where tab `index` starts on screen.
pub fn tabX(self: *const App, index: usize) f64 {
    return @as(f64, @floatFromInt(index)) * self.tabWidth() - self.tab_scroll;
}

/// The tab under an x position of the strip.
pub fn tabAt(self: *const App, x: f64) ?usize {
    if (x < 0 or x >= self.tabRight()) return null;
    const index: usize = @intFromFloat((x + self.tab_scroll) / self.tabWidth());
    return if (index < self.tabs.items.len) index else null;
}

pub fn tabScrollMax(self: *const App) f64 {
    const count: f64 = @floatFromInt(self.tabs.items.len);
    return @max(0, count * self.tabWidth() - self.tabRight());
}

pub fn scrollTabs(self: *App, delta: f64) void {
    const before = self.tab_scroll;
    self.tab_scroll = std.math.clamp(before + delta, 0, self.tabScrollMax());
    if (self.tab_scroll != before) self.dirty = true;
}

/// What decides whether the selected tab needs bringing into view.
pub const Strip = struct { selected: usize = std.math.maxInt(usize), count: usize = 0, right: f64 = 0 };

/// Scrolls the selected tab into view when it, the number of tabs or the
/// width changed, and keeps the scroll in range. Other changes (typing)
/// leave a strip the user scrolled away alone.
pub fn revealTab(self: *App) void {
    const seen: Strip = .{ .selected = self.selected, .count = self.tabs.items.len, .right = self.tabRight() };
    if (!std.meta.eql(seen, self.strip_seen)) {
        self.strip_seen = seen;
        const width = self.tabWidth();
        const left = @as(f64, @floatFromInt(self.selected)) * width;
        if (left < self.tab_scroll) {
            self.tab_scroll = left;
        } else if (left + width > self.tab_scroll + seen.right) self.tab_scroll = left + width - seen.right;
    }
    self.tab_scroll = std.math.clamp(self.tab_scroll, 0, self.tabScrollMax());
}

pub fn tabCloseBox(self: *const App, index: usize) Rect {
    return .{ .x = self.tabX(index) + self.tabWidth() - 36, .y = 2, .w = 34, .h = 34 };
}

pub fn newButtonBox(self: *const App) Rect {
    return .{ .x = self.tabRight(), .y = 2, .w = 36, .h = 34 };
}

pub fn menuButtonBox(self: *const App) Rect {
    return .{ .x = @as(f64, @floatFromInt(self.w)) - 38, .y = 2, .w = 36, .h = 34 };
}

const Hover = union(enum) { none, close: usize, new, menu, search: SearchControl, dialog: usize };

pub fn hoverTarget(self: *App) Hover {
    if (self.close_tab != null) {
        const x = (@as(f64, @floatFromInt(self.w)) - 420) / 2;
        const y = (@as(f64, @floatFromInt(self.h)) - 170) / 2;
        for ([_]Rect{
            .{ .x = x + 20, .y = y + 112, .w = 115, .h = 38 },
            .{ .x = x + 145, .y = y + 112, .w = 125, .h = 38 },
            .{ .x = x + 280, .y = y + 112, .w = 120, .h = 38 },
        }, 0..) |box, i| if (box.contains(self.px, self.py)) return .{ .dialog = i };
        return .none;
    }
    if (self.menu_open) return .none;
    if (self.find_open) if (self.searchHit(self.px, self.py)) |hit| return .{ .search = hit };
    if (self.newButtonBox().contains(self.px, self.py)) return .new;
    if (!self.has_titlebar and self.menuButtonBox().contains(self.px, self.py)) return .menu;
    if (self.tabAt(self.px)) |i| if (self.tabCloseBox(i).contains(self.px, self.py)) return .{ .close = i };
    return .none;
}

pub fn paintIcon(self: *App, cr: *c.cairo_t, box: Rect, icon: @import("ui").layout.IconId, label: []const u8, selected: bool) void {
    var layer = ui.Layer.begin(cr, .{ .x = @floatCast(box.x), .y = @floatCast(box.y), .w = @floatCast(box.w), .h = @floatCast(box.h) }) orelse return;
    defer layer.finish();
    layer.renderer.palette = theme.shellPalette();
    button.paint(&layer.renderer, layer.local(), .{ .label = label, .icon = icon, .variant = .ghost, .size = .sm }, .{
        .selected = selected,
        .pointer = if (!self.menu_open and self.close_tab == null and box.contains(self.px, self.py)) .hover else .idle,
    });
}
