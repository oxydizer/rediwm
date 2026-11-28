//! The window's view of every I/O service job, from the job table (stage
//! S3b): what the Transfers card lists, with pause, resume and cancel. Jobs
//! of every window appear, not only this one's: a job belongs to the
//! service, and any window may control it.
const std = @import("std");
const io_service = @import("io_service.zig");

pub const Model = struct {
    records: [io_service.max_live_jobs]io_service.JobRecord = undefined,
    len: usize = 0,
    /// Bumped whenever the list of active jobs or a row's look changes.
    revision: u64 = 0,

    /// Applies a changed record: a retired job leaves, others are kept.
    /// Downloads are not kept: the window lists torrents from the helper.
    pub fn apply(self: *Model, record: io_service.JobRecord) void {
        if (record.kind == .download) return;
        for (self.records[0..self.len], 0..) |*known, i| {
            if (known.id != record.id) continue;
            if (record.removed) {
                self.records[i] = self.records[self.len - 1];
                self.len -= 1;
            } else known.* = record;
            self.revision +%= 1;
            return;
        }
        if (record.removed or self.len == self.records.len) return;
        self.records[self.len] = record;
        self.len += 1;
        self.revision +%= 1;
    }

    /// A resync: what follows is the whole table.
    pub fn clear(self: *Model) void {
        self.len = 0;
        self.revision +%= 1;
    }

    /// The jobs still running, oldest first, into `out`.
    pub fn active(self: *const Model, out: []io_service.JobRecord) []io_service.JobRecord {
        var count: usize = 0;
        for (self.records[0..self.len]) |record| {
            if (record.state.isTerminal() or count == out.len) continue;
            out[count] = record;
            count += 1;
        }
        const shown = out[0..count];
        std.mem.sort(io_service.JobRecord, shown, {}, struct {
            fn less(_: void, a: io_service.JobRecord, b: io_service.JobRecord) bool {
                return a.started_at_ms < b.started_at_ms or (a.started_at_ms == b.started_at_ms and a.id < b.id);
            }
        }.less);
        return shown;
    }

    pub fn find(self: *const Model, job_id: io_service.JobId) ?io_service.JobRecord {
        for (self.records[0..self.len]) |record| if (record.id == job_id) return record;
        return null;
    }
};

/// Pause, resume and cancel apply to copies, moves and extractions; a
/// deletion can only be cancelled.
pub fn canPause(record: io_service.JobRecord) bool {
    return switch (record.kind) {
        .copy, .move, .extract => record.state == .running or record.state == .queued or record.state == .paused or record.state == .waiting,
        else => false,
    };
}

/// Done over total, when the total is known.
pub fn fraction(record: io_service.JobRecord) ?f64 {
    if (record.total_bytes > 0) return @min(1.0, @as(f64, @floatFromInt(record.completed_bytes)) / @as(f64, @floatFromInt(record.total_bytes)));
    if (record.total_items > 0) return @min(1.0, @as(f64, @floatFromInt(record.completed_items)) / @as(f64, @floatFromInt(record.total_items)));
    return null;
}

test "the model keeps live jobs, drops retired ones and lists the running oldest first" {
    var model: Model = .{};
    model.apply(.{ .id = 2, .state = .running, .started_at_ms = 20 });
    model.apply(.{ .id = 1, .state = .queued, .started_at_ms = 10 });
    model.apply(.{ .id = 3, .state = .completed, .started_at_ms = 5 });
    var out: [8]io_service.JobRecord = undefined;
    const shown = model.active(&out);
    try std.testing.expectEqual(@as(usize, 2), shown.len);
    try std.testing.expectEqual(@as(u64, 1), shown[0].id);
    try std.testing.expectEqual(@as(u64, 2), shown[1].id);

    model.apply(.{ .id = 2, .state = .completed, .removed = true });
    try std.testing.expectEqual(@as(usize, 2), model.len);
    try std.testing.expectEqual(@as(usize, 1), model.active(&out).len);
    try std.testing.expectEqual(@as(?f64, 0.25), fraction(.{ .completed_bytes = 1, .total_bytes = 4 }));
    try std.testing.expectEqual(@as(?f64, null), fraction(.{}));
}
