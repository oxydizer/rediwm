//! The Service's side of external subscribers (stage S6): the endpoint's
//! shell panel clients. They read the job table like a window, by cursor
//! (`fetchChanges`), with their own wake (`externalWakeFd`), and may pause,
//! resume and cancel jobs through a small queue of their own. Every call
//! here comes from the endpoint thread, never the UI thread, so it may take
//! the Service mutex.
const std = @import("std");
const io_service = @import("io_service.zig");
const Service = io_service.Service;
const JobRecord = io_service.JobRecord;
const JobId = io_service.JobId;
const FetchResult = io_service.FetchResult;

/// Registers a subscriber that is not a window.
pub fn registerExternal(self: *Service) !ExternalHandle {
    self.lock();
    defer self.unlock();
    if (self.stopping.load(.acquire)) return error.ServiceStopping;
    for (&self.external_ids, 0..) |*slot_id, i| {
        if (slot_id.* != 0) continue;
        const id = self.next_window_id.fetchAdd(1, .monotonic);
        if (id > io_service.max_window_id) return error.WindowIdExhausted;
        slot_id.* = id;
        self.table.attach(io_service.max_windows + i, id, false);
        return .{ .service = self, .index = i, .id = id };
    }
    return error.TooManyConsumers;
}

/// Readable after any job record changed; shared by every subscriber, so the
/// endpoint drains it once and then fetches for each.
pub fn externalWakeFd(self: *const Service) std.posix.fd_t {
    return self.external_wake_fd;
}

pub fn drainExternalWake(self: *Service) u64 {
    return io_service.drainWake(self.external_wake_fd);
}

pub const Control = enum { pause, @"resume", cancel };

/// Queues pause, resume or cancel for a live job, from any endpoint client.
/// Accepted is not done: the record shows what the coordinator made of it.
pub fn sendControl(self: *Service, control: Control, job_id: JobId) error{ JobNotFound, InvalidState, QueueFull, ServiceStopping }!void {
    self.lock();
    defer self.unlock();
    if (self.stopping.load(.acquire)) return error.ServiceStopping;
    const record = self.table.get(job_id) orelse return error.JobNotFound;
    if (io_service.isTorrentJob(job_id)) {
        // A failed download is still the helper's until it is removed.
        const kind: io_service.CommandKind = switch (control) {
            .pause => .pause_job,
            .@"resume" => .resume_job,
            .cancel => .cancel_job,
        };
        if (!self.torrent_controls.push(.{ .kind = kind, .job_id = job_id })) return error.QueueFull;
        Service.signalWake(self.update_wake_fd);
        return;
    }
    if (record.state.isTerminal()) return error.InvalidState;
    const command: io_service.Command = .{
        .kind = switch (control) {
            .pause => .pause_job,
            .@"resume" => .resume_job,
            .cancel => .cancel_job,
        },
        .job_id = job_id,
    };
    if (!self.external_controls.push(command)) return error.QueueFull;
    Service.signalWake(self.command_wake_fd);
}

/// A subscriber's capability on the job table.
pub const ExternalHandle = struct {
    service: *Service,
    index: usize,
    id: u64,

    pub fn fetchChanges(self: ExternalHandle, out: []JobRecord) FetchResult {
        self.service.lock();
        defer self.service.unlock();
        return self.service.table.fetch(io_service.max_windows + self.index, out);
    }

    /// The job's speed samples, oldest first (one a second, at most
    /// `rate_history_len`). Zero for a job that is gone.
    pub fn rateHistory(self: ExternalHandle, job_id: JobId, out: []u64) usize {
        self.service.lock();
        defer self.service.unlock();
        return self.service.table.copyRateHistory(job_id, out);
    }

    pub fn close(self: *ExternalHandle) void {
        const service = self.service;
        const index = self.index;
        self.* = undefined;
        service.lock();
        defer service.unlock();
        service.table.detach(io_service.max_windows + index);
        service.external_ids[index] = 0;
    }
};
