// State transition for a `.swatch` widget. Selection across a row of
// swatches is exclusive, but a single swatch has no way to reach its
// siblings — `select` only fires the shared `on_select(color)` callback
// (see layout.zig's SwatchData doc comment); the caller's callback is
// responsible for updating every sibling's `selected` flag.
const std = @import("std");
const layout = @import("../layout.zig");
const Widget = layout.Widget;

pub fn select(widget: *Widget) void {
    switch (widget.kind) {
        .swatch => |data| data.on_select(data.owner, data.id, data.color),
        else => {},
    }
}

test "select fires on_select with this swatch's own color" {
    const Recorder = struct {
        var last: [4]f32 = .{ 0, 0, 0, 0 };
        fn call(_: ?*anyopaque, _: usize, c: [4]f32) void {
            last = c;
        }
    };
    var widget = Widget{ .kind = .{ .swatch = .{ .color = .{ 1, 0, 0, 1 }, .selected = false, .on_select = &Recorder.call } } };
    select(&widget);
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, Recorder.last);
}
