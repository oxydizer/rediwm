//! Helper jobs wake once by eventfd; no archive/image work on the event loop.
const std = @import("std");
const platform = @import("platform");
const Server = @import("../Server.zig");
const wl = @import("wayland").server.wl;
const protocol = @import("../ipc/protocol.zig");
const Client = @import("../ipc/server.zig").Client;
const c = std.posix.system;
const a = std.heap.c_allocator;
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    server: *Server,
    io: std.Io,
    argv: []const []const u8,
    env: std.process.Environ.Map,
    fd: c_int,
    source: ?*wl.EventSource = null,
    thread: ?std.Thread = null,
    result: anyerror!std.process.RunResult = error.NotFinished,
    client: ?*Client = null,
    id: ?protocol.RequestId = null,

    pub fn deinit(self: *Job) void {
        if (self.source) |s| s.remove();
        if (self.thread) |t| t.join();
        _ = c.close(self.fd);
        self.env.deinit();
        self.arena.deinit();
        a.destroy(self);
    }
    fn run(self: *Job) void {
        self.result = std.process.run(self.arena.allocator(), self.io, .{
            .argv = self.argv,
            .environ_map = &self.env,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(16384),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
        });
        const one: u64 = 1;
        _ = c.write(self.fd, std.mem.asBytes(&one).ptr, @sizeOf(u64));
    }
};

pub fn start(server: *Server, args: []const []const u8, client: ?*Client, id: ?protocol.RequestId) !void {
    if (server.locker != null or server.greeter_mode) return error.SessionLocked;
    if (server.theme_job != null) return error.ThemeJobBusy;
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const mem = arena.allocator();
    const exe = try std.process.executableDirPathAlloc(server.io, mem);
    var argv = try mem.alloc([]const u8, args.len + 1);
    argv[0] = try std.fs.path.join(mem, &.{ exe, "rediwm-theme" });
    for (args, argv[1..]) |arg, *dst| dst.* = try mem.dupe(u8, arg);
    var env = try server.environ.createMap(a);
    errdefer env.deinit();
    const fd = platform.wake.create() orelse return error.EventFdFailed;
    errdefer _ = c.close(fd);
    const job = try a.create(Job);
    errdefer a.destroy(job);
    job.* = .{ .arena = arena, .server = server, .io = server.io, .argv = argv, .env = env, .fd = fd, .client = client, .id = if (id) |rid| switch (rid) {
        .integer => rid,
        .string => |s| .{ .string = try mem.dupe(u8, s) },
    } else null };
    job.source = try server.wl_server.getEventLoop().addFd(*Job, fd, .{ .readable = true }, ready, job);
    errdefer job.source.?.remove();
    job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
    server.theme_job = job;
    if (server.input.open_control_center) |cc| {
        cc.appearance.theme_message = if (std.mem.eql(u8, args[0], "install")) "Installing theme…" else if (std.mem.eql(u8, args[0], "remove")) "Removing theme…" else "Saving theme…";
        cc.refresh();
    }
}
fn ready(_: c_int, _: wl.EventMask, job: *Job) c_int {
    job.thread.?.join();
    job.thread = null;
    const server = job.server;
    server.theme_job = null;
    defer job.deinit();
    var message: []const u8 = "Theme saved.";
    var response: protocol.Response = .{ .ok = .{ .theme_job = .{ .id = "", .message = message } } };
    if (job.result) |result| {
        const success = result.term == .exited and result.term.exited == 0;
        message = if (success) "Theme saved." else result.stderr;
        const installed_id = std.mem.trim(u8, result.stdout, " \n\r");
        if (success and server.locker == null and (std.mem.eql(u8, installed_id, server.config.theme_base) or (std.mem.eql(u8, job.argv[1], "remove") and std.mem.eql(u8, job.argv[2], server.config.theme_base)))) {
            // App clients stat the config, so an active-pack upgrade publishes
            // a fresh timestamp even when its base and overrides are unchanged.
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const bytes = std.Io.Dir.cwd().readFileAlloc(server.io, server.config.path, scratch.allocator(), .limited(1 << 20)) catch "";
            if (bytes.len > 0) std.Io.Dir.cwd().writeFile(server.io, .{ .sub_path = server.config.path, .data = bytes }) catch {};
            @import("watcher.zig").reloadConfig(server);
            @import("theme_pack.zig").configureIcons(server);
            if (server.wallpaper_source) |path| @import("../main.zig").gpa.free(path);
            server.wallpaper_source = null;
            server.reloadWallpaper();
            server.input.reloadCursorTheme();
            @import("../control_center/sections/appearance.zig").refreshTheme(server, true);
        }
        response = if (success) .{ .ok = .{ .theme_job = .{ .id = std.mem.trim(u8, result.stdout, " \n\r"), .message = message } } } else .{ .err = message };
    } else |err| {
        message = @errorName(err);
        response = .{ .err = message };
    }
    if (job.client) |client| {
        if (server.locker != null) response = .{ .err = "SessionLocked" };
        if (client.sandbox) |sb| if (!server.config.sandboxAllowGroups(sb.app_id, sb.engine).contains(.ipc)) {
            response = .{ .err = "PermissionDenied" };
        };
        const writer = protocol.BufferWriter{ .list = &client.write_buf, .allocator = client.ipc.allocator };
        protocol.stringifyResponseWithId(job.id, response, writer) catch {};
        client.updateFdInterest() catch {};
    }
    if (server.input.open_control_center) |cc| {
        if (std.mem.indexOf(u8, message, "AlreadyInstalled") == null) {
            if (cc.appearance.theme_pending_path) |path| @import("../main.zig").gpa.free(path);
            cc.appearance.theme_pending_path = null;
        }
        cc.appearance.theme_message = std.fmt.bufPrint(&cc.appearance.theme_message_buf, "{s}", .{message[0 .. std.mem.indexOfScalar(u8, message, '\n') orelse message.len]}) catch "Theme operation failed.";
        cc.refresh();
    }
    return 0;
}
