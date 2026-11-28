const std = @import("std");
const model = @import("model.zig");
const Model = model.Model;

const a = std.testing.allocator;

test "a snapshot seeds jobs, their history and the aligned total" {
    var m: Model = .{};
    try std.testing.expect(try m.applyLine(a,
        \\{"version":1,"event":"snapshot","sequence":3,"jobs":[
        \\{"id":1,"kind":"copy","state":"running","label":"a.iso","destination":"/home/u/ISOs","source_count":1,"completed_bytes":50,"total_bytes":200,"rate_bytes_per_second":10,"rate_history":[1,2,3]},
        \\{"id":2,"kind":"delete","state":"paused","label":"old","completed_items":3,"total_items":4,"rate_history":[5]}]}
    ));
    try std.testing.expectEqual(@as(usize, 2), m.liveJobs().len);
    const first = m.liveJobs()[0];
    try std.testing.expectEqualStrings("a.iso", first.label.slice());
    try std.testing.expectEqualStrings("/home/u/ISOs", first.destination.slice());
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, first.history.values());
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 8 }, m.total.values());
    try std.testing.expectEqual(@as(?f32, 0.75), m.liveJobs()[1].fraction());
    const s = m.summary();
    try std.testing.expectEqual(@as(usize, 2), s.active);
    try std.testing.expect(!s.all_paused);
    // One byte job at 25% and one item job at 75%, a job's worth each.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.fraction.?, 0.001);
}

test "changes update, retire into done, and cancelled jobs are not kept" {
    var m: Model = .{};
    _ = try m.applyLine(a,
        \\{"version":1,"event":"snapshot","sequence":1,"jobs":[{"id":1,"state":"running","total_bytes":10},{"id":2,"state":"running"}]}
    );
    _ = try m.applyLine(a,
        \\{"version":1,"event":"jobs","sequence":2,"jobs":[{"id":1,"state":"completed","completed_bytes":10,"total_bytes":10},{"id":3,"state":"queued","conflict":true}]}
    );
    try std.testing.expectEqual(@as(usize, 3), m.liveJobs().len);
    try std.testing.expect(m.summary().attention);
    _ = try m.applyLine(a,
        \\{"version":1,"event":"jobs","sequence":3,"jobs":[{"id":1,"state":"completed","removed":true},{"id":2,"state":"cancelled","removed":true}]}
    );
    try std.testing.expectEqual(@as(usize, 1), m.liveJobs().len);
    try std.testing.expectEqual(@as(u64, 3), m.liveJobs()[0].id);
    try std.testing.expectEqual(@as(usize, 1), m.doneJobs().len);
    try std.testing.expectEqual(@as(u64, 1), m.doneJobs()[0].id);
    m.clearDone();
    try std.testing.expect(m.present());
    m.disconnected();
    try std.testing.expect(!m.present());
}

test "an answer to a request is not an event, and garbage is an error" {
    var m: Model = .{};
    try std.testing.expect(!try m.applyLine(a, "{\"version\":1,\"id\":\"s\",\"result\":{}}"));
    try std.testing.expectError(error.BadLine, m.applyLine(a, "nope"));
}

test "ticks record running rates and the summary sees all-paused" {
    var m: Model = .{};
    _ = try m.applyLine(a,
        \\{"version":1,"event":"jobs","sequence":1,"jobs":[{"id":4,"state":"running","rate_bytes_per_second":100,"total_bytes":1000,"completed_bytes":500}]}
    );
    m.tick();
    m.tick();
    try std.testing.expectEqualSlices(u64, &.{ 100, 100 }, m.total.values());
    try std.testing.expectEqual(@as(?u64, 5), m.liveJobs()[0].etaSeconds());
    _ = try m.applyLine(a,
        \\{"version":1,"event":"jobs","sequence":2,"jobs":[{"id":4,"state":"paused","total_bytes":1000,"completed_bytes":500}]}
    );
    m.tick();
    try std.testing.expectEqual(@as(u64, 0), m.total.values()[2]);
    try std.testing.expect(m.summary().all_paused);
    try std.testing.expectEqual(@as(?u64, null), m.liveJobs()[0].etaSeconds());
}

test "history keeps the last minute" {
    var h: model.History = .{};
    for (0..70) |i| h.push(i);
    try std.testing.expectEqual(@as(usize, model.history_len), h.values().len);
    try std.testing.expectEqual(@as(u64, 10), h.values()[0]);
    try std.testing.expectEqual(@as(u64, 69), h.peak());
    var seeded: model.History = .{};
    var long: [120]u64 = undefined;
    for (&long, 0..) |*v, i| v.* = i;
    seeded.seed(&long);
    try std.testing.expectEqual(@as(u64, 60), seeded.values()[0]);
}

test "formatting" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", model.formatBytes(&buf, 512));
    try std.testing.expectEqualStrings("1.5 MB", model.formatBytes(&buf, 1024 * 1536));
    try std.testing.expectEqualStrings("3m 05s", model.formatDuration(&buf, 185));
    try std.testing.expectEqualStrings("1h 02m", model.formatDuration(&buf, 3720));
    try std.testing.expectEqualStrings("~/ISOs", model.shortPath(&buf, "/home/u/ISOs", "/home/u"));
    try std.testing.expectEqualStrings("/home/uu/x", model.shortPath(&buf, "/home/uu/x", "/home/u"));
}

test "downloads: seeding is apart from the active count, and choosing asks for attention" {
    var m: Model = .{};
    _ = try m.applyLine(a,
        \\{"version":1,"event":"snapshot","sequence":1,"jobs":[
        \\{"id":281474976710656,"kind":"download","state":"seeding","label":"distro.iso","total_bytes":1000,"rate_bytes_per_second":300,"upload_rate_bytes_per_second":300,"uploaded_bytes":250,"ratio_limit":1,"rate_history":[100,200]},
        \\{"id":281474976710657,"kind":"download","state":"running","label":"video","total_bytes":800,"completed_bytes":200,"rate_bytes_per_second":50,"upload_rate_bytes_per_second":10,"peers":12,"rate_history":[40]},
        \\{"id":281474976710658,"kind":"download","state":"queued","label":"album","choose_files":true}]}
    );
    const s = m.summary();
    try std.testing.expectEqual(@as(usize, 2), s.active);
    try std.testing.expectEqual(@as(usize, 1), s.seeding);
    try std.testing.expectEqual(@as(u64, 310), s.upload_rate);
    try std.testing.expect(s.attention);
    const seeding = m.liveJobs()[0];
    try std.testing.expectEqual(model.Kind.download, seeding.kind);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), seeding.ratio().?, 0.001);
    try std.testing.expectEqualSlices(u64, &.{ 0, 40 }, m.total.values());
    try std.testing.expectEqualSlices(u64, &.{ 100, 200 }, m.upload.values());
    m.tick();
    try std.testing.expectEqual(@as(u64, 310), m.upload.values()[2]);
    try std.testing.expectEqual(@as(u64, 50), m.total.values()[2]);
}
