//! linux-dmabuf default feedback: the compositor's main device and the
//! format/modifier pairs it imports there. A buffer outside that set is a
//! protocol error on v4+, so nothing is created without checking here first.
const std = @import("std");
const zwp = @import("wayland").client.zwp;
const a = std.heap.c_allocator;
const native = @import("builtin").cpu.arch.endian();

pub const Pair = struct { format: u32, modifier: u64 };

pub const Feedback = struct {
    proxy: ?*zwp.LinuxDmabufFeedbackV1 = null,
    /// The device the compositor renders with (a `dev_t`).
    main_device: ?u64 = null,
    /// Pairs usable on the main device, from the last complete batch.
    pairs: std.ArrayList(Pair) = .empty,
    /// True once the first batch ended with `done`.
    ready: bool = false,

    table: []align(std.heap.page_size_min) const u8 = &.{},
    pending: std.ArrayList(Pair) = .empty,
    pending_main: ?u64 = null,
    tranche_device: ?u64 = null,

    pub fn listen(self: *Feedback, dmabuf: *zwp.LinuxDmabufV1) !void {
        const proxy = try dmabuf.getDefaultFeedback();
        proxy.setListener(*Feedback, event, self);
        self.proxy = proxy;
    }

    pub fn deinit(self: *Feedback) void {
        if (self.proxy) |proxy| proxy.destroy();
        self.unmap();
        self.pairs.deinit(a);
        self.pending.deinit(a);
    }

    pub fn supports(self: *const Feedback, format: u32, modifier: u64) bool {
        for (self.pairs.items) |pair| {
            if (pair.format == format and pair.modifier == modifier) return true;
        }
        return false;
    }

    fn unmap(self: *Feedback) void {
        if (self.table.len != 0) std.posix.munmap(self.table);
        self.table = &.{};
    }

    fn event(_: *zwp.LinuxDmabufFeedbackV1, ev: zwp.LinuxDmabufFeedbackV1.Event, self: *Feedback) void {
        switch (ev) {
            .format_table => |t| {
                defer _ = std.c.close(t.fd);
                self.unmap();
                self.table = std.posix.mmap(null, t.size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, t.fd, 0) catch &.{};
            },
            .main_device => |m| self.pending_main = devId(m.device.slice(u8)),
            .tranche_target_device => |t| self.tranche_device = devId(t.device.slice(u8)),
            .tranche_formats => |t| {
                // A tranche for another device (a scanout-only GPU) is not
                // something the compositor can sample.
                if (self.tranche_device == null or self.tranche_device != self.pending_main) return;
                for (t.indices.slice(u16)) |index| {
                    const entry = tableEntry(self.table, index) orelse continue;
                    self.pending.append(a, entry) catch return;
                }
            },
            .tranche_flags => {},
            .tranche_done => self.tranche_device = null,
            .done => {
                std.mem.swap(std.ArrayList(Pair), &self.pairs, &self.pending);
                self.pending.clearRetainingCapacity();
                self.main_device = self.pending_main;
                self.ready = true;
            },
        }
    }
};

/// A `dev_t` from a feedback array: its raw bytes, in the platform's size.
fn devId(bytes: []const u8) ?u64 {
    return switch (bytes.len) {
        8 => std.mem.readInt(u64, bytes[0..8], native),
        4 => std.mem.readInt(u32, bytes[0..4], native),
        else => null,
    };
}

/// Format table entries are 16 bytes: format (u32), padding, modifier (u64).
fn tableEntry(table: []const u8, index: u16) ?Pair {
    const at = @as(usize, index) * 16;
    if (at + 16 > table.len) return null;
    return .{
        .format = std.mem.readInt(u32, table[at..][0..4], native),
        .modifier = std.mem.readInt(u64, table[at + 8 ..][0..8], native),
    };
}

test "table entries and device ids decode in native order" {
    var table: [32]u8 = @splat(0);
    std.mem.writeInt(u32, table[16..20], 0x3231564e, native);
    std.mem.writeInt(u64, table[24..32], 0x0100000000000002, native);
    const pair = tableEntry(&table, 1).?;
    try std.testing.expectEqual(@as(u32, 0x3231564e), pair.format);
    try std.testing.expectEqual(@as(u64, 0x0100000000000002), pair.modifier);
    try std.testing.expect(tableEntry(&table, 2) == null);
    var dev: [8]u8 = undefined;
    std.mem.writeInt(u64, &dev, 0xe280, native);
    try std.testing.expectEqual(@as(?u64, 0xe280), devId(&dev));
}
