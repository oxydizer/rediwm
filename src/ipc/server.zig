const std = @import("std");
const wl = @import("wayland").server.wl;

const CompositorServer = @import("../Server.zig");
const protocol = @import("protocol.zig");
const handlers = @import("handlers.zig");
const events = @import("events.zig");
const wait_mod = @import("wait.zig");

const log = std.log.scoped(.ipc);
const c = std.posix.system;

fn closeFd(fd: std.posix.fd_t) void {
    _ = c.close(fd);
}

fn getEnv(key: [*:0]const u8) ?[]const u8 {
    if (c.getenv(key)) |ptr| {
        return std.mem.span(ptr);
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    var buf: [108:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return c.access(&buf, 0) == 0;
}

fn unlinkFile(path: []const u8) void {
    var buf: [108:0]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.unlink(&buf);
}

pub const IpcError = error{
    NoRuntimeDir,
    RuntimeDirNotPrivate,
    SocketPathTooLong,
    SocketPathCollision,
    SocketCreateFailed,
    BindFailed,
    ListenFailed,
    EventLoopFailed,
    OutOfMemory,
};

pub const IpcServer = struct {
    compositor: *CompositorServer,
    allocator: std.mem.Allocator,
    listener_fd: std.posix.fd_t,
    listener_source: ?*wl.EventSource = null,
    socket_path: []const u8,
    session_id: []const u8,
    wait_mgr: *wait_mod.WaitManager,
    clients: std.ArrayList(*Client),
    next_client_id: u64 = 1,
    seq: u64 = 1,
    focused_window_id: ?u64 = null,
    /// Synthetic input and pixel access (`commands.CommandSpec.automation`).
    /// Fixed at startup, so enabling it needs a visible compositor restart.
    automation: bool,

    pub fn create(compositor: *CompositorServer, wayland_display: []const u8, allocator: std.mem.Allocator) IpcError!*IpcServer {
        const socket_path = try resolveSocketPath(allocator, wayland_display);
        errdefer allocator.free(socket_path);

        if (socket_path.len >= 107) return error.SocketPathTooLong;
        try requirePrivateDir(std.fs.path.dirname(socket_path) orelse ".");

        if (fileExists(socket_path)) {
            log.err("socket path already exists: {s}", .{socket_path});
            return error.SocketPathCollision;
        }

        const sock_type = std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC;
        const listener_fd = c.socket(std.posix.AF.UNIX, sock_type, 0);
        if (listener_fd < 0) return error.SocketCreateFailed;
        errdefer closeFd(listener_fd);

        var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..socket_path.len], socket_path);

        const path_len = socket_path.len;
        const addr_len = @as(std.posix.socklen_t, @intCast(@offsetOf(std.posix.sockaddr.un, "path") + path_len + 1));
        // Create the socket 0600 rather than chmod it afterwards, which would
        // leave it connectable with the umask's mode in between.
        const old_umask = std.c.umask(0o177);
        const bound = c.bind(listener_fd, @ptrCast(&addr), addr_len);
        _ = std.c.umask(old_umask);
        if (bound < 0) return error.BindFailed;
        errdefer unlinkFile(socket_path);

        if (c.listen(listener_fd, 16) < 0) return error.ListenFailed;

        var rand_bytes: [16]u8 = undefined;
        _ = std.c.getrandom(&rand_bytes, rand_bytes.len, 0);
        const hex = std.fmt.bytesToHex(rand_bytes, .lower);
        const session_id = try allocator.dupe(u8, &hex);
        errdefer allocator.free(session_id);

        const wait_mgr = try wait_mod.WaitManager.create(compositor, allocator);
        errdefer wait_mgr.deinit();

        const ipc = try allocator.create(IpcServer);
        errdefer allocator.destroy(ipc);

        ipc.* = .{
            .compositor = compositor,
            .allocator = allocator,
            .listener_fd = listener_fd,
            .socket_path = socket_path,
            .session_id = session_id,
            .wait_mgr = wait_mgr,
            .clients = std.ArrayList(*Client).empty,
            .automation = automationEnabled(compositor),
        };
        if (ipc.automation) log.warn("IPC automation enabled: synthetic input and screen capture are available to any client of this socket", .{});

        const event_loop = compositor.wl_server.getEventLoop();
        const source = event_loop.addFd(
            *IpcServer,
            listener_fd,
            .{ .readable = true },
            handleListenerFd,
            ipc,
        ) catch return error.EventLoopFailed;

        ipc.listener_source = source;
        return ipc;
    }

    pub fn deinit(ipc: *IpcServer) void {
        if (ipc.listener_source) |source| {
            source.remove();
        }
        closeFd(ipc.listener_fd);

        while (ipc.clients.items.len > 0) {
            ipc.clients.items[0].destroy();
        }
        ipc.clients.deinit(ipc.allocator);

        ipc.wait_mgr.deinit();
        ipc.allocator.free(ipc.session_id);

        unlinkFile(ipc.socket_path);
        ipc.allocator.free(ipc.socket_path);
        ipc.allocator.destroy(ipc);
    }

    pub fn findClientById(ipc: *IpcServer, id: u64) ?*Client {
        for (ipc.clients.items) |c_item| {
            if (c_item.id == id) return c_item;
        }
        return null;
    }

    pub fn checkSandboxAllowances(ipc: *IpcServer) void {
        var i: usize = 0;
        while (i < ipc.clients.items.len) {
            const client = ipc.clients.items[i];
            if (client.sandbox) |sb| {
                const groups = ipc.compositor.config.sandboxAllowGroups(sb.app_id, sb.engine);
                if (!groups.contains(.ipc)) {
                    if (sb.app_id) |app| {
                        log.info("closing sandboxed IPC client '{s}' due to revoked ipc allowance", .{app});
                    } else {
                        log.info("closing sandboxed IPC client due to revoked ipc allowance", .{});
                    }
                    client.destroy();
                    continue;
                }
            }
            i += 1;
        }
    }
};

