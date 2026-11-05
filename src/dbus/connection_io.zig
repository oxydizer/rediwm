//! Wire I/O: serials, sending, dispatching incoming messages, reading (with fds), writing, and the loop's fd and timer callbacks.

const std = @import("std");
const wl = @import("wayland").server.wl;
const c = std.posix.system;
const wire = @import("wire.zig");
const log = std.log.scoped(.dbus);
const connection_mod = @import("connection.zig");
const Connection = connection_mod.Connection;
const queue_limit = connection_mod.queue_limit;
const eq = connection_mod.eq;
const nowMs = connection_mod.nowMs;
const SignalHandler = Connection.SignalHandler;

pub fn allocateSerial(self: *Connection) u32 {
    while (true) {
        const value = self.next_serial;
        self.next_serial +%= 1;
        if (self.next_serial == 0) self.next_serial = 1;
        var used = false;
        for (self.pending.items) |p| if (p.serial == value) {
            used = true;
            break;
        };
        if (!used) return value;
    }
}

pub fn send(self: *Connection, kind: wire.Kind, flags: u8, value: u32, h: wire.Headers, body: *const wire.Writer) !void {
    if (self.closed) return error.Disconnected;
    var message = try wire.encode(self.allocator, kind, flags, value, h, body);
    defer message.deinit();
    if (message.bytes.items.len > queue_limit - (self.write_buf.items.len - self.write_offset)) return error.QueueFull;
    self.compactWrites();
    const old_len = self.write_buf.items.len;
    try self.write_buf.appendSlice(self.allocator, message.bytes.items);
    errdefer self.write_buf.items.len = old_len;
    try self.interest();
}

pub fn compactWrites(self: *Connection) void {
    const remaining = self.write_buf.items[self.write_offset..];
    std.mem.copyForwards(u8, self.write_buf.items[0..remaining.len], remaining);
    if (self.wipe_buffers) std.crypto.secureZero(u8, self.write_buf.items[remaining.len..]);
    self.write_buf.items.len = remaining.len;
    self.write_offset = 0;
}

pub fn interest(self: *Connection) !void {
    if (self.source) |s| try s.fdUpdate(.{ .readable = true, .writable = self.write_buf.items.len > self.write_offset });
}

pub fn dispatch(self: *Connection, message: wire.Message) !void {
    if (message.kind == .method_return or message.kind == .error_reply) {
        for (self.pending.items, 0..) |p, i| {
            if (p.serial != message.headers.reply_serial.?) continue;
            _ = self.pending.orderedRemove(i);
            if (p.hello) {
                if (message.kind != .method_return or !eq(message.headers.signature, "s")) {
                    self.complete(p, error.InvalidReply);
                    self.close();
                    return;
                }
                var body = message.body;
                const name = try body.string();
                if (name.len < 3 or name[0] != ':') {
                    self.complete(p, error.InvalidReply);
                    self.close();
                    return;
                }
                self.unique_name = self.allocator.dupe(u8, name) catch {
                    self.complete(p, error.OutOfMemory);
                    self.close();
                    return;
                };
            }
            self.complete(p, message);
            return;
        }
    } else if (message.kind == .method_call) {
        for (self.handlers.items) |h| {
            if (eq(h.path, message.headers.path.?) and eq(h.member, message.headers.member.?) and
                (message.headers.interface == null or eq(h.interface, message.headers.interface.?)))
            {
                self.callback_depth += 1;
                defer self.callback_depth -= 1;
                h.callback(h.owner, self, message) catch |err| {
                    if (!self.closed) try self.replyError(message, "org.freedesktop.DBus.Error.InvalidArgs", @errorName(err));
                };
                return;
            }
        }
        try self.replyError(message, "org.freedesktop.DBus.Error.UnknownMethod", "No matching method");
    } else if (message.kind == .signal) {
        if (self.signals.items.len == 0) return;
        var inline_buf: [16]SignalHandler = undefined;
        const snapshot = if (self.signals.items.len <= inline_buf.len) blk: {
            @memcpy(inline_buf[0..self.signals.items.len], self.signals.items);
            break :blk inline_buf[0..self.signals.items.len];
        } else self.allocator.dupe(SignalHandler, self.signals.items) catch return;
        defer if (snapshot.ptr != &inline_buf) self.allocator.free(snapshot);

        for (snapshot) |h| {
            if (self.closed) break;
            if (!self.hasSignal(h)) continue;
            if (h.sender) |s| if (message.headers.sender == null or !eq(s, message.headers.sender.?)) continue;
            if (h.path) |p| if (message.headers.path == null or !eq(p, message.headers.path.?)) continue;
            if (h.interface) |iface| if (message.headers.interface == null or !eq(iface, message.headers.interface.?)) continue;
            if (h.member) |m| if (message.headers.member == null or !eq(m, message.headers.member.?)) continue;
            {
                self.callback_depth += 1;
                defer self.callback_depth -= 1;
                h.callback(h.owner, self, message) catch |err| {
                    log.warn("signal callback error: {}", .{err});
                };
            }
        }
    }
}

