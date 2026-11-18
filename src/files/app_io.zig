//! Runtime integration for the Manager-owned Files discovery service.
const std = @import("std");
const App = @import("app.zig").App;
const io_manager = @import("io_manager.zig");
const io_discovery_executor = @import("io_discovery_executor.zig");
const io_operation_executor = @import("io_operation_executor.zig");
const ViewItem = @import("app_model.zig").ViewItem;
const fold = @import("ui").fold;

/// Starts discovery for a Job whose root entry has already been added.
/// The executor is created only when discovery is first requested.
pub fn startDiscovery(
    self: *App,
    job_id: io_manager.JobId,
    root_path: []const u8,
) !void {
    const manager = if (self.io_manager) |*value| value else
        return error.DiscoveryManagerUnavailable;

    for (self.discovery_jobs.items) |existing| {
        if (existing == job_id) return error.DiscoveryAlreadyTracked;
    }
    try self.discovery_jobs.ensureUnusedCapacity(self.allocator, 1);

    if (self.discovery_executor == null) {
        self.discovery_executor = try io_discovery_executor.Executor.init(
            self.allocator,
            2,
            4,
            64,
        );
    }

    try manager.startDiscovery(job_id, root_path);
    self.discovery_jobs.appendAssumeCapacity(job_id);
}

/// Promotes the discovered directory corresponding to a newly navigated
/// filesystem path. Its descendants become promoted-subtree work.
pub fn promoteDiscoveryPath(self: *App, path: []const u8) void {
    promoteDiscoveryPathWithPriority(self, path, true);
}

/// Promotes a hovered directory and its discovered descendants.
pub fn promoteDiscoverySubtreePath(self: *App, path: []const u8) void {
    promoteDiscoveryPathWithPriority(self, path, false);
}

fn promoteDiscoveryPathWithPriority(
    self: *App,
    path: []const u8,
    foreground: bool,
) void {
    const manager = if (self.io_manager) |*value| value else return;

    for (self.discovery_jobs.items) |job_id| {
        const root_path = manager.discoveryRootPath(job_id) orelse continue;
        const tree = manager.treeIndex(job_id) orelse continue;

        for (tree.entries.items) |entry| {
            if (entry.kind != .directory) continue;
            const candidate = entryPath(
                self.allocator,
                root_path,
                tree,
                entry.id,
            ) catch continue;
            defer self.allocator.free(candidate);
            if (!std.mem.eql(u8, candidate, path)) continue;

            if (foreground) {
                manager.prioritizeDiscovery(job_id, entry.id) catch {};
            } else {
                manager.promoteDiscoverySubtree(job_id, entry.id) catch {};
            }
        }
    }
}

/// Reconciles completed batches and submits more bounded discovery work.
/// Called on the Files main thread; workers never access App or Manager.
pub fn stepDiscovery(self: *App) void {
    const executor = if (self.discovery_executor) |*value| value else return;
    const manager = if (self.io_manager) |*value| value else return;

    _ = executor.drainWake();
    const drained = executor.drainCompletions(manager) catch {
        self.setStatusNotice("Directory discovery failed", true);
        return;
    };
    if (drained > 0 and self.snapshot != null and
        self.transfer_browse_root == null)
    {
        self.rebuildView();
    }
    _ = executor.dispatchReady(manager) catch {
        self.setStatusNotice("Could not schedule directory discovery", true);
    };
}

/// Builds an owned path for an entry by walking its stable parent IDs.
/// The root entry itself maps to the original filesystem root path.
fn entryPath(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    tree: anytype,
    entry_id: u64,
) ![]u8 {
    var components: std.ArrayList([]const u8) = .empty;
    defer components.deinit(allocator);

    var current_id = entry_id;
    while (true) {
        const entry = tree.getConst(current_id) orelse return error.UnknownEntry;
        const parent_id = entry.parent_id orelse break;
        try components.append(allocator, entry.name);
        current_id = parent_id;
    }

    var result = try allocator.dupe(u8, root_path);
    errdefer allocator.free(result);
    var index = components.items.len;
    while (index > 0) {
        index -= 1;
        const next = try std.fs.path.join(allocator, &.{ result, components.items[index] });
        allocator.free(result);
        result = next;
    }
    return result;
}