pub const Server = IpcServer;

pub const SandboxCaller = struct {
    app_id: ?[]const u8 = null,
    engine: ?[]const u8 = "org.flatpak",
};

pub const Client = struct {
    id: u64,
    ipc: *IpcServer,
    fd: std.posix.fd_t,
    sandbox: ?SandboxCaller = null,
    event_source: ?*wl.EventSource = null,
    read_buf: std.ArrayList(u8),
    write_buf: std.ArrayList(u8),
    write_offset: usize = 0,
    is_event_subscriber: bool = false,
    event_filter: ?protocol.EventFilter = null,
    event_filter_arena: ?std.heap.ArenaAllocator = null,
    closing: bool = false,
    process_job: ?*@import("processes.zig").Job = null,
    held_buttons: std.AutoHashMap(u32, void),
    held_keys: std.AutoHashMap(u32, void),

    pub fn create(ipc: *IpcServer, fd: std.posix.fd_t, sandbox: ?SandboxCaller) !*Client {
        const client = try ipc.allocator.create(Client);
        errdefer ipc.allocator.destroy(client);

        const client_id = ipc.next_client_id;
        ipc.next_client_id += 1;

        client.* = .{
            .id = client_id,
            .ipc = ipc,
            .fd = fd,
            .sandbox = sandbox,
            .read_buf = std.ArrayList(u8).empty,
            .write_buf = std.ArrayList(u8).empty,
            .held_buttons = std.AutoHashMap(u32, void).init(ipc.allocator),
            .held_keys = std.AutoHashMap(u32, void).init(ipc.allocator),
        };

        const event_loop = ipc.compositor.wl_server.getEventLoop();
        const source = try event_loop.addFd(
            *Client,
            fd,
            .{ .readable = true },
            handleClientFd,
            client,
        );
        client.event_source = source;
        try ipc.clients.append(ipc.allocator, client);
        return client;
    }

    pub fn destroy(client: *Client) void {
        if (client.process_job) |job| job.cancel();
        client.process_job = null;
        client.ipc.wait_mgr.cancelForClient(client.id);

        if (client.ipc.compositor.screenshot_mgr) |sm| {
            sm.cancelForClient(client.id);
        }

        if (client.ipc.compositor.virtual_input) |vi| {
            if (vi.active_sequence) |seq| {
                if (seq.client_id == client.id) {
                    vi.cancelSequence(seq);
                }
            }
            const now = @import("../input/virtual.zig").VirtualInput.nowMs();
            var bit = client.held_buttons.iterator();
            while (bit.next()) |entry| {
                vi.pointer.sendButton(now, entry.key_ptr.*, .released);
            }

            var kit = client.held_keys.iterator();
            while (kit.next()) |entry| {
                vi.keyboard.sendKey(now, entry.key_ptr.*, .released);
            }

            if (client.held_buttons.count() > 0) {
                client.ipc.compositor.input.clearGrab();
            }
        }
        if (client.event_filter_arena) |*arena| arena.deinit();
        client.held_buttons.deinit();
        client.held_keys.deinit();

        if (client.sandbox) |sb| {
            if (sb.app_id) |id| client.ipc.allocator.free(id);
        }

        if (client.event_source) |source| {
            source.remove();
            client.event_source = null;
        }
        closeFd(client.fd);

        client.read_buf.deinit(client.ipc.allocator);
        client.write_buf.deinit(client.ipc.allocator);

        for (client.ipc.clients.items, 0..) |item, idx| {
            if (item == client) {
                _ = client.ipc.clients.orderedRemove(idx);
                break;
            }
        }
        client.ipc.allocator.destroy(client);
    }

    pub fn updateFdInterest(client: *Client) !void {
        const source = client.event_source orelse return;
        const has_write = client.write_buf.items.len > client.write_offset;
        try source.fdUpdate(.{
            .readable = !client.closing,
            .writable = has_write,
        });
    }
};

