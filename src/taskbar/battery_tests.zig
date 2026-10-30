const std = @import("std");
const linux = std.os.linux;
const battery = @import("battery.zig");
const State = battery.State;
const Snapshot = battery.Snapshot;
const isSystemPowerSupplyUevent = battery.isSystemPowerSupplyUevent;
const drainUevents = battery.drainUevents;

test "battery percentage and external power are independent" {
    var s: Snapshot = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=82\nPOWER_SUPPLY_STATUS=Discharging\n");
    try std.testing.expectEqual(State{ .valid = true, .present = true, .external_power = false, .percent = 82, .discharging = true }, s.state());
    s.add("POWER_SUPPLY_TYPE=Mains\nPOWER_SUPPLY_ONLINE=1\n");
    try std.testing.expectEqual(State{ .valid = true, .present = true, .external_power = true, .percent = 82, .plugged = true, .discharging = true }, s.state());
    s = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=100\nPOWER_SUPPLY_STATUS=Full\n");
    s.add("POWER_SUPPLY_TYPE=USB\nPOWER_SUPPLY_ONLINE=1\n");
    try std.testing.expectEqual(State{ .valid = true, .present = true, .external_power = true, .percent = 100, .plugged = true, .full = true }, s.state());
}

test "only system power_supply uevents trigger a read" {
    try std.testing.expect(isSystemPowerSupplyUevent("change@/devices/platform/ACPI0003:00/power_supply/AC0\x00ACTION=change\x00SUBSYSTEM=power_supply\x00POWER_SUPPLY_NAME=AC0\x00POWER_SUPPLY_ONLINE=1\x00"));
    try std.testing.expect(isSystemPowerSupplyUevent("remove@/devices/x/power_supply/BAT1\x00ACTION=remove\x00SUBSYSTEM=power_supply"));
    try std.testing.expect(!isSystemPowerSupplyUevent("change@/devices/x/power_supply/hid-mouse\x00SUBSYSTEM=power_supply\x00POWER_SUPPLY_SCOPE=Device\x00"));
    try std.testing.expect(!isSystemPowerSupplyUevent("add@/devices/pci0000:00/usb1/1-1\x00ACTION=add\x00SUBSYSTEM=usb\x00"));
    try std.testing.expect(!isSystemPowerSupplyUevent("libudev\x00SUBSYSTEM=power_supply\x00"));
}

test "draining reports a queued power_supply event once and stops at EAGAIN" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0, &fds)));
    defer for (fds) |fd| {
        _ = std.posix.system.close(fd);
    };
    const usb = "add@/devices/usb1\x00SUBSYSTEM=usb\x00";
    const ac = "change@/devices/AC0/power_supply/AC0\x00SUBSYSTEM=power_supply\x00";
    try std.testing.expect(!drainUevents(fds[0]));
    _ = linux.sendto(fds[1], usb, usb.len, 0, null, 0);
    try std.testing.expect(!drainUevents(fds[0]));
    _ = linux.sendto(fds[1], ac, ac.len, 0, null, 0);
    _ = linux.sendto(fds[1], usb, usb.len, 0, null, 0);
    try std.testing.expect(drainUevents(fds[0]));
    try std.testing.expect(!drainUevents(fds[0]));
}

test "over-full capacity from a worn pack clamps to 100 instead of hiding" {
    var s: Snapshot = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=101\nPOWER_SUPPLY_STATUS=Discharging\n");
    try std.testing.expectEqual(State{ .valid = true, .present = true, .external_power = false, .percent = 100, .discharging = true }, s.state());
    s = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=300\n");
    try std.testing.expectEqual(@as(?u8, 100), s.state().percent);
}

test "absent peripheral and invalid batteries are hidden; charging works without AC entry" {
    var s: Snapshot = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=90\nPOWER_SUPPLY_SCOPE=Device\n");
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=90\nPOWER_SUPPLY_PRESENT=0\n");
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=-1\n");
    try std.testing.expectEqual(@as(?u8, null), s.state().percent);
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=0\nPOWER_SUPPLY_STATUS=Charging\n");
    try std.testing.expectEqual(State{ .valid = true, .present = true, .external_power = true, .percent = 0, .plugged = true, .charging = true }, s.state());
}

