// The shell's one button look, and state transitions for a `.button`
// widget. `paint` is what the widget tree's `.button` draws and what screens
// laid out by hand (lock, polkit) call directly. The hovered/pressed
// bookkeeping lives in input.zig's dispatcher; this module only moves a single
// button between states and fires its callback.
const chrome = @import("../window_chrome.zig");
const std = @import("std");
const layout = @import("../layout.zig");
const theme = @import("../theme.zig");
const paint_mod = @import("../paint.zig");
const Renderer = paint_mod.Renderer;
const Widget = layout.Widget;
const ButtonState = layout.ButtonState;
const IconId = layout.IconId;

pub const Rect = @import("field.zig").Rect;

/// `primary` is the accent fill (the start menu's selected category chip);
/// `secondary` a quiet surface with a hairline border; `ghost` shows only on
/// hover; `chrome` is a window-style close button, red on hover.
pub const Variant = enum { primary, secondary, ghost, chrome };

pub const Size = enum { sm, md, lg };

pub const Options = struct {
    variant: Variant = .secondary,
    size: Size = .md,
    label: []const u8 = "",
    /// Paints this glyph centred instead of `label` (an icon-only button);
    /// the label stays its accessible name.
    icon: ?IconId = null,
    /// Icon size as a fraction of the button's shorter side.
    icon_scale: f32 = 0.5,
    /// A glyph before the label, centred together with it ("▭ Region").
    leading_icon: ?IconId = null,
    /// A glyph at the right end, after a centred label (the lock's "Unlock ›").
    trailing_icon: ?IconId = null,
    /// `leading_icon` above the label rather than beside it: a tile, like the
    /// lock's Power and Restart.
    stacked: bool = false,
    alignment: enum { center, left } = .center,
};

pub const State = struct {
    pointer: ButtonState = .idle,
    /// Toggled on (a view mode, an active filter): an accent tint behind a
    /// non-primary button.
    selected: bool = false,
    /// Keyboard focus: a ring inside the button's bounds, so a widget tree's
    /// damage still covers it.
    focused: bool = false,
};

pub const Metrics = struct {
    height: f32,
    font_size: f32,
    pad_x: f32,
    icon: f32,
    radius: f32,
};

pub fn metrics(size: Size, t: theme.Theme) Metrics {
    return switch (size) {
        .sm => .{ .height = 28, .font_size = t.button_font_size, .pad_x = 10, .icon = 14, .radius = t.radius },
        .md => .{ .height = 34, .font_size = t.button_font_size, .pad_x = 13, .icon = 16, .radius = t.radius },
        // Matches the large text field it usually sits under.
        .lg => .{ .height = 52, .font_size = t.button_font_size + 5.5, .pad_x = 20, .icon = 20, .radius = t.field_radius + 2 },
    };
}

/// Natural size for a label `label_w` wide, for measure.zig.
pub fn naturalSize(opts: Options, t: theme.Theme, label_w: f32) struct { w: f32, h: f32 } {
    const m = metrics(opts.size, t);
    if (opts.icon != null) return .{ .w = m.height, .h = m.height };
    if (opts.stacked) {
        const icon = stackedIcon(m);
        return .{ .w = @max(label_w, icon) + m.pad_x * 2, .h = icon + stack_gap + m.font_size * 1.4 + m.pad_x };
    }
    const leading: f32 = if (opts.leading_icon != null) m.icon + iconGap(m) else 0;
    const trailing: f32 = if (opts.trailing_icon != null) m.icon + m.pad_x / 2 else 0;
    return .{ .w = label_w + m.pad_x * 2 + 2 + leading + trailing, .h = m.height };
}

const stack_gap: f32 = 6;

fn stackedIcon(m: Metrics) f32 {
    return m.icon * 1.5;
}

fn iconGap(m: Metrics) f32 {
    return m.icon / 2;
}

pub fn optionsOf(data: layout.ButtonData) Options {
    return .{
        .variant = data.variant,
        .size = data.size,
        .label = data.label,
        .icon = data.icon,
        .icon_scale = data.icon_scale,
        .leading_icon = data.leading_icon,
        .trailing_icon = data.trailing_icon,
        .stacked = data.stacked,
    };
}

