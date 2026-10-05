// State transitions for a `.toggle` widget — identical shape to
// checkbox.zig's `toggle`, kept separate since the two carry unrelated
// visuals (a pill thumb vs. a checked square; see layout.zig's ToggleData).
const std = @import("std");
const layout = @import("../layout.zig");
const Widget = layout.Widget;

const Renderer = @import("../paint.zig").Renderer;
const theme = @import("../theme.zig");
const Rect = @import("field.zig").Rect;

/// Natural switch size, shared by widget trees (measure.zig) and hand-laid panels.
pub const width: f32 = 36;
pub const height: f32 = 20;

pub const Options = struct {
    on: bool,
    style: @FieldType(layout.ToggleData, "style") = .standard,
    focused: bool = false,
    disabled: bool = false,
};

/// Shared switch painter for widget trees and hand-laid panels.
pub fn paint(r: *Renderer, box: Rect, opts: Options) void {
    const t = r.palette orelse theme.global;
    const radius: f32 = if (opts.style == .settings) t.toggle_radius else box.h / 2;
    var track: [4]f32 = if (opts.on) t.accent else t.toggle_track;
    var thumb = t.control_thumb;
    if (opts.disabled) {
        track[3] *= 0.5;
        thumb[3] *= 0.5;
    }
    r.fillRect(box.x, box.y, box.w, box.h, .{
        .color = track,
        .radius = radius,
        .border_width = if (opts.focused and !opts.disabled) 2 else 0,
        .border_color = t.controlFocusColor(),
    });
    const inset: f32 = 2;
    const side = @max(0, box.h - inset * 2);
    const x = if (opts.on) box.x + box.w - inset - side else box.x + inset;
    r.fillRect(x, box.y + inset, side, side, .{ .color = thumb, .radius = if (opts.style == .settings) t.toggle_thumb_radius else side / 2 });
}

pub fn toggle(widget: *Widget) void {
    switch (widget.kind) {
        .toggle => |*data| {
            if (data.disabled) return;
            data.on = !data.on;
            widget.markDirty();
            data.on_change(data.owner, data.id, data.on);
        },
        else => {},
    }
}

test "toggle routes changes to its own context and ID" {
    const Recorder = struct {
        last: bool = false,
        calls: u32 = 0,
        id: usize = 0,
        fn call(owner: ?*anyopaque, id: usize, value: bool) void {
            const self: *@This() = @ptrCast(@alignCast(owner.?));
            self.last = value;
            self.calls += 1;
            self.id = id;
        }
    };
    var first = Recorder{};
    var second = Recorder{};
    var one = Widget{ .kind = .{ .toggle = .{ .on = false, .owner = &first, .id = 12, .on_change = Recorder.call } } };
    var two = Widget{ .kind = .{ .toggle = .{ .on = false, .owner = &second, .id = 34, .on_change = Recorder.call } } };
    one.needs_layout = false;
    toggle(&one);
    toggle(&two);
    toggle(&one);
    try std.testing.expect(!one.kind.toggle.on);
    try std.testing.expect(one.needs_layout);
    try std.testing.expectEqual(@as(u32, 2), first.calls);
    try std.testing.expectEqual(@as(usize, 12), first.id);
    try std.testing.expect(!first.last);
    try std.testing.expectEqual(@as(u32, 1), second.calls);
    try std.testing.expectEqual(@as(usize, 34), second.id);
    try std.testing.expect(second.last);
    two.kind.toggle.disabled = true;
    toggle(&two);
    try std.testing.expect(two.kind.toggle.on);
    try std.testing.expectEqual(@as(u32, 1), second.calls);
}
