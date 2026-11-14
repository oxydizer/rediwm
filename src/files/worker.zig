const std = @import("std");
const tr = @import("i18n").tr;
const archive = @import("archive.zig");
const appimage = @import("appimage.zig");
const c = @import("c.zig").api;
const platform = @import("platform");
const theme = @import("../icon_theme.zig");
const icons = @import("../icon_cache.zig");
const git = @import("git.zig");
const recent = @import("recent.zig");
const collation = @import("collation.zig");
const Allocator = std.mem.Allocator;

pub const Item = struct {
    git_status: git.Status = .clean,
    git_lines: ?git.LineCounts = null,
    missing: bool = false,
    name: []const u8,
    /// Path relative to the listed folder, for the flat list of changed files.
    label: []const u8 = "",
    name_key: ?[]const u8 = null,
    label_key: ?[]const u8 = null,
    path: []const u8,
    is_dir: bool,
    is_symlink: bool,
    is_broken: bool,
    bytes: i64,
    mtime: i64,
    opened: i64 = 0,
    mode: c.mode_t = 0,
    owner: []const u8 = "",
    icon_name: []const u8,
    icon_candidates: []const []const u8 = &.{},
};

/// What a pass over the browsed folder's events found: whether anything
/// changed, and whether its watch must be set up again.
const DirScan = struct {
    watch: platform.watch.Watch,
    changed: bool = false,

    fn event(self: *DirScan, ev: platform.watch.Event) void {
        if (ev.flags.isChange()) self.changed = true;
        if (ev.watch == self.watch and ev.flags.lost()) self.watch = platform.watch.none;
    }
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    request_id: u64,
    dir: []const u8,
    items: []Item,
    err_msg: ?[]const u8 = null,
    repository: ?git.Repository = null,
    /// Every changed file below the folder, at any depth: the Git view's flat
    /// list. Empty outside repositories.
    changed: []Item = &.{},
    /// More files changed than `max_changed_rows`; `changed` is cut short.
    changed_truncated: bool = false,
    collation_name: []const u8 = "C",

    pub fn destroy(self: *Snapshot) void {
        self.arena.deinit();
        std.heap.c_allocator.destroy(self);
    }
};

