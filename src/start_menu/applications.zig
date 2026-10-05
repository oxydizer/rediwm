// Desktop entry catalog for the start menu.
//
// Scans XDG application directories in specification-defined precedence order:
// 1. $XDG_DATA_HOME/applications (or ~/.local/share/applications)
// 2. $XDG_DATA_DIRS/applications (or /usr/local/share/applications, /usr/share/applications)
//
// Desktop file IDs are resolved before filtering so that a user entry with
// Hidden=true tombstones that ID and prevents the system entry from being exposed.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const c = std.posix.system;
const wl = @import("wayland").server.wl;
const linux = std.os.linux;

const catalog_cache = @import("catalog_cache.zig");
const startup = @import("../startup.zig");
const stats = @import("../ipc/stats.zig");

const log = std.log.scoped(.catalog);

pub const AppEntry = struct {
    id: []const u8,
    desktop_file_path: []const u8,
    name: []const u8,
    generic_name: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    /// Value of the desktop file's StartupWMClass= key, if present.  This is
    /// the string Wayland/X11 clients advertise as their app_id / WM_CLASS,
    /// and it often differs from the Icon= name (e.g. "brave-browser" vs
    /// "brave-desktop").  Stored so the taskbar can resolve the right icon.
    startup_wm_class: ?[]const u8 = null,
    exec: []const u8,
    path: ?[]const u8 = null,
    try_exec: ?[]const u8 = null,
    terminal: bool = false,
    keywords: []const u8 = "",
    categories: []const u8 = "",
    dbus_activatable: bool = false,
};

pub const Locale = struct {
    lang: []const u8 = "",
    country: []const u8 = "",
    modifier: []const u8 = "",

    pub fn fromEnv(environ: std.process.Environ) Locale {
        const raw = environ.getPosix("LC_ALL") orelse
            environ.getPosix("LC_MESSAGES") orelse
            environ.getPosix("LANG") orelse return .{};
        return parseLocale(raw);
    }

    pub fn parseLocale(raw: []const u8) Locale {
        var loc = Locale{};
        var rest = raw;
        // Strip encoding (.UTF-8)
        if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
            const before_dot = rest[0..dot];
            const after_dot = rest[dot + 1 ..];
            if (std.mem.indexOfScalar(u8, after_dot, '@')) |at| {
                loc.modifier = after_dot[at + 1 ..];
            }
            rest = before_dot;
        } else if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
            loc.modifier = rest[at + 1 ..];
            rest = rest[0..at];
        }

        if (std.mem.indexOfScalar(u8, rest, '_')) |us| {
            loc.lang = rest[0..us];
            loc.country = rest[us + 1 ..];
        } else {
            loc.lang = rest;
        }
        return loc;
    }
};

pub const ParsedEntry = struct {
    is_application: bool = false,
    no_display: bool = false,
    hidden: bool = false,
    try_exec: ?[]const u8 = null,
    only_show_in: ?[]const u8 = null,
    not_show_in: ?[]const u8 = null,
    name: ?[]const u8 = null,
    generic_name: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    startup_wm_class: ?[]const u8 = null,
    exec: ?[]const u8 = null,
    path: ?[]const u8 = null,
    terminal: bool = false,
    keywords: ?[]const u8 = null,
    categories: ?[]const u8 = null,
    dbus_activatable: bool = false,
};

