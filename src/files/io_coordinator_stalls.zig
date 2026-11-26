//! Jobs held up by a stuck task (docs/plans/files-io-worker-pools.md §4.2).
//! Work yields in bounded units (a copy chunk, a discovery batch, one
//! prepare), so a task a worker has run for a while without returning is stuck
//! in a syscall on a mount that does not answer.
//!
//! * After `suspect_after_ms` the mount it waits on is **suspect**: nothing
//!   new starts on it, in any lane, so it cannot take more workers (step 3c).
//!   Jobs that touch it are held in the Manager (`setJobHeld`); prepares,
//!   requests and staging work for it wait in their backlog while other work
//!   passes them. Running work goes on. Deletions are not held (their jobs are
//!   one task each and are not watched).
//! * After `report_after_ms` the job's record names the mount (`waiting_for`),
//!   and so do the records of jobs held on it,
//!   and the window shows "Waiting for <mount>…" with Cancel still offered
//!   (step 3b). There is no later state: a thread stuck in a syscall cannot be
//!   stopped.
//!
//! Both clear when the stuck task returns. Nothing here touches the stuck
//! mount: start times come from the pools, and mounts from
//! `/proc/self/mountinfo` (in memory, `platform.mounts`), read when the set
//! of suspects changes.
const std = @import("std");
const platform = @import("platform");
const io_workers = @import("io_workers.zig");
const io_service_tasks = @import("io_service_tasks.zig");
const io_requests = @import("io_requests.zig");
const io_coordinator = @import("io_coordinator.zig");
const Coordinator = io_coordinator.Coordinator;
const Published = io_coordinator.Published;
const Mount = platform.mounts.Borrowed;

pub const suspect_after_ms: i64 = 10_000;
pub const report_after_ms: i64 = 30_000;
/// A task that started after a pass looked is seen this much later at most.
const recheck_ms: i64 = 1_000;

/// Every worker of every lane that runs a job's tasks, at their caps.
const max_running = 32;

/// Prepares a worker has run past `suspect_after_ms`: they no longer count
/// against the prepares allowed in the pool, so others can start.
pub fn stuckPrepares(self: *Coordinator) usize {
    var running: [16]io_workers.Running = undefined;
    const count = self.tasks.runningTasks(&running);
    const now = io_workers.monotonicMs();
    var stuck: usize = 0;
    for (running[0..count]) |task| {
        if (task.key != 0 and now - task.since_ms >= suspect_after_ms and self.preparing.contains(task.key)) stuck += 1;
    }
    return stuck;
}

/// The coordinator's view of suspect mounts.
pub const State = struct {
    /// Owned mount points.
    suspects: std.ArrayList([]u8) = .empty,
    /// Read when the suspects change; null while there are none.
    table: ?platform.mounts.Table = null,
    /// The jobs found stuck last pass, to skip the work while they stay.
    stuck: std.ArrayList(u64) = .empty,
    /// Holds changed this pass: dispatch again before sleeping.
    changed: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        for (self.suspects.items) |point| allocator.free(point);
        self.suspects.deinit(allocator);
        self.stuck.deinit(allocator);
        if (self.table) |*table| table.deinit();
        self.* = undefined;
    }
};

/// Updates the suspects, the holds and each record's `waiting_for`. Returns
/// when to look again, or null when nothing runs.
pub fn watchStalls(self: *Coordinator, now: i64) ?i64 {
    // Stuck workers stop counting: queued work gets fresh ones (§4.3).
    var grown = self.tasks.grow(suspect_after_ms);
    grown += self.staging_tasks.grow(suspect_after_ms);
    grown += self.deletion_pool.grow(suspect_after_ms);
    if (self.runtime.discovery_executor) |*executor| grown += executor.grow(suspect_after_ms);
    if (self.runtime.operation_executor) |*executor| grown += executor.grow(suspect_after_ms);
    if (grown > 0) std.log.info("Files started {d} worker(s) beside stuck ones", .{grown});

    var running: [max_running]io_workers.Running = undefined;
    var count: usize = 0;
    var queued: usize = 0;
    count += self.tasks.runningTasks(running[count..]);
    queued += self.tasks.queuedCount();
    count += self.staging_tasks.runningTasks(running[count..]);
    queued += self.staging_tasks.queuedCount();
    if (self.runtime.discovery_executor) |*executor| {
        count += executor.runningTasks(running[count..]);
        queued += executor.queuedCount();
    }
    if (self.runtime.operation_executor) |*executor| {
        count += executor.runningTasks(running[count..]);
        queued += executor.queuedCount();
    }

    var deadline: ?i64 = if (queued > 0) now + recheck_ms else null;
    var stuck_jobs: [max_running]u64 = undefined;
    var stuck_count: usize = 0;
    // A held job waits on the same mounts: it says so once the stall is old
    // enough to report.
    var longest: i64 = 0;
    for (running[0..count]) |task| {
        if (task.key != 0) longest = @max(longest, now - task.since_ms);
    }
    const report_held = longest >= report_after_ms;
    var entries = self.published.iterator();
    while (entries.next()) |kv| {
        const job_id = kv.key_ptr.*;
        const entry = kv.value_ptr;
        var oldest: ?i64 = null;
        for (running[0..count]) |task| {
            if (task.key != job_id) continue;
            oldest = if (oldest) |at| @min(at, task.since_ms) else task.since_ms;
        }
        const age = if (oldest) |since| now - since else 0;
        if (oldest) |since| {
            if (age < suspect_after_ms) deadline = earliest(deadline, since + suspect_after_ms);
            if (age < report_after_ms) deadline = earliest(deadline, since + report_after_ms);
            if (age >= suspect_after_ms and stuck_count < stuck_jobs.len) {
                stuck_jobs[stuck_count] = job_id;
                stuck_count += 1;
            }
        }
        // A stuck job's work is not using its disks (§4.4).
        const stalled = age >= suspect_after_ms;
        if (stalled != entry.stalled) {
            entry.stalled = stalled;
            _ = self.runtime.manager.setJobStalled(job_id, stalled);
            self.stalls.changed = true;
        }
        report(self, job_id, entry, age >= report_after_ms or (entry.held and report_held), age);
    }

    updateSuspects(self, stuck_jobs[0..stuck_count]);
    updateHolds(self);
    return deadline;
}

