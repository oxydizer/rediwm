//! Files listing: navigation, history moves, snapshot sync and the filtered, sorted view.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const anim = @import("ui").anim;
const c = @import("c.zig").api;
const worker_mod = @import("worker.zig");
const recent = @import("recent.zig");
const collation = @import("collation.zig");
const fold = @import("ui").fold;
const icons = @import("../icon_cache.zig");
const theme = @import("../icon_theme.zig");
const header = @import("header.zig");
const shell_ui = @import("ui").cairo;
const ui_theme = @import("ui").theme;
const chooser_mod = @import("chooser.zig");
const Sort = @import("app_model.zig").Sort;
const ViewItem = @import("app_model.zig").ViewItem;
const nowMs = @import("app_draw.zig").nowMs;
const setSource = @import("app_draw.zig").setSource;
const withAlpha = @import("app_draw.zig").withAlpha;
const drawEllipsis = @import("app_draw.zig").drawEllipsis;
const measureText = @import("app_draw.zig").measureText;
const formatPermissions = @import("app_draw.zig").formatPermissions;

pub fn navigate(self: *App, new_path: []const u8) void {
    if (!self.recentAvailable() and recent.isLocation(new_path)) return;
    self.rememberView();
    self.history.navigate(new_path) catch return;
    self.applyHistoryNav(self.history.current);
}

pub fn refresh(self: *App) void {
    self.clearFolderSizes();
    self.beginLoading();
    self.active_request_id = self.worker.refresh();
    self.invalidate();
}

pub fn toggleHidden(self: *App) void {
    self.show_hidden = !self.show_hidden;
    self.beginLoading();
    self.active_request_id = self.worker.setShowHidden(self.show_hidden);
    self.invalidate();
}

pub fn selectOnLoad(self: *App, path: []const u8) void {
    self.initial_selection = path;
    if (std.mem.startsWith(u8, std.fs.path.basename(path), ".")) self.toggleHidden();
}

pub fn back(self: *App) void {
    if (self.transfer_view.active) {
        self.leaveTransfers();
        return;
    }
    self.rememberView();
    if (self.history.back() catch null) |path| {
        self.applyHistoryNav(path);
    }
}

pub fn forward(self: *App) void {
    self.rememberView();
    if (self.history.forward() catch null) |path| {
        self.applyHistoryNav(path);
    }
}

pub fn up(self: *App) void {
    self.rememberView();
    if (self.history.up() catch null) |path| {
        self.applyHistoryNav(path);
    }
}

pub fn home(self: *App) void {
    self.rememberView();
    if (self.history.home(self.home_dir) catch null) |path| {
        self.applyHistoryNav(path);
    }
}

pub fn applyHistoryNav(self: *App, path: []const u8) void {
    self.leaveTransfers();
    self.navigation_count +%= 1;
    self.overwrite_pending = false;
    if (self.chooser != null and self.chooser.?.mode == .open) self.setChooserName("");
    self.cancelWheel();
    self.cancelDrag();
    self.cancelRunningFolderSizes();
    self.restore_view = true;
    self.edit_revision += 1;
    self.text_dragging = false;
    self.updateTitle();
    self.menu = null;
    self.search.text.clearRetainingCapacity();
    self.search.cursor = 0;
    self.search_visible = false;
    self.items.clearRetainingCapacity();
    if (self.snapshot) |snap| snap.destroy();
    self.snapshot = null;
    self.scroll_y = 0;
    self.selection_anchor = null;
    self.focused_index = null;
    self.beginLoading();
    self.error_message = null;

    self.location.text.clearRetainingCapacity();
    self.location.text.appendSlice(self.allocator, path) catch {};
    self.location.cursor = self.location.text.items.len;
    self.location.select_all = false;
    self.location.anchor = self.location.cursor;
    self.location.scroll = 0;

    self.active_request_id = self.worker.navigateLocation(path, self.show_hidden, self.history.archive_len);
    self.invalidate();
}

// A navigate()/refresh()/toggleHidden() call bumps active_request_id and
// tags the worker request with it; the worker may still be finishing a
// scan for an earlier request when the new one lands. Applying that
// snapshot anyway would flash the previous directory's listing (or an
// empty/error state from a request that's since been superseded).
pub fn isStaleSnapshot(snapshot_request_id: u64, active_request_id: u64) bool {
    return snapshot_request_id < active_request_id;
}

