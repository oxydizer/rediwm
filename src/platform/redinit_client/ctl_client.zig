//! Exported client module. Reuses the wire schema; applications need neither a
//! shell nor their own framing/parser. Blocking I/O belongs in the client only.
const std = @import("std");
const linux = std.os.linux;
pub const protocol = @import("ctl_proto");
pub const Request = protocol.Request;
pub const Error = error{ ConnectFailed, Disconnected, IoFailure, FrameTooLarge, InvalidRequest };

pub const Connection = struct {
    fd: linux.fd_t,
    buffer: [protocol.max_line]u8 = undefined,
    begin: usize = 0,
    end: usize = 0,

    pub fn connect(path: []const u8) Error!Connection {
        return connectTimeout(path, 0);
    }
    /// A nonzero timeout bounds connect/send/read for short desktop requests.
    /// Streaming clients keep the default (no socket timeout).
    pub fn connectTimeout(path: []const u8, timeout_ms: u32) Error!Connection {
        var address: linux.sockaddr.un = .{ .path = @splat(0) };
        if (path.len >= address.path.len or std.mem.indexOfScalar(u8, path, 0) != null) return error.ConnectFailed;
        @memcpy(address.path[0..path.len], path);
        const result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(result) != .SUCCESS) return error.ConnectFailed;
        const fd: linux.fd_t = @intCast(result);
        if (timeout_ms != 0) {
            const timeout: linux.timeval = .{ .sec = timeout_ms / 1000, .usec = (timeout_ms % 1000) * 1000 };
            inline for (.{ linux.SO.RCVTIMEO, linux.SO.SNDTIMEO }) |opt| {
                if (linux.errno(linux.setsockopt(fd, linux.SOL.SOCKET, opt, @ptrCast(&timeout), @sizeOf(linux.timeval))) != .SUCCESS) {
                    _ = linux.close(fd);
                    return error.IoFailure;
                }
            }
        }
        if (linux.errno(linux.connect(fd, &address, @sizeOf(@TypeOf(address)))) != .SUCCESS) {
            _ = linux.close(fd);
            return error.ConnectFailed;
        }
        return .{ .fd = fd };
    }
    pub fn close(self: *Connection) void {
        _ = linux.close(self.fd);
    }

    pub fn send(self: *Connection, req: Request) Error!void {
        switch (req.verb) {
            .start, .stop, .restart, .status, .enable, .disable, .why, .logs, .reload_unit, .run, .adopt => {},
            else => if (req.unit.len != 0) return error.InvalidRequest,
        }
        if (req.follow and req.verb != .logs) return error.InvalidRequest;
        var buffer: [protocol.max_request + 1]u8 = undefined;
        var w = std.Io.Writer.fixed(&buffer);
        const verb = switch (req.verb) {
            inline else => |v| protocol.name(v),
        };
        w.writeAll(verb) catch return error.InvalidRequest;
        switch (req.verb) {
            .start, .stop, .restart, .status, .enable, .disable, .why, .reload_unit => w.print(" {s}", .{req.unit}) catch return error.InvalidRequest,
            .logs => w.print(" {s} {d} {d}", .{ req.unit, req.lines, @intFromBool(req.follow) }) catch return error.InvalidRequest,
            .run, .adopt => w.print(" {s} {s}", .{ req.unit, req.rest }) catch return error.InvalidRequest,
            .scope, .environment => if (req.rest.len != 0) {
                w.print(" {s}", .{req.rest}) catch return error.InvalidRequest;
            },
            .subscribe => {
                if (req.since) |seq| w.print(" {d}", .{seq}) catch return error.InvalidRequest else w.writeAll(" now") catch return error.InvalidRequest;
                w.print(" {d} {s} {d}", .{ req.epoch, req.glob, req.kinds }) catch return error.InvalidRequest;
            },
            else => {},
        }
        _ = protocol.parse(w.buffered()) catch return error.InvalidRequest;
        w.writeByte('\n') catch return error.InvalidRequest;
        var at: usize = 0;
        while (at < w.buffered().len) {
            const n = linux.sendto(self.fd, w.buffered()[at..].ptr, w.buffered().len - at, linux.MSG.NOSIGNAL, null, 0);
            if (linux.errno(n) == .INTR) continue;
            if (linux.errno(n) != .SUCCESS or n == 0) return error.IoFailure;
            at += n;
        }
    }

    /// Borrowed until the next call. A whole frame is always returned, even
    /// when the stream split it across several reads or coalesced many frames.
    pub fn next(self: *Connection) Error![]const u8 {
        while (true) {
            if (std.mem.indexOfScalarPos(u8, self.buffer[0..self.end], self.begin, '\n')) |eol| {
                const line = self.buffer[self.begin..eol];
                self.begin = eol + 1;
                return line;
            }
            if (self.begin > 0) {
                std.mem.copyForwards(u8, &self.buffer, self.buffer[self.begin..self.end]);
                self.end -= self.begin;
                self.begin = 0;
            }
            if (self.end == self.buffer.len) return error.FrameTooLarge;
            const n = linux.read(self.fd, self.buffer[self.end..].ptr, self.buffer.len - self.end);
            if (linux.errno(n) == .INTR) continue;
            if (linux.errno(n) != .SUCCESS) return error.IoFailure;
            if (n == 0) return error.Disconnected;
            self.end += n;
        }
    }

    pub fn nextFrame(self: *Connection, allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
        return std.json.parseFromSlice(std.json.Value, allocator, try self.next(), .{ .allocate = .alloc_always });
    }
};

