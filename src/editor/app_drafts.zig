//! Keeping unsaved tabs as drafts: which tabs, when they are written, and
//! bringing them back with the next editor. The files are `drafts.zig`'s.

const std = @import("std");
const c = @import("../files/c.zig").api;
const key_repeat = @import("ui").key_repeat;
const drafts = @import("drafts.zig");
const Document = @import("document.zig").Document;
const app_mod = @import("app.zig");
const App = app_mod.App;
const Tab = app_mod.Tab;
const a = std.heap.c_allocator;

/// A tab with work worth keeping: changed, and not an empty new document.
fn wants(t: *const Tab) bool {
    return t.doc.modified() and (t.path != null or t.doc.text.items.len > 0);
}
fn fits(t: *const Tab, total: usize) bool {
    return t.doc.text.items.len <= drafts.text_limit and total + t.doc.text.items.len <= drafts.total_limit;
}
fn anyWanted(self: *App) bool {
    for (self.tabs.items) |t| if (wants(t)) return true;
    return false;
}

/// Everything a write would change, in one number: the tabs, what they hold
/// and which one is selected. Cursor moves are not in it; they only ride along
/// with the next write.
fn signature(self: *App) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(std.mem.asBytes(&self.selected));
    for (self.tabs.items) |t| {
        hash.update(std.mem.asBytes(&t.id));
        hash.update(std.mem.asBytes(&t.doc.revision));
        hash.update(&.{ @intFromBool(t.doc.modified()), 0 });
        if (t.path) |path| hash.update(path);
        hash.update(&.{0});
    }
    return hash.final();
}

/// Copies what a write needs, so the tabs can change meanwhile.
fn snapshot(self: *App, k: *drafts.Keeper) !drafts.Snapshot {
    var items: std.ArrayList(drafts.Item) = .empty;
    errdefer {
        for (items.items) |item| item.deinit();
        items.deinit(a);
    }
    var total: usize = 0;
    var selected: usize = 0;
    for (self.tabs.items, 0..) |t, i| {
        if (!wants(t) or !fits(t, total)) continue;
        total += t.doc.text.items.len;
        const path = if (t.path) |p| try a.dupe(u8, p) else null;
        errdefer if (path) |p| a.free(p);
        const text = if (t.draft_rev == t.doc.revision) null else try a.dupe(u8, t.doc.text.items);
        errdefer if (text) |x| a.free(x);
        try items.append(a, .{
            .entry = .{ .name = t.draft_name orelse k.next, .path = path, .stamp = t.stamp, .cursor = t.doc.cursor, .anchor = t.doc.anchor, .top = t.doc.top, .bom = t.doc.bom },
            .tab_id = t.id,
            .revision = t.doc.revision,
            .text = text,
        });
        if (t.draft_name == null) {
            t.draft_name = k.next;
            k.next += 1;
        }
        if (i == self.selected) selected = items.items.len - 1;
    }
    return .{ .selected = selected, .next = k.next, .items = try items.toOwnedSlice(a) };
}

/// A written snapshot is what the disk holds now. Tabs that left it lost their files.
fn commit(self: *App, k: *drafts.Keeper, snap: drafts.Snapshot, sig: u64) void {
    for (self.tabs.items) |t| {
        const item = for (snap.items) |item| {
            if (item.tab_id == t.id) break item;
        } else null;
        if (item) |it| {
            if (it.text != null) t.draft_rev = it.revision;
        } else {
            t.draft_name = null;
            t.draft_rev = null;
        }
    }
    k.written = sig;
    k.on_disk = snap.items.len > 0;
}

/// A failed write is tried again after the usual quiet time, not in a loop.
fn backoff(k: *drafts.Keeper, now: i64) void {
    k.last = now;
    k.since = now;
}

fn finish(self: *App, k: *drafts.Keeper, job: *drafts.Job, now: i64) void {
    k.job = null;
    defer job.deinit();
    if (job.err) |err| {
        std.log.warn("rediwm-editor: cannot write drafts: {}", .{err});
        backoff(k, now);
        return;
    }
    commit(self, k, job.snapshot, job.signature);
}

fn startFlush(self: *App, k: *drafts.Keeper, now: i64) void {
    const snap = snapshot(self, k) catch return backoff(k, now);
    if (snap.items.len == 0 and !k.on_disk) {
        // Only tabs too large to keep: there is nothing to write or clear.
        snap.deinit();
        k.written = k.seen;
        k.since = null;
        return;
    }
    k.job = drafts.Job.start(&k.store, snap, k.seen, k.wake) catch {
        snap.deinit();
        return backoff(k, now);
    };
}

