//! Bounded, cancellable HTTP/1.1 over Unix sockets or plain TCP. DNS, connect,
//! upload and response share one deadline. No credentials or redirects.
const std = @import("std");
const c = @import("native.zig").c;
pub const endpoint = @import("endpoint.zig");
const A = std.mem.Allocator;
const max_header = 16 * 1024;
const max_body = 2 * 1024 * 1024;
const deadline_ms = 3000;

pub fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

fn ready(fd: c_int, events: c_short, cancel: c_int, deadline: i64) !void {
    while (true) {
        const remaining = deadline - nowMs();
        if (remaining <= 0) return error.Timeout;
        var fds = [_]c.struct_pollfd{ .{ .fd = fd, .events = events, .revents = 0 }, .{ .fd = cancel, .events = c.POLLIN, .revents = 0 } };
        const n = c.poll(&fds, fds.len, @intCast(remaining));
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return error.ConnectionFailed;
        }
        if (n == 0) return error.Timeout;
        if (fds[1].revents != 0) return error.Cancelled;
        if (fds[0].revents != 0) return;
    }
}

fn sendAll(fd: c_int, bytes: []const u8, cancel: c_int, deadline: i64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try ready(fd, c.POLLOUT, cancel, deadline);
        const n = c.send(fd, bytes[offset..].ptr, bytes.len - offset, c.MSG_NOSIGNAL);
        if (n < 0) {
            const e = std.posix.errno(n);
            if (e == .AGAIN or e == .INTR) continue;
            return error.ConnectionFailed;
        }
        if (n == 0) return error.ConnectionFailed;
        offset += @intCast(n);
    }
}

pub const Info = struct {
    cups_version: [32]u8 = @splat(0),
    len: usize = 0,
    pub fn version(self: *const Info) []const u8 {
        return self.cups_version[0..self.len];
    }
};

const Header = struct { body: usize, length: ?usize = null, chunked: bool = false, info: Info = .{} };
fn header(bytes: []const u8) !?Header {
    const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse {
        if (bytes.len > max_header) return error.ResponseTooLarge;
        return null;
    };
    if (end > max_header) return error.ResponseTooLarge;
    var lines = std.mem.splitSequence(u8, bytes[0..end], "\r\n");
    const status = lines.next() orelse return error.InvalidHttp;
    if (!(std.mem.startsWith(u8, status, "HTTP/1.1 ") or std.mem.startsWith(u8, status, "HTTP/1.0 ")) or status.len < 12) return error.InvalidHttp;
    if (status.len > 12 and status[12] != ' ') return error.InvalidHttp;
    const code = std.fmt.parseInt(u16, status[9..12], 10) catch return error.InvalidHttp;
    if (code == 401 or code == 403) return error.NotAuthorized;
    if (code != 200) return error.HttpError;
    var h: Header = .{ .body = end + 4 };
    var content_type = false;
    while (lines.next()) |line| {
        const sep = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHttp;
        const name = line[0..sep];
        const value = std.mem.trim(u8, line[sep + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (h.length != null) return error.InvalidHttp;
            if (value.len == 0) return error.InvalidHttp;
            for (value) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidHttp;
            h.length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidHttp;
            if (h.length.? > max_body) return error.ResponseTooLarge;
        } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
            if (h.chunked or !std.ascii.eqlIgnoreCase(value, "chunked")) return error.InvalidHttp;
            h.chunked = true;
        } else if (std.ascii.eqlIgnoreCase(name, "Content-Type")) {
            const mime = std.mem.trim(u8, value[0 .. std.mem.indexOfScalar(u8, value, ';') orelse value.len], " \t");
            if (!std.ascii.eqlIgnoreCase(mime, "application/ipp")) return error.InvalidHttp;
            content_type = true;
        } else if (std.ascii.eqlIgnoreCase(name, "Server")) {
            // Keep only the version token. Arbitrary server strings can carry
            // host names or other private text and never enter a report.
            if (std.mem.startsWith(u8, value, "CUPS/")) {
                const rest = value[5..];
                const end_version = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
                const version = rest[0..end_version];
                var valid = version.len > 0 and version.len <= h.info.cups_version.len;
                for (version) |byte| if (!(std.ascii.isDigit(byte) or byte == '.' or byte == '-')) {
                    valid = false;
                };
                if (valid) {
                    @memcpy(h.info.cups_version[0..version.len], version);
                    h.info.len = version.len;
                }
            }
        }
    }
    if (!content_type or (h.length != null and h.chunked)) return error.InvalidHttp;
    return h;
}

