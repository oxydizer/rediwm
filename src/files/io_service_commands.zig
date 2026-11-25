//! Commands windows send to the Files I/O service, and their owned payloads.
//! Re-exported by io_service.zig.
const std = @import("std");

pub const WindowId = u64;
pub const JobId = u64;
pub const ResourceId = u64;

pub const CommandKind = enum {
    submit_job,
    start_discovery,
    prioritize_discovery,
    pause_job,
    resume_job,
    cancel_job,
    resolve_conflict,
    /// Drops a borrow this window holds (`resource_id`).
    release_borrow,
    /// Gives a window-owned resource (`resource_id`) back to its executor,
    /// which destroys it on a worker.
    dispose_resource,
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
            .pause_job, .resume_job, .cancel_job, .resolve_conflict, .release_borrow, .dispose_resource => .control,
        };
    }
};

pub const RoutedCommand = struct {
    window_id: WindowId,
    command: Command,
};

