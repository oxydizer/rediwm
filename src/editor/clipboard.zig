//! Regular Wayland clipboard with bounded, nonblocking pipes and deadlines.
const std = @import("std");
const wl = @import("wayland").client.wl;
const c = @import("../files/c.zig").api;
const transfer = @import("../files/transfer.zig");
const App = @import("app.zig").App;
const now = @import("ui").key_repeat.nowMs;
const a = std.heap.c_allocator;
const Offer = struct { proxy: *wl.DataOffer, utf8: bool = false, text: bool = false };
const Source = struct { owner: *Clipboard, proxy: *wl.DataSource, bytes: []u8 };
pub const Clipboard = struct {
    app: *App,
    manager: ?*wl.DataDeviceManager = null,
    device: ?*wl.DataDevice = null,
    offers: std.ArrayList(*Offer) = .empty,
    selection: ?*Offer = null,
    source: ?*Source = null,
    sends: std.ArrayList(transfer.Send) = .empty,
    receive: ?transfer.Receive = null,
    revision: usize = 0,
    tab_id: usize = 0,
    cursor: usize = 0,
    anchor: usize = 0,
    find: bool = false,
    pub fn deinit(self: *Clipboard) void {
        if (self.receive) |*r| r.deinit();
        for (self.sends.items) |*s| s.deinit();
        self.sends.deinit(a);
        if (self.source) |s| {
            s.proxy.destroy();
            a.free(s.bytes);
            a.destroy(s);
        }
        for (self.offers.items) |o| {
            o.proxy.destroy();
            a.destroy(o);
        }
        self.offers.deinit(a);
        if (self.device) |d| d.release();
        if (self.manager) |m| m.destroy();
    }
    pub fn setup(self: *Clipboard, seat: *wl.Seat) !void {
        if (self.manager) |m| {
            self.device = try m.getDataDevice(seat);
            self.device.?.setListener(*Clipboard, deviceEvent, self);
        }
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
                const offer = a.create(Offer) catch {
                    e.id.destroy();
                    return;
                };
                offer.* = .{ .proxy = e.id };
                self.offers.append(a, offer) catch {
                    e.id.destroy();
                    a.destroy(offer);
                    return;
                };
                e.id.setListener(*Offer, offerEvent, offer);
            },
            .selection => |e| {
                self.selection = null;
                var i: usize = 0;
                while (i < self.offers.items.len) {
                    const offer = self.offers.items[i];
                    if (offer.proxy == e.id) {
                        self.selection = offer;
                        i += 1;
                    } else {
                        _ = self.offers.swapRemove(i);
                        offer.proxy.destroy();
                        a.destroy(offer);
                    }
                }
            },
            .enter => |e| {
                if (e.id) |offer| offer.accept(e.serial, null);
            },
            else => {},
        }
    }
    fn sourceEvent(_: *wl.DataSource, event: wl.DataSource.Event, source: *Source) void {
        const self = source.owner;
        switch (event) {
            .send => |e| {
                const mime = std.mem.span(e.mime_type);
                if ((!std.mem.eql(u8, mime, "text/plain") and !std.mem.eql(u8, mime, "text/plain;charset=utf-8")) or self.sends.items.len >= 8) {
                    _ = c.close(e.fd);
                    return;
                }
                var send = transfer.Send.init(e.fd, source.bytes, now()) catch return;
                self.sends.append(a, send) catch {
                    send.deinit();
                };
            },
            .cancelled => {
                if (self.source == source) self.source = null;
                source.proxy.destroy();
                a.free(source.bytes);
                a.destroy(source);
            },
            else => {},
        }
    }
    pub fn sync(self: *Clipboard, serial: u32) void {
        if (self.revision != self.app.clipboard_revision) {
            self.revision = self.app.clipboard_revision;
            self.publish(serial) catch {
                self.app.message("Could not copy text (clipboard limit is 1 MiB).");
            };
        }
        if (self.app.paste_requested) {
            self.app.paste_requested = false;
            self.paste() catch {
                self.app.message("Could not paste text.");
            };
        }
    }
    fn publish(self: *Clipboard, serial: u32) !void {
        const manager = self.manager orelse return;
        const device = self.device orelse return;
        if (self.app.clipboard.items.len > transfer.limit) return error.TooLarge;
        const source = try a.create(Source);
        errdefer a.destroy(source);
        const bytes = try a.dupe(u8, self.app.clipboard.items);
        errdefer a.free(bytes);
        const proxy = try manager.createDataSource();
        source.* = .{ .owner = self, .proxy = proxy, .bytes = bytes };
        proxy.setListener(*Source, sourceEvent, source);
        proxy.offer("text/plain;charset=utf-8");
        proxy.offer("text/plain");
        device.setSelection(proxy, serial);
        if (self.source) |old| {
            old.proxy.destroy();
            a.free(old.bytes);
            a.destroy(old);
        }
        self.source = source;
    }
    fn paste(self: *Clipboard) !void {
        if (self.receive) |*r| r.deinit();
        self.receive = null;
        if (self.source) |s| {
            self.app.pasteText(s.bytes);
            return;
        }
        const offer = self.selection orelse return;
        const mime: [:0]const u8 = if (offer.utf8) "text/plain;charset=utf-8" else if (offer.text) "text/plain" else return;
        var fds: [2]c_int = undefined;
        if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return error.PipeFailed;
        defer _ = c.close(fds[1]);
        errdefer _ = c.close(fds[0]);
        if (c.fcntl(fds[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.PipeFailed;
        self.receive = .{ .fd = fds[0], .text = true, .revision = self.app.editRevision(), .directory = try a.dupe(u8, ""), .started = now() };
        self.tab_id = self.app.tabId();
        self.cursor = self.app.document().cursor;
        self.anchor = self.app.document().anchor;
        self.find = self.app.find_open;
        offer.proxy.receive(mime, fds[1]);
    }
    pub fn addPoll(self: *Clipboard, fds: []c.struct_pollfd) usize {
        var count: usize = 0;
        if (self.receive) |r| {
            fds[count] = .{ .fd = r.fd, .events = c.POLLIN, .revents = 0 };
            count += 1;
        }
        for (self.sends.items) |s| {
            fds[count] = .{ .fd = s.fd, .events = c.POLLOUT, .revents = 0 };
            count += 1;
        }
        return count;
    }
    pub fn timeout(self: *Clipboard, initial: c_int) c_int {
        var ms = initial;
        if (self.receive) |r| ms = deadline(ms, r.started);
        for (self.sends.items) |s| ms = deadline(ms, s.started);
        return ms;
    }
    fn deadline(current: c_int, started: i64) c_int {
        const remaining: c_int = @intCast(@max(0, transfer.timeout_ms - (now() - started)));
        return if (current < 0) remaining else @min(current, remaining);
    }
    pub fn dispatch(self: *Clipboard) void {
        if (self.receive) |*r| {
            const expired = now() - r.started >= transfer.timeout_ms;
            var failed = false;
            const done = if (expired) true else r.read() catch blk: {
                failed = true;
                self.app.message("Clipboard transfer failed or exceeded 1 MiB.");
                break :blk true;
            };
            if (done) {
                if (!expired and !failed and self.app.tabId() == self.tab_id and self.app.editRevision() == r.revision and self.app.document().cursor == self.cursor and self.app.document().anchor == self.anchor and self.app.find_open == self.find) self.app.pasteText(r.bytes.items);
                r.deinit();
                self.receive = null;
            }
        }
        var i: usize = 0;
        while (i < self.sends.items.len) {
            const s = &self.sends.items[i];
            if (now() - s.started >= transfer.timeout_ms or (s.write() catch true)) {
                var ended = self.sends.swapRemove(i);
                ended.deinit();
            } else i += 1;
        }
    }
};