/// Validate the complete chunk stream before allocating its decoded body.
fn chunkSize(bytes: []const u8, output: ?[]u8) !?usize {
    var offset: usize = 0;
    var count: usize = 0;
    var chunks: usize = 0;
    while (true) {
        const end = std.mem.indexOfPos(u8, bytes, offset, "\r\n") orelse return null;
        if (end - offset > 128) return error.InvalidHttp;
        const line = bytes[offset..end];
        const len = std.fmt.parseInt(usize, line[0 .. std.mem.indexOfScalar(u8, line, ';') orelse line.len], 16) catch return error.InvalidHttp;
        offset = end + 2;
        if (len == 0) {
            if (bytes.len - offset < 2) return null;
            // CUPS does not send trailers. Bound and validate any it does.
            if (!std.mem.startsWith(u8, bytes[offset..], "\r\n")) {
                const trailer = std.mem.indexOfPos(u8, bytes, offset, "\r\n\r\n") orelse {
                    if (bytes.len - offset > max_header) return error.ResponseTooLarge;
                    return null;
                };
                if (trailer - offset > max_header) return error.ResponseTooLarge;
            }
            return count;
        }
        if (len > max_body - count) return error.ResponseTooLarge;
        chunks += 1;
        if (chunks > 16384) return error.ResponseTooLarge;
        if (len > bytes.len - offset or bytes.len - offset - len < 2) return null;
        if (!std.mem.eql(u8, bytes[offset + len ..][0..2], "\r\n")) return error.InvalidHttp;
        if (output) |out| @memcpy(out[count..][0..len], bytes[offset..][0..len]);
        count += len;
        offset += len + 2;
    }
}

pub fn request(a: A, socket: []const u8, resource: []const u8, body: []const u8, cancel: c_int) ![]u8 {
    return requestWithIo(a, null, try endpoint.parseServer(socket), resource, body, cancel, null);
}

pub fn requestIo(a: A, io: std.Io, server: []const u8, resource: []const u8, body: []const u8, cancel: c_int) ![]u8 {
    return requestWithIo(a, io, try endpoint.parseServer(server), resource, body, cancel, null);
}

pub fn requestIoInfo(a: A, io: std.Io, server: []const u8, resource: []const u8, body: []const u8, cancel: c_int, info: *Info) ![]u8 {
    info.* = .{};
    return requestWithIo(a, io, try endpoint.parseServer(server), resource, body, cancel, info);
}

/// Probe only the supplied IPP URI; never discover a host or try other ports.
pub fn requestUri(a: A, io: std.Io, uri: []const u8, body: []const u8, cancel: c_int) ![]u8 {
    const target = try endpoint.parsePrinterUri(uri);
    return requestWithIo(a, io, target, target.resource, body, cancel, null);
}