/// Writes what the tabs hold now, here and now, after any write in flight.
/// Closing the editor on purpose asks about unsaved tabs first, so what is
/// written here is a session that ended some other way.
fn writeNow(self: *App, k: *drafts.Keeper) bool {
    if (k.job) |job| {
        job.wait();
        finish(self, k, job, key_repeat.nowMs());
    }
    const sig = signature(self);
    if (sig == k.written) return true;
    const snap = snapshot(self, k) catch return false;
    defer snap.deinit();
    if (snap.items.len > 0 or k.on_disk) k.store.write(snap) catch |err| {
        std.log.warn("rediwm-editor: cannot write drafts: {}", .{err});
        return false;
    };
    commit(self, k, snap, sig);
    k.seen = sig;
    k.since = null;
    return true;
}

/// Takes the drafts directory and brings back the last session's tabs. Without
/// a home, or while another editor owns the directory, there are no drafts and
/// closing asks about unsaved work as it always did.
pub fn openDrafts(self: *App, env: std.process.Environ) void {
    start(self, env) catch |err| std.log.warn("rediwm-editor: unsaved text will not be kept: {}", .{err});
}
fn start(self: *App, env: std.process.Environ) !void {
    var store = try drafts.Store.open(self.io, try drafts.directory(env));
    errdefer store.deinit();
    const wake = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
    if (wake < 0) return error.EventFailed;
    errdefer _ = c.close(wake);
    const k = try a.create(drafts.Keeper);
    errdefer a.destroy(k);
    var loaded = store.load();
    defer loaded.deinit();
    k.* = .{ .store = store, .wake = wake, .next = loaded.next, .on_disk = loaded.tabs.items.len > 0 };
    restore(self, &loaded);
    k.seen = signature(self);
    k.written = k.seen;
    self.keeper = k;
    drafts.catchSignals(wake);
}

fn clampToChar(text: []const u8, pos: usize) usize {
    var at = @min(pos, text.len);
    while (at > 0 and at < text.len and text[at] & 0xc0 == 0x80) at -= 1;
    return at;
}

fn restore(self: *App, loaded: *drafts.Loaded) void {
    const blank = self.tabs.items.len == 1 and self.tabs.items[0].path == null and
        self.tabs.items[0].doc.text.items.len == 0 and !self.tabs.items[0].doc.modified();
    var selected: usize = 0;
    var count: usize = 0;
    for (loaded.tabs.items, 0..) |*r, i| {
        const t = a.create(Tab) catch continue;
        t.* = .{ .id = self.next_id, .doc = Document.adopt(r.text, r.bom) catch {
            a.destroy(t);
            continue;
        } };
        r.text = .empty;
        t.path = r.path;
        r.path = null;
        t.stamp = r.stamp;
        const text = t.doc.text.items;
        t.doc.cursor = clampToChar(text, r.cursor);
        t.doc.anchor = clampToChar(text, r.anchor);
        t.doc.top = t.doc.lineStart(clampToChar(text, r.top));
        // The history did not survive, so there is no state to undo back to.
        t.doc.saved = null;
        t.draft_name = r.name;
        t.draft_rev = t.doc.revision;
        self.tabs.append(a, t) catch {
            t.deinit();
            continue;
        };
        self.next_id += 1;
        if (i == loaded.selected) selected = self.tabs.items.len - 1;
        count += 1;
    }
    if (count == 0) return;
    if (blank) {
        self.tabs.orderedRemove(0).deinit();
        selected -|= 1;
    }
    self.selected = selected;
    self.changed();
}

/// Called after every event: notices changes, collects a finished write and
/// starts the next one once typing has paused.
pub fn stepDrafts(self: *App, now: i64) void {
    const k = self.keeper orelse return;
    if (k.job) |job| if (job.done.load(.acquire)) finish(self, k, job, now);
    const sig = signature(self);
    if (sig != k.seen) {
        k.seen = sig;
        k.last = now;
    }
    if (k.seen == k.written) {
        k.since = null;
    } else if (!k.on_disk and !anyWanted(self)) {
        // Nothing to keep and nothing to clear: no timer for a tab switch.
        k.written = k.seen;
        k.since = null;
    } else if (k.since == null) k.since = k.last;
    if (k.due(now)) |wait| if (wait == 0) startFlush(self, k, now);
}

/// Milliseconds until `stepDrafts` has something to do, for the poll timeout.
pub fn draftTimeout(self: *App, now: i64) ?i64 {
    const k = self.keeper orelse return null;
    return k.due(now);
}

pub fn draftWake(self: *App) c_int {
    return if (self.keeper) |k| k.wake else -1;
}

pub fn drainDrafts(self: *App) void {
    const k = self.keeper orelse return;
    var count: u64 = 0;
    _ = c.read(k.wake, &count, 8);
}

/// A signal that ends the session arrived.
pub fn signaled(self: *App) bool {
    return self.keeper != null and drafts.stopping.load(.acquire);
}

pub fn deinitDrafts(self: *App) void {
    const k = self.keeper orelse return;
    self.keeper = null;
    drafts.releaseSignals();
    _ = writeNow(self, k);
    k.store.deinit();
    _ = c.close(k.wake);
    a.destroy(k);
}