pub fn paint(r: *Renderer, box: Rect, opts: Options, state: State) void {
    paintBackground(r, box, opts, state);
    paintContent(r, box, opts, state);
}

/// Separate passes let toolbars place a moving hover chip beneath the ink.
pub fn paintBackground(r: *Renderer, box: Rect, opts: Options, state: State) void {
    const t = r.palette orelse theme.global;
    const m = metrics(opts.size, t);
    const disabled = state.pointer == .disabled;
    const hovered = state.pointer == .hover or state.pointer == .press;
    const clear: [4]f32 = .{ 0, 0, 0, 0 };
    var bg: [4]f32 = switch (opts.variant) {
        .primary => t.accent,
        .secondary => if (hovered) t.surface_hover else t.surface,
        .ghost => if (hovered) t.surface_hover else clear,
        .chrome => if (hovered) t.window_close_hover else clear,
    };
    if (opts.variant == .chrome) bg[3] *= t.window_close_hover_alpha;
    if (opts.variant == .primary and hovered) for (0..3) |i| {
        bg[i] = @min(1, bg[i] * t.button_hover_brightness);
    };
    if (state.selected and opts.variant != .primary) bg = .{ t.accent[0], t.accent[1], t.accent[2], t.accent[3] * @as(f32, if (hovered) t.button_selected_hover_alpha else t.button_selected_alpha) };
    if (disabled) bg[3] *= t.button_disabled_alpha;
    const ring = state.focused and !disabled;
    const border_w: f32 = if (ring) 2 else if (opts.variant == .secondary) 1 else 0;
    if (bg[3] > 0 or border_w > 0) r.fillRect(box.x, box.y, box.w, box.h, .{
        .color = bg,
        .radius = if (opts.variant == .chrome) chrome.control_radius else m.radius,
        .border_width = border_w,
        .border_color = if (ring) t.controlFocusColor() else if (hovered) t.border else t.border_soft,
    });
}

pub fn paintContent(r: *Renderer, box: Rect, opts: Options, state: State) void {
    const t = r.palette orelse theme.global;
    const m = metrics(opts.size, t);
    const disabled = state.pointer == .disabled;
    const fg = if (disabled) t.faint else if (opts.variant == .primary) t.on_accent else t.fg;
    if (opts.icon) |id| {
        if (opts.variant == .chrome and id == .close) {
            paintClose(r, box, opts, state);
            return;
        }
        const side = @min(box.w, box.h) * opts.icon_scale;
        r.drawIcon(box.x + (box.w - side) / 2, box.y + (box.h - side) / 2, side, side, .{ .id = id, .color = fg });
        return;
    }
    const label_style: layout.TextStyle = .{ .content = opts.label, .font_size = m.font_size, .weight = 600, .color = fg };
    // A left-aligned label starts at the edge, so a long one would otherwise
    // run under the trailing glyph.
    const trailing_room: f32 = if (opts.alignment == .left and opts.trailing_icon != null) m.icon + m.pad_x + iconGap(m) else 0;
    if (opts.stacked) {
        const icon = stackedIcon(m);
        const line = m.font_size * 1.4;
        const top = box.y + (box.h - (icon + stack_gap + line)) / 2;
        if (opts.leading_icon) |id| r.drawIcon(box.x + (box.w - icon) / 2, top, icon, icon, .{ .id = id, .color = fg });
        const tx = paint_mod.centeredTextX(box.x, box.w, opts.label, m.font_size);
        r.drawText(tx, top + icon + stack_gap, box.x + box.w - tx, line, label_style);
        return;
    }
    if (opts.leading_icon) |id| {
        // Icon and label centred as one group.
        const label_w = paint_mod.labelWidth(opts.label, m.font_size);
        const group = m.icon + iconGap(m) + label_w;
        const left = box.x + (if (opts.alignment == .left) m.pad_x else @max(0, (box.w - group) / 2));
        r.drawIcon(left, box.y + (box.h - m.icon) / 2, m.icon, m.icon, .{ .id = id, .color = fg });
        const tx = left + m.icon + iconGap(m);
        r.drawText(tx, box.y, @max(0, box.x + box.w - tx - trailing_room), box.h, label_style);
    } else {
        const tx = if (opts.alignment == .left) box.x + m.pad_x else paint_mod.centeredTextX(box.x, box.w, opts.label, m.font_size);
        r.drawText(tx, box.y, @max(0, box.x + box.w - tx - trailing_room), box.h, label_style);
    }
    if (opts.trailing_icon) |id| {
        r.drawIcon(box.x + box.w - m.pad_x - m.icon, box.y + (box.h - m.icon) / 2, m.icon, m.icon, .{ .id = id, .color = fg });
    }
}

