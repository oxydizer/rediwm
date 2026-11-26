const std = @import("std");
const c = @import("c.zig").api;
const wire = @import("io_endpoint_wire.zig");
const io_endpoint = @import("io_endpoint.zig");

const allocator = std.testing.allocator;

test "endpoint wire: an OpenWindow request parses" {
    var result = try wire.parse(allocator,
        \\{"version":1,"id":"7","command":"OpenWindow","params":{"path":"/home/u","select":"/home/u/a.txt","transfers":true,"activation_token":"tok","extra":1}}
    );
    switch (result) {
        .rejected => return error.TestUnexpectedResult,
        .request => |*parsed| {
            defer parsed.deinit();
            try std.testing.expectEqualStrings("7", parsed.id);
            const open = parsed.request.open_window;
            try std.testing.expectEqualStrings("/home/u", open.path);
            try std.testing.expectEqualStrings("/home/u/a.txt", open.select.?);
            try std.testing.expect(open.transfers);
            try std.testing.expectEqualStrings("tok", open.activation_token.?);
        },
    }
}

test "endpoint wire: bad requests are answered with their error code" {
    const cases = [_]struct { line: []const u8, code: wire.ErrorCode, id: []const u8 }{
        .{ .line = "not json", .code = .INVALID_REQUEST, .id = "" },
        .{ .line = "{\"version\":1,\"id\":\"\",\"command\":\"OpenWindow\"}", .code = .INVALID_REQUEST, .id = "" },
        .{ .line = "{\"version\":2,\"id\":\"a\",\"command\":\"OpenWindow\"}", .code = .UNSUPPORTED_VERSION, .id = "a" },
        .{ .line = "{\"version\":1,\"id\":\"b\",\"command\":\"Explode\"}", .code = .UNKNOWN_COMMAND, .id = "b" },
        .{ .line = "{\"version\":1,\"id\":\"c\",\"command\":\"OpenWindow\",\"params\":{}}", .code = .INVALID_ARGUMENT, .id = "c" },
        .{ .line = "{\"version\":1,\"id\":\"d\",\"command\":\"OpenWindow\",\"params\":{\"path\":\"relative\"}}", .code = .INVALID_ARGUMENT, .id = "d" },
        .{ .line = "{\"version\":1,\"id\":\"e\",\"command\":\"OpenWindow\",\"params\":{\"path\":\"/a\",\"select\":\"b\"}}", .code = .INVALID_ARGUMENT, .id = "e" },
    };
    for (cases) |case| {
        const result = try wire.parse(allocator, case.line);
        switch (result) {
            .request => return error.TestUnexpectedResult,
            .rejected => |rejection| {
                try std.testing.expectEqual(case.code, rejection.code);
                try std.testing.expectEqualStrings(case.id, rejection.id());
            },
        }
    }
}

test "endpoint wire: lines split across reads, several per read, and an overlong one" {
    var lines: wire.Lines = .{};
    var out: [wire.max_line]u8 = undefined;
    const first = "{\"a\":1}\n{\"b\"";
    @memcpy(lines.free()[0..first.len], first);
    lines.commit(first.len);
    try std.testing.expectEqualStrings("{\"a\":1}", (try lines.next(&out)).?);
    try std.testing.expect((try lines.next(&out)) == null);
    const rest = ":2}\n";
    @memcpy(lines.free()[0..rest.len], rest);
    lines.commit(rest.len);
    try std.testing.expectEqualStrings("{\"b\":2}", (try lines.next(&out)).?);

    var long: wire.Lines = .{};
    @memset(long.free()[0..wire.max_line], 'x');
    long.commit(wire.max_line);
    try std.testing.expectError(error.TooLong, long.next(&out));
}

test "endpoint wire: responses are one line and recognised" {
    const ok = try wire.formatOk(allocator, "launch");
    defer allocator.free(ok);
    try std.testing.expect(ok[ok.len - 1] == '\n');
    try std.testing.expect(wire.isOk(allocator, ok[0 .. ok.len - 1], "launch"));
    try std.testing.expect(!wire.isOk(allocator, ok[0 .. ok.len - 1], "other"));
    const failed = try wire.formatError(allocator, "launch", .SERVICE_BUSY, "busy");
    defer allocator.free(failed);
    try std.testing.expect(!wire.isOk(allocator, failed[0 .. failed.len - 1], "launch"));
}

const Runtime = struct {
    buf: [64]u8 = undefined,
    path: []const u8 = "",

    fn init(self: *Runtime) !void {
        const template = "/tmp/rediwm_endpoint_XXXXXX";
        @memcpy(self.buf[0..template.len], template);
        self.buf[template.len] = 0;
        const made = c.mkdtemp(@ptrCast(&self.buf)) orelse return error.MkdtempFailed;
        self.path = std.mem.span(@as([*:0]const u8, @ptrCast(made)));
    }

    fn deinit(self: *Runtime, paths: *const io_endpoint.Paths) void {
        _ = c.unlink(paths.socket);
        _ = c.unlink(paths.lock);
        _ = c.rmdir(@ptrCast(&self.buf));
    }
};

