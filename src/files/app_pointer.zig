//! Files pointer input: motion, drags, the selection band and clicks.

const recent = @import("recent.zig");
const std = @import("std");
const io_thread_guard = @import("io_thread_guard.zig");
const App = @import("app.zig").App;
const scrollbar = @import("ui").widgets.scrollbar;
const c = @import("c.zig").api;
const deletion = @import("../delete_dialog.zig");
const header = @import("header.zig");
const ui_theme = @import("ui").theme;
const open_with = @import("open_with.zig");
const properties = @import("properties.zig");
const git_header_h = App.git_header_h;
const git_row_h = App.git_row_h;
const nowMs = @import("app_draw.zig").nowMs;
const setSource = @import("app_draw.zig").setSource;
const gitBranchRowCount = App.gitBranchRowCount;
const gitBranchRow = App.gitBranchRow;

/// Reserved for per-character permission hover keys: base + item * 9 + bit.
/// Kept separate from the size-button range and transient transfer keys.
pub const permissionHoverBase: usize = 3_000_000;

pub const PermissionHit = struct {
    index: usize,
    bit: usize,
};

fn permissionsAvailable(self: *App) bool {
    return self.list_view and
        !self.transfer_view.active and
        self.repository() == null and
        self.chooser == null and
        self.dialog == null and
        self.menu == null and
        self.history.archive_len == 0 and
        !@import("app_trash.zig").inTrash(self) and
        self.columnLabels().len > 4;
}

/// Whether this user can change the item's permissions, using cached ownership.
pub fn canTogglePermission(self: *App, index: usize) bool {
    if (!permissionsAvailable(self) or index >= self.items.items.len) return false;
    const item = self.items.items[index];
    if (item.transfer_stub or item.transfer_ghost or item.missing or item.is_symlink or item.is_broken) return false;
    const euid = c.geteuid();
    return euid == 0 or euid == item.owner_uid;
}

pub fn permissionRect(self: *App, index: usize, bit: usize) ?header.Rect {
    if (bit >= 9 or !self.canTogglePermission(index)) return null;

    const column = self.listColumn(4);
    const row: i32 = @intCast(index);
    const row_y: f64 = @floatFromInt(
        self.viewTop() + self.itemInset() +
            @divTrunc(row, self.columns()) * self.rowHeight() - self.scroll_y,
    );
    const start_x = column.x + 18;
    const offset: f64 = @floatFromInt(bit * 10 + (bit / 3) * 4);
    return .{
        .x = start_x + offset,
        .y = row_y + self.listBaseline() - 17,
        .w = 10,
        .h = 22,
    };
}

pub fn permissionHit(self: *App, x: f64, y: f64) ?PermissionHit {
    if (!permissionsAvailable(self)) return null;
    const index = self.itemAt(x, y) orelse return null;
    for (0..9) |bit| {
        if (permissionRect(self, index, bit)) |rect| {
            if (rect.contains(x, y)) return .{ .index = index, .bit = bit };
        }
    }
    return null;
}

pub fn toggleInlinePermission(self: *App, hit: PermissionHit) void {
    if (hit.index >= self.items.items.len or hit.bit >= 9) return;
    const path = self.items.items[hit.index].path;
    const owned = self.allocator.dupe(u8, path) catch return;
    _ = @import("app_requests.zig").send(self, .{ .toggle_permission = .{ .path = path, .bit = @intCast(hit.bit) } }, .{ .toggle_permission = .{ .path = owned } });
}

