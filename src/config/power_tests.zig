const std = @import("std");
const loader = @import("loader.zig");
const power = @import("power.zig");

test "power source overrides preserve legacy idle settings and independent deadlines" {
    var config = try loader.parse(std.testing.allocator,
        \\[idle]
        \\blank_after_seconds = 600
        \\[power]
        \\enabled = true
        \\power_saver_percent = 15
        \\charge_limit = 80
        \\critical_action = "sleep"
        \\[power.on_battery]
        \\mode = "power_saver"
        \\brightness = 45
        \\keyboard_brightness = 0
        \\blank_after_seconds = 0
        \\suspend_after_seconds = 300
        \\lid_close = "suspend"
    , "test");
    defer config.deinit();
    try std.testing.expectEqual(@as(u32, 600), power.idle(config.power.plugged_in, config.idle).blank_after_seconds);
    const battery = power.idle(config.power.on_battery, config.idle);
    try std.testing.expectEqual(@as(u32, 0), battery.blank_after_seconds);
    try std.testing.expectEqual(@as(u32, 300), battery.suspend_after_seconds);
    try std.testing.expectEqual(@as(?u32, 0), config.power.on_battery.keyboard_brightness);
    try std.testing.expectEqual(@as(u32, 80), config.power.charge_limit);
}

test "power settings reject invalid percentages and unknown actions" {
    for ([_][]const u8{
        "[power.on_battery]\nbrightness = 101\n",
        "[power.on_battery]\nkeyboard_brightness = -2\n",
        "[power.on_battery]\nmode = \"turbo\"\n",
        "[power]\ncharge_limit = 49\n",
        "[power]\ncritical_action = \"erase\"\n",
        "[power]\nunknown = 1\n",
    }) |text| try std.testing.expectError(error.InvalidConfig, loader.parse(std.testing.allocator, text, "invalid"));
    var config = try loader.parse(std.testing.allocator, "[power.on_battery]\nkeyboard_brightness = -1\n", "test");
    defer config.deinit();
    try std.testing.expectEqual(null, config.power.on_battery.keyboard_brightness);
}
