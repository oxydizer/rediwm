//! Downloads in the job table: the process's own connection to the transfer
//! helper (`rediwm-transfers`), mirroring each torrent as a `download` job,
//! so windows and the shell's Transfers panel see downloads as they see
//! copies. A torrent is a folder that has not materialized yet; its job is
//! the materializing.
//!
//! Runs on the UI thread, in the main loop (`main.zig`), with or without
//! windows: while the helper downloads or seeds, Files stays up headless so
//! the panel keeps seeing it. It never starts the helper (a window does when
//! it adds a torrent); it connects when the helper is already up at start
//! and whenever a window has connected since.
//!
//! States: fetching the file list is `planning`; waiting for files to be
//! chosen is `queued` with `choose_files`; a finished download that shares
//! is `seeding`; a finished, stopped one has completed and retires. An
//! error is `failed`, kept live until the download is removed. Pause,
//! resume and cancel (remove, keeping what was downloaded) come back
//! through the Service (`takeTorrentControl`).
const std = @import("std");
const io_service = @import("io_service.zig");
const torrents = @import("torrents.zig");
const JobRecord = io_service.JobRecord;
const JobId = io_service.JobId;

const max_entries = 64;

const Entry = struct {
    used: bool = false,
    id_buf: [64]u8 = undefined,
    id_len: u8 = 0,
    job: JobId = 0,
    /// The job retired; the helper may still list the download (stopped),
    /// which does not bring it back.
    retired: bool = false,
    /// Seen in the latest snapshot.
    seen: bool = false,

    fn id(self: *const Entry) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

pub const Bridge = struct {
    service: *io_service.Service,
    client: torrents.Client = .{},
    entries: [max_entries]Entry = @splat(.{}),
    next_job: JobId = io_service.torrent_job_base,
    last_sample_ms: i64 = 0,
    /// Set once the first snapshot after connecting is in: downloads already
    /// stopped then are history, not new jobs.
    synced: bool = false,

    pub fn deinit(self: *Bridge) void {
        self.retireAll();
        self.client.deinit();
    }

    pub fn connected(self: *const Bridge) bool {
        return self.client.fd >= 0;
    }

    /// The descriptor to poll, or -1.
    pub fn fd(self: *const Bridge) c_int {
        return self.client.fd;
    }

    /// Connects to a running helper and asks for its list.
    pub fn connect(self: *Bridge, runtime: []const u8) void {
        if (self.connected()) return;
        if (!self.client.connect(runtime)) return;
        if (self.client.snapshot) |*s| s.deinit();
        self.client.snapshot = null;
        self.synced = false;
        _ = self.client.send(.{ .op = "list" });
    }

    /// Whether the helper has work this process should stay up for.
    pub fn active(self: *const Bridge) bool {
        if (!self.connected()) return false;
        for (self.client.items()) |t| {
            if (t.@"error".len > 0) continue;
            if (!t.paused or t.pending) return true;
        }
        return false;
    }

    /// Reads the helper, mirrors its snapshot and sends queued controls.
    pub fn step(self: *Bridge, now_ms: i64) void {
        if (self.connected()) {
            const before = self.client.generation;
            self.client.drain();
            if (!self.connected()) return self.retireAll();
            if (self.client.generation != before) self.mirror(now_ms);
        }
        while (self.service.takeTorrentControl()) |queued| self.control(queued);
    }

    fn control(self: *Bridge, c: io_service.TorrentControl) void {
        const entry = self.byJob(c.job_id) orelse return;
        const op = switch (c.kind) {
            .pause_job => "pause",
            .resume_job => "resume",
            .cancel_job => "remove",
            else => return,
        };
        _ = self.client.send(.{ .op = op, .id = entry.id() });
    }

    /// The download job `job` mirrors, by its transfer id, while it is live.
    pub fn transferOf(self: *const Bridge, job: JobId) ?[]const u8 {
        for (&self.entries) |*e| if (e.used and !e.retired and e.job == job) return e.id();
        return null;
    }

    fn byJob(self: *Bridge, job: JobId) ?*Entry {
        for (&self.entries) |*e| if (e.used and e.job == job) return e;
        return null;
    }

    fn byId(self: *Bridge, id: []const u8) ?*Entry {
        for (&self.entries) |*e| if (e.used and std.mem.eql(u8, e.id(), id)) return e;
        return null;
    }

    /// Mirrors the client's latest snapshot into the job table.
    pub fn mirror(self: *Bridge, now_ms: i64) void {
        const sample = now_ms - self.last_sample_ms >= 1000;
        if (sample) self.last_sample_ms = now_ms;
        for (&self.entries) |*e| e.seen = false;
        for (self.client.items()) |t| {
            if (t.id.len == 0 or t.id.len > 64) continue;
            const stopped = t.finished and t.paused and t.@"error".len == 0;
            var entry = self.byId(t.id);
            if (entry == null) {
                // Stopped before this process saw it: history, not a job.
                if (stopped and !self.synced) {
                    if (self.add(t.id)) |e| {
                        e.retired = true;
                        e.seen = true;
                    }
                    continue;
                }
                entry = self.add(t.id) orelse continue;
                entry.?.job = self.next_job;
                self.next_job += 1;
                self.service.createJobRecord(record(entry.?.job, t), false) catch {
                    entry.?.used = false;
                    continue;
                };
            }
            const e = entry.?;
            e.seen = true;
            if (e.retired) {
                // Resumed after it stopped: a new job from here on.
                if (stopped) continue;
                e.retired = false;
                e.job = self.next_job;
                self.next_job += 1;
                self.service.createJobRecord(record(e.job, t), false) catch {
                    e.retired = true;
                    continue;
                };
            }
            const r = record(e.job, t);
            self.service.updateJobRecord(r) catch {};
            if (sample and !r.state.isTerminal()) self.service.appendRateSample(e.job, r.rate_bytes_per_second);
            if (stopped) {
                self.service.retireJobRecord(e.job) catch {};
                e.retired = true;
            }
        }
        // Removed from the helper: cancelled, and gone.
        for (&self.entries) |*e| {
            if (!e.used or e.seen) continue;
            if (!e.retired) self.finish(e.job, .cancelled);
            e.used = false;
        }
        self.synced = true;
    }

    fn add(self: *Bridge, id: []const u8) ?*Entry {
        for (&self.entries) |*e| if (!e.used) {
            e.* = .{ .used = true, .id_len = @intCast(id.len) };
            @memcpy(e.id_buf[0..id.len], id);
            return e;
        };
        return null;
    }

    /// Ends a live job with `state`, then retires it.
    fn finish(self: *Bridge, job: JobId, outcome: io_service.JobState) void {
        if (self.service.getJobRecord(job)) |current| {
            var final = current;
            final.state = outcome;
            final.rate_bytes_per_second = 0;
            final.finished_at_ms = @import("io_coordinator.zig").wallClockMs();
            self.service.updateJobRecord(final) catch {};
        }
        self.service.retireJobRecord(job) catch {};
    }

    /// The helper went away: its downloads have no outcome here.
    fn retireAll(self: *Bridge) void {
        for (&self.entries) |*e| {
            if (e.used and !e.retired) self.finish(e.job, .cancelled);
            e.* = .{};
        }
    }
};

/// What a download shows as a job.
pub fn record(job: JobId, t: torrents.Transfer) JobRecord {
    var r: JobRecord = .{ .id = job, .kind = .download, .source_count = 1 };
    r.setLabel(t.name);
    r.setDestination(t.download_directory);
    r.state = state(t);
    r.choose_files = t.pending and t.metadata and t.@"error".len == 0;
    r.completed_bytes = @intCast(@max(0, t.done));
    r.total_bytes = @intCast(@max(0, t.total));
    const down: u64 = @intCast(@max(0, t.download_rate));
    const up: u64 = @intCast(@max(0, t.upload_rate));
    // A seeding download's speed is what it shares.
    r.rate_bytes_per_second = if (r.state == .seeding) up else if (r.state == .running) down else 0;
    r.upload_rate_bytes_per_second = up;
    r.uploaded_bytes = @intCast(@max(0, t.uploaded));
    r.ratio_limit = @intCast(std.math.clamp(t.ratio, 0, 255));
    r.peers = @intCast(@max(0, t.peers));
    return r;
}

fn state(t: torrents.Transfer) io_service.JobState {
    if (t.@"error".len > 0) return .failed;
    if (t.pending) return if (t.metadata) .queued else .planning;
    if (t.finished) return if (t.paused) .completed else .seeding;
    if (t.paused) return .paused;
    return .running;
}

test {
    _ = @import("io_torrent_bridge_tests.zig");
}