// Input handlers
pub fn hoverKey(self: *App) usize {
    if (self.dialog) |dlg| if (dlg.kind == .transfers) return self.transfersHover();
    if (self.dialog == null) {
        const file_ops_hover = self.fileOpsSidebarHover(self.mouse_x, self.mouse_y);
        if (file_ops_hover != 0) return file_ops_hover;
    }
    if (self.dialog == null) {
        const torrent_hover = self.torrentSidebarHover(self.mouse_x, self.mouse_y);
        if (torrent_hover != 0) return torrent_hover;
    }
    const x = self.mouse_x;
    const y = self.mouse_y;
    if (self.dialog) |dlg| {
        if (dlg.kind == .properties) return dlg.properties.?.hit(self.w, self.h, x, y);
        if (dlg.kind == .trash_properties) return @backingInt(dlg.trash_properties.?.hit(self.w, self.h, x, y));
        if (dlg.kind == .open_with) return dlg.applications.?.hit(self.w, self.h, x, y);
        if (dlg.kind == .trash_confirm) return @backingInt(dlg.deletion.geometry(self.w, self.h).target(x, y));
        if (self.dialog_surface.hovered) |target| return @intCast(target.id);
        return 0;
    }
    if (self.menu != null) return 100 + (self.menuHit(x, y) orelse 99);
    if (self.transfer_view.active and (y < @as(f64, @floatFromInt(self.contentTop())) or
        (x >= @as(f64, @floatFromInt(self.sidebarWidth())) and y < @as(f64, @floatFromInt(self.contentBottom()))))) return self.transferPaneHover();
    if (self.terminalHit(x, y)) |index| return 900 + index;
    if (self.sidebar_resize != null or self.overSidebarDivider(x, y)) return 0;
    if (self.sidebarHeaderAt(x, y)) |section| return 940 + @as(usize, @backingInt(section));
    if (self.chooser) |opts| {
        if (y >= @as(f64, @floatFromInt(self.h - self.footerHeight()))) {
            for (0..4 + opts.choices.len) |i| {
                if (self.chooserRect(i).contains(x, y)) return 501 + i;
            }
            return 500;
        }
    }
    if (@import("app_audio_bar.zig").hit(self, x, y)) |id| return 920 + id;
    if (self.toolbar_surface.hovered) |target| return 200 + @as(usize, @intCast(target.id));
    if (self.list_view and x >= @as(f64, @floatFromInt(self.sidebarWidth())) and x < @as(f64, @floatFromInt(self.w - self.scrollbarGutter()))) {
        if (self.column_surface.hovered) |target| return @intCast(target.id);
    }
    if (self.sidebar_surface.hovered) |target| return @intCast(target.id);
    if (self.permissionHit(x, y)) |hit| return permissionHoverBase + hit.index * 9 + hit.bit;
    if (self.inlineTorrentHit(x, y)) |hit| return std.math.maxInt(usize) - 3000 - hit.index * 2 - @intFromBool(hit.toggle);
    if (@import("app_torrent_browse.zig").checkHit(self, x, y)) |index| return std.math.maxInt(usize) - 6000 - index;
    if (self.audioButtonHit(x, y)) |index| return @import("app_audio.zig").audioHoverKey(index);
    if (self.item_surface.hovered) |target| {
        const i: usize = @intCast(target.id);
        if (i < self.items.items.len) {
            if (self.sizeButtonRect(i)) |rect| {
                if (rect.contains(x, y)) {
                    if (self.folder_sizes.get(self.items.items[i].path)) |sz| {
                        switch (sz) {
                            .running => return 2_000_000 + i,
                            .done => {},
                        }
                    } else {
                        return 2_000_000 + i;
                    }
                }
            }
            return 1000 + i;
        }
    }
    return 0;
}

const transfer_hover_priority_delay_ms: i64 = 300;

fn transferHoverPriorityGestureActive(self: *App) bool {
    return self.drag_origin != null or
        self.drag_ready or
        self.selection_band != null or
        self.text_dragging or
        self.scroll_drag.active or
        self.sidebar_scroll_drag.active or
        self.horizontal_drag.active or
        self.column_resize != null or
        self.sidebar_resize != null;
}

fn hoveredCopyGhostEntry(self: *App) ?@import("io_tree.zig").EntryId {
    const target = self.item_surface.hovered orelse return null;
    const index: usize = @intCast(target.id);
    if (index >= self.items.items.len or self.hoverKey() != 1000 + index)
        return null;

    const item = self.items.items[index];
    if (!item.transfer_ghost or item.is_dir or item.is_symlink) return null;
    const state = item.transfer_state orelse return null;
    if (state != .pending and state != .copying) return null;
    return item.transfer_entry_id;
}