pub const Worker = struct {
    allocator: Allocator,
    io: std.Io,
    environ: std.process.Environ,
    theme_cfg: theme.Config,
    /// Accessed only by the directory worker; snapshots own transformed keys.
    collate: collation.Locale,
    mutex: c.pthread_mutex_t = undefined,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    rescan_requested: std.atomic.Value(bool) = .init(true),

    scrollbar_width: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 8))),

    animation_settings: @import("ui").anim.Settings = .{},
    /// Latest theme from `Settings.poll`; null once the app has taken it.
    theme: ?@import("settings.zig").ThemeUpdate = null,

    // State protected by mutex
    current_dir: []u8,
    archive_len: usize = 0,
    show_hidden: bool = false,
    request_id: u64 = 1,
    pending_snapshot: ?*Snapshot = null,
    opened_paths: std.ArrayList([]u8) = .empty,
    theme_installs: std.ArrayList([]u8) = .empty,
    theme_notice: ?[]u8 = null,
    application_pending: ?[]u8 = null,
    application_busy: bool = false,
    application_notice: ?appimage.Notice = null,
    /// Signalled after each request so the worker sleeps between them
    /// instead of polling on an 80 ms clock.
    wake: c_int = -1,
    /// Signalled when a snapshot or setting is published, so the Wayland
    /// thread can block instead of polling for them.
    wake_main: c_int = -1,

    pub fn init(allocator: Allocator, io: std.Io, environ: std.process.Environ, initial_dir: []const u8) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);

        const theme_cfg = try theme.resolveConfig(allocator, environ);
        errdefer {
            for (theme_cfg.base_dirs) |d| allocator.free(d);
            allocator.free(theme_cfg.base_dirs);
        }

        self.* = .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .theme_cfg = theme_cfg,
            .current_dir = try allocator.dupe(u8, initial_dir),
            .collate = collation.Locale.fromPreferences("", environ),
        };
        errdefer self.collate.deinit();

        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexInitFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        self.wake = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (self.wake < 0) return error.EventFdFailed;
        errdefer _ = c.close(self.wake);
        self.wake_main = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
        if (self.wake_main < 0) return error.EventFdFailed;
        errdefer _ = c.close(self.wake_main);

        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn deinit(self: *Worker) void {
        self.stop.store(true, .release);
        self.signal();
        if (self.thread) |t| t.join();
        self.collate.deinit();
        _ = c.close(self.wake);
        _ = c.close(self.wake_main);
        if (self.pending_snapshot) |s| s.destroy();
        if (self.theme) |t| t.deinit();
        for (self.opened_paths.items) |p| self.allocator.free(p);
        self.opened_paths.deinit(self.allocator);
        for (self.theme_installs.items) |p| self.allocator.free(p);
        self.theme_installs.deinit(self.allocator);
        if (self.theme_notice) |p| self.allocator.free(p);
        if (self.application_pending) |p| self.allocator.free(p);

        for (self.theme_cfg.base_dirs) |d| self.allocator.free(d);
        self.allocator.free(self.theme_cfg.base_dirs);
        self.allocator.free(self.current_dir);
        _ = c.pthread_mutex_destroy(&self.mutex);
        self.allocator.destroy(self);
    }

    pub fn navigateTo(self: *Worker, new_dir: []const u8, show_hidden: bool) u64 {
        return self.navigateLocation(new_dir, show_hidden, 0);
    }

    pub fn installTheme(self: *Worker, path: []const u8) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        const owned = self.allocator.dupe(u8, path) catch return;
        self.theme_installs.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            return;
        };
        self.signal();
    }
    pub fn takeThemeNotice(self: *Worker) ?[]u8 {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        const notice = self.theme_notice;
        self.theme_notice = null;
        return notice;
    }
    fn processTheme(self: *Worker, path: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const mem = arena.allocator();
        const exe_dir = std.process.executableDirPathAlloc(self.io, mem) catch return;
        const helper = std.fs.path.join(mem, &.{ exe_dir, "rediwm-theme" }) catch return;
        const result = std.process.run(mem, self.io, .{ .argv = &.{ helper, "install", path }, .stdout_limit = .limited(4096), .stderr_limit = .limited(16384), .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } } }) catch return;
        const success = result.term == .exited and result.term.exited == 0;
        const message = self.allocator.dupe(u8, if (success) tr("Theme installed. Choose it in Settings → Appearance.") else result.stderr) catch return;
        _ = c.pthread_mutex_lock(&self.mutex);
        if (self.theme_notice) |old| self.allocator.free(old);
        self.theme_notice = message;
        _ = c.pthread_mutex_unlock(&self.mutex);
        notify(self.wake_main);
    }

    pub fn recordOpened(self: *Worker, path: []const u8) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        const owned = self.allocator.dupe(u8, path) catch return;
        self.opened_paths.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            return;
        };
        self.signal();
    }

    pub fn addApplication(self: *Worker, path: []const u8) !void {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        if (self.application_busy) return error.Busy;
        self.application_pending = try self.allocator.dupe(u8, path);
        self.application_busy = true;
        self.signal();
    }

    pub fn takeApplicationNotice(self: *Worker) ?appimage.Notice {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        const notice = self.application_notice;
        self.application_notice = null;
        if (notice != null) self.application_busy = false;
        return notice;
    }

    fn processApplication(self: *Worker, path: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const notice: appimage.Notice = if (appimage.install(arena.allocator(), self.io, self.environ, path))
            .{ .message = tr("Added to applications. Keep the AppImage in its current location.") }
        else |err|
            .{ .message = appimage.message(err), .failed = true };
        _ = c.pthread_mutex_lock(&self.mutex);
        self.application_notice = notice;
        _ = c.pthread_mutex_unlock(&self.mutex);
        notify(self.wake_main);
    }

    pub fn navigateLocation(self: *Worker, new_dir: []const u8, show_hidden: bool, archive_len: usize) u64 {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        const owned = self.allocator.dupe(u8, new_dir) catch return self.request_id;
        self.allocator.free(self.current_dir);
        self.current_dir = owned;
        self.archive_len = archive_len;
        self.show_hidden = show_hidden;
        self.request_id += 1;
        self.rescan_requested.store(true, .release);
        self.signal();
        return self.request_id;
    }

    pub fn refresh(self: *Worker) u64 {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        self.request_id += 1;
        self.rescan_requested.store(true, .release);
        self.signal();
        return self.request_id;
    }

    pub fn setShowHidden(self: *Worker, show: bool) u64 {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        self.show_hidden = show;
        self.request_id += 1;
        self.rescan_requested.store(true, .release);
        self.signal();
        return self.request_id;
    }

    fn signal(self: *Worker) void {
        notify(self.wake);
    }

    fn notify(fd: c_int) void {
        const one: u64 = 1;
        _ = c.write(fd, &one, @sizeOf(u64));
    }

    /// Clears `wake_main` after the Wayland thread's poll saw it readable.
    pub fn drainMain(self: *Worker) void {
        var count: u64 = 0;
        _ = c.read(self.wake_main, &count, @sizeOf(u64));
    }

    pub fn takeSnapshot(self: *Worker) ?*Snapshot {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);

        const snap = self.pending_snapshot;
        self.pending_snapshot = null;
        return snap;
    }

    fn run(self: *Worker) void {
        var settings: @import("settings.zig").Settings = @import("settings.zig").Settings.init(self.allocator, self.environ) catch .{};
        defer settings.deinit(self.allocator);
        // Without file watching the watchers keep fd -1 and the loop polls.
        var dir_watcher = platform.watch.Watcher.init() catch platform.watch.Watcher{};
        defer dir_watcher.deinit();
        // Its own watcher: the browsed folder can be the config directory,
        // and leaving it must not drop the theme watch.
        var theme_watcher = platform.watch.Watcher.init() catch platform.watch.Watcher{};
        defer theme_watcher.deinit();
        if (theme_watcher.fd >= 0) settings.watch(theme_watcher);
        var theme_changed = true;

        var watched_dir: ?[]u8 = null;
        defer if (watched_dir) |d| self.allocator.free(d);

        var archive_cache: ArchiveCache = .{};
        defer archive_cache.clear(self.allocator);
        var dir_watch = platform.watch.none;
        var git_watches: [4]platform.watch.Watch = @splat(platform.watch.none);

        while (true) {
            _ = c.pthread_mutex_lock(&self.mutex);
            const installs = self.theme_installs;
            self.theme_installs = .empty;
            const opened = self.opened_paths;
            self.opened_paths = .empty;
            const application = self.application_pending;
            self.application_pending = null;
            _ = c.pthread_mutex_unlock(&self.mutex);
            if (application) |path| {
                defer self.allocator.free(path);
                if (!self.stop.load(.acquire)) self.processApplication(path);
            }
            for (installs.items) |p| {
                self.processTheme(p);
                self.allocator.free(p);
            }
            var install_storage = installs;
            install_storage.deinit(self.allocator);
            for (opened.items) |p| {
                recent.record(self.allocator, self.io, self.environ, p) catch {};
                self.allocator.free(p);
            }
            var opened_storage = opened;
            opened_storage.deinit(self.allocator);
            if (self.stop.load(.acquire)) break;
            const update = if (theme_watcher.fd < 0) settings.poll(self.allocator, self.io) else if (theme_changed) settings.reload(self.allocator, self.io) else null;
            theme_changed = false;
            if (update) |t| {
                const requested = collation.Locale.requested(t.region.formats, self.environ);
                if (!std.mem.eql(u8, requested, self.collate.name())) {
                    self.collate.deinit();
                    self.collate = collation.Locale.fromPreferences(t.region.formats, self.environ);
                    self.rescan_requested.store(true, .release);
                }
                _ = c.pthread_mutex_lock(&self.mutex);
                self.animation_settings = settings.animations;
                if (self.theme) |old| old.deinit();
                self.theme = t;
                _ = c.pthread_mutex_unlock(&self.mutex);
                self.scrollbar_width.store(@bitCast(t.value.scrollbar_width), .release);
                notify(self.wake_main);
            }
            // Check if directory to watch changed
            var cur_dir: []u8 = undefined;
            var cur_show_hidden: bool = false;
            var cur_req_id: u64 = 0;
            var cur_archive_len: usize = 0;

            {
                _ = c.pthread_mutex_lock(&self.mutex);
                cur_dir = self.allocator.dupe(u8, self.current_dir) catch {
                    _ = c.pthread_mutex_unlock(&self.mutex);
                    _ = c.usleep(50 * 1000);
                    continue;
                };
                cur_show_hidden = self.show_hidden;
                cur_req_id = self.request_id;
                cur_archive_len = self.archive_len;
                _ = c.pthread_mutex_unlock(&self.mutex);
            }
            defer self.allocator.free(cur_dir);

            const dir_changed = watched_dir == null or !std.mem.eql(u8, watched_dir.?, cur_dir);
            if (dir_changed) {
                if (dir_watcher.fd >= 0 and dir_watch >= 0) {
                    dir_watcher.remove(dir_watch);
                    dir_watch = platform.watch.none;
                }
                if (watched_dir) |d| self.allocator.free(d);
                watched_dir = self.allocator.dupe(u8, cur_dir) catch null;

                if (dir_watcher.fd >= 0 and watched_dir != null) {
                    const recent_path = if (recent.isLocation(cur_dir)) recent.path(self.allocator, self.environ) catch null else null;
                    defer if (recent_path) |p| self.allocator.free(p);
                    const watch_path = if (recent_path) |p| std.fs.path.dirname(p).? else if (cur_archive_len > 0) std.fs.path.dirname(cur_dir[0..cur_archive_len]) orelse "/" else watched_dir.?;
                    // A first-run data directory may not exist yet. Watch
                    // its nearest existing parent until it is created.
                    const found = if (recent_path != null) dir_watcher.addOrParent(watch_path, .listing) else dir_watcher.add(watch_path, .listing);
                    dir_watch = found orelse platform.watch.none;
                }
            }

            if (dir_changed or self.rescan_requested.swap(false, .acq_rel)) {
                const snap = if (cur_archive_len > 0) self.scanArchive(cur_dir, cur_archive_len, cur_show_hidden, cur_req_id, &archive_cache) else self.scan(cur_dir, cur_show_hidden, cur_req_id);
                self.prepareCollation(snap) catch {
                    snap.items = &.{};
                    snap.changed = &.{};
                    snap.err_msg = tr("Could not sort folder names");
                };
                // Register new watches before dropping old ones. Re-adding an
                // existing path returns its descriptor and creates no events.
                var next_watches: [4]platform.watch.Watch = @splat(platform.watch.none);
                if (dir_watcher.fd >= 0) {
                    if (snap.repository) |repo| {
                        for (repo.watch_paths, 0..) |path, i| {
                            next_watches[i] = dir_watcher.add(path, .{ .created = true, .deleted = true, .moved_from = true, .moved_to = true, .written = true }) orelse platform.watch.none;
                        }
                    }
                    for (git_watches) |watch| {
                        if (watch >= 0 and std.mem.indexOfScalar(platform.watch.Watch, &next_watches, watch) == null) dir_watcher.remove(watch);
                    }
                }
                git_watches = next_watches;
                _ = c.pthread_mutex_lock(&self.mutex);
                const old = self.pending_snapshot;
                self.pending_snapshot = snap;
                _ = c.pthread_mutex_unlock(&self.mutex);
                notify(self.wake_main);
                if (old) |o| o.destroy();
            }

            if (dir_watcher.fd >= 0) {
                var fds = [3]c.struct_pollfd{
                    .{ .fd = self.wake, .events = c.POLLIN, .revents = 0 },
                    .{ .fd = dir_watcher.fd, .events = c.POLLIN, .revents = 0 },
                    .{ .fd = theme_watcher.fd, .events = c.POLLIN, .revents = 0 },
                };
                // Requests, directory and theme changes wake the poll. Without
                // a theme watch the timeout paces Settings.poll's once-a-second stat.
                const poll_res = c.poll(&fds, fds.len, if (theme_watcher.fd >= 0) -1 else 1000);
                if (poll_res > 0 and (fds[2].revents & c.POLLIN != 0)) {
                    _ = theme_watcher.flush();
                    settings.watch(theme_watcher);
                    theme_changed = true;
                }
                if (poll_res > 0 and (fds[0].revents & c.POLLIN != 0)) {
                    var count: u64 = 0;
                    _ = c.read(self.wake, &count, @sizeOf(u64));
                }
                if (poll_res > 0 and (fds[1].revents & c.POLLIN != 0)) {
                    var events: DirScan = .{ .watch = dir_watch };
                    dir_watcher.drain(&events, DirScan.event) catch {};
                    dir_watch = events.watch;
                    if (events.changed) {
                        self.rescan_requested.store(true, .release);
                        if (recent.isLocation(cur_dir)) {
                            // Re-establish the watch after creation or replacement
                            // of the data directory, without a periodic rescan.
                            if (watched_dir) |d| self.allocator.free(d);
                            watched_dir = null;
                        }
                    }
                }
            } else {
                _ = c.usleep(80 * 1000);
            }
        }
    }

    const ArchiveCache = struct {
        path: ?[]u8 = null,
        stat: c.struct_stat = undefined,
        index: ?archive.Index = null,
        fn clear(self: *ArchiveCache, mem: Allocator) void {
            if (self.path) |p| mem.free(p);
            if (self.index) |*index| index.deinit();
            self.* = .{};
        }
    };

    fn scanArchive(self: *Worker, path: []const u8, archive_len: usize, hidden: bool, request: u64, cache: *ArchiveCache) *Snapshot {
        const snap = std.heap.c_allocator.create(Snapshot) catch @panic("OOM");
        snap.* = .{ .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator), .request_id = request, .dir = "", .items = &.{} };
        self.fillArchive(snap, path, archive_len, hidden, cache) catch |err| {
            snap.items = &.{};
            snap.err_msg = archive.message(err);
        };
        return snap;
    }

    fn fillArchive(self: *Worker, snap: *Snapshot, path: []const u8, archive_len: usize, hidden: bool, cache: *ArchiveCache) !void {
        const mem = snap.arena.allocator();
        snap.dir = try mem.dupe(u8, path);
        const source = path[0..archive_len];
        const zsource = try mem.dupeSentinel(u8, source, 0);
        var stat: c.struct_stat = undefined;
        if (c.stat(zsource, &stat) != 0) return error.OpenArchiveFailed;
        if (cache.path == null or !std.mem.eql(u8, cache.path.?, source) or
            cache.stat.st_ino != stat.st_ino or cache.stat.st_dev != stat.st_dev or cache.stat.st_size != stat.st_size or
            !std.meta.eql(cache.stat.st_mtim, stat.st_mtim) or !std.meta.eql(cache.stat.st_ctim, stat.st_ctim))
        {
            cache.clear(self.allocator);
            var index = try archive.Index.read(self.allocator, source, &self.stop);
            errdefer index.deinit();
            cache.path = try self.allocator.dupe(u8, source);
            cache.index = index;
            cache.stat = stat;
        }
        const member_dir = if (path.len > archive_len) path[archive_len + 1 ..] else "";
        var exists = member_dir.len == 0;
        var items: std.ArrayList(Item) = .empty;
        for (cache.index.?.entries) |entry| {
            if (entry.directory and std.mem.eql(u8, entry.path, member_dir)) exists = true;
            if (!std.mem.eql(u8, std.fs.path.dirname(entry.path) orelse "", member_dir)) continue;
            const name = std.fs.path.basename(entry.path);
            if (!hidden and std.mem.startsWith(u8, name, ".")) continue;
            try items.append(mem, .{
                .name = try mem.dupe(u8, name),
                .path = try std.fmt.allocPrint(mem, "{s}/{s}", .{ source, entry.path }),
                .is_dir = entry.directory,
                .is_symlink = entry.link,
                .is_broken = entry.link,
                .bytes = entry.bytes,
                .mtime = entry.mtime,
                .icon_name = mimeIcon(name, entry.directory, entry.link, entry.link),
            });
        }
        if (!exists) return error.MemberNotFound;
        snap.items = try items.toOwnedSlice(mem);
    }

    fn scan(self: *Worker, dir_path: []const u8, show_hidden: bool, req_id: u64) *Snapshot {
        const snap = std.heap.c_allocator.create(Snapshot) catch @panic("OOM");
        snap.* = .{
            .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator),
            .request_id = req_id,
            .dir = "",
            .items = &.{},
            .err_msg = null,
        };
        const mem = snap.arena.allocator();
        snap.dir = mem.dupe(u8, dir_path) catch {
            snap.err_msg = tr("Out of memory");
            return snap;
        };

        if (recent.isLocation(dir_path)) {
            const entries = recent.read(mem, self.io, self.environ) catch {
                snap.err_msg = tr("Could not read recent files");
                return snap;
            };
            var list: std.ArrayList(Item) = .empty;
            var owners: std.AutoHashMapUnmanaged(c.uid_t, []const u8) = .empty;
            var associations: @import("associations.zig").Resolver = .{ .allocator = mem };
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            for (entries) |entry| {
                const name = std.fs.path.basename(entry.path);
                if (!show_hidden and std.mem.startsWith(u8, name, ".")) continue;
                if (seen.contains(entry.path)) continue;
                var item = statItem(mem, &owners, &associations, name, entry.path) orelse continue;
                if (item.is_dir or item.is_broken or (item.mode & c.S_IFMT != c.S_IFREG and !item.is_symlink)) continue;
                item.opened = entry.opened;
                seen.put(mem, entry.path, {}) catch continue;
                if (item.is_dir) item.icon_name = theme.folderName(mem, self.io, self.environ, item.path);
                list.append(mem, item) catch continue;
            }
            snap.items = list.toOwnedSlice(mem) catch &.{};
            return snap;
        }

        var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch |err| {
            snap.err_msg = switch (err) {
                error.FileNotFound => tr("Folder not found"),
                error.AccessDenied => tr("Permission denied"),
                error.NotDir => tr("Not a directory"),
                else => tr("Could not open folder"),
            };
            return snap;
        };
        defer dir.close(self.io);

        var it = dir.iterate();
        var list: std.ArrayList(Item) = .empty;
        var owners: std.AutoHashMapUnmanaged(c.uid_t, []const u8) = .empty;
        var associations: @import("associations.zig").Resolver = .{ .allocator = mem };

        while (it.next(self.io) catch null) |entry| {
            if (!show_hidden and std.mem.startsWith(u8, entry.name, ".")) continue;
            const full_path = std.fmt.allocPrintSentinel(mem, "{s}/{s}", .{ dir_path, entry.name }, 0) catch continue;
            var item = statItem(mem, &owners, &associations, entry.name, full_path) orelse continue;
            if (item.is_dir) item.icon_name = theme.folderName(mem, self.io, self.environ, item.path);
            list.append(mem, item) catch continue;
        }

        // Temporarily disable Git integration while file operations are being completed.
        const git_enabled = false;
        snap.repository = if (git_enabled) git.scan(mem, self.io, self.environ, dir_path) catch null else null;
        if (snap.repository) |repo| {
            for (list.items) |*item| {
                item.git_status = repo.status(item.name);
                item.git_lines = repo.lines(item.name);
            }
            snap.changed = changedItems(mem, repo, dir_path, show_hidden, &owners, &associations, &snap.changed_truncated);
            // Missing tracked files are informational rows, never file-operation targets.
            const prefix = if (repo.directory.len > repo.root.len) repo.directory[repo.root.len + 1 ..] else "";
            for (repo.changes) |change| {
                if (change.status != .deleted) continue;
                var name = change.path;
                if (prefix.len > 0) {
                    if (!std.mem.startsWith(u8, name, prefix) or name.len <= prefix.len or name[prefix.len] != '/') continue;
                    name = name[prefix.len + 1 ..];
                }
                if (std.mem.indexOfScalar(u8, name, '/') != null or (!show_hidden and std.mem.startsWith(u8, name, "."))) continue;
                var exists = false;
                for (list.items) |item| {
                    if (std.mem.eql(u8, item.name, name)) {
                        exists = true;
                        break;
                    }
                }
                if (exists) continue;
                list.append(mem, .{ .name = name, .path = std.fmt.allocPrint(mem, "{s}/{s}", .{ dir_path, name }) catch continue, .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 0, .icon_name = mimeIcon(name, false, false, false), .git_status = .deleted, .git_lines = repo.lines(name), .missing = true }) catch {};
            }
        }

        snap.items = list.toOwnedSlice(mem) catch &.{};
        return snap;
    }

    fn prepareCollation(self: *Worker, snap: *Snapshot) !void {
        const mem = snap.arena.allocator();
        snap.collation_name = try mem.dupe(u8, self.collate.name());
        for ([_][]Item{ snap.items, snap.changed }) |items| for (items) |*item| {
            item.name_key = try self.collate.key(mem, item.name);
            if (item.label.len > 0) item.label_key = try self.collate.key(mem, item.label);
        };
        // Freeze expensive libc transformations once, also for archive and
        // Recent listings. UI re-sorts compare these byte keys only.
        std.mem.sort(Item, snap.items, {}, struct {
            fn less(_: void, a: Item, b: Item) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                return collation.order(a.name_key.?, b.name_key.?, a.name, b.name, a.path, b.path) == .lt;
            }
        }.less);
    }
};