pub fn onSequenceComplete(vi: *@import("../input/virtual.zig").VirtualInput, seq: *@import("../input/virtual.zig").Sequence, err: ?[]const u8) void {
    const client_id = seq.client_id orelse return;
    const ipc = vi.server.ipc orelse return;
    const client = ipc.findClientById(client_id) orelse return;

    const bw = protocol.BufferWriter{ .list = &client.write_buf, .allocator = ipc.allocator };
    if (err) |e| {
        protocol.stringifyResponseWithId(seq.request_id, .{ .err = e }, bw) catch {};
    } else {
        protocol.stringifyResponseWithId(seq.request_id, .{ .ok = .handled }, bw) catch {};
    }
    client.updateFdInterest() catch {};
}

const Ucred = extern struct {
    pid: std.posix.pid_t,
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
};

const SO_PEERPIDFD: c_int = 77;
extern "c" fn pidfd_send_signal(pidfd: c_int, sig: c_int, info: ?*anyopaque, flags: c_uint) c_int;

pub fn parseFlatpakAppId(content: []const u8) ?[]const u8 {
    var in_application_section = false;
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            in_application_section = std.mem.eql(u8, section, "Application");
            continue;
        }
        if (in_application_section) {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
                const key = std.mem.trim(u8, line[0..eq_idx], " \t");
                if (std.mem.eql(u8, key, "name")) {
                    var val = std.mem.trim(u8, line[eq_idx + 1 ..], " \t\r");
                    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
                        val = val[1 .. val.len - 1];
                    }
                    if (val.len > 0) return val;
                }
            }
        }
    }
    return null;
}

