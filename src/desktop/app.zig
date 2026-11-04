const std = @import("std");
const c = @import("c.zig").api;
const grid = @import("grid.zig");
const watcher = @import("watcher.zig");
const config = @import("config.zig");
const damage_mod = @import("damage.zig");
pub const Damage = damage_mod.Damage;
const rename = @import("rename.zig");
const deletion = @import("../delete_dialog.zig");
const trash_properties = @import("../files/trash_properties.zig");
const Host = @import("host.zig").Host;
const host_mod = @import("host.zig");
const Menu = @import("menu.zig").Menu;
const a = std.heap.c_allocator;
const app_layout = @import("app_layout.zig");
const app_pointer = @import("app_pointer.zig");
const app_keyboard = @import("app_keyboard.zig");
const app_actions = @import("app_actions.zig");
const app_paint = @import("app_paint.zig");
const app_draw = @import("app_draw.zig");
const sameImage = app_draw.sameImage;
const copyItem = app_draw.copyItem;
const freeItem = app_draw.freeItem;
pub const nowMs = app_draw.nowMs;
pub const rounded = app_draw.rounded;
const IconRaster = app_draw.IconRaster;
const NameCache = app_draw.NameCache;
pub const label = app_draw.label;
pub const Icon = struct {
    item: watcher.Item,
    cell: grid.Cell,
    selected: bool = false,

    born: i64,
    removed: ?i64 = null,
    hover_amount: f64 = 0,
    selection_amount: f64 = 0,
    name_cache: NameCache = .{},
    raster: IconRaster = .{},

    pub fn replaceItem(self: *Icon, item: watcher.Item) void {
        // Worker snapshots are immutable. A replacement can change the icon
        // pixels or fallback monogram even while rename shows the same text.
        self.raster.deinit();
        freeItem(self.item);
        self.item = item;
    }
};
pub const App = struct {
    worker: *watcher.Worker,
    host: Host = .none,
    /// Embedded hosts present prompts above windows in a separate scene layer.
    separate_overlays: bool = false,
    wallpaper: ?@import("wallpaper.zig").Image = null,
    /// Bumped whenever `wallpaper` changes to a different image.
    wallpaper_revision: u64 = 0,
    icon_only: bool = false,
    /// `bottom_exclusion` from the desktop config, which beats the host's.
    bottom_config: ?i32 = null,
    icons: std.ArrayList(Icon) = .empty,
    geometry: grid.Grid = .{ .w = 1280, .h = 720 },
    x: f64 = 0,
    y: f64 = 0,
    down_x: f64 = 0,
    down_y: f64 = 0,
    down_at: i64 = 0,
    hover: ?usize = null,
    pressed: ?usize = null,
    dragging: bool = false,
    rubber: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    rename_editor: rename.Editor = .{},
    last_click: i64 = 0,
    last_icon: ?usize = null,
    menu: bool = false,
    menu_selected: usize = 0,
    menu_layout: Menu = .{},
    menu_icon: ?usize = null,
    menu_x: i32 = 0,
    menu_y: i32 = 0,
    edit: enum { none, rename, folder, file, trash, trash_properties, properties, add_app, open_with } = .none,
    folder_token: u64 = 0,
    deletion: deletion.State = .{},
    /// The Trash's Properties window, the one Files shows too.
    trash_card: ?trash_properties.State = null,
    catalog: []const @import("dotdesktop.zig").parser.AppEntry = &.{},
    applications: ?@import("../files/open_with.zig").State = null,
    picker_theme: @import("../icon_theme.zig").Config = .{ .theme_name = "", .base_dirs = &.{} },
    menu_labels: [8][]const u8 = undefined,
    choice: usize = 0,
    last_tick: i64 = 0,
    last_tick_active: bool = false,
    edit_text: std.ArrayList(u8) = .empty,
    launching_until: i64 = 0,
    /// Last cursor asked of the host.
    cursor: host_mod.Cursor = .normal,
    /// Identifies the launch the busy state waits for; stale worker reports
    /// for earlier launches carry an older token.
    launch_token: u64 = 0,
    launch_after_id: u64 = 0,
    launched: ?watcher.Launched = null,
    dirty: bool = true,
    damage: Damage = .{},
    presented_selection: ?grid.Rect = null,
    /// The selection band's raster during one `paint`.
    band: ?*c.cairo_pattern_t = null,
    notice: [256]u8 = undefined,
    notice_len: usize = 0,
    notice_until: i64 = 0,
    clipboard: std.ArrayList([]const u8) = .empty,
    cut: bool = false,
    pub fn invalidate(self: *App) void {
        self.dirty = true;
        self.damage.all();
    }
    pub fn prepareDamage(self: *App) void {
        // Pointer events may arrive much faster than the output refreshes.
        // Intermediate rubberbands were never displayed and need no damage.
        self.damage.rubberband(self.presented_selection, if (self.rubber) self.selectionRect() else null);
    }
    pub fn themeChanged(self: *App) void {
        for (self.icons.items) |*ic| {
            ic.raster.deinit();
            ic.name_cache.deinit();
        }
        self.invalidate();
    }

    pub fn presented(self: *App) void {
        self.presented_selection = if (self.rubber) self.selectionRect() else null;
        self.damage.clear();
        self.dirty = false;
    }
    pub fn damageRect(self: *App, r: grid.Rect) void {
        self.dirty = true;
        self.damage.add(r);
    }
    pub fn damageIcon(self: *App, index: usize) void {
        if (index >= self.icons.items.len) return;
        self.damageRect(self.iconRect(index));
    }
    pub fn iconRect(self: *App, index: usize) grid.Rect {
        var r = self.geometry.rect(self.icons.items[index].cell);
        if (self.dragging and self.pressed == index) {
            r.x = @intFromFloat(self.x - @as(f64, @floatFromInt(r.w)) / 2);
            r.y = @intFromFloat(self.y - 40);
        }
        return r;
    }
    pub fn damageDrag(self: *App) void {
        if (!self.dragging) return;
        if (self.pressed) |i| self.damageIcon(i);
        self.damageRect(damage_mod.expand(self.geometry.rect(self.geometry.snap(self.x, self.y)), 1));
    }
    pub fn deinit(self: *App) void {
        self.closePicker();
        self.closeTrashCard();
        self.deletion.deinit();
        self.rename_editor.deinit();
        if (self.wallpaper) |im| a.free(im.pixels);
        for (self.icons.items) |*ic| {
            ic.name_cache.deinit();
            ic.raster.deinit();
            freeItem(ic.item);
        }
        self.icons.deinit(a);
        self.edit_text.deinit(a);
        for (self.clipboard.items) |p| a.free(p);
        self.clipboard.deinit(a);
    }
    pub fn sync(self: *App) void {
        const snap = self.worker.take() orelse return;
        defer snap.destroy();
        const now = nowMs();
        // Every rescan reloads the wallpaper; only a different image counts
        // as a change for hosts that draw it elsewhere too.
        if (!sameImage(self.wallpaper, snap.wallpaper)) {
            if (self.wallpaper) |im| a.free(im.pixels);
            self.wallpaper = null;
            self.wallpaper_revision +%= 1;
            if (snap.wallpaper) |im| {
                var owned = im;
                owned.pixels = a.dupe(u32, im.pixels) catch return;
                self.wallpaper = owned;
            }
        }
        self.bottom_config = snap.bottom;
        self.refreshBottom();
        self.icon_only = snap.icon_only;
        self.catalog = snap.catalog;
        if (self.applications) |*picker| picker.shortcut_catalog = self.catalog;
        for (self.icons.items) |*ic| {
            var found = false;
            for (snap.items) |item| if (std.mem.eql(u8, item.path, ic.item.path)) {
                found = true;
                break;
            };
            if (!found and ic.removed == null) {
                ic.removed = now;
                if (self.edit == .rename and ic.selected) self.edit = .none;
            }
        }
        var layout_changed = false;
        for (snap.items) |item| {
            var found = false;
            for (self.icons.items) |*ic| if (std.mem.eql(u8, item.path, ic.item.path) or (ic.removed != null and item.inode != 0 and item.inode == ic.item.inode and item.device == ic.item.device)) {
                const owned = copyItem(item) catch continue;
                if (!std.mem.eql(u8, item.path, ic.item.path)) layout_changed = true;
                ic.replaceItem(owned);
                ic.removed = null;
                found = true;
                break;
            };
            if (found) continue;
            const fallback = if (item.builtin != .none and self.valid(self.defaultCell(item.builtin))) self.defaultCell(item.builtin) else self.firstEmpty();
            const cell = if (item.cell) |pos| if (self.valid(pos) and !self.occupied(pos, null)) pos else fallback else fallback;
            const owned = copyItem(item) catch continue;
            self.icons.append(a, .{ .item = owned, .cell = cell, .born = now }) catch {
                freeItem(owned);
                continue;
            };
            layout_changed = true;
        }
        if (snap.created_folder) |created| {
            if (self.edit == .folder and created.token == self.folder_token) {
                self.edit = .none;
                for (self.icons.items, 0..) |ic, i| {
                    if (ic.removed == null and std.mem.eql(u8, ic.item.path, created.path)) {
                        self.deselect();
                        self.icons.items[i].selected = true;
                        self.beginEdit(.rename);
                        break;
                    }
                }
            }
        }
        self.invalidate();
        if (layout_changed) self.persist();
    }
    // app_layout.zig
    pub const refreshBottom = app_layout.refreshBottom;
    pub const defaultCell = app_layout.defaultCell;
    pub const valid = app_layout.valid;
    pub const occupied = app_layout.occupied;
    pub const firstEmpty = app_layout.firstEmpty;
    pub const resize = app_layout.resize;
    pub const hit = app_layout.hit;
    pub const renameGeometry = app_layout.renameGeometry;

    // app_pointer.zig
    pub const motion = app_pointer.motion;
    pub const pointerMotion = app_pointer.pointerMotion;
    pub const leave = app_pointer.leave;
    pub const selectionRect = app_pointer.selectionRect;
    pub const deselect = app_pointer.deselect;
    pub const button = app_pointer.button;
    pub const pointerButton = app_pointer.pointerButton;
    pub const openSelected = app_pointer.openSelected;
    pub const endLaunch = app_pointer.endLaunch;
    pub const wantedCursor = app_pointer.wantedCursor;
    pub const syncCursor = app_pointer.syncCursor;
    pub const updateLaunch = app_pointer.updateLaunch;

    // app_keyboard.zig
    pub const keyboardLeft = app_keyboard.keyboardLeft;

    pub fn persist(self: *App) void {
        var positions: std.ArrayList(config.Position) = .empty;
        defer positions.deinit(a);
        for (self.icons.items) |ic| if (ic.removed == null) {
            if (ic.item.builtin != .none) {
                const home = self.defaultCell(ic.item.builtin);
                if (ic.cell.col == home.col and ic.cell.row == home.row) continue;
            }
            positions.append(a, .{ .path = ic.item.path, .cell = ic.cell }) catch return;
        };
        const data = config.encode(a, positions.items) catch return;
        defer a.free(data);
        self.worker.enqueue(.{ .kind = .save, .path = "", .value = data });
    }
    // app_keyboard.zig
    pub const keyRepeats = app_keyboard.keyRepeats;
    pub const key = app_keyboard.key;

    // app_actions.zig
    pub const copy = app_actions.copy;
    pub const paste = app_actions.paste;
    pub const pasteLocal = app_actions.pasteLocal;
    pub const menuBuiltin = app_actions.menuBuiltin;
    pub const menuLabels = app_actions.menuLabels;
    pub const menuIcon = app_actions.menuIcon;
    pub const menuHint = app_actions.menuHint;
    pub const untrustedLauncher = app_actions.untrustedLauncher;
    pub const menuAction = app_actions.menuAction;
    pub const closePicker = app_actions.closePicker;
    pub const pickerAction = app_actions.pickerAction;
    pub const beginEdit = app_actions.beginEdit;
    pub const deleteAction = app_actions.deleteAction;
    pub const beginTrashProperties = app_actions.beginTrashProperties;
    pub const trashPropertiesAction = app_actions.trashPropertiesAction;
    pub const closeTrashCard = app_actions.closeTrashCard;
    pub const finishEdit = app_actions.finishEdit;
    pub const choiceEntry = app_actions.choiceEntry;

    // app_paint.zig
    pub const rasterBand = app_paint.rasterBand;
    pub const drawBand = app_paint.drawBand;

    /// When the app next needs a tick without input: a notice expiring, or a
    /// press becoming a drag. Past the drag threshold, motion drives the rest.
    pub fn nextDeadline(self: *const App, now: i64) ?i64 {
        var deadline: ?i64 = null;
        if (self.notice_until != 0) deadline = self.notice_until;
        if (self.pressed != null and !self.dragging and now < self.down_at + 150) {
            const drag_at = self.down_at + 150;
            deadline = if (deadline) |d| @min(d, drag_at) else drag_at;
        }
        return deadline;
    }
    pub fn notify(self: *App, comptime format: []const u8, args: anytype) void {
        const message: []const u8 = std.fmt.bufPrint(&self.notice, format, args) catch "";
        self.notice_len = message.len;
        self.notice_until = nowMs() + 5000;
        self.invalidate();
    }
    pub fn tick(self: *App) bool {
        const now = nowMs();
        if (self.trash_card) |*card| if (card.poll()) self.invalidate();
        const error_len = self.worker.takeError(&self.notice);
        if (error_len > 0) {
            if (self.edit == .folder) self.edit = .none;
            self.notice_len = error_len;
            self.notice_until = now + 5000;
            self.invalidate();
        }
        self.updateLaunch(now);
        if (self.notice_until != 0 and now >= self.notice_until) {
            self.notice_until = 0;
            self.invalidate();
        }
        var active = now < self.launching_until;
        if (self.pressed != null and !self.dragging and now - self.down_at >= 150 and (@abs(self.x - self.down_x) > 4 or @abs(self.y - self.down_y) > 4)) {
            self.damageIcon(self.pressed.?);
            self.dragging = true;
            self.damageDrag();
        }
        const previous_tick = self.last_tick;
        // The event loop sleeps while nothing animates, so the first step
        // after a quiet stretch is one frame, not the whole idle gap (which
        // would jump a new hover straight to its end).
        const step_ms = if (self.last_tick_active) now - previous_tick else @min(now - previous_tick, 16);
        const delta = std.math.clamp(@as(f64, @floatFromInt(step_ms)) / 150.0, 0, 1);
        self.last_tick = now;
        for (self.icons.items, 0..) |*ic, index| {
            const target_hover: f64 = if (self.hover == index) 1 else 0;
            const target_selection: f64 = if (ic.selected) 1 else 0;
            const previous_hover = ic.hover_amount;
            const previous_selection = ic.selection_amount;
            ic.hover_amount += std.math.clamp(target_hover - ic.hover_amount, -delta, delta);
            ic.selection_amount += std.math.clamp(target_selection - ic.selection_amount, -delta, delta);
            if (previous_hover != ic.hover_amount or previous_selection != ic.selection_amount or (now < self.launching_until and ic.selected)) self.damageIcon(index);
            if (ic.hover_amount != target_hover or ic.selection_amount != target_selection) active = true;
        }
        var i: usize = 0;
        while (i < self.icons.items.len) {
            const ic = self.icons.items[i];
            if (ic.removed) |t| {
                if (now - t >= 150) {
                    var removed = self.icons.orderedRemove(i);
                    removed.name_cache.deinit();
                    removed.raster.deinit();
                    freeItem(removed.item);
                    self.hover = null;
                    self.pressed = null;
                    self.last_icon = null;
                    self.menu = false;
                    self.invalidate();
                    self.persist();
                    continue;
                }
                active = true;
                self.damageIcon(i);
            } else if (previous_tick - ic.born < 200) {
                active = now - ic.born < 200 or active;
                self.damageIcon(i);
            }
            i += 1;
        }
        self.last_tick_active = active;
        return active;
    }
    // app_paint.zig
    pub const paint = app_paint.paint;
    pub const paintAt = app_paint.paintAt;
    pub const paintRect = app_paint.paintRect;
    pub const render = app_paint.render;
    pub const promptRect = app_paint.promptRect;
    pub const overlayRect = app_paint.overlayRect;
    pub const paintOverlay = app_paint.paintOverlay;
};

test {
    _ = @import("app_tests.zig");
}