/// Describes one directory entry, or null when it vanished or cannot be read.
fn statItem(
    mem: Allocator,
    owners: *std.AutoHashMapUnmanaged(c.uid_t, []const u8),
    associations: *@import("associations.zig").Resolver,
    name: []const u8,
    full_path: [:0]const u8,
) ?Item {
    var lstat_buf: c.struct_stat = undefined;
    if (c.lstat(full_path, &lstat_buf) != 0) return null;

    const is_symlink = (lstat_buf.st_mode & c.S_IFMT) == c.S_IFLNK;
    var is_dir = false;
    var is_broken = false;
    var size = @as(i64, @intCast(lstat_buf.st_size));

    if (is_symlink) {
        var target_stat: c.struct_stat = undefined;
        if (c.stat(full_path, &target_stat) == 0) {
            is_dir = (target_stat.st_mode & c.S_IFMT) == c.S_IFDIR;
            size = @as(i64, @intCast(target_stat.st_size));
        } else {
            is_broken = true;
        }
    } else {
        is_dir = (lstat_buf.st_mode & c.S_IFMT) == c.S_IFDIR;
    }

    return .{
        .name = mem.dupe(u8, name) catch return null,
        .path = full_path,
        .is_dir = is_dir,
        .is_symlink = is_symlink,
        .is_broken = is_broken,
        .bytes = size,
        .mtime = @as(i64, @intCast(lstat_buf.st_mtim.tv_sec)),
        .mode = lstat_buf.st_mode,
        .owner = owners.get(lstat_buf.st_uid) orelse blk: {
            const owner = ownerName(mem, lstat_buf.st_uid) catch return null;
            owners.put(mem, lstat_buf.st_uid, owner) catch {};
            break :blk owner;
        },
        .icon_name = mimeIcon(name, is_dir, is_symlink, is_broken),
        .icon_candidates = if (is_dir or is_broken) &.{} else associations.candidates(full_path) catch &.{},
    };
}