/// Parses a desktop entry file content.
pub fn parseDesktopFile(arena: Allocator, content: []const u8, locale: Locale) ?ParsedEntry {
    var entry = ParsedEntry{};
    var in_desktop_entry = false;

    // Match priority for localized keys: 0 = unlocalized, 1 = lang, 2 = lang_country, 3 = lang_country@mod
    var name_prio: u8 = 0;
    var generic_prio: u8 = 0;
    var comment_prio: u8 = 0;
    var keywords_prio: u8 = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const section = line[1..close];
            in_desktop_entry = std.mem.eql(u8, section, "Desktop Entry");
            continue;
        }
        if (!in_desktop_entry) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const raw_key = std.mem.trim(u8, line[0..eq], " \t");
        const raw_val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        // Split key and locale tag e.g. "Name[de_DE]"
        var key_name = raw_key;
        var key_locale: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, raw_key, '[')) |bracket| {
            if (std.mem.endsWith(u8, raw_key, "]")) {
                key_name = raw_key[0..bracket];
                key_locale = raw_key[bracket + 1 .. raw_key.len - 1];
            }
        }

        if (std.mem.eql(u8, key_name, "Type")) {
            entry.is_application = std.mem.eql(u8, raw_val, "Application");
        } else if (std.mem.eql(u8, key_name, "NoDisplay")) {
            entry.no_display = std.mem.eql(u8, raw_val, "true");
        } else if (std.mem.eql(u8, key_name, "Hidden")) {
            entry.hidden = std.mem.eql(u8, raw_val, "true");
        } else if (std.mem.eql(u8, key_name, "Terminal")) {
            entry.terminal = std.mem.eql(u8, raw_val, "true");
        } else if (std.mem.eql(u8, key_name, "DBusActivatable")) {
            entry.dbus_activatable = std.mem.eql(u8, raw_val, "true");
        } else if (std.mem.eql(u8, key_name, "TryExec")) {
            entry.try_exec = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "Exec")) {
            entry.exec = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "Path")) {
            entry.path = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "Icon")) {
            entry.icon = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "StartupWMClass")) {
            entry.startup_wm_class = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "Categories")) {
            entry.categories = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "OnlyShowIn")) {
            entry.only_show_in = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "NotShowIn")) {
            entry.not_show_in = unescape(arena, raw_val) catch raw_val;
        } else if (std.mem.eql(u8, key_name, "Name")) {
            const prio = localePriority(key_locale, locale);
            if (prio > name_prio or entry.name == null) {
                entry.name = unescape(arena, raw_val) catch raw_val;
                name_prio = prio;
            }
        } else if (std.mem.eql(u8, key_name, "GenericName")) {
            const prio = localePriority(key_locale, locale);
            if (prio > generic_prio or entry.generic_name == null) {
                entry.generic_name = unescape(arena, raw_val) catch raw_val;
                generic_prio = prio;
            }
        } else if (std.mem.eql(u8, key_name, "Comment")) {
            const prio = localePriority(key_locale, locale);
            if (prio > comment_prio or entry.comment == null) {
                entry.comment = unescape(arena, raw_val) catch raw_val;
                comment_prio = prio;
            }
        } else if (std.mem.eql(u8, key_name, "Keywords")) {
            const prio = localePriority(key_locale, locale);
            if (prio > keywords_prio or entry.keywords == null) {
                entry.keywords = unescape(arena, raw_val) catch raw_val;
                keywords_prio = prio;
            }
        }
    }

    if (!entry.is_application or entry.name == null or entry.name.?.len == 0) return null;
    return entry;
}

fn localePriority(key_loc: ?[]const u8, target: Locale) u8 {
    const k = key_loc orelse return 1; // Unlocalized is lowest valid priority
    if (target.lang.len == 0) return 0;

    const parsed = Locale.parseLocale(k);
    if (!std.mem.eql(u8, parsed.lang, target.lang)) return 0;

    if (target.modifier.len > 0 and std.mem.eql(u8, parsed.modifier, target.modifier) and
        target.country.len > 0 and std.mem.eql(u8, parsed.country, target.country))
    {
        return 5;
    }
    if (target.country.len > 0 and std.mem.eql(u8, parsed.country, target.country)) {
        return 4;
    }
    if (target.modifier.len > 0 and std.mem.eql(u8, parsed.modifier, target.modifier)) {
        return 3;
    }
    if (parsed.country.len == 0 and parsed.modifier.len == 0) {
        return 2;
    }
    return 0;
}

fn unescape(allocator: Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                's' => try out.append(allocator, ' '),
                'n' => try out.append(allocator, '\n'),
                't' => try out.append(allocator, '\t'),
                'r' => try out.append(allocator, '\r'),
                '\\' => try out.append(allocator, '\\'),
                else => try out.append(allocator, s[i]),
            }
        } else {
            try out.append(allocator, s[i]);
        }
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

pub fn checkTryExec(try_exec: []const u8, environ: std.process.Environ) bool {
    if (try_exec.len == 0) return true;
    if (try_exec[0] == '/') {
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        if (try_exec.len >= buf.len) return false;
        @memcpy(buf[0..try_exec.len], try_exec);
        buf[try_exec.len] = 0;
        const zpath: [*:0]const u8 = buf[0..try_exec.len :0];
        return c.access(zpath, c.X_OK) == 0;
    }

    const path_env = environ.getPosix("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        const candidate = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, try_exec }) catch continue;
        if (c.access(candidate.ptr, c.X_OK) == 0) return true;
    }
    return false;
}

