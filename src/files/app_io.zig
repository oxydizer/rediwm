//! Runtime integration for the Manager-owned Files discovery service.
const std = @import("std");
const App = @import("app.zig").App;
const io_manager = @import("io_manager.zig");
const io_tree = @import("io_tree.zig");
const io_discovery = @import("io_discovery.zig");
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
    const manager = if (self.io_manager) |value| value else return error.DiscoveryManagerUnavailable;

    for (self.discovery_jobs.items) |existing| {
        if (existing == job_id) return error.DiscoveryAlreadyTracked;
    }
    try self.discovery_jobs.ensureUnusedCapacity(self.allocator, 1);

    const runtime = self.io_runtime orelse return error.DiscoveryManagerUnavailable;
    self.discovery_executor = try runtime.ensureDiscoveryExecutor();

    try manager.startDiscovery(job_id, root_path);
    self.discovery_jobs.appendAssumeCapacity(job_id);
}

/// Atomically queues a multi-root directory Job and tracks it for discovery.
pub fn startDiscoveryRoots(
    self: *App,
    job_id: io_manager.JobId,
    roots: []const io_manager.DiscoveryRoot,
) !void {
    const manager = if (self.io_manager) |value| value else return error.DiscoveryManagerUnavailable;

    for (self.discovery_jobs.items) |existing| {
        if (existing == job_id) return error.DiscoveryAlreadyTracked;
    }
    try self.discovery_jobs.ensureUnusedCapacity(self.allocator, 1);

    const runtime = self.io_runtime orelse return error.DiscoveryManagerUnavailable;
    self.discovery_executor = try runtime.ensureDiscoveryExecutor();

    try manager.queueJobWithDiscoveryRoots(job_id, roots);
    self.discovery_jobs.appendAssumeCapacity(job_id);
}