fn detectSandbox(pid: i32, client_fd: c_int, allocator: std.mem.Allocator) ?SandboxCaller {
    if (pid <= 0) return null;

    var pidfd: c_int = -1;
    var pidfd_len: std.posix.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(client_fd, std.posix.SOL.SOCKET, SO_PEERPIDFD, @ptrCast(&pidfd), &pidfd_len) < 0 or pidfd < 0) {
        const rc = std.os.linux.pidfd_open(pid, 0);
        if (std.os.linux.errno(rc) == .SUCCESS) {
            pidfd = @intCast(rc);
        } else {
            pidfd = -1;
        }
    }
    defer if (pidfd >= 0) closeFd(pidfd);

    var proc_buf: [64]u8 = undefined;
    const proc_path = std.fmt.bufPrintZ(&proc_buf, "/proc/{d}", .{pid}) catch return null;

    const proc_fd = c.open(proc_path.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (proc_fd < 0) return null;
    defer closeFd(proc_fd);

    const file_fd = c.openat(proc_fd, "root/.flatpak-info", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (file_fd < 0) {
        const err = std.posix.errno(file_fd);
        if (err == .NOENT) {
            return null;
        }
        return .{ .app_id = null, .engine = "org.flatpak" };
    }
    defer closeFd(file_fd);

    if (pidfd >= 0) {
        if (pidfd_send_signal(pidfd, 0, null, 0) != 0) {
            return .{ .app_id = null, .engine = "org.flatpak" };
        }
    } else {
        const rc = std.os.linux.syscall2(.kill, @as(usize, @bitCast(@as(isize, pid))), 0);
        if (std.os.linux.errno(rc) != .SUCCESS) {
            return .{ .app_id = null, .engine = "org.flatpak" };
        }
    }

    var buf: [16 * 1024]u8 = undefined;
    const nread = c.read(file_fd, &buf, buf.len);
    if (nread <= 0) {
        return .{ .app_id = null, .engine = "org.flatpak" };
    }
    const content = buf[0..@intCast(nread)];

    const parsed_id = parseFlatpakAppId(content);
    const app_id = if (parsed_id) |id| (allocator.dupe(u8, id) catch null) else null;
    return .{
        .app_id = app_id,
        .engine = "org.flatpak",
    };
}

fn handleListenerFd(fd: c_int, mask: wl.EventMask, ipc: *IpcServer) c_int {
    _ = mask;
    var client_addr: std.posix.sockaddr.un = undefined;
    var client_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.un);

    const client_fd = std.c.accept4(
        fd,
        @ptrCast(&client_addr),
        &client_addr_len,
        std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
    );
    if (client_fd < 0) return 0;

    var ucred: Ucred = undefined;
    var ucred_len: std.posix.socklen_t = @sizeOf(Ucred);
    if (c.getsockopt(
        client_fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.PEERCRED,
        @ptrCast(&ucred),
        &ucred_len,
    ) < 0) {
        closeFd(client_fd);
        return 0;
    }

    if (ucred.uid != c.getuid()) {
        log.warn("rejecting IPC connection from UID {d} (expected {d})", .{ ucred.uid, c.getuid() });
        closeFd(client_fd);
        return 0;
    }

    const sandbox_opt = detectSandbox(ucred.pid, client_fd, ipc.allocator);
    if (sandbox_opt) |sb| {
        const groups = ipc.compositor.config.sandboxAllowGroups(sb.app_id, sb.engine);
        if (!groups.contains(.ipc)) {
            if (sb.app_id) |app| {
                log.warn("rejecting sandboxed IPC connection from app '{s}' (no ipc allowance in [[sandbox_allow]])", .{app});
            } else {
                log.warn("rejecting sandboxed IPC connection (unidentified app, no ipc allowance in [[sandbox_allow]])", .{});
            }
            if (sb.app_id) |app| ipc.allocator.free(app);
            closeFd(client_fd);
            return 0;
        }
    }

    if (ipc.clients.items.len >= 32) {
        log.warn("rejecting IPC connection: client limit (32) reached", .{});
        if (sandbox_opt) |sb| if (sb.app_id) |app| ipc.allocator.free(app);
        closeFd(client_fd);
        return 0;
    }

    _ = Client.create(ipc, client_fd, sandbox_opt) catch |err| {
        log.err("failed to accept IPC client: {}", .{err});
        if (sandbox_opt) |sb| if (sb.app_id) |app| ipc.allocator.free(app);
        closeFd(client_fd);
        return 0;
    };

    return 0;
}