/// Where a control message's data starts, CMSG_LEN(0): the header padded to
/// the machine word. FreeBSD's header is 12 bytes and its data starts at 16,
/// as on Linux, where the header is already 16.
pub const cmsg_data = std.mem.alignForward(usize, @sizeOf(c.cmsghdr), @sizeOf(usize));

pub fn closeReadFds(self: *Connection) void {
    for (self.read_fds[0..self.read_fd_count]) |fd| _ = c.close(fd);
    self.read_fd_count = 0;
}

pub fn readWithFds(self: *Connection) !void {
    // Never cross a message boundary: ancillary FDs belong to this frame.
    // Bound each event's work, and close even unclaimed or malformed replies.
    const target = (try wire.frameLength(self.read_buf.items)) orelse 16;
    var buf: [16384]u8 = undefined;
    var iov: std.posix.iovec = .{ .base = &buf, .len = @min(buf.len, target - self.read_buf.items.len) };
    var control: [cmsg_data + 16 * @sizeOf(c_int)]u8 align(@alignOf(c.cmsghdr)) = undefined;
    var msg: c.msghdr = std.mem.zeroes(c.msghdr);
    msg.iov = @ptrCast(&iov);
    msg.iovlen = 1;
    msg.control = &control;
    msg.controllen = control.len;
    const n = c.recvmsg(self.fd, &msg, std.posix.MSG.CMSG_CLOEXEC);
    if (n < 0) {
        const err = std.posix.errno(n);
        if (err == .AGAIN or err == .INTR) return;
        return error.ReadFailed;
    }
    var overflow = false;
    var offset: usize = 0;
    while (offset + @sizeOf(c.cmsghdr) <= msg.controllen) {
        const header: *const c.cmsghdr = @ptrCast(@alignCast(&control[offset]));
        if (header.len < @sizeOf(c.cmsghdr) or header.len > msg.controllen - offset) return error.InvalidReply;
        if (header.level == std.posix.SOL.SOCKET and header.type == c.SCM.RIGHTS) {
            const data = control[@min(offset + cmsg_data, offset + header.len) .. offset + header.len];
            const fds: []const c_int = std.mem.bytesAsSlice(c_int, @as([]align(@alignOf(c_int)) const u8, @alignCast(data)));
            for (fds) |fd| {
                if (self.read_fd_count == self.read_fds.len) {
                    _ = c.close(fd);
                    overflow = true;
                } else {
                    self.read_fds[self.read_fd_count] = fd;
                    self.read_fd_count += 1;
                }
            }
        }
        offset += std.mem.alignForward(usize, header.len, @sizeOf(usize));
    }
    if (overflow or msg.flags & std.posix.MSG.CTRUNC != 0) return error.TooManyFds;
    if (n == 0) return error.Disconnected;
    try self.read_buf.appendSlice(self.allocator, buf[0..@intCast(n)]);
    const len = (try wire.frameLength(self.read_buf.items)) orelse return;
    if (self.read_buf.items.len < len) return;
    defer self.closeReadFds();
    try self.dispatch(try wire.decodeWithFds(self.read_buf.items, self.read_fds[0..self.read_fd_count]));
    self.read_buf.clearRetainingCapacity();
}