pub fn checkDesktopVisibility(parsed: ParsedEntry, current_desktop: ?[]const u8) bool {
    if (parsed.hidden or parsed.no_display) return false;

    if (current_desktop) |desk| {
        if (parsed.not_show_in) |not_show| {
            var it = std.mem.splitScalar(u8, not_show, ';');
            while (it.next()) |d| {
                if (d.len > 0 and std.ascii.eqlIgnoreCase(d, desk)) return false;
            }
        }
        if (parsed.only_show_in) |only_show| {
            var found = false;
            var it = std.mem.splitScalar(u8, only_show, ';');
            while (it.next()) |d| {
                if (d.len > 0 and std.ascii.eqlIgnoreCase(d, desk)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
    }
    return true;
}

pub const Snapshot = struct {
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    arena: std.heap.ArenaAllocator,
    parent_allocator: Allocator,
    entries: []const AppEntry = &.{},
    sources: []const catalog_cache.SourceIdent = &.{},
    generation: u64 = 0,
    epoch: u64 = 0,
    provisional: bool = false,
    loading: bool = false,
    from_cache: bool = false,
    scan_ns: u64 = 0,

    pub fn create(parent: Allocator) !*Snapshot {
        const snap = try parent.create(Snapshot);
        snap.* = .{
            .arena = std.heap.ArenaAllocator.init(parent),
            .parent_allocator = parent,
        };
        return snap;
    }

    pub fn retain(self: *Snapshot) *Snapshot {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *Snapshot) void {
        if (self.refs.fetchSub(1, .release) == 1) {
            _ = self.refs.load(.acquire);
            const parent = self.parent_allocator;
            self.arena.deinit();
            parent.destroy(self);
        }
    }

    pub fn allocator(self: *Snapshot) Allocator {
        return self.arena.allocator();
    }
};

pub const Catalog = struct {
    allocator: Allocator,
    io: Io,
    environ: std.process.Environ,
    mutex: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,
    cond: c.pthread_cond_t = c.PTHREAD_COND_INITIALIZER,
    current: *Snapshot,
    pending: ?*Snapshot = null,
    generation: u64 = 0,
    epoch: u64 = 0,
    refresh_requested: bool = false,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    eventfd: posix.fd_t = -1,
    thread: ?std.Thread = null,
    delay_ns: u64 = 0,

    watch_fd: i32 = -1,
    watch_source: ?*wl.EventSource = null,
    watch_wds: std.ArrayList(i32) = .empty,
    watched_paths: std.StringHashMapUnmanaged(void) = .empty,

    /// `scan` false leaves the catalog empty and never touches the cache
    /// (the greeter has no start menu).
    pub fn init(allocator: Allocator, io: Io, environ: std.process.Environ, scan: bool) !*Catalog {
        const cat = try allocator.create(Catalog);
        errdefer allocator.destroy(cat);

        const loading = try Snapshot.create(allocator);
        loading.loading = scan;

        const efd = c.eventfd(0, @intCast(std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK));
        if (efd < 0) {
            loading.release();
            allocator.destroy(cat);
            return error.EventFdFailed;
        }
        errdefer _ = c.close(efd);

        cat.* = .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .current = loading,
            .eventfd = efd,
            .delay_ns = startup.envDelayNs(environ, "REDIWM_CATALOG_SCAN_DELAY_MS"),
        };

        if (!scan) {} else if (cat.readCacheSnapshot()) |snap| {
            cat.current.release();
            cat.current = snap;
            cat.generation = 1;
            snap.generation = 1;
            startup.markCatalogCacheRead(snap.scan_ns, @intCast(snap.entries.len));
        } else {
            startup.markCatalogLoading();
        }

        cat.thread = std.Thread.spawn(.{}, worker, .{cat}) catch {
            log.warn("catalog worker failed to start; scanning on the compositor thread", .{});
            if (scan) cat.scanOnThisThread();
            return cat;
        };
        if (scan) cat.requestRefresh();
        return cat;
    }

    pub fn wakeFd(self: *const Catalog) posix.fd_t {
        return self.eventfd;
    }

    pub fn attachWatch(self: *Catalog, loop: *wl.EventLoop) void {
        const fd = std.c.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (fd < 0) return;
        self.watch_fd = fd;
        self.watch_source = loop.addFd(*Catalog, fd, .{ .readable = true }, handleInotify, self) catch {
            _ = std.c.close(fd);
            self.watch_fd = -1;
            return;
        };
        self.syncWatches();
    }

    pub fn deinit(self: *Catalog) void {
        self.running.store(false, .seq_cst);
        self.lock();
        self.broadcast();
        self.unlock();
        if (self.thread) |t| t.join();

        if (self.watch_source) |src| src.remove();
        if (self.watch_fd >= 0) _ = std.c.close(self.watch_fd);
        var it = self.watched_paths.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.watched_paths.deinit(self.allocator);
        self.watch_wds.deinit(self.allocator);

        if (self.eventfd >= 0) _ = c.close(self.eventfd);
        if (self.pending) |snap| snap.release();
        self.current.release();
        self.allocator.destroy(self);
    }

    /// Caller must `release` the returned generation.
    pub fn retainSnapshot(self: *Catalog) *Snapshot {
        self.lock();
        defer self.unlock();
        return self.current.retain();
    }

    pub fn requestRefresh(self: *Catalog) void {
        self.lock();
        self.refresh_requested = true;
        self.epoch += 1;
        self.signal();
        self.unlock();
    }

    pub fn refreshAsync(self: *Catalog) void {
        self.requestRefresh();
    }

    /// Compositor thread. Returns true if the published generation changed.
    pub fn drainCompletions(self: *Catalog) bool {
        var discard: [8]u8 = undefined;
        _ = c.read(self.eventfd, &discard, discard.len);

        self.lock();
        const incoming = self.pending;
        self.pending = null;
        const old: ?*Snapshot = if (incoming != null) self.current else null;
        if (incoming) |snap| {
            self.generation += 1;
            snap.generation = self.generation;
            self.current = snap;
        }
        self.unlock();

        const published = incoming orelse return false;
        if (old) |prev| prev.release();
        startup.markCatalogPublished(published.scan_ns, @intCast(published.entries.len), published.provisional, published.generation);
        self.syncWatches();
        return true;
    }

    fn scanOnThisThread(self: *Catalog) void {
        const snap = self.buildSnapshot(self.current, self.epoch) orelse return;
        const old = self.current;
        self.generation += 1;
        snap.generation = self.generation;
        self.current = snap;
        old.release();
        startup.markCatalogPublished(snap.scan_ns, @intCast(snap.entries.len), snap.provisional, snap.generation);
    }

    fn worker(self: *Catalog) void {
        while (true) {
            self.lock();
            while (self.running.load(.seq_cst) and !self.refresh_requested) self.wait();
            if (!self.running.load(.seq_cst)) {
                self.unlock();
                break;
            }
            self.refresh_requested = false;
            const epoch = self.epoch;
            const baseline = self.current.retain();
            self.unlock();
            defer baseline.release();

            const snap = self.buildSnapshot(baseline, epoch) orelse continue;
            if (!self.running.load(.seq_cst)) {
                snap.release();
                break;
            }

            self.lock();
            if (!self.running.load(.seq_cst)) {
                self.unlock();
                snap.release();
                break;
            }
            if (self.pending) |old| old.release();
            self.pending = snap;
            self.unlock();
            self.wake();
        }
    }

    fn buildSnapshot(self: *Catalog, baseline: *Snapshot, epoch: u64) ?*Snapshot {
        startup.interruptibleSleep(&self.running, self.delay_ns);
        if (!self.running.load(.seq_cst)) return null;

        const snap = Snapshot.create(self.allocator) catch return null;
        snap.epoch = epoch;
        const a = snap.allocator();
        const t0 = stats.nowNs();

        if (!baseline.loading) {
            if (collectSources(a, self.io, self.environ)) |sources| {
                if (catalog_cache.sourcesMatch(baseline.sources, sources)) {
                    if (copyFiltered(a, baseline.entries, self.environ)) |entries| {
                        snap.entries = entries;
                        snap.sources = sources;
                        snap.provisional = false;
                        snap.loading = false;
                        snap.from_cache = baseline.from_cache;
                        snap.scan_ns = stats.nowNs() -% t0;
                        return snap;
                    } else |_| {}
                }
            } else |_| {}
        }

        const outcome = scanAll(a, self.io, self.environ) catch {
            snap.loading = false;
            snap.provisional = false;
            snap.scan_ns = stats.nowNs() -% t0;
            return snap;
        };
        snap.entries = outcome.entries;
        snap.sources = outcome.sources;
        snap.loading = false;
        snap.provisional = false;
        snap.scan_ns = stats.nowNs() -% t0;

        const keys = catalog_cache.envKeys(a, self.environ) catch {
            return snap;
        };
        catalog_cache.write(self.allocator, self.io, self.environ, .{
            .locale_tag = keys.locale_tag,
            .current_desktop = keys.current_desktop,
            .app_dirs = keys.app_dirs,
            .path_env = keys.path_env,
            .sources = snap.sources,
            .entries = snap.entries,
        });
        return snap;
    }

    fn readCacheSnapshot(self: *Catalog) ?*Snapshot {
        const t0 = stats.nowNs();
        const snap = Snapshot.create(self.allocator) catch return null;
        const payload = catalog_cache.read(snap.allocator(), self.io, self.environ) orelse {
            snap.release();
            return null;
        };
        snap.entries = payload.entries;
        snap.sources = payload.sources;
        snap.provisional = true;
        snap.loading = false;
        snap.from_cache = true;
        snap.scan_ns = stats.nowNs() -% t0;
        return snap;
    }

    fn wake(self: *Catalog) void {
        const val: u64 = 1;
        _ = c.write(self.eventfd, std.mem.asBytes(&val), @sizeOf(u64));
    }

    fn lock(self: *Catalog) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }
    fn unlock(self: *Catalog) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
    }
    fn wait(self: *Catalog) void {
        _ = c.pthread_cond_wait(&self.cond, &self.mutex);
    }
    fn signal(self: *Catalog) void {
        _ = c.pthread_cond_signal(&self.cond);
    }
    fn broadcast(self: *Catalog) void {
        _ = c.pthread_cond_broadcast(&self.cond);
    }

    fn syncWatches(self: *Catalog) void {
        if (self.watch_fd < 0) return;
        var tmp = std.heap.ArenaAllocator.init(self.allocator);
        defer tmp.deinit();
        const a = tmp.allocator();
        const mask: u32 = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MODIFY | linux.IN.MOVED_FROM |
            linux.IN.MOVED_TO | linux.IN.ATTRIB | linux.IN.CLOSE_WRITE | linux.IN.DELETE_SELF;

        if (resolveApplicationDirs(a, self.environ)) |dirs| {
            for (dirs) |dir| self.addWatch(dir, mask);
        } else |_| {}

        // Directories already visited by the scan, without walking the tree again
        // on the compositor thread.
        for (self.current.sources) |src| {
            if (std.fs.path.dirname(src.path)) |dir| self.addWatch(dir, mask);
        }
    }

    fn addWatch(self: *Catalog, dir: []const u8, mask: u32) void {
        if (self.watched_paths.contains(dir)) return;
        var zbuf: [std.posix.PATH_MAX]u8 = undefined;
        const zdir = std.fmt.bufPrintZ(&zbuf, "{s}", .{dir}) catch return;
        const wd = std.c.inotify_add_watch(self.watch_fd, zdir.ptr, mask);
        if (wd < 0) return;
        const owned = self.allocator.dupe(u8, dir) catch return;
        self.watched_paths.put(self.allocator, owned, {}) catch {
            self.allocator.free(owned);
            return;
        };
        self.watch_wds.append(self.allocator, wd) catch {};
    }
};