/// Damage only the surfaces that display file-operation byte progress.
/// Structural changes still use invalidate(), because they can change layout.
fn damageJobProgress(
    self: *App,
    damage_surfaces: bool,
    damage_tooltip: bool,
) void {
    if (damage_surfaces) {
        if (self.transfer_view.active) {
            // The file operation is the final row in the Transfers hub.
            const row = @import("app_torrents.zig").fileOperationRowRect(
                self,
                self.torrents.items().len,
            );
            self.addDamageRegion(self.clipToViewport(row));
        } else if (self.job_runner) |runner| {
        // Parent-folder progress rings are drawn inside visible item icons.
            const columns = self.columns();
            const first = @divTrunc(self.scroll_y, self.rowHeight()) * columns;
            const last = @min(
                @as(i32, @intCast(self.items.items.len)),
                (@divTrunc(
                    self.scroll_y + @max(0, self.contentBottom() - self.viewTop()),
                    self.rowHeight(),
                ) + 1) * columns,
            );

            var index = first;
            while (index < last) : (index += 1) {
                const item = self.items.items[@intCast(index)];
                if (!item.is_dir or item.is_symlink) continue;
                if (runner.progressForPath(item.path) == null) continue;

                const icon = self.itemIconRect(index);
                const ring_size = @min(26.0, icon.w);
                self.addDamageRegion(self.clipToViewport(.{
                    .x = icon.x + (icon.w - ring_size) / 2 - 2,
                    .y = icon.y + (icon.w - ring_size) / 2 - 2,
                    .w = ring_size + 4,
                    .h = ring_size + 4,
                }));
            }
        }

        // The sidebar progress row remains visible alongside either main view.
        const transfers = self.sidebarLayout().cards[
            @intFromEnum(@import("app_model.zig").SidebarSection.transfers)
        ];
        if (transfers.visible and transfers.expanded and self.sidebarWidth() > 0) {
            const area = @import("app_sidebar_paint.zig").fileOpsBox(self);
            if (area.w >= 120) {
                self.addDamageRegion(.{
                    .x = @floatCast(area.x),
                    .y = @floatCast(area.y),
                    .w = @floatCast(area.w),
                    .h = @floatCast(area.h),
                });
            }
        }
    }

    // The tooltip is the only other consumer of the live byte/rate counters.
    if (damage_tooltip) {
        if (@import("app_transfer_tip.zig").bounds(
            self.w,
            self.h,
            self.mouse_x,
            self.mouse_y,
            2,
        )) |rect| {
            self.addDamageRegion(rect);
        }
    }
}

