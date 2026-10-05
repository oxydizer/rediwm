//! Asynchronous FileChooser backend. The browser runs out of process; its
//! request is an anonymous stdin file and its only output is a bounded JSON
//! result. No filesystem access or directory scan runs on the compositor loop.
const std = @import("std");
const wl = @import("wayland").server.wl;
const dbus = @import("dbus");
const wire = dbus.wire;
const Server = @import("../Server.zig");
const model = @import("../files/chooser.zig");
const protocol = @import("file_chooser_protocol.zig");
const settings = @import("settings_portal.zig");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
});
const a = std.heap.c_allocator;
const interface = "org.freedesktop.impl.portal.FileChooser";
const Request = struct {
    manager: *Manager,
    arena: std.heap.ArenaAllocator,
    handle: []const u8,
    options: model.Options,
    deferred: dbus.Connection.Deferred,
    fd: c_int,
    pidfd: c_int,
    source: ?*wl.EventSource = null,
    output: std.ArrayList(u8) = .empty,

    fn destroy(self: *Request) void {
        const conn = self.manager.conn;
        conn.unregisterMethodsByOwner(self);
        conn.releaseDeferred(&self.deferred);
        if (self.source) |s| s.remove();
        _ = std.os.linux.pidfd_send_signal(self.pidfd, .TERM, null, 0);
        _ = c.close(self.pidfd);
        _ = c.close(self.fd);
        self.output.deinit(a);
        self.arena.deinit();
        for (self.manager.requests.items, 0..) |r, i| if (r == self) {
            _ = self.manager.requests.swapRemove(i);
            break;
        };
        a.destroy(self);
    }
    fn finish(self: *Request, code: u32, result: ?model.Result) void {
        defer self.destroy();
        var body: wire.Writer = .{ .allocator = a };
        defer body.deinit();
        const locked = self.manager.server.locker != null;
        protocol.response(&body, self.options, if (locked) null else result, if (locked) 1 else code) catch {
            self.manager.conn.replyErrorDeferred(&self.deferred, "org.freedesktop.portal.Error.Failed", "Invalid chooser result") catch {};
            return;
        };
        self.manager.conn.replyDeferred(&self.deferred, "ua{sv}", &body) catch {};
    }
    fn readable(fd: c_int, _: wl.EventMask, self: *Request) c_int {
        while (true) {
            var buf: [8192]u8 = undefined;
            const n = c.read(fd, &buf, buf.len);
            if (n < 0) switch (std.posix.errno(n)) {
                .INTR => continue,
                .AGAIN => return 0,
                else => {
                    self.finish(2, null);
                    return 0;
                },
            };
            if (n == 0) {
                const parsed = std.json.parseFromSlice(model.Result, a, self.output.items, .{}) catch {
                    self.finish(1, null);
                    return 0;
                };
                defer parsed.deinit();
                self.finish(if (parsed.value.paths.len == 0) 1 else 0, if (parsed.value.paths.len == 0) null else parsed.value);
                return 0;
            }
            if (self.output.items.len + @as(usize, @intCast(n)) > 1024 * 1024) {
                self.finish(2, null);
                return 0;
            }
            self.output.appendSlice(a, buf[0..@intCast(n)]) catch {
                self.finish(2, null);
                return 0;
            };
        }
    }
};
pub const Manager = struct {
    server: *Server,
    conn: *dbus.Connection,
    requests: std.ArrayList(*Request) = .empty,

    pub fn create(server: *Server, conn: *dbus.Connection) !*Manager {
        const self = try a.create(Manager);
        errdefer a.destroy(self);
        self.* = .{ .server = server, .conn = conn };
        errdefer conn.unregisterMethodsByOwner(self);
        inline for (.{ "OpenFile", "SaveFile", "SaveFiles" }) |member| try conn.register(.{ .path = settings.object_path, .interface = interface, .member = member, .owner = self, .callback = open });
        inline for (.{ "Get", "GetAll" }) |member| try conn.register(.{ .path = settings.object_path, .interface = "org.freedesktop.DBus.Properties", .member = member, .owner = self, .callback = properties });
        try conn.registerSignal(.{ .sender = "org.freedesktop.DBus", .interface = "org.freedesktop.DBus", .member = "NameOwnerChanged", .owner = self, .callback = ownerChanged });
        conn.on_disconnect = .{ .owner = self, .callback = disconnected };
        return self;
    }
    pub fn start(self: *Manager) void {
        _ = self.conn.addMatch("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'", null, null) catch {};
    }
    pub fn destroy(self: *Manager) void {
        while (self.requests.items.len > 0) self.requests.items[0].destroy();
        self.requests.deinit(a);
        self.conn.unregisterMethodsByOwner(self);
        self.conn.unregisterSignalsByOwner(self);
        self.conn.on_disconnect = null;
        a.destroy(self);
    }
};
fn disconnected(owner: ?*anyopaque) void {
    const self: *Manager = @ptrCast(@alignCast(owner.?));
    while (self.requests.items.len > 0) self.requests.items[0].destroy();
}
fn ownerChanged(owner: ?*anyopaque, _: *dbus.Connection, msg: wire.Message) !void {
    const self: *Manager = @ptrCast(@alignCast(owner.?));
    var reader = msg.body;
    const name = try reader.string();
    _ = try reader.string();
    const next = try reader.string();
    if (next.len != 0) return;
    var i: usize = 0;
    while (i < self.requests.items.len) {
        const r = self.requests.items[i];
        if (std.mem.eql(u8, r.deferred.sender, name)) r.destroy() else i += 1;
    }
}
fn close(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) !void {
    const r: *Request = @ptrCast(@alignCast(owner.?));
    if (!std.mem.eql(u8, msg.headers.sender orelse "", r.deferred.sender)) {
        try conn.replyError(msg, "org.freedesktop.DBus.Error.AccessDenied", "Request belongs to another caller");
        return;
    }
    const empty: wire.Writer = .{ .allocator = a };
    try conn.reply(msg, "", &empty);
    r.finish(1, null);
}

