// The shell's checkbox look, and state transitions for a `.checkbox` widget.
const std = @import("std");
const layout = @import("../layout.zig");
const theme = @import("../theme.zig");
const Renderer = @import("../paint.zig").Renderer;
const Rect = @import("field.zig").Rect;
const Widget = layout.Widget;

pub const box_size: f32 = 18;
/// Square to label.
pub const gap: f32 = 10;

pub const State = struct {
    icon: ?layout.ImageData = null,
    checked: bool = false,
    /// Keyboard focus: a ring on the square.
    focused: bool = false,
    disabled: bool = false,
};

/// Square at the left of `box`, vertically centred, then `label`.
pub fn paint(r: *Renderer, box: Rect, label: []const u8, state: State) void {
    const t = r.palette orelse theme.global;
    const y = box.y + (box.h - box_size) / 2;
    const ring = state.focused and !state.disabled;
    var fill = if (state.checked) t.accent else t.surface;
    if (state.disabled) fill[3] *= 0.5;
    r.fillRect(box.x, y, box_size, box_size, .{
        .color = fill,
        .radius = t.checkbox_radius,
        .border_width = if (ring) 2 else 1,
        .border_color = if (ring) t.controlFocusColor() else if (state.checked) t.accent else t.border_hover,
    });
    if (state.checked) r.drawIcon(box.x, y, box_size, box_size, .{ .id = .checkmark, .color = t.on_accent });
    var left = box.x + box_size + gap;
    if (state.icon) |icon| {
        if (icon.pixels) |pixels| {
            r.drawImageCover(left, y, box_size, box_size, 0, .{ .pixels = pixels, .width = icon.width, .height = icon.height });
        } else r.drawIcon(left, y, box_size, box_size, .{ .id = icon.fallback_icon orelse .generic, .color = t.fg });
        left += box_size + gap;
    }
    r.drawText(left, box.y, @max(0, box.x + box.w - left), box.h, .{
        .content = label,
        .font_size = t.font_size,
        .color = if (state.disabled) t.faint else t.fg,
    });
}

pub fn toggle(widget: *Widget) void {
    switch (widget.kind) {
        .checkbox => |*data| {
            if (data.disabled) return;
            data.checked = !data.checked;
            widget.markDirty();
            data.on_change(data.owner, data.id, data.checked);
        },
        else => {},
    }
}

test "toggle flips checked and calls on_change" {
    const Recorder = struct {
        var last: bool = false;
        var calls: u32 = 0;
        fn call(_: ?*anyopaque, _: usize, value: bool) void {
            last = value;
            calls += 1;
        }
    };
    var widget = Widget{ .kind = .{ .checkbox = .{ .label = "Enabled", .checked = false, .on_change = &Recorder.call } } };
    widget.needs_layout = false;

    toggle(&widget);
    try std.testing.expect(widget.kind.checkbox.checked);
    try std.testing.expectEqual(@as(u32, 1), Recorder.calls);
    try std.testing.expect(Recorder.last);
    try std.testing.expect(widget.needs_layout);

    toggle(&widget);
    try std.testing.expect(!widget.kind.checkbox.checked);
    try std.testing.expectEqual(@as(u32, 2), Recorder.calls);
}
