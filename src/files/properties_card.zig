//! The body shared by every Properties window: an identity row (preview tile,
//! name, kind, Open) and the label/value fields under it. File Properties
//! (`properties.zig`) and the Trash's (`trash_properties.zig`, also shown by the
//! desktop) both draw with these, so the two cannot drift apart.
//!
//! `s` is how far the content is scrolled, less the title bar's extra height:
//! a row at `y` is drawn at `y - s`. The renderer's palette is the body's
//! (`fg` for text, `accent` for Open); call these with it set.
const std = @import("std");
const ui = @import("ui");
const theme = ui.theme;
const button = ui.widgets.button;
const Renderer = ui.paint.Renderer;
const Rect = ui.cairo.Rect;

pub const fields_y: f32 = 157;
pub const field_step: f32 = 26;

pub fn openBox(width: f32, s: f32) Rect {
    return .{ .x = width - 48, .y = 67 - s, .w = 28, .h = 28 };
}

/// Where the content ends once it holds `count` fields.
pub fn fieldsBottom(count: usize) f32 {
    return fields_y + @as(f32, @floatFromInt(count)) * field_step;
}

pub const Identity = struct {
    /// Raster of the thing described, drawn 44 px wide in its tile.
    image: ?ui.paint.Image = null,
    /// Vector glyph for when there is no raster.
    glyph: ui.layout.IconId,
    name: []const u8,
    kind: []const u8,
};

pub fn paintIdentity(r: *Renderer, width: f32, s: f32, id: Identity) void {
    const t = r.palette orelse theme.global;
    r.fillRect(24, 66 - s, 64, 64, .{ .color = theme.global.app_toolbar, .radius = 9, .border_width = 1, .border_color = theme.global.app_item_border });
    if (id.image) |im| r.drawImageCover(34, 76 - s, 44, 44, 0, im) else r.drawIcon(34, 76 - s, 44, 44, .{ .id = id.glyph, .color = t.fg });
    r.drawText(108, 68 - s, width - 162, 26, .{ .content = id.name, .font_size = t.font_size, .weight = 600, .color = t.fg });
    r.drawText(108, 99 - s, width - 132, 24, .{ .content = id.kind, .font_size = t.font_size, .color = t.fg });
}

pub fn paintOpen(r: *Renderer, width: f32, s: f32, label: []const u8, focused: bool, hovered: bool) void {
    const body = r.palette orelse theme.global;
    var accent = body;
    accent.fg = body.accent;
    r.palette = accent;
    button.paint(r, openBox(width, s), .{ .icon = .open, .variant = .ghost, .label = label }, .{ .focused = focused, .pointer = if (hovered) .hover else .idle });
    r.palette = body;
}

/// The rule under the identity row, then one label and value per line.
pub fn paintFields(r: *Renderer, width: f32, s: f32, labels: []const []const u8, values: []const []const u8) void {
    const t = r.palette orelse theme.global;
    r.fillRect(24, 146 - s, width - 48, 1, .{ .color = theme.global.app_divider });
    for (labels, values, 0..) |label, value, i| {
        const y = fields_y + @as(f32, @floatFromInt(i)) * field_step - s;
        r.drawText(24, y, 120, 24, .{ .content = label, .font_size = t.font_size, .color = t.fg });
        r.drawText(162, y, width - 186, 24, .{ .content = value, .font_size = t.font_size, .color = t.fg });
    }
}
