//! Unsaved text that outlives the window, a crash and a reboot, like the drafts
//! of GNOME Text Editor.
//!
//! `$XDG_STATE_HOME/rediwm/editor-drafts/` holds `session.json` (the tabs with
//! unsaved work, in order, with their file and cursor) and one `<name>.txt`
//! per such tab. Every file is replaced through a temporary name and synced, so
//! a crash leaves the old or the new one, never half of it. One editor owns the
//! directory (an exclusive `lock`); a second runs without drafts rather than
//! fight over it. Which tabs to keep and when to write is `app_drafts.zig`'s
//! business; nothing here knows about tabs or Wayland.
const std = @import("std");
const c = @import("../files/c.zig").api;
const op = @import("operation.zig");
const Document = @import("document.zig").Document;
const a = std.heap.c_allocator;

/// A tab holding more text than this is not kept as a draft: rewriting it on
/// every pause in typing would cost more than it protects. Closing the window
/// asks about such a tab as usual.
pub const text_limit: usize = 8 * 1024 * 1024;
/// The same for all drafts together.
pub const total_limit: usize = 64 * 1024 * 1024;
/// Quiet time after the last change before the drafts are written.
pub const delay_ms: i64 = 1000;
/// Longest a change waits while typing goes on.
pub const max_wait_ms: i64 = 5000;
const max_tabs = 256;
const manifest_name = "session.json";
const manifest_limit: usize = 4 * 1024 * 1024;

pub const Entry = struct {
    name: u64,
    path: ?[]const u8 = null,
    /// What the file looked like when the tab was loaded or last saved, so a
    /// save of the restored text still notices that the file changed since.
    stamp: ?op.Stamp = null,
    cursor: usize = 0,
    anchor: usize = 0,
    top: usize = 0,
    bom: bool = false,
};
const Manifest = struct {
    version: u32 = 1,
    selected: usize = 0,
    next: u64 = 1,
    tabs: []const Entry = &.{},
};

pub const Restored = struct {
    name: u64,
    path: ?[:0]u8,
    stamp: ?op.Stamp,
    cursor: usize,
    anchor: usize,
    top: usize,
    bom: bool,
    text: std.ArrayList(u8),
    pub fn deinit(r: *Restored) void {
        if (r.path) |path| a.free(path);
        r.text.deinit(a);
    }
};
pub const Loaded = struct {
    selected: usize = 0,
    next: u64 = 1,
    tabs: std.ArrayList(Restored) = .empty,
    pub fn deinit(l: *Loaded) void {
        for (l.tabs.items) |*t| t.deinit();
        l.tabs.deinit(a);
    }
};

/// One tab's draft as handed to the writer. Everything is owned, because the
/// tab goes on changing while a background thread writes.
pub const Item = struct {
    entry: Entry,
    tab_id: usize,
    revision: usize,
    /// Null when the file for `entry.name` already holds this revision.
    text: ?[]u8,
    pub fn deinit(item: Item) void {
        if (item.text) |text| a.free(text);
        if (item.entry.path) |path| a.free(@constCast(path));
    }
};
pub const Snapshot = struct {
    selected: usize,
    next: u64,
    items: []Item,
    pub fn deinit(s: Snapshot) void {
        for (s.items) |item| item.deinit();
        a.free(s.items);
    }
};

pub fn directory(env: std.process.Environ) ![:0]u8 {
    if (env.getPosix("XDG_STATE_HOME")) |base| {
        if (std.fs.path.isAbsolute(base)) return std.fmt.allocPrintSentinel(a, "{s}/rediwm/editor-drafts", .{base}, 0);
    }
    const home = env.getPosix("HOME") orelse return error.NoHome;
    return std.fmt.allocPrintSentinel(a, "{s}/.local/state/rediwm/editor-drafts", .{home}, 0);
}

