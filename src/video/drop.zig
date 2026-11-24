//! Accept copy-only URI lists. Read the pipe after returning to dispatch;
//! a source in another client may still be waiting for its send event.
const std = @import("std");
const wl = @import("wayland").client.wl;
const c = @import("c");
const transfer = @import("../files/transfer.zig");
const clipboard = @import("../files/clipboard.zig");
const a = std.heap.c_allocator;
const mime = "text/uri-list";

const Offer = struct {
    proxy: *wl.DataOffer,
    uri: bool = false,
    copy: bool = false,

    fn event(_: *wl.DataOffer, ev: wl.DataOffer.Event, self: *Offer) void {
        switch (ev) {
            .offer => |e| if (std.mem.eql(u8, std.mem.span(e.mime_type), mime)) {
                self.uri = true;
            },
            .action => |e| self.copy = e.dnd_action.copy,
            else => {},
        }
    }
    fn destroy(self: *Offer) void {
        self.proxy.destroy();
        a.destroy(self);
    }
};

pub const Drop = struct {
    manager: ?*wl.DataDeviceManager = null,
    device: ?*wl.DataDevice = null,
    drag: ?*Offer = null,
    reading: ?*Offer = null,
    fd: c_int = -1,
    deadline: ?i64 = null,
    bytes: std.ArrayList(u8) = .empty,

    pub fn bind(self: *Drop, seat: *wl.Seat) !void {
        const mgr = self.manager orelse return;
        self.device = try mgr.getDataDevice(seat);
        self.device.?.setListener(*Drop, event, self);
    }

    pub fn deinit(self: *Drop) void {
        self.end(false);
        if (self.drag) |offer| offer.destroy();
        if (self.device) |dev| if (dev.getVersion() >= 2) dev.release() else dev.destroy();
        if (self.manager) |mgr| mgr.destroy();
    }

    fn event(_: *wl.DataDevice, ev: wl.DataDevice.Event, self: *Drop) void {
        switch (ev) {
            .data_offer => |e| {
                const offer = a.create(Offer) catch {
                    e.id.destroy();
                    return;
                };
                offer.* = .{ .proxy = e.id };
                e.id.setListener(*Offer, Offer.event, offer);
            },
            .selection => |e| if (fromProxy(e.id)) |offer| offer.destroy(),
            .enter => |e| {
                if (self.drag) |old| old.destroy();
                self.drag = fromProxy(e.id);
                const offer = self.drag orelse return;
                const accept = offer.uri and self.reading == null;
                offer.proxy.accept(e.serial, if (accept) mime else null);
                if (offer.proxy.getVersion() >= 3) offer.proxy.setActions(.{ .copy = accept }, .{ .copy = accept });
            },
            .leave => {
                if (self.drag) |offer| offer.destroy();
                self.drag = null;
            },
            .motion => {},
            .drop => {
                const offer = self.drag orelse return;
                self.drag = null;
                if (self.reading != null or !offer.uri or (offer.proxy.getVersion() >= 3 and !offer.copy)) return offer.destroy();
                var pipe: [2]c_int = undefined;
                if (c.pipe2(&pipe, c.O_CLOEXEC) != 0) return offer.destroy();
                defer _ = c.close(pipe[1]);
                if (c.fcntl(pipe[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) {
                    _ = c.close(pipe[0]);
                    return offer.destroy();
                }
                self.fd = pipe[0];
                self.reading = offer;
                self.deadline = @import("clock.zig").now() + transfer.timeout_ms * std.time.ns_per_ms;
                offer.proxy.receive(mime, pipe[1]);
            },
        }
    }

    fn fromProxy(proxy: ?*wl.DataOffer) ?*Offer {
        return @ptrCast(@alignCast((proxy orelse return null).getUserData()));
    }

    pub fn end(self: *Drop, accepted: bool) void {
        if (self.reading) |offer| {
            if (accepted and offer.proxy.getVersion() >= 3) offer.proxy.finish();
            offer.destroy();
        }
        self.reading = null;
        self.deadline = null;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        self.bytes.clearAndFree(a);
    }

    pub fn read(self: *Drop) !?[:0]u8 {
        errdefer self.end(false);
        var buf: [16384]u8 = undefined;
        const n = c.read(self.fd, &buf, buf.len);
        if (n < 0) return switch (std.posix.errno(n)) {
            .INTR, .AGAIN => null,
            else => error.DropFailed,
        };
        if (n > 0) {
            if (self.bytes.items.len + @as(usize, @intCast(n)) > transfer.limit) return error.DropTooLarge;
            try self.bytes.appendSlice(a, buf[0..@intCast(n)]);
            return null;
        }
        const decoded = try clipboard.decodeUris(a, self.bytes.items);
        defer decoded.deinit(a);
        if (decoded.paths.len == 0) return error.NoLocalFile;
        return try a.dupeSentinel(u8, decoded.paths[0], 0);
    }
};
