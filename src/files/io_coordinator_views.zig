//! Job views on the coordinator (architecture §14). Methods of `Coordinator`,
//! aliased there.
//!
//! A window watches a folder by path. Each pass the coordinator finds the
//! jobs writing into it: those whose destination is the folder (their roots
//! land there) or one of its ancestors (the folder is inside one of their
//! trees, found by name). It writes a bounded snapshot of their entries
//! there when it changed: at once for a change of shape or state, at most
//! every `progress_interval_ms` when only bytes moved. All in memory; the
//! cost is bounded by the jobs and the rows watched.
const std = @import("std");
const io_service = @import("io_service.zig");
const io_manager = @import("io_manager.zig");
const io_tree = @import("io_tree.zig");
const views = @import("io_job_views.zig");
const io_coordinator = @import("io_coordinator.zig");
const Coordinator = io_coordinator.Coordinator;

const progress_interval_ms = 50;

pub const Watching = struct {
    window_id: io_service.WindowId,
    slot: u8,
    /// Owned.
    path: []u8,
    offset: u32,
    limit: u32,
    generation: u64,
    /// What the last snapshot showed: its shape and states, and its bytes.
    shape: u64 = 0,
    bytes: u64 = 0,
    written: bool = false,
    last_ms: i64 = 0,
    /// The folder last promoted for this watch, so discovery is asked once
    /// per folder, not every pass.
    promoted: u64 = 0,
};

fn key(window_id: io_service.WindowId, slot: u8) u64 {
    return (window_id << 2) | slot;
}

pub fn deinitWatching(self: *Coordinator) void {
    var values = self.watching.valueIterator();
    while (values.next()) |watching| self.allocator.free(watching.path);
    self.watching.deinit(self.allocator);
}

pub fn watchView(self: *Coordinator, window_id: io_service.WindowId, payload: ?*io_service.OwnedPayload) !void {
    const owned = payload orelse return error.MissingWatchPayload;
    const watch = switch (owned.data) {
        .watch => |w| w,
        else => return error.UnexpectedWatchPayload,
    };
    const path = try self.allocator.dupe(u8, watch.path);
    errdefer self.allocator.free(path);
    const entry = try self.watching.getOrPut(self.allocator, key(window_id, watch.slot));
    if (entry.found_existing) self.allocator.free(entry.value_ptr.path);
    // A new watch in a slot replaces the old one and is written at once.
    entry.value_ptr.* = .{
        .window_id = window_id,
        .slot = watch.slot,
        .path = path,
        .offset = watch.offset,
        .limit = watch.limit,
        .generation = watch.generation,
    };
}

pub fn unwatchView(self: *Coordinator, window_id: io_service.WindowId, slot: u64) void {
    if (slot >= views.slots_per_window) return;
    if (self.watching.fetchRemove(key(window_id, @intCast(slot)))) |entry| self.allocator.free(entry.value.path);
}

/// Drops the watches of closed windows (the close sweep, §6).
pub fn dropWindowViews(self: *Coordinator, window_id: io_service.WindowId) void {
    for (0..views.slots_per_window) |slot| unwatchView(self, window_id, slot);
}

/// One job's entries in the watched folder.
const Level = struct {
    job_id: io_manager.JobId,
    tree: *const io_tree.TreeIndex,
    children: []const io_tree.EntryId,
    /// The folder's own entry, when it is inside the job's tree.
    folder: ?io_tree.EntryId,
};

/// Where `path` is in a job's tree, if the job writes there.
fn resolve(manager: *const io_manager.Manager, job_id: io_manager.JobId, path: []const u8) ?Level {
    const destination = manager.destinationDirectory(job_id) orelse return null;
    const tree = manager.treeIndex(job_id) orelse return null;
    if (std.mem.eql(u8, path, destination)) return .{ .job_id = job_id, .tree = tree, .children = tree.roots(), .folder = null };
    const root_destination = destination.len == 1 and destination[0] == '/';
    const prefix_len = if (root_destination) 1 else destination.len + 1;
    if (path.len <= prefix_len or !std.mem.startsWith(u8, path, destination) or
        (!root_destination and path[destination.len] != '/')) return null;
    var children = tree.roots();
    var folder: ?io_tree.EntryId = null;
    var components = std.mem.tokenizeScalar(u8, path[prefix_len..], '/');
    while (components.next()) |name| {
        const found = for (children) |id| {
            const entry = tree.getConst(id) orelse continue;
            if (entry.kind == .directory and std.mem.eql(u8, entry.name, name)) break entry;
        } else return null;
        folder = found.id;
        children = found.children.items;
    }
    return .{ .job_id = job_id, .tree = tree, .children = children, .folder = folder };
}

const max_levels = 8;

fn levels(manager: *io_manager.Manager, path: []const u8, out: *[max_levels]Level) []Level {
    var count: usize = 0;
    for (0..manager.jobCount()) |index| {
        if (count == out.len) break;
        const job_id = manager.jobSummaryAt(index).id;
        out[count] = resolve(manager, job_id, path) orelse continue;
        count += 1;
    }
    return out[0..count];
}