fn updateTransferHoverPriority(self: *App, now: i64) void {
    if (transferHoverPriorityGestureActive(self)) {
        self.transfer_hover_priority = null;
        return;
    }

    const entry_id = hoveredCopyGhostEntry(self) orelse {
        self.transfer_hover_priority = null;
        return;
    };

    if (self.transfer_hover_priority) |pending| {
        if (pending.entry_id == entry_id) return;
    }

    self.transfer_hover_priority = .{
        .entry_id = entry_id,
        .deadline_ms = now + transfer_hover_priority_delay_ms,
    };
}

/// The poll loop sleeps until this deadline rather than polling continuously.
pub fn transferHoverPriorityDeadline(self: *const App) ?i64 {
    const pending = self.transfer_hover_priority orelse return null;
    if (pending.requested) return null;
    return pending.deadline_ms;
}

/// Requests priority once the pointer has remained over the same queued
/// copy ghost for the full dwell interval.
pub fn stepTransferHoverPriority(self: *App, now: i64) void {
    var pending = self.transfer_hover_priority orelse return;
    if (pending.requested or now < pending.deadline_ms) return;

    if (transferHoverPriorityGestureActive(self)) {
        self.transfer_hover_priority = null;
        return;
    }

    const entry_id = hoveredCopyGhostEntry(self) orelse {
        self.transfer_hover_priority = null;
        return;
    };
    if (entry_id != pending.entry_id) {
        self.transfer_hover_priority = null;
        return;
    }

    if (!self.prioritizeTransferEntry(pending.entry_id)) {
        self.transfer_hover_priority = null;
        return;
    }
    pending.requested = true;
    self.transfer_hover_priority = pending;
}

