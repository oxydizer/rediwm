//! Commands windows send to the Files I/O service, and their owned payloads.
//! Re-exported by io_service.zig.
const std = @import("std");
const io_requests = @import("io_requests.zig");
const io_job_views = @import("io_job_views.zig");

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
    /// A metadata or small-mutation request (`io_requests.zig`). `submit_tag`
    /// names it; its reply goes to one of the window's reply slots.
    request,
    /// Watch a level of a job's tree in a view slot (`io_job_views.zig`).
    watch_view,
    /// Stop the watch in view slot `submit_tag`.
    unwatch_view,
    /// Copy entry `resource_id` of job `job_id` next (a hovered ghost).
    prioritize_entry,
    /// Discover and copy folder `resource_id` of job `job_id` sooner.
    promote_subtree,
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

/// What a deletion job does (threading §8: delete, trash and empty_trash
/// are jobs, since they can be long and want progress and cancellation).
pub const DeletionKind = enum {
    /// `rm -r` on each path.
    delete,
    /// `gio trash` on each path.
    trash,
    /// `gio trash --empty`, then the orphaned metadata under `trash_dir`.
    empty_trash,
    /// Top-level entries of the Trash view, with their metadata.
    delete_from_trash,
};

pub const DeletionRequest = struct {
    kind: DeletionKind,
    paths: [][]u8,
    /// The Trash `files/` directory, for `empty_trash` and
    /// `delete_from_trash`; null otherwise.
    trash_dir: ?[]u8 = null,

    fn deinit(self: *DeletionRequest, allocator: std.mem.Allocator) void {
        for (self.paths) |path| allocator.free(path);
        allocator.free(self.paths);
        if (self.trash_dir) |dir| allocator.free(dir);
    }
};

/// What an archive job is for (stage S4).
pub const ArchivePurpose = enum {
    /// Into `destination`, published through the usual conflicts and ghosts.
    extract,
    /// One member, `members[0]`, into private staging: the window opens it.
    member,
    /// The members named into private staging: the window puts them on the
    /// clipboard, in a drag or before Open With.
    @"export",
};

pub const ArchiveRequest = struct {
    purpose: ArchivePurpose,
    /// The archive file.
    source: []u8,
    /// Where an extraction goes; for the other purposes the staging parent.
    destination: []u8,
    /// Members, relative to the archive root. Empty extracts everything.
    members: [][]u8,

    fn deinit(self: *ArchiveRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.destination);
        for (self.members) |member| allocator.free(member);
        allocator.free(self.members);
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
        deletion: DeletionRequest,
        archive: ArchiveRequest,
        request: io_requests.Owned,
        watch: io_job_views.Watch,
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

    pub fn createDeletion(
        allocator: std.mem.Allocator,
        kind: DeletionKind,
        paths: []const []const u8,
        trash_dir: ?[]const u8,
    ) !*OwnedPayload {
        const payload = try allocator.create(OwnedPayload);
        errdefer allocator.destroy(payload);

        const owned_dir = if (trash_dir) |dir| try allocator.dupe(u8, dir) else null;
        errdefer if (owned_dir) |dir| allocator.free(dir);

        const owned = try allocator.alloc([]u8, paths.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |path| allocator.free(path);
            allocator.free(owned);
        }
        for (paths, 0..) |path, index| {
            owned[index] = try allocator.dupe(u8, path);
            initialized += 1;
        }

        payload.* = .{
            .allocator = allocator,
            .data = .{ .deletion = .{ .kind = kind, .paths = owned, .trash_dir = owned_dir } },
        };
        return payload;
    }

    pub fn createArchive(
        allocator: std.mem.Allocator,
        purpose: ArchivePurpose,
        source: []const u8,
        destination: []const u8,
        members: []const []const u8,
    ) !*OwnedPayload {
        if (purpose == .member and members.len != 1) return error.InvalidArchiveMemberPath;
        const payload = try allocator.create(OwnedPayload);
        errdefer allocator.destroy(payload);
        const owned_source = try allocator.dupe(u8, source);
        errdefer allocator.free(owned_source);
        const owned_destination = try allocator.dupe(u8, destination);
        errdefer allocator.free(owned_destination);
        const owned = try allocator.alloc([]u8, members.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |member| allocator.free(member);
            allocator.free(owned);
        }
        for (members, 0..) |member, index| {
            owned[index] = try allocator.dupe(u8, member);
            initialized += 1;
        }
        payload.* = .{ .allocator = allocator, .data = .{ .archive = .{
            .purpose = purpose,
            .source = owned_source,
            .destination = owned_destination,
            .members = owned,
        } } };
        return payload;
    }

    pub fn createRequest(allocator: std.mem.Allocator, request: io_requests.Request) !*OwnedPayload {
        const payload = try allocator.create(OwnedPayload);
        errdefer allocator.destroy(payload);
        payload.* = .{ .allocator = allocator, .data = .{ .request = try io_requests.create(allocator, request) } };
        return payload;
    }

    pub fn createWatch(allocator: std.mem.Allocator, watch: io_job_views.Watch) !*OwnedPayload {
        if (watch.slot >= io_job_views.slots_per_window or watch.limit == 0 or watch.limit > io_job_views.max_rows)
            return error.InvalidWatch;
        const payload = try allocator.create(OwnedPayload);
        errdefer allocator.destroy(payload);
        var owned = watch;
        owned.path = try allocator.dupe(u8, watch.path);
        payload.* = .{ .allocator = allocator, .data = .{ .watch = owned } };
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
            .deletion => |*request| request.deinit(allocator),
            .archive => |*request| request.deinit(allocator),
            .request => |*request| request.deinit(),
            .watch => |w| allocator.free(w.path),
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
            .submit_job, .start_discovery, .prioritize_discovery, .request, .watch_view, .unwatch_view, .prioritize_entry, .promote_subtree => .normal,
            .pause_job, .resume_job, .cancel_job, .resolve_conflict, .release_borrow, .dispose_resource => .control,
        };
    }
};

pub const RoutedCommand = struct {
    window_id: WindowId,
    command: Command,
};

