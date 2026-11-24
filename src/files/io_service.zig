//! Process-owned Files I/O service boundary.
//!
//! This module contains only bounded message delivery and window identity.
//! It deliberately exposes no Manager, Runtime, executor or ledger pointer.
const std = @import("std");
const c = @import("c.zig").api;
const wake = @import("platform").wake;

pub const WindowId = u64;
pub const JobId = u64;
pub const ResourceId = u64;

pub const max_windows = 16;
pub const command_capacity_per_window = 8;
pub const control_capacity_per_window = 2;
pub const aggregate_command_capacity = 64;
pub const update_capacity_per_window = 32;

pub const CommandKind = enum {
    submit_job,
    start_discovery,
    prioritize_discovery,
    pause_job,
    resume_job,
    cancel_job,
    resolve_conflict,
    retire_job,
    release_resource,
};

pub const CommandClass = enum {
    normal,
    control,
};

pub const Command = struct {
    kind: CommandKind,
    job_id: JobId = 0,
    resource_id: ResourceId = 0,

    pub fn class(self: Command) CommandClass {
        return switch (self.kind) {
            .submit_job, .start_discovery, .prioritize_discovery => .normal,
            .pause_job, .resume_job, .cancel_job, .resolve_conflict,
            .retire_job, .release_resource => .control,
        };
    }
};

pub const RoutedCommand = struct {
    window_id: WindowId,
    command: Command,
};

pub const UpdateKind = enum {
    progress,
    job_state,
    conflict,
    archive_ready,
    command_rejected,
    resync_required,
};

/// A copied value. Path strings and other owned payloads are deliberately
/// excluded; later command/update variants must define their ownership.
pub const Update = struct {
    sequence: u64 = 0,
    job_id: JobId = 0,
    kind: UpdateKind,
    completed_bytes: u64 = 0,
    total_bytes: u64 = 0,
    rate_bytes_per_second: u64 = 0,
    state_code: u8 = 0,
    conflict_id: u64 = 0,
    resource_id: ResourceId = 0,
};

fn Ring(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        head: usize = 0,
        count: usize = 0,

        fn push(self: *@This(), value: T) bool {
            if (self.count == capacity) return false;
            self.items[(self.head + self.count) % capacity] = value;
            self.count += 1;
            return true;
        }

        fn pop(self: *@This()) ?T {
            if (self.count == 0) return null;
            const value = self.items[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            return value;
        }

        fn clear(self: *@This()) void {
            self.head = 0;
            self.count = 0;
        }

        fn last(self: *@This()) ?*T {
            if (self.count == 0) return null;
            return &self.items[(self.head + self.count - 1) % capacity];
        }
    };
}

const WindowSlot = struct {
    id: WindowId = 0,
    active: bool = false,
    normal_commands: Ring(Command, command_capacity_per_window) = .{},
    control_commands: Ring(Command, control_capacity_per_window) = .{},
    updates: Ring(Update, update_capacity_per_window) = .{},
    needs_resync: bool = false,
    resync_sequence: u64 = 0,

    fn reset(self: *WindowSlot) void {
        self.* = .{};
    }
};