fn open(owner: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) !void {
    const self: *Manager = @ptrCast(@alignCast(owner.?));
    if (self.server.locker != null or self.server.greeter_mode or self.requests.items.len >= 16) {
        try conn.replyError(msg, "org.freedesktop.portal.Error.NotAllowed", "File chooser is unavailable");
        return;
    }
    if (!std.mem.eql(u8, msg.headers.signature, "osssa{sv}")) return error.InvalidArguments;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var reader = msg.body;
    const handle = try alloc.dupe(u8, try reader.string());
    for (self.requests.items) |r| if (std.mem.eql(u8, handle, r.handle)) return error.DuplicateRequest;
    _ = try reader.string(); // app_id belongs to the frontend, never a command.
    const parent = try alloc.dupe(u8, try reader.string());
    const title = try alloc.dupe(u8, try reader.string());
    const member = msg.headers.member orelse "";
    var opts = try protocol.options(alloc, &reader, std.mem.eql(u8, member, "SaveFile"), std.mem.eql(u8, member, "SaveFiles"));
    try reader.done();
    opts.title = title;
    opts.parent_window = parent;
    const bytes = try std.json.Stringify.valueAlloc(alloc, opts, .{});
    if (bytes.len > 1024 * 1024) return error.TooLarge;
    const input = c.memfd_create("rediwm-file-chooser", c.MFD_CLOEXEC);
    if (input < 0) return error.CreateFailed;
    defer _ = c.close(input);
    try (std.Io.File{ .handle = input, .flags = .{ .nonblocking = false } }).writeStreamingAll(self.server.io, bytes);
    if (c.lseek(input, 0, c.SEEK_SET) < 0) return error.SeekFailed;
    var env = try self.server.environ.createMap(a);
    defer env.deinit();
    try self.server.applyChildEnv(&env);
    var pathbuf: [4096]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &pathbuf, pathbuf.len);
    const executable = if (n > 0 and n < pathbuf.len) try std.fmt.allocPrint(alloc, "{s}/rediwm-files", .{std.fs.path.dirname(pathbuf[0..@intCast(n)]).?}) else "rediwm-files";
    var child = try std.process.spawn(self.server.io, .{ .argv = &.{ executable, "--chooser-stdin" }, .environ_map = &env, .stdin = .{ .file = .{ .handle = input, .flags = .{ .nonblocking = false } } }, .stdout = .pipe });
    errdefer child.kill(self.server.io);
    const pidfd_result = std.os.linux.pidfd_open(child.id.?, 0);
    if (std.os.linux.errno(pidfd_result) != .SUCCESS) return error.PidfdFailed;
    const pidfd: c_int = @intCast(pidfd_result);
    errdefer _ = c.close(pidfd);
    const fd = child.stdout.?.handle;
    if (c.fcntl(fd, c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.NonblockingFailed;
    const r = try a.create(Request);
    errdefer a.destroy(r);
    r.* = .{ .manager = self, .arena = arena, .handle = handle, .options = opts, .deferred = try conn.deferReply(msg), .fd = fd, .pidfd = pidfd };
    errdefer conn.releaseDeferred(&r.deferred);
    try conn.register(.{ .path = handle, .interface = "org.freedesktop.impl.portal.Request", .member = "Close", .owner = r, .callback = close });
    errdefer conn.unregisterMethodsByOwner(r);
    r.source = try self.server.wl_server.getEventLoop().addFd(*Request, fd, .{ .readable = true }, Request.readable, r);
    errdefer r.source.?.remove();
    try self.requests.append(a, r);
    errdefer _ = self.requests.pop();
    _ = try @import("child.zig").watch(a, self.server.wl_server.getEventLoop(), child.id.?, null, null);
}
fn properties(_: ?*anyopaque, conn: *dbus.Connection, msg: wire.Message) !void {
    var reader = msg.body;
    const iface = try reader.string();
    const all = std.mem.eql(u8, msg.headers.member orelse "", "GetAll");
    const property = if (all) "version" else try reader.string();
    try reader.done();
    if (!std.mem.eql(u8, iface, interface) or !std.mem.eql(u8, property, "version")) {
        try conn.replyError(msg, "org.freedesktop.DBus.Error.UnknownProperty", "Unknown property");
        return;
    }
    var body: wire.Writer = .{ .allocator = a };
    defer body.deinit();
    const dict = if (all) try body.beginArray(8) else null;
    if (all) {
        try body.alignTo(8);
        try body.string("version");
    }
    try body.variant("u");
    try body.uint32(3);
    if (dict) |array| try body.endArray(array);
    try conn.reply(msg, if (all) "a{sv}" else "v", &body);
}
