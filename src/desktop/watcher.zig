//! Filesystem worker. Only immutable snapshots cross into the Wayland thread.
const std = @import("std");
const c = @import("c.zig").api;
const icons = @import("../icon_cache.zig");
const theme = @import("../icon_theme.zig");
const desktop = @import("dotdesktop.zig");
const grid = @import("grid.zig");
const config = @import("config.zig");
const a = std.heap.c_allocator;
/// `untrusted`: a launcher (.desktop file) shown as the plain file it is,
/// which never runs until the user allows it (`trustedLauncher`).
pub const Item = struct { inode: u64 = 0, device: u64 = 0, bytes: i64 = 0, path: []const u8, name: []const u8, icon: ?icons.Entry, exec: []const u8 = "", terminal: bool = false, folder: bool = false, cell: ?grid.Cell = null, builtin: Builtin = .none, untrusted: bool = false };
/// Icons the desktop always shows: they are not files in the desktop folder,
/// so they cannot be renamed, moved to the Trash or dropped onto.
pub const Builtin = enum { none, home, trash };
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    items: []Item,
    wallpaper: ?@import("wallpaper.zig").Image = null,
    catalog: []const desktop.parser.AppEntry = &.{},
    /// `bottom_exclusion` from the desktop config; null defers to the host.
    bottom: ?i32 = null,
    icon_only: bool = false,
    pub fn destroy(self: *Snapshot) void {
        self.arena.deinit();
        a.destroy(self);
    }
};
/// `token` tags a launch so its `Launched` report reaches the request that
/// asked for it; zero launches untracked (the settings file).
pub const Command = struct { kind: enum { launch, save, rename, folder, file, trash, empty_trash, delete, link, copy, move, drop, catalog, settings, send, trust }, path: []const u8, value: []const u8 = "", terminal: bool = false, folder: bool = false, fd: i32 = -1, launch_file: bool = false, token: u64 = 0 };
/// A spawned launch. The Wayland thread asks its host whether a window for
/// it has appeared; the worker has no view of the compositor.
pub const Launched = struct {
    token: u64,
    pid: i32,
    app_buf: [128]u8 = undefined,
    app_len: usize = 0,
    pub fn app(self: *const Launched) []const u8 {
        return self.app_buf[0..self.app_len];
    }
    fn setApp(self: *Launched, value: []const u8) void {
        self.app_len = @min(value.len, self.app_buf.len);
        @memcpy(self.app_buf[0..self.app_len], value[0..self.app_len]);
    }
};
/// White glyph from the shell icon set, centred in a transparent square so it
/// sits in the same box as the themed icons. Rasters live for the process,
/// like `icon_cache`'s, because snapshots only borrow their pixels.
var builtin_icons: [8]?struct { glyph: @import("ui").layout.IconId, entry: icons.Entry } = @splat(null);
fn builtinIcon(glyph: @import("ui").layout.IconId, size: i32) ?icons.Entry {
    for (builtin_icons) |slot| if (slot) |s| if (s.glyph == glyph and s.entry.size == size) return s.entry;
    const inner = @divTrunc(size * 3, 4);
    const mask = @import("ui").shell_icons.get(glyph, inner) orelse return null;
    const n: usize = @intCast(size);
    const pixels = a.alloc(u32, n * n) catch return null;
    @memset(pixels, 0);
    const pad: usize = @intCast(@divTrunc(size - mask.size, 2));
    const m: usize = @intCast(mask.size);
    for (0..m) |y| for (0..m) |x| {
        const v: u32 = mask.alpha[y * m + x];
        pixels[(y + pad) * n + x + pad] = v << 24 | v << 16 | v << 8 | v; // premultiplied white
    };
    const entry = icons.Entry{ .pixels = pixels, .size = size };
    for (&builtin_icons) |*slot| if (slot.* == null) {
        slot.* = .{ .glyph = glyph, .entry = entry };
        break;
    };
    return entry;
}
pub const Worker = struct {
    io: std.Io,
    environ: std.process.Environ,
    child_env: std.process.Environ.Map,
    dir: []const u8,
    layout: []const u8,
    theme_cfg: theme.Config,
    mutex: c.pthread_mutex_t = undefined,
    pending: ?*Snapshot = null,
    error_message: [256]u8 = undefined,
    error_len: usize = 0,
    commands: std.ArrayList(Command) = .empty,
    stop: std.atomic.Value(bool) = .init(false),
    refresh: std.atomic.Value(bool) = .init(true),
    thread: ?std.Thread = null,
    drop_done: std.atomic.Value(bool) = .init(false),
    drop_success: std.atomic.Value(bool) = .init(false),
    catalog_arena: std.heap.ArenaAllocator = .init(a),
    catalog: []const desktop.parser.AppEntry = &.{},
    icon_size: std.atomic.Value(i32) = .init(56),
    launched: ?Launched = null,
    /// Every spawned launch, for the host to give its own systemd scope.
    /// Launches beyond its length between two drains keep the host's cgroup.
    started: [8]Launched = undefined,
    started_len: usize = 0,
    /// Both threads block instead of polling on a clock: the Wayland thread
    /// signals `wake_worker` after queueing work, and the worker signals
    /// `wake_main` after publishing a snapshot, error, launch or drop result.
    wake_worker: c_int = -1,
    wake_main: c_int = -1,
    /// Takes ownership of the host's immutable session environment on success.
    pub fn init(io: std.Io, env: std.process.Environ, child_env: std.process.Environ.Map) !*Worker {
        const self = try a.create(Worker);
        const home = env.getPosix("HOME") orelse return error.NoHome;
        const dir = if (env.getPosix("REDIWM_DESKTOP_DIR")) |d| try a.dupe(u8, d) else try std.fmt.allocPrint(a, "{s}/Desktop", .{home});
        const config_home = env.getPosix("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(a, "{s}/.config", .{home});
        defer if (env.getPosix("XDG_CONFIG_HOME") == null) a.free(config_home);
        self.* = .{ .io = io, .environ = env, .child_env = child_env, .dir = dir, .layout = try std.fmt.allocPrint(a, "{s}/rediwm-desktop/layout.toml", .{config_home}), .theme_cfg = try theme.resolveConfig(a, env) };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexFailed;
        self.wake_worker = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        self.wake_main = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (self.wake_worker < 0 or self.wake_main < 0) return error.EventFdFailed;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn stopAndJoin(self: *Worker) void {
        self.stop.store(true, .release);
        signal(self.wake_worker);
        if (self.thread) |t| t.join();
        self.thread = null;
    }
    pub fn deinit(self: *Worker) void {
        self.stopAndJoin();
        for (self.started[0..self.started_len]) |launch| {
            var status: u32 = 0;
            _ = std.os.linux.wait4(launch.pid, &status, std.os.linux.W.NOHANG, null);
        }
        if (self.wake_worker >= 0) _ = c.close(self.wake_worker);
        if (self.wake_main >= 0) _ = c.close(self.wake_main);
        if (self.pending) |s| s.destroy();
        for (self.commands.items) |cmd| {
            a.free(cmd.path);
            a.free(cmd.value);
            if (cmd.fd >= 0) _ = c.close(cmd.fd);
        }
        self.commands.deinit(a);
        self.catalog_arena.deinit();
        self.child_env.deinit();
        for (self.theme_cfg.base_dirs) |d| a.free(d);
        a.free(self.theme_cfg.base_dirs);
        a.free(self.dir);
        a.free(self.layout);
        _ = c.pthread_mutex_destroy(&self.mutex);
        a.destroy(self);
    }
    fn signal(fd: c_int) void {
        if (fd < 0) return;
        const one: u64 = 1;
        _ = c.write(fd, &one, @sizeOf(u64));
    }
    /// Clears a wake counter after its poll reported it readable.
    pub fn drain(fd: c_int) void {
        var count: u64 = 0;
        _ = c.read(fd, &count, @sizeOf(u64));
    }
    /// Asks the worker to rescan from the Wayland thread.
    pub fn requestRefresh(self: *Worker) void {
        self.refresh.store(true, .release);
        signal(self.wake_worker);
    }
    pub fn takeError(self: *Worker, out: []u8) usize {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        const n = @min(out.len, self.error_len);
        @memcpy(out[0..n], self.error_message[0..n]);
        self.error_len = 0;
        return n;
    }
    fn reportError(self: *Worker, operation: []const u8, err: anyerror) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        const message = std.fmt.bufPrint(&self.error_message, "Could not {s}: {s}", .{ operation, @errorName(err) }) catch "File operation failed";
        self.error_len = message.len;
        if (message.ptr != &self.error_message) @memcpy(self.error_message[0..message.len], message);
        signal(self.wake_main);
    }
    /// Launches spawned since the last call, copied into `out`.
    pub fn takeStarted(self: *Worker, out: *[8]Launched) []const Launched {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        const n = self.started_len;
        @memcpy(out[0..n], self.started[0..n]);
        self.started_len = 0;
        return out[0..n];
    }
    pub fn takeLaunched(self: *Worker) ?Launched {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        const result = self.launched;
        self.launched = null;
        return result;
    }
    pub fn take(self: *Worker) ?*Snapshot {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        const result = self.pending;
        self.pending = null;
        return result;
    }
    pub fn enqueue(self: *Worker, cmd: Command) void {
        var owned = cmd;
        owned.path = a.dupe(u8, cmd.path) catch {
            self.failedEnqueue(cmd);
            return;
        };
        owned.value = a.dupe(u8, cmd.value) catch {
            a.free(owned.path);
            self.failedEnqueue(cmd);
            return;
        };
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        self.commands.append(a, owned) catch {
            a.free(owned.path);
            a.free(owned.value);
            self.failedEnqueue(cmd);
            return;
        };
        signal(self.wake_worker);
    }
    fn failedEnqueue(self: *Worker, cmd: Command) void {
        if (cmd.fd >= 0) _ = c.close(cmd.fd);
        if (cmd.kind == .drop) {
            self.drop_success.store(false, .release);
            self.drop_done.store(true, .release);
        }
    }
    /// Home and Trash, listed first. `REDIWM_DESKTOP_BUILTINS=0` omits them.
    fn appendBuiltins(self: *Worker, mem: std.mem.Allocator, list: *std.ArrayList(Item), saved: []const u8) !void {
        if (self.environ.getPosix("REDIWM_DESKTOP_BUILTINS")) |v| if (std.mem.eql(u8, v, "0")) return;
        const home = self.environ.getPosix("HOME") orelse return;
        const data_home = if (self.environ.getPosix("XDG_DATA_HOME")) |d| try mem.dupe(u8, d) else try std.fmt.allocPrint(mem, "{s}/.local/share", .{home});
        const trash_files = try std.fmt.allocPrint(mem, "{s}/Trash/files", .{data_home});
        // Files browses the trash by path; it must exist before the first deletion.
        std.Io.Dir.cwd().createDirPath(self.io, trash_files) catch {};
        const size = self.icon_size.load(.acquire);
        const entries = [_]struct { kind: Builtin, name: []const u8, path: []const u8, glyph: @import("ui").layout.IconId }{
            .{ .kind = .home, .name = "Home", .path = home, .glyph = .home },
            .{ .kind = .trash, .name = "Trash", .path = trash_files, .glyph = .trash_can },
        };
        for (entries) |e| try list.append(mem, .{ .path = try mem.dupe(u8, e.path), .name = e.name, .icon = builtinIcon(e.glyph, size), .folder = true, .cell = config.lookup(mem, saved, e.path), .builtin = e.kind });
    }
    fn scan(self: *Worker) !*Snapshot {
        const snap = try a.create(Snapshot);
        snap.* = .{ .arena = std.heap.ArenaAllocator.init(a), .items = &.{} };
        errdefer snap.destroy();
        snap.catalog = self.catalog;
        const mem = snap.arena.allocator();
        var list: std.ArrayList(Item) = .empty;
        const settings_path = try std.fmt.allocPrint(mem, "{s}/config.toml", .{std.fs.path.dirname(self.layout).?});
        const settings = std.Io.Dir.cwd().readFileAlloc(self.io, settings_path, mem, .limited(65536)) catch "";
        var wallpaper_path: []const u8 = "";
        var wallpaper_mode: @import("wallpaper.zig").Mode = .fill;
        var lines = std.mem.splitScalar(u8, settings, '\n');
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
            if (std.mem.eql(u8, key, "wallpaper")) {
                const parsed = std.json.parseFromSlice([]const u8, mem, value, .{ .allocate = .alloc_always }) catch continue;
                wallpaper_path = parsed.value;
            } else if (std.mem.eql(u8, key, "wallpaper_mode")) wallpaper_mode = std.meta.stringToEnum(@import("wallpaper.zig").Mode, std.mem.trim(u8, value, "\"")) orelse .fill else if (std.mem.eql(u8, key, "bottom_exclusion")) snap.bottom = std.math.clamp(std.fmt.parseInt(i32, value, 10) catch 64, 0, 4096) else if (std.mem.eql(u8, key, "icon_only_input")) snap.icon_only = std.mem.eql(u8, value, "true");
        }
        if (wallpaper_path.len > 0) snap.wallpaper = @import("wallpaper.zig").load(mem, wallpaper_path, wallpaper_mode) catch null;

        const saved = std.Io.Dir.cwd().readFileAlloc(self.io, self.layout, mem, .limited(4 * 1024 * 1024)) catch "";
        try self.appendBuiltins(mem, &list, saved);
        var dir = try std.Io.Dir.cwd().openDir(self.io, self.dir, .{ .iterate = true });
        defer dir.close(self.io);
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            const path = try std.fmt.allocPrintSentinel(mem, "{s}/{s}", .{ self.dir, entry.name }, 0);
            var stat: c.struct_stat = undefined;
            const folder = c.stat(path, &stat) == 0 and stat.st_mode & c.S_IFMT == c.S_IFDIR;
            var own_stat: c.struct_stat = undefined;
            const has_own_stat = c.lstat(path, &own_stat) == 0;
            var item = Item{ .inode = if (has_own_stat) own_stat.st_ino else 0, .device = if (has_own_stat) own_stat.st_dev else 0, .bytes = if (has_own_stat) own_stat.st_size else 0, .path = path, .name = try mem.dupe(u8, entry.name), .icon = null, .folder = folder, .cell = config.lookup(mem, saved, path) };
            const resolved = if (entry.kind == .sym_link) c.realpath(path, null) else null;
            defer if (resolved != null) c.free(resolved);
            const target_name = if (resolved != null) std.mem.span(resolved) else entry.name;
            var icon_name: []const u8 = if (folder) "folder" else mimeIcon(target_name);
            if (!folder and std.mem.endsWith(u8, target_name, ".desktop")) {
                const content = std.Io.Dir.cwd().readFileAlloc(self.io, path, mem, .limited(512 * 1024)) catch continue;
                const parsed = desktop.parse(mem, content, desktop.Locale.fromEnv(self.environ)) orelse continue;
                if (parsed.hidden or parsed.no_display or !parsed.is_application) continue;
                if (self.trustedLauncher(mem, path, entry.name, parsed)) {
                    item.name = parsed.name orelse entry.name;
                    item.exec = parsed.exec orelse "";
                    item.terminal = parsed.terminal;
                    icon_name = parsed.icon orelse "application-x-executable";
                } else {
                    // Its own Name and Icon could pass it off as a document.
                    item.untrusted = true;
                }
            }
            item.icon = icons.get(self.theme_cfg, self.io, icon_name, self.icon_size.load(.acquire));
            try list.append(mem, item);
        }
        std.mem.sort(Item, list.items, {}, struct {
            fn less(_: void, l: Item, r: Item) bool {
                if ((l.builtin != .none) != (r.builtin != .none)) return l.builtin != .none;
                if (l.builtin != .none) return @intFromEnum(l.builtin) < @intFromEnum(r.builtin);
                return std.ascii.lessThanIgnoreCase(l.name, r.name);
            }
        }.less);
        snap.items = try list.toOwnedSlice(mem);
        return snap;
    }
    /// KDE's rule for launchers outside the menus: an installed entry or a
    /// link to one, a root-owned file, or a file marked executable. Also an
    /// exact copy of an installed entry (what Add Application… makes), which
    /// can only start that installed program. Anything else that lands on the
    /// desktop (a download, an archive, a USB stick) stays a plain file.
    fn trustedLauncher(self: *Worker, mem: std.mem.Allocator, path: [:0]const u8, file_name: []const u8, parsed: desktop.DesktopEntry) bool {
        const app_dirs = desktop.parser.resolveApplicationDirs(mem, self.environ) catch return false;
        if (c.realpath(path, null)) |real| {
            defer c.free(real);
            const target = std.mem.span(real);
            for (app_dirs) |dir| {
                const zdir = mem.dupeZ(u8, dir) catch continue;
                const canonical = c.realpath(zdir, null) orelse continue;
                defer c.free(canonical);
                const prefix = std.mem.span(canonical);
                if (target.len > prefix.len and std.mem.startsWith(u8, target, prefix) and target[prefix.len] == '/') return true;
            }
        }
        var stat: c.struct_stat = undefined;
        if (c.stat(path, &stat) != 0) return false;
        if (stat.st_uid == 0 or c.access(path, c.X_OK) == 0) return true;
        for (app_dirs) |dir| {
            const installed_path = std.fmt.allocPrint(mem, "{s}/{s}", .{ dir, file_name }) catch continue;
            const content = std.Io.Dir.cwd().readFileAlloc(self.io, installed_path, mem, .limited(512 * 1024)) catch continue;
            const installed = desktop.parse(mem, content, desktop.Locale.fromEnv(self.environ)) orelse return false;
            // The first match is the entry the menus use.
            return sameText(installed.exec, parsed.exec) and sameText(installed.path, parsed.path) and installed.terminal == parsed.terminal;
        }
        return false;
    }
    fn run(self: *Worker) void {
        std.Io.Dir.cwd().createDirPath(self.io, self.dir) catch |err| {
            std.log.err("desktop directory: {}", .{err});
            return;
        };
        const zdir = a.dupeZ(u8, self.dir) catch return;
        defer a.free(zdir);
        const fd = c.inotify_init1(c.IN_NONBLOCK | c.IN_CLOEXEC);
        defer if (fd >= 0) {
            _ = c.close(fd);
        };
        var wd: c_int = -1;
        while (!self.stop.load(.acquire)) {
            if (fd >= 0 and wd < 0) {
                _ = c.mkdir(zdir, 0o755);
                wd = c.inotify_add_watch(fd, zdir, c.IN_CREATE | c.IN_DELETE | c.IN_MOVED_FROM | c.IN_MOVED_TO | c.IN_CLOSE_WRITE | c.IN_ATTRIB | c.IN_DELETE_SELF | c.IN_MOVE_SELF);
            }
            _ = c.pthread_mutex_lock(&self.mutex);
            const commands = self.commands;
            self.commands = .empty;
            _ = c.pthread_mutex_unlock(&self.mutex);
            var cmds = commands;
            for (cmds.items) |cmd| {
                self.execute(cmd) catch |err| {
                    std.log.err("desktop {s}: {}", .{ @tagName(cmd.kind), err });
                    self.reportError(@tagName(cmd.kind), err);
                };
                a.free(cmd.path);
                a.free(cmd.value);
                self.refresh.store(true, .release);
            }
            cmds.deinit(a);
            if (self.refresh.swap(false, .acq_rel)) {
                if (self.scan()) |snap| {
                    _ = c.pthread_mutex_lock(&self.mutex);
                    const old = self.pending;
                    self.pending = snap;
                    _ = c.pthread_mutex_unlock(&self.mutex);
                    signal(self.wake_main);
                    if (old) |s| s.destroy();
                } else |err| std.log.warn("desktop scan: {}", .{err});
            }
            var fds = [2]c.struct_pollfd{
                .{ .fd = self.wake_worker, .events = c.POLLIN, .revents = 0 },
                .{ .fd = fd, .events = c.POLLIN, .revents = 0 },
            };
            // Only a failed watch retry needs a clock; commands and
            // filesystem changes wake the poll directly.
            const timeout: c_int = if (fd >= 0 and wd < 0) 1000 else -1;
            _ = c.poll(&fds, fds.len, timeout);
            if (fds[0].revents & c.POLLIN != 0) drain(self.wake_worker);
            if (fds[1].revents & c.POLLIN != 0) {
                var buf: [16384]u8 align(@alignOf(c.struct_inotify_event)) = undefined;
                while (true) {
                    const n = c.read(fd, &buf, buf.len);
                    if (n <= 0) break;
                    var off: usize = 0;
                    while (off + @sizeOf(c.struct_inotify_event) <= @as(usize, @intCast(n))) {
                        const ev: *const c.struct_inotify_event = @ptrCast(@alignCast(&buf[off]));
                        if (ev.mask & (c.IN_IGNORED | c.IN_DELETE_SELF | c.IN_MOVE_SELF) != 0) wd = -1;
                        off += @sizeOf(c.struct_inotify_event) + ev.len;
                    }
                }
                self.refresh.store(true, .release);
            }
        }
    }
    fn execute(self: *Worker, cmd: Command) !void {
        switch (cmd.kind) {
            .send => {
                defer _ = c.close(cmd.fd);
                _ = c.fcntl(cmd.fd, c.F_SETFL, @as(c_int, c.O_NONBLOCK));
                var offset: usize = 0;
                while (offset < cmd.value.len) {
                    var p = c.struct_pollfd{ .fd = cmd.fd, .events = c.POLLOUT, .revents = 0 };
                    if (c.poll(&p, 1, 1000) <= 0) return error.TransferTimeout;
                    const n = c.write(cmd.fd, cmd.value.ptr + offset, cmd.value.len - offset);
                    if (n <= 0) return error.TransferFailed;
                    offset += @intCast(n);
                }
            },
            .catalog => {
                if (self.catalog.len == 0) self.catalog = (try desktop.parser.scanAll(self.catalog_arena.allocator(), self.io, self.environ)).entries;
            },
            .settings => {
                const path = try std.fmt.allocPrint(a, "{s}/config.toml", .{std.fs.path.dirname(self.layout).?});
                defer a.free(path);
                try std.Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(path).?);
                if (std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(65536))) |existing| {
                    a.free(existing);
                } else |_| {
                    try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = "# RediWM desktop (~/.config/rediwm-desktop): choose Refresh after editing\nwallpaper = \"\"\nwallpaper_mode = \"fill\"\nbottom_exclusion = 64\nicon_only_input = false\n" });
                }
                try self.execute(.{ .kind = .launch, .path = path });
            },
            .drop => {
                defer {
                    _ = c.close(cmd.fd);
                    self.drop_done.store(true, .release);
                    signal(self.wake_main);
                }
                self.drop_success.store(false, .release);
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const mem = arena.allocator();
                var data: std.ArrayList(u8) = .empty;
                while (data.items.len < 1024 * 1024) {
                    var p = c.struct_pollfd{ .fd = cmd.fd, .events = c.POLLIN, .revents = 0 };
                    if (c.poll(&p, 1, 2000) <= 0) return error.TransferTimeout;
                    var buf: [4096]u8 = undefined;
                    const n = c.read(cmd.fd, &buf, buf.len);
                    if (n == 0) break;
                    if (n < 0) return error.TransferFailed;
                    try data.appendSlice(mem, buf[0..@intCast(n)]);
                }
                if (data.items.len >= 1024 * 1024) return error.TransferTooLarge;
                var lines = std.mem.splitScalar(u8, data.items, '\n');
                while (lines.next()) |raw| {
                    const uri = std.mem.trim(u8, raw, " \t\r");
                    if (uri.len == 0 or uri[0] == '#' or std.mem.eql(u8, uri, "copy") or std.mem.eql(u8, uri, "cut")) continue;
                    const path = try @import("dnd.zig").localPath(mem, uri);
                    const dest = try std.fmt.allocPrint(mem, "{s}/{s}", .{ cmd.path, std.fs.path.basename(path) });
                    try self.execute(.{ .kind = if (cmd.folder or std.mem.startsWith(u8, data.items, "cut\n")) .move else if (std.mem.eql(u8, cmd.value, "paste")) .copy else .link, .path = path, .value = dest });
                }
                self.drop_success.store(true, .release);
            },
            .save => {
                try std.Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(self.layout).?);
                const temp = try std.fmt.allocPrint(a, "{s}.tmp", .{self.layout});
                defer a.free(temp);
                try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = temp, .data = cmd.value });
                try std.Io.Dir.renameAbsolute(temp, self.layout, self.io);
            },
            .launch => {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const mem = arena.allocator();
                var args: std.ArrayList([]const u8) = .empty;
                const defaults = @import("../config_runtime/default_apps.zig");
                const preferences = defaults.load(mem, self.io, self.environ);
                const entries = if ((cmd.folder and preferences.file_manager.len > 0) or (cmd.terminal and preferences.terminal.len > 0))
                    (try desktop.parser.scanAll(mem, self.io, self.environ)).entries
                else
                    &.{};
                var cwd: std.process.Child.Cwd = .inherit;
                if (cmd.value.len > 0) {
                    if (cmd.terminal) try args.appendSlice(mem, try defaults.terminalPrefix(mem, defaults.find(entries, preferences.terminal), self.environ));
                    const parsed = try @import("../start_menu/launch.zig").parseExec(mem, cmd.value, null);
                    try args.appendSlice(mem, parsed);
                    if (cmd.launch_file) try args.append(mem, cmd.path);
                } else if (if (cmd.folder) defaults.find(entries, preferences.file_manager) else null) |entry| {
                    if (entry.terminal) try args.appendSlice(mem, try defaults.terminalPrefix(mem, defaults.find(entries, preferences.terminal), self.environ));
                    const uris = try @import("dnd.zig").uriList(mem, &.{cmd.path});
                    const uri = std.mem.trimEnd(u8, uris, "\r\n");
                    const parsed = if (entry.exec.len == 0 and entry.dbus_activatable)
                        try mem.dupe([]const u8, &.{ "gio", "launch", entry.desktop_file_path, uri })
                    else
                        try @import("../start_menu/launch.zig").parseExecUris(mem, entry.exec, entry, &.{uri});
                    try args.appendSlice(mem, parsed);
                    // Entries without file field codes still need the requested folder.
                    const without = try @import("../start_menu/launch.zig").parseExec(mem, entry.exec, entry);
                    if (without.len == parsed.len) try args.append(mem, cmd.path);
                    if (entry.path) |path| {
                        if (path.len > 0) cwd = .{ .path = path };
                    }
                } else {
                    try args.appendSlice(mem, &.{ if (cmd.folder and executable(self.environ, "rediwm-files")) "rediwm-files" else "xdg-open", cmd.path });
                }
                if (args.items.len == 0) return error.EmptyCommand;
                var child = try std.process.spawn(self.io, .{ .argv = args.items, .cwd = cwd, .environ_map = &self.child_env });
                var launched = Launched{ .token = cmd.token, .pid = child.id orelse 0 };
                launched.setApp(std.fs.path.stem(std.fs.path.basename(cmd.path)));
                // A launcher names its scope; an opened file names it after the program.
                var started = launched;
                if (!std.mem.endsWith(u8, cmd.path, ".desktop")) started.setApp(std.fs.path.basename(args.items[0]));
                _ = c.pthread_mutex_lock(&self.mutex);
                // Ownership must reach the main loop even for launches without
                // feedback tokens. Never leave an untracked child on overflow.
                if (self.started_len == self.started.len) {
                    _ = c.pthread_mutex_unlock(&self.mutex);
                    child.kill(self.io);
                    return error.TooManyLaunches;
                }
                if (cmd.token != 0) self.launched = launched;
                self.started[self.started_len] = started;
                self.started_len += 1;
                _ = c.pthread_mutex_unlock(&self.mutex);
                signal(self.wake_main);
            },
            .folder => {
                const p = try a.dupeZ(u8, cmd.path);
                defer a.free(p);
                if (c.mkdir(p, 0o755) != 0) return error.CreateFailed;
            },
            .trust => { // Allow Launching: the user's own `chmod u+x`.
                const p = try a.dupeZ(u8, cmd.path);
                defer a.free(p);
                var stat: c.struct_stat = undefined;
                if (c.stat(p, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_uid != c.getuid()) return error.NotYourFile;
                if (c.chmod(p, (stat.st_mode & 0o7777) | c.S_IXUSR) != 0) return error.PermissionChangeFailed;
            },
            .file => {
                const p = try a.dupeZ(u8, cmd.path);
                defer a.free(p);
                const fd = c.open(p, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o644));
                if (fd < 0) return error.CreateFailed;
                _ = c.close(fd);
            },
            .rename, .move => { // No overwriting another desktop item.
                const from = try a.dupeZ(u8, cmd.path);
                defer a.free(from);
                const to = try a.dupeZ(u8, cmd.value);
                defer a.free(to);
                if (c.renameat2(c.AT_FDCWD, from, c.AT_FDCWD, to, 1) != 0) return error.RenameFailed;
            },
            .link => {
                const from = try a.dupeZ(u8, cmd.path);
                defer a.free(from);
                const to = try a.dupeZ(u8, cmd.value);
                defer a.free(to);
                if (c.symlink(from, to) != 0) return error.LinkFailed;
            },
            .delete => try @import("../files/ops.zig").deleteItems(self.io, &.{cmd.path}),
            .trash, .empty_trash, .copy => {
                const args: []const []const u8 = switch (cmd.kind) {
                    .trash => &.{ "gio", "trash", "--", cmd.path },
                    .empty_trash => &.{ "gio", "trash", "--empty" },
                    else => &.{ "cp", "-R", "-n", "--", cmd.path, cmd.value },
                };
                var child = try std.process.spawn(self.io, .{ .argv = args, .environ_map = &self.child_env });
                const result = try child.wait(self.io);
                if (result != .exited or result.exited != 0) return error.FileOperationFailed;
            },
        }
    }
};
fn sameText(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}
fn executable(env: std.process.Environ, name: []const u8) bool {
    var paths = std.mem.splitScalar(u8, env.getPosix("PATH") orelse "", ':');
    while (paths.next()) |p| {
        var buf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ p, name }) catch continue;
        if (c.access(z, c.X_OK) == 0) return true;
    }
    return false;
}
fn mimeIcon(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    if (std.ascii.eqlIgnoreCase(ext, ".png") or std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".svg")) return "image-x-generic";
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return "application-pdf";
    if (std.ascii.eqlIgnoreCase(ext, ".mp3") or std.ascii.eqlIgnoreCase(ext, ".flac")) return "audio-x-generic";
    if (std.ascii.eqlIgnoreCase(ext, ".mp4")) return "video-x-generic";
    if (std.ascii.eqlIgnoreCase(ext, ".zip") or std.ascii.eqlIgnoreCase(ext, ".gz")) return "package-x-generic";
    return "text-x-generic";
}