pub fn handleMotion(self: *App, x: f64, y: f64) void {
    if (@import("app_audio_playlist.zig").motion(self, x, y)) {
        self.transfer_hover_priority = null;
        return;
    }
    if (@import("app_audio_bar.zig").motion(self, x, y)) {
        self.transfer_hover_priority = null;
        return;
    }
    if (self.terminalMotion(x, y)) {
        self.mouse_x = x;
        self.mouse_y = y;
        self.transfer_hover_priority = null;
        return;
    }
    if (self.overTerminalDivider(self.mouse_x, self.mouse_y) != self.overTerminalDivider(x, y)) self.terminalDamage();
    if (self.sidebar_resize) |drag| {
        self.mouse_x = x;
        self.mouse_y = y;
        const width = drag.widthAt(x, 160, @divTrunc(self.w, 2));
        if (width != self.sidebarWidth()) {
            self.sidebar_requested = width;
            self.syncSidebarWidth();
            self.clampScroll();
            self.clampSidebarScroll();
            self.invalidate();
        }
        self.transfer_hover_priority = null;
        return;
    }
    if (self.overSidebarDivider(self.mouse_x, self.mouse_y) != self.overSidebarDivider(x, y)) self.damageSidebarDivider();
    if (self.dialog) |*dlg| {
        const moved = switch (dlg.kind) {
            .properties => dlg.properties.?.motion(self.w, self.h, x, y),
            .trash_properties => dlg.trash_properties.?.motion(self.w, self.h, x, y),
            .open_with => dlg.applications.?.motion(self.w, self.h, x, y),
            .trash_confirm => dlg.deletion.motion(self.w, self.h, x, y),
            else => false,
        };
        if (moved) self.invalidate();
    }
    if (self.column_resize != null) {
        self.mouse_x = x;
        self.mouse_y = y;
        self.resizeColumn(x);
        self.transfer_hover_priority = null;
        return;
    }
    if (self.drag_origin) |origin| {
        const dx = x - origin.x;
        const dy = y - origin.y;
        if (dx * dx + dy * dy >= 64) {
            self.drag_ready = self.history.archive_len == 0 or
                self.hasSelectedArchiveMembers();
            self.drag_origin = null;
            self.collapse_on_release = null;
            self.deselect_on_release = null;
            self.open_on_release = null;
            self.last_click_index = null;
        }
    }
    const old_x = self.mouse_x;
    const old_y = self.mouse_y;
    const old_hover = self.hoverKey();
    self.mouse_x = x;
    self.mouse_y = y;
    self.updateToolbarSurface();
    self.updateSidebarSurface();
    self.updateColumnSurface();
    self.updateDialogSurface();
    self.updateItemSurface();
    self.damageToolbarProximity(old_x, old_y, x, y);
    self.damageSidebarProximity(old_x, old_y, x, y);
    if (self.selection_band != null) self.updateSelectionBand();
    if (self.text_dragging) {
        self.placeCaret(x, true);
        self.edit_revision += 1;
        self.invalidate();
    }
    if (self.menu != null) {
        if (self.menuHit(x, y)) |row| self.menu_selected = row;
    }
    const new_hover = self.hoverKey();
    updateTransferHoverPriority(self, nowMs());
    if (old_hover != new_hover) {
        if (self.item_surface.hovered) |target| {
            const index: usize = @intCast(target.id);
            if (index < self.items.items.len) {
                const item = self.items.items[index];
                if (item.is_dir and !item.is_symlink)
                    self.promoteDiscoverySubtreePath(item.path);
            }
        }
        self.invalidateHover(old_hover, new_hover);
    } else if (new_hover == std.math.maxInt(usize) - 2001 or
        new_hover == std.math.maxInt(usize) - 2002)
    {
        // Sidebar transfer tooltips follow the pointer even while their
        // owning hover key remains unchanged. Repaint to clear the old
        // tooltip position before drawing it at the new one.
        self.invalidate();
    }

    if (self.sidebar_scroll_drag.active) {
        if (self.sidebarScrollbar()) |bar| {
            const offset = self.sidebar_scroll_drag.offsetAt(bar, @floatCast(x), @floatCast(y));
            self.sidebar_scroll = @intFromFloat(@round(offset));
            self.invalidate();
        }
    }
    if (self.scroll_drag.active) {
        if (self.scrollbarGeometry()) |bar| {
            self.scroll_y = std.math.clamp(@as(i32, @intFromFloat(@round(self.scroll_drag.offsetAt(bar, @floatCast(x), @floatCast(y))))), 0, self.maxScroll());
            self.invalidate();
        }
    }
    if (self.horizontal_drag.active) {
        if (self.horizontalScrollbar()) |bar| {
            self.scroll_x = self.horizontal_drag.offsetAt(bar, @floatCast(x), @floatCast(y));
            self.invalidate();
        }
    }
}

pub fn cancelDrag(self: *App) void {
    self.audio_bar.drag.end();
    self.terminalCancelPointer();
    self.terminal.resize = null;
    self.terminal.selecting = false;
    self.terminal.scroll_drag.end();
    if (self.dialog) |*dlg| {
        dlg.deletion.placement.grab = null;
        if (dlg.properties) |*props| props.placement.grab = null;
        if (dlg.trash_properties) |*props| props.placement.grab = null;
        if (dlg.applications) |*apps| apps.placement.grab = null;
    }
    self.column_resize = null;
    if (self.sidebar_resize != null) self.damageSidebarDivider();
    self.sidebar_resize = null;
    self.horizontal_drag.end();
    if (self.selection_band != null) self.invalidate();
    self.selection_band = null;
    self.drag_origin = null;
    self.drag_ready = false;
    self.collapse_on_release = null;
    self.deselect_on_release = null;
    self.open_on_release = null;
}

pub fn bandRect(self: *App) header.Rect {
    const band = self.selection_band.?;
    const x = std.math.clamp(self.mouse_x, @as(f64, @floatFromInt(self.sidebarWidth())), @as(f64, @floatFromInt(self.w - self.scrollbarGutter())));
    const y = std.math.clamp(self.mouse_y, @as(f64, @floatFromInt(self.viewTop())), @as(f64, @floatFromInt(self.contentBottom()))) + @as(f64, @floatFromInt(self.scroll_y));
    return .{ .x = @min(band.x, x), .y = @min(band.y, y), .w = @abs(x - band.x), .h = @abs(y - band.y) };
}