/// Best-effort cancellation when hiding a local page. There is no waiting,
/// reply, retained socket, worker or timer. A full send means queued to CUPS,
/// not acknowledged; failure cannot delay compositor teardown.
pub fn sendNoWait(server: []const u8, resource: []const u8, body: []const u8) !void {
    const target = try endpoint.parseServer(server);
    const socket = target.unix orelse return error.UnsupportedServer;
    try endpoint.validateResource(resource);
    if (body.len > 1024) return error.RequestTooLarge;
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.ConnectionFailed;
    defer _ = c.close(fd);
    var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    @memcpy(addr.sun_path[0..socket.len], socket);
    if (std.c.connect(fd, @ptrCast(&addr), @intCast(@offsetOf(c.struct_sockaddr_un, "sun_path") + socket.len + 1)) != 0) return error.ConnectionFailed;
    var packet: [2048]u8 = undefined;
    const headers = std.fmt.bufPrint(&packet, "POST {s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/ipp\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ resource, body.len }) catch return error.RequestTooLarge;
    if (headers.len + body.len > packet.len) return error.RequestTooLarge;
    @memcpy(packet[headers.len..][0..body.len], body);
    const length = headers.len + body.len;
    const sent = c.send(fd, &packet, length, c.MSG_NOSIGNAL | c.MSG_DONTWAIT);
    if (sent < 0 or @as(usize, @intCast(sent)) != length) return error.ConnectionFailed;
}

fn requestWithIo(a: A, io: ?std.Io, target: endpoint.Endpoint, resource: []const u8, body: []const u8, cancel: c_int, info: ?*Info) ![]u8 {
    try endpoint.validateResource(resource);
    const deadline = nowMs() + deadline_ms;
    const fd = if (target.unix) |socket| try connectUnix(socket, cancel, deadline) else try connectTcp(io, target, cancel, deadline);
    defer _ = c.close(fd);
    const headers = try std.fmt.allocPrint(a, "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/ipp\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ resource, target.authority, body.len });
    defer a.free(headers);
    try sendAll(fd, headers, cancel, deadline);
    try sendAll(fd, body, cancel, deadline);
    return response(a, fd, cancel, deadline, info);
}

fn connectUnix(socket: []const u8, cancel: c_int, deadline: i64) !c_int {
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.ConnectionFailed;
    errdefer _ = c.close(fd);
    var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    @memcpy(addr.sun_path[0..socket.len], socket);
    const result = std.c.connect(fd, @ptrCast(&addr), @intCast(@offsetOf(c.struct_sockaddr_un, "sun_path") + socket.len + 1));
    if (result < 0) {
        const e = std.posix.errno(result);
        if (e == .NOENT or e == .CONNREFUSED) return error.CupsUnavailable;
        if (e == .ACCES) return error.NotAuthorized;
        if (e != .INPROGRESS and e != .AGAIN) return error.ConnectionFailed;
        try connected(fd, cancel, deadline);
    }
    return fd;
}

fn connected(fd: c_int, cancel: c_int, deadline: i64) !void {
    try ready(fd, c.POLLOUT, cancel, deadline);
    var sock_error: c_int = 0;
    var length: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &sock_error, &length) != 0 or sock_error != 0) return error.ConnectionFailed;
}

const Addresses = struct { values: [32]std.Io.net.IpAddress = undefined, count: usize = 0 };

/// Zig's Linux resolver uses cancellable DNS sockets, rather than libc's
/// blocking getaddrinfo/NSS. Completion uses an eventfd so the existing page
/// cancellation fd interrupts resolution as well as ordinary socket I/O.
fn lookup(io: std.Io, host: []const u8, port: u16, done: c_int, result: *Addresses) anyerror!void {
    defer {
        var one: u64 = 1;
        _ = c.write(done, &one, @sizeOf(u64));
    }
    const name = try std.Io.net.HostName.init(host);
    var buffer: [32]std.Io.net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&buffer);
    var resolver = try io.concurrent(std.Io.net.HostName.lookup, .{ name, io, &queue, .{ .port = port } });
    defer resolver.cancel(io) catch {};
    // Drain while resolving: a large local hosts file must not fill the queue
    // and stall a valid endpoint. Retain a fixed number of addresses only.
    while (queue.getOne(io)) |value| {
        if (value == .address and result.count < result.values.len) {
            result.values[result.count] = value.address;
            result.count += 1;
        }
    } else |err| switch (err) {
        error.Canceled => return err,
        error.Closed => {},
    }
    try resolver.await(io);
    if (result.count == 0) return error.UnknownHostName;
}

