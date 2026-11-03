const std = @import("std");
const Heading = @import("move_heading.zig");

test "drag heading stays attached through diagonal jitter but follows deliberate turns" {
    var heading: Heading = .{};
    _ = heading.update(10, 9);
    for (0..30) |i| {
        const dx: f32 = if (i % 2 == 0) 9 else 10;
        const dy: f32 = if (i % 2 == 0) 10 else 9;
        try std.testing.expect(!heading.update(dx, dy));
        try std.testing.expectEqual(@as(u2, 0), heading.value);
    }
    for (0..6) |_| _ = heading.update(0, 10);
    try std.testing.expectEqual(@as(u2, 2), heading.value);
    for (0..6) |_| _ = heading.update(-10, 0);
    try std.testing.expectEqual(@as(u2, 1), heading.value);
    for (0..6) |_| _ = heading.update(0, -10);
    try std.testing.expectEqual(@as(u2, 3), heading.value);
    const stopped = heading;
    try std.testing.expect(!heading.update(0, 0));
    try std.testing.expectEqualDeep(stopped, heading);
}