// The same SDF cross and neutral resting ink as server-side decorations.
fn paintClose(r: *Renderer, box: Rect, opts: Options, state: State) void {
    const t = r.palette orelse theme.global;
    const hovered = state.pointer == .hover or state.pointer == .press;
    const dim = t.window_dim;
    const luma = dim[0] * 0.2126 + dim[1] * 0.7152 + dim[2] * 0.0722;
    const ink = if (hovered) @import("../text.zig").Color{ .r = t.window_close_fg[0], .g = t.window_close_fg[1], .b = t.window_close_fg[2], .a = t.window_close_fg[3] } else @import("../text.zig").Color{ .r = luma, .g = luma, .b = luma, .a = dim[3] * @as(f32, if (state.pointer == .disabled) 0.5 else 1) };
    const cx = box.x + box.w / 2;
    const cy = box.y + box.h / 2;
    const glyph_scale = chrome.button_glyph_scale * opts.icon_scale / 0.5;
    if (glyph_scale <= 0) return;
    const clip = r.effectiveClip();
    const left: i32 = @intFromFloat(@max(0, @floor(box.x * r.scale)));
    const top: i32 = @intFromFloat(@max(0, @floor(box.y * r.scale)));
    const right: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(r.width)), @ceil((box.x + box.w) * r.scale)));
    const bottom: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(r.height)), @ceil((box.y + box.h) * r.scale)));
    r.clean = false;
    var y = top;
    while (y < bottom) : (y += 1) {
        var x = left;
        while (x < right) : (x += 1) {
            const px = (@as(f32, @floatFromInt(x)) + 0.5) / r.scale;
            const py = (@as(f32, @floatFromInt(y)) + 0.5) / r.scale;
            if (clip) |c| if (px < c.x or py < c.y or px >= c.x + c.w or py >= c.y + c.h) continue;
            const cov = chrome.closeIconCoverage((px - cx) / glyph_scale, (py - cy) / glyph_scale, .{ .x = -1, .y = -1, .w = 2, .h = 2 }, @sqrt(@as(f32, 0.5)), r.scale * glyph_scale);
            paint_mod.blendPixel(&r.pixels[@intCast(y * r.width + x)], ink, cov);
        }
    }
}

pub fn setState(widget: *Widget, state: ButtonState) void {
    switch (widget.kind) {
        .button => |*data| {
            if (data.state == state) return;
            data.state = state;
            widget.markDirty();
        },
        else => {},
    }
}

/// Fires `on_click`. A no-op on a disabled button or a non-button widget.
pub fn press(widget: *Widget) void {
    switch (widget.kind) {
        .button => |data| if (data.state != .disabled) {
            if (data.on_click) |cb| cb(data.owner, data.id);
        },
        else => {},
    }
}

test "setState is a no-op when unchanged, dirties on real change" {
    var clicked = false;
    const Callback = struct {
        fn call(_: ?*anyopaque, _: usize) void {}
    };
    var widget = Widget{ .kind = .{ .button = .{ .label = "Go", .on_click = &Callback.call } } };
    widget.needs_layout = false;

    setState(&widget, .idle);
    try std.testing.expect(!widget.needs_layout);

    setState(&widget, .hover);
    try std.testing.expect(widget.needs_layout);
    try std.testing.expectEqual(ButtonState.hover, widget.kind.button.state);
    _ = &clicked;
}

test "press ignores disabled buttons" {
    const Counter = struct {
        var count: u32 = 0;
        fn call(_: ?*anyopaque, _: usize) void {
            count += 1;
        }
    };
    var widget = Widget{ .kind = .{ .button = .{ .label = "Go", .on_click = &Counter.call, .state = .disabled } } };
    press(&widget);
    try std.testing.expectEqual(@as(u32, 0), Counter.count);

    setState(&widget, .idle);
    press(&widget);
    try std.testing.expectEqual(@as(u32, 1), Counter.count);
}

