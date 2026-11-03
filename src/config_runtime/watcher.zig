// Watches the compositor config file's directory, wired into the Wayland event loop.
const std = @import("std");
const wl = @import("wayland").server.wl;
const platform = @import("platform");

const Server = @import("../Server.zig");
const loader = @import("config").loader;

const log = std.log.scoped(.config);

pub const ConfigWatcher = struct {
    watcher: platform.watch.Watcher,
    path: []const u8,
    basename: []const u8,
    source: ?*wl.EventSource = null,

    pub fn deinit(self: *ConfigWatcher, allocator: std.mem.Allocator) void {
        if (self.source) |src| {
            src.remove();
            self.source = null;
        }
        self.watcher.deinit();
        allocator.free(self.path);
    }
};

pub fn init(path: []const u8, server: *Server) !ConfigWatcher {
    const allocator = @import("../main.zig").gpa;
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);

    var watcher = platform.watch.Watcher.init() catch return error.WatchFailed;
    errdefer watcher.deinit();

    // Completed writes and atomic replacements only: a modification can
    // observe an editor's empty or half-written file, and a transient empty
    // config would reset live display scales and placement.
    _ = watcher.add(std.fs.path.dirname(path) orelse ".", .{ .written = true, .moved_to = true }) orelse return error.WatchFailed;

    const event_loop = server.wl_server.getEventLoop();
    const source = event_loop.addFd(
        *Server,
        watcher.fd,
        .{ .readable = true },
        handleFd,
        server,
    ) catch return error.EventLoopFailed;

    return .{
        .watcher = watcher,
        .path = owned_path,
        .basename = std.fs.path.basename(owned_path),
        .source = source,
    };
}

const Pending = struct {
    basename: []const u8,
    reload: bool = false,

    fn event(self: *Pending, ev: platform.watch.Event) void {
        if (ev.name.len != 0 and !std.mem.eql(u8, ev.name, self.basename)) return;
        if (ev.flags.matches(.{ .written = true, .moved_to = true })) self.reload = true;
    }
};

fn handleFd(_: c_int, _: wl.EventMask, server: *Server) c_int {
    const watcher = &(server.config_watcher orelse return 0);
    var pending: Pending = .{ .basename = watcher.basename };
    watcher.watcher.drain(&pending, Pending.event) catch {};
    if (pending.reload) reloadConfig(server);
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
    // The open Settings page was built from `old` and is rebuilt on its next
    // frame (or after a drag): it keeps `old` until then.
    if (server.input.open_control_center) |cc| cc.retireConfig(&old) else old.deinit();
    server.config_generation += 1;
    server.config_reload_error = null;
    @import("../ipc/events.zig").onConfigLoaded(server);
}
