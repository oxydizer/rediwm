//! Job views on the coordinator (architecture §14). Methods of `Coordinator`,
//! aliased there.
//!
//! A window watches a level of a job's tree; each pass the coordinator writes
//! a bounded snapshot of every watched level that changed: at once when its
//! shape or a row's state changed, at most every `progress_interval_ms` when
//! only bytes moved. Snapshots are built from the Manager in memory, never
//! with I/O, and their cost is bounded by the rows watched.
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
    watch: views.Watch,
    /// What the last snapshot showed: its shape and states, and its bytes.
    shape: u64 = 0,
    bytes: u64 = 0,
    written: bool = false,
    last_ms: i64 = 0,
};

fn key(window_id: io_service.WindowId, slot: u8) u64 {
    return (window_id << 2) | slot;
}

pub fn watchView(self: *Coordinator, window_id: io_service.WindowId, payload: ?*io_service.OwnedPayload) !void {
    const owned = payload orelse return error.MissingWatchPayload;
    const watch = switch (owned.data) {
        .watch => |w| w,
        else => return error.UnexpectedWatchPayload,
    };
    // A new watch in a slot replaces the old one and is written at once.
    try self.watching.put(self.allocator, key(window_id, watch.slot), .{ .window_id = window_id, .watch = watch });
}

pub fn unwatchView(self: *Coordinator, window_id: io_service.WindowId, slot: u64) void {
    if (slot >= views.slots_per_window) return;
    _ = self.watching.remove(key(window_id, @intCast(slot)));
}

/// Writes the watched levels that changed. Returns when to look again
/// for throttled progress, if any.
pub fn publishViews(self: *Coordinator, now: i64) ?i64 {
    var deadline: ?i64 = null;
    var dropped: std.ArrayList(u64) = .empty;
    defer dropped.deinit(self.allocator);
    var iterator = self.watching.iterator();
    while (iterator.next()) |item| {
        const watching = item.value_ptr;
        const manager = &self.runtime.manager;
        // A job that retired, or a window that closed, ends the watch.
        const tree = manager.treeIndex(watching.watch.job_id) orelse {
            dropped.append(self.allocator, item.key_ptr.*) catch {};
            continue;
        };
        const children = levelChildren(tree, watching.watch.entry_id) orelse {
            dropped.append(self.allocator, item.key_ptr.*) catch {};
            continue;
        };
        const window = rowWindow(children.len, watching.watch);
        var shape = std.hash.Wyhash.init(children.len);
        var bytes: u64 = 0;
        for (children[window.start..window.end]) |entry_id| {
            const row = rowOf(manager, tree, watching.watch.job_id, entry_id) orelse continue;
            shape.update(std.mem.asBytes(&entry_id));
            shape.update(std.mem.asBytes(&row.state));
            shape.update(std.mem.asBytes(&row.child_count));
            bytes +%= row.completed_bytes +% row.total_bytes *% 31;
        }
        const shape_hash = shape.final();
        const structural = !watching.written or shape_hash != watching.shape;
        const progressed = bytes != watching.bytes;
        if (!structural and !progressed) continue;
        if (!structural and now - watching.last_ms < progress_interval_ms) {
            const at = watching.last_ms + progress_interval_ms;
            deadline = if (deadline) |d| @min(d, at) else at;
            continue;
        }
        const snapshot = build(self.allocator, manager, tree, watching.watch, children, window) catch continue;
        if (!self.service.deliverView(watching.window_id, snapshot)) {
            dropped.append(self.allocator, item.key_ptr.*) catch {};
            continue;
        }
        watching.shape = shape_hash;
        watching.bytes = bytes;
        watching.written = true;
        watching.last_ms = now;
    }
    for (dropped.items) |k| _ = self.watching.remove(k);
    return deadline;
}

/// Drops the watches of closed windows (the close sweep, §6).
pub fn dropWindowViews(self: *Coordinator, window_id: io_service.WindowId) void {
    for (0..views.slots_per_window) |slot| _ = self.watching.remove(key(window_id, @intCast(slot)));
}

fn levelChildren(tree: *const io_tree.TreeIndex, entry_id: u64) ?[]const io_tree.EntryId {
    if (entry_id == 0) return tree.roots();
    const entry = tree.getConst(entry_id) orelse return null;
    return entry.children.items;
}

fn rowWindow(count: usize, watch: views.Watch) struct { start: usize, end: usize } {
    const start = @min(count, watch.offset);
    return .{ .start = start, .end = @min(count, start + watch.limit) };
}

fn rowOf(manager: *const io_manager.Manager, tree: *const io_tree.TreeIndex, job_id: u64, entry_id: io_tree.EntryId) ?views.Row {
    const entry = tree.getConst(entry_id) orelse return null;
    const progress = manager.entryBytes(job_id, entry_id) orelse return null;
    const operation = manager.entryOperationView(job_id, entry_id);
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
    tree: *const io_tree.TreeIndex,
    watch: views.Watch,
    children: []const io_tree.EntryId,
    window: anytype,
) !*views.Snapshot {
    const shown = children[window.start..window.end];
    var names_len: usize = 0;
    for (shown) |entry_id| {
        if (tree.getConst(entry_id)) |entry| names_len += @min(entry.name.len, std.math.maxInt(u16));
    }
    const rows = try allocator.alloc(views.Row, shown.len);
    errdefer allocator.free(rows);
    const names = try allocator.alloc(u8, names_len);
    errdefer allocator.free(names);
    var count: usize = 0;
    var at: usize = 0;
    for (shown) |entry_id| {
        var row = rowOf(manager, tree, watch.job_id, entry_id) orelse continue;
        const entry = tree.getConst(entry_id).?;
        row.name_start = @intCast(at);
        @memcpy(names[at..][0..row.name_len], entry.name[0..row.name_len]);
        at += row.name_len;
        rows[count] = row;
        count += 1;
    }
    // Rows whose entry vanished between counting and copying are left out.
    const kept = if (count < rows.len) try allocator.realloc(rows, count) else rows;
    const snapshot = try allocator.create(views.Snapshot);
    snapshot.* = .{
        .allocator = allocator,
        .slot = watch.slot,
        .job_id = watch.job_id,
        .entry_id = watch.entry_id,
        .offset = @intCast(window.start),
        .total_children = @intCast(@min(children.len, std.math.maxInt(u32))),
        .rows = kept,
        .names = names,
    };
    return snapshot;
}