test "sizes: natural width wraps the label, icon-only buttons are square" {
    const t: theme.Theme = .{};
    const md = naturalSize(.{ .label = "x" }, t, 40);
    try std.testing.expectEqual(@as(f32, 40 + 26 + 2), md.w);
    try std.testing.expectEqual(@as(f32, 34), md.h);
    const lg = naturalSize(.{ .size = .lg, .trailing_icon = .chevron_right }, t, 40);
    try std.testing.expectEqual(@as(f32, 40 + 40 + 2 + 20 + 10), lg.w);
    try std.testing.expectEqual(@as(f32, 52), lg.h);
    const icon = naturalSize(.{ .icon = .power, .size = .sm }, t, 40);
    try std.testing.expectEqual(@as(f32, 28), icon.w);
    const leading = naturalSize(.{ .leading_icon = .region }, t, 40);
    try std.testing.expectEqual(md.w + 16 + 8, leading.w);
    const tile = naturalSize(.{ .leading_icon = .power, .stacked = true, .size = .sm }, t, 40);
    try std.testing.expectEqual(@as(f32, 60), tile.w);
    try std.testing.expect(tile.h > 21 + 6 + 12.5);
}

test "a stacked tile draws its icon above the label" {
    var pixels: [90 * 80]u32 = @splat(0);
    var r = Renderer.init(&pixels, 90, 80, 1);
    var t: theme.Theme = .{};
    t.fg = .{ 1, 1, 1, 1 };
    r.palette = t;
    paint(&r, .{ .x = 0, .y = 0, .w = 90, .h = 80 }, .{ .variant = .ghost, .size = .sm, .stacked = true, .leading_icon = .plus, .label = "Power" }, .{});
    var top_ink: usize = 80;
    var bottom_ink: usize = 0;
    for (0..80) |y| for (0..90) |x| if (pixels[y * 90 + x] >> 24 > 0x80) {
        top_ink = @min(top_ink, y);
        bottom_ink = @max(bottom_ink, y);
    };
    // Ink spans icon and label, centred as a group.
    try std.testing.expect(top_ink > 5 and top_ink < 30);
    try std.testing.expect(bottom_ink > 45 and bottom_ink < 75);
}

test "primary fills with the accent and a focus ring shows only when enabled" {
    var pixels: [80 * 40]u32 = @splat(0);
    var r = Renderer.init(&pixels, 80, 40, 1);
    var t: theme.Theme = .{};
    t.accent = .{ 1, 0, 0, 1 };
    t.fg = .{ 1, 1, 1, 1 };
    r.palette = t;
    const box: Rect = .{ .x = 0, .y = 0, .w = 80, .h = 40 };
    paint(&r, box, .{ .variant = .primary }, .{});
    // Middle of the top edge, and a pixel inside that edge.
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[40]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[80 + 40]);

    paint(&r, box, .{ .variant = .primary }, .{ .focused = true });
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[40]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[80 + 40]);

    @memset(&pixels, 0);
    paint(&r, box, .{ .variant = .primary }, .{ .focused = true, .pointer = .disabled });
    // Half-alpha fill, no ring.
    try std.testing.expect(pixels[40] >> 24 < 0xc0);
    try std.testing.expectEqual(pixels[40] & 0xff, 0);
}

test "ghost and chrome buttons draw nothing until hovered" {
    var pixels: [40 * 40]u32 = @splat(0);
    var r = Renderer.init(&pixels, 40, 40, 1);
    const box: Rect = .{ .x = 0, .y = 0, .w = 40, .h = 40 };
    paint(&r, box, .{ .variant = .ghost, .icon = .close, .icon_scale = 0.01 }, .{});
    paint(&r, box, .{ .variant = .chrome, .icon = .close, .icon_scale = 0.01 }, .{});
    try std.testing.expectEqual(@as(u32, 0), pixels[5 * 40 + 20]);
    paint(&r, box, .{ .variant = .chrome, .icon = .close, .icon_scale = 0.01 }, .{ .pointer = .hover });
    try std.testing.expectEqual(@as(u32, 217), pixels[5 * 40 + 20] >> 24);
}