pub fn sync(self: *App) void {
    if (self.worker.takeApplicationNotice()) |notice| self.setStatusNotice(notice.message, notice.failed);
    if (self.worker.takeThemeNotice()) |notice| {
        defer self.worker.allocator.free(notice);
        self.setStatusNotice(notice, false);
    }
    self.syncFolderSizes();
    if (self.dialog) |*dlg| if (dlg.trash_properties) |*props| if (props.poll()) self.invalidate();
    _ = c.pthread_mutex_lock(&self.worker.mutex);
    const animation_settings = self.worker.animation_settings;
    const new_theme = self.worker.theme;
    self.worker.theme = null;
    _ = c.pthread_mutex_unlock(&self.worker.mutex);
    if (new_theme) |t| {
        self.single_click_open = t.single_click_open;
        self.audio_player = t.audio_player;
        self.open_on_release = null;
        t.apply();
        self.theme_cfg.override_root = @import("settings.zig").iconRoot();
        const base = @import("settings.zig").iconTheme();
        self.theme_cfg.theme_name = if (base.len > 0) base else if (std.c.getenv("REDIWM_ICON_THEME")) |name| std.mem.span(name) else "Adwaita";
        self.theme_cfg.generation += 1;
        theme.forgetParsedThemes(icons.gpa);
        self.invalidate();
    }
    if (!anim.currentSettings().eql(animation_settings)) {
        self.cancelWheel();
        anim.applySettings(animation_settings);
    }
    const width: f32 = @bitCast(self.worker.scrollbar_width.load(.acquire));
    if (width != self.scrollbar_width) {
        self.scrollbar_width = width;
        self.clampScroll();
        self.invalidate();
    }
    if (self.job_runner) |runner| {
        const progress = runner.pollProgress();
        const sample_at = nowMs();
        var rate_changed = false;
        if (progress.state == .running or progress.state == .paused or progress.state == .waiting_conflict) {
            if (self.job_rate_sample_at == 0) {
                self.job_rate_sample_at = sample_at;
                self.job_rate_sample_bytes = progress.transferred_bytes;
                self.job_bytes_per_second = 0;
            } else if (sample_at - self.job_rate_sample_at >= 500) {
                const elapsed = @max(1, sample_at - self.job_rate_sample_at);
                const transferred = progress.transferred_bytes -| self.job_rate_sample_bytes;
                self.job_bytes_per_second = if (progress.state == .running)
                    @intFromFloat(@as(f64, @floatFromInt(transferred)) * 1000.0 / @as(f64, @floatFromInt(elapsed)))
                else
                    0;
                self.job_rate_sample_at = sample_at;
                self.job_rate_sample_bytes = progress.transferred_bytes;
                rate_changed = true;
            }
        } else {
            self.job_rate_sample_at = 0;
            self.job_rate_sample_bytes = 0;
            self.job_bytes_per_second = 0;
        }
        if (progress.state == .waiting_conflict) {
            if (self.dialog == null or self.dialog.?.kind != .conflict) {
                self.openConflictDialog(progress.conflict_item_name);
            }
        } else if (self.dialog != null and self.dialog.?.kind == .conflict and progress.state != .waiting_conflict) {
            self.closeDialog();
        }

        if (progress.state == .finished) {
            if (self.job_was_running) {
                self.job_was_running = false;
                self.setStatusNotice(progress.status_message, progress.is_error);
                if (self.clipboard_cut and !self.clipboard_is_text and self.job_cut_revision == self.clipboard_revision) {
                    var i: usize = 0;
                    var changed = false;
                    while (i < self.clipboard_paths.items.len) {
                        if (runner.movedSuccessfully(self.clipboard_paths.items[i])) {
                            self.allocator.free(self.clipboard_paths.orderedRemove(i));
                            changed = true;
                        } else i += 1;
                    }
                    if (self.clipboard_paths.items.len == 0) self.clipboard_cut = false;
                    if (changed) self.clipboard_revision += 1;
                }
                if (runner.kind == .open_archive_member) {
                    if (runner.result_path) |path| {
                        if (self.archive_open_navigation == self.navigation_count) self.openExtracted(path, self.archive_preview);
                    }
                } else self.refresh();
            }
        } else if (progress.state == .running or progress.state == .paused or progress.state == .waiting_conflict) {
            self.job_was_running = true;
            const structure_changed = self.job_progress != progress.processed_items or
                self.job_state != progress.state;
            const bytes_changed = self.job_transferred_bytes != progress.transferred_bytes;
            const tooltip_hovered = self.hoverKey() == std.math.maxInt(usize) - 2002;
            if (structure_changed) {
                self.invalidate();
            } else if (bytes_changed or
                (rate_changed and tooltip_hovered))
            {
                damageJobProgress(self, bytes_changed, tooltip_hovered);
            }
        }
        self.job_progress = progress.processed_items;
        self.job_state = progress.state;
        self.job_transferred_bytes = progress.transferred_bytes;
    }

    const file_ops_active = self.job_state == .running or
        self.job_state == .paused or
        self.job_state == .waiting_conflict;
    const torrent_active = for (self.torrents.items()) |transfer| {
        if (transfer.@"error".len == 0 and
            !transfer.finished and
            !(transfer.pending and transfer.metadata))
        {
            break true;
        }
    } else false;
    const transfers_active = file_ops_active or torrent_active;
    if (transfers_active and !self.transfers_were_active) {
        self.sidebar_expanded[@intFromEnum(@import("app_model.zig").SidebarSection.transfers)] = true;
        self.invalidate();
    }
    self.transfers_were_active = transfers_active;

    if (self.status_notice != null and nowMs() >= self.status_notice_until) {
        self.allocator.free(self.status_notice.?);
        self.status_notice = null;
        self.invalidate();
    }

    if (self.transfer_view.active) return;

    // A background refresh must not reorder items or cancel a gesture
    // while the button is held. The worker retains its latest snapshot;
    // the first loop after release applies it.
    if (self.selection_band != null or self.drag_origin != null) return;
    const snap = self.worker.takeSnapshot() orelse {
        if (self.torrents.rows_changed) self.rebuildView();
        return;
    };
    if (isStaleSnapshot(snap.request_id, self.active_request_id)) {
        snap.destroy();
        return;
    }
    if (self.snapshot) |old| old.destroy();
    self.snapshot = snap;
    self.syncGitLayout();
    self.column_resize = null;
    self.clampSidebarScroll();
    self.loading = false;
    self.rebuildView();
    if (self.restore_view) self.restoreView();
    if (self.initial_selection) |path| {
        self.initial_selection = null;
        for (self.items.items, 0..) |*item, i| {
            if (!std.mem.eql(u8, item.path, path)) continue;
            item.selected = true;
            self.focused_index = i;
            self.selection_anchor = i;
            self.revealIndex(i);
            break;
        }
    }
}