fn earliest(current: ?i64, candidate: i64) i64 {
    return if (current) |value| @min(value, candidate) else candidate;
}

fn report(self: *Coordinator, job_id: u64, entry: *Published, stuck: bool, age: i64) void {
    if (stuck == (entry.record.waiting_for_len != 0)) return;
    var next = entry.record;
    if (stuck) {
        var buf: [256]u8 = undefined;
        next.setWaitingFor(mountName(self.allocator, entry, &buf));
        if (age >= report_after_ms)
            std.log.warn("Files job {d} waits on {s}: a task has not returned for {d} s", .{ job_id, next.waitingFor(), @divTrunc(age, 1000) })
        else
            std.log.warn("Files job {d} waits on {s}: held while it is suspect", .{ job_id, next.waitingFor() });
    } else {
        next.setWaitingFor("");
        std.log.info("Files job {d} is moving again", .{job_id});
    }
    self.service.updateJobRecord(next) catch |err| {
        std.log.err("Files job record update for job {d} failed: {s}", .{ job_id, @errorName(err) });
        return;
    };
    entry.record = next;
}

/// The suspects are the mounts the stuck jobs most likely wait on.
fn updateSuspects(self: *Coordinator, stuck_jobs: []const u64) void {
    const state = &self.stalls;
    if (std.mem.eql(u64, stuck_jobs, state.stuck.items)) return;
    state.stuck.clearRetainingCapacity();
    state.stuck.appendSlice(self.allocator, stuck_jobs) catch {};
    if (stuck_jobs.len == 0) {
        if (state.suspects.items.len == 0) return;
        for (state.suspects.items) |point| self.allocator.free(point);
        state.suspects.clearRetainingCapacity();
        if (state.table) |*table| table.deinit();
        state.table = null;
        state.changed = true;
        std.log.info("Files: no mount is suspect any more", .{});
        return;
    }
    // A new stall: read the mounts again (one may have appeared since).
    var table = platform.mounts.Table.load(self.allocator) orelse return;
    var next: std.ArrayList([]u8) = .empty;
    for (stuck_jobs) |job_id| {
        const entry = self.published.getPtr(job_id) orelse continue;
        var scratch: [2][4096]u8 = undefined;
        const mount = domainOf(&table, entry, &scratch) orelse continue;
        if (contains(next.items, mount.point)) continue;
        const owned = self.allocator.dupe(u8, mount.point) catch continue;
        next.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            continue;
        };
    }
    if (sameSet(next.items, state.suspects.items)) {
        for (next.items) |point| self.allocator.free(point);
        next.deinit(self.allocator);
        table.deinit();
        return;
    }
    for (state.suspects.items) |point| self.allocator.free(point);
    state.suspects.deinit(self.allocator);
    state.suspects = next;
    if (state.table) |*old| old.deinit();
    state.table = table;
    state.changed = true;
    for (next.items) |point| std.log.warn("Files: {s} is suspect; nothing new starts on it", .{point});
}

fn contains(points: []const []u8, point: []const u8) bool {
    for (points) |candidate| if (std.mem.eql(u8, candidate, point)) return true;
    return false;
}

fn sameSet(a: []const []u8, b: []const []u8) bool {
    if (a.len != b.len) return false;
    for (a) |point| if (!contains(b, point)) return false;
    return true;
}

