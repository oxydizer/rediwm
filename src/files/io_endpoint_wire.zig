//! Wire format of the Files endpoint (architecture §13): newline-delimited
//! JSON, one request or response object per line, as in the deferred IPC
//! contract (§2, §3, §11). Parsing and formatting only; no sockets here, so
//! the rules can be tested on their own.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const version = 1;
/// The longest line accepted, newline excluded. A longer one closes the
/// connection: framing cannot be trusted past it.
pub const max_line = 16 * 1024;
/// A path in a request: what the kernel accepts, and no more.
pub const max_path = 4096;
/// Activation tokens are short; this bounds a hostile one.
pub const max_token = 256;
/// Request ids are the client's own correlation strings.
pub const max_id = 128;

pub const ErrorCode = enum {
    INVALID_REQUEST,
    UNSUPPORTED_VERSION,
    UNKNOWN_COMMAND,
    INVALID_ARGUMENT,
    RESOURCE_LIMIT,
    SERVICE_BUSY,
    INTERNAL_ERROR,
};

/// `OpenWindow`: a launch of Files handed to the running process.
pub const OpenWindow = struct {
    /// The folder to show: absolute.
    path: []const u8,
    /// A file in it to select, absolute.
    select: ?[]const u8 = null,
    /// Open the Transfers view.
    transfers: bool = false,
    /// The launcher's XDG activation token, so the new window may take focus.
    activation_token: ?[]const u8 = null,
};

pub const Request = union(enum) {
    open_window: OpenWindow,
};

/// A parsed request line. `id` and the request's strings point into the
/// parse arena; `deinit` frees them.
pub const Parsed = struct {
    id: []const u8,
    request: Request,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *Parsed) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

/// A line that is not a valid request: the error to answer with, and the
/// request id when it could be read (empty otherwise).
pub const Rejection = struct {
    code: ErrorCode,
    message: []const u8,
    id_buf: [max_id]u8 = undefined,
    id_len: usize = 0,

    pub fn id(self: *const Rejection) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

pub const ParseResult = union(enum) {
    request: Parsed,
    rejected: Rejection,
};

const Envelope = struct {
    version: u32,
    id: []const u8,
    command: []const u8,
    params: std.json.Value = .null,
};

/// Parses one line (without its newline). Never fails on input: a bad line
/// becomes a rejection to answer.
pub fn parse(allocator: Allocator, line: []const u8) error{OutOfMemory}!ParseResult {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = .init(allocator);
    var keep = false;
    defer if (!keep) {
        arena.deinit();
        allocator.destroy(arena);
    };
    const a = arena.allocator();

    const envelope = std.json.parseFromSliceLeaky(Envelope, a, line, .{ .ignore_unknown_fields = true }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .rejected = .{ .code = .INVALID_REQUEST, .message = "Not a request object" } };
    };
    var rejection: Rejection = .{ .code = .INVALID_REQUEST, .message = "" };
    if (envelope.id.len == 0 or envelope.id.len > max_id) {
        rejection.message = "Missing or overlong request id";
        return .{ .rejected = rejection };
    }
    @memcpy(rejection.id_buf[0..envelope.id.len], envelope.id);
    rejection.id_len = envelope.id.len;
    if (envelope.version != version) {
        rejection.code = .UNSUPPORTED_VERSION;
        rejection.message = "Unsupported protocol version";
        return .{ .rejected = rejection };
    }
    if (!std.mem.eql(u8, envelope.command, "OpenWindow")) {
        rejection.code = .UNKNOWN_COMMAND;
        rejection.message = "Unknown command";
        return .{ .rejected = rejection };
    }
    const open = std.json.parseFromValueLeaky(OpenWindow, a, envelope.params, .{ .ignore_unknown_fields = true }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        rejection.code = .INVALID_ARGUMENT;
        rejection.message = "OpenWindow needs a path";
        return .{ .rejected = rejection };
    };
    if (!validPath(open.path) or (open.select != null and !validPath(open.select.?))) {
        rejection.code = .INVALID_ARGUMENT;
        rejection.message = "Paths must be absolute, without NUL, at most 4096 bytes";
        return .{ .rejected = rejection };
    }
    if (open.activation_token) |token| if (token.len > max_token or std.mem.indexOfScalar(u8, token, 0) != null) {
        rejection.code = .INVALID_ARGUMENT;
        rejection.message = "Invalid activation token";
        return .{ .rejected = rejection };
    };
    keep = true;
    return .{ .request = .{ .id = envelope.id, .request = .{ .open_window = open }, .arena = arena } };
}

fn validPath(path: []const u8) bool {
    return path.len > 0 and path.len <= max_path and path[0] == '/' and
        std.mem.indexOfScalar(u8, path, 0) == null;
}

/// `{"version":1,"id":…,"result":{}}` and a newline.
pub fn formatOk(allocator: Allocator, id: []const u8) ![]u8 {
    return formatLine(allocator, .{ .version = version, .id = id, .result = .{} });
}

/// `{"version":1,"id":…,"error":{"code":…,"message":…}}` and a newline.
pub fn formatError(allocator: Allocator, id: []const u8, code: ErrorCode, message: []const u8) ![]u8 {
    return formatLine(allocator, .{
        .version = version,
        .id = id,
        .@"error" = .{ .code = @tagName(code), .message = message },
    });
}

/// A request line, for the launcher.
pub fn formatOpenWindow(allocator: Allocator, id: []const u8, open: OpenWindow) ![]u8 {
    return formatLine(allocator, .{
        .version = version,
        .id = id,
        .command = "OpenWindow",
        .params = open,
    });
}

fn formatLine(allocator: Allocator, value: anytype) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{ .emit_null_optional_fields = false });
    defer allocator.free(json);
    const line = try allocator.alloc(u8, json.len + 1);
    @memcpy(line[0..json.len], json);
    line[json.len] = '\n';
    return line;
}

/// Whether a response line answers `id` with success.
pub fn isOk(allocator: Allocator, line: []const u8, id: []const u8) bool {
    const Response = struct {
        version: u32,
        id: []const u8,
        result: ?std.json.Value = null,
    };
    const parsed = std.json.parseFromSlice(Response, allocator, line, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    return parsed.value.version == version and std.mem.eql(u8, parsed.value.id, id) and parsed.value.result != null;
}

/// Splits complete lines off the front of a receive buffer.
pub const Lines = struct {
    buf: [max_line + 1]u8 = undefined,
    len: usize = 0,

    /// Room for the next read; empty when a line has overrun `max_line`.
    pub fn free(self: *Lines) []u8 {
        return self.buf[self.len..];
    }

    pub fn commit(self: *Lines, n: usize) void {
        self.len += n;
    }

    /// The next complete line, without its newline, or null. `error.TooLong`
    /// when the buffer is full and holds no newline.
    pub fn next(self: *Lines, out: *[max_line]u8) error{TooLong}!?[]const u8 {
        const end = std.mem.indexOfScalar(u8, self.buf[0..self.len], '\n') orelse {
            if (self.len >= max_line) return error.TooLong;
            return null;
        };
        if (end > max_line) return error.TooLong;
        @memcpy(out[0..end], self.buf[0..end]);
        const rest = self.len - (end + 1);
        std.mem.copyForwards(u8, self.buf[0..rest], self.buf[end + 1 .. self.len]);
        self.len = rest;
        return out[0..end];
    }
};
