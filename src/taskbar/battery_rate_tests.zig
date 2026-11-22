const std = @import("std");
const battery = @import("battery.zig");
const Estimator = @import("battery_rate.zig");

fn level(wh: f64, watts: ?f64) battery.Level {
    return .{ .unit = .energy, .now = wh * 1_000_000, .full = 60_000_000, .rate = if (watts) |w| w * 1_000_000 else null };
}

test "a level draining faster than the sampled rate wins once it has history" {
    // 12 W real drain, but every minute tick catches an idle 4 W reading.
    var e: Estimator = .{};
    var minutes: ?u32 = null;
    for (0..6) |i| {
        const t: f64 = 1000 + @as(f64, @floatFromInt(i)) * 60;
        minutes = e.feed(t, level(40 - 0.2 * @as(f64, @floatFromInt(i)), 4), .discharging);
        // The first minutes have only the reported rate: 40 Wh / 4 W.
        if (i == 0) try std.testing.expectEqual(@as(?u32, 600), minutes);
    }
    // 39 Wh left at 12 W: 195 min.
    try std.testing.expect(minutes.? >= 195 and minutes.? <= 196);
}

test "reported rates average as power, not as time" {
    var e: Estimator = .{};
    _ = e.feed(0, level(40, 4), .discharging);
    // Level unchanged (coarse firmware), rates 4 W and 16 W: 40 Wh / 10 W.
    try std.testing.expectEqual(@as(?u32, 240), e.feed(60, level(40, 16), .discharging));
}

test "coarse level steps wait for enough changes before the slope counts" {
    var e: Estimator = .{};
    var minutes: ?u32 = null;
    // 1 % steps of 0.6 Wh every 3 min (12 W), firmware rate claims 6 W.
    for (0..10) |i| {
        const step: f64 = @floatFromInt(i / 3);
        minutes = e.feed(@as(f64, @floatFromInt(i)) * 60, level(30 - 0.6 * step, 6), .discharging);
        if (i == 5) try std.testing.expect(minutes.? > 250);
    }
    try std.testing.expect(minutes.? < 170);
}

test "a gap, a direction change or a missing level starts over" {
    var e: Estimator = .{};
    for (0..6) |i| _ = e.feed(@as(f64, @floatFromInt(i)) * 60, level(40 - 0.2 * @as(f64, @floatFromInt(i)), 4), .discharging);
    // After suspend only the new reading's rate counts.
    try std.testing.expectEqual(@as(?u32, 585), e.feed(3600, level(39, 4), .discharging));
    // Charging needs the room left to full: 21 Wh at 30 W.
    try std.testing.expectEqual(@as(?u32, 42), e.feed(3660, level(39, 30), .charging));
    try std.testing.expectEqual(@as(?u32, null), e.feed(3720, level(39, 30), null));
    try std.testing.expectEqual(@as(usize, 0), e.len);
    try std.testing.expectEqual(@as(?u32, null), e.feed(3780, null, .discharging));
    try std.testing.expectEqual(@as(?u32, null), e.feed(3840, level(39, null), .discharging));
}

test "old readings leave the window and the buffer never overflows" {
    var e: Estimator = .{};
    for (0..200) |i| _ = e.feed(@as(f64, @floatFromInt(i)) * 10, level(50 - 0.01 * @as(f64, @floatFromInt(i)), 3.6), .discharging);
    try std.testing.expect(e.len <= 64);
    try std.testing.expect(e.samples[e.len - 1].t - e.samples[0].t <= Estimator.window_s);
}

test "snapshot levels sum packs with the same units and drop mixed ones" {
    var s: battery.Snapshot = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=50\nPOWER_SUPPLY_STATUS=Discharging\nPOWER_SUPPLY_ENERGY_NOW=20000000\nPOWER_SUPPLY_ENERGY_FULL=40000000\nPOWER_SUPPLY_POWER_NOW=5000000\n");
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=50\nPOWER_SUPPLY_STATUS=Discharging\nPOWER_SUPPLY_ENERGY_NOW=10000000\nPOWER_SUPPLY_ENERGY_FULL=20000000\nPOWER_SUPPLY_POWER_NOW=1000000\n");
    try std.testing.expectEqual(@as(?battery.Level, .{ .unit = .energy, .now = 30_000_000, .full = 60_000_000, .rate = 6_000_000 }), s.level());
    try std.testing.expect(!s.driver_time);
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=50\nPOWER_SUPPLY_CHARGE_NOW=1000000\n");
    try std.testing.expectEqual(@as(?battery.Level, null), s.level());
    s = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=50\nPOWER_SUPPLY_STATUS=Discharging\nPOWER_SUPPLY_CHARGE_NOW=2000000\nPOWER_SUPPLY_CURRENT_NOW=-1000000\nPOWER_SUPPLY_TIME_TO_EMPTY_NOW=3600\n");
    try std.testing.expectEqual(@as(?battery.Level, .{ .unit = .charge, .now = 2_000_000, .full = null, .rate = 1_000_000 }), s.level());
    try std.testing.expect(s.driver_time);
}
