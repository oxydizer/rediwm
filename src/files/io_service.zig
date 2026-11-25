//! Process-owned Files I/O service boundary.
//!
//! This module contains only bounded message delivery and window identity.
//! It deliberately exposes no Manager, Runtime, executor or ledger pointer.
const std = @import("std");
const c = @import("c.zig").api;
const wake = @import("platform").wake;
const io_job_table = @import("io_job_table.zig");

pub const JobRecord = io_job_table.Record;
pub const JobState = io_job_table.State;
pub const JobKind = io_job_table.Kind;
pub const FetchResult = io_job_table.FetchResult;

pub const WindowId = u64;
pub const JobId = u64;
pub const ResourceId = u64;

pub const max_windows = 16;
pub const command_capacity_per_window = 8;
pub const control_capacity_per_window = 2;
pub const aggregate_command_capacity = 64;

// Job-table capacities for stage S1 (docs/plans/files-io-threading-and-ownership.md
// §6). Starting values; roadmap phase 7 calibrates them.

/// Jobs from admission until retirement. Never occupied by a consumer.
pub const max_live_jobs = io_job_table.max_live_jobs;
/// Final records of a window's own jobs, reserved at submit.
pub const outcome_slots_per_window = io_job_table.outcome_slots_per_window;
/// Final records of retired jobs for every other window.
pub const tombstone_capacity = io_job_table.tombstone_capacity;
/// Subscribers that are not windows (the shell panel, stage S6).
pub const max_external_consumers = 4;
/// Replies to metadata and small-mutation requests, reserved at admission.
pub const reply_slots_per_window = 4;
/// Borrows a window may hold on resources it does not own.
pub const max_borrows_per_window = 4;
/// Window-local queue for commands refused with ServiceBusy.
pub const outbox_capacity = 4;

comptime {
    // A queued submit must always find a live slot to reserve.
    std.debug.assert(max_live_jobs >= aggregate_command_capacity);
}

/// Debug aid: set while this thread holds a Service mutex. Relocking a
/// default mutex from its holder deadlocks with `lock` and fails forever with
/// `trylock`; this turns either into an immediate panic.
threadlocal var holding_service_mutex: bool = false;

pub const CommandKind = enum {
    submit_job,
    start_discovery,
    prioritize_discovery,
    pause_job,
    resume_job,
    cancel_job,
    resolve_conflict,
    release_resource,
};

pub const CommandClass = enum {
    normal,
    control,
};

pub const TransferMode = enum {
    copy,
    move,
};

pub const TransferSource = struct {
    path: []u8,
};

pub const TransferRequest = struct {
    mode: TransferMode,
    destination_path: []u8,
    sources: []TransferSource,

    fn deinit(self: *TransferRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.destination_path);
        for (self.sources) |source| allocator.free(source.path);
        allocator.free(self.sources);
    }
};

pub const DiscoveryRequest = struct {
    root_entry_id: u64,
    root_path: ?[]u8 = null,

    fn deinit(self: *DiscoveryRequest, allocator: std.mem.Allocator) void {
        if (self.root_path) |path| allocator.free(path);
    }
};

pub const ConflictAction = enum {
    retry,
    replace,
    merge,
    rename,
    skip,
    cancel,
};

pub const ConflictResolutionRequest = struct {
    conflict_id: u64,
    action: ConflictAction,
    destination_path: ?[]u8 = null,

    fn deinit(
        self: *ConflictResolutionRequest,
        allocator: std.mem.Allocator,
    ) void {
        if (self.destination_path) |path| allocator.free(path);
    }
};