/// Gives the active copy Job a one-shot preference for a hovered transfer
/// ghost. The Manager retains the preference after pointer leave.
pub fn prioritizeTransferEntry(self: *App, entry_id: io_tree.EntryId) bool {
    const job_id = self.active_io_copy_job orelse return false;
    const manager = self.io_manager orelse return false;
    return manager.prioritizeEntryOperation(job_id, entry_id);
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
    const manager = if (self.io_manager) |value| value else return;

    for (self.discovery_jobs.items) |job_id| {
        const tree = manager.treeIndex(job_id) orelse continue;

        for (tree.entries.items) |entry| {
            if (entry.kind != .directory) continue;
            const root_id = tree.rootForEntry(entry.id) orelse continue;
            const root_path = manager.discoveryRootPath(
                job_id,
                root_id,
            ) orelse continue;
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
    const executor = if (self.discovery_executor) |value| value else return;
    const manager = if (self.io_manager) |value| value else return;

    _ = executor.drainWake();
    const drained = executor.drainCompletions(manager) catch {
        self.setStatusNotice("Directory discovery failed", true);
        return;
    };
    if (drained > 0) {
        if (self.active_io_copy_job != null) {
            self.transfer_tree_state.markDirty();
            self.transfer_rows_dirty = true;
        }
        if (self.snapshot != null and self.transfer_browse_root == null and
            self.active_io_copy_job == null)
        {
            self.rebuildView();
        }
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

    const manager = if (self.io_manager) |value| value else return;

    for (self.discovery_jobs.items) |job_id| {
        const tree = manager.treeIndex(job_id) orelse continue;
        _ = tree.root() orelse continue;

        for (tree.entries.items) |entry| {
            const parent_id = entry.parent_id orelse continue;
            const root_id = tree.rootForEntry(parent_id) orelse continue;
            const root_path = manager.discoveryRootPath(
                job_id,
                root_id,
            ) orelse continue;
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
    const executor = if (self.discovery_executor) |value| value else return -1;
    return @intCast(executor.wakeFd());
}

/// Starts the bounded operation Runtime on first use.
pub fn startOperations(self: *App) !void {
    if (self.operation_executor != null) return;
    const runtime = self.io_runtime orelse return error.OperationManagerUnavailable;
    self.operation_executor = try runtime.ensureOperationExecutor();
}

/// Tracks an archive operation whose worker result will hand off a staging
/// lease to the main-thread publication scanner.
pub fn trackArchivePublication(
    self: *App,
    job_id: io_manager.JobId,
    operation_id: io_manager.OperationId,
) !void {
    for (self.archive_publications.items) |publication| {
        if (publication.job_id == job_id and
            publication.operation_id == operation_id)
            return error.ArchivePublicationAlreadyTracked;
    }
    try self.archive_publications.append(self.allocator, .{
        .job_id = job_id,
        .operation_id = operation_id,
    });
}

fn closeArchivePublicationCursor(publication: *App.ArchivePublication) void {
    if (publication.cursor) |*cursor| cursor.deinit();
    publication.cursor = null;
}

fn failArchivePublication(
    self: *App,
    manager: *io_manager.Manager,
    publication: *App.ArchivePublication,
) void {
    closeArchivePublicationCursor(publication);
    if (publication.registration_closed) return;
    const token = publication.token orelse return;
    manager.failArchivePublication(token) catch {
        self.setStatusNotice("Could not close archive publication after an error", true);
        return;
    };
    publication.registration_closed = true;
}

/// Extracts one selected archive member, opens it on the main thread, and
/// completes its publication barrier without publishing it into the folder.
fn stepArchiveMemberExtractions(
    self: *App,
    manager: *io_manager.Manager,
    executor: *io_operation_executor.Runtime,
) void {
    var index: usize = 0;
    while (index < self.archive_member_extractions.items.len) {
        const extraction = &self.archive_member_extractions.items[index];
        const state = manager.jobState(extraction.job_id);
        if (state == null or state.?.isTerminal()) {
            _ = executor.discardArchiveStaging(
                extraction.job_id,
                extraction.operation_id,
            ) catch {
                self.setStatusNotice("Could not remove archive staging data", true);
                index += 1;
                continue;
            };
            _ = self.archive_member_extractions.orderedRemove(index);
            continue;
        }

        if (extraction.token == null) {
            extraction.token = executor.archiveStagingToken(
                extraction.job_id,
                extraction.operation_id,
            );
            if (extraction.token == null) {
                index += 1;
                continue;
            }
        }

        const token = extraction.token.?;
        if (!extraction.registration_closed) {
            const details = manager.archiveOperationDetails(token) orelse {
                index += 1;
                continue;
            };
            const staging_path = executor.archiveStagingPath(token) orelse {
                manager.failArchivePublication(token) catch {};
                extraction.registration_closed = true;
                index += 1;
                continue;
            };
            const member_path = details.member_path orelse {
                manager.failArchivePublication(token) catch {};
                extraction.registration_closed = true;
                index += 1;
                continue;
            };
            const extracted_path = std.fs.path.join(
                self.allocator,
                &.{ staging_path, member_path },
            ) catch {
                manager.failArchivePublication(token) catch {};
                extraction.registration_closed = true;
                index += 1;
                continue;
            };
            defer self.allocator.free(extracted_path);

            if (self.navigation_count == extraction.navigation_count) {
                if (!self.openExtracted(extracted_path, extraction.preview)) {
                    manager.failArchivePublication(token) catch {};
                    extraction.registration_closed = true;
                    index += 1;
                    continue;
                }
                extraction.opened = true;
                self.active_io_copy_archive_member_opened = true;
            }

            manager.closeArchivePublication(token) catch {
                manager.failArchivePublication(token) catch {};
                extraction.registration_closed = true;
                index += 1;
                continue;
            };
            extraction.registration_closed = true;
        }

        if (extraction.registration_closed and
            manager.archivePublicationReady(token) == true)
        {
            // A successfully opened member keeps its lease for the viewer or
            // editor. A member skipped because navigation changed is cleaned.
            if (!extraction.opened) {
                const released = executor.releaseArchiveStaging(token) catch {
                    self.setStatusNotice("Could not remove archive staging data", true);
                    index += 1;
                    continue;
                };
                if (!released) {
                    index += 1;
                    continue;
                }
            }
            if (!manager.completeArchivePublication(token)) {
                self.setStatusNotice("Could not complete archive member extraction", true);
                index += 1;
                continue;
            }
            _ = self.archive_member_extractions.orderedRemove(index);
            continue;
        }
        index += 1;
    }
}

/// Materializes selected archive members for clipboard or drag export.
/// The staging lease remains App-owned until the destination owner takes it.
fn stepArchiveExports(
    self: *App,
    manager: *io_manager.Manager,
    executor: *io_operation_executor.Runtime,
) void {
    var index: usize = 0;
    while (index < self.archive_exports.items.len) {
        const extraction = &self.archive_exports.items[index];
        const state = manager.jobState(extraction.job_id);
        if (state == null or state.?.isTerminal()) {
            if (extraction.staging_lease) |*lease| {
                lease.deinit();
                extraction.staging_lease = null;
            }
            _ = executor.discardArchiveStaging(
                extraction.job_id,
                extraction.operation_id,
            ) catch {
                self.setStatusNotice("Could not remove archive staging data", true);
                index += 1;
                continue;
            };
            for (extraction.member_paths.items) |path| self.allocator.free(path);
            extraction.member_paths.deinit(self.allocator);
            _ = self.archive_exports.orderedRemove(index);
            continue;
        }

        if (extraction.token == null) {
            extraction.token = executor.archiveStagingToken(
                extraction.job_id,
                extraction.operation_id,
            );
            if (extraction.token == null) {
                index += 1;
                continue;
            }
        }

        const token = extraction.token.?;
        if (!extraction.registration_closed) {
            manager.closeArchivePublication(token) catch {
                manager.failArchivePublication(token) catch {
                    self.setStatusNotice(
                        "Could not close archive clipboard publication",
                        true,
                    );
                    index += 1;
                    continue;
                };
            };
            extraction.registration_closed = true;
        }

        if (manager.archivePublicationReady(token) != true) {
            index += 1;
            continue;
        }

        if (extraction.staging_lease == null) {
            extraction.staging_lease = executor.takeArchiveStaging(token);
            if (extraction.staging_lease == null) {
                self.setStatusNotice("Could not retain archive staging data", true);
                index += 1;
                continue;
            }
        }

        var staged_paths: std.ArrayList([]const u8) = .empty;
        var paths_failed = false;
        for (extraction.member_paths.items) |member| {
            const path = std.fs.path.join(
                self.allocator,
                &.{ extraction.staging_lease.?.path, member },
            ) catch {
                paths_failed = true;
                break;
            };
            staged_paths.append(self.allocator, path) catch {
                self.allocator.free(path);
                paths_failed = true;
                break;
            };
        }

        if (!paths_failed and
            staged_paths.items.len == extraction.member_paths.items.len)
        {
            switch (extraction.purpose) {
                .clipboard => self.clipboard_paths.ensureUnusedCapacity(
                    self.allocator,
                    staged_paths.items.len,
                ) catch {
                    paths_failed = true;
                },
                .drag => {},
                .open_with => self.archive_open_with_leases.ensureUnusedCapacity(
                    self.allocator,
                    1,
                ) catch {
                    paths_failed = true;
                },
            }
        } else {
            paths_failed = true;
        }

        if (paths_failed) {
            for (staged_paths.items) |path| self.allocator.free(path);
            staged_paths.deinit(self.allocator);
            if (!manager.completeArchivePublication(token)) {
                index += 1;
                continue;
            }
            if (extraction.staging_lease) |*lease| lease.deinit();
            extraction.staging_lease = null;
            self.setStatusNotice(
                switch (extraction.purpose) {
                    .clipboard => "Could not prepare archive clipboard paths",
                    .drag => "Could not prepare archive drag",
                    .open_with => "Could not prepare archive members for Open With",
                },
                true,
            );
            for (extraction.member_paths.items) |path| self.allocator.free(path);
            extraction.member_paths.deinit(self.allocator);
            _ = self.archive_exports.orderedRemove(index);
            continue;
        }

        if (!manager.completeArchivePublication(token)) {
            for (staged_paths.items) |path| self.allocator.free(path);
            staged_paths.deinit(self.allocator);
            self.setStatusNotice("Could not complete archive export", true);
            index += 1;
            continue;
        }

        const completed_state = manager.jobState(extraction.job_id);
        if (completed_state != .completed) {
            for (staged_paths.items) |path| self.allocator.free(path);
            staged_paths.deinit(self.allocator);
            if (extraction.staging_lease) |*lease| lease.deinit();
            extraction.staging_lease = null;
            self.setStatusNotice("Archive export failed", true);
            for (extraction.member_paths.items) |path| self.allocator.free(path);
            extraction.member_paths.deinit(self.allocator);
            _ = self.archive_exports.orderedRemove(index);
            continue;
        }

        const lease = extraction.staging_lease.?;
        extraction.staging_lease = null;
        switch (extraction.purpose) {
            .clipboard => {
                self.clearClipboard();
                for (staged_paths.items) |path|
                    self.clipboard_paths.appendAssumeCapacity(path);
                staged_paths.deinit(self.allocator);
                self.clipboard_staging_lease = lease;
                self.clipboard_is_text = false;
                self.clipboard_cut = false;
                self.clipboard_revision += 1;
            },
            .drag => {
                if (self.archive_drag_export) |*old_export| old_export.deinit();
                self.archive_drag_export = .{
                    .allocator = self.allocator,
                    .paths = staged_paths,
                    .staging_lease = lease,
                };
            },
            .open_with => {
                if (self.openWithPaths(staged_paths.items, true)) {
                    self.archive_open_with_leases.appendAssumeCapacity(lease);
                } else {
                    var failed_lease = lease;
                    failed_lease.deinit();
                }
                for (staged_paths.items) |path| self.allocator.free(path);
                staged_paths.deinit(self.allocator);
            },
        }

        for (extraction.member_paths.items) |path| self.allocator.free(path);
        extraction.member_paths.deinit(self.allocator);
        _ = self.archive_exports.orderedRemove(index);
    }
}

/// Scans at most 64 top-level staging entries per main-loop pass, then drains
/// the Manager barrier before releasing the staging lease.
fn stepArchivePublications(
    self: *App,
    manager: *io_manager.Manager,
    executor: *io_operation_executor.Runtime,
) void {
    var index: usize = 0;
    while (index < self.archive_publications.items.len) {
        const publication = &self.archive_publications.items[index];
        if (manager.jobState(publication.job_id)) |state| {
            if (state.isTerminal()) {
                closeArchivePublicationCursor(publication);
                _ = executor.discardArchiveStaging(
                    publication.job_id,
                    publication.operation_id,
                ) catch {
                    self.setStatusNotice("Could not remove archive staging data", true);
                    index += 1;
                    continue;
                };
                _ = self.archive_publications.orderedRemove(index);
                continue;
            }
        }
        if (publication.token == null) {
            publication.token = executor.archiveStagingToken(
                publication.job_id,
                publication.operation_id,
            );
            if (publication.token == null) {
                if (manager.jobState(publication.job_id)) |state| {
                    if (state.isTerminal()) {
                        _ = self.archive_publications.orderedRemove(index);
                        continue;
                    }
                }
                index += 1;
                continue;
            }
        }

        const token = publication.token.?;
        if (!publication.registration_closed) {
            if (publication.cursor == null) {
                const staging_path = executor.archiveStagingPath(token) orelse {
                    failArchivePublication(self, manager, publication);
                    index += 1;
                    continue;
                };
                const zpath = self.allocator.dupeSentinel(u8, staging_path, 0) catch {
                    failArchivePublication(self, manager, publication);
                    index += 1;
                    continue;
                };
                defer self.allocator.free(zpath);
                publication.cursor = io_discovery.Cursor.open(zpath) catch {
                    failArchivePublication(self, manager, publication);
                    index += 1;
                    continue;
                };
            }

            var batch = publication.cursor.?.nextBatch(self.allocator, 64) catch {
                failArchivePublication(self, manager, publication);
                index += 1;
                continue;
            };
            defer batch.deinit();

            var registration_failed = false;
            for (batch.records.items) |record| {
                if (record.entry_error or record.kind == .other) {
                    registration_failed = true;
                    break;
                }

                // Directory roots schedule discovery as part of registration.
                // Ensure the App has an executor ready to drain that work.
                if (record.kind == .directory and self.discovery_executor == null) {
                    const runtime = self.io_runtime orelse {
                        registration_failed = true;
                        break;
                    };
                    self.discovery_executor = runtime.ensureDiscoveryExecutor() catch {
                        registration_failed = true;
                        break;
                    };
                }

                const staging_path = executor.archiveStagingPath(token) orelse {
                    registration_failed = true;
                    break;
                };
                const source_path = std.fs.path.join(
                    self.allocator,
                    &.{ staging_path, record.name },
                ) catch {
                    registration_failed = true;
                    break;
                };
                defer self.allocator.free(source_path);

                _ = manager.addArchivePublicationRoot(token, .{
                    .name = record.name,
                    .source_path = source_path,
                    .kind = record.kind,
                    .metadata = record.metadata,
                    .symlink_target = record.symlink_target,
                }) catch {
                    registration_failed = true;
                    break;
                };
            }

            if (registration_failed) {
                failArchivePublication(self, manager, publication);
            } else if (batch.complete) {
                closeArchivePublicationCursor(publication);
                manager.closeArchivePublication(token) catch {
                    failArchivePublication(self, manager, publication);
                    index += 1;
                    continue;
                };
                publication.registration_closed = true;
            }
        }

        if (publication.registration_closed and
            manager.archivePublicationReady(token) == true)
        {
            const released = executor.releaseArchiveStaging(token) catch {
                self.setStatusNotice("Could not remove archive staging data", true);
                index += 1;
                continue;
            };
            if (!released) {
                index += 1;
                continue;
            }
            if (!manager.completeArchivePublication(token)) {
                self.setStatusNotice("Could not complete archive publication", true);
                index += 1;
                continue;
            }
            _ = self.archive_publications.orderedRemove(index);
            continue;
        }
        index += 1;
    }

    // Root registration above can enqueue discovery after stepDiscovery()
    // has already run for this main-loop pass. Dispatch it now, before the
    // main thread can enter its wake-FD poll.
    if (self.discovery_executor) |discovery| {
        _ = discovery.dispatchReady(manager) catch {
            self.setStatusNotice("Could not schedule archive directory discovery", true);
        };
    }
}

/// Removes only successfully moved roots from the matching cut clipboard.
/// Skipped and failed roots remain available for a later paste.
fn updateMovedClipboard(
    self: *App,
    manager: *io_manager.Manager,
    job_id: io_manager.JobId,
) void {
    if (!self.clipboard_cut or self.clipboard_is_text or
        self.job_cut_revision != self.clipboard_revision)
    {
        return;
    }

    const tree = manager.treeIndex(job_id) orelse return;
    var changed = false;
    for (tree.roots()) |root_id| {
        const operation_state = manager.sourceDetachOperationState(job_id, root_id) orelse
            (manager.entryOperationView(job_id, root_id) orelse continue).state;
        if (operation_state != .completed) continue;

        const source = manager.sourcePath(self.allocator, job_id, root_id) catch continue;
        defer self.allocator.free(source);
        var index: usize = 0;
        while (index < self.clipboard_paths.items.len) {
            if (std.mem.eql(u8, self.clipboard_paths.items[index], source)) {
                self.allocator.free(self.clipboard_paths.orderedRemove(index));
                changed = true;
            } else {
                index += 1;
            }
        }
    }

    if (self.clipboard_paths.items.len == 0) self.clipboard_cut = false;
    if (changed) self.clipboard_revision += 1;
}

/// Drains completed operations and submits newly ready work on the main thread.
pub fn stepOperations(self: *App) void {
    const executor = if (self.operation_executor) |value| value else return;
    const manager = if (self.io_manager) |value| value else return;

    _ = executor.drainWake();
    const drained = executor.drainCompletionsWithStats() catch {
        self.setStatusNotice("File operation completion failed", true);
        return;
    };
    if (drained.drained > 0 and self.active_io_copy_job != null) {
        self.transfer_tree_state.markDirty();
    }
    if (drained.state_changes > 0 and self.active_io_copy_job != null) {
        self.transfer_rows_dirty = true;
    }
    stepArchiveExports(self, manager, executor);
    stepArchiveMemberExtractions(self, manager, executor);
    stepArchivePublications(self, manager, executor);
    _ = executor.dispatchReady() catch {
        self.setStatusNotice("Could not schedule file operation", true);
    };

    if (self.active_io_copy_job) |job_id| {
        if (manager.treeIndex(job_id)) |tree| {
            for (tree.entries.items) |entry| {
                const operation = manager.entryOperationView(job_id, entry.id) orelse
                    continue;
                if (operation.copy_phase != .flushing or
                    (operation.state != .pending and operation.state != .running))
                {
                    continue;
                }
                const message = @import("i18n").tr("Flushing to storage…");
                if (self.status_notice == null or
                    !std.mem.eql(u8, self.status_notice.?, message))
                {
                    self.setStatusNotice(message, false);
                } else {
                    self.status_notice_until = @import("app_draw.zig").nowMs() + 4000;
                }
                break;
            }
        }
    }

    // Only one conflict dialog is visible globally. Leave other modal
    // dialogs untouched and present the FIFO head as soon as the UI is free.
    if (self.dialog == null) {
        if (manager.nextConflict()) |conflict| {
            self.openManagerConflictDialog(
                conflict.id,
                std.fs.path.basename(conflict.destination_path),
            );
        }
    }

    if (self.active_io_copy_job) |job_id| {
        if (manager.jobState(job_id)) |state| {
            if (state.isTerminal()) {
                const destination = self.active_io_copy_destination;
                const is_directory = self.active_io_copy_is_directory;
                const is_move = self.active_io_copy_is_move;
                const is_archive = self.active_io_copy_is_archive;
                const is_archive_member = self.active_io_copy_is_archive_member;
                const is_archive_clipboard = self.active_io_copy_is_archive_clipboard;
                const is_archive_drag = self.active_io_copy_is_archive_drag;
                const is_archive_open_with = self.active_io_copy_is_archive_open_with;
                const archive_member_opened =
                    self.active_io_copy_archive_member_opened;
                const multiple_items = self.active_io_copy_item_count > 1;
                if (is_move) updateMovedClipboard(self, manager, job_id);
                self.active_io_copy_destination = null;
                self.active_io_copy_job = null;
                // Removing the Transfers card can shorten the sidebar while
                // it is scrolled. Clamp the saved offset against the new
                // content extent, and retarget an in-flight sidebar glide.
                self.clampSidebarScroll();
                if (self.wheel_sidebar) self.cancelWheel();
                self.active_io_copy_is_directory = false;
                self.active_io_copy_is_move = false;
                self.active_io_copy_is_archive = false;
                self.active_io_copy_is_archive_member = false;
                self.active_io_copy_is_archive_clipboard = false;
                self.active_io_copy_is_archive_drag = false;
                self.active_io_copy_is_archive_open_with = false;
                self.active_io_copy_archive_member_opened = false;
                self.active_io_copy_item_count = 0;
                self.job_cut_revision = null;

                if (is_archive) {
                    switch (state) {
                        .completed => self.setStatusNotice("Archive extracted", false),
                        .completed_with_errors, .failed => self.setStatusNotice(
                            "Could not extract archive",
                            true,
                        ),
                        .cancelled => self.setStatusNotice(
                            "Archive extraction cancelled",
                            true,
                        ),
                        else => unreachable,
                    }
                } else if (is_archive_clipboard) {
                    switch (state) {
                        .completed => self.setStatusNotice("Archive members copied to clipboard", false),
                        .completed_with_errors, .failed => self.setStatusNotice(
                            "Could not copy archive members",
                            true,
                        ),
                        .cancelled => self.setStatusNotice(
                            "Archive clipboard copy cancelled",
                            true,
                        ),
                        else => unreachable,
                    }
                } else if (is_archive_drag) {
                    switch (state) {
                        .completed => self.setStatusNotice("Archive members ready for drag", false),
                        .completed_with_errors, .failed => self.setStatusNotice(
                            "Could not prepare archive drag",
                            true,
                        ),
                        .cancelled => self.setStatusNotice(
                            "Archive drag cancelled",
                            true,
                        ),
                        else => unreachable,
                    }
                } else if (is_archive_open_with) {
                    switch (state) {
                        .completed => {},
                        .completed_with_errors, .failed => self.setStatusNotice(
                            "Could not prepare archive members for Open With",
                            true,
                        ),
                        .cancelled => self.setStatusNotice(
                            "Preparing archive members for Open With cancelled",
                            true,
                        ),
                        else => unreachable,
                    }
                } else if (is_archive_member) {
                    switch (state) {
                        .completed => self.setStatusNotice(
                            if (archive_member_opened)
                                "Archive member opened"
                            else
                                "Archive member is no longer in this view",
                            false,
                        ),
                        .completed_with_errors, .failed => self.setStatusNotice(
                            "Could not open archive member",
                            true,
                        ),
                        .cancelled => self.setStatusNotice(
                            "Archive member opening cancelled",
                            true,
                        ),
                        else => unreachable,
                    }
                } else switch (state) {
                    .completed => {
                        if (manager.jobHasSkippedOperations(job_id)) {
                            self.setStatusNotice(
                                if (multiple_items) "Some items skipped" else if (is_move and is_directory) "Folder move skipped" else if (is_move) "File move skipped" else if (is_directory) "Folder copy skipped" else "File copy skipped",
                                false,
                            );
                        } else {
                            self.setStatusNotice(
                                if (multiple_items) (if (is_move) "Items moved" else "Items copied") else if (is_move and is_directory) "Folder moved" else if (is_move) "File moved" else if (is_directory) "Folder copied" else "File copied",
                                false,
                            );
                        }
                    },
                    .completed_with_errors, .failed => self.setStatusNotice(if (multiple_items)
                        (if (is_move) "Could not move all items" else "Could not copy all items")
                    else if (is_move and is_directory)
                        "Folder move failed"
                    else if (is_move)
                        "File move failed"
                    else if (is_directory)
                        "Folder copy failed"
                    else
                        "File copy failed", true),
                    .cancelled => self.setStatusNotice(if (multiple_items)
                        (if (is_move) "Items move cancelled" else "Items copy cancelled")
                    else if (is_move and is_directory)
                        "Folder move cancelled"
                    else if (is_move)
                        "File move cancelled"
                    else if (is_directory)
                        "Folder copy cancelled"
                    else
                        "File copy cancelled", true),
                    else => unreachable,
                }

                if (destination) |path| {
                    var refresh_listing =
                        std.mem.eql(u8, self.history.current, path);

                    if (is_move and !refresh_listing) {
                        if (manager.treeIndex(job_id)) |tree| {
                            for (tree.roots()) |root_id| {
                                const source_path = manager.sourcePath(
                                    self.allocator,
                                    job_id,
                                    root_id,
                                ) catch continue;
                                const source_parent =
                                    std.fs.path.dirname(source_path) orelse "";
                                const source_is_current =
                                    std.mem.eql(u8, self.history.current, source_parent);
                                self.allocator.free(source_path);
                                if (source_is_current) {
                                    refresh_listing = true;
                                    break;
                                }
                            }
                        }
                    }

                    self.allocator.free(path);
                    if (refresh_listing) self.refresh();
                }
            }
        }
    }
}

/// Poll descriptor for operation completions, or -1 before first use.
pub fn operationWakeFd(self: *App) i32 {
    const executor = if (self.operation_executor) |value| value else return -1;
    return @intCast(executor.wakeFd());
}
