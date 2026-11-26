//! The reaper: a window's teardown never waits on a helper thread
//! (threading §12, "Teardown").
const std = @import("std");
const c = @import("c.zig").api;
const reaper_mod = @import("reaper.zig");
const worker_mod = @import("worker.zig");

/// A helper whose thread sits in a read that a stop request cannot cut short,
/// like a listing worker in a syscall on a hung mount.
const Parked = struct {
    gate: [2]c_int,
    thread: std.Thread = undefined,
    stop_requested: bool = false,
    order: *std.ArrayList(u8),
    tag: u8,

    fn start(self: *Parked) !void {
        self.thread = try std.Thread.spawn(.{}, park, .{self});
    }

    fn park(self: *Parked) void {
        var byte: u8 = 0;
        _ = c.read(self.gate[0], &byte, 1);
    }

    fn open(self: *Parked) void {
        const byte: u8 = 1;
        _ = c.write(self.gate[1], &byte, 1);
    }

    pub fn requestStop(self: *Parked) void {
        self.stop_requested = true;
    }

    fn finish(self: *Parked) void {
        self.thread.join();
        self.order.append(std.heap.c_allocator, self.tag) catch {};
    }
};

fn makeParked(order: *std.ArrayList(u8), tag: u8) !Parked {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    return .{ .gate = fds, .order = order, .tag = tag };
}

fn closeGate(p: *Parked) void {
    _ = c.close(p.gate[0]);
    _ = c.close(p.gate[1]);
}

test "retiring a parked helper returns at once; the reaper joins it once it can" {
    var reaper: reaper_mod.Reaper = undefined;
    try reaper.start();
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.heap.c_allocator);

    var parked = try makeParked(&order, 1);
    defer closeGate(&parked);
    try parked.start();

    reaper_mod.retire(&reaper, &parked, Parked.finish);
    try std.testing.expect(parked.stop_requested);
    try std.testing.expectEqual(@as(usize, 0), reaper.finishedCount());

    parked.open();
    reaper.deinit();
    try std.testing.expectEqualSlices(u8, &.{1}, order.items);
}

test "the reaper finishes helpers in the order they were handed over" {
    var reaper: reaper_mod.Reaper = undefined;
    try reaper.start();
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.heap.c_allocator);

    var first = try makeParked(&order, 1);
    defer closeGate(&first);
    var second = try makeParked(&order, 2);
    defer closeGate(&second);
    try first.start();
    try second.start();

    reaper_mod.retire(&reaper, &first, Parked.finish);
    reaper_mod.retire(&reaper, &second, Parked.finish);
    second.open();
    first.open();
    reaper.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, order.items);
}

test "without a reaper a helper is finished in place" {
    var order: std.ArrayList(u8) = .empty;
    defer order.deinit(std.heap.c_allocator);
    var parked = try makeParked(&order, 7);
    defer closeGate(&parked);
    try parked.start();
    parked.open();
    reaper_mod.retire(null, &parked, Parked.finish);
    try std.testing.expectEqualSlices(u8, &.{7}, order.items);
}

test "a listing worker handed to the reaper is stopped, joined and freed" {
    var reaper: reaper_mod.Reaper = undefined;
    try reaper.start();
    const worker = try worker_mod.Worker.init(std.heap.c_allocator, std.testing.io, std.process.Environ.empty, "/");
    reaper_mod.retire(&reaper, worker, worker_mod.Worker.deinit);
    reaper.deinit();
}
