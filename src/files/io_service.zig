//! Process-owned Files I/O service boundary.
//!
//! This module contains only bounded message delivery and window identity.
//! It deliberately exposes no Manager, Runtime, executor or ledger pointer.
const std = @import("std");
const c = @import("c.zig").api;
const wake = @import("platform").wake;
const io_job_table = @import("io_job_table.zig");
const commands = @import("io_service_commands.zig");

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
/// Commands the coordinator handles per loop pass before it reconciles
/// completions and publishes (threading §5, §7). Below the aggregate capacity,
/// so a full set of queues takes several passes, each with its completions.
pub const command_quota = 16;

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
/// Control commands from every external subscriber waiting at once.
pub const external_control_capacity = 16;
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

pub const CommandKind = commands.CommandKind;
pub const CommandClass = commands.CommandClass;
pub const TransferMode = commands.TransferMode;
pub const TransferSource = commands.TransferSource;
pub const TransferRequest = commands.TransferRequest;
pub const DeletionKind = commands.DeletionKind;
pub const ArchivePurpose = commands.ArchivePurpose;
pub const ArchiveRequest = commands.ArchiveRequest;
pub const DeletionRequest = commands.DeletionRequest;
pub const DiscoveryRequest = commands.DiscoveryRequest;
pub const ConflictAction = commands.ConflictAction;
pub const ConflictResolutionRequest = commands.ConflictResolutionRequest;
pub const OwnedPayload = commands.OwnedPayload;
pub const Command = commands.Command;
pub const ExternalHandle = @import("io_service_external.zig").ExternalHandle;
pub const RoutedCommand = commands.RoutedCommand;
pub const Request = io_requests.Request;
pub const Reply = io_requests.Reply;
const io_requests = @import("io_requests.zig");
pub const io_job_views = @import("io_job_views.zig");
pub const ViewSnapshot = io_job_views.Snapshot;

pub fn Ring(comptime T: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]T = undefined,
        head: usize = 0,
        count: usize = 0,

        pub fn push(self: *@This(), value: T) bool {
            if (self.count == capacity) return false;
            self.items[(self.head + self.count) % capacity] = value;
            self.count += 1;
            return true;
        }

        pub fn pop(self: *@This()) ?T {
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
pub const max_window_id: WindowId = (1 << 62) - 1;

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
    /// Replies waiting for the window, and slots reserved for requests
    /// still in flight. Together at most `reply_slots_per_window`.
    replies: Ring(*Reply, reply_slots_per_window) = .{},
    reserved_replies: usize = 0,
    /// The newest snapshot of each watched view not yet taken.
    views: [io_job_views.slots_per_window]?*ViewSnapshot = @splat(null),

    fn freeReplies(self: *WindowSlot) void {
        while (self.replies.pop()) |reply| reply.destroy();
        self.reserved_replies = 0;
        for (&self.views) |*view| if (view.*) |snapshot| {
            snapshot.destroy();
            view.* = null;
        };
    }

    /// Called under the Service mutex on a closing slot. Clears the guarded
    /// fields first, then publishes the slot as free with release ordering,
    /// so a registrar that claims it sees empty queues.
    fn reset(self: *WindowSlot) void {
        std.debug.assert(slotState(self.word.load(.acquire)) == .closing);
        self.normal_commands = .{};
        self.control_commands = .{};
        self.freeReplies();
        self.word.store(0, .release);
    }
};

