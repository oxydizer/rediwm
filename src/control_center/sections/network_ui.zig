//! Small widget builders shared by the Network page's cards.
const i18n = @import("i18n");
const std = @import("std");
const panel = @import("../panel.zig");
const ui = @import("ui");
const W = ui.layout.Widget;
const Allocator = std.mem.Allocator;

pub fn text(value: []const u8, size: f32, dim: bool) W {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = value, .font_size = size, .weight = if (dim) 400 else 600, .color = if (dim) t.dim else t.fg } } };
}
pub fn icon(id: ui.layout.IconId, size: f32, accent: bool) W {
    return .{ .kind = .{ .icon = .{ .id = id, .color = if (accent) panel.palette().accent else panel.palette().fg } }, .width = .{ .fixed = size }, .height = .{ .fixed = size } };
}
pub fn group(a: Allocator, direction: ui.layout.Direction, items: []const W) !W {
    return .{ .kind = .container, .direction = direction, .gap = 10, .@"align" = if (direction == .row) .center else .stretch, .width = .{ .percent = 1 }, .children = try a.dupe(W, items) };
}
pub fn card(a: Allocator, items: []const W) !W {
    var w = try group(a, .column, items);
    const t = panel.palette();
    w.kind = .{ .rect = .{ .color = t.app_item, .radius = 9, .border_width = 1, .border_color = t.app_item_border, .relief = t.settings_card_relief } };
    w.padding = ui.layout.Edges.all(16);
    w.gap = 14;
    return w;
}
pub fn divider(vertical: bool) W {
    return .{ .kind = .{ .rect = .{ .color = panel.palette().border_soft } }, .width = if (vertical) .{ .fixed = 1 } else .{ .percent = 1 }, .height = if (vertical) .{ .fixed = 58 } else .{ .fixed = 1 } };
}
pub fn status(a: Allocator, value: []const u8, active: bool) !W {
    var label = text(value, 13, true);
    label.width = .{ .flex = 1 };
    if (active) label.kind.text.color = panel.palette().accent;
    return group(a, .row, &.{
        .{ .kind = .{ .rect = .{ .color = if (active) panel.palette().accent else panel.palette().dim, .radius = 4 } }, .width = .{ .fixed = 7 }, .height = .{ .fixed = 7 } },
        label,
    });
}
pub fn summary(a: Allocator, glyph: ui.layout.IconId, title: []const u8, state: []const u8, description: []const u8, active: bool) !W {
    var labels = try group(a, .column, &.{ text(title, 14, false), try status(a, state, active), text(description, 12, true) });
    labels.width = .{ .flex = 1 };
    labels.gap = 5;
    var w = try group(a, .row, &.{ icon(glyph, 30, active), labels });
    w.width = .{ .flex = 1 };
    return w;
}
pub fn action(cc: *panel.ControlCenter, name: []const u8, value: []const u8, id: usize, callback: *const fn (?*anyopaque, usize) void, disabled: bool) W {
    return .{ .name = name, .kind = .{ .button = .{ .label = value, .owner = cc, .id = id, .on_click = callback, .state = if (disabled) .disabled else .idle } }, .height = .{ .fixed = 34 } };
}