/// The process owner creates one Service at a stable address. Window handles
/// are non-owning capabilities; they cannot access service internals.
pub const Service = struct {
    mutex: c.pthread_mutex_t = undefined,
    command_wake_fd: std.posix.fd_t = -1,
    update_wake_fd: std.posix.fd_t = -1,
    windows: [max_windows]WindowSlot = std.mem.zeroes([max_windows]WindowSlot),
    next_window_id: WindowId = 1,
    next_event_sequence: u64 = 1,
    next_drain_slot: usize = 0,
    pending_normal_commands: usize = 0,
    stopping: bool = false,

    /// Initialize in place: an initialized pthread mutex must not be copied.
    pub fn init(self: *Service) !void {
        self.* = .{};
        if (c.pthread_mutex_init(&self.mutex, null) != 0)
            return error.MutexInitFailed;
        errdefer std.debug.assert(c.pthread_mutex_destroy(&self.mutex) == 0);

        self.command_wake_fd = wake.create() orelse return error.WakeDescriptorCreateFailed;
        errdefer _ = std.posix.system.close(self.command_wake_fd);

        self.update_wake_fd = wake.create() orelse return error.WakeDescriptorCreateFailed;
    }

    pub fn deinit(self: *Service) void {
        self.lock();
        for (self.windows) |slot| std.debug.assert(!slot.active);
        std.debug.assert(self.pending_normal_commands == 0);
        self.unlock();
        std.debug.assert(c.pthread_mutex_destroy(&self.mutex) == 0);
        _ = std.posix.system.close(self.command_wake_fd);
        _ = std.posix.system.close(self.update_wake_fd);
    }

    /// Shared process-wide wake descriptor for newly admitted commands.
    pub fn commandWakeFd(self: *const Service) std.posix.fd_t {
        return self.command_wake_fd;
    }

    /// Shared process-wide wake descriptor for published window updates.
    pub fn updateWakeFd(self: *const Service) std.posix.fd_t {
        return self.update_wake_fd;
    }

    /// Drain the command wake counter after polling commandWakeFd().
    pub fn drainCommandWake(self: *Service) u64 {
        return drainWake(self.command_wake_fd);
    }

    /// Drain the update wake counter after polling updateWakeFd().
    pub fn drainUpdateWake(self: *Service) u64 {
        return drainWake(self.update_wake_fd);
    }

    /// IDs are monotonic and never reused, even when a slot is recycled.
    pub fn registerWindow(self: *Service) !Handle {
        if (!self.tryLock()) return error.ServiceBusy;
        defer self.unlock();

        if (self.stopping) return error.ServiceStopping;
        if (self.next_window_id == std.math.maxInt(WindowId))
            return error.WindowIdExhausted;

        for (&self.windows) |*slot| {
            if (slot.active) continue;
            const id = self.next_window_id;
            self.next_window_id += 1;
            slot.* = .{ .id = id, .active = true };
            return .{ .service = self, .window_id = id };
        }
        return error.TooManyWindows;
    }

    /// Stops new admission. Existing handles may still drain queued updates
    /// and unregister; the process owner controls final teardown.
    pub fn beginShutdown(self: *Service) void {
        self.lock();
        defer self.unlock();
        self.stopping = true;
        signalWake(self.command_wake_fd);
    }

    pub fn isStopping(self: *Service) bool {
        self.lock();
        defer self.unlock();
        return self.stopping;
    }

    /// Called only by the service coordinator. Commands are selected
    /// round-robin across windows; control commands precede normal commands
    /// within each window.
    pub fn tryReceiveCommand(self: *Service) ?RoutedCommand {
        self.lock();
        defer self.unlock();

        for (0..max_windows) |_| {
            const index = self.next_drain_slot;
            self.next_drain_slot = (self.next_drain_slot + 1) % max_windows;
            const slot = &self.windows[index];
            if (!slot.active) continue;

            if (slot.control_commands.pop()) |command| {
                return .{ .window_id = slot.id, .command = command };
            }
            if (slot.normal_commands.pop()) |command| {
                self.pending_normal_commands -= 1;
                return .{ .window_id = slot.id, .command = command };
            }
        }
        return null;
    }

    /// Publishes one update to one registered window and assigns its
    /// service-wide sequence number. Progress is coalesced only with the
    /// immediately preceding progress update for the same job, preserving
    /// event order around lifecycle updates.
    pub fn publishUpdate(
        self: *Service,
        window_id: WindowId,
        update: Update,
    ) !u64 {
        self.lock();
        defer self.unlock();

        const slot = self.findSlot(window_id) orelse return error.WindowClosed;
        if (self.next_event_sequence == std.math.maxInt(u64))
            return error.SequenceExhausted;
        const sequence = self.next_event_sequence;
        self.next_event_sequence += 1;

        var sequenced = update;
        sequenced.sequence = sequence;

        if (slot.needs_resync) {
            slot.resync_sequence = sequence;
            signalWake(self.update_wake_fd);
            return sequence;
        }

        if (sequenced.kind == .progress) {
            if (slot.updates.last()) |last| {
                if (last.kind == .progress and last.job_id == sequenced.job_id) {
                    last.* = sequenced;
                    signalWake(self.update_wake_fd);
                    return sequence;
                }
            }
        }

        if (!slot.updates.push(sequenced)) {
            // A full queue cannot pretend to be continuous. Discard the
            // partial stream and make the loss explicit to its consumer.
            slot.updates.clear();
            slot.needs_resync = true;
            slot.resync_sequence = sequence;
        }
        signalWake(self.update_wake_fd);
        return sequence;
    }

    fn enqueue(self: *Service, window_id: WindowId, command: Command) !void {
        if (!self.tryLock()) return error.ServiceBusy;
        defer self.unlock();

        if (self.stopping) return error.ServiceStopping;
        const slot = self.findSlot(window_id) orelse return error.WindowClosed;
        switch (command.class()) {
            .control => {
                if (!slot.control_commands.push(command))
                    return error.ControlQueueFull;
            },
            .normal => {
                if (slot.normal_commands.count == command_capacity_per_window)
                    return error.WindowQueueFull;
                if (self.pending_normal_commands == aggregate_command_capacity)
                    return error.AggregateQueueFull;
                std.debug.assert(slot.normal_commands.push(command));
                self.pending_normal_commands += 1;
            },
        }
        signalWake(self.command_wake_fd);
    }

    fn receiveUpdate(self: *Service, window_id: WindowId) !?Update {
        if (!self.tryLock()) return error.ServiceBusy;
        defer self.unlock();

        const slot = self.findSlot(window_id) orelse return null;
        if (slot.needs_resync) {
            slot.needs_resync = false;
            return .{
                .sequence = slot.resync_sequence,
                .kind = .resync_required,
            };
        }
        return slot.updates.pop();
    }

    fn unregisterWindow(self: *Service, window_id: WindowId) !void {
        if (!self.tryLock()) return error.ServiceBusy;
        defer self.unlock();

        const slot = self.findSlot(window_id) orelse return;
        self.pending_normal_commands -= slot.normal_commands.count;
        slot.reset();
    }

    fn findSlot(self: *Service, window_id: WindowId) ?*WindowSlot {
        for (&self.windows) |*slot| {
            if (slot.active and slot.id == window_id) return slot;
        }
        return null;
    }

    fn lock(self: *Service) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }

    fn tryLock(self: *Service) bool {
        return c.pthread_mutex_trylock(&self.mutex) == 0;
    }

    fn unlock(self: *Service) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
    }

    fn signalWake(fd: std.posix.fd_t) void {
        const one: u64 = 1;
        while (true) {
            const rc = std.posix.system.write(fd, std.mem.asBytes(&one), @sizeOf(u64));
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    std.debug.assert(rc == @sizeOf(u64));
                    return;
                },
                .INTR => continue,
                // A saturated eventfd is already readable.
                .AGAIN => return,
                else => std.debug.panic("Files service eventfd write failed: {s}", .{
                    @tagName(std.posix.errno(rc)),
                }),
            }
        }
    }
};

fn drainWake(fd: std.posix.fd_t) u64 {
    var count: u64 = 0;
    while (true) {
        var value: u64 = 0;
        const rc = std.posix.system.read(fd, std.mem.asBytes(&value), @sizeOf(u64));
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                std.debug.assert(rc == @sizeOf(u64));
                count +|= value;
            },
            .INTR => continue,
            .AGAIN => return count,
            else => std.debug.panic("Files service eventfd read failed: {s}", .{
                @tagName(std.posix.errno(rc)),
            }),
        }
    }
}

/// Copyable, non-owning per-window capability. Closing it unregisters its
/// identity; stale copies then fail admission and receive no updates.
pub const Handle = struct {
    service: *Service,
    window_id: WindowId,

    pub fn trySend(self: Handle, command: Command) !void {
        try self.service.enqueue(self.window_id, command);
    }

    pub fn tryReceiveUpdate(self: Handle) !?Update {
        return self.service.receiveUpdate(self.window_id);
    }

    pub fn close(self: *Handle) !void {
        try self.service.unregisterWindow(self.window_id);
        self.* = undefined;
    }
};
