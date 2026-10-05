//! One editor per Wayland display. A private runtime socket receives open requests.
const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/file.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});
const a = std.heap.c_allocator;
pub const Request = struct { path: []const u8 = "", token: []const u8 = "" };
pub const Instance = struct {
    fd: c_int,
    path: [:0]u8,
    primary: bool,
    pub fn init(environ: std.process.Environ) !Instance {
        const runtime = environ.getPosix("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDirectory;
        const dir = try a.dupeZ(u8, runtime);
        defer a.free(dir);
        var st: c.struct_stat = undefined;
        if (c.lstat(dir, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFDIR or st.st_uid != c.getuid() or st.st_mode & 0o077 != 0) return error.RuntimeDirectoryNotPrivate;
        const display = environ.getPosix("WAYLAND_DISPLAY") orelse "wayland-0";
        const path = try std.fmt.allocPrintSentinel(a, "{s}/rediwm-editor-{x}.sock", .{ runtime, std.hash.Wyhash.hash(0, display) }, 0);
        errdefer a.free(path);
        var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        if (path.len >= address.sun_path.len) return error.PathTooLong;
        address.sun_family = c.AF_UNIX;
        @memcpy(address.sun_path[0..path.len], path);
        const lock_path = try std.fmt.allocPrintSentinel(a, "{s}.lock", .{path}, 0);
        defer a.free(lock_path);
        const lock = c.open(lock_path, c.O_CREAT | c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (lock < 0) return error.LockFailed;
        defer _ = c.close(lock);
        if (c.flock(lock, c.LOCK_EX) != 0) return error.LockFailed;
        defer _ = c.flock(lock, c.LOCK_UN);
        const fd = c.socket(c.AF_UNIX, c.SOCK_DGRAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        if (c.connect(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)) == 0) return .{ .fd = fd, .path = path, .primary = false };
        const err = std.posix.errno(@as(c_int, -1));
        if (err != .NOENT and err != .CONNREFUSED) return error.ConnectFailed;
        _ = c.unlink(path);
        if (c.bind(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)) != 0) return error.BindFailed;
        _ = c.chmod(path, 0o600);
        return .{ .fd = fd, .path = path, .primary = true };
    }
    pub fn deinit(self: *Instance) void {
        _ = c.close(self.fd);
        if (self.primary) _ = c.unlink(self.path);
        a.free(self.path);
    }
    pub fn send(self: *Instance, request: Request) !void {
        const json = try std.json.Stringify.valueAlloc(a, request, .{});
        defer a.free(json);
        if (json.len > 16384) return error.RequestTooLarge;
        if (c.send(self.fd, json.ptr, json.len, c.MSG_NOSIGNAL) != json.len) return error.SendFailed;
    }
    pub fn receive(self: *Instance, buffer: []u8) ?[]const u8 {
        const n = c.recv(self.fd, buffer.ptr, buffer.len, c.MSG_TRUNC);
        if (n <= 0 or n > buffer.len) return null;
        return buffer[0..@intCast(n)];
    }
};
