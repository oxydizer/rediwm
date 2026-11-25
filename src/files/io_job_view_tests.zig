//! Job views: the coordinator's writer against a Manager job built by hand,
//! so every step is deterministic.
const std = @import("std");
const io_coordinator = @import("io_coordinator.zig");
const io_service = @import("io_service.zig");
const io_runtime = @import("io_runtime.zig");
const io_manager = @import("io_manager.zig");
const views = @import("io_job_views.zig");
const job_views = @import("io_coordinator_views.zig");

const allocator = std.testing.allocator;

const Fixture = struct {
    service: io_service.Service = .{},
    runtime: io_runtime.Runtime = undefined,
    coordinator: io_coordinator.Coordinator = undefined,
    window: io_service.Handle = undefined,

    fn start(self: *Fixture) !void {
        try self.service.init();
        self.runtime = io_runtime.Runtime.init(allocator);
        self.coordinator = .{ .allocator = allocator, .service = &self.service, .runtime = &self.runtime };
        self.window = try self.service.registerWindow();
    }

    fn stop(self: *Fixture) void {
        job_views.deinitWatching(&self.coordinator);
        self.window.close();
        self.runtime.deinit();
        self.service.deinit();
    }

    fn watch(self: *Fixture, w: views.Watch) !void {
        var payload = try io_service.OwnedPayload.createWatch(allocator, w);
        defer payload.deinit();
        try job_views.watchView(&self.coordinator, self.window.window_id, payload);
    }

    fn take(self: *Fixture, slot: u8) !?*io_service.ViewSnapshot {
        return self.window.takeView(slot);
    }
};

test "a watched folder shows what jobs bring into it, at any depth, and follows progress" {
    var f: Fixture = .{};
    try f.start();
    defer f.stop();
    const manager = &f.runtime.manager;

    const job = try manager.createJob(f.window.window_id);
    const folder = try manager.addTreeRoot(job, "folder", .directory, .{}, null);
    const a = try manager.addTreeEntry(job, folder, "a.bin", .regular_file, .{ .size = 100 }, null);
    const b = try manager.addTreeEntry(job, folder, "b.bin", .regular_file, .{ .size = 300 }, null);
    try manager.setDestinationDirectory(job, "/dest");
    _ = try manager.addEntryOperation(job, folder, .create_directory);
    _ = try manager.addEntryOperation(job, a, .copy_file);
    _ = try manager.addEntryOperation(job, b, .copy_file);
    try manager.queueJob(job);

    try f.watch(.{ .slot = 0, .path = "/dest" });
    try f.watch(.{ .slot = 1, .path = "/dest/folder" });
    try f.watch(.{ .slot = 2, .path = "/elsewhere" });
    try f.watch(.{ .slot = 3, .path = "/" });
    _ = job_views.publishViews(&f.coordinator, 1000);

    const roots = (try f.take(0)).?;
    defer roots.destroy();
    try std.testing.expectEqual(@as(u32, 1), roots.total_children);
    try std.testing.expectEqual(job, roots.rows[0].job_id);
    try std.testing.expectEqualStrings("folder", roots.name(roots.rows[0]));
    try std.testing.expectEqual(views.Kind.directory, roots.rows[0].kind);
    try std.testing.expectEqual(@as(u64, 400), roots.rows[0].total_bytes);
    try std.testing.expectEqual(@as(u32, 2), roots.rows[0].child_count);
    try std.testing.expectEqual(views.RowState.pending, roots.rows[0].state);

    const level = (try f.take(1)).?;
    defer level.destroy();
    try std.testing.expectEqual(@as(usize, 2), level.rows.len);
    try std.testing.expectEqualStrings("a.bin", level.name(level.rows[0]));
    try std.testing.expectEqualStrings("b.bin", level.name(level.rows[1]));
    // A folder no job writes into gets an empty snapshot, once.
    const elsewhere = (try f.take(2)).?;
    defer elsewhere.destroy();
    try std.testing.expectEqual(@as(usize, 0), elsewhere.rows.len);
    // Above the destination, the folder the job writes beneath shows its
    // progress, as a real folder.
    const above = (try f.take(3)).?;
    defer above.destroy();
    try std.testing.expectEqual(@as(usize, 1), above.rows.len);
    try std.testing.expectEqualStrings("dest", above.name(above.rows[0]));
    try std.testing.expect(above.rows[0].materialized);
    try std.testing.expectEqual(@as(u64, 400), above.rows[0].total_bytes);

    // Nothing changed: nothing is written.
    _ = job_views.publishViews(&f.coordinator, 1010);
    try std.testing.expectEqual(@as(?*io_service.ViewSnapshot, null), try f.take(0));

    // The folder is made and a file runs: a state change is written at once.
    try std.testing.expect(manager.completeWork(manager.dispatchNext().?, .completed));
    const file = manager.dispatchNext().?;
    const file_total = manager.entryBytes(job, manager.operationDetails(file).?.entry_id).?.total_bytes;
    try std.testing.expect(manager.completeWork(file, .yielded));
    try std.testing.expect(manager.recordOperationProgress(file, 50, file_total, .transferring));
    _ = job_views.publishViews(&f.coordinator, 1012);
    _ = job_views.publishViews(&f.coordinator, 1013);
    const moving = (try f.take(1)).?;
    defer moving.destroy();
    var running: usize = 0;
    for (moving.rows) |row| {
        if (row.completed_bytes == 50) running += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), running);
    // The root level shows the folder's bytes moving.
    const root_moving = (try f.take(0)).?;
    defer root_moving.destroy();
    try std.testing.expectEqual(@as(u64, 50), root_moving.rows[0].completed_bytes);
    try std.testing.expectEqual(views.RowState.running, root_moving.rows[0].state);

    // Bytes alone wait for the progress interval.
    try std.testing.expect(manager.recordOperationProgress(file, 60, file_total, .transferring));
    try std.testing.expect(job_views.publishViews(&f.coordinator, 1020) != null);
    try std.testing.expectEqual(@as(?*io_service.ViewSnapshot, null), try f.take(0));
    _ = job_views.publishViews(&f.coordinator, 1070);
    const later = (try f.take(0)).?;
    defer later.destroy();
    try std.testing.expectEqual(@as(u64, 60), later.rows[0].completed_bytes);

    // Unwatched: nothing more.
    job_views.unwatchView(&f.coordinator, f.window.window_id, 0);
    try std.testing.expect(manager.recordOperationProgress(file, 70, file_total, .transferring));
    _ = job_views.publishViews(&f.coordinator, 2000);
    try std.testing.expectEqual(@as(?*io_service.ViewSnapshot, null), try f.take(0));
}
