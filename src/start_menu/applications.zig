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
const platform = @import("platform");

const catalog_cache = @import("catalog_cache.zig");
const startup = @import("../startup.zig");
const i18n = @import("i18n");
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

const desktop_file = @import("desktop_file.zig");
pub const Locale = desktop_file.Locale;
pub const ParsedEntry = desktop_file.ParsedEntry;
pub const parseDesktopFile = desktop_file.parseDesktopFile;
pub const checkTryExec = desktop_file.checkTryExec;
pub const checkDesktopVisibility = desktop_file.checkDesktopVisibility;

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
    locale_tag: []const u8 = "",

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
    locale_tag: []u8,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    eventfd: posix.fd_t = -1,
    thread: ?std.Thread = null,
    delay_ns: u64 = 0,

    watcher: ?platform.watch.Watcher = null,
    watch_source: ?*wl.EventSource = null,
    watched_paths: std.StringHashMapUnmanaged(void) = .empty,

    /// `scan` false leaves the catalog empty and never touches the cache
    /// (the greeter has no start menu).
    pub fn init(allocator: Allocator, io: Io, environ: std.process.Environ, scan: bool, locale_tag: []const u8) !*Catalog {
        const cat = try allocator.create(Catalog);
        errdefer allocator.destroy(cat);

        const loading = try Snapshot.create(allocator);
        errdefer loading.release();
        loading.loading = scan;

        const efd = platform.wake.create() orelse return error.EventFdFailed;
        errdefer _ = c.close(efd);

        const owned_locale = try allocator.dupe(u8, locale_tag);
        errdefer allocator.free(owned_locale);
        cat.* = .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .current = loading,
            .locale_tag = owned_locale,
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
        var watcher = platform.watch.Watcher.init() catch return;
        self.watch_source = loop.addFd(*Catalog, watcher.fd, .{ .readable = true }, handleWatch, self) catch {
            watcher.deinit();
            return;
        };
        self.watcher = watcher;
        self.syncWatches();
    }

    pub fn deinit(self: *Catalog) void {
        self.running.store(false, .seq_cst);
        self.lock();
        self.broadcast();
        self.unlock();
        if (self.thread) |t| t.join();

        if (self.watch_source) |src| src.remove();
        if (self.watcher) |*w| w.deinit();
        var it = self.watched_paths.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.watched_paths.deinit(self.allocator);

        if (self.eventfd >= 0) _ = c.close(self.eventfd);
        if (self.pending) |snap| snap.release();
        self.current.release();
        self.allocator.free(self.locale_tag);
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

    /// Main thread updates the request; the worker snapshots it under the mutex.
    pub fn setLocale(self: *Catalog, locale_tag: []const u8) !void {
        self.lock();
        defer self.unlock();
        if (std.mem.eql(u8, self.locale_tag, locale_tag)) return;
        const owned = try self.allocator.dupe(u8, locale_tag);
        self.allocator.free(self.locale_tag);
        self.locale_tag = owned;
        self.refresh_requested = true;
        self.epoch += 1;
        self.signal();
    }

    pub fn refreshAsync(self: *Catalog) void {
        self.requestRefresh();
    }

    /// Compositor thread. Returns true if the published generation changed.
    pub fn drainCompletions(self: *Catalog) bool {
        var discard: [8]u8 = undefined;
        _ = c.read(self.eventfd, &discard, discard.len);

        self.lock();
        var incoming = self.pending;
        self.pending = null;
        if (incoming) |candidate| if (!std.mem.eql(u8, candidate.locale_tag, self.locale_tag)) {
            candidate.release();
            incoming = null;
        };
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
        self.lock();
        snap.locale_tag = a.dupe(u8, self.locale_tag) catch {
            self.unlock();
            snap.release();
            return null;
        };
        self.unlock();
        const t0 = stats.nowNs();

        if (!baseline.loading and std.mem.eql(u8, baseline.locale_tag, snap.locale_tag)) {
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

        const outcome = scanAllWithLocale(a, self.io, self.environ, snap.locale_tag) catch {
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

        const keys = catalog_cache.envKeysWithLocale(a, self.environ, snap.locale_tag) catch {
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
        const payload = catalog_cache.readWithLocale(snap.allocator(), self.io, self.environ, self.locale_tag) orelse {
            snap.release();
            return null;
        };
        snap.locale_tag = snap.allocator().dupe(u8, self.locale_tag) catch {
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
        const watcher = self.watcher orelse return;
        var tmp = std.heap.ArenaAllocator.init(self.allocator);
        defer tmp.deinit();
        const a = tmp.allocator();

        if (resolveApplicationDirs(a, self.environ)) |dirs| {
            for (dirs) |dir| self.addWatch(watcher, dir);
        } else |_| {}

        // Directories already visited by the scan, without walking the tree again
        // on the compositor thread.
        for (self.current.sources) |src| {
            if (std.fs.path.dirname(src.path)) |dir| self.addWatch(watcher, dir);
        }
    }

    fn addWatch(self: *Catalog, watcher: platform.watch.Watcher, dir: []const u8) void {
        if (self.watched_paths.contains(dir)) return;
        _ = watcher.add(dir, .{ .created = true, .deleted = true, .modified = true, .moved_from = true, .moved_to = true, .attrib = true, .written = true }) orelse return;
        const owned = self.allocator.dupe(u8, dir) catch return;
        self.watched_paths.put(self.allocator, owned, {}) catch self.allocator.free(owned);
    }
};

const Changes = struct {
    catalog: *Catalog,
    saw: bool = false,

    fn event(self: *Changes, ev: platform.watch.Event) void {
        if (!ev.flags.isChange()) return;
        self.saw = true;
        // A new directory may hold applications of its own.
        if (ev.flags.created and ev.flags.is_dir) self.catalog.syncWatches();
    }
};

fn handleWatch(_: c_int, _: wl.EventMask, catalog: *Catalog) c_int {
    const watcher = catalog.watcher orelse return 0;
    var changes: Changes = .{ .catalog = catalog };
    watcher.drain(&changes, Changes.event) catch {};
    if (changes.saw) catalog.requestRefresh();
    return 0;
}

const applications_scan = @import("scan.zig");
const copyFiltered = applications_scan.copyFiltered;
pub const resolveApplicationDirs = applications_scan.resolveApplicationDirs;
pub const ScanOutcome = applications_scan.ScanOutcome;
pub const scanAll = applications_scan.scanAll;
pub const scanAllWithLocale = applications_scan.scanAllWithLocale;
const collectSources = applications_scan.collectSources;

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

test "bare Portuguese requests Brazil without promoting generic desktop keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entry = parseDesktopFile(arena.allocator(),
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Files
        \\Name[pt_BR]=Arquivos
        \\Name[pt]=Ficheiros
        \\Exec=/bin/true
    , Locale.forLanguage("pt.UTF-8")).?;
    try std.testing.expectEqualStrings("Arquivos", entry.name.?);
    try std.testing.expectEqualStrings("", Locale.parseLocale("pt").country);
    try std.testing.expectEqualStrings("PT", Locale.forLanguage("pt_PT.UTF-8").country);
}