pub fn updateSelectionBand(self: *App) void {
    const band = if (self.selection_band) |*b| b else return;
    const rect = self.bandRect();
    if (!band.active and rect.w * rect.w + rect.h * rect.h < 16) return;
    band.active = true;
    const cols = self.columns();
    for (self.items.items, 0..) |*item, i| {
        const index: i32 = @intCast(i);
        const x: f64 = @floatFromInt(self.sidebarWidth() + self.itemLeftInset() + @mod(index, cols) * self.cellWidth());
        const y: f64 = @floatFromInt(self.viewTop() + self.itemInset() + @divTrunc(index, cols) * self.rowHeight());
        const hit = rect.x < x + @as(f64, @floatFromInt(self.cellWidth() - 20)) and rect.x + rect.w > x and
            rect.y < y + @as(f64, @floatFromInt(self.cardHeight())) and rect.y + rect.h > y;
        item.selected = if (band.toggle) item.selected_before_band != hit else hit or (band.extend and item.selected_before_band);
    }
    self.invalidate();
}

pub fn bandScrollDirection(self: *App) i32 {
    const band = self.selection_band orelse return 0;
    if (!band.active) return 0;
    if (self.mouse_y < @as(f64, @floatFromInt(self.viewTop() + 20)) and self.scroll_y > 0) return -1;
    if (self.mouse_y > @as(f64, @floatFromInt(self.contentBottom() - 20)) and self.scroll_y < self.maxScroll()) return 1;
    return 0;
}

pub fn selectionNeedsScroll(self: *App) bool {
    return self.bandScrollDirection() != 0;
}

pub fn stepSelection(self: *App, now: i64) void {
    const band = if (self.selection_band) |*b| b else return;
    const elapsed = std.math.clamp(now - band.last_ms, 0, 50);
    band.last_ms = now;
    const direction = self.bandScrollDirection();
    if (direction == 0 or elapsed == 0) return;
    self.scroll_y = std.math.clamp(self.scroll_y + direction * @as(i32, @intCast(@max(1, @divTrunc(elapsed * 600, 1000)))), 0, self.maxScroll());
    self.updateSelectionBand();
}

pub fn renderSelectionBand(self: *App, cr: *c.cairo_t) void {
    const band = self.selection_band orelse return;
    if (!band.active) return;
    const rect = self.bandRect();
    const palette = ui_theme.shellPalette();
    setSource(cr, palette.selectionColor());
    c.cairo_rectangle(cr, rect.x, rect.y - @as(f64, @floatFromInt(self.scroll_y)), rect.w, rect.h);
    c.cairo_fill_preserve(cr);
    setSource(cr, palette.accent);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
}

/// Opens the folder under the pointer in a background tab: a folder in the
/// listing, or a place in the sidebar. Files, archives' insides and the
/// transfer view are left alone.
pub fn openFolderTab(self: *App) void {
    if (self.dialog != null or self.menu != null or self.chooser != null or self.history.archive_len > 0) return;
    if (self.itemAt(self.mouse_x, self.mouse_y)) |idx| {
        const item = self.items.items[idx];
        if (item.is_dir and !item.missing and !item.transfer_ghost) self.openTab(item.path, false);
        return;
    }
    if (self.hoveredPlace()) |place| {
        var buf: [4096]u8 = undefined;
        if (self.deviceAt(place)) |volume| {
            if (volume.mount) |mount| self.openTab(mount, false);
        } else if (self.placePath(place, &buf)) |path| {
            // Only a folder opens; the service looks.
            if (recent.isLocation(path)) return self.openTab(path, false);
            const owned = self.allocator.dupe(u8, path) catch return;
            _ = @import("app_requests.zig").send(self, .{ .path_kinds = .{ .paths = &.{path} } }, .{ .folder_tab = .{ .path = owned } });
        }
    }
}
