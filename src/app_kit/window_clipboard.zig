//! Plain-text clipboard for an app-kit window: the wl_data_device selection,
//! sent and received through nonblocking pipes with a size bound and a
//! deadline, progressed from the host's poll loop.
const std = @import("std");
const wl = @import("wayland").client.wl;
const c = @import("c_gfx");
const now = @import("ui").key_repeat.nowMs;
const a = std.heap.c_allocator;

pub const limit = 1024 * 1024;
pub const timeout_ms = 10_000;
/// Poll slots: one receive and this many concurrent sends.
pub const max_sends = 8;
pub const slots = 1 + max_sends;

const Offer = struct { proxy: *wl.DataOffer, utf8: bool = false, text: bool = false };
const Source = struct { owner: *Clipboard, proxy: *wl.DataSource, bytes: []u8 };
const Send = struct { fd: c_int, bytes: []u8, offset: usize = 0, started: i64 };

/// A finished paste; the caller frees it with `deinit`.
pub const Received = struct {
    bytes: std.ArrayList(u8) = .empty,
    pub fn deinit(self: *Received) void {
        self.bytes.deinit(a);
    }
};
const Receive = struct { fd: c_int, started: i64, bytes: std.ArrayList(u8) = .empty };

pub const Clipboard = struct {
    manager: ?*wl.DataDeviceManager = null,
    device: ?*wl.DataDevice = null,
    offers: std.ArrayList(*Offer) = .empty,
    selection: ?*Offer = null,
    source: ?*Source = null,
    sends: std.ArrayList(Send) = .empty,
    receive: ?Receive = null,

    pub fn bind(self: *Clipboard, registry: *wl.Registry, name: u32, version: u32) void {
        if (self.manager == null) self.manager = registry.bind(name, wl.DataDeviceManager, @min(version, 3)) catch null;
    }
    pub fn setup(self: *Clipboard, seat: *wl.Seat) void {
        const manager = self.manager orelse return;
        if (self.device != null) return;
        self.device = manager.getDataDevice(seat) catch return;
        self.device.?.setListener(*Clipboard, deviceEvent, self);
    }
    pub fn deinit(self: *Clipboard) void {
        self.endReceive();
        for (self.sends.items) |*s| endSend(s);
        self.sends.deinit(a);
        if (self.source) |s| destroySource(s);
        self.source = null;
        for (self.offers.items) |o| destroyOffer(o);
        self.offers.deinit(a);
        if (self.device) |d| d.release();
        if (self.manager) |m| m.destroy();
        self.* = .{};
    }

    /// Owns the selection with `bytes` from the input event `serial`.
    pub fn publish(self: *Clipboard, bytes: []const u8, serial: u32) !void {
        const manager = self.manager orelse return error.NoClipboard;
        const device = self.device orelse return error.NoClipboard;
        if (bytes.len > limit) return error.TooLarge;
        const source = try a.create(Source);
        errdefer a.destroy(source);
        const copy = try a.dupe(u8, bytes);
        errdefer a.free(copy);
        const proxy = try manager.createDataSource();
        source.* = .{ .owner = self, .proxy = proxy, .bytes = copy };
        proxy.setListener(*Source, sourceEvent, source);
        proxy.offer("text/plain;charset=utf-8");
        proxy.offer("text/plain");
        device.setSelection(proxy, serial);
        if (self.source) |old| destroySource(old);
        self.source = source;
    }

    /// Starts reading the selection. Our own selection is returned at once
    /// (valid until the next publish); another client's arrives through
    /// `dispatch`. Null when there is nothing to paste or it is pending.
    pub fn paste(self: *Clipboard) !?[]const u8 {
        self.endReceive();
        if (self.source) |s| return s.bytes;
        const offer = self.selection orelse return null;
        const mime: [:0]const u8 = if (offer.utf8) "text/plain;charset=utf-8" else if (offer.text) "text/plain" else return null;
        var fds: [2]c_int = undefined;
        if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return error.PipeFailed;
        defer _ = c.close(fds[1]);
        errdefer _ = c.close(fds[0]);
        if (c.fcntl(fds[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.PipeFailed;
        offer.proxy.receive(mime, fds[1]);
        self.receive = .{ .fd = fds[0], .started = now() };
        return null;
    }

    pub fn pollFds(self: *const Clipboard, fds: *[slots]c.struct_pollfd) void {
        fds[0] = .{ .fd = if (self.receive) |r| r.fd else -1, .events = c.POLLIN, .revents = 0 };
        for (fds[1..], 0..) |*fd, i| fd.* = .{ .fd = if (i < self.sends.items.len) self.sends.items[i].fd else -1, .events = c.POLLOUT, .revents = 0 };
    }

    /// Milliseconds until the oldest transfer's deadline, if any is running.
    pub fn timeoutMs(self: *const Clipboard, at: i64) ?i64 {
        var started: ?i64 = if (self.receive) |r| r.started else null;
        for (self.sends.items) |s| started = if (started) |old| @min(old, s.started) else s.started;
        return if (started) |first| @max(0, first + timeout_ms - at) else null;
    }

    /// Moves transfers along; returns a paste that completed. Failed, oversized
    /// and late transfers are dropped.
    pub fn dispatch(self: *Clipboard) ?Received {
        var result: ?Received = null;
        if (self.receive) |*r| {
            const done = now() - r.started >= timeout_ms or (readChunk(r) catch blk: {
                r.bytes.clearRetainingCapacity();
                break :blk true;
            });
            if (done) {
                // A late or failed paste ends empty and is not delivered.
                if (r.bytes.items.len > 0 and now() - r.started < timeout_ms) {
                    result = .{ .bytes = r.bytes };
                    r.bytes = .empty;
                }
                self.endReceive();
            }
        }
        var i: usize = 0;
        while (i < self.sends.items.len) {
            const s = &self.sends.items[i];
            const done = now() - s.started >= timeout_ms or (writeChunk(s) catch true);
            if (done) {
                var ended = self.sends.swapRemove(i);
                endSend(&ended);
            } else i += 1;
        }
        return result;
    }

    fn endReceive(self: *Clipboard) void {
        if (self.receive) |*r| {
            _ = c.close(r.fd);
            r.bytes.deinit(a);
        }
        self.receive = null;
    }
    fn readChunk(r: *Receive) !bool {
        var buf: [65536]u8 = undefined;
        // One chunk per loop iteration keeps a large offer fair to input.
        while (true) {
            const n = c.read(r.fd, &buf, buf.len);
            if (n == 0) return true;
            if (n < 0) switch (std.posix.errno(n)) {
                .INTR => continue,
                .AGAIN => return false,
                else => return error.ReadFailed,
            };
            if (r.bytes.items.len + @as(usize, @intCast(n)) > limit) return error.TooLarge;
            try r.bytes.appendSlice(a, buf[0..@intCast(n)]);
            return false;
        }
    }
    fn writeChunk(s: *Send) !bool {
        while (s.offset < s.bytes.len) {
            const n = c.write(s.fd, s.bytes.ptr + s.offset, @min(65536, s.bytes.len - s.offset));
            if (n < 0) switch (std.posix.errno(n)) {
                .INTR => continue,
                .AGAIN => return false,
                else => return error.WriteFailed,
            };
            if (n == 0) return error.WriteFailed;
            s.offset += @intCast(n);
            return s.offset == s.bytes.len;
        }
        return true;
    }
    fn endSend(s: *Send) void {
        _ = c.close(s.fd);
        a.free(s.bytes);
    }
    fn destroySource(s: *Source) void {
        s.proxy.destroy();
        a.free(s.bytes);
        a.destroy(s);
    }
    fn destroyOffer(o: *Offer) void {
        o.proxy.destroy();
        a.destroy(o);
    }

    fn offerEvent(_: *wl.DataOffer, event: wl.DataOffer.Event, offer: *Offer) void {
        switch (event) {
            .offer => |e| {
                const mime = std.mem.span(e.mime_type);
                if (std.mem.eql(u8, mime, "text/plain;charset=utf-8")) offer.utf8 = true;
                if (std.mem.eql(u8, mime, "text/plain")) offer.text = true;
            },
            else => {},
        }
    }
    fn deviceEvent(_: *wl.DataDevice, event: wl.DataDevice.Event, self: *Clipboard) void {
        switch (event) {
            .data_offer => |e| {
                const offer = a.create(Offer) catch return e.id.destroy();
                offer.* = .{ .proxy = e.id };
                self.offers.append(a, offer) catch {
                    e.id.destroy();
                    a.destroy(offer);
                    return;
                };
                e.id.setListener(*Offer, offerEvent, offer);
            },
            .selection => |e| {
                // Only the current selection is kept; drag offers are refused.
                self.selection = null;
                var i: usize = 0;
                while (i < self.offers.items.len) {
                    const offer = self.offers.items[i];
                    if (offer.proxy == e.id) {
                        self.selection = offer;
                        i += 1;
                    } else {
                        _ = self.offers.swapRemove(i);
                        destroyOffer(offer);
                    }
                }
            },
            .enter => |e| if (e.id) |offer| offer.accept(e.serial, null),
            else => {},
        }
    }
    fn sourceEvent(_: *wl.DataSource, event: wl.DataSource.Event, source: *Source) void {
        const self = source.owner;
        switch (event) {
            .send => |e| {
                const mime = std.mem.span(e.mime_type);
                const text = std.mem.eql(u8, mime, "text/plain") or std.mem.eql(u8, mime, "text/plain;charset=utf-8");
                if (!text or self.sends.items.len >= max_sends) {
                    _ = c.close(e.fd);
                    return;
                }
                const flags = c.fcntl(e.fd, c.F_GETFL, @as(c_int, 0));
                const bytes = a.dupe(u8, source.bytes) catch null;
                if (flags < 0 or c.fcntl(e.fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0 or bytes == null) {
                    if (bytes) |b| a.free(b);
                    _ = c.close(e.fd);
                    return;
                }
                self.sends.append(a, .{ .fd = e.fd, .bytes = bytes.?, .started = now() }) catch {
                    a.free(bytes.?);
                    _ = c.close(e.fd);
                };
            },
            .cancelled => {
                if (self.source == source) self.source = null;
                destroySource(source);
            },
            else => {},
        }
    }
};