/// Repositories list as one Git column and ignore the grid, but the user's
/// own grid/list choice returns as soon as the Git view is not in effect.
pub fn syncGitLayout(self: *App) void {
    if (self.repository() != null) {
        if (self.non_git_list_view == null) self.non_git_list_view = self.list_view;
        self.list_view = true;
    } else if (self.non_git_list_view) |previous| {
        self.list_view = previous;
        self.non_git_list_view = null;
    }
}

pub fn setGitView(self: *App, on: bool) void {
    if (self.git_view == on) return;
    self.git_view = on;
    self.savePreferences();
    self.syncGitLayout();
    self.column_resize = null;
    self.scroll_y = 0;
    self.nav_hover = .{};
    self.rebuildView();
    self.clampSidebarScroll();
    self.last_click_index = null;
}

/// The Git view with only changed files lists them flat, from any depth.
pub fn shownName(self: *App, item: worker_mod.Item) []const u8 {
    return if (self.changedOnly() and self.full_paths and item.label.len > 0) item.label else item.name;
}

pub fn matches(self: *App, item: worker_mod.Item) bool {
    // Deleted tracked files are rows of the Git view only.
    if (item.missing and self.repository() == null) return false;
    if (self.chooser) |opts| {
        if (!item.is_dir) {
            if (opts.mode == .folder) return false;
            if (opts.filters.len > 0 and !chooser_mod.matches(opts.filters[@min(opts.filter_index, opts.filters.len - 1)], item.name)) return false;
        }
    }
    if (self.folders_only and !item.is_dir) return false;
    return fold.contains(self.shownName(item), self.search.text.items, .{ .turkish = @import("i18n").isTurkish() });
}

pub fn lessThan(mode: Sort, a: ViewItem, b: ViewItem) bool {
    // Sorting by date mixes folders and files; every other order groups folders first.
    if (mode != .modified and mode != .modified_asc and a.is_dir != b.is_dir) return a.is_dir;
    if (mode == .size or mode == .size_asc) {
        if (a.is_dir and b.is_dir) {
            const a_calc = a.bytes >= 0;
            const b_calc = b.bytes >= 0;
            if (a_calc != b_calc) return a_calc;
            if (a_calc and b_calc and a.bytes != b.bytes) {
                return if (mode == .size) a.bytes > b.bytes else a.bytes < b.bytes;
            }
        } else if (a.bytes != b.bytes) {
            return if (mode == .size) a.bytes > b.bytes else a.bytes < b.bytes;
        }
    }
    const a_date = if (a.opened != 0) a.opened else a.mtime;
    const b_date = if (b.opened != 0) b.opened else b.mtime;
    if (mode == .modified and a_date != b_date) return a_date > b_date;
    if (mode == .modified_asc and a_date != b_date) return a_date < b_date;
    if (mode == .type or mode == .type_desc) {
        const order = std.mem.order(u8, itemType(a), itemType(b));
        if (order != .eq) return if (mode == .type) order == .lt else order == .gt;
    }
    const order = collation.order(a.sort_key orelse a.text(), b.sort_key orelse b.text(), a.text(), b.text(), a.path, b.path);
    return if (mode == .name_desc) order == .gt else order == .lt;
}