fn handleInotify(fd: c_int, mask: wl.EventMask, catalog: *Catalog) c_int {
    _ = mask;
    var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    var saw = false;
    while (true) {
        const n = posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => break,
            else => break,
        };
        if (n == 0) break;
        var off: usize = 0;
        while (off + @sizeOf(linux.inotify_event) <= n) {
            const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
            if (ev.mask & (linux.IN.CREATE | linux.IN.DELETE | linux.IN.MODIFY | linux.IN.MOVED_FROM |
                linux.IN.MOVED_TO | linux.IN.ATTRIB | linux.IN.CLOSE_WRITE | linux.IN.DELETE_SELF) != 0)
            {
                saw = true;
                if (ev.mask & linux.IN.CREATE != 0 and ev.mask & linux.IN.ISDIR != 0) {
                    catalog.syncWatches();
                }
            }
            off += @sizeOf(linux.inotify_event) + ev.len;
        }
    }
    if (saw) catalog.requestRefresh();
    return 0;
}

fn copyFiltered(arena: Allocator, entries: []const AppEntry, environ: std.process.Environ) ![]AppEntry {
    var out: std.ArrayList(AppEntry) = .empty;
    errdefer out.deinit(arena);
    for (entries) |e| {
        if (e.try_exec) |try_exec| {
            if (!checkTryExec(try_exec, environ)) continue;
        }
        try out.append(arena, try dupeEntry(arena, e));
    }
    return out.toOwnedSlice(arena);
}

