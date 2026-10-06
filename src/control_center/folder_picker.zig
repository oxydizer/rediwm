//! Settings' file and folder pickers: runs Files in chooser mode (the
//! same process and JSON contract the FileChooser portal uses) and hands the
//! picked path to a callback. The event loop only reads the child's pipe.
const std = @import("std");
const wl = @import("wayland").server.wl;
const Server = @import("../Server.zig");
const chooser = @import("../files/chooser.zig");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
});

const a = std.heap.c_allocator;
/// A path in JSON; anything larger is not a result.
const max_output = 64 * 1024;

const Picker = struct {
    server: *Server,
    fd: c_int,
    pidfd: c_int,
    source: ?*wl.EventSource = null,
    output: std.ArrayList(u8) = .empty,
    owner: ?*anyopaque,
    on_done: *const fn (?*anyopaque, ?[]const u8) void,

    fn destroy(self: *Picker) void {
        if (active == self) active = null;
        if (self.source) |s| s.remove();
        _ = std.os.linux.pidfd_send_signal(self.pidfd, .TERM, null, 0);
        _ = c.close(self.pidfd);
        _ = c.close(self.fd);
        self.output.deinit(a);
        a.destroy(self);
    }

    /// Ends the chooser and reports its outcome: the path, or null when it
    /// was cancelled, failed or the session locked meanwhile.
    fn end(self: *Picker, path: ?[]const u8) void {
        defer self.destroy();
        if (active == self) active = null;
        self.on_done(self.owner, path);
    }

    fn finish(self: *Picker) void {
        // A session lock owns the screen: nothing the picker chose applies.
        if (self.server.locker != null) return self.end(null);
        const parsed = std.json.parseFromSlice(chooser.Result, a, self.output.items, .{ .ignore_unknown_fields = true }) catch return self.end(null);
        defer parsed.deinit();
        self.end(if (parsed.value.paths.len == 0) null else parsed.value.paths[0]);
    }

    fn readable(fd: c_int, _: wl.EventMask, self: *Picker) c_int {
        while (true) {
            var buf: [4096]u8 = undefined;
            const n = c.read(fd, &buf, buf.len);
            if (n < 0) switch (std.posix.errno(n)) {
                .INTR => continue,
                .AGAIN => return 0,
                else => {
                    self.end(null);
                    return 0;
                },
            };
            if (n == 0) {
                self.finish();
                return 0;
            }
            if (self.output.items.len + @as(usize, @intCast(n)) > max_output) {
                self.end(null);
                return 0;
            }
            self.output.appendSlice(a, buf[0..@intCast(n)]) catch {
                self.end(null);
                return 0;
            };
        }
    }
};

var active: ?*Picker = null;

pub fn running() bool {
    return active != null;
}

/// Ends a chooser still open, without calling back (server shutdown).
pub fn cancel() void {
    if (active) |p| p.destroy();
}

/// Opens the chooser at `start_dir`; `on_done` gets the chosen folder's path
/// (valid only during the call), or null. One chooser at a time.
pub fn start(server: *Server, title: []const u8, start_dir: []const u8, owner: ?*anyopaque, on_done: *const fn (?*anyopaque, ?[]const u8) void) !void {
    return startWithOptions(server, .{ .mode = .folder, .title = title, .accept_label = "Use folder", .current_folder = start_dir }, owner, on_done);
}

pub fn startWithOptions(server: *Server, opts: chooser.Options, owner: ?*anyopaque, on_done: *const fn (?*anyopaque, ?[]const u8) void) !void {
    if (active != null or server.locker != null or server.greeter_mode) return error.Busy;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const bytes = try std.json.Stringify.valueAlloc(alloc, opts, .{});
    const input = c.memfd_create("rediwm-folder-picker", c.MFD_CLOEXEC);
    if (input < 0) return error.CreateFailed;
    defer _ = c.close(input);
    try (std.Io.File{ .handle = input, .flags = .{ .nonblocking = false } }).writeStreamingAll(server.io, bytes);
    if (c.lseek(input, 0, c.SEEK_SET) < 0) return error.SeekFailed;
    var env = try server.environ.createMap(a);
    defer env.deinit();
    try server.applyChildEnv(&env);
    var pathbuf: [4096]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &pathbuf, pathbuf.len);
    const executable = if (n > 0 and n < pathbuf.len) try std.fmt.allocPrint(alloc, "{s}/rediwm-files", .{std.fs.path.dirname(pathbuf[0..@intCast(n)]).?}) else "rediwm-files";
    var child = try std.process.spawn(server.io, .{ .argv = &.{ executable, "--chooser-stdin" }, .environ_map = &env, .stdin = .{ .file = .{ .handle = input, .flags = .{ .nonblocking = false } } }, .stdout = .pipe });
    errdefer child.kill(server.io);
    @import("../session/app_scope.zig").place(server, child.id.?, "file-chooser");
    const pidfd_result = std.os.linux.pidfd_open(child.id.?, 0);
    if (std.os.linux.errno(pidfd_result) != .SUCCESS) return error.PidfdFailed;
    const pidfd: c_int = @intCast(pidfd_result);
    errdefer _ = c.close(pidfd);
    const fd = child.stdout.?.handle;
    if (c.fcntl(fd, c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.NonblockingFailed;
    const picker = try a.create(Picker);
    errdefer a.destroy(picker);
    picker.* = .{ .server = server, .fd = fd, .pidfd = pidfd, .owner = owner, .on_done = on_done };
    picker.source = try server.wl_server.getEventLoop().addFd(*Picker, fd, .{ .readable = true }, Picker.readable, picker);
    errdefer picker.source.?.remove();
    _ = try @import("../session/child.zig").watch(a, server.wl_server.getEventLoop(), child.id.?, null, null);
    active = picker;
}