/// Adds newly discovered direct children to the current listing. Existing
/// snapshot rows win, so this projection never duplicates normal filesystem
/// entries or changes their richer metadata.
pub fn appendDiscoveryRows(
    self: *App,
    mem: std.mem.Allocator,
    old: *const std.StringHashMap(ViewItem),
) void {
    if (self.chooser != null or self.transfer_view.active or
        self.history.archive_len > 0 or self.isRecent() or self.changedOnly())
        return;

    const manager = if (self.io_manager) |*value| value else return;

    for (self.discovery_jobs.items) |job_id| {
        const root_path = manager.discoveryRootPath(job_id) orelse continue;
        const tree = manager.treeIndex(job_id) orelse continue;
        _ = tree.root() orelse continue;

        for (tree.entries.items) |entry| {
            const parent_id = entry.parent_id orelse continue;
            const parent_path = entryPath(
                mem,
                root_path,
                tree,
                parent_id,
            ) catch continue;
            defer mem.free(parent_path);
            if (!std.mem.eql(u8, parent_path, self.history.current)) continue;

            const path = std.fs.path.join(mem, &.{ parent_path, entry.name }) catch continue;
            var duplicate = false;
            for (self.items.items) |existing| {
                if (std.mem.eql(u8, existing.path, path)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;

            const is_dir = entry.kind == .directory;
            if (self.folders_only and !is_dir) continue;
            if (!fold.contains(entry.name, self.search.text.items, .{
                .turkish = @import("i18n").isTurkish(),
            })) continue;

            const previous = old.get(path);
            self.items.append(self.allocator, .{
                .name = mem.dupe(u8, entry.name) catch continue,
                .path = path,
                .is_dir = is_dir,
                .is_symlink = entry.kind == .symlink,
                .is_broken = false,
                .bytes = @intCast(@min(entry.metadata.size, std.math.maxInt(i64))),
                .mtime = entry.metadata.mtime_sec,
                .mode = @intCast(entry.metadata.mode),
                .icon_name = if (is_dir) "folder" else "text-x-generic",
                .selected = if (previous) |item| item.selected else false,
                .selection_fill = if (previous) |item| item.selection_fill else .{},
                .selection_border = if (previous) |item| item.selection_border else .{},
            }) catch continue;
        }
    }
}

/// Poll descriptor for worker completions, or -1 before discovery is used.
pub fn discoveryWakeFd(self: *App) i32 {
    const executor = if (self.discovery_executor) |*value| value else return -1;
    return @intCast(executor.wakeFd());
}

/// Starts the bounded operation Runtime on first use.
pub fn startOperations(self: *App) !void {
    if (self.operation_executor != null) return;
    const manager = if (self.io_manager) |*value| value else
        return error.OperationManagerUnavailable;

    self.operation_executor = try io_operation_executor.Runtime.init(
        self.allocator,
        manager,
        2,
        4,
    );
}

/// Drains completed operations and submits newly ready work on the main thread.
pub fn stepOperations(self: *App) void {
    const executor = if (self.operation_executor) |*value| value else return;
    const manager = if (self.io_manager) |*value| value else return;

    _ = executor.drainWake();
    _ = executor.drainCompletions() catch {
        self.setStatusNotice("File operation completion failed", true);
        return;
    };
    _ = executor.dispatchReady() catch {
        self.setStatusNotice("Could not schedule file operation", true);
    };

    if (self.active_io_copy_job) |job_id| {
        if (manager.jobState(job_id)) |state| {
            if (state.isTerminal()) {
                const destination = self.active_io_copy_destination;
                self.active_io_copy_destination = null;
                self.active_io_copy_job = null;

                switch (state) {
                    .completed => self.setStatusNotice("File copied", false),
                    .completed_with_errors, .failed =>
                        self.setStatusNotice("File copy failed", true),
                    .cancelled => self.setStatusNotice("File copy cancelled", true),
                    else => unreachable,
                }

                if (destination) |path| {
                    const refresh_destination =
                        std.mem.eql(u8, self.history.current, path);
                    self.allocator.free(path);
                    if (refresh_destination) self.refresh();
                }
            }
        }
    }
}

/// Poll descriptor for operation completions, or -1 before first use.
pub fn operationWakeFd(self: *App) i32 {
    const executor = if (self.operation_executor) |*value| value else return -1;
    return @intCast(executor.wakeFd());
}