fn dupeEntry(arena: Allocator, e: AppEntry) !AppEntry {
    return .{
        .id = try arena.dupe(u8, e.id),
        .desktop_file_path = try arena.dupe(u8, e.desktop_file_path),
        .name = try arena.dupe(u8, e.name),
        .generic_name = if (e.generic_name) |s| try arena.dupe(u8, s) else null,
        .comment = if (e.comment) |s| try arena.dupe(u8, s) else null,
        .icon = if (e.icon) |s| try arena.dupe(u8, s) else null,
        .startup_wm_class = if (e.startup_wm_class) |s| try arena.dupe(u8, s) else null,
        .exec = try arena.dupe(u8, e.exec),
        .path = if (e.path) |s| try arena.dupe(u8, s) else null,
        .try_exec = if (e.try_exec) |s| try arena.dupe(u8, s) else null,
        .terminal = e.terminal,
        .keywords = try arena.dupe(u8, e.keywords),
        .categories = try arena.dupe(u8, e.categories),
        .dbus_activatable = e.dbus_activatable,
    };
}

pub fn resolveApplicationDirs(arena: Allocator, environ: std.process.Environ) ![]const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;

    if (environ.getPosix("XDG_DATA_HOME")) |dh| {
        try dirs.append(arena, try std.fmt.allocPrint(arena, "{s}/applications", .{dh}));
    } else if (environ.getPosix("HOME")) |home| {
        try dirs.append(arena, try std.fmt.allocPrint(arena, "{s}/.local/share/applications", .{home}));
    }

    const data_dirs = environ.getPosix("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = std.mem.splitScalar(u8, data_dirs, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        try dirs.append(arena, try std.fmt.allocPrint(arena, "{s}/applications", .{dir}));
    }
    return dirs.toOwnedSlice(arena);
}

