//! Shared icon buttons for compact sidebar controls.

const c = @import("c.zig").api;
const ui = @import("ui").cairo;
const theme = @import("ui").theme;
const draw = @import("app_draw.zig");
const Rect = ui.Rect;

pub const Icon = enum {
    pause,
    play,
    close,
};

/// `right_inset` positions the button's left edge from the area's right edge.
pub fn buttonRect(area: Rect, right_inset: f32, top_inset: f32) Rect {
    return .{
        .x = area.x + area.w - right_inset,
        .y = area.y + top_inset,
        .w = 24,
        .h = 24,
    };
}

pub fn contains(rect: Rect, x: f64, y: f64) bool {
    return x >= rect.x and x < rect.x + rect.w and
        y >= rect.y and y < rect.y + rect.h;
}

pub fn render(cr: *c.cairo_t, rect: Rect, icon: Icon, hovered: bool) void {
    if (hovered) {
        draw.roundedRect(cr, rect.x, rect.y, rect.w, rect.h, 6);
        draw.setSource(cr, theme.global.app_item_hover);
        c.cairo_fill(cr);
    }

    if (ui.Layer.begin(cr, rect)) |icon_layer| {
        var layer = icon_layer;
        layer.renderer.drawIcon(4, 4, 16, 16, .{
            .id = switch (icon) {
                .pause => .pause,
                .play => .play,
                .close => .close,
            },
            .color = theme.global.app_icon,
        });
        layer.finish();
    }
}
