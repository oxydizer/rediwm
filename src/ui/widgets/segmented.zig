// State transitions for a `.segmented` widget: N equal-width cells packed
// into the widget's own rect (see paint.zig's `paintSegmented` for the
// matching draw geometry).
const std = @import("std");
const layout = @import("../layout.zig");
const Widget = layout.Widget;

pub fn selectAt(widget: *Widget, pointer_x: f32) void {
    switch (widget.kind) {
        .segmented => |*data| {
            if (data.labels.len == 0 or widget.computed_width <= 0) return;
            const cell_w = widget.computed_width / @as(f32, @floatFromInt(data.labels.len));
            const rel = pointer_x - widget.computed_x;
            const index_f = std.math.clamp(@divFloor(rel, cell_w), 0, @as(f32, @floatFromInt(data.labels.len - 1)));
            const index: usize = @intFromFloat(index_f);
            if (index == data.selected) return;
            data.selected = index;
            widget.markDirty();
            data.on_change(data.owner, data.id, index);
        },
        else => {},
    }
}

test "selectAt resolves the cell under the pointer" {
    const Recorder = struct {
        var last: usize = 0;
        fn call(_: ?*anyopaque, _: usize, i: usize) void {
            last = i;
        }
    };
    var widget = Widget{ .kind = .{ .segmented = .{ .labels = &.{ "S", "M", "L" }, .selected = 1, .on_change = &Recorder.call } } };
    widget.computed_x = 0;
    widget.computed_width = 90;

    selectAt(&widget, 5);
    try std.testing.expectEqual(@as(usize, 0), widget.kind.segmented.selected);
    try std.testing.expectEqual(@as(usize, 0), Recorder.last);

    selectAt(&widget, 65);
    try std.testing.expectEqual(@as(usize, 2), widget.kind.segmented.selected);
}