fn handleClientFd(fd: c_int, mask: wl.EventMask, client: *Client) c_int {
    if (mask.@"error" or mask.hangup) {
        client.closing = true;
        if (client.write_buf.items.len == client.write_offset) {
            client.destroy();
            return 0;
        }
    }

    if (mask.readable and !client.closing) {
        var tmp: [4096]u8 = undefined;
        const nread_res = c.read(fd, &tmp, tmp.len);
        if (nread_res < 0) {
            const err = std.posix.errno(nread_res);
            if (err == .AGAIN or err == .INTR) {
                // Non-fatal, try again later
            } else {
                client.destroy();
                return 0;
            }
        } else {
            const nread: usize = @intCast(nread_res);
            if (nread == 0) {
                client.closing = true;
                if (client.write_buf.items.len == client.write_offset) {
                    client.destroy();
                    return 0;
                }
            } else {
                client.read_buf.appendSlice(client.ipc.allocator, tmp[0..nread]) catch {
                    client.destroy();
                    return 0;
                };

                if (client.read_buf.items.len > 64 * 1024) {
                    log.warn("closing client: request line exceeded 64 KiB limit", .{});
                    client.destroy();
                    return 0;
                }

                processReadBuffer(client) catch {
                    client.destroy();
                    return 0;
                };
            }
        }
    }

    if (mask.writable) {
        if (client.write_buf.items.len > client.write_offset) {
            const pending = client.write_buf.items[client.write_offset..];
            const nwritten_res = c.write(fd, pending.ptr, pending.len);
            if (nwritten_res < 0) {
                const err = std.posix.errno(nwritten_res);
                if (err == .AGAIN or err == .INTR) {
                    // Non-fatal
                } else {
                    client.destroy();
                    return 0;
                }
            } else {
                const nwritten: usize = @intCast(nwritten_res);
                client.write_offset += nwritten;
                if (client.write_offset == client.write_buf.items.len) {
                    client.write_buf.clearRetainingCapacity();
                    client.write_offset = 0;
                    if (client.closing) {
                        client.destroy();
                        return 0;
                    }
                } else if (nwritten > 0) {
                    // Reclaim the sent prefix even if the queue never fully drains.
                    // Otherwise a slow reader can grow the allocation indefinitely
                    // while keeping its unsent backlog below the limit.
                    const remaining = client.write_buf.items[client.write_offset..];
                    std.mem.copyForwards(u8, client.write_buf.items[0..remaining.len], remaining);
                    client.write_buf.items.len = remaining.len;
                    client.write_offset = 0;
                }
            }
        }
    }

    // Check bounded write buffer (512 KiB)
    if (client.write_buf.items.len - client.write_offset > 512 * 1024) {
        log.warn("closing client: write buffer exceeded 512 KiB limit", .{});
        client.destroy();
        return 0;
    }

    client.updateFdInterest() catch {
        client.destroy();
        return 0;
    };

    return 0;
}

fn processReadBuffer(client: *Client) !void {
    var count: usize = 0;
    while (std.mem.indexOfScalar(u8, client.read_buf.items, '\n')) |idx| {
        if (count >= 16) {
            break;
        }
        count += 1;

        const line = client.read_buf.items[0..idx];
        const trimmed = std.mem.trim(u8, line, " \t\r\n");

        if (trimmed.len > 0) {
            var arena = std.heap.ArenaAllocator.init(client.ipc.allocator);
            defer arena.deinit();
            const req_allocator = arena.allocator();

            const parsed_env = protocol.parseEnvelope(req_allocator, trimmed);
            if (parsed_env) |env| {
                // Subscribing sends a state snapshot, so it shares the lock gate
                // `handleRequest` applies to everything else.
                const subscribes = env.request == .event_stream or env.request == .event_stream_filtered;
                if (subscribes and client.ipc.compositor.locker != null) {
                    const bw = protocol.BufferWriter{ .list = &client.write_buf, .allocator = client.ipc.allocator };
                    try protocol.stringifyResponseWithId(env.id, .{ .err = "SessionLocked" }, bw);
                } else if (subscribes and client.sandbox != null and !client.ipc.compositor.config.sandboxAllowGroups(client.sandbox.?.app_id, client.sandbox.?.engine).contains(.ipc)) {
                    const bw = protocol.BufferWriter{ .list = &client.write_buf, .allocator = client.ipc.allocator };
                    try protocol.stringifyResponseWithId(env.id, .{ .err = "PermissionDenied: sandboxed caller lacks ipc allowance" }, bw);
                } else switch (env.request) {
                    .event_stream => {
                        client.is_event_subscriber = true;
                        if (client.event_filter_arena) |*old| old.deinit();
                        client.event_filter_arena = null;
                        client.event_filter = null;
                        @import("../startup.zig").markFirstIpc();
                        const bw = protocol.BufferWriter{ .list = &client.write_buf, .allocator = client.ipc.allocator };
                        try protocol.stringifyResponseWithId(env.id, .{ .ok = .handled }, bw);
                        try events.sendSnapshot(client.ipc, client);
                    },
                    .event_stream_filtered => |filter| {
                        client.is_event_subscriber = true;
                        // The filter borrows strings from the request arena.
                        // Transfer its storage to the subscription before request cleanup.
                        if (client.event_filter_arena) |*old| old.deinit();
                        client.event_filter_arena = arena;
                        arena = std.heap.ArenaAllocator.init(client.ipc.allocator);
                        client.event_filter = filter;
                        const bw = protocol.BufferWriter{ .list = &client.write_buf, .allocator = client.ipc.allocator };
                        try protocol.stringifyResponseWithId(env.id, .{ .ok = .handled }, bw);
                        try events.sendSnapshot(client.ipc, client);
                    },
                    else => {
                        const resp = try handlers.handleRequest(client.ipc.compositor, env.id, env.request, req_allocator, client);
                        if (resp == .ok) @import("../startup.zig").markFirstIpc();
                        if (resp == .ok and resp.ok == .async_pending) {
                            // Response pending completion of async sequence or wait
                        } else {
                            const bw = protocol.BufferWriter{ .list = &client.write_buf, .allocator = client.ipc.allocator };
                            try protocol.stringifyResponseWithId(env.id, resp, bw);
                        }
                    },
                }
            } else |err| {
                const bw = protocol.BufferWriter{ .list = &client.write_buf, .allocator = client.ipc.allocator };
                const err_msg = switch (err) {
                    error.InvalidEnvelope => "InvalidEnvelope: expected version 1, command, optional params and id",
                    error.InvalidRequestId => "InvalidRequestId: request id must be a string of at most 256 bytes or a non-negative integer",
                    error.InvalidRequest => "InvalidRequest: parse error",
                    else => "InvalidRequest: parse error",
                };
                try protocol.stringifyResponse(.{ .err = err_msg }, bw);
            }
        }

        const remaining = client.read_buf.items[idx + 1 ..];
        std.mem.copyForwards(u8, client.read_buf.items[0..remaining.len], remaining);
        client.read_buf.items.len = remaining.len;
    }
}