/// Holds every job that touches a suspect mount, and lets the others go.
fn updateHolds(self: *Coordinator) void {
    var entries = self.published.iterator();
    while (entries.next()) |kv| {
        const entry = kv.value_ptr;
        const held = touchesSuspect(self, entry.source_path) or touchesSuspect(self, entry.destination_path);
        if (held == entry.held) continue;
        entry.held = held;
        _ = self.runtime.manager.setJobHeld(kv.key_ptr.*, held);
        self.stalls.changed = true;
    }
}

/// On a suspect mount; false when none is suspect.
pub fn isSuspect(self: *const Coordinator, path: []const u8) bool {
    const table = &(self.stalls.table orelse return false);
    var scratch: [4096]u8 = undefined;
    const mount = table.find(path, &scratch) orelse return false;
    return contains(self.stalls.suspects.items, mount.point);
}

fn touchesSuspect(self: *const Coordinator, path: ?[]const u8) bool {
    return if (path) |p| isSuspect(self, p) else false;
}

/// Whether a service task must wait because what it touches is suspect.
pub fn taskHeld(self: *const Coordinator, task: io_service_tasks.Task) bool {
    if (self.stalls.suspects.items.len == 0) return false;
    return switch (task) {
        .prepare_transfer => |prepare| switch (prepare.payload.data) {
            .transfer => |*request| blk: {
                if (isSuspect(self, request.destination_path)) break :blk true;
                for (request.sources) |source| if (isSuspect(self, source.path)) break :blk true;
                break :blk false;
            },
            else => false,
        },
        .request => |request| if (io_requests.primaryPath(&request.payload.data.request.request)) |path| isSuspect(self, path) else false,
        .scan_staging => |scan| isSuspect(self, scan.path),
        .delete_tree => |delete| isSuspect(self, delete.path),
    };
}

/// The mount the job most likely waits on. A copy reads its source and writes
/// its destination in one task, so which one hangs cannot be seen from here: a
/// network or FUSE mount is the likelier culprit than a disk; otherwise a job
/// still planning or discovering waits on its source, a running one on its
/// destination.
fn domainOf(table: *const platform.mounts.Table, entry: *const Published, scratch: *[2][4096]u8) ?Mount {
    const source = if (entry.source_path) |path| table.find(path, &scratch[0]) else null;
    const destination = if (entry.destination_path) |path| table.find(path, &scratch[1]) else null;
    return choose(source, destination, planning(entry));
}

fn planning(entry: *const Published) bool {
    return entry.record.state == .planning or entry.record.total_items == 0;
}

fn mountName(alloc: std.mem.Allocator, entry: *const Published, buf: []u8) []const u8 {
    if (platform.mounts.Table.load(alloc)) |loaded| {
        var table = loaded;
        defer table.deinit();
        var scratch: [2][4096]u8 = undefined;
        if (domainOf(&table, entry, &scratch)) |mount| return copyName(displayName(mount.point), buf);
    }
    return fallbackName(entry, planning(entry), buf);
}

fn choose(source: ?Mount, destination: ?Mount, is_planning: bool) ?Mount {
    const s = source orelse return destination;
    const d = destination orelse return s;
    if (s.anonymous != d.anonymous) return if (s.anonymous) s else d;
    return if (is_planning) s else d;
}

/// No mount table: the folder itself.
fn fallbackName(entry: *const Published, is_planning: bool, buf: []u8) []const u8 {
    const path = (if (is_planning) entry.source_path else entry.destination_path) orelse
        entry.source_path orelse entry.destination_path orelse return "?";
    const parent = if (is_planning) std.fs.path.dirname(path) orelse path else path;
    return copyName(displayName(parent), buf);
}

/// A mount is shown by its last component (`/run/media/u/USB STICK` reads
/// "USB STICK"); the root by its path.
fn displayName(point: []const u8) []const u8 {
    const base = std.fs.path.basename(point);
    return if (base.len == 0) point else base;
}

fn copyName(name: []const u8, buf: []u8) []const u8 {
    const len = @min(name.len, buf.len);
    @memcpy(buf[0..len], name[0..len]);
    return buf[0..len];
}

test "a stuck copy names the network mount over the disk, else source while planning" {
    const disk_source: Mount = .{ .point = "/", .anonymous = false };
    const stick: Mount = .{ .point = "/run/media/u/STICK", .anonymous = false };
    const nas: Mount = .{ .point = "/mnt/nas", .anonymous = true };
    try std.testing.expectEqualStrings("/mnt/nas", choose(nas, stick, false).?.point);
    try std.testing.expectEqualStrings("/mnt/nas", choose(disk_source, nas, true).?.point);
    try std.testing.expectEqualStrings("/", choose(disk_source, stick, true).?.point);
    try std.testing.expectEqualStrings("/run/media/u/STICK", choose(disk_source, stick, false).?.point);
    try std.testing.expectEqualStrings("STICK", displayName("/run/media/u/STICK"));
    try std.testing.expectEqualStrings("/", displayName("/"));
}
