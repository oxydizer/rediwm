//! Bounded, nonblocking client for the per-user transfer helper.
const std = @import("std");
const tr = @import("i18n").tr;
const c = @import("c");
const platform = @import("platform");
pub const File = struct { index: usize, path: []const u8, size: i64 };
pub const Transfer = struct {
    source: []const u8 = "",
    download_directory: []const u8 = "",
    peers: i32 = 0,
    known_peers: i32 = 0,
    seeds: i32 = 0,
    id: []const u8,
    name: []const u8,
    destination: []const u8,
    storage: []const u8,
    pending: bool,
    metadata: bool,
    paused: bool,
    finished: bool,
    published: bool,
    progress: i32,
    download_rate: i64,
    upload_rate: i64,
    total: i64,
    done: i64,
    ratio: i32,
    limit: i32,
    @"error": []const u8,
    files: []const File,
    pub fn status(self: Transfer) []const u8 {
        if (self.@"error".len > 0) return self.@"error";
        if (self.pending) return if (self.metadata) tr("Choose files to download") else tr("Fetching file list…");
        if (self.paused) return if (self.finished) tr("Complete · Stopped") else tr("Paused");
        return if (self.finished) tr("Downloaded · Seeding") else tr("Downloading");
    }
};
pub const Snapshot = struct { transfers: []const Transfer = &.{}, @"error": []const u8 = "" };
pub const Client = struct {
    rows_changed: bool = false,
    fd: c_int = -1,
    snapshot: ?std.json.Parsed(Snapshot) = null,
    retry_at: ?i64 = null,
    attempts: u8 = 0,
    error_buf: [256]u8 = @splat(0),
    pub fn deinit(self: *Client) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        if (self.snapshot) |*s| s.deinit();
    }
    pub fn items(self: *const Client) []const Transfer {
        return if (self.snapshot) |s| s.value.transfers else &.{};
    }
    pub fn message(self: *const Client) []const u8 {
        return std.mem.sliceTo(&self.error_buf, 0);
    }
    pub fn fail(self: *Client, msg: []const u8) void {
        const n = @min(msg.len, self.error_buf.len - 1);
        @memcpy(self.error_buf[0..n], msg[0..n]);
        self.error_buf[n] = 0;
    }
    pub fn connect(self: *Client, runtime: []const u8) bool {
        var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        address.sun_family = c.AF_UNIX;
        _ = std.fmt.bufPrintSentinel(@ptrCast(&address.sun_path), "{s}/files-transfers.sock", .{runtime}, 0) catch return false;
        const fd = c.socket(c.AF_UNIX, c.SOCK_SEQPACKET | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
        if (fd < 0) return false;
        if (std.c.connect(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) {
            _ = c.close(fd);
            return false;
        }
        const same_user = if (platform.peer.of(fd)) |peer| peer.uid == c.getuid() else false;
        if (!same_user) {
            _ = c.close(fd);
            return false;
        }
        self.fd = fd;
        self.retry_at = null;
        self.error_buf[0] = 0;
        return true;
    }
    pub fn send(self: *Client, value: anytype) bool {
        if (self.fd < 0) {
            self.fail(tr("Transfers is disconnected. Reopen Transfers to reconnect."));
            return false;
        }
        const bytes = std.json.Stringify.valueAlloc(std.heap.c_allocator, value, .{}) catch return false;
        defer std.heap.c_allocator.free(bytes);
        if (bytes.len > 192 * 1024 or c.send(self.fd, bytes.ptr, bytes.len, c.MSG_DONTWAIT | c.MSG_NOSIGNAL) != @as(isize, @intCast(bytes.len))) {
            self.fail(tr("Transfer request could not be sent. Please retry."));
            return false;
        }
        self.error_buf[0] = 0;
        return true;
    }
    pub fn drain(self: *Client) void {
        var buffer: [192 * 1024]u8 = undefined;
        // Bounded per loop so a busy session cannot starve Wayland input.
        for (0..8) |_| {
            const n = c.recv(self.fd, &buffer, buffer.len, c.MSG_DONTWAIT | c.MSG_TRUNC);
            if (n < 0 and std.posix.errno(n) == .AGAIN) return;
            if (n <= 0 or n >= buffer.len) {
                _ = c.close(self.fd);
                self.fd = -1;
                self.fail(tr("Transfers disconnected. Reopen Transfers to reconnect."));
                return;
            }
            const next = std.json.parseFromSlice(Snapshot, std.heap.c_allocator, buffer[0..@intCast(n)], .{ .allocate = .alloc_always, .ignore_unknown_fields = true, .max_value_len = 16384 }) catch {
                self.fail(tr("Invalid transfer update"));
                return;
            };
            if (next.value.@"error".len > 0) {
                self.fail(next.value.@"error");
                next.deinit();
                continue;
            }
            var valid = next.value.transfers.len <= 64;
            for (next.value.transfers) |t| {
                valid = valid and t.id.len <= 64 and t.files.len <= 512;
                for (t.files) |f| valid = valid and f.index < 512;
            }
            if (!valid) {
                next.deinit();
                self.fail(tr("Invalid transfer metadata"));
                return;
            }
            self.rows_changed = self.rows_changed or !sameRows(self.items(), next.value.transfers);
            if (self.snapshot) |*old| old.deinit();
            self.snapshot = next;
        }
    }
};

fn sameRows(a: []const Transfer, b: []const Transfer) bool {
    if (a.len != b.len) return false;
    for (a, b) |old, next| {
        if (old.published != next.published or !std.mem.eql(u8, old.id, next.id) or
            !std.mem.eql(u8, old.name, next.name) or !std.mem.eql(u8, old.source, next.source) or
            !std.mem.eql(u8, old.download_directory, next.download_directory) or
            !std.mem.eql(u8, old.destination, next.destination) or !std.mem.eql(u8, old.storage, next.storage)) return false;
    }
    return true;
}

pub fn etaSeconds(t: Transfer) ?i64 {
    if (t.pending) return null;
    if (t.finished) return 0;
    if (t.paused or t.download_rate <= 0 or t.total <= 0) return null;
    const remaining = t.total -| @max(0, t.done);
    if (remaining <= 0) return 0;
    return @divTrunc(remaining - 1, t.download_rate) + 1;
}
