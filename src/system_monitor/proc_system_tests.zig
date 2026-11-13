const std = @import("std");
const proc = @import("proc.zig");
const linux = @import("proc_linux_system.zig");
const header = "Inter-| Receive | Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n";
const ethernet = "eth0: 1000 1 0 0 0 0 0 0 2000 2 0 0 0 0 0 0\n";
const wifi = "wlan0: 500 1 0 0 0 0 0 0 300 2 0 0 0 0 0 0\n";

test "network totals exclude loopback and compare interface sets independent of order" {
    const before = linux.parseNetwork(header ++ ethernet ++ wifi ++ "lo: 9999 0 0 0 0 0 0 0 9999 0 0 0 0 0 0 0\n").?;
    const reordered = linux.parseNetwork(header ++ wifi ++ ethernet).?;
    try std.testing.expectEqual(@as(u64, 1500), before.received);
    try std.testing.expectEqual(@as(u64, 2300), before.sent);
    try std.testing.expectEqual(before, reordered);
    const unchanged = proc.networkRate(before, reordered, 1_000_000_000).?;
    try std.testing.expectEqual(@as(f64, 0), unchanged.received);
    var after = before;
    after.received += 3000;
    after.sent += 1000;
    const rate = proc.networkRate(before, after, 2_000_000_000).?;
    try std.testing.expectEqual(@as(f64, 1500), rate.received);
    try std.testing.expectEqual(@as(f64, 500), rate.sent);
    try std.testing.expect(proc.networkRate(after, before, 1_000_000_000) == null);
    try std.testing.expect(proc.networkRate(before, after, 0) == null);
    try std.testing.expect(proc.networkRate(linux.parseNetwork(header ++ ethernet).?, after, 1_000_000_000) == null);
    try std.testing.expect(linux.parseNetwork(header ++ "eth0: 1 2 3\n") == null);
    try std.testing.expect(linux.parseNetwork("unavailable") == null);
}

test "load averages and the thread count come from /proc/loadavg" {
    var system: proc.System = .{};
    linux.parseLoad("0.52 0.58 1.50 2/1234 5678\n", &system);
    try std.testing.expectEqual([3]f64{ 0.52, 0.58, 1.50 }, system.load.?);
    try std.testing.expectEqual(@as(u64, 1234), system.threads.?);
    var broken: proc.System = .{};
    linux.parseLoad("0.5 nan", &broken);
    try std.testing.expect(broken.load == null and broken.threads == null);
}