pub const max_changed_rows = 10_000;

fn hasHiddenComponent(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, ".")) return true;
    }
    return false;
}

/// One row per changed file under the folder, however deep. `label` is the
/// path from the folder, so identical names in different places stay apart.
fn changedItems(
    mem: Allocator,
    repo: git.Repository,
    dir_path: []const u8,
    show_hidden: bool,
    owners: *std.AutoHashMapUnmanaged(c.uid_t, []const u8),
    associations: *@import("associations.zig").Resolver,
    truncated: *bool,
) []Item {
    const prefix = if (repo.directory.len > repo.root.len) repo.directory[repo.root.len + 1 ..] else "";
    var list: std.ArrayList(Item) = .empty;
    // Git can report one path twice, such as a staged deletion of a file that
    // was then recreated; the rows merge like the folder listing's statuses.
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    for (repo.changes) |change| {
        var rel = change.path;
        if (prefix.len > 0) {
            if (!std.mem.startsWith(u8, rel, prefix) or rel.len <= prefix.len or rel[prefix.len] != '/') continue;
            rel = rel[prefix.len + 1 ..];
        }
        if (rel.len == 0 or (!show_hidden and hasHiddenComponent(rel))) continue;
        if (seen.get(rel)) |i| {
            const row = &list.items[i];
            const status: git.Status = if (change.status == .deleted and !row.missing) .modified else change.status;
            if (row.git_status == .conflict or status == .conflict) {
                row.git_status = .conflict;
            } else if (row.git_status != status) row.git_status = .modified;
            row.git_lines = git.LineCounts.merge(row.git_lines, change.lines);
            continue;
        }
        if (list.items.len >= max_changed_rows) {
            truncated.* = true;
            break;
        }
        const full_path = std.fmt.allocPrintSentinel(mem, "{s}/{s}", .{ dir_path, rel }, 0) catch continue;
        const base = std.fs.path.basename(rel);
        var item = statItem(mem, owners, associations, base, full_path) orelse blk: {
            // Only a deletion may be absent from the disk; anything else vanished mid-scan.
            if (change.status != .deleted) continue;
            break :blk Item{ .name = base, .path = full_path, .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 0, .icon_name = mimeIcon(base, false, false, false), .missing = true };
        };
        item.label = rel;
        item.git_status = if (item.missing) .deleted else if (change.status == .deleted) .modified else change.status;
        item.git_lines = change.lines;
        seen.put(mem, rel, list.items.len) catch {};
        list.append(mem, item) catch continue;
    }
    return list.toOwnedSlice(mem) catch &.{};
}

