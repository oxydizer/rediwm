//! Subscribers of the Files endpoint (architecture §13, contract §8): the
//! shell's Transfers panel. A subscriber is an external consumer of the job
//! table. It gets a snapshot of every job (with its speed history), then each
//! change as a `jobs` event, by cursor.
//!
//! A subscriber that stops reading only stops its own cursor: nothing is
//! fetched for it while its unsent output is above `low_water`. The table
//! keeps only the newest record of each job, so a reader that catches up
//! receives the newest state, not every step. Falling behind the table's
//! tombstone ring makes the next fetch a resync, which becomes a fresh
//! snapshot. Output past `max_output` or stuck for `stall_ms` disconnects it
//! (contract §9.3); a reconnect starts from a new snapshot.
const std = @import("std");
const io_service = @import("io_service.zig");
const io_job_table = @import("io_job_table.zig");
const wire = @import("io_endpoint_wire.zig");

const Allocator = std.mem.Allocator;
const JobRecord = io_service.JobRecord;

/// Fetching pauses while more than this is waiting to be sent.
pub const low_water = 64 * 1024;
/// A subscriber whose unsent output would pass this is disconnected.
pub const max_output = 1024 * 1024;
/// A subscriber that has not taken any output for this long is disconnected.
pub const stall_ms = 30_000;
/// Records fetched per table call.
const batch = 32;

pub const Subscriber = struct {
    handle: io_service.ExternalHandle,
    /// Collecting a snapshot: every record of the sweep, newest per job.
    in_snapshot: bool = true,
    snapshot: std.ArrayList(JobRecord) = .empty,
    /// The highest revision delivered or collected.
    sequence: u64 = 0,

    pub fn init(service: *io_service.Service) !Subscriber {
        return .{ .handle = try service.registerExternal() };
    }

    pub fn deinit(self: *Subscriber, allocator: Allocator) void {
        self.snapshot.deinit(allocator);
        self.handle.close();
    }

    /// Fetches what changed and appends the events to `output`, while it
    /// stays below `low_water`. False when the subscriber must be dropped:
    /// the output would pass `max_output`, or memory ran out.
    pub fn pump(self: *Subscriber, allocator: Allocator, output: *std.ArrayList(u8)) bool {
        var records: [batch]JobRecord = undefined;
        while (output.items.len < low_water) {
            const result = self.handle.fetchChanges(&records);
            const got = records[0..result.count];
            if (result.resync) {
                self.in_snapshot = true;
                self.snapshot.clearRetainingCapacity();
            }
            for (got) |record| self.sequence = @max(self.sequence, record.revision);
            if (self.in_snapshot) {
                for (got) |record| self.collect(allocator, record) catch return false;
                if (!result.more) {
                    if (!self.emitSnapshot(allocator, output)) return false;
                    self.in_snapshot = false;
                    self.snapshot.clearRetainingCapacity();
                }
            } else if (got.len > 0) {
                const line = wire.formatEvent(allocator, .jobs, self.sequence, got, null) catch return false;
                defer allocator.free(line);
                if (!append(allocator, output, line)) return false;
            }
            if (!result.more) return true;
        }
        return true;
    }

    /// Keeps the newest record of each job seen during the sweep.
    fn collect(self: *Subscriber, allocator: Allocator, record: JobRecord) !void {
        for (self.snapshot.items) |*existing| if (existing.id == record.id) {
            if (record.revision > existing.revision) existing.* = record;
            return;
        };
        try self.snapshot.append(allocator, record);
    }

    /// The jobs still live, each with its speed history.
    fn emitSnapshot(self: *Subscriber, allocator: Allocator, output: *std.ArrayList(u8)) bool {
        var live: std.ArrayList(JobRecord) = .empty;
        defer live.deinit(allocator);
        for (self.snapshot.items) |record| if (!record.removed) live.append(allocator, record) catch return false;
        const storage = allocator.alloc([io_job_table.rate_history_len]u64, live.items.len) catch return false;
        defer allocator.free(storage);
        const histories = allocator.alloc([]const u64, live.items.len) catch return false;
        defer allocator.free(histories);
        for (live.items, storage, histories) |record, *samples, *history| {
            history.* = samples[0..self.handle.rateHistory(record.id, samples)];
        }
        const line = wire.formatEvent(allocator, .snapshot, self.sequence, live.items, histories) catch return false;
        defer allocator.free(line);
        return append(allocator, output, line);
    }
};

fn append(allocator: Allocator, output: *std.ArrayList(u8), line: []const u8) bool {
    if (output.items.len + line.len > max_output) return false;
    output.appendSlice(allocator, line) catch return false;
    return true;
}
