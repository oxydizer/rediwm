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
            .pause_job, .resume_job, .cancel_job, .resolve_conflict, .retire_job, .release_resource => .control,
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
    updates: Ring(Update, update_capacity_per_window) = .{},
    needs_resync: bool = false,
    resync_sequence: u64 = 0,

    /// Called under the Service mutex on a closing slot. Clears the guarded
    /// fields first, then publishes the slot as free with release ordering,
    /// so a registrar that claims it sees empty queues.
    fn reset(self: *WindowSlot) void {
        std.debug.assert(slotState(self.word.load(.acquire)) == .closing);
        self.normal_commands = .{};
        self.control_commands = .{};
        self.updates = .{};
        self.needs_resync = false;
        self.resync_sequence = 0;
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
    next_event_sequence: u64 = 1,
    next_drain_slot: usize = 0,
    pending_normal_commands: usize = 0,
    stopping: std.atomic.Value(bool) = .init(false),

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
        self.reapClosedSlots();
        for (&self.windows) |*slot| std.debug.assert(slot.word.load(.acquire) == 0);
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

    /// Stops new admission. Existing handles may still drain queued updates
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
                recycleClosedSlot(slot);
                return routed;
            }
            if (slot.normal_commands.pop()) |command| {
                self.pending_normal_commands -= 1;
                const routed = RoutedCommand{ .window_id = window_id, .command = command };
                recycleClosedSlot(slot);
                return routed;
            }
            // A slot closed with nothing queued is recycled here.
            recycleClosedSlot(slot);
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
                std.debug.assert(slot.normal_commands.push(command.*));
                self.pending_normal_commands += 1;
            },
        }
        // The queue now owns the payload. On every admission error above,
        // the caller's Command remains unchanged and retains ownership.
        command.payload = null;
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
                recycleClosedSlot(slot);
                self.unlock();
            }
            signalWake(self.command_wake_fd);
            return;
        }
    }

    /// Called under the mutex.
    fn reapClosedSlots(self: *Service) void {
        for (&self.windows) |*slot| recycleClosedSlot(slot);
    }

    /// Called under the mutex.
    fn recycleClosedSlot(slot: *WindowSlot) void {
        if (slotState(slot.word.load(.acquire)) != .closing) return;
        if (slot.normal_commands.count != 0 or slot.control_commands.count != 0)
            return;
        slot.reset();
    }

    /// Called under the mutex. Finds an open (not closing) window.
    fn findSlot(self: *Service, window_id: WindowId) ?*WindowSlot {
        const active = packSlot(window_id, .active);
        for (&self.windows) |*slot| {
            if (slot.word.load(.acquire) == active) return slot;
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
        var copy = command;
        try self.service.enqueue(self.window_id, &copy, false);
    }

    /// On success, ownership of command.payload moves into the service queue
    /// and command.payload is cleared. On failure, the caller retains it.
    pub fn trySendOwned(self: Handle, command: *Command) !void {
        try self.service.enqueue(self.window_id, command, true);
    }

    pub fn tryReceiveUpdate(self: Handle) !?Update {
        return self.service.receiveUpdate(self.window_id);
    }

    /// Never fails and never waits (see `Service.unregisterWindow`).
    pub fn close(self: *Handle) void {
        self.service.unregisterWindow(self.window_id);
        self.* = undefined;
    }
};
