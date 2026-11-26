//! Jobs held up by a stuck task (docs/plans/files-io-worker-pools.md §4.2,
//! step 3b). Work yields in bounded units (a copy chunk, a discovery batch, one
//! prepare), so a task a worker has run for `report_after_ms` without
//! returning is stuck in a syscall on a mount that does not answer. Its job's
//! record then names that mount (`waiting_for`), and the window shows "Waiting
//! for <mount>…" with Cancel still offered. There is no later state: a thread
//! stuck in a syscall cannot be stopped. The record clears once the task
//! returns.
//!
//! Nothing here touches the stuck mount: the workers' start times come from
//! the pools, and the mount is looked up in `/proc/self/mountinfo` (in
//! memory, `platform.mounts`), once per stall.
const std = @import("std");
const platform = @import("platform");
const io_workers = @import("io_workers.zig");
const io_coordinator = @import("io_coordinator.zig");
const Coordinator = io_coordinator.Coordinator;
const Published = io_coordinator.Published;

pub const report_after_ms: i64 = 30_000;
/// A task that started after a pass looked is seen this much later at most.
const recheck_ms: i64 = 1_000;

/// Every worker of every lane that runs a job's tasks.
const max_running = 32;

/// Sets or clears `waiting_for` on each job's record. Returns when to look
/// again, or null when nothing runs.
pub fn watchStalls(self: *Coordinator, now: i64) ?i64 {
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
    var entries = self.published.iterator();
    while (entries.next()) |kv| {
        const job_id = kv.key_ptr.*;
        const entry = kv.value_ptr;
        var oldest: ?i64 = null;
        for (running[0..count]) |task| {
            if (task.key != job_id) continue;
            oldest = if (oldest) |at| @min(at, task.since_ms) else task.since_ms;
        }
        const stuck = if (oldest) |since| now - since >= report_after_ms else false;
        if (oldest) |since| if (!stuck) {
            deadline = earliest(deadline, since + report_after_ms);
        };
        if (stuck == (entry.record.waiting_for_len != 0)) continue;

        var next = entry.record;
        if (stuck) {
            var buf: [256]u8 = undefined;
            next.setWaitingFor(mountName(self.allocator, entry, &buf));
            std.log.warn("Files job {d} waits on {s}: a task has not returned for {d} s", .{ job_id, next.waitingFor(), @divTrunc(now - oldest.?, 1000) });
        } else {
            next.setWaitingFor("");
            std.log.info("Files job {d} is moving again", .{job_id});
        }
        self.service.updateJobRecord(next) catch |err| {
            std.log.err("Files job record update for job {d} failed: {s}", .{ job_id, @errorName(err) });
            continue;
        };
        entry.record = next;
    }
    return deadline;
}

fn earliest(current: ?i64, candidate: i64) i64 {
    return if (current) |value| @min(value, candidate) else candidate;
}

/// The mount the job most likely waits on. A copy reads its source and writes
/// its destination in one task, so which one hangs cannot be seen from here: a
/// network or FUSE mount is the likelier culprit than a disk; otherwise a job
/// still planning or discovering waits on its source, a running one on its
/// destination.
fn mountName(allocator: std.mem.Allocator, entry: *const Published, buf: []u8) []const u8 {
    const source = if (entry.source_path) |path| platform.mounts.mountOf(allocator, path) catch null else null;
    defer if (source) |mount| allocator.free(mount.point);
    const destination = if (entry.destination_path) |path| platform.mounts.mountOf(allocator, path) catch null else null;
    defer if (destination) |mount| allocator.free(mount.point);

    const planning = entry.record.state == .planning or entry.record.total_items == 0;
    const pick = choose(source, destination, planning) orelse
        return fallbackName(entry, planning, buf);
    return copyName(displayName(pick.point), buf);
}

fn choose(source: ?platform.mounts.Mount, destination: ?platform.mounts.Mount, planning: bool) ?platform.mounts.Mount {
    const s = source orelse return destination;
    const d = destination orelse return s;
    if (s.anonymous != d.anonymous) return if (s.anonymous) s else d;
    return if (planning) s else d;
}

/// No mount table: the folder itself.
fn fallbackName(entry: *const Published, planning: bool, buf: []u8) []const u8 {
    const path = (if (planning) entry.source_path else entry.destination_path) orelse
        entry.source_path orelse entry.destination_path orelse return "?";
    const parent = if (planning) std.fs.path.dirname(path) orelse path else path;
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
    var disk_a = "/".*;
    var disk_b = "/run/media/u/STICK".*;
    var net = "/mnt/nas".*;
    const disk_source: platform.mounts.Mount = .{ .point = &disk_a, .anonymous = false };
    const stick: platform.mounts.Mount = .{ .point = &disk_b, .anonymous = false };
    const nas: platform.mounts.Mount = .{ .point = &net, .anonymous = true };
    try std.testing.expectEqualStrings("/mnt/nas", choose(nas, stick, false).?.point);
    try std.testing.expectEqualStrings("/mnt/nas", choose(disk_source, nas, true).?.point);
    try std.testing.expectEqualStrings("/", choose(disk_source, stick, true).?.point);
    try std.testing.expectEqualStrings("/run/media/u/STICK", choose(disk_source, stick, false).?.point);
    try std.testing.expectEqualStrings("STICK", displayName("/run/media/u/STICK"));
    try std.testing.expectEqualStrings("/", displayName("/"));
}
