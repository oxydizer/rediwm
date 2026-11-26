const std = @import("std");
const io_service = @import("io_service.zig");
const torrents = @import("torrents.zig");
const bridge_mod = @import("io_torrent_bridge.zig");

const base = io_service.torrent_job_base;

fn transfer(comptime id: []const u8, comptime flags: []const u8) []const u8 {
    return "{\"id\":\"" ++ id ++ "\",\"name\":\"" ++ id ++ ".iso\",\"destination\":\"/d\",\"download_directory\":\"/home/u/Downloads\",\"storage\":\"/s\"," ++
        "\"published\":false,\"progress\":0,\"download_rate\":2048,\"upload_rate\":512,\"total\":1000,\"done\":250,\"uploaded\":300,\"ratio\":1,\"limit\":1048576,\"error\":\"\",\"files\":[]," ++ flags ++ "}";
}

fn feed(bridge: *bridge_mod.Bridge, json: []const u8, now: i64) !void {
    if (bridge.client.snapshot) |*s| s.deinit();
    bridge.client.snapshot = try std.json.parseFromSlice(torrents.Snapshot, std.heap.c_allocator, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    bridge.mirror(now);
}

test "downloads mirror into the job table and leave it as they stop" {
    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();
    var bridge: bridge_mod.Bridge = .{ .service = &service };
    defer if (bridge.client.snapshot) |*s| s.deinit();

    const running = comptime transfer("a", "\"pending\":false,\"metadata\":true,\"paused\":false,\"finished\":false");
    const choosing = comptime transfer("b", "\"pending\":true,\"metadata\":true,\"paused\":true,\"finished\":false");
    const old = comptime transfer("c", "\"pending\":false,\"metadata\":true,\"paused\":true,\"finished\":true");
    try feed(&bridge, "{\"transfers\":[" ++ running ++ "," ++ choosing ++ "," ++ old ++ "]}", 1000);
    const a = service.getJobRecord(base).?;
    try std.testing.expectEqual(io_service.JobState.running, a.state);
    try std.testing.expectEqual(io_service.JobKind.download, a.kind);
    try std.testing.expectEqualStrings("a.iso", a.label());
    try std.testing.expectEqualStrings("/home/u/Downloads", a.destination());
    try std.testing.expectEqual(@as(u64, 2048), a.rate_bytes_per_second);
    try std.testing.expectEqual(@as(u64, 300), a.uploaded_bytes);
    const b = service.getJobRecord(base + 1).?;
    try std.testing.expect(b.choose_files and b.state == .queued);
    // Stopped before this process saw it: not a job.
    try std.testing.expect(service.getJobRecord(base + 2) == null);

    const seeding = comptime transfer("a", "\"pending\":false,\"metadata\":true,\"paused\":false,\"finished\":true");
    try feed(&bridge, "{\"transfers\":[" ++ seeding ++ "," ++ old ++ "]}", 2000);
    const s = service.getJobRecord(base).?;
    try std.testing.expectEqual(io_service.JobState.seeding, s.state);
    try std.testing.expectEqual(@as(u64, 512), s.rate_bytes_per_second);
    // Removed from the helper: gone.
    try std.testing.expect(service.getJobRecord(base + 1) == null);

    const stopped = comptime transfer("a", "\"pending\":false,\"metadata\":true,\"paused\":true,\"finished\":true");
    try feed(&bridge, "{\"transfers\":[" ++ stopped ++ "," ++ old ++ "]}", 3000);
    try std.testing.expect(service.getJobRecord(base) == null);
    try std.testing.expect(!bridge.active());
}

test "download controls go to the bridge, not the coordinator" {
    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();
    var record: io_service.JobRecord = .{ .id = base + 7, .kind = .download, .state = .failed };
    record.setLabel("x");
    try service.createJobRecord(record, false);
    // A failed download can still be removed.
    try service.sendControl(.cancel, base + 7);
    try std.testing.expect(!service.hasQueuedCommands());
    const control = service.takeTorrentControl().?;
    try std.testing.expectEqual(io_service.CommandKind.cancel_job, control.kind);
    try std.testing.expectEqual(base + 7, control.job_id);
    try std.testing.expect(service.takeTorrentControl() == null);
}