pub const ScanOutcome = struct {
    entries: []AppEntry,
    sources: []catalog_cache.SourceIdent,
};

pub fn scanAll(arena: Allocator, io: Io, environ: std.process.Environ) !ScanOutcome {
    const locale = Locale.fromEnv(environ);
    const current_desktop = environ.getPosix("XDG_CURRENT_DESKTOP");
    const app_dirs = try resolveApplicationDirs(arena, environ);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);
    var results: std.ArrayList(AppEntry) = .empty;
    var sources: std.ArrayList(catalog_cache.SourceIdent) = .empty;

    for (app_dirs) |dir| {
        scanDirectory(arena, io, environ, dir, "", locale, current_desktop, &seen, &results, &sources) catch continue;
    }
    catalog_cache.sortSources(sources.items);

    return .{
        .entries = try results.toOwnedSlice(arena),
        .sources = try sources.toOwnedSlice(arena),
    };
}

fn collectSources(arena: Allocator, io: Io, environ: std.process.Environ) ![]catalog_cache.SourceIdent {
    const app_dirs = try resolveApplicationDirs(arena, environ);
    var sources: std.ArrayList(catalog_cache.SourceIdent) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);
    for (app_dirs) |dir| {
        walkSources(arena, io, dir, &sources, &seen) catch continue;
    }
    catalog_cache.sortSources(sources.items);
    return sources.toOwnedSlice(arena);
}

fn walkSources(
    arena: Allocator,
    io: Io,
    dir: []const u8,
    sources: *std.ArrayList(catalog_cache.SourceIdent),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    var iter = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer iter.close(io);
    var it = iter.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            const child = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, entry.name });
            walkSources(arena, io, child, sources, seen) catch continue;
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".desktop")) continue;
        const full_file_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, entry.name });
        if (seen.contains(full_file_path)) continue;
        try seen.put(arena, full_file_path, {});
        if (catalog_cache.statPath(io, full_file_path)) |ident| {
            try sources.append(arena, .{
                .path = full_file_path,
                .mtime_sec = ident.mtime_sec,
                .mtime_nsec = ident.mtime_nsec,
                .size = ident.size,
            });
        }
    }
}

