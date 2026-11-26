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
    owner_uid: c.uid_t = 0,
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
    theme: ?@import("app_kit").settings.ThemeUpdate = null,

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

    /// Asks the thread to stop and returns at once (`reaper.retire`).
    pub fn requestStop(self: *Worker) void {
        self.stop.store(true, .release);
        self.signal();
    }

    pub fn deinit(self: *Worker) void {
        self.requestStop();
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
        var settings: @import("app_kit").settings.Settings = @import("app_kit").settings.Settings.init(self.allocator, self.environ) catch .{};
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
            self.runQueued();
            if (self.stop.load(.acquire)) break;
            const update = if (theme_watcher.fd < 0) settings.poll(self.allocator, self.io) else if (theme_changed) settings.reload(self.allocator, self.io) else null;
            theme_changed = false;
            if (update) |t| self.applyTheme(t, settings.animations);
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
                self.publishScan(cur_dir, cur_show_hidden, cur_req_id, cur_archive_len, &archive_cache, &dir_watcher, &git_watches);
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

    /// Work other threads queued: an AppImage to register, themes to
    /// install, opened files for Recent.
    fn runQueued(self: *Worker) void {
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
    }

    /// A changed theme: the collation follows its formats locale.
    fn applyTheme(self: *Worker, t: @import("app_kit").settings.ThemeUpdate, animations: @import("ui").anim.Settings) void {
        const requested = collation.Locale.requested(t.region.formats, self.environ);
        if (!std.mem.eql(u8, requested, self.collate.name())) {
            self.collate.deinit();
            self.collate = collation.Locale.fromPreferences(t.region.formats, self.environ);
            self.rescan_requested.store(true, .release);
        }
        _ = c.pthread_mutex_lock(&self.mutex);
        self.animation_settings = animations;
        if (self.theme) |old| old.deinit();
        self.theme = t;
        _ = c.pthread_mutex_unlock(&self.mutex);
        self.scrollbar_width.store(@bitCast(t.value.scrollbar_width), .release);
        notify(self.wake_main);
    }

    /// Scans the folder (or archive) and publishes the snapshot, moving the
    /// Git watches to the repository it found.
    fn publishScan(
        self: *Worker,
        cur_dir: []const u8,
        cur_show_hidden: bool,
        cur_req_id: u64,
        cur_archive_len: usize,
        cache: *ArchiveCache,
        dir_watcher: *platform.watch.Watcher,
        git_watches: *[4]platform.watch.Watch,
    ) void {
        const snap = if (cur_archive_len > 0) self.scanArchive(cur_dir, cur_archive_len, cur_show_hidden, cur_req_id, cache) else self.scan(cur_dir, cur_show_hidden, cur_req_id);
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
            for (git_watches.*) |watch| {
                if (watch >= 0 and std.mem.indexOfScalar(platform.watch.Watch, &next_watches, watch) == null) dir_watcher.remove(watch);
            }
        }
        git_watches.* = next_watches;
        _ = c.pthread_mutex_lock(&self.mutex);
        const old = self.pending_snapshot;
        self.pending_snapshot = snap;
        _ = c.pthread_mutex_unlock(&self.mutex);
        notify(self.wake_main);
        if (old) |o| o.destroy();
    }

    const worker_scan = @import("worker_scan.zig");
    const ArchiveCache = worker_scan.ArchiveCache;
    const scanArchive = worker_scan.scanArchive;
    const scan = worker_scan.scan;
    const prepareCollation = worker_scan.prepareCollation;
};

pub const max_changed_rows = @import("worker_scan.zig").max_changed_rows;
pub const mimeIcon = @import("worker_scan.zig").mimeIcon;