pub fn mimeIcon(name: []const u8, is_dir: bool, is_symlink: bool, is_broken: bool) []const u8 {
    _ = is_symlink;
    if (is_broken) return "dialog-warning";
    if (is_dir) return "folder";

    const ext = std.fs.path.extension(name);
    if (std.ascii.eqlIgnoreCase(ext, ".png") or std.ascii.eqlIgnoreCase(ext, ".jpg") or
        std.ascii.eqlIgnoreCase(ext, ".jpeg") or std.ascii.eqlIgnoreCase(ext, ".svg") or
        std.ascii.eqlIgnoreCase(ext, ".webp") or std.ascii.eqlIgnoreCase(ext, ".gif"))
    {
        return "image-x-generic";
    }
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return "application-pdf";
    if (std.ascii.eqlIgnoreCase(ext, ".mp3") or std.ascii.eqlIgnoreCase(ext, ".flac") or
        std.ascii.eqlIgnoreCase(ext, ".wav") or std.ascii.eqlIgnoreCase(ext, ".ogg"))
    {
        return "audio-x-generic";
    }
    if (std.ascii.eqlIgnoreCase(ext, ".mp4") or std.ascii.eqlIgnoreCase(ext, ".mkv") or
        std.ascii.eqlIgnoreCase(ext, ".webm") or std.ascii.eqlIgnoreCase(ext, ".avi"))
    {
        return "video-x-generic";
    }
    if (std.ascii.eqlIgnoreCase(ext, ".zip") or std.ascii.eqlIgnoreCase(ext, ".tar") or
        std.ascii.eqlIgnoreCase(ext, ".gz") or std.ascii.eqlIgnoreCase(ext, ".xz") or
        std.ascii.eqlIgnoreCase(ext, ".7z"))
    {
        return "package-x-generic";
    }
    if (std.ascii.eqlIgnoreCase(ext, ".sh") or std.ascii.eqlIgnoreCase(ext, ".bash") or
        std.ascii.eqlIgnoreCase(ext, ".py") or std.ascii.eqlIgnoreCase(ext, ".zig") or
        std.ascii.eqlIgnoreCase(ext, ".c") or std.ascii.eqlIgnoreCase(ext, ".h") or
        std.ascii.eqlIgnoreCase(ext, ".cpp"))
    {
        return "text-x-script";
    }
    if (std.ascii.eqlIgnoreCase(ext, ".desktop")) return "application-x-executable";
    return "text-x-generic";
}

// Resolve once per UID per snapshot, off the UI thread. Use the reentrant
// lookup because other workers may also be consulting the account database.
fn ownerName(mem: Allocator, uid: c.uid_t) ![]const u8 {
    var size: usize = 1024;
    while (size <= 1024 * 1024) : (size *= 2) {
        const buffer = try mem.alloc(u8, size);
        defer mem.free(buffer);
        var entry: c.struct_passwd = undefined;
        var result: ?*c.struct_passwd = null;
        const err = c.getpwuid_r(uid, &entry, buffer.ptr, buffer.len, &result);
        if (err == c.ERANGE) continue;
        if (err == 0 and result != null) return mem.dupe(u8, std.mem.span(entry.pw_name));
        break;
    }
    return std.fmt.allocPrint(mem, "{d}", .{uid});
}
