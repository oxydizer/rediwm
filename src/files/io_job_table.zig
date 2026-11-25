//! The Files I/O job table: the only service-to-consumer channel for job
//! state (docs/plans/files-io-threading-and-ownership.md §6).
//!
//! Plain data, no threads, no Manager knowledge. The Service owns one table
//! and guards it with its mutex. The coordinator writes records; consumers
//! (windows, and later external subscribers) read them by revision.
//!
//! * Live records: every job from admission until it retires. Retirement
//!   depends only on the job, so a consumer never pins a live slot.
//! * Outcome slots: the final record of each job a window submitted, reserved
//!   at admission, so that window cannot lose it however late it reads.
//! * Tombstone ring: final records of retired jobs for every other consumer.
//!   FIFO; overwriting the oldest raises the resync floor.
const std = @import("std");

pub const max_live_jobs = 64;
pub const tombstone_capacity = 64;
pub const outcome_slots_per_window = 16;
pub const label_capacity = 96;
/// Speed samples kept per live job: one per second, two minutes.
pub const rate_history_len = 120;

/// Mirrors the Manager's job states by name; the coordinator maps them.
pub const State = enum(u8) {
    planning,
    queued,
    running,
    finalizing,
    paused,
    waiting,
    completed,
    completed_with_errors,
    failed,
    cancelled,

    pub fn isTerminal(self: State) bool {
        return switch (self) {
            .completed, .completed_with_errors, .failed, .cancelled => true,
            else => false,
        };
    }
};

pub const Kind = enum(u8) { copy, move, extract, delete, trash, empty_trash, other };

/// A copied value: no pointers, no slices, so a copy is always valid.
pub const Record = struct {
    id: u64 = 0,
    origin_window_id: u64 = 0,
    /// Chosen by the submitting window and echoed back.
    submit_tag: u64 = 0,
    kind: Kind = .other,
    state: State = .planning,
    cancel_requested: bool = false,
    /// Set when the job has retired; the record is final.
    removed: bool = false,
    error_code: u8 = 0,
    borrow_count: u8 = 0,
    /// How many sources the submit named; with the label, enough for
    /// "photo.jpg and 3 more".
    source_count: u32 = 0,
    label_len: u8 = 0,
    label_buf: [label_capacity]u8 = @splat(0),
    completed_bytes: u64 = 0,
    total_bytes: u64 = 0,
    rate_bytes_per_second: u64 = 0,
    completed_items: u64 = 0,
    total_items: u64 = 0,
    started_at_ms: i64 = 0,
    finished_at_ms: i64 = 0,
    /// 0 when no conflict of this job is at the head of the queue.
    pending_conflict: u64 = 0,
    /// 0 when the job offers no resource (finished extraction staging).
    offered_resource: u64 = 0,
    /// Service-wide sequence at the record's last change.
    revision: u64 = 0,

    pub fn label(self: *const Record) []const u8 {
        return self.label_buf[0..self.label_len];
    }

    /// Truncates at a UTF-8 boundary to fit the fixed buffer.
    pub fn setLabel(self: *Record, text: []const u8) void {
        var len = @min(text.len, label_capacity);
        while (len > 0 and len < text.len and (text[len] & 0xC0) == 0x80) len -= 1;
        @memcpy(self.label_buf[0..len], text[0..len]);
        self.label_len = @intCast(len);
    }
};

pub const Error = error{
    TooManyJobs,
    WindowOutcomesFull,
    UnknownJob,
    DuplicateJob,
    NoReservation,
};

const Consumer = struct {
    active: bool = false,
    /// The window id, or an external subscriber id. 0 when free.
    id: u64 = 0,
    /// Windows receive their own outcomes; external consumers do not.
    has_outcomes: bool = false,
    cursor: u64 = 0,
    in_resync: bool = false,
    floor_at_sweep_start: u64 = 0,
    /// Outcome slots reserved by submits of this window not yet retired.
    reserved_outcomes: usize = 0,
    outcomes: [outcome_slots_per_window]Record = undefined,
    outcome_count: usize = 0,

    fn freeOutcomeSlots(self: *const Consumer) usize {
        return outcome_slots_per_window - self.reserved_outcomes - self.outcome_count;
    }
};

pub const FetchResult = struct {
    count: usize,
    /// True when the consumer must treat this sweep as a full resync: mark
    /// every job it knows stale *before* applying this result's records, and
    /// drop those not reported by the time `more` is false.
    resync: bool,
    more: bool,
};

