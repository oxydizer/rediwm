// The shell's one text-field look, modelled on the start menu's search box:
// a rounded frame, an optional leading icon and an optional trailing
// accessory, all from `theme` tokens. The content is drawn by the caller into
// `Layout.text` — the widget tree's `.text_input` (paint.zig, with the
// dispatcher's animated caret) or a secret (`paintSecret`) — so screens laid
// out by hand, like the lock and the polkit dialog, share the look without
// joining a widget tree.
const std = @import("std");
const layout = @import("../layout.zig");
const theme = @import("../theme.zig");
const Renderer = @import("../paint.zig").Renderer;
const secret_input = @import("secret_input.zig");

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

pub const Size = enum { md, lg };

/// `.reveal` is a password's show/hide eye. Its click is the caller's to
/// handle: hit test `Layout.trailing`.
pub const Trailing = enum { none, reveal };

pub const Options = struct {
    size: Size = .md,
    /// None by default; `.search` for search boxes.
    leading_icon: ?layout.IconId = null,
    leading_icon_size: ?f32 = null,
    leading_icon_color: ?[4]f32 = null,
    trailing: Trailing = .none,
};

pub const State = struct {
    focused: bool = false,
    disabled: bool = false,
    invalid: bool = false,
    /// A secret is shown in the clear, and the `.reveal` eye is open.
    revealed: bool = false,
    /// Keyboard focus on the trailing accessory rather than the text.
    trailing_focused: bool = false,
    /// The caller draws the caret itself (an animated overlay) at
    /// `Layout.caret`; the painter only reports where it goes.
    external_caret: bool = false,
};

pub const Metrics = struct {
    height: f32,
    font_size: f32,
    /// Frame edge to the leading icon (or to the text without one), and to
    /// the text's right end.
    pad: f32,
    icon: f32,
    /// Leading icon's right edge to the text.
    icon_gap: f32,
    /// Side of the trailing accessory's square.
    trailing: f32,
    radius: f32,
};

pub fn metrics(size: Size, t: theme.Theme) Metrics {
    return switch (size) {
        .md => .{ .height = 44, .font_size = t.font_size, .pad = 12, .icon = 16, .icon_gap = 20, .trailing = 32, .radius = t.field_radius },
        .lg => .{ .height = 56, .font_size = t.font_size + 5, .pad = 16, .icon = 20, .icon_gap = 14, .trailing = 40, .radius = t.field_radius + 2 },
    };
}

pub const Layout = struct {
    text: Rect,
    icon: ?Rect = null,
    trailing: ?Rect = null,
    font_size: f32,
    /// Set by `paintSecret` while the field shows a caret.
    caret: ?secret_input.Input.CaretPlace = null,
};

pub fn arrange(box: Rect, opts: Options, t: theme.Theme) Layout {
    const m = metrics(opts.size, t);
    var out: Layout = .{ .text = box, .font_size = m.font_size };
    var left = box.x + m.pad;
    var right = box.x + box.w - m.pad;
    if (opts.leading_icon != null) {
        const icon_size = @min(box.h, opts.leading_icon_size orelse m.icon);
        out.icon = .{ .x = left, .y = box.y + (box.h - icon_size) / 2, .w = icon_size, .h = icon_size };
        left += icon_size + m.icon_gap;
    }
    if (opts.trailing != .none) {
        const side = @min(m.trailing, box.h);
        const inset = (box.h - side) / 2;
        const tx = box.x + box.w - inset - side;
        out.trailing = .{ .x = tx, .y = box.y + inset, .w = side, .h = side };
        right = @min(right, tx - 4);
    }
    out.text = .{ .x = left, .y = box.y, .w = @max(0, right - left), .h = box.h };
    return out;
}

/// Natural size of a field whose text is `text_w` wide, for measure.zig.
pub fn naturalSize(opts: Options, t: theme.Theme, text_w: f32) struct { w: f32, h: f32 } {
    const m = metrics(opts.size, t);
    const probe = arrange(.{ .x = 0, .y = 0, .w = 1000, .h = m.height }, opts, t);
    return .{ .w = text_w + 1000 - probe.text.w, .h = m.height };
}