/// What to run in a transient unit of its own (`redictl run`, or a launcher
/// such as a compositor starting an application).
pub const RunSpec = struct {
    /// `null` lets the manager pick `run-<n>`.
    name: ?[]const u8 = null,
    workdir: ?[]const u8 = null,
    /// `NAME=value` entries, at most 16.
    env: []const []const u8 = &.{},
    /// argv, the first an absolute path, at most 16 words.
    argv: []const []const u8,
};

/// Encode a `RunSpec` as the `rest` of a `run` request (put the name in `unit`).
pub fn encodeRun(buf: []u8, spec: RunSpec) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    protocol.encodeToken(&w, spec.workdir orelse "") catch return null;
    w.print(" {d}", .{spec.env.len}) catch return null;
    for (spec.env) |entry| {
        w.writeByte(' ') catch return null;
        protocol.encodeToken(&w, entry) catch return null;
    }
    for (spec.argv) |arg| {
        w.writeByte(' ') catch return null;
        protocol.encodeToken(&w, arg) catch return null;
    }
    return w.buffered();
}

pub const RunReply = struct {
    ok: bool,
    /// The unit's name when `ok`, otherwise why not. Allocated.
    message: []u8,
};

/// Run `spec` in a unit of its own.
pub fn run(conn: *Connection, allocator: std.mem.Allocator, spec: RunSpec) !RunReply {
    var buf: [protocol.max_request]u8 = undefined;
    const rest = encodeRun(&buf, spec) orelse return error.InvalidRequest;
    return request(conn, allocator, .{ .verb = .run, .unit = spec.name orelse "-", .rest = rest });
}

pub fn adopt(conn: *Connection, allocator: std.mem.Allocator, name: []const u8, pid: i32) !RunReply {
    var buf: [24]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{pid});
    return request(conn, allocator, .{ .verb = .adopt, .unit = name, .rest = text });
}

pub fn request(conn: *Connection, allocator: std.mem.Allocator, req: Request) !RunReply {
    try conn.send(req);
    while (true) {
        const parsed = try conn.nextFrame(allocator);
        defer parsed.deinit();
        const v = parsed.value;
        if (v != .object) continue;
        const kind = v.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "done")) continue;
        const ok = v.object.get("ok") orelse return error.IoFailure;
        const message = v.object.get("message");
        if (ok != .bool or message == null or message.? != .string) return error.IoFailure;
        return .{ .ok = ok.bool, .message = try allocator.dupe(u8, message.?.string) };
    }
}

/// Allocated NAME=value strings; callers own both the strings and the slice.
pub fn environment(conn: *Connection, allocator: std.mem.Allocator) ![][]u8 {
    var entries: std.ArrayList([]u8) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit(allocator);
    }
    try conn.send(.{ .verb = .environment, .rest = "get" });
    while (true) {
        const parsed = try conn.nextFrame(allocator);
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidRequest;
        const kind = parsed.value.object.get("type") orelse return error.InvalidRequest;
        if (kind != .string) return error.InvalidRequest;
        if (std.mem.eql(u8, kind.string, "done")) {
            const ok = parsed.value.object.get("ok") orelse return error.InvalidRequest;
            if (ok != .bool or !ok.bool) return error.IoFailure;
            return entries.toOwnedSlice(allocator);
        }
        if (std.mem.eql(u8, kind.string, "environment")) {
            const value = parsed.value.object.get("assignment") orelse return error.InvalidRequest;
            if (value != .string or entries.items.len == 32) return error.InvalidRequest;
            var decoded: [protocol.max_line]u8 = undefined;
            const entry = try allocator.dupe(u8, try decodeBytes(value.string, &decoded));
            errdefer allocator.free(entry);
            try entries.append(allocator, entry);
        }
    }
}

pub fn changeEnvironment(conn: *Connection, allocator: std.mem.Allocator, set: bool, entries: []const []const u8) !RunReply {
    var buf: [protocol.max_request]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll(if (set) "set" else "unset");
    for (entries) |entry| {
        try w.writeByte(' ');
        try protocol.encodeToken(&w, entry);
    }
    return request(conn, allocator, .{ .verb = .environment, .rest = w.buffered() });
}

/// JSON carries arbitrary log bytes as U+0000..U+00FF, avoiding invalid UTF-8.
/// Decode after the JSON parser has converted those escapes to UTF-8.
pub fn decodeBytes(text: []const u8, out: []u8) error{InvalidData}![]u8 {
    var view = (std.unicode.Utf8View.init(text) catch return error.InvalidData).iterator();
    var n: usize = 0;
    while (view.nextCodepoint()) |cp| {
        if (cp > 255 or n == out.len) return error.InvalidData;
        out[n] = @intCast(cp);
        n += 1;
    }
    return out[0..n];
}