/// Writes the watched folders that changed. Returns when to look again
/// for throttled progress, if any.
pub fn publishViews(self: *Coordinator, now: i64) ?i64 {
    var deadline: ?i64 = null;
    var dropped: std.ArrayList(u64) = .empty;
    defer dropped.deinit(self.allocator);
    const manager = &self.runtime.manager;
    var iterator = self.watching.iterator();
    while (iterator.next()) |item| {
        const watching = item.value_ptr;
        var level_storage: [max_levels]Level = undefined;
        const found = levels(manager, watching.path, &level_storage);

        // Watching a folder inside a job's tree is interest in it: discover
        // it first, as navigating into it would.
        for (found) |level| {
            const folder = level.folder orelse continue;
            const mark = level.job_id *% 1_000_003 +% folder;
            if (watching.promoted == mark) continue;
            watching.promoted = mark;
            manager.prioritizeDiscovery(level.job_id, folder) catch {};
        }

        var shape = std.hash.Wyhash.init(0);
        var bytes: u64 = 0;
        var total: usize = 0;
        for (found) |level| {
            total += level.children.len;
            for (level.children) |entry_id| {
                const row = rowOf(manager, level, entry_id) orelse continue;
                shape.update(std.mem.asBytes(&level.job_id));
                shape.update(std.mem.asBytes(&entry_id));
                shape.update(std.mem.asBytes(&row.state));
                bytes +%= row.completed_bytes +% row.total_bytes *% 31;
            }
        }
        shape.update(std.mem.asBytes(&total));
        const shape_hash = shape.final();
        const structural = !watching.written or shape_hash != watching.shape;
        const progressed = bytes != watching.bytes;
        if (!structural and !progressed) continue;
        if (!structural and now - watching.last_ms < progress_interval_ms) {
            const at = watching.last_ms + progress_interval_ms;
            deadline = if (deadline) |d| @min(d, at) else at;
            continue;
        }
        const snapshot = build(self.allocator, manager, watching, found, total) catch continue;
        if (!self.service.deliverView(watching.window_id, snapshot)) {
            dropped.append(self.allocator, item.key_ptr.*) catch {};
            continue;
        }
        watching.shape = shape_hash;
        watching.bytes = bytes;
        watching.written = true;
        watching.last_ms = now;
    }
    for (dropped.items) |k| {
        if (self.watching.fetchRemove(k)) |entry| self.allocator.free(entry.value.path);
    }
    return deadline;
}

fn rowOf(manager: *const io_manager.Manager, level: Level, entry_id: io_tree.EntryId) ?views.Row {
    const entry = level.tree.getConst(entry_id) orelse return null;
    const progress = manager.entryBytes(level.job_id, entry_id) orelse return null;
    const operation = manager.entryOperationView(level.job_id, entry_id);
    var state: views.RowState = if (operation) |op| switch (op.state) {
        .pending, .waiting => .pending,
        .running => .running,
        .completed => .done,
        .skipped => .skipped,
        .failed => .failed,
        .cancelled => .cancelled,
    } else .pending;
    // A folder is done when what is under it is, not when it is created.
    if (entry.kind == .directory and state == .done and progress.completed_bytes < progress.total_bytes) state = .running;
    if (state == .pending and progress.completed_bytes > 0) state = .running;
    return .{
        .job_id = level.job_id,
        .entry_id = entry_id,
        .name_start = 0,
        .name_len = @intCast(@min(entry.name.len, std.math.maxInt(u16))),
        .kind = switch (entry.kind) {
            .directory => .directory,
            .regular_file => .regular_file,
            .symlink => .symlink,
            .other => .other,
        },
        .state = state,
        .child_count = @intCast(@min(entry.children.items.len, std.math.maxInt(u32))),
        .completed_bytes = progress.completed_bytes,
        .total_bytes = progress.total_bytes,
    };
}

fn build(
    allocator: std.mem.Allocator,
    manager: *const io_manager.Manager,
    watching: *const Watching,
    found: []const Level,
    total: usize,
) !*views.Snapshot {
    // Rows `offset` to `offset + limit` across the jobs, in job order.
    const start = @min(total, watching.offset);
    const end = @min(total, start + watching.limit);
    var rows = try allocator.alloc(views.Row, end - start);
    errdefer allocator.free(rows);
    var names: std.ArrayList(u8) = .empty;
    errdefer names.deinit(allocator);
    var index: usize = 0;
    var count: usize = 0;
    for (found) |level| {
        for (level.children) |entry_id| {
            defer index += 1;
            if (index < start or index >= end) continue;
            var row = rowOf(manager, level, entry_id) orelse continue;
            const entry = level.tree.getConst(entry_id).?;
            row.name_start = @intCast(names.items.len);
            try names.appendSlice(allocator, entry.name[0..row.name_len]);
            rows[count] = row;
            count += 1;
        }
    }
    if (count < rows.len) rows = try allocator.realloc(rows, count);
    const owned_names = try names.toOwnedSlice(allocator);
    errdefer allocator.free(owned_names);
    const snapshot = try allocator.create(views.Snapshot);
    snapshot.* = .{
        .allocator = allocator,
        .slot = watching.slot,
        .generation = watching.generation,
        .offset = @intCast(start),
        .total_children = @intCast(@min(total, std.math.maxInt(u32))),
        .rows = rows,
        .names = owned_names,
    };
    return snapshot;
}