/// Frame, leading icon and trailing accessory. Returns where the content goes.
pub fn paintFrame(r: *Renderer, box: Rect, opts: Options, state: State) Layout {
    const t = r.palette orelse theme.global;
    const m = metrics(opts.size, t);
    const out = arrange(box, opts, t);
    var bg = t.field_bg;
    if (state.disabled) bg[3] *= 0.6;
    const border = if (state.invalid)
        t.danger
    else if (state.focused and !state.disabled)
        t.fieldFocusColor()
    else
        t.field_border;
    r.fillRect(box.x, box.y, box.w, box.h, .{ .color = bg, .radius = m.radius, .border_width = 1, .border_color = border });
    if (out.icon) |icon| r.drawIcon(icon.x, icon.y, icon.w, icon.h, .{
        .id = opts.leading_icon.?,
        .color = if (state.disabled) t.faint else opts.leading_icon_color orelse t.dim,
    });
    if (out.trailing) |slot| switch (opts.trailing) {
        .none => {},
        .reveal => {
            if (state.trailing_focused) r.fillRect(slot.x, slot.y, slot.w, slot.h, .{
                .color = t.surface_hover,
                .radius = @max(0, m.radius - 2),
                .border_width = 1,
                .border_color = t.fieldFocusColor(),
            });
            r.drawIcon(slot.x + (slot.w - m.icon) / 2, slot.y + (slot.h - m.icon) / 2, m.icon, m.icon, .{
                .id = if (state.revealed) .eye else .eye_off,
                .color = if (state.disabled) t.faint else if (state.trailing_focused) t.fg else t.dim,
            });
        },
    };
    return out;
}

/// A password or other secret: bullets unless `state.revealed`, rasterized
/// through the uncached sensitive text path. The caret is static unless
/// `state.external_caret` hands it to the caller.
pub fn paintSecret(r: *Renderer, box: Rect, opts: Options, state: State, input: *const secret_input.Input, placeholder: []const u8) Layout {
    var out = paintFrame(r, box, opts, state);
    out.caret = input.paint(r, out.text.x, out.text.y, out.text.w, out.text.h, out.font_size, .{
        .hidden = !state.revealed,
        .caret = state.focused and !state.disabled,
        .placeholder = placeholder,
        .draw_caret = !state.external_caret,
    });
    return out;
}

test "the leading icon and trailing accessory take their room from the text" {
    const t: theme.Theme = .{};
    const box: Rect = .{ .x = 10, .y = 20, .w = 300, .h = 44 };

    const plain = arrange(box, .{}, t);
    try std.testing.expect(plain.icon == null and plain.trailing == null);
    try std.testing.expectEqual(@as(f32, 22), plain.text.x);
    try std.testing.expectEqual(@as(f32, 276), plain.text.w);

    // The start menu's search box: icon at 12, text 20 past it.
    const search = arrange(box, .{ .leading_icon = .search }, t);
    try std.testing.expectEqual(@as(f32, 22), search.icon.?.x);
    try std.testing.expectEqual(@as(f32, 34), search.icon.?.y);
    try std.testing.expectEqual(@as(f32, 58), search.text.x);
    try std.testing.expectEqual(@as(f32, 20), search.text.y);
    try std.testing.expectEqual(@as(f32, 44), search.text.h);

    const secret = arrange(box, .{ .trailing = .reveal }, t);
    const eye = secret.trailing.?;
    try std.testing.expectEqual(box.x + box.w - 6, eye.x + eye.w);
    try std.testing.expectEqual(box.y + 6, eye.y);
    try std.testing.expect(secret.text.x + secret.text.w <= eye.x);
}

test "natural size adds the frame's chrome to the text" {
    const t: theme.Theme = .{};
    const plain = naturalSize(.{}, t, 100);
    try std.testing.expectEqual(@as(f32, 124), plain.w);
    try std.testing.expectEqual(@as(f32, 44), plain.h);
    const search = naturalSize(.{ .leading_icon = .search, .size = .lg }, t, 100);
    try std.testing.expectEqual(@as(f32, 100 + 16 + 20 + 14 + 16), search.w);
    try std.testing.expectEqual(@as(f32, 56), search.h);
}

test "focus colours the border with the accent in effect unless the theme sets one" {
    var pixels: [64 * 48]u32 = @splat(0);
    var r = Renderer.init(&pixels, 64, 48, 1);
    var t: theme.Theme = .{};
    t.accent = .{ 1, 0, 0, 1 };
    t.field_bg = .{ 0, 0, 0, 1 };
    r.palette = t;
    const box: Rect = .{ .x = 0, .y = 0, .w = 64, .h = 44 };
    _ = paintFrame(&r, box, .{}, .{ .focused = true });
    // Middle of the top edge: the 1px border, fully covered.
    try std.testing.expectEqual(@as(u32, 0xffff0000), pixels[32]);

    t.field_border_focus = .{ 0, 0, 1, 1 };
    r.palette = t;
    _ = paintFrame(&r, box, .{}, .{ .focused = true });
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[32]);

    _ = paintFrame(&r, box, .{}, .{ .focused = true, .invalid = true });
    const danger = pixels[32];
    try std.testing.expect((danger >> 16) & 0xff > (danger & 0xff));
}