/// Heap-owned command data. The allocator travels with the payload so every
/// consumer can release it without depending on the originating window.
pub const OwnedPayload = struct {
    allocator: std.mem.Allocator,
    data: union(enum) {
        transfer: TransferRequest,
        discovery: DiscoveryRequest,
        conflict_resolution: ConflictResolutionRequest,
    },

    pub fn createTransfer(
        allocator: std.mem.Allocator,
        mode: TransferMode,
        destination_path: []const u8,
        source_paths: []const []const u8,
    ) !*OwnedPayload {
        const payload = try allocator.create(OwnedPayload);
        errdefer allocator.destroy(payload);

        const destination = try allocator.dupe(u8, destination_path);
        errdefer allocator.free(destination);

        const sources = try allocator.alloc(TransferSource, source_paths.len);
        var initialized: usize = 0;
        errdefer {
            for (sources[0..initialized]) |source| allocator.free(source.path);
            allocator.free(sources);
        }

        for (source_paths, 0..) |path, index| {
            sources[index] = .{ .path = try allocator.dupe(u8, path) };
            initialized += 1;
        }

        payload.* = .{
            .allocator = allocator,
            .data = .{ .transfer = .{
                .mode = mode,
                .destination_path = destination,
                .sources = sources,
            } },
        };
        return payload;
    }

    pub fn createDiscovery(
        allocator: std.mem.Allocator,
        root_entry_id: u64,
        root_path: ?[]const u8,
    ) !*OwnedPayload {
        const payload = try allocator.create(OwnedPayload);
        errdefer allocator.destroy(payload);

        const owned_path = if (root_path) |path|
            try allocator.dupe(u8, path)
        else
            null;
        errdefer if (owned_path) |path| allocator.free(path);

        payload.* = .{
            .allocator = allocator,
            .data = .{ .discovery = .{
                .root_entry_id = root_entry_id,
                .root_path = owned_path,
            } },
        };
        return payload;
    }

    pub fn createConflictResolution(
        allocator: std.mem.Allocator,
        conflict_id: u64,
        action: ConflictAction,
        destination_path: ?[]const u8,
    ) !*OwnedPayload {
        if ((action == .rename) != (destination_path != null))
            return error.InvalidConflictResolutionPayload;

        const payload = try allocator.create(OwnedPayload);
        errdefer allocator.destroy(payload);

        const owned_path = if (destination_path) |path|
            try allocator.dupe(u8, path)
        else
            null;
        errdefer if (owned_path) |path| allocator.free(path);

        payload.* = .{
            .allocator = allocator,
            .data = .{ .conflict_resolution = .{
                .conflict_id = conflict_id,
                .action = action,
                .destination_path = owned_path,
            } },
        };
        return payload;
    }

    pub fn deinit(self: *OwnedPayload) void {
        const allocator = self.allocator;
        switch (self.data) {
            .transfer => |*request| request.deinit(allocator),
            .discovery => |*request| request.deinit(allocator),
            .conflict_resolution => |*request| request.deinit(allocator),
        }
        allocator.destroy(self);
    }
};

pub const Command = struct {
    kind: CommandKind,
    job_id: JobId = 0,
    resource_id: ResourceId = 0,
    /// For `submit_job`: chosen by the window, echoed in the job's record so
    /// the window can recognise the job it submitted.
    submit_tag: u64 = 0,
    payload: ?*OwnedPayload = null,

    pub fn deinitPayload(self: *Command) void {
        if (self.payload) |payload| {
            self.payload = null;
            payload.deinit();
        }
    }

    pub fn class(self: Command) CommandClass {
        return switch (self.kind) {
            .submit_job, .start_discovery, .prioritize_discovery => .normal,
            .pause_job, .resume_job, .cancel_job, .resolve_conflict, .release_resource => .control,
        };
    }
};

pub const RoutedCommand = struct {
    window_id: WindowId,
    command: Command,
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

    };
}

/// A window slot's identity and lifecycle in one atomic word, so that
/// registering and closing a window take no lock and cannot race a reuse of
/// the slot (ABA): `(id << 2) | state`, and 0 means free.
const SlotState = enum(u2) { free = 0, active = 1, closing = 2 };