test "battery details use full versus design capacity and preserve missing readings" {
    var s: Snapshot = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=100\nPOWER_SUPPLY_STATUS=Full\nPOWER_SUPPLY_ENERGY_FULL=57000000\nPOWER_SUPPLY_ENERGY_FULL_DESIGN=90000000\nPOWER_SUPPLY_CYCLE_COUNT=482\n");
    try std.testing.expectEqual(@as(?u8, 63), s.state().health);
    try std.testing.expectEqual(@as(?f64, 57), s.state().full_wh);
    try std.testing.expectEqual(@as(?u32, 482), s.state().cycles);
    try std.testing.expectEqualStrings("Fully Charged", s.state().status());
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=80\n");
    try std.testing.expectEqual(@as(?u8, null), s.state().health);
    try std.testing.expectEqual(@as(?f64, null), s.state().full_wh);
    try std.testing.expectEqual(@as(?u32, null), s.state().cycles);
    try std.testing.expect(!s.state().full);
}

test "charge-only battery uses nominal voltage; invalid details stay unavailable" {
    var s: Snapshot = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=50\nPOWER_SUPPLY_CHARGE_FULL=4000000\nPOWER_SUPPLY_CHARGE_FULL_DESIGN=5000000\nPOWER_SUPPLY_VOLTAGE_MIN_DESIGN=12000000\nPOWER_SUPPLY_CYCLE_COUNT=0\n");
    try std.testing.expectEqual(@as(?u8, 80), s.state().health);
    try std.testing.expectEqual(@as(?f64, 48), s.state().full_wh);
    try std.testing.expectEqual(@as(?u32, 0), s.state().cycles);
    s = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=20\nPOWER_SUPPLY_ENERGY_FULL=-1\nPOWER_SUPPLY_ENERGY_FULL_DESIGN=0\nPOWER_SUPPLY_CYCLE_COUNT=-1\n");
    try std.testing.expectEqual(@as(?u8, null), s.state().health);
    try std.testing.expectEqual(@as(?f64, null), s.state().full_wh);
    try std.testing.expectEqual(@as(?u32, null), s.state().cycles);
}

test "time estimates use driver seconds then matching energy or charge rates" {
    const cases = .{
        .{ "Charging", "POWER_SUPPLY_TIME_TO_FULL_NOW=5100\n", @as(?u32, 85) },
        .{ "Discharging", "POWER_SUPPLY_TIME_TO_EMPTY_NOW=0\nPOWER_SUPPLY_TIME_TO_EMPTY_AVG=3600\n", @as(?u32, 60) },
        .{ "Charging", "POWER_SUPPLY_ENERGY_NOW=40000000\nPOWER_SUPPLY_ENERGY_FULL=57000000\nPOWER_SUPPLY_POWER_NOW=12000000\n", @as(?u32, 85) },
        .{ "Discharging", "POWER_SUPPLY_ENERGY_NOW=40000000\nPOWER_SUPPLY_POWER_NOW=12000000\n", @as(?u32, 200) },
        .{ "Charging", "POWER_SUPPLY_CHARGE_NOW=3000000\nPOWER_SUPPLY_CHARGE_FULL=4000000\nPOWER_SUPPLY_CURRENT_NOW=2000000\n", @as(?u32, 30) },
        .{ "Discharging", "POWER_SUPPLY_CHARGE_NOW=3000000\nPOWER_SUPPLY_CURRENT_NOW=2000000\n", @as(?u32, 90) },
        .{ "Discharging", "POWER_SUPPLY_TIME_TO_EMPTY_NOW=1\n", @as(?u32, 1) },
        .{ "Discharging", "POWER_SUPPLY_ENERGY_NOW=3000000\nPOWER_SUPPLY_POWER_NOW=0\n", @as(?u32, null) },
        .{ "Discharging", "POWER_SUPPLY_ENERGY_NOW=3000000\nPOWER_SUPPLY_CURRENT_NOW=2000000\n", @as(?u32, null) },
        .{ "Charging", "POWER_SUPPLY_ENERGY_NOW=60000000\nPOWER_SUPPLY_ENERGY_FULL=57000000\nPOWER_SUPPLY_POWER_NOW=12000000\n", @as(?u32, null) },
        .{ "Charging", "POWER_SUPPLY_TIME_TO_FULL_NOW=-1\n", @as(?u32, null) },
        .{ "Discharging", "POWER_SUPPLY_TIME_TO_EMPTY_NOW=18446744073709551615\n", @as(?u32, null) },
        .{ "Full", "POWER_SUPPLY_TIME_TO_FULL_NOW=3600\n", @as(?u32, null) },
        .{ "Not charging", "POWER_SUPPLY_TIME_TO_FULL_NOW=3600\n", @as(?u32, null) },
        .{ "Unknown", "POWER_SUPPLY_ENERGY_NOW=40000000\nPOWER_SUPPLY_POWER_NOW=12000000\n", @as(?u32, null) },
    };
    inline for (cases) |case| {
        var snapshot: Snapshot = .{};
        snapshot.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=72\nPOWER_SUPPLY_STATUS=" ++ case[0] ++ "\n" ++ case[1]);
        try std.testing.expectEqual(case[2], snapshot.state().remaining_minutes);
    }
}