pub fn rebuildView(self: *App) void {
    const snap = self.snapshot orelse return;
    self.torrents.rows_changed = false;
    // Keep old storage alive until names, selection and focus have been copied.
    // Both a worker refresh and a local filter can rebuild this view.
    self.cancelWheel();
    self.cancelDrag();
    self.view_revision +%= 1;
    var old_arena = self.items_arena;
    defer old_arena.deinit();
    var old_items = self.items;
    defer old_items.deinit(self.allocator);
    const old_focus = if (self.focused_index) |i| (if (i < old_items.items.len) old_items.items[i].path else null) else null;
    const old_anchor = if (self.selection_anchor) |i| (if (i < old_items.items.len) old_items.items[i].path else null) else null;
    var selected_paths = std.StringHashMap(ViewItem).init(self.allocator);
    defer selected_paths.deinit();
    for (old_items.items) |item| {
        if (item.selected or item.selection_fill.alpha > 0 or item.selection_border.alpha > 0) selected_paths.put(item.path, item) catch {};
    }
    self.items_arena = std.heap.ArenaAllocator.init(self.allocator);
    const mem = self.items_arena.allocator();
    self.items = .empty;
    self.error_message = snap.err_msg;
    self.focused_index = null;
    self.selection_anchor = null;
    self.last_click_index = null;
    if (snap.err_msg == null) {
        for (if (self.changedOnly()) snap.changed else snap.items) |it| {
            if (!self.matches(it)) continue;
            const previous = selected_paths.get(it.path);
            const selected = if (previous) |item| item.selected else false;
            var bytes = it.bytes;
            if (it.is_dir and !it.is_symlink) {
                if (self.folder_sizes.get(it.path)) |sz| {
                    switch (sz) {
                        .done => |d| bytes = d.bytes,
                        else => bytes = -1,
                    }
                } else {
                    bytes = -1;
                }
            }
            self.items.append(self.allocator, .{
                .name = mem.dupe(u8, it.name) catch continue,
                .label = mem.dupe(u8, if (self.changedOnly() and self.full_paths) it.label else "") catch continue,
                .sort_key = if (if (self.changedOnly() and self.full_paths and it.label.len > 0) it.label_key else it.name_key) |key| mem.dupe(u8, key) catch continue else null,
                .path = mem.dupe(u8, it.path) catch continue,
                .is_dir = it.is_dir,
                .is_symlink = it.is_symlink,
                .is_broken = it.is_broken,
                .git_status = it.git_status,
                .git_lines = it.git_lines,
                .missing = it.missing,
                .bytes = bytes,
                .mtime = it.mtime,
                .opened = it.opened,
                .mode = it.mode,
                .permissions_text = std.fmt.allocPrint(mem, "{s} ({s})", .{ formatPermissions(it.mode), it.owner }) catch continue,
                .icon_name = mem.dupe(u8, it.icon_name) catch continue,
                .icon_candidates = @import("associations.zig").dupeCandidates(mem, it.icon_candidates) catch continue,
                .selected = selected,
                .selection_fill = if (previous) |item| item.selection_fill else .{},
                .selection_border = if (previous) |item| item.selection_border else .{},
            }) catch continue;
        }
        self.appendTorrentRows(mem, &selected_paths);
        // Transfer placeholders and synthetic snapshots have no worker key.
        // Give those rows keys from the same locale before sorting so every
        // comparison uses one collation, including mixed real/stub folders.
        var fallback_locale: ?collation.Locale = null;
        defer if (fallback_locale) |*locale| locale.deinit();
        var missing_key = false;
        for (self.items.items) |*item| {
            if (item.sort_key != null) continue;
            if (fallback_locale == null) fallback_locale = collation.Locale.init(snap.collation_name) orelse collation.Locale.init("C").?;
            item.sort_key = fallback_locale.?.key(mem, item.text()) catch null;
            missing_key = missing_key or item.sort_key == null;
        }
        // Allocation failure must not mix byte and locale comparisons: that
        // could make the comparator non-transitive.
        if (missing_key) for (self.items.items) |*item| {
            item.sort_key = null;
        };
        std.mem.sort(ViewItem, self.items.items, self.effectiveSort(), lessThan);
        for (self.items.items, 0..) |item, i| {
            if (old_focus) |path| {
                if (std.mem.eql(u8, path, item.path)) self.focused_index = i;
            }
            if (old_anchor) |path| {
                if (std.mem.eql(u8, path, item.path)) self.selection_anchor = i;
            }
        }
    }
    self.clampScroll();
    self.invalidate();
}

pub fn sortColumn(self: *App) usize {
    return switch (self.effectiveSort()) {
        .name, .name_desc => 0,
        .size, .size_asc => 1,
        .type, .type_desc => 2,
        .modified, .modified_asc => 3,
    };
}

pub fn sortDescending(self: *App) bool {
    return switch (self.effectiveSort()) {
        .name_desc, .size, .modified, .type_desc => true,
        else => false,
    };
}

pub fn startSortFeedback(self: *App, now: i64) void {
    if (!self.list_view) return;
    self.sort_feedback.animation.pulse(now, 1, 0, 220);
    _ = self.sort_feedback.step(now, false);
    self.invalidate();
}

