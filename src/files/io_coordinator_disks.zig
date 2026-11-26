//! Per-disk limits (docs/plans/files-io-worker-pools.md §4.4, step 5). A
//! spinning disk or one on USB slows down when several copies write to it at
//! once: two jobs onto one stick run one after the other instead of
//! thrashing it. Such a disk gets a limit of `serial_limit` operations at a
//! time, across every job that reads or writes it; other disks (SSDs, NVMe,
//! network mounts) are limited only by the lane. A partition, a btrfs
//! subvolume and a FUSE filesystem on a disk (ntfs-3g, exfat-fuse) all count
//! against that disk.
//!
//! The disk behind each filesystem is looked up once, in /proc and /sys
//! (`platform.mounts.diskOf`, answered from memory), when a job's plan
//! arrives; the plan already has every source's and the destination's device.
const std = @import("std");
const platform = @import("platform");
const io_transfer_plan = @import("io_transfer_plan.zig");
const io_manager = @import("io_manager.zig");
const Coordinator = @import("io_coordinator.zig").Coordinator;

/// Operations at a time on a serial disk. A starting value: calibrating it
/// on real disks is roadmap phase 7 (`Coordinator.serial_limit`, which the
/// bench sets from REDIWM_IO_BENCH_SERIAL_LIMIT; 0 there means no limit).
pub const serial_limit = 1;

/// Tells the Manager which serial disks job `job_id` touches, and their
/// limits. Best effort: a disk not found is not limited.
pub fn limitDisks(self: *Coordinator, job_id: io_manager.JobId, plan: *const io_transfer_plan.TransferPlan) void {
    var disks: [io_manager.max_job_disks]u64 = undefined;
    var count: usize = 0;
    add(self, plan.destination_device_id, &disks, &count);
    for (plan.sources.items) |source| {
        if (count == disks.len) break;
        if (source.metadata.device_id) |device| add(self, device, &disks, &count);
    }
    if (count > 0) _ = self.runtime.manager.setJobDisks(job_id, disks[0..count]);
}

fn add(self: *Coordinator, st_dev: u64, disks: *[io_manager.max_job_disks]u64, count: *usize) void {
    const disk = diskOf(self, st_dev) orelse return;
    if (!disk.serial or self.serial_limit == 0) return;
    if (std.mem.indexOfScalar(u64, disks[0..count.*], disk.key) != null) return;
    if (count.* == disks.len) return;
    self.runtime.manager.setDiskLimit(disk.key, self.serial_limit) catch return;
    disks[count.*] = disk.key;
    count.* += 1;
}

fn diskOf(self: *Coordinator, st_dev: u64) ?platform.mounts.Disk {
    if (self.disks.get(st_dev)) |known| return known;
    const found = platform.mounts.diskOf(st_dev);
    self.disks.put(self.allocator, st_dev, found) catch {};
    if (found) |disk| std.log.info("Files: device {d} is on disk {d}{s}", .{ st_dev, disk.key, if (disk.serial) " (one operation at a time)" else "" });
    return found;
}
