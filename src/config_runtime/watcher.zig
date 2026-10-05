// inotify watch on the compositor config file, wired into the Wayland event loop.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const wl = @import("wayland").server.wl;

const Server = @import("../Server.zig");
const loader = @import("config").loader;

const log = std.log.scoped(.config);

pub const ConfigWatcher = struct {
    fd: i32 = -1,
    wd: i32 = -1,
    path: []const u8,
    basename: []const u8,
    dir_z: [:0]const u8,
    source: ?*wl.EventSource = null,

    pub fn deinit(self: *ConfigWatcher, allocator: std.mem.Allocator) void {
        if (self.source) |src| {
            src.remove();
            self.source = null;
        }
        if (self.fd >= 0) {
            _ = std.c.close(self.fd);
            self.fd = -1;
        }
        allocator.free(self.path);
        allocator.free(self.dir_z);
    }
};

pub fn init(path: []const u8, server: *Server) !ConfigWatcher {
    const allocator = @import("../main.zig").gpa;
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);

    const dir = std.fs.path.dirname(path) orelse ".";
    const dir_z = try allocator.dupeZ(u8, dir);
    errdefer allocator.free(dir_z);

    const fd = std.c.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (fd < 0) return error.InotifyInitFailed;
    errdefer _ = std.c.close(fd);

    // MODIFY/CREATE can observe an editor's empty or half-written file. Only
    // reload completed writes and atomic replacements, especially now that a
    // transient empty config would reset live display scales and placement.
    const mask: u32 = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO;
    const wd = std.c.inotify_add_watch(fd, dir_z.ptr, mask);
    if (wd < 0) return error.InotifyWatchFailed;

    const event_loop = server.wl_server.getEventLoop();
    const source = event_loop.addFd(
        *Server,
        fd,
        .{ .readable = true },
        handleFd,
        server,
    ) catch return error.EventLoopFailed;

    return .{
        .fd = fd,
        .wd = wd,
        .path = owned_path,
        .basename = std.fs.path.basename(owned_path),
        .dir_z = dir_z,
        .source = source,
    };
}

fn handleFd(fd: c_int, mask: wl.EventMask, server: *Server) c_int {
    _ = mask;
    const watcher = &(server.config_watcher orelse return 0);
    var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            else => break,
        };
        if (n == 0) break;
        var off: usize = 0;
        var reload = false;
        while (off + @sizeOf(linux.inotify_event) <= n) {
            const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
            const name = ev.getName();
            if (name == null or std.mem.eql(u8, name.?, watcher.basename)) {
                if (ev.mask & (linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO) != 0) {
                    reload = true;
                }
            }
            off += @sizeOf(linux.inotify_event) + ev.len;
        }
        if (reload) reloadConfig(server);
    }
    return 0;
}

pub fn reloadConfig(server: *Server) void {
    const path = server.config.path;
    if (path.len == 0) {
        server.config_reload_error = "NoConfigPath";
        @import("../ipc/events.zig").onConfigLoaded(server);
        return;
    }
    const new_cfg = loader.load(path, @import("../main.zig").gpa, server.io, server.environ) catch |err| {
        server.config_reload_error = @errorName(err);
        @import("../ipc/events.zig").onConfigLoaded(server);
        log.warn("reload failed ({s}); keeping previous config", .{@errorName(err)});
        return;
    };
    applyLoadedConfig(server, new_cfg);
}

/// Transfer ownership of a fully loaded configuration, including theme overlays.
/// Display settings prepare this before committing so publication needs no fallible reload.
pub fn applyLoadedConfig(server: *Server, new_cfg: loader.Config) void {
    if (server.input.open_control_center) |cc| {
        cc.shortcuts.cancel();
        cc.refresh();
    }
    var old = server.config;
    server.config = new_cfg;
    @import("apply.zig").applyDiff(server, old, new_cfg);
    old.deinit();
    server.config_generation += 1;
    server.config_reload_error = null;
    @import("../ipc/events.zig").onConfigLoaded(server);
}
