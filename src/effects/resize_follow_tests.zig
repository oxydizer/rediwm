const std = @import("std");
const Follow = @import("resize_follow.zig");

test "resize follows behind, finishes exactly and never overshoots on reversal" {
    var follow = Follow.init(.{ .width = 400, .height = 300 }, 1000);
    follow.retarget(.{ .width = 600, .height = 400 }, 1000, 1);
    try std.testing.expectEqual(@as(i32, 400), follow.value(1000, 1).width);
    const middle = follow.value(1055, 1);
    try std.testing.expect(middle.width > 400 and middle.width < 500);
    try std.testing.expect(follow.pending(1055, 1));
    follow.retarget(.{ .width = 320, .height = 240 }, 1055, 1);
    try std.testing.expectEqual(middle, follow.value(1055, 1));
    for (0..9) |i| {
        const size = follow.value(1055 + @as(i64, @intCast(i)) * 100, 1);
        try std.testing.expect(size.width >= 320 and size.width <= middle.width);
        try std.testing.expect(size.height >= 240 and size.height <= middle.height);
    }
    try std.testing.expectEqual(follow.target, follow.value(1855, 1));
    try std.testing.expect(!follow.pending(1855, 1));
    try std.testing.expectEqual(follow.target, follow.value(1055, 0));
}

test "resize sampling is independent of frame rate and respects animation speed" {
    var a = Follow.init(.{ .width = 400, .height = 300 }, 0);
    a.retarget(.{ .width = 800, .height = 500 }, 0, 1);
    const b = a;
    for (0..100) |i| _ = a.value(@intCast(i * 2), 1);
    try std.testing.expectEqual(b.value(200, 1), a.value(200, 1));
    try std.testing.expectEqual(a.value(200, 1), a.value(100, 2));
}