pub fn paintSortFeedback(self: *App, cr: *c.cairo_t, rect: header.Rect) void {
    if (self.sort_feedback.alpha <= 0) return;
    setSource(cr, withAlpha(ui_theme.shellPalette().accent, 0.10 * self.sort_feedback.alpha));
    c.cairo_rectangle(cr, rect.x, rect.y, rect.w, rect.h);
    c.cairo_fill(cr);
}

pub fn sortByColumn(self: *App, column: usize) void {
    if (column >= 4 or (self.repository() != null and column != 0)) return;
    const reverse = self.sortColumn() == column and !self.sortDescending();
    const mode: Sort = switch (column) {
        0 => if (reverse) .name_desc else .name,
        1 => if (reverse) .size else .size_asc,
        2 => if (reverse) .type_desc else .type,
        else => if (reverse) .modified else .modified_asc,
    };
    self.setSort(mode);
    self.rebuildView();
    self.savePreferences();
    self.startSortFeedback(nowMs());
}

pub fn renderColumns(self: *App, cr: *c.cairo_t) void {
    if (!self.list_view and !self.transfer_view.active) return;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, @floatFromInt(self.sidebarWidth()), @floatFromInt(self.contentTop()), @floatFromInt(self.w - self.sidebarWidth() - self.scrollbarGutter()), 30);
    c.cairo_clip(cr);
    setSource(cr, ui_theme.global.app_bar);
    c.cairo_rectangle(cr, @floatFromInt(self.sidebarWidth()), @floatFromInt(self.contentTop()), @floatFromInt(self.w - self.sidebarWidth()), 30);
    c.cairo_fill(cr);
    for (self.columnLabels(), 0..) |label, i| {
        const rect = self.listColumn(i);
        if (i + 1 < self.columnLabels().len) {
            setSource(cr, withAlpha(ui_theme.global.window_fg, 0.2));
            c.cairo_rectangle(cr, rect.x + rect.w - 0.5, rect.y + 6, 1, rect.h - 12);
            c.cairo_fill(cr);
        }
        const sorted = !self.transfer_view.active and self.sortColumn() == i and (self.repository() == null or i == 0);
        const hovered = self.hoverKey() == 400 + i;
        if (sorted) {
            setSource(cr, ui_theme.global.surface);
            c.cairo_rectangle(cr, rect.x, rect.y, rect.w, rect.h);
            c.cairo_fill(cr);
        }
        if (hovered) {
            setSource(cr, ui_theme.global.surface_hover);
            c.cairo_rectangle(cr, rect.x, rect.y, rect.w, rect.h);
            c.cairo_fill(cr);
        }
        if (sorted) self.paintSortFeedback(cr, rect);
        // Narrow columns step down one more, so "Modified" still fits.
        const size: f64 = if (rect.w < 75) shell_ui.headingSize() - 1 else shell_ui.headingSize();
        const label_width = @max(0, rect.w - (if (sorted) @as(f64, 20) else 8));
        setSource(cr, ui_theme.global.window_fg);
        drawEllipsis(cr, label, rect.x + 4, rect.y + 20, label_width, size, true);
        if (sorted) {
            // Six pixels between the label's advance and the triangle.
            const x = rect.x + 4 + @min(measureText(cr, label, size, true), label_width) + 9;
            const y = rect.y + 15;
            const direction: f64 = if (self.sortDescending()) 1 else -1;
            c.cairo_move_to(cr, x - 3, y - 2 * direction);
            c.cairo_line_to(cr, x + 3, y - 2 * direction);
            c.cairo_line_to(cr, x, y + 2 * direction);
            c.cairo_close_path(cr);
            c.cairo_fill(cr);
        }
    }
}

pub fn itemType(item: ViewItem) []const u8 {
    if (item.is_broken) return tr("Broken link");
    if (item.is_symlink) return tr("Link");
    if (item.is_dir) return tr("Folder");
    const ext = std.fs.path.extension(item.name);
    return if (ext.len > 1) ext[1..] else tr("File");
}

pub fn isRecent(self: *const App) bool {
    return recent.isLocation(self.history.current);
}

pub fn recentAvailable(self: *const App) bool {
    return if (self.chooser) |opts| opts.mode == .open else true;
}

pub fn effectiveSort(self: *const App) Sort {
    return if (self.isRecent()) self.recent_sort_mode else self.sort_mode;
}

pub fn setSort(self: *App, mode: Sort) void {
    if (self.isRecent()) self.recent_sort_mode = mode else self.sort_mode = mode;
}