pub fn read(self: *Connection) !void {
    if (self.receive_fds) return self.readWithFds();
    // One chunk per event prevents a busy peer starving compositor frames.
    var buf: [16384]u8 = undefined;
    const n = c.read(self.fd, &buf, buf.len);
    if (n < 0) {
        const err = std.posix.errno(n);
        if (err == .AGAIN or err == .INTR) return;
        return error.ReadFailed;
    }
    if (n == 0) return error.Disconnected;
    if (@as(usize, @intCast(n)) > wire.max_message - self.read_buf.items.len) return error.TooLarge;
    try self.read_buf.appendSlice(self.allocator, buf[0..@intCast(n)]);
    var consumed: usize = 0;
    while (!self.closed) {
        const bytes = self.read_buf.items[consumed..];
        const len = (try wire.frameLength(bytes)) orelse break;
        if (bytes.len < len) break;
        try self.dispatch(try wire.decode(bytes[0..len]));
        consumed += len;
    }
    const rest = self.read_buf.items[consumed..];
    std.mem.copyForwards(u8, self.read_buf.items[0..rest.len], rest);
    self.read_buf.items.len = rest.len;
}

/// Try to drain queued output without waiting or dispatching callbacks.
/// Shutdown users may flush best-effort messages before closing; EAGAIN
/// leaves bytes queued, so delivery is not guaranteed by this operation.
pub fn flush(self: *Connection) !void {
    if (self.closed) return error.Disconnected;
    try self.write();
    try self.interest();
}

pub fn write(self: *Connection) !void {
    const data = self.write_buf.items[self.write_offset..];
    if (data.len == 0) return;
    const n = c.send(self.fd, data.ptr, data.len, std.posix.MSG.NOSIGNAL);
    if (n < 0) {
        const err = std.posix.errno(n);
        if (err == .AGAIN or err == .INTR) return;
        return error.WriteFailed;
    }
    if (n == 0) return error.Disconnected;
    self.write_offset += @intCast(n);
    self.compactWrites();
}

pub fn onFd(_: c_int, mask: wl.EventMask, self: *Connection) c_int {
    if (mask.readable) self.read() catch |err| {
        log.warn("connection closed: {}", .{err});
        self.close();
    };
    if (!self.closed and mask.writable) self.write() catch {
        self.close();
    };
    if (mask.hangup or mask.@"error") self.close();
    if (!self.closed) self.interest() catch {
        self.close();
    };
    return 0;
}

pub fn onTimer(self: *Connection) c_int {
    const now = nowMs();
    var i: usize = 0;
    while (!self.closed and i < self.pending.items.len) {
        if (self.pending.items[i].deadline <= now) {
            const p = self.pending.orderedRemove(i);
            self.complete(p, error.Timeout);
            if (p.hello) self.close();
        } else i += 1;
    }
    if (!self.closed) self.armTimer() catch self.close();
    return 0;
}

/// Wake for the earliest reply deadline, or not at all. An idle
/// connection must not poll: a fixed 100 ms sweep woke the compositor
/// 10 times a second per connection with nothing outstanding. A call
/// answered before its deadline leaves at most one early wakeup, which
/// re-arms for the next deadline or disarms.
pub fn armTimer(self: *Connection) !void {
    const timer = self.timer orelse return;
    if (self.pending.items.len == 0) return timer.timerUpdate(0);
    var earliest = self.pending.items[0].deadline;
    for (self.pending.items[1..]) |p| earliest = @min(earliest, p.deadline);
    const delay = std.math.clamp(earliest - nowMs(), 1, std.math.maxInt(c_int));
    try timer.timerUpdate(@intCast(delay));
}