/// Window ids must leave room for the two state bits.
const max_window_id: WindowId = (1 << 62) - 1;

fn packSlot(id: WindowId, state: SlotState) u64 {
    std.debug.assert(id <= max_window_id);
    return (id << 2) | @intFromEnum(state);
}

fn slotId(word: u64) WindowId {
    return word >> 2;
}

fn slotState(word: u64) SlotState {
    return @enumFromInt(@as(u2, @truncate(word)));
}

const WindowSlot = struct {
    /// Written by `registerWindow` (free -> active) and `Handle.close`
    /// (active -> closing) without the Service mutex, and by the coordinator
    /// (closing -> free) under it. Every other field is guarded by the mutex.
    word: std.atomic.Value(u64) = .init(0),
    normal_commands: Ring(Command, command_capacity_per_window) = .{},
    control_commands: Ring(Command, control_capacity_per_window) = .{},

    /// Called under the Service mutex on a closing slot. Clears the guarded
    /// fields first, then publishes the slot as free with release ordering,
    /// so a registrar that claims it sees empty queues.
    fn reset(self: *WindowSlot) void {
        std.debug.assert(slotState(self.word.load(.acquire)) == .closing);
        self.normal_commands = .{};
        self.control_commands = .{};
        self.word.store(0, .release);
    }
};