test "fresh snapshots replace estimates and multiple packs do not expose one pack's time" {
    var s: Snapshot = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=72\nPOWER_SUPPLY_STATUS=Charging\nPOWER_SUPPLY_TIME_TO_FULL_NOW=5100\n");
    var buf: [192]u8 = undefined;
    try std.testing.expectEqualStrings("~1h 25min left", s.state().estimate(&buf).?);
    s = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=72\nPOWER_SUPPLY_STATUS=Discharging\nPOWER_SUPPLY_TIME_TO_EMPTY_NOW=1800\n");
    try std.testing.expectEqualStrings("~30min left", s.state().estimate(&buf).?);
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=90\nPOWER_SUPPLY_STATUS=Discharging\nPOWER_SUPPLY_TIME_TO_EMPTY_NOW=3600\n");
    try std.testing.expectEqual(@as(?u32, null), s.state().remaining_minutes);
    s = .{};
    s.add("POWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_CAPACITY=72\nPOWER_SUPPLY_STATUS=Charging\n");
    try std.testing.expectEqual(@as(?[]const u8, null), s.state().estimate(&buf));
}

test "low battery warns once at ten percent, rearms after recovery, and ignores missing data" {
    var warning: battery.Warning = .{};
    try std.testing.expectEqual(.clear, warning.update(.{ .percent = 11, .discharging = true }));
    try std.testing.expectEqual(.show, warning.update(.{ .percent = 10, .discharging = true }));
    // Repeated snapshots, another monitor, and further discharge do not repeat.
    try std.testing.expectEqual(.none, warning.update(.{ .percent = 10, .discharging = true }));
    try std.testing.expectEqual(.none, warning.update(.{}));
    try std.testing.expectEqual(.none, warning.update(.{ .percent = 0, .discharging = true }));
    try std.testing.expectEqual(.clear, warning.update(.{ .percent = 5, .charging = true, .plugged = true }));
    try std.testing.expectEqual(.show, warning.update(.{ .percent = 5, .discharging = true }));
    try std.testing.expectEqual(.clear, warning.update(.{ .percent = 12, .discharging = true }));
    try std.testing.expectEqual(.show, warning.update(.{ .percent = 9, .discharging = true }));
    try std.testing.expectEqual(.clear, warning.update(.{ .percent = 8, .plugged = true }));
    try std.testing.expectEqual(.clear, warning.update(.{ .percent = 8 }));
    // A weak adapter may still report a genuine discharge while online.
    try std.testing.expectEqual(.show, warning.update(.{ .percent = 8, .plugged = true, .discharging = true }));
}
