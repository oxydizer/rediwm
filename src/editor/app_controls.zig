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
const ui_theme = @import("ui").theme;

pub fn buttonProximity(self: *const App, box: Rect) button.ProximitySample {
    return button.sampleProximity(
        .{ .x = @floatCast(box.x), .y = @floatCast(box.y), .w = @floatCast(box.w), .h = @floatCast(box.h) },
        @floatCast(self.px),
        @floatCast(self.py),
        .{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = @floatFromInt(self.h) },
    );
}

fn nearestButton(self: *App, x: f64, y: f64) f32 {
    if (self.menu_open) return std.math.inf(f32);
    var nearest = std.math.inf(f32);
    if (self.close_tab != null) {
        if (self.operation == null) {
            const dx = (@as(f64, @floatFromInt(self.w)) - 420) / 2;
            const dy = (@as(f64, @floatFromInt(self.h)) - 170) / 2;
            for ([_]Rect{
                .{ .x = dx + 20, .y = dy + 112, .w = 115, .h = 38 },
                .{ .x = dx + 145, .y = dy + 112, .w = 125, .h = 38 },
                .{ .x = dx + 280, .y = dy + 112, .w = 120, .h = 38 },
            }) |box| {
                const sample = button.sampleProximity(
                    .{ .x = @floatCast(box.x), .y = @floatCast(box.y), .w = @floatCast(box.w), .h = @floatCast(box.h) },
                    @floatCast(x), @floatCast(y),
                    .{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = @floatFromInt(self.h) },
                );
                nearest = @min(nearest, sample.distance);
            }
        }
        return nearest;
    }
    for (self.first_tab..self.tabs.items.len) |i| {
        const index = i - self.first_tab;
        if (@as(f64, @floatFromInt(index + 1)) * app.tab_w > self.tabRight()) break;
        const box = self.tabCloseBox(index);
        const sample = button.sampleProximity(
            .{ .x = @floatCast(box.x), .y = @floatCast(box.y), .w = @floatCast(box.w), .h = @floatCast(box.h) },
            @floatCast(x), @floatCast(y),
            .{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = @floatFromInt(self.h) },
        );
        nearest = @min(nearest, sample.distance);
    }
    for ([_]Rect{ self.newButtonBox() }) |box| {
        const sample = button.sampleProximity(
            .{ .x = @floatCast(box.x), .y = @floatCast(box.y), .w = @floatCast(box.w), .h = @floatCast(box.h) },
            @floatCast(x), @floatCast(y),
            .{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = @floatFromInt(self.h) },
        );
        nearest = @min(nearest, sample.distance);
    }
    if (!self.has_titlebar) {
        const box = self.menuButtonBox();
        const sample = button.sampleProximity(
            .{ .x = @floatCast(box.x), .y = @floatCast(box.y), .w = @floatCast(box.w), .h = @floatCast(box.h) },
            @floatCast(x), @floatCast(y),
            .{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = @floatFromInt(self.h) },
        );
        nearest = @min(nearest, sample.distance);
    }
    if (self.find_open) {
        const controls = [_]SearchControl{ .next, .toggle, .close, .replace, .replace_all };
        for (controls) |control| {
            if (!self.replace_open and (control == .replace or control == .replace_all)) continue;
            const box = self.searchBox(control);
            const sample = button.sampleProximity(
                .{ .x = @floatCast(box.x), .y = @floatCast(box.y), .w = @floatCast(box.w), .h = @floatCast(box.h) },
                @floatCast(x), @floatCast(y),
                .{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = @floatFromInt(self.h) },
            );
            nearest = @min(nearest, sample.distance);
        }
    }
    return nearest;
}

pub fn proximityChanged(self: *App, old_x: f64, old_y: f64, new_x: f64, new_y: f64) bool {
    const reach = ui_theme.global.border_glow_reach;
    if (!ui_theme.global.button_hover_glow_enabled or reach <= 0) return false;
    return @min(nearestButton(self, old_x, old_y), nearestButton(self, new_x, new_y)) <= reach;
}

pub fn tabCloseBox(_: *const App, index: usize) Rect {
    return .{ .x = @as(f64, @floatFromInt(index)) * app.tab_w + app.tab_w - 36, .y = 2, .w = 34, .h = 34 };
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
    for (self.first_tab..self.tabs.items.len) |i| {
        const index = i - self.first_tab;
        if (@as(f64, @floatFromInt(index + 1)) * app.tab_w > self.tabRight()) break;
        if (self.tabCloseBox(index).contains(self.px, self.py)) return .{ .close = i };
    }
    return .none;
}

pub fn paintIcon(self: *App, cr: *c.cairo_t, box: Rect, icon: @import("ui").layout.IconId, label: []const u8, selected: bool) void {
    var layer = ui.Layer.begin(cr, .{ .x = @floatCast(box.x), .y = @floatCast(box.y), .w = @floatCast(box.w), .h = @floatCast(box.h) }) orelse return;
    defer layer.finish();
    layer.renderer.palette = theme.shellPalette();
    const active = !self.menu_open and self.close_tab == null;
    const proximity = if (active) self.buttonProximity(box) else .{ .distance = std.math.inf(f32), .x = 0, .y = 0 };
    button.paint(&layer.renderer, layer.local(), .{ .label = label, .icon = icon, .variant = .ghost, .size = .sm }, .{
        .selected = selected,
        .pointer = if (active and box.contains(self.px, self.py)) .hover else .idle,
        .proximity_distance = proximity.distance,
        .proximity_x = proximity.x,
        .proximity_y = proximity.y,
    });
}