/// The process owner creates one Service at a stable address. Window handles
/// are non-owning capabilities; they cannot access service internals.
pub const Service = struct {
    mutex: c.pthread_mutex_t = undefined,
    command_wake_fd: std.posix.fd_t = -1,
    update_wake_fd: std.posix.fd_t = -1,
    windows: [max_windows]WindowSlot = std.mem.zeroes([max_windows]WindowSlot),
    next_window_id: std.atomic.Value(WindowId) = .init(1),
    next_drain_slot: usize = 0,
    pending_normal_commands: usize = 0,
    /// Consumers 0..max_windows-1 are the window slots, in slot order; the
    /// rest are external subscribers. Guarded by the mutex.
    table: io_job_table.Table(max_windows + max_external_consumers) = .{},
    external_ids: [max_external_consumers]u64 = @splat(0),
    stopping: std.atomic.Value(bool) = .init(false),

    /// Initialize in place: an initialized pthread mutex must not be copied.
    pub fn init(self: *Service) !void {
        self.* = .{};
        // Safety-checked builds use an error-checking mutex, so an unlock by
        // a thread that does not hold it is reported instead of undefined.
        var attr: c.pthread_mutexattr_t = undefined;
        if (c.pthread_mutexattr_init(&attr) != 0) return error.MutexInitFailed;
        defer std.debug.assert(c.pthread_mutexattr_destroy(&attr) == 0);
        if (std.debug.runtime_safety and
            c.pthread_mutexattr_settype(&attr, c.PTHREAD_MUTEX_ERRORCHECK) != 0)
            return error.MutexInitFailed;
        if (c.pthread_mutex_init(&self.mutex, &attr) != 0)
            return error.MutexInitFailed;
        errdefer std.debug.assert(c.pthread_mutex_destroy(&self.mutex) == 0);

        self.command_wake_fd = wake.create() orelse return error.WakeDescriptorCreateFailed;
        errdefer _ = std.posix.system.close(self.command_wake_fd);

        self.update_wake_fd = wake.create() orelse return error.WakeDescriptorCreateFailed;
    }

    pub fn deinit(self: *Service) void {
        self.lock();
        self.reapClosedSlots();
        for (&self.windows) |*slot| std.debug.assert(slot.word.load(.acquire) == 0);
        for (self.external_ids) |id| std.debug.assert(id == 0);
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

    /// Shared process-wide wake descriptor, signalled when any job record changes.
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
    /// Takes no lock and never waits: safe on the UI thread. Fails only with
    /// `ServiceStopping`, `WindowIdExhausted` or `TooManyWindows`. Closing
    /// slots count toward `max_windows` until the coordinator recycles them.
    pub fn registerWindow(self: *Service) !Handle {
        if (self.stopping.load(.acquire)) return error.ServiceStopping;
        const id = self.next_window_id.fetchAdd(1, .monotonic);
        if (id > max_window_id) return error.WindowIdExhausted;
        if (self.claimFreeSlot(id)) return .{ .service = self, .window_id = id };

        // Every slot is taken or still closing. Recycle drained closing slots
        // if the mutex happens to be free; never wait for it.
        if (self.tryLock()) {
            self.reapClosedSlots();
            self.unlock();
            if (self.claimFreeSlot(id)) return .{ .service = self, .window_id = id };
        }
        return error.TooManyWindows;
    }

    fn claimFreeSlot(self: *Service, id: WindowId) bool {
        const claimed = packSlot(id, .active);
        for (&self.windows) |*slot| {
            if (slot.word.cmpxchgStrong(0, claimed, .acq_rel, .monotonic) == null)
                return true;
        }
        return false;
    }

    /// Stops new admission. Existing handles may still read the job table
    /// and unregister; the process owner controls final teardown.
    pub fn beginShutdown(self: *Service) void {
        self.lock();
        defer self.unlock();
        self.stopping.store(true, .release);
        signalWake(self.command_wake_fd);
    }

    pub fn isStopping(self: *Service) bool {
        return self.stopping.load(.acquire);
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
            const word = slot.word.load(.acquire);
            if (word == 0) continue;
            const window_id = slotId(word);

            if (slot.control_commands.pop()) |command| {
                const routed = RoutedCommand{ .window_id = window_id, .command = command };
                self.recycleClosedSlot(slot);
                return routed;
            }
            if (slot.normal_commands.pop()) |command| {
                self.pending_normal_commands -= 1;
                const routed = RoutedCommand{ .window_id = window_id, .command = command };
                self.recycleClosedSlot(slot);
                return routed;
            }
            // A slot closed with nothing queued is recycled here.
            self.recycleClosedSlot(slot);
        }
        return null;
    }

    fn enqueue(
        self: *Service,
        window_id: WindowId,
        command: *Command,
        allow_payload: bool,
    ) !void {
        if (!self.tryLock()) return error.ServiceBusy;
        defer self.unlock();

        if (!allow_payload and command.payload != null)
            return error.OwnedPayloadRequiresTransfer;
        if (self.stopping.load(.acquire)) return error.ServiceStopping;
        const slot = self.findSlot(window_id) orelse return error.WindowClosed;
        switch (command.class()) {
            .control => {
                if (!slot.control_commands.push(command.*))
                    return error.ControlQueueFull;
            },
            .normal => {
                if (slot.normal_commands.count == command_capacity_per_window)
                    return error.WindowQueueFull;
                if (self.pending_normal_commands == aggregate_command_capacity)
                    return error.AggregateQueueFull;
                // An accepted submit always has a record to appear in, and
                // its window an outcome slot (threading §5).
                if (command.kind == .submit_job) {
                    const index = self.ensureConsumer(slot, window_id);
                    try self.table.reserveSubmit(index);
                }
                std.debug.assert(slot.normal_commands.push(command.*));
                self.pending_normal_commands += 1;
            },
        }
        // The queue now owns the payload. On every admission error above,
        // the caller's Command remains unchanged and retains ownership.
        command.payload = null;
        signalWake(self.command_wake_fd);
    }

    // ---- job table: consumers ----

    /// Fail-fast table read for a window (UI thread). See
    /// `io_job_table.Table.fetch` for the ordering and resync contract.
    fn fetchChanges(self: *Service, window_id: WindowId, out: []JobRecord) !FetchResult {
        if (!self.tryLock()) return error.ServiceBusy;
        defer self.unlock();
        const slot = self.findSlot(window_id) orelse return error.WindowClosed;
        const index = self.ensureConsumer(slot, window_id);
        return self.table.fetch(index, out);
    }

    fn copyRateHistory(self: *Service, window_id: WindowId, job_id: JobId, out: []u64) !usize {
        if (!self.tryLock()) return error.ServiceBusy;
        defer self.unlock();
        _ = self.findSlot(window_id) orelse return error.WindowClosed;
        return self.table.copyRateHistory(job_id, out);
    }

    /// Registers a subscriber that is not a window (stage S6). Called from
    /// the endpoint thread, never the UI thread, so it may take the lock.
    pub fn registerExternal(self: *Service) !ExternalHandle {
        self.lock();
        defer self.unlock();
        if (self.stopping.load(.acquire)) return error.ServiceStopping;
        for (&self.external_ids, 0..) |*slot_id, i| {
            if (slot_id.* != 0) continue;
            const id = self.next_window_id.fetchAdd(1, .monotonic);
            if (id > max_window_id) return error.WindowIdExhausted;
            slot_id.* = id;
            self.table.attach(max_windows + i, id, false);
            return .{ .service = self, .index = i, .id = id };
        }
        return error.TooManyConsumers;
    }

    // ---- job table: writer (coordinator only) ----

    /// Creates a job's record. `from_reservation` consumes the live slot that
    /// `submit_job` admission reserved.
    pub fn createJobRecord(self: *Service, record: JobRecord, from_reservation: bool) !void {
        self.lock();
        defer self.unlock();
        try self.table.create(record, from_reservation);
        signalWake(self.update_wake_fd);
    }

    pub fn updateJobRecord(self: *Service, record: JobRecord) !void {
        self.lock();
        defer self.unlock();
        try self.table.update(record);
        signalWake(self.update_wake_fd);
    }

    pub fn retireJobRecord(self: *Service, job_id: JobId) !void {
        self.lock();
        defer self.unlock();
        try self.table.retire(job_id);
        signalWake(self.update_wake_fd);
    }

    pub fn appendRateSample(self: *Service, job_id: JobId, bytes_per_second: u64) void {
        self.lock();
        defer self.unlock();
        self.table.appendRateSample(job_id, bytes_per_second);
    }


    /// Marks the window closing with one compare-and-swap. Takes no lock,
    /// cannot fail and never waits, so window teardown cannot stall the UI
    /// thread. The id in the CAS means a stale `Handle` copy can never close
    /// a later window that reused the slot. Closing twice is harmless.
    fn unregisterWindow(self: *Service, window_id: WindowId) void {
        const active = packSlot(window_id, .active);
        const closing = packSlot(window_id, .closing);
        for (&self.windows) |*slot| {
            if (slot.word.cmpxchgStrong(active, closing, .acq_rel, .monotonic) != null)
                continue;
            // Queued commands are still processed; the coordinator recycles
            // the slot once they are. Recycle at once if nobody holds the
            // mutex, but never wait for it.
            if (self.tryLock()) {
                self.recycleClosedSlot(slot);
                self.unlock();
            }
            signalWake(self.command_wake_fd);
            return;
        }
    }

    /// Called under the mutex.
    fn reapClosedSlots(self: *Service) void {
        for (&self.windows) |*slot| self.recycleClosedSlot(slot);
    }

    /// Called under the mutex. Drops the window's table view (cursor and
    /// outcomes) with the slot; jobs are never touched.
    fn recycleClosedSlot(self: *Service, slot: *WindowSlot) void {
        if (slotState(slot.word.load(.acquire)) != .closing) return;
        if (slot.normal_commands.count != 0 or slot.control_commands.count != 0)
            return;
        self.table.detach(self.slotIndex(slot));
        slot.reset();
    }

    fn slotIndex(self: *const Service, slot: *const WindowSlot) usize {
        return (@intFromPtr(slot) - @intFromPtr(&self.windows[0])) / @sizeOf(WindowSlot);
    }

    /// Called under the mutex. A window's table consumer is attached on its
    /// first locked call, since registration itself takes no lock.
    fn ensureConsumer(self: *Service, slot: *WindowSlot, window_id: WindowId) usize {
        const index = self.slotIndex(slot);
        if (!self.table.isAttached(index, window_id)) self.table.attach(index, window_id, true);
        return index;
    }

    /// Called under the mutex. Finds an open (not closing) window.
    fn findSlot(self: *Service, window_id: WindowId) ?*WindowSlot {
        const active = packSlot(window_id, .active);
        for (&self.windows) |*slot| {
            if (slot.word.load(.acquire) == active) return slot;
        }
        return null;
    }

    /// Blocking acquisition: the coordinator, and the process owner after
    /// the UI is gone. Never on the UI thread (threading §3).
    fn lock(self: *Service) void {
        assertNotHolding();
        const rc = c.pthread_mutex_lock(&self.mutex);
        if (rc != 0) std.debug.panic("Files service mutex lock failed: {d}", .{rc});
        holding_service_mutex = true;
    }

    /// Fail-fast acquisition for UI-side calls.
    fn tryLock(self: *Service) bool {
        assertNotHolding();
        const rc = c.pthread_mutex_trylock(&self.mutex);
        if (rc == c.EBUSY) return false;
        if (rc != 0) std.debug.panic("Files service mutex trylock failed: {d}", .{rc});
        holding_service_mutex = true;
        return true;
    }

    fn unlock(self: *Service) void {
        holding_service_mutex = false;
        const rc = c.pthread_mutex_unlock(&self.mutex);
        if (rc != 0) std.debug.panic("Files service mutex unlock failed: {d}", .{rc});
    }

    fn assertNotHolding() void {
        if (std.debug.runtime_safety and holding_service_mutex)
            std.debug.panic("Files service mutex relocked by its holder", .{});
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
/// identity; stale copies then fail admission and job-table reads.
pub const Handle = struct {
    service: *Service,
    window_id: WindowId,

    pub fn trySend(self: Handle, command: Command) !void {
        var copy = command;
        try self.service.enqueue(self.window_id, &copy, false);
    }

    /// On success, ownership of command.payload moves into the service queue
    /// and command.payload is cleared. On failure, the caller retains it.
    pub fn trySendOwned(self: Handle, command: *Command) !void {
        try self.service.enqueue(self.window_id, command, true);
    }

    /// Reads job records changed since this window's last read, its own
    /// outcomes first. Fails fast with `ServiceBusy`; retry on a later
    /// event-loop iteration (threading §3).
    pub fn fetchChanges(self: Handle, out: []JobRecord) !FetchResult {
        return self.service.fetchChanges(self.window_id, out);
    }

    /// Copies a live job's speed history, oldest first.
    pub fn rateHistory(self: Handle, job_id: JobId, out: []u64) !usize {
        return self.service.copyRateHistory(self.window_id, job_id, out);
    }

    /// Never fails and never waits (see `Service.unregisterWindow`).
    pub fn close(self: *Handle) void {
        self.service.unregisterWindow(self.window_id);
        self.* = undefined;
    }
};

/// A subscriber that is not a window (stage S6). Used from the endpoint
/// thread, which may block on the Service mutex.
pub const ExternalHandle = struct {
    service: *Service,
    index: usize,
    id: u64,

    pub fn fetchChanges(self: ExternalHandle, out: []JobRecord) FetchResult {
        self.service.lock();
        defer self.service.unlock();
        return self.service.table.fetch(max_windows + self.index, out);
    }

    pub fn close(self: *ExternalHandle) void {
        const service = self.service;
        const index = self.index;
        self.* = undefined;
        service.lock();
        defer service.unlock();
        service.table.detach(max_windows + index);
        service.external_ids[index] = 0;
    }
};