fn automationEnabled(compositor: *CompositorServer) bool {
    if (getEnv("REDIWM_IPC_AUTOMATION")) |value| {
        if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true")) return true;
    }
    return compositor.config.ipc.automation;
}

fn resolveSocketPath(allocator: std.mem.Allocator, wayland_display: []const u8) ![]const u8 {
    if (getEnv("REDIWM_SOCKET")) |env_path| {
        return allocator.dupe(u8, env_path);
    }
    // No shared-directory fallback: the socket lives where only this uid can reach it.
    const xdg_dir = getEnv("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;
    return std.fmt.allocPrint(allocator, "{s}/rediwm-{s}.sock", .{ xdg_dir, wayland_display });
}

/// The socket's directory must belong to this uid and deny group and others,
/// as `$XDG_RUNTIME_DIR` does; the socket mode alone does not stop another
/// user from replacing it between sessions.
fn requirePrivateDir(dir: []const u8) IpcError!void {
    const linux = std.os.linux;
    var buf: [108:0]u8 = undefined;
    if (dir.len >= buf.len) return error.SocketPathTooLong;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    var info: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, &buf, 0, .{ .UID = true, .MODE = true }, &info);
    if (linux.errno(rc) != .SUCCESS) return error.NoRuntimeDir;
    if (info.uid != linux.getuid() or info.mode & 0o077 != 0) {
        log.err("IPC socket directory {s} is not private to this uid", .{dir});
        return error.RuntimeDirNotPrivate;
    }
}

test "parseFlatpakAppId parses application name" {
    const info =
        \\# Flatpak info sample
        \\[Application]
        \\name=org.example.App
        \\runtime=runtime/org.freedesktop.Platform/x86_64/23.08
    ;
    try std.testing.expectEqualStrings("org.example.App", parseFlatpakAppId(info).?);

    const quoted =
        \\[Context]
        \\shared=network;
        \\
        \\[Application]
        \\name = "com.obsproject.Studio"
    ;
    try std.testing.expectEqualStrings("com.obsproject.Studio", parseFlatpakAppId(quoted).?);

    const no_app =
        \\[Runtime]
        \\name=org.freedesktop.Platform
    ;
    try std.testing.expect(parseFlatpakAppId(no_app) == null);

    const empty = "";
    try std.testing.expect(parseFlatpakAppId(empty) == null);
}