fn startInstance(endpoint: *io_endpoint.Endpoint, paths: *const io_endpoint.Paths) !void {
    switch (io_endpoint.claim(allocator, paths, .{ .path = "/first" })) {
        .instance => |fd| try endpoint.start(allocator, fd, paths.socket, null),
        else => return error.TestUnexpectedResult,
    }
}

test "endpoint: a second launch is handed to the instance, which opens it" {
    var runtime: Runtime = .{};
    try runtime.init();
    var paths = try io_endpoint.Paths.init(allocator, runtime.path, "wayland-test");
    defer paths.deinit(allocator);
    defer runtime.deinit(&paths);

    var endpoint: io_endpoint.Endpoint = undefined;
    try startInstance(&endpoint, &paths);
    defer endpoint.deinit();

    try std.testing.expect(endpoint.takeOpen() == null);
    try std.testing.expectEqual(io_endpoint.Claim.handed_over, io_endpoint.claim(allocator, &paths, .{
        .path = "/home/u/Documents",
        .select = "/home/u/Documents/a.txt",
        .activation_token = "token-1",
    }));
    var request = endpoint.takeOpen() orelse return error.MissingRequest;
    defer request.deinit(allocator);
    try std.testing.expectEqualStrings("/home/u/Documents", request.dir);
    try std.testing.expectEqualStrings("/home/u/Documents/a.txt", request.select.?);
    try std.testing.expectEqualStrings("token-1", request.activation_token.?);
    try std.testing.expect(endpoint.takeOpen() == null);

    // Once it stops serving, the next launch becomes the instance itself.
    endpoint.stop();
    switch (io_endpoint.claim(allocator, &paths, .{ .path = "/third" })) {
        .instance => |fd| _ = c.close(fd),
        else => return error.TestUnexpectedResult,
    }
}

test "endpoint: a socket left by a process that died is taken over" {
    var runtime: Runtime = .{};
    try runtime.init();
    var paths = try io_endpoint.Paths.init(allocator, runtime.path, "wayland-test");
    defer paths.deinit(allocator);
    defer runtime.deinit(&paths);

    // Bound, never listened on, closed: what a crash leaves behind.
    const stale = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    @memcpy(address.sun_path[0..paths.socket.len], paths.socket);
    try std.testing.expectEqual(@as(c_int, 0), std.c.bind(stale, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)));
    _ = c.close(stale);

    switch (io_endpoint.claim(allocator, &paths, .{ .path = "/x" })) {
        .instance => |fd| _ = c.close(fd),
        else => return error.TestUnexpectedResult,
    }
}

fn connectRaw(paths: *const io_endpoint.Paths) !c_int {
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    @memcpy(address.sun_path[0..paths.socket.len], paths.socket);
    if (std.c.connect(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)) != 0) return error.ConnectFailed;
    return fd;
}

/// Reads until the peer closes or a second passes.
fn readAll(fd: c_int, buf: []u8) usize {
    var len: usize = 0;
    while (len < buf.len) {
        var pfd = [_]c.struct_pollfd{.{ .fd = fd, .events = c.POLLIN, .revents = 0 }};
        if (c.poll(&pfd, 1, 1000) <= 0) break;
        const n = c.recv(fd, buf[len..].ptr, buf.len - len, 0);
        if (n <= 0) break;
        len += @intCast(n);
    }
    return len;
}

test "endpoint: an overlong request is refused and the connection closed" {
    var runtime: Runtime = .{};
    try runtime.init();
    var paths = try io_endpoint.Paths.init(allocator, runtime.path, "wayland-test");
    defer paths.deinit(allocator);
    defer runtime.deinit(&paths);
    var endpoint: io_endpoint.Endpoint = undefined;
    try startInstance(&endpoint, &paths);
    defer endpoint.deinit();

    const fd = try connectRaw(&paths);
    defer _ = c.close(fd);
    const junk = try allocator.alloc(u8, wire.max_line + 10);
    defer allocator.free(junk);
    @memset(junk, 'x');
    _ = c.send(fd, junk.ptr, junk.len, c.MSG_NOSIGNAL);
    var buf: [512]u8 = undefined;
    const n = readAll(fd, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "INVALID_REQUEST") != null);
}

test "endpoint: launches beyond the queue are refused, and the launcher runs on its own" {
    var runtime: Runtime = .{};
    try runtime.init();
    var paths = try io_endpoint.Paths.init(allocator, runtime.path, "wayland-test");
    defer paths.deinit(allocator);
    defer runtime.deinit(&paths);
    var endpoint: io_endpoint.Endpoint = undefined;
    try startInstance(&endpoint, &paths);
    defer endpoint.deinit();

    for (0..io_endpoint.max_pending) |_| {
        try std.testing.expectEqual(io_endpoint.Claim.handed_over, io_endpoint.claim(allocator, &paths, .{ .path = "/q" }));
    }
    try std.testing.expectEqual(io_endpoint.Claim.standalone, io_endpoint.claim(allocator, &paths, .{ .path = "/q" }));
    // deinit frees what the UI thread never took.
}