pub fn Table(comptime max_consumers: usize) type {
    return struct {
        const Self = @This();

        live: [max_live_jobs]Record = undefined,
        live_used: [max_live_jobs]bool = @splat(false),
        /// Whether the live job holds an outcome reservation of its origin.
        live_outcome: [max_live_jobs]bool = @splat(false),
        live_count: usize = 0,
        reserved_live: usize = 0,
        rate_history: [max_live_jobs][rate_history_len]u64 = undefined,
        rate_history_len: [max_live_jobs]usize = @splat(0),

        tombstones: [tombstone_capacity]Record = undefined,
        tombstone_head: usize = 0,
        tombstone_count: usize = 0,
        /// Highest revision among overwritten tombstones. A consumer whose
        /// cursor is below it may have missed a retirement.
        resync_floor: u64 = 0,

        consumers: [max_consumers]Consumer = @splat(.{}),
        sequence: u64 = 0,

        fn nextRevision(self: *Self) u64 {
            self.sequence += 1;
            return self.sequence;
        }

        // ---- consumers ----

        pub fn attach(self: *Self, index: usize, id: u64, has_outcomes: bool) void {
            std.debug.assert(!self.consumers[index].active);
            self.consumers[index] = .{ .active = true, .id = id, .has_outcomes = has_outcomes };
        }

        /// Drops the consumer's view state and outcomes. Never touches a job.
        pub fn detach(self: *Self, index: usize) void {
            self.consumers[index] = .{};
        }

        pub fn isAttached(self: *const Self, index: usize, id: u64) bool {
            const consumer = &self.consumers[index];
            return consumer.active and consumer.id == id;
        }

        // ---- admission ----

        /// Reserves a live slot and, for a window, an outcome slot. Called at
        /// `submit_job` admission so an accepted submit always has a record.
        pub fn reserveSubmit(self: *Self, index: usize) Error!void {
            const consumer = &self.consumers[index];
            std.debug.assert(consumer.active);
            if (self.live_count + self.reserved_live >= max_live_jobs) return error.TooManyJobs;
            if (consumer.has_outcomes) {
                if (consumer.freeOutcomeSlots() == 0) return error.WindowOutcomesFull;
                consumer.reserved_outcomes += 1;
            }
            self.reserved_live += 1;
        }

        /// Undoes a reservation whose command never entered a queue.
        pub fn cancelReservation(self: *Self, index: usize) void {
            const consumer = &self.consumers[index];
            if (consumer.has_outcomes) consumer.reserved_outcomes -= 1;
            self.reserved_live -= 1;
        }

        // ---- writer (coordinator) ----

        /// Creates the record of a job. `from_reservation` consumes one live
        /// reservation made at admission; otherwise a free slot beyond the
        /// reservations is required.
        pub fn create(self: *Self, record: Record, from_reservation: bool) Error!void {
            if (self.findLive(record.id) != null) return error.DuplicateJob;
            if (from_reservation) {
                if (self.reserved_live == 0) return error.NoReservation;
            } else if (self.live_count + self.reserved_live >= max_live_jobs) {
                return error.TooManyJobs;
            }
            const slot = for (self.live_used, 0..) |used, i| {
                if (!used) break i;
            } else unreachable; // live_count + reserved_live bounds it
            if (from_reservation) self.reserved_live -= 1;
            self.live[slot] = record;
            self.live[slot].removed = false;
            self.live[slot].revision = self.nextRevision();
            self.live_used[slot] = true;
            self.live_outcome[slot] = from_reservation;
            self.live_count += 1;
            self.rate_history_len[slot] = 0;
        }

        /// Replaces a live record's fields, keeping id and origin.
        pub fn update(self: *Self, record: Record) Error!void {
            const slot = self.findLive(record.id) orelse return error.UnknownJob;
            const kept = self.live[slot];
            self.live[slot] = record;
            self.live[slot].origin_window_id = kept.origin_window_id;
            self.live[slot].submit_tag = kept.submit_tag;
            self.live[slot].removed = false;
            self.live[slot].revision = self.nextRevision();
        }

        pub fn get(self: *const Self, job_id: u64) ?Record {
            const slot = self.findLive(job_id) orelse return null;
            return self.live[slot];
        }

        pub fn appendRateSample(self: *Self, job_id: u64, bytes_per_second: u64) void {
            const slot = self.findLive(job_id) orelse return;
            const history = &self.rate_history[slot];
            const len = &self.rate_history_len[slot];
            if (len.* == rate_history_len) {
                std.mem.copyForwards(u64, history[0 .. rate_history_len - 1], history[1..]);
                len.* -= 1;
            }
            history[len.*] = bytes_per_second;
            len.* += 1;
        }

        /// Copies the job's speed history, oldest first.
        pub fn copyRateHistory(self: *const Self, job_id: u64, out: []u64) usize {
            const slot = self.findLive(job_id) orelse return 0;
            const len = @min(out.len, self.rate_history_len[slot]);
            const start = self.rate_history_len[slot] - len;
            @memcpy(out[0..len], self.rate_history[slot][start..self.rate_history_len[slot]]);
            return len;
        }

        /// Retires a job: its final record goes to the origin window's
        /// outcome slot (if that window is still attached) and to the
        /// tombstone ring, and its live slot is free at once.
        pub fn retire(self: *Self, job_id: u64) Error!void {
            const slot = self.findLive(job_id) orelse return error.UnknownJob;
            var final = self.live[slot];
            final.removed = true;
            final.revision = self.nextRevision();

            if (self.live_outcome[slot]) for (&self.consumers) |*consumer| {
                if (!consumer.active or !consumer.has_outcomes) continue;
                if (consumer.id != final.origin_window_id) continue;
                if (consumer.reserved_outcomes == 0) break;
                consumer.reserved_outcomes -= 1;
                consumer.outcomes[consumer.outcome_count] = final;
                consumer.outcome_count += 1;
                break;
            };

            if (self.tombstone_count == tombstone_capacity) {
                const oldest = &self.tombstones[self.tombstone_head];
                self.resync_floor = @max(self.resync_floor, oldest.revision);
                self.tombstone_head = (self.tombstone_head + 1) % tombstone_capacity;
                self.tombstone_count -= 1;
            }
            const tail = (self.tombstone_head + self.tombstone_count) % tombstone_capacity;
            self.tombstones[tail] = final;
            self.tombstone_count += 1;

            self.live_used[slot] = false;
            self.live_count -= 1;
        }

        fn findLive(self: *const Self, job_id: u64) ?usize {
            for (self.live_used, 0..) |used, i| {
                if (used and self.live[i].id == job_id) return i;
            }
            return null;
        }

        // ---- reader (consumers) ----

        /// Copies out, oldest first: the consumer's own unread outcomes, then
        /// live records and tombstones changed since its cursor. The cursor
        /// lives in the consumer slot. Bounded by `out.len`; call again while
        /// `more` is true.
        pub fn fetch(self: *Self, index: usize, out: []Record) FetchResult {
            const consumer = &self.consumers[index];
            std.debug.assert(consumer.active);
            var count: usize = 0;

            // Own outcomes first. Delivering one frees its slot.
            const outcome_take = @min(out.len, consumer.outcome_count);
            @memcpy(out[0..outcome_take], consumer.outcomes[0..outcome_take]);
            std.mem.copyForwards(
                Record,
                consumer.outcomes[0 .. consumer.outcome_count - outcome_take],
                consumer.outcomes[outcome_take..consumer.outcome_count],
            );
            consumer.outcome_count -= outcome_take;
            count = outcome_take;

            var resync = false;
            if (!consumer.in_resync and consumer.cursor < self.resync_floor) {
                consumer.in_resync = true;
                consumer.floor_at_sweep_start = self.resync_floor;
                consumer.cursor = 0;
                resync = true;
            }

            // Then changed records, in revision order.
            var last = consumer.cursor;
            while (count < out.len) {
                const next = self.nextAfter(last) orelse break;
                out[count] = next;
                count += 1;
                last = next.revision;
            }
            const more_records = self.nextAfter(last) != null;
            consumer.cursor = if (more_records) last else self.sequence;

            const more = more_records or consumer.outcome_count > 0;
            if (consumer.in_resync and !more_records) {
                consumer.in_resync = false;
                // Retirements overwritten during a long sweep may have been
                // missed: sweep again. Converges because sweeps are bounded.
                if (self.resync_floor > consumer.floor_at_sweep_start) {
                    consumer.cursor = 0;
                    consumer.in_resync = true;
                    consumer.floor_at_sweep_start = self.resync_floor;
                    return .{ .count = count, .resync = true, .more = true };
                }
            }
            return .{ .count = count, .resync = resync, .more = more };
        }

        /// The record with the smallest revision greater than `revision`,
        /// across live records and tombstones.
        fn nextAfter(self: *const Self, revision: u64) ?Record {
            var best: ?Record = null;
            for (self.live_used, 0..) |used, i| {
                if (!used) continue;
                const record = self.live[i];
                if (record.revision > revision and (best == null or record.revision < best.?.revision))
                    best = record;
            }
            for (0..self.tombstone_count) |offset| {
                const record = self.tombstones[(self.tombstone_head + offset) % tombstone_capacity];
                if (record.revision > revision and (best == null or record.revision < best.?.revision))
                    best = record;
            }
            return best;
        }
    };
}

test {
    _ = @import("io_job_table_tests.zig");
}
