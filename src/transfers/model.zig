//! What the Transfers panel knows about Files jobs, from the Files endpoint's
//! subscription lines (`files/io_endpoint_wire.zig`). Plain data: no
//! sockets, no compositor; `client.zig` feeds it lines and ticks.
//!
//! * Live jobs: every job Files reports until it retires.
//! * Done: jobs that retired completed or failed, newest first, kept by the
//!   panel until "Clear Done" (a cancelled job was the user's choice and is
//!   not kept).
//! * Speed history: one sample a second for the last minute, per job and in
//!   total. A snapshot seeds it from Files' own history; afterwards `tick`
//!   appends the current rates while any job is live.
const std = @import("std");

pub const history_len = 60;
pub const max_live = 64;
pub const max_done = 32;

/// `download` is a torrent: Files mirrors the transfer helper's downloads.
pub const Kind = enum { copy, move, extract, delete, trash, empty_trash, other, download };

pub const State = enum {
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
    /// A finished download sharing what it has.
    seeding,

    pub fn isTerminal(self: State) bool {
        return switch (self) {
            .completed, .completed_with_errors, .failed, .cancelled => true,
            else => false,
        };
    }
};

/// A string in a fixed buffer, cut at a UTF-8 boundary.
pub fn Text(comptime capacity: usize) type {
    return struct {
        buf: [capacity]u8 = undefined,
        len: u16 = 0,

        const Self = @This();

        pub fn set(self: *Self, value: []const u8) void {
            var n = @min(value.len, capacity);
            while (n > 0 and n < value.len and (value[n] & 0xC0) == 0x80) n -= 1;
            @memcpy(self.buf[0..n], value[0..n]);
            self.len = @intCast(n);
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

/// The last `history_len` one-second samples; the newest is last.
pub const History = struct {
    samples: [history_len]u64 = @splat(0),
    count: usize = 0,

    pub fn push(self: *History, value: u64) void {
        std.mem.copyForwards(u64, self.samples[0 .. history_len - 1], self.samples[1..]);
        self.samples[history_len - 1] = value;
        self.count = @min(self.count + 1, history_len);
    }

    /// Recorded samples, oldest first.
    pub fn values(self: *const History) []const u64 {
        return self.samples[history_len - self.count ..];
    }

    /// Replaces the history with the newest `history_len` of `rates`.
    pub fn seed(self: *History, rates: []const u64) void {
        self.* = .{};
        const tail = rates[rates.len - @min(rates.len, history_len) ..];
        for (tail) |rate| self.push(rate);
    }

    pub fn peak(self: *const History) u64 {
        var best: u64 = 0;
        for (self.values()) |v| best = @max(best, v);
        return best;
    }

    pub fn average(self: *const History) u64 {
        const v = self.values();
        if (v.len == 0) return 0;
        var sum: u64 = 0;
        for (v) |sample| sum +|= sample;
        return sum / v.len;
    }
};

pub const Job = struct {
    id: u64 = 0,
    kind: Kind = .other,
    state: State = .queued,
    label: Text(96) = .{},
    destination: Text(256) = .{},
    waiting_for: Text(48) = .{},
    source_count: u32 = 0,
    completed_bytes: u64 = 0,
    total_bytes: u64 = 0,
    rate: u64 = 0,
    completed_items: u64 = 0,
    total_items: u64 = 0,
    started_at_ms: i64 = 0,
    finished_at_ms: i64 = 0,
    cancel_requested: bool = false,
    conflict: bool = false,
    error_code: u8 = 0,
    /// Downloads: sharing speed, all shared, the ratio at which seeding
    /// stops (0 never seeds), peers, and files still to be chosen.
    upload_rate: u64 = 0,
    uploaded_bytes: u64 = 0,
    ratio_limit: u8 = 0,
    peers: u32 = 0,
    choose_files: bool = false,
    history: History = .{},

    /// Deletions count items; everything else counts bytes. Null until
    /// planning knows the total.
    pub fn fraction(self: *const Job) ?f32 {
        if (self.state == .seeding) return 1;
        if (self.state == .completed or self.state == .completed_with_errors) return 1;
        if (countsItems(self.kind) or self.total_bytes == 0) {
            if (self.total_items == 0) return null;
            return clampFraction(self.completed_items, self.total_items);
        }
        return clampFraction(self.completed_bytes, self.total_bytes);
    }

    /// Seconds left at the recent average rate; null when unknown.
    pub fn etaSeconds(self: *const Job) ?u64 {
        if (self.state != .running or countsItems(self.kind) or self.total_bytes == 0) return null;
        const recent = recentRate(&self.history, self.rate);
        if (recent == 0) return null;
        const left = self.total_bytes -| self.completed_bytes;
        return (left + recent - 1) / recent;
    }

    /// Asks for the user: a conflict waits in Files, or a download's files
    /// are to be chosen.
    pub fn needsAttention(self: *const Job) bool {
        return self.conflict or self.choose_files;
    }

    /// Shared over size, the share ratio; null before anything was shared.
    pub fn ratio(self: *const Job) ?f32 {
        if (self.total_bytes == 0) return null;
        return @as(f32, @floatFromInt(self.uploaded_bytes)) / @as(f32, @floatFromInt(self.total_bytes));
    }
};

pub fn countsItems(kind: Kind) bool {
    return kind == .delete or kind == .trash or kind == .empty_trash;
}

fn clampFraction(done: u64, total: u64) f32 {
    return @min(1, @as(f32, @floatFromInt(done)) / @as(f32, @floatFromInt(total)));
}

/// The mean of the last five samples (and the current rate), so an ETA
/// does not jump with every reading.
fn recentRate(history: *const History, current: u64) u64 {
    const v = history.values();
    const tail = v[v.len - @min(v.len, 5) ..];
    var sum: u64 = current;
    for (tail) |s| sum +|= s;
    return sum / (tail.len + 1);
}

/// What the tray icon shows.
pub const Summary = struct {
    /// Jobs that have not finished. Seeding downloads have, and are apart.
    active: usize = 0,
    seeding: usize = 0,
    upload_rate: u64 = 0,
    paused: usize = 0,
    /// Every active job is paused.
    all_paused: bool = false,
    /// Aggregate progress of the active jobs, when any has a total.
    fraction: ?f32 = null,
    rate: u64 = 0,
    attention: bool = false,
    done: usize = 0,
    failed: usize = 0,
};

pub const Model = struct {
    live: [max_live]Job = undefined,
    live_len: usize = 0,
    done: [max_done]Job = undefined,
    done_len: usize = 0,
    total: History = .{},
    /// What seeding and downloading torrents share, apart from `total`.
    upload: History = .{},
    /// The last event's sequence, to notice a gap.
    sequence: u64 = 0,
    /// Bumped on every change the panel or the icon shows.
    revision: u64 = 0,

    pub fn liveJobs(self: *const Model) []const Job {
        return self.live[0..self.live_len];
    }

    pub fn doneJobs(self: *const Model) []const Job {
        return self.done[0..self.done_len];
    }

    /// Whether the taskbar item has anything to show.
    pub fn present(self: *const Model) bool {
        return self.live_len > 0 or self.done_len > 0;
    }

    pub fn find(self: *Model, id: u64) ?*Job {
        for (self.live[0..self.live_len]) |*job| if (job.id == id) return job;
        return null;
    }

    pub fn summary(self: *const Model) Summary {
        var s: Summary = .{ .done = self.done_len };
        var done_bytes: u64 = 0;
        var total_bytes: u64 = 0;
        var fractions: f32 = 0;
        var fraction_count: usize = 0;
        for (self.live[0..self.live_len]) |*job| {
            if (job.needsAttention()) s.attention = true;
            s.upload_rate +|= job.upload_rate;
            if (job.state == .seeding) {
                s.seeding += 1;
                continue;
            }
            if (job.state.isTerminal()) continue;
            s.active += 1;
            s.rate +|= job.rate;
            if (job.state == .paused) s.paused += 1;
            if (!countsItems(job.kind) and job.total_bytes > 0) {
                done_bytes +|= @min(job.completed_bytes, job.total_bytes);
                total_bytes +|= job.total_bytes;
            } else if (job.fraction()) |f| {
                fractions += f;
                fraction_count += 1;
            }
        }
        for (self.done[0..self.done_len]) |*job| {
            if (job.state == .failed or job.state == .completed_with_errors) s.failed += 1;
        }
        s.all_paused = s.active > 0 and s.paused == s.active;
        // Bytes weigh by size; item-counted jobs count as one job's worth each.
        if (total_bytes > 0 or fraction_count > 0) {
            const byte_part: f32 = if (total_bytes > 0) clampFraction(done_bytes, total_bytes) else 0;
            const byte_jobs: f32 = if (total_bytes > 0) @floatFromInt(s.active - fraction_count) else 0;
            const weight = byte_jobs + @as(f32, @floatFromInt(fraction_count));
            if (weight > 0) s.fraction = (byte_part * byte_jobs + fractions) / weight;
        }
        return s;
    }

    /// Applies one line from the endpoint. Returns whether anything shown
    /// changed. A line that is not an event (a request's answer) is ignored.
    pub fn applyLine(self: *Model, allocator: std.mem.Allocator, line: []const u8) !bool {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(WireLine, arena.allocator(), line, .{ .ignore_unknown_fields = true }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.BadLine;
        };
        const event = parsed.event orelse return false;
        if (std.mem.eql(u8, event, "snapshot")) {
            self.applySnapshot(parsed.jobs);
        } else if (std.mem.eql(u8, event, "jobs")) {
            for (parsed.jobs) |*wire| self.applyJob(wire);
        } else return false;
        self.sequence = parsed.sequence;
        self.revision +%= 1;
        return true;
    }

    fn applySnapshot(self: *Model, jobs: []const WireJob) void {
        self.live_len = 0;
        self.total = .{};
        self.upload = .{};
        var longest: usize = 0;
        for (jobs) |*wire| {
            if (wire.removed or self.live_len == max_live) continue;
            var job: Job = .{};
            fill(&job, wire);
            if (wire.rate_history) |rates| job.history.seed(rates);
            longest = @max(longest, job.history.count);
            self.live[self.live_len] = job;
            self.live_len += 1;
        }
        // The totals are the sums of the jobs' histories, aligned at the
        // newest; a seeding job's history is what it shared.
        var sums: [history_len]u64 = @splat(0);
        var shared: [history_len]u64 = @splat(0);
        for (self.live[0..self.live_len]) |*job| {
            const v = job.history.values();
            const into = if (job.state == .seeding) &shared else &sums;
            for (v, 0..) |rate, i| into[history_len - v.len + i] +|= rate;
        }
        for (sums[history_len - longest ..], shared[history_len - longest ..]) |rate, up| {
            self.total.push(rate);
            self.upload.push(up);
        }
    }

    fn applyJob(self: *Model, wire: *const WireJob) void {
        if (self.find(wire.id)) |job| {
            if (!wire.removed) return fill(job, wire);
            var last = job.*;
            fill(&last, wire);
            const index = (@intFromPtr(job) - @intFromPtr(&self.live)) / @sizeOf(Job);
            std.mem.copyForwards(Job, self.live[index .. self.live_len - 1], self.live[index + 1 .. self.live_len]);
            self.live_len -= 1;
            self.retire(last);
            return;
        }
        if (wire.removed) {
            var last: Job = .{};
            fill(&last, wire);
            return self.retire(last);
        }
        if (self.live_len == max_live) return;
        var job: Job = .{};
        fill(&job, wire);
        self.live[self.live_len] = job;
        self.live_len += 1;
    }

    /// A retired job joins the done list, unless the user cancelled it.
    fn retire(self: *Model, job: Job) void {
        if (job.state == .cancelled or !job.state.isTerminal()) return;
        if (self.done_len == max_done) self.done_len -= 1;
        std.mem.copyBackwards(Job, self.done[1 .. self.done_len + 1], self.done[0..self.done_len]);
        self.done[0] = job;
        self.done_len += 1;
    }

    /// One second passed: record each live job's rate and the total.
    pub fn tick(self: *Model) void {
        if (self.live_len == 0) return;
        var sum: u64 = 0;
        var up: u64 = 0;
        for (self.live[0..self.live_len]) |*job| {
            const rate = if (job.state == .running or job.state == .seeding) job.rate else 0;
            job.history.push(rate);
            if (job.state == .running) sum +|= rate;
            up +|= job.upload_rate;
        }
        self.total.push(sum);
        self.upload.push(up);
        self.revision +%= 1;
    }

    /// The endpoint went away. Jobs that had finished are kept as done;
    /// anything else had no outcome and is dropped.
    pub fn disconnected(self: *Model) void {
        for (self.live[0..self.live_len]) |job| self.retire(job);
        self.live_len = 0;
        self.total = .{};
        self.upload = .{};
        self.sequence = 0;
        self.revision +%= 1;
    }

    pub fn clearDone(self: *Model) void {
        self.done_len = 0;
        self.revision +%= 1;
    }
};

fn fill(job: *Job, wire: *const WireJob) void {
    job.id = wire.id;
    job.kind = std.meta.stringToEnum(Kind, wire.kind) orelse .other;
    job.state = std.meta.stringToEnum(State, wire.state) orelse job.state;
    job.label.set(wire.label);
    job.destination.set(if (wire.destination.len <= 256) wire.destination else "");
    job.waiting_for.set(wire.waiting_for);
    job.source_count = wire.source_count;
    job.completed_bytes = wire.completed_bytes;
    job.total_bytes = wire.total_bytes;
    job.rate = wire.rate_bytes_per_second;
    job.completed_items = wire.completed_items;
    job.total_items = wire.total_items;
    job.started_at_ms = wire.started_at_ms;
    job.finished_at_ms = wire.finished_at_ms;
    job.cancel_requested = wire.cancel_requested;
    job.conflict = wire.conflict;
    job.error_code = wire.error_code;
    job.upload_rate = wire.upload_rate_bytes_per_second;
    job.uploaded_bytes = wire.uploaded_bytes;
    job.ratio_limit = wire.ratio_limit;
    job.peers = wire.peers;
    job.choose_files = wire.choose_files;
}

const WireJob = struct {
    id: u64,
    kind: []const u8 = "other",
    state: []const u8 = "queued",
    label: []const u8 = "",
    destination: []const u8 = "",
    source_count: u32 = 0,
    completed_bytes: u64 = 0,
    total_bytes: u64 = 0,
    rate_bytes_per_second: u64 = 0,
    completed_items: u64 = 0,
    total_items: u64 = 0,
    started_at_ms: i64 = 0,
    finished_at_ms: i64 = 0,
    cancel_requested: bool = false,
    conflict: bool = false,
    waiting_for: []const u8 = "",
    error_code: u8 = 0,
    removed: bool = false,
    revision: u64 = 0,
    rate_history: ?[]const u64 = null,
    upload_rate_bytes_per_second: u64 = 0,
    uploaded_bytes: u64 = 0,
    ratio_limit: u8 = 0,
    peers: u32 = 0,
    choose_files: bool = false,
};

const WireLine = struct {
    version: u32 = 0,
    event: ?[]const u8 = null,
    sequence: u64 = 0,
    jobs: []const WireJob = &.{},
};

/// `1.5 MB`, binary units like Files.
pub fn formatBytes(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "";
    var value = @as(f64, @floatFromInt(bytes)) / 1024;
    var unit: usize = 0;
    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) value /= 1024;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "";
}

/// `42s`, `3m 05s`, `1h 12m`.
pub fn formatDuration(buf: []u8, seconds: u64) []const u8 {
    if (seconds < 60) return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "";
    if (seconds < 3600) return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ seconds / 60, seconds % 60 }) catch "";
    return std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ seconds / 3600, seconds / 60 % 60 }) catch "";
}

/// Shows `$HOME/...` as `~/...`.
pub fn shortPath(buf: []u8, path: []const u8, home: []const u8) []const u8 {
    if (home.len > 1 and std.mem.startsWith(u8, path, home) and (path.len == home.len or path[home.len] == '/'))
        return std.fmt.bufPrint(buf, "~{s}", .{path[home.len..]}) catch path;
    return path;
}

test {
    _ = @import("model_tests.zig");
}
