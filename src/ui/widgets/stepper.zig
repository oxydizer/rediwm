// State transitions for a `.stepper` widget: a "− value +" row where the
// two end zones are buttons and the middle is a plain label (see paint.zig's
// `paintStepper` for the matching draw geometry — `button_width` must stay
// in sync with it).
const std = @import("std");
const layout = @import("../layout.zig");
const Widget = layout.Widget;

const button_width: f32 = 28;

fn changeBy(widget: *Widget, delta: f32) void {
    switch (widget.kind) {
        .stepper => |*data| {
            const value = std.math.clamp(data.value + delta, data.min, data.max);
            if (value == data.value) return;
            data.value = value;
            widget.markDirty();
            data.on_change(data.owner, data.id, value);
        },
        else => {},
    }
}

/// Routes a click at `pointer_x` (widget-tree coordinates) to the minus or
/// plus zone; a click on the middle label is a no-op.
pub fn clickAt(widget: *Widget, pointer_x: f32) void {
    const data = switch (widget.kind) {
        .stepper => |d| d,
        else => return,
    };
    const rel = pointer_x - widget.computed_x;
    if (rel < button_width) {
        changeBy(widget, -data.step);
    } else if (rel >= widget.computed_width - button_width) {
        changeBy(widget, data.step);
    }
}

test "clickAt increments and decrements, clamped to [min, max]" {
    const Recorder = struct {
        var last: f32 = 0;
        fn call(_: ?*anyopaque, _: usize, v: f32) void {
            last = v;
        }
    };
    var widget = Widget{ .kind = .{ .stepper = .{ .value = 400, .min = 0, .max = 1000, .step = 50, .on_change = &Recorder.call } } };
    widget.computed_x = 0;
    widget.computed_width = 112;

    clickAt(&widget, 10); // minus zone
    try std.testing.expectEqual(@as(f32, 350), widget.kind.stepper.value);
    try std.testing.expectEqual(@as(f32, 350), Recorder.last);

    clickAt(&widget, 100); // plus zone
    try std.testing.expectEqual(@as(f32, 400), widget.kind.stepper.value);

    clickAt(&widget, 56); // middle label: no-op
    try std.testing.expectEqual(@as(f32, 400), widget.kind.stepper.value);
}