fn connectTcp(io: ?std.Io, target: endpoint.Endpoint, cancel: c_int, deadline: i64) !c_int {
    var addresses: Addresses = .{};
    if (std.Io.net.IpAddress.parse(target.host, target.port)) |address| {
        addresses.values[0] = address;
        addresses.count = 1;
    } else |_| {
        const resolver_io = io orelse return error.DnsRequiresIo;
        const done = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (done < 0) return error.ConnectionFailed;
        defer _ = c.close(done);
        var task = try resolver_io.concurrent(lookup, .{ resolver_io, target.host, target.port, done, &addresses });
        defer task.cancel(resolver_io) catch {};
        try ready(done, c.POLLIN, cancel, deadline);
        try task.await(resolver_io);
    }
    for (addresses.values[0..addresses.count]) |address| {
        const family: c_int = if (address == .ip4) c.AF_INET else c.AF_INET6;
        const fd = c.socket(family, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
        if (fd < 0) continue;
        const result = switch (address) {
            .ip4 => |ip| blk: {
                var addr: std.posix.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, ip.port), .addr = @bitCast(ip.bytes) };
                break :blk std.c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
            },
            .ip6 => |ip| blk: {
                var addr: std.posix.sockaddr.in6 = .{ .port = std.mem.nativeToBig(u16, ip.port), .flowinfo = ip.flow, .addr = ip.bytes, .scope_id = ip.interface.index };
                break :blk std.c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
            },
        };
        if (result == 0) return fd;
        const err = std.posix.errno(result);
        if (err == .INPROGRESS or err == .AGAIN) {
            connected(fd, cancel, deadline) catch |failure| {
                _ = c.close(fd);
                if (failure == error.Timeout or failure == error.Cancelled) return failure;
                continue;
            };
            return fd;
        }
        _ = c.close(fd);
    }
    return error.CupsUnavailable;
}

fn response(a: A, fd: c_int, cancel: c_int, deadline: i64, info: ?*Info) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    var parsed: ?Header = null;
    while (true) {
        try ready(fd, c.POLLIN, cancel, deadline);
        var scratch: [8192]u8 = undefined;
        const n = c.recv(fd, &scratch, scratch.len, 0);
        if (n < 0) {
            const e = std.posix.errno(n);
            if (e == .AGAIN or e == .INTR) continue;
            return error.ConnectionFailed;
        }
        if (n > 0) {
            if (bytes.items.len + @as(usize, @intCast(n)) > max_body + max_header) return error.ResponseTooLarge;
            try bytes.appendSlice(a, scratch[0..@intCast(n)]);
        }
        if (parsed == null) parsed = try header(bytes.items);
        if (parsed) |h| {
            if (info) |out| out.* = h.info;
            const data = bytes.items[h.body..];
            if (h.chunked) {
                if (try chunkSize(data, null)) |size| {
                    const out = try a.alloc(u8, size);
                    errdefer a.free(out);
                    _ = try chunkSize(data, out);
                    return out;
                }
            } else if (h.length) |len| {
                if (data.len >= len) return a.dupe(u8, data[0..len]);
            } else if (n == 0) return a.dupe(u8, data);
        }
        if (n == 0) return error.TruncatedResponse;
    }
}

test "HTTP bounds, status, framing ambiguity and chunks" {
    const t = std.testing;
    try t.expect((try header("HTTP/1.1 200 OK\r\nContent-Type: application/ipp\r\nContent-Length: 4\r\n\r\n1234")).?.length.? == 4);
    try t.expectError(error.NotAuthorized, header("HTTP/1.1 403 Forbidden\r\n\r\n"));
    try t.expectError(error.InvalidHttp, header("HTTP/1.1 200 OK\r\nContent-Type: application/ipp\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n"));
    try t.expectError(error.InvalidHttp, header("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n"));
    try t.expectEqual(@as(?usize, null), try chunkSize("4\r\n12", null));
    try t.expectEqual(@as(?usize, 5), try chunkSize("2\r\nab\r\n3\r\ncde\r\n0\r\n\r\n", null));
    var out: [5]u8 = undefined;
    _ = try chunkSize("2\r\nab\r\n3\r\ncde\r\n0\r\n\r\n", &out);
    try t.expectEqualStrings("abcde", &out);
    try t.expectError(error.ResponseTooLarge, chunkSize("fffffffffffffff\r\n", null));
    const versioned = (try header("HTTP/1.1 200 OK\r\nContent-Type: application/ipp\r\nServer: CUPS/2.4.20 IPP/2.1\r\nContent-Length: 0\r\n\r\n")).?;
    try t.expectEqualStrings("2.4.20", versioned.info.version());
    const hostile = (try header("HTTP/1.1 200 OK\r\nContent-Type: application/ipp\r\nServer: CUPS/private.example\r\nContent-Length: 0\r\n\r\n")).?;
    try t.expectEqualStrings("", hostile.info.version());
}

