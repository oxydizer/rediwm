const std = @import("std");
const table_mod = @import("io_job_table.zig");

const T = table_mod.Table(4);
const Record = table_mod.Record;

const window_a = 0; // consumer index
const window_b = 1;
const external = 2;

fn record(id: u64, origin: u64) Record {
    var r: Record = .{ .id = id, .origin_window_id = origin, .kind = .copy, .state = .queued };
    r.setLabel("item");
    return r;
}

fn submit(t: *T, consumer: usize, id: u64, origin: u64) !void {
    try t.reserveSubmit(consumer);
    try t.create(record(id, origin), true);
}

fn finish(t: *T, id: u64) !void {
    var r = t.get(id).?;
    r.state = .completed;
    try t.update(r);
    try t.retire(id);
}

/// Drains a consumer and returns how many records it received.
fn drain(t: *T, consumer: usize) usize {
    var out: [8]Record = undefined;
    var total: usize = 0;
    while (true) {
        const result = t.fetch(consumer, &out);
        total += result.count;
        if (!result.more) return total;
    }
}

test "records arrive in revision order and an idle fetch is empty" {
    var t: T = .{};
    t.attach(window_a, 10, true);
    try submit(&t, window_a, 1, 10);
    try submit(&t, window_a, 2, 10);
    var r = t.get(1).?;
    r.completed_bytes = 5;
    try t.update(r);

    var out: [8]Record = undefined;
    const result = t.fetch(window_a, &out);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expect(!result.more and !result.resync);
    try std.testing.expectEqual(@as(u64, 2), out[0].id);
    try std.testing.expectEqual(@as(u64, 1), out[1].id);
    try std.testing.expectEqual(@as(u64, 5), out[1].completed_bytes);
    try std.testing.expectEqual(@as(usize, 0), t.fetch(window_a, &out).count);
}

test "a small buffer bounds each fetch and resumes where it stopped" {
    var t: T = .{};
    t.attach(window_a, 10, true);
    for (1..6) |id| try submit(&t, window_a, id, 10);

    var out: [2]Record = undefined;
    var seen: usize = 0;
    var last_id: u64 = 0;
    while (true) {
        const result = t.fetch(window_a, &out);
        for (out[0..result.count]) |r| {
            try std.testing.expect(r.id > last_id);
            last_id = r.id;
        }
        seen += result.count;
        if (!result.more) break;
    }
    try std.testing.expectEqual(@as(usize, 5), seen);
}

test "a late-attached consumer sees every live job" {
    var t: T = .{};
    t.attach(window_a, 10, true);
    for (1..4) |id| try submit(&t, window_a, id, 10);
    try finish(&t, 1);

    t.attach(window_b, 11, true);
    var out: [8]Record = undefined;
    const result = t.fetch(window_b, &out);
    var live: usize = 0;
    for (out[0..result.count]) |r| {
        if (!r.removed) live += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), live);
}

test "a window that never reads keeps its own outcomes and blocks only its own submits" {
    var t: T = .{};
    t.attach(window_a, 10, true);
    t.attach(window_b, 11, true);

    // Window A submits until its outcome slots are reserved, and every job
    // finishes and retires while A never reads.
    for (1..table_mod.outcome_slots_per_window + 1) |id| {
        try submit(&t, window_a, id, 10);
        try finish(&t, id);
    }
    try std.testing.expectError(error.WindowOutcomesFull, t.reserveSubmit(window_a));

    // Retirement was not delayed and window B is unaffected, even after far
    // more retirements than the tombstone ring holds.
    try std.testing.expectEqual(@as(usize, 0), t.live_count);
    for (100..100 + 3 * table_mod.tombstone_capacity) |id| {
        try submit(&t, window_b, id, 11);
        try finish(&t, id);
        _ = drain(&t, window_b);
    }

    // When A finally reads, it gets every outcome of its own jobs.
    var out: [table_mod.outcome_slots_per_window]Record = undefined;
    const result = t.fetch(window_a, &out);
    try std.testing.expectEqual(table_mod.outcome_slots_per_window, result.count);
    for (out[0..result.count], 1..) |r, id| {
        try std.testing.expectEqual(@as(u64, id), r.id);
        try std.testing.expect(r.removed and r.state == .completed);
    }
    // Its own slots are free again.
    try t.reserveSubmit(window_a);
    t.cancelReservation(window_a);
}

test "a lagging foreign consumer resyncs to exactly the live set" {
    var t: T = .{};
    t.attach(window_a, 10, true);
    t.attach(external, 99, false);

    try submit(&t, window_a, 1, 10);
    _ = drain(&t, external);
    try submit(&t, window_a, 2, 10);
    try submit(&t, window_a, 3, 10);
    // More retirements than the ring holds, while the external reader sleeps.
    for (10..10 + table_mod.tombstone_capacity + 5) |id| {
        try submit(&t, window_a, id, 10);
        try finish(&t, id);
        _ = drain(&t, window_a);
    }
    try finish(&t, 1);

    var out: [4]Record = undefined;
    var resynced = false;
    var live = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer live.deinit();
    while (true) {
        const result = t.fetch(external, &out);
        if (result.resync) {
            resynced = true;
            live.clearRetainingCapacity();
        }
        for (out[0..result.count]) |r| {
            if (r.removed) _ = live.remove(r.id) else try live.put(r.id, {});
        }
        if (!result.more) break;
    }
    try std.testing.expect(resynced);
    try std.testing.expectEqual(@as(u32, 2), live.count());
    try std.testing.expect(live.contains(2) and live.contains(3));
}

test "a full live table refuses submits until a job retires" {
    var t: T = .{};
    t.attach(external, 99, false);
    for (1..table_mod.max_live_jobs + 1) |id| try submit(&t, external, id, 0);
    try std.testing.expectError(error.TooManyJobs, t.reserveSubmit(external));
    try finish(&t, 1);
    try t.reserveSubmit(external);
}

test "outcomes go only to the reserving origin window" {
    var t: T = .{};
    t.attach(window_a, 10, true);
    // A job created without a reservation (not a window submit) must not
    // consume window A's slots.
    try t.create(record(1, 10), false);
    try finish(&t, 1);
    try std.testing.expectEqual(@as(usize, 0), t.consumers[window_a].outcome_count);
}

test "rate history keeps the newest samples, oldest first" {
    var t: T = .{};
    t.attach(window_a, 10, true);
    try submit(&t, window_a, 1, 10);
    for (0..table_mod.rate_history_len + 10) |i| t.appendRateSample(1, i);
    var out: [table_mod.rate_history_len]u64 = undefined;
    const n = t.copyRateHistory(1, &out);
    try std.testing.expectEqual(table_mod.rate_history_len, n);
    try std.testing.expectEqual(@as(u64, 10), out[0]);
    try std.testing.expectEqual(@as(u64, table_mod.rate_history_len + 9), out[n - 1]);
}

test "labels are truncated on a UTF-8 boundary" {
    var r: Record = .{};
    var text: [table_mod.label_capacity + 1]u8 = @splat('a');
    // "é" (two bytes) straddles the end of the buffer.
    text[table_mod.label_capacity - 1] = 0xC3;
    text[table_mod.label_capacity] = 0xA9;
    r.setLabel(&text);
    try std.testing.expectEqual(@as(usize, table_mod.label_capacity - 1), r.label().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r.label()));
}