fn scanDirectory(
    arena: Allocator,
    io: Io,
    environ: std.process.Environ,
    base_dir: []const u8,
    rel_sub: []const u8,
    locale: Locale,
    current_desktop: ?[]const u8,
    seen: *std.StringHashMapUnmanaged(void),
    results: *std.ArrayList(AppEntry),
    sources: *std.ArrayList(catalog_cache.SourceIdent),
) !void {
    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    const full_dir = if (rel_sub.len == 0)
        base_dir
    else
        std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, rel_sub }) catch return;

    var iter = Io.Dir.cwd().openDir(io, full_dir, .{ .iterate = true }) catch return;
    defer iter.close(io);

    var it = iter.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            var sub_buf: [256]u8 = undefined;
            const next_sub = if (rel_sub.len == 0)
                std.fmt.bufPrint(&sub_buf, "{s}", .{entry.name}) catch continue
            else
                std.fmt.bufPrint(&sub_buf, "{s}-{s}", .{ rel_sub, entry.name }) catch continue;
            scanDirectory(arena, io, environ, base_dir, next_sub, locale, current_desktop, seen, results, sources) catch continue;
            continue;
        }

        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".desktop")) continue;

        const full_file_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ full_dir, entry.name });
        if (catalog_cache.statPath(io, full_file_path)) |ident| {
            try sources.append(arena, .{
                .path = full_file_path,
                .mtime_sec = ident.mtime_sec,
                .mtime_nsec = ident.mtime_nsec,
                .size = ident.size,
            });
        }

        // Form desktop-file ID
        const desktop_id = if (rel_sub.len == 0)
            try arena.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(arena, "{s}-{s}", .{ rel_sub, entry.name });

        if (seen.contains(desktop_id)) continue;
        try seen.put(arena, desktop_id, {});

        const content = Io.Dir.cwd().readFileAlloc(io, full_file_path, arena, .limited(512 * 1024)) catch continue;

        const parsed = parseDesktopFile(arena, content, locale) orelse continue;

        // Visibility rules
        if (!checkDesktopVisibility(parsed, current_desktop)) continue;

        // TryExec check
        if (parsed.try_exec) |try_exec| {
            if (!checkTryExec(try_exec, environ)) continue;
        }

        const exec_cmd = parsed.exec orelse continue;

        try results.append(arena, .{
            .id = desktop_id,
            .desktop_file_path = full_file_path,
            .name = parsed.name.?,
            .generic_name = parsed.generic_name,
            .comment = parsed.comment,
            .icon = parsed.icon,
            .startup_wm_class = parsed.startup_wm_class,
            .exec = exec_cmd,
            .path = parsed.path,
            .try_exec = parsed.try_exec,
            .terminal = parsed.terminal,
            .keywords = parsed.keywords orelse "",
            .categories = parsed.categories orelse "",
            .dbus_activatable = parsed.dbus_activatable,
        });
    }
}

test "desktop file parsing and localization" {
    const fixture =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Files
        \\Name[de]=Dateien
        \\GenericName=File Manager
        \\Comment=Manage your files
        \\Icon=system-file-manager
        \\Exec=nautilus %U
        \\Categories=Utility;FileManager;
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const loc_de = Locale{ .lang = "de", .country = "DE" };
    const parsed_de = parseDesktopFile(arena.allocator(), fixture, loc_de) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Dateien", parsed_de.name.?);
    try std.testing.expectEqualStrings("File Manager", parsed_de.generic_name.?);
    try std.testing.expectEqualStrings("nautilus %U", parsed_de.exec.?);

    const loc_en = Locale{ .lang = "en" };
    const parsed_en = parseDesktopFile(arena.allocator(), fixture, loc_en) orelse return error.TestFailed;
    try std.testing.expectEqualStrings("Files", parsed_en.name.?);
}

test "snapshot retain releases once" {
    const snap = try Snapshot.create(std.testing.allocator);
    _ = snap.retain();
    snap.release();
    snap.release();
}

test "desktop file hidden override" {
    const fixture =
        \\[Desktop Entry]
        \\Type=Application
        \\Name=HiddenApp
        \\Hidden=true
        \\Exec=hidden
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parsed = parseDesktopFile(arena.allocator(), fixture, .{}) orelse return error.TestFailed;
    try std.testing.expect(parsed.hidden);
    try std.testing.expect(!checkDesktopVisibility(parsed, null));
}