test "remote loopback HTTP preserves authority, resource and body" {
    const t = std.testing;
    const listener = c.socket(c.AF_INET, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    try t.expect(listener >= 0);
    defer _ = c.close(listener);
    var address: std.posix.sockaddr.in = .{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    try t.expectEqual(@as(c_int, 0), std.c.bind(listener, @ptrCast(&address), @sizeOf(@TypeOf(address))));
    try t.expectEqual(@as(c_int, 0), c.listen(listener, 1));
    var length: std.c.socklen_t = @sizeOf(@TypeOf(address));
    try t.expectEqual(@as(c_int, 0), std.c.getsockname(listener, @ptrCast(&address), &length));
    const Fixture = struct {
        listener: c_int,
        bytes: [4096]u8 = undefined,
        count: usize = 0,
        fn run(self: *@This()) void {
            ready(self.listener, c.POLLIN, -1, nowMs() + 3000) catch return;
            const fd = std.c.accept(self.listener, null, null);
            if (fd < 0) return;
            defer _ = c.close(fd);
            while (self.count < self.bytes.len) {
                ready(fd, c.POLLIN, -1, nowMs() + 3000) catch return;
                const n = c.recv(fd, self.bytes[self.count..].ptr, self.bytes.len - self.count, 0);
                if (n <= 0) return;
                self.count += @intCast(n);
                if (std.mem.endsWith(u8, self.bytes[0..self.count], "test-ipp")) break;
            }
            const reply = "HTTP/1.1 200 OK\r\nContent-Type: application/ipp\r\nContent-Length: 5\r\n\r\nreply";
            _ = c.send(fd, reply, reply.len, c.MSG_NOSIGNAL);
        }
    };
    var fixture: Fixture = .{ .listener = listener };
    const thread = try std.Thread.spawn(.{}, Fixture.run, .{&fixture});
    var joined = false;
    defer if (!joined) thread.join();
    var host: [128]u8 = undefined;
    const server = try std.fmt.bufPrint(&host, "localhost:{d}", .{std.mem.bigToNative(u16, address.port)});
    const reply = try requestIo(t.allocator, t.io, server, "/ipp/print?queue=1", "test-ipp", -1);
    defer t.allocator.free(reply);
    thread.join();
    joined = true;
    try t.expectEqualStrings("reply", reply);
    try t.expect(std.mem.startsWith(u8, fixture.bytes[0..fixture.count], "POST /ipp/print?queue=1 HTTP/1.1\r\nHost: localhost:"));
}

test "DNS cancellation joins the resolver without waiting for its timeout" {
    const t = std.testing;
    const Slow = struct {
        var started: c_int = -1;
        fn lookup(userdata: ?*anyopaque, _: std.Io.net.HostName, queue: *std.Io.Queue(std.Io.net.HostName.LookupResult), _: std.Io.net.HostName.LookupOptions) std.Io.net.HostName.LookupError!void {
            const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
            const io = threaded.io();
            defer queue.close(io);
            var one: u64 = 1;
            _ = c.write(started, &one, @sizeOf(u64));
            try std.Io.sleep(io, .fromSeconds(60), .awake);
        }
        fn cancelWhenStarted(started_fd: c_int, cancel: c_int) void {
            ready(started_fd, c.POLLIN, -1, nowMs() + 1000) catch return;
            var one: u64 = 1;
            _ = c.write(cancel, &one, @sizeOf(u64));
        }
    };
    var vtable = t.io.vtable.*;
    vtable.netLookup = Slow.lookup;
    var io = t.io;
    io.vtable = &vtable;
    const cancel = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
    try t.expect(cancel >= 0);
    defer _ = c.close(cancel);
    const started = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
    try t.expect(started >= 0);
    defer _ = c.close(started);
    Slow.started = started;
    defer Slow.started = -1;
    const canceller = try std.Thread.spawn(.{}, Slow.cancelWhenStarted, .{ started, cancel });
    defer canceller.join();
    const start = nowMs();
    try t.expectError(error.Cancelled, requestIo(t.allocator, io, "slow.invalid:631", "/", "test", cancel));
    try t.expect(nowMs() - start < 1000);
}

test {
    _ = endpoint;
}
