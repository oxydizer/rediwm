//! Barrier rules of `fifo.zig`, without wlroots. Sequence numbers stand for
//! wl_surface commits in order; `hold` mimics what the commit handler does.
const std = @import("std");
const Barriers = @import("fifo.zig").Barriers;
const gpa = @import("main.zig").gpa;

fn hold(b: *Barriers, seq: u32, set: bool, wait: bool) !bool {
    const waits_on = b.committed(seq, set, wait, false) orelse return false;
    try b.held.append(gpa, .{ .seq = seq, .waits_on = waits_on });
    return true;
}

fn releasedSeqs(b: *Barriers, out: []u32) []u32 {
    var n: usize = 0;
    while (b.nextReleasable()) |held| : (n += 1) out[n] = held.seq;
    return out[0..n];
}

test "a wait with no barrier ever set is ready" {
    var b: Barriers = .{};
    defer b.deinit();
    try std.testing.expect(!try hold(&b, 1, false, true));
    try std.testing.expect(!try hold(&b, 2, true, true));
}

test "two commits in one refresh: the second waits for a latch" {
    var b: Barriers = .{};
    defer b.deinit();
    // Commit 1 sets the barrier and applies at once.
    try std.testing.expect(!try hold(&b, 1, true, true));
    b.appliedState(1, true);
    // Commit 2 arrives before the output latched: held.
    try std.testing.expect(try hold(&b, 2, true, true));
    try std.testing.expect(b.waitingOnArmed());
    var buf: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), releasedSeqs(&b, &buf).len);
    // The latch clears it and releases commit 2, which sets a new barrier.
    try std.testing.expect(b.clear());
    try std.testing.expectEqualSlices(u32, &.{2}, releasedSeqs(&b, &buf));
    b.appliedState(2, true);
    // Commit 3 waits for the next latch, not the one that released 2.
    try std.testing.expect(try hold(&b, 3, true, true));
    try std.testing.expectEqual(@as(usize, 0), releasedSeqs(&b, &buf).len);
    try std.testing.expect(b.clear());
    try std.testing.expectEqualSlices(u32, &.{3}, releasedSeqs(&b, &buf));
}

test "a latch releases waits up to the next barrier only" {
    var b: Barriers = .{};
    defer b.deinit();
    _ = try hold(&b, 1, true, false);
    b.appliedState(1, true);
    try std.testing.expect(try hold(&b, 2, false, true)); // waits on 1
    try std.testing.expect(try hold(&b, 3, true, true)); // waits on 1, sets
    try std.testing.expect(try hold(&b, 4, false, true)); // waits on 3
    try std.testing.expect(b.clear());
    var buf: [4]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{ 2, 3 }, releasedSeqs(&b, &buf));
    b.appliedState(2, false);
    b.appliedState(3, true);
    try std.testing.expectEqual(@as(usize, 0), releasedSeqs(&b, &buf).len);
    try std.testing.expect(b.clear());
    try std.testing.expectEqualSlices(u32, &.{4}, releasedSeqs(&b, &buf));
}

test "a barrier still queued behind another lock (explicit sync) is waited for" {
    var b: Barriers = .{};
    defer b.deinit();
    // Commit 1 sets a barrier but waits on its acquire point: not applied.
    try std.testing.expect(!try hold(&b, 1, true, false));
    // Commit 2 waits: barrier_set alone (nothing applied) would let it pass.
    try std.testing.expect(try hold(&b, 2, true, true));
    // A latch before commit 1 applies clears nothing.
    try std.testing.expect(!b.clear());
    var buf: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), releasedSeqs(&b, &buf).len);
    try std.testing.expect(!b.waitingOnArmed());
    // The fence materializes: commit 1 applies; commit 2 still waits a latch.
    b.appliedState(1, true);
    try std.testing.expect(b.waitingOnArmed());
    try std.testing.expectEqual(@as(usize, 0), releasedSeqs(&b, &buf).len);
    try std.testing.expect(b.clear());
    try std.testing.expectEqualSlices(u32, &.{2}, releasedSeqs(&b, &buf));
}

test "a synchronized subsurface's wait is ignored, its set_barrier kept" {
    var b: Barriers = .{};
    defer b.deinit();
    try std.testing.expectEqual(@as(?u32, null), b.committed(1, true, false, true));
    b.appliedState(1, true);
    try std.testing.expectEqual(@as(?u32, null), b.committed(2, true, true, true));
    // Once desynchronized, waits count against the barrier it set.
    try std.testing.expectEqual(@as(?u32, 2), b.committed(3, false, true, false));
}

test "sequence numbers wrap" {
    var b: Barriers = .{};
    defer b.deinit();
    const max = std.math.maxInt(u32);
    _ = try hold(&b, max, true, false);
    b.appliedState(max, true);
    try std.testing.expect(try hold(&b, 0, true, true));
    try std.testing.expect(b.clear());
    var buf: [2]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{0}, releasedSeqs(&b, &buf));
    b.appliedState(0, true);
    try std.testing.expect(try hold(&b, 1, false, true));
    try std.testing.expectEqual(@as(usize, 0), releasedSeqs(&b, &buf).len);
}
