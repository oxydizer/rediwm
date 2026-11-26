//! Fixed-capacity FIFOs. The pipeline mutex guards the rings, their byte
//! and duration budgets, and generation changes as one transaction.
const std = @import("std");
const c = @import("c_av");

pub fn Ring(comptime T: type, comptime capacity: usize) type {
    return struct {
        slots: [capacity]T = undefined,
        head: usize = 0,
        count: usize = 0,
        pub fn full(self: *const @This()) bool {
            return self.count == capacity;
        }
        pub fn push(self: *@This(), item: T) void {
            std.debug.assert(!self.full());
            self.slots[(self.head + self.count) % capacity] = item;
            self.count += 1;
        }
        pub fn first(self: *const @This()) ?T {
            return if (self.count == 0) null else self.slots[self.head];
        }
        pub fn pop(self: *@This()) ?T {
            const item = self.first() orelse return null;
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            return item;
        }
    };
}

const Packet = struct { ptr: *c.AVPacket, duration: i64 };
pub const Packets = struct {
    ring: Ring(Packet, 512) = .{},
    bytes: usize = 0,
    duration: i64 = 0,
    pub fn fits(self: *const Packets, size: usize, duration: i64) bool {
        // Admit one oversized packet to an empty queue so forward progress
        // doesn't depend on packetization or a particular bitrate.
        return self.ring.count == 0 or (!self.ring.full() and self.bytes + size <= 8 * 1024 * 1024 and self.duration +| duration <= 2 * std.time.ns_per_s);
    }
    pub fn push(self: *Packets, ptr: *c.AVPacket, duration: i64) void {
        self.ring.push(.{ .ptr = ptr, .duration = duration });
        self.bytes += @intCast(ptr.size);
        self.duration += duration;
    }
    pub fn pop(self: *Packets) ?*c.AVPacket {
        const p = self.ring.pop() orelse return null;
        self.bytes -= @intCast(p.ptr.size);
        self.duration -= p.duration;
        return p.ptr;
    }
    pub fn clear(self: *Packets) void {
        while (self.pop()) |p| {
            var ptr: ?*c.AVPacket = p;
            c.av_packet_free(&ptr);
        }
    }
};
pub const Picture = struct {
    frame: *c.AVFrame,
    pts: i64,
    pub fn free(self: Picture) void {
        var ptr: ?*c.AVFrame = self.frame;
        c.av_frame_free(&ptr);
    }
};

test "packet budgets, oversized progress and FIFO wrap" {
    var packets: Packets = .{};
    var pkt: c.AVPacket = std.mem.zeroes(c.AVPacket);
    pkt.size = 10 * 1024 * 1024;
    try std.testing.expect(packets.fits(@intCast(pkt.size), 1));
    packets.push(&pkt, 1);
    try std.testing.expect(!packets.fits(1, 1));
    _ = packets.pop();
    pkt.size = 1;
    packets.push(&pkt, 2 * std.time.ns_per_s);
    try std.testing.expect(!packets.fits(1, 1));
    var ring: Ring(u8, 2) = .{};
    ring.push(1);
    ring.push(2);
    _ = ring.pop();
    ring.push(3);
    try std.testing.expectEqual(2, ring.pop().?);
    try std.testing.expectEqual(3, ring.pop().?);
}