pub const Store = struct {
    path: [:0]u8,
    dir: c_int,
    lock: c_int,

    /// Takes `path`, which it frees on failure too.
    pub fn open(io: std.Io, path: [:0]u8) !Store {
        errdefer a.free(path);
        try std.Io.Dir.cwd().createDirPath(io, path);
        const dir = c.open(path, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NOFOLLOW);
        if (dir < 0) return error.OpenFailed;
        errdefer _ = c.close(dir);
        var st: c.struct_stat = undefined;
        if (c.fstat(dir, &st) != 0 or st.st_uid != c.getuid()) return error.NotOwned;
        _ = c.fchmod(dir, 0o700);
        const lock = c.openat(dir, "lock", c.O_RDWR | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (lock < 0) return error.LockFailed;
        errdefer _ = c.close(lock);
        if (c.flock(lock, c.LOCK_EX | c.LOCK_NB) != 0) return error.Busy;
        return .{ .path = path, .dir = dir, .lock = lock };
    }
    pub fn deinit(s: *Store) void {
        _ = c.close(s.lock);
        _ = c.close(s.dir);
        a.free(s.path);
    }

    /// The drafts of the last session. Anything unreadable, over the limits or
    /// not valid text is left out rather than failing the rest.
    pub fn load(s: *const Store) Loaded {
        var out: Loaded = .{};
        const bytes = readAt(s.dir, manifest_name, manifest_limit) catch return out;
        defer a.free(bytes);
        const parsed = std.json.parseFromSlice(Manifest, a, bytes, .{ .ignore_unknown_fields = true }) catch return out;
        defer parsed.deinit();
        const manifest = parsed.value;
        if (manifest.version != 1) return out;
        out.next = @max(manifest.next, 1);
        for (manifest.tabs[0..@min(manifest.tabs.len, max_tabs)]) |entry| {
            out.next = @max(out.next, entry.name +| 1);
            var file: [32]u8 = undefined;
            const name = std.fmt.bufPrintSentinel(&file, "{d}.txt", .{entry.name}, 0) catch continue;
            const text = readAt(s.dir, name, text_limit) catch continue;
            Document.validate(text) catch {
                a.free(text);
                continue;
            };
            const usable = if (entry.path) |p| std.fs.path.isAbsolute(p) and std.mem.indexOfScalar(u8, p, 0) == null else false;
            const path = if (usable) a.dupeSentinel(u8, entry.path.?, 0) catch null else null;
            out.tabs.append(a, .{
                .name = entry.name,
                .path = path,
                .stamp = if (path != null) entry.stamp else null,
                .cursor = entry.cursor,
                .anchor = entry.anchor,
                .top = entry.top,
                .bom = entry.bom,
                .text = .fromOwnedSlice(text),
            }) catch {
                if (path) |p| a.free(p);
                a.free(text);
                continue;
            };
        }
        out.selected = if (manifest.selected < out.tabs.items.len) manifest.selected else 0;
        return out;
    }

    /// Writes the changed texts, then the session that refers to them, then
    /// removes the files nothing refers to any more.
    pub fn write(s: *const Store, snapshot: Snapshot) !void {
        for (snapshot.items) |item| if (item.text) |text| {
            var file: [32]u8 = undefined;
            try replace(s.dir, try std.fmt.bufPrintSentinel(&file, "{d}.txt", .{item.entry.name}, 0), text);
        };
        const entries = try a.alloc(Entry, snapshot.items.len);
        defer a.free(entries);
        for (snapshot.items, entries) |item, *entry| entry.* = item.entry;
        const json = try std.json.Stringify.valueAlloc(a, Manifest{ .selected = snapshot.selected, .next = snapshot.next, .tabs = entries }, .{});
        defer a.free(json);
        try replace(s.dir, manifest_name, json);
        _ = c.fsync(s.dir);
        s.sweep(snapshot.items);
    }
    fn sweep(s: *const Store, keep: []const Item) void {
        const fd = c.dup(s.dir);
        if (fd < 0) return;
        const stream = c.fdopendir(fd) orelse {
            _ = c.close(fd);
            return;
        };
        defer _ = c.closedir(stream);
        c.rewinddir(stream);
        while (c.readdir(stream)) |entry| {
            const name = std.mem.sliceTo(entry.*.d_name[0..], 0);
            const stale = blk: {
                if (std.mem.endsWith(u8, name, ".tmp")) break :blk true;
                const number = draftNumber(name) orelse break :blk false;
                for (keep) |item| if (item.entry.name == number) break :blk false;
                break :blk true;
            };
            if (stale) _ = c.unlinkat(s.dir, @ptrCast(&entry.*.d_name), 0);
        }
    }
};

/// `<digits>.txt` as a draft's file name.
fn draftNumber(name: []const u8) ?u64 {
    if (!std.mem.endsWith(u8, name, ".txt")) return null;
    return std.fmt.parseInt(u64, name[0 .. name.len - 4], 10) catch null;
}

fn replace(dir: c_int, name: [:0]const u8, bytes: []const u8) !void {
    var buffer: [64]u8 = undefined;
    const temp = try std.fmt.bufPrintSentinel(&buffer, "{s}.tmp", .{name}, 0);
    const fd = c.openat(dir, temp, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (fd < 0) return error.WriteFailed;
    {
        defer _ = c.close(fd);
        errdefer _ = c.unlinkat(dir, temp, 0);
        try op.writeAll(fd, bytes);
        if (c.fsync(fd) != 0) return error.WriteFailed;
    }
    if (c.renameat(dir, temp, dir, name) != 0) {
        _ = c.unlinkat(dir, temp, 0);
        return error.WriteFailed;
    }
}

fn readAt(dir: c_int, name: [:0]const u8, limit: usize) ![]u8 {
    const fd = c.openat(dir, name, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG or st.st_size < 0 or @as(u64, @intCast(st.st_size)) > limit) return error.Unreadable;
    const buffer = try a.alloc(u8, @intCast(st.st_size));
    errdefer a.free(buffer);
    var got: usize = 0;
    while (got < buffer.len) {
        const n = c.read(fd, buffer.ptr + got, buffer.len - got);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return error.Unreadable;
        got += @intCast(n);
    }
    return buffer;
}

/// Writes a snapshot on a thread of its own and wakes the event loop through
/// `wake` when done. Fsyncs can take tens of milliseconds on a slow disk.
pub const Job = struct {
    store: *const Store,
    snapshot: Snapshot,
    /// The state of the tabs the snapshot was taken from.
    signature: u64,
    wake: c_int,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    err: ?anyerror = null,

    /// On failure the caller still owns `snapshot`.
    pub fn start(store: *const Store, snapshot: Snapshot, signature: u64, wake: c_int) !*Job {
        const job = try a.create(Job);
        errdefer a.destroy(job);
        job.* = .{ .store = store, .snapshot = snapshot, .signature = signature, .wake = wake };
        job.thread = try std.Thread.spawn(.{}, run, .{job});
        return job;
    }
    fn run(job: *Job) void {
        job.store.write(job.snapshot) catch |err| {
            job.err = err;
        };
        job.done.store(true, .release);
        notify(job.wake);
    }
    pub fn wait(job: *Job) void {
        if (job.thread) |thread| thread.join();
        job.thread = null;
    }
    pub fn deinit(job: *Job) void {
        job.wait();
        job.snapshot.deinit();
        a.destroy(job);
    }
};

fn notify(fd: c_int) void {
    const one: u64 = 1;
    _ = c.write(fd, &one, 8);
}

/// Set by SIGTERM/SIGHUP/SIGINT: the session is ending, write what is open.
pub var stopping = std.atomic.Value(bool).init(false);
var signal_wake: c_int = -1;
fn onSignal(_: c_int) callconv(.c) void {
    const errno = std.c._errno();
    const saved = errno.*;
    stopping.store(true, .release);
    notify(signal_wake);
    errno.* = saved;
}
/// Routes the signals that end a session to `wake`, so the event loop can
/// write the drafts before it exits instead of dying with the last seconds.
pub fn catchSignals(wake: c_int) void {
    signal_wake = wake;
    _ = c.signal(c.SIGTERM, onSignal);
    _ = c.signal(c.SIGHUP, onSignal);
    _ = c.signal(c.SIGINT, onSignal);
}

pub fn releaseSignals() void {
    _ = c.signal(c.SIGTERM, c.SIG_DFL);
    _ = c.signal(c.SIGHUP, c.SIG_DFL);
    _ = c.signal(c.SIGINT, c.SIG_DFL);
    signal_wake = -1;
}

/// What the app keeps between events: the store, the writer in flight and the
/// timing of the next write.
pub const Keeper = struct {
    store: Store,
    wake: c_int,
    job: ?*Job = null,
    /// The next draft file name.
    next: u64 = 1,
    /// The state of the tabs last looked at and last written (`app_drafts.signature`).
    seen: u64 = 0,
    written: u64 = 0,
    /// The first and the latest change not written yet.
    since: ?i64 = null,
    last: i64 = 0,
    /// Whether the session on disk holds any tab, which a write must clear.
    on_disk: bool = false,

    /// Milliseconds until the pending change is due, null with nothing to
    /// wait for. A write in flight wakes the loop itself.
    pub fn due(k: *const Keeper, now: i64) ?i64 {
        if (k.job != null) return null;
        const since = k.since orelse return null;
        return @max(0, @min(k.last + delay_ms, since + max_wait_ms) - now);
    }
};