/// The process owner creates one Service at a stable address. Window handles
/// are non-owning capabilities; they cannot access service internals.
pub const Service = struct {
    mutex: c.pthread_mutex_t = undefined,
    command_wake_fd: std.posix.fd_t = -1,
    update_wake_fd: std.posix.fd_t = -1,
    /// The coordinator has nothing in hand (stage S6): set by it each pass,
    /// read by the UI thread to tell whether a process without windows still
    /// has work, and so must stay reachable through its endpoint.
    work_idle: std.atomic.Value(bool) = .init(true),
    windows: [max_windows]WindowSlot = @splat(.{}),
    next_window_id: std.atomic.Value(WindowId) = .init(1),
    next_drain_slot: usize = 0,
    pending_normal_commands: usize = 0,
    /// Consumers 0..max_windows-1 are the window slots, in slot order; the
    /// rest are external subscribers. Guarded by the mutex.
    table: io_job_table.Table(max_windows + max_external_consumers) = .{},
    /// Windows whose slot was recycled since the coordinator last asked, so
    /// it can drop their borrows and dispose what they own. Guarded by the
    /// mutex. On overflow the coordinator sweeps every holder instead.
    closed_windows: Ring(WindowId, max_windows) = .{},
    closed_overflow: bool = false,
    external_ids: [max_external_consumers]u64 = @splat(0),
    /// Signalled with every table change, for the endpoint thread (S6b).
    external_wake_fd: std.posix.fd_t = -1,
    /// Pause, resume and cancel from external subscribers. Guarded by the
    /// mutex; taken before the windows' queues, being few and small.
    external_controls: Ring(Command, external_control_capacity) = .{},
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
        errdefer _ = std.posix.system.close(self.update_wake_fd);

        self.external_wake_fd = wake.create() orelse return error.WakeDescriptorCreateFailed;
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
        _ = std.posix.system.close(self.external_wake_fd);
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

    /// Coordinator: records whether it is idle; a change wakes the UI thread.
    pub fn setWorkIdle(self: *Service, idle: bool) void {
        if (self.work_idle.swap(idle, .acq_rel) != idle) signalWake(self.update_wake_fd);
    }

    /// UI thread: whether the coordinator had nothing in hand at its last pass.
    pub fn isWorkIdle(self: *const Service) bool {
        return self.work_idle.load(.acquire);
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
        return self.popCommand();
    }

    /// Takes up to `out.len` commands under one lock, in the same order as
    /// repeated `tryReceiveCommand` calls (round-robin over windows, control
    /// first within a window). The coordinator passes `command_quota` slots,
    /// so a window that keeps sending cannot hold it away from completions.
    pub fn receiveCommands(self: *Service, out: []RoutedCommand) usize {
        self.lock();
        defer self.unlock();
        var count: usize = 0;
        while (count < out.len) : (count += 1) {
            out[count] = self.popCommand() orelse break;
        }
        return count;
    }

    /// Caller holds the lock.
    fn popCommand(self: *Service) ?RoutedCommand {
        // External controls carry no window: pause, resume and cancel act on
        // the job alone.
        if (self.external_controls.pop()) |command| return .{ .window_id = 0, .command = command };
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
                // An accepted request always has a slot for its reply.
                if (command.kind == .request) {
                    if (slot.reserved_replies + slot.replies.count >= reply_slots_per_window)
                        return error.RepliesFull;
                    slot.reserved_replies += 1;
                }
                std.debug.assert(slot.normal_commands.push(command.*));
                self.pending_normal_commands += 1;
            },
        }
        // The queue now owns the payload. On every admission error above,
        // the caller's Command remains unchanged and retains ownership.
        command.payload = null;
        // Busy until the coordinator says otherwise: a window that sends a
        // copy and closes at once must not leave a process that looks idle.
        self.work_idle.store(false, .release);
        signalWake(self.command_wake_fd);
    }

    // ---- request replies ----

    /// Called by the coordinator: hands a reply to its window's reserved
    /// slot, or frees it when the window is gone.
    pub fn deliverReply(self: *Service, window_id: WindowId, reply: *Reply) void {
        self.lock();
        defer self.unlock();
        const slot = self.findSlot(window_id) orelse return reply.destroy();
        std.debug.assert(slot.reserved_replies > 0);
        slot.reserved_replies -= 1;
        std.debug.assert(slot.replies.push(reply));
        signalWake(self.update_wake_fd);
    }

    /// Called by the coordinator for a request that will never reply.
    pub fn cancelReplyReservation(self: *Service, window_id: WindowId) void {
        self.lock();
        defer self.unlock();
        const slot = self.findSlot(window_id) orelse return;
        if (slot.reserved_replies > 0) slot.reserved_replies -= 1;
    }

    /// Called by the coordinator: the newest snapshot of a watched view
    /// replaces one the window has not taken (latest wins), or is freed
    /// when the window is gone. False in that case.
    pub fn deliverView(self: *Service, window_id: WindowId, snapshot: *ViewSnapshot) bool {
        self.lock();
        defer self.unlock();
        const slot = self.findSlot(window_id) orelse {
            snapshot.destroy();
            return false;
        };
        const view = &slot.views[snapshot.slot];
        if (view.*) |old| old.destroy();
        view.* = snapshot;
        signalWake(self.update_wake_fd);
        return true;
    }

    fn takeView(self: *Service, window_id: WindowId, view_slot: u8) !?*ViewSnapshot {
        if (!self.tryLock()) return error.ServiceBusy;
        defer self.unlock();
        const slot = self.findSlot(window_id) orelse return error.WindowClosed;
        const snapshot = slot.views[view_slot];
        slot.views[view_slot] = null;
        return snapshot;
    }

    fn takeReply(self: *Service, window_id: WindowId) !?*Reply {
        if (!self.tryLock()) return error.ServiceBusy;
        defer self.unlock();
        const slot = self.findSlot(window_id) orelse return error.WindowClosed;
        return slot.replies.pop();
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

    const external = @import("io_service_external.zig");
    pub const registerExternal = external.registerExternal;
    pub const externalWakeFd = external.externalWakeFd;
    pub const drainExternalWake = external.drainExternalWake;
    pub const sendControl = external.sendControl;

    // ---- job table: writer (coordinator only) ----

    /// Creates a job's record. `from_reservation` consumes the live slot that
    /// `submit_job` admission reserved.
    pub fn createJobRecord(self: *Service, record: JobRecord, from_reservation: bool) !void {
        self.lock();
        defer self.unlock();
        try self.table.create(record, from_reservation);
        signalWake(self.update_wake_fd);
        signalWake(self.external_wake_fd);
    }

    pub fn updateJobRecord(self: *Service, record: JobRecord) !void {
        self.lock();
        defer self.unlock();
        try self.table.update(record);
        signalWake(self.update_wake_fd);
        signalWake(self.external_wake_fd);
    }

    pub fn retireJobRecord(self: *Service, job_id: JobId) !void {
        self.lock();
        defer self.unlock();
        try self.table.retire(job_id);
        signalWake(self.update_wake_fd);
        signalWake(self.external_wake_fd);
    }

    pub fn appendRateSample(self: *Service, job_id: JobId, bytes_per_second: u64) void {
        self.lock();
        defer self.unlock();
        self.table.appendRateSample(job_id, bytes_per_second);
        signalWake(self.external_wake_fd);
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
        if (!self.closed_windows.push(slotId(slot.word.load(.acquire)))) self.closed_overflow = true;
        slot.reset();
        signalWake(self.command_wake_fd);
    }

    /// Called by the coordinator: the next window closed since its last
    /// call, or null. `overflowed` is set when some were not recorded and
    /// every holder must be checked with `isWindowOpen`.
    pub fn takeClosedWindow(self: *Service, overflowed: *bool) ?WindowId {
        self.lock();
        defer self.unlock();
        if (self.closed_overflow) {
            self.closed_overflow = false;
            overflowed.* = true;
        }
        return self.closed_windows.pop();
    }

    /// Lock-free: how many windows are registered and not closing.
    pub fn openWindowCount(self: *const Service) usize {
        var count: usize = 0;
        for (&self.windows) |*slot| {
            if (slotState(slot.word.load(.acquire)) == .active) count += 1;
        }
        return count;
    }

    /// Lock-free: whether any window is registered and not closing.
    pub fn anyWindowOpen(self: *const Service) bool {
        for (&self.windows) |*slot| {
            if (slotState(slot.word.load(.acquire)) == .active) return true;
        }
        return false;
    }

    /// Whether any accepted command still waits in a queue.
    pub fn hasQueuedCommands(self: *Service) bool {
        self.lock();
        defer self.unlock();
        if (self.external_controls.count != 0) return true;
        for (&self.windows) |*slot| {
            if (slot.normal_commands.count != 0 or slot.control_commands.count != 0) return true;
        }
        return false;
    }

    /// Lock-free: whether `window_id` is registered and not closing.
    pub fn isWindowOpen(self: *const Service, window_id: WindowId) bool {
        if (window_id == 0 or window_id > max_window_id) return false;
        const active = packSlot(window_id, .active);
        for (&self.windows) |*slot| {
            if (slot.word.load(.acquire) == active) return true;
        }
        return false;
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
    pub fn lock(self: *Service) void {
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

    pub fn unlock(self: *Service) void {
        holding_service_mutex = false;
        const rc = c.pthread_mutex_unlock(&self.mutex);
        if (rc != 0) std.debug.panic("Files service mutex unlock failed: {d}", .{rc});
    }

    fn assertNotHolding() void {
        if (std.debug.runtime_safety and holding_service_mutex)
            std.debug.panic("Files service mutex relocked by its holder", .{});
    }

    pub fn signalWake(fd: std.posix.fd_t) void {
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

pub fn drainWake(fd: std.posix.fd_t) u64 {
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

    /// The next reply to one of this window's requests, or null. The caller
    /// owns it (`Reply.destroy`). Fails fast with `ServiceBusy`.
    pub fn takeReply(self: Handle) !?*Reply {
        return self.service.takeReply(self.window_id);
    }

    /// The newest snapshot of view slot `view_slot`, or null when none
    /// arrived since the last take. The caller owns it (`destroy`).
    pub fn takeView(self: Handle, view_slot: u8) !?*ViewSnapshot {
        return self.service.takeView(self.window_id, view_slot);
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

