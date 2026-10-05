const std = @import("std");
const appearance_theme = @import("ui").theme;
const shell_cairo = @import("ui").cairo;
const c = @import("c.zig").api;
const grid = @import("grid.zig");
const watcher = @import("watcher.zig");
const text = @import("ui").text;
const config = @import("config.zig");
const damage_mod = @import("damage.zig");
pub const Damage = damage_mod.Damage;
const rename = @import("rename.zig");
const deletion = @import("../delete_dialog.zig");
const Host = @import("host.zig").Host;
const host_mod = @import("host.zig");
const context_menu = @import("ui").context_menu;
const Menu = @import("menu.zig").Menu;
const a = std.heap.c_allocator;
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

    fn replaceItem(self: *Icon, item: watcher.Item) void {
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
    edit: enum { none, rename, folder, file, trash, properties, add_file, add_app, open_with } = .none,
    deletion: deletion.State = .{},
    catalog: []const @import("dotdesktop.zig").parser.AppEntry = &.{},
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
    fn damageRect(self: *App, r: grid.Rect) void {
        self.dirty = true;
        self.damage.add(r);
    }
    fn damageIcon(self: *App, index: usize) void {
        if (index >= self.icons.items.len) return;
        self.damageRect(self.iconRect(index));
    }
    fn iconRect(self: *App, index: usize) grid.Rect {
        var r = self.geometry.rect(self.icons.items[index].cell);
        if (self.dragging and self.pressed == index) {
            r.x = @intFromFloat(self.x - 48);
            r.y = @intFromFloat(self.y - 40);
        }
        return r;
    }
    fn damageDrag(self: *App) void {
        if (!self.dragging) return;
        if (self.pressed) |i| self.damageIcon(i);
        self.damageRect(damage_mod.expand(self.geometry.rect(self.geometry.snap(self.x, self.y)), 1));
    }
    pub fn deinit(self: *App) void {
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
        self.invalidate();
        if (layout_changed) self.persist();
    }
    /// Re-reads the reserved bottom strip, e.g. after the taskbar resized.
    pub fn refreshBottom(self: *App) void {
        self.geometry.bottom = self.bottom_config orelse self.host.bottomExclusion() orelse 64;
    }
    /// Home and Trash start in the top-left corner (cells count from the right).
    fn defaultCell(self: *App, builtin: watcher.Builtin) grid.Cell {
        return .{ .col = self.geometry.cols() - 1, .row = @as(i32, @intFromEnum(builtin)) - 1 };
    }
    fn valid(self: *App, cell: grid.Cell) bool {
        return cell.col >= 0 and cell.row >= 0 and cell.col < self.geometry.cols() and cell.row < self.geometry.rows();
    }
    fn occupied(self: *App, cell: grid.Cell, skip: ?usize) bool {
        for (self.icons.items, 0..) |ic, i| if (skip != i and ic.cell.col == cell.col and ic.cell.row == cell.row and ic.removed == null) return true;
        return false;
    }
    fn firstEmpty(self: *App) grid.Cell {
        var i: usize = 0;
        while (i <= self.icons.items.len) : (i += 1) {
            const cell = self.geometry.cell(i);
            if (!self.occupied(cell, null)) return cell;
        }
        return self.geometry.cell(i);
    }
    pub fn resize(self: *App, w: i32, h: i32) void {
        var unmoved: [2]bool = @splat(false);
        for (self.icons.items) |ic| if (ic.item.builtin != .none and ic.removed == null) {
            const cell = self.defaultCell(ic.item.builtin);
            unmoved[@intFromEnum(ic.item.builtin) - 1] = ic.cell.col == cell.col and ic.cell.row == cell.row;
        };
        self.geometry.w = w;
        self.geometry.h = h;
        for (self.icons.items) |*ic| if (ic.item.builtin != .none and unmoved[@intFromEnum(ic.item.builtin) - 1]) {
            ic.cell = self.defaultCell(ic.item.builtin);
        };
        for (self.icons.items, 0..) |*ic, i| if (!self.valid(ic.cell) or self.occupied(ic.cell, i)) {
            ic.cell = self.firstEmpty();
        };
        self.invalidate();
    }
    pub fn hit(self: *App, x: f64, y: f64) ?usize {
        for (self.icons.items, 0..) |ic, i| if (ic.removed == null and self.geometry.rect(ic.cell).contains(x, y)) return i;
        return null;
    }
    fn renameGeometry(self: *App) ?rename.Geometry {
        if (self.edit != .rename) return null;
        for (self.icons.items) |ic| {
            if (ic.selected and ic.removed == null) return rename.Geometry.init(self.geometry.rect(ic.cell), self.geometry);
        }
        return null;
    }
    pub fn motion(self: *App, x: f64, y: f64) void {
        self.pointerMotion(x, y);
        self.syncCursor();
    }
    fn pointerMotion(self: *App, x: f64, y: f64) void {
        if (self.edit == .trash) {
            if (self.deletion.motion(self.geometry.w, self.geometry.h - self.geometry.bottom, x, y)) self.invalidate();
            const g = self.deletion.geometry(self.geometry.w, self.geometry.h - self.geometry.bottom);
            const changed = g.target(self.x, self.y) != g.target(x, y);
            self.x = x;
            self.y = y;
            if (changed) self.invalidate();
            return;
        }
        const moved = self.x != x or self.y != y;
        if (moved) self.damageDrag();
        self.x = x;
        self.y = y;
        const hover = if (self.edit == .rename) null else self.hit(x, y);
        if (self.hover != hover) {
            if (self.hover) |i| self.damageIcon(i);
            self.hover = hover;
            if (hover) |i| self.damageIcon(i);
        }
        if (self.renameGeometry()) |g| {
            if (self.rename_editor.selecting) self.rename_editor.point(g, x, true);
            if (moved) self.damageRect(damage_mod.expand(g.panel, 2));
            return;
        }
        if (self.menu) {
            if (self.menu_layout.hit(x, y)) |row| {
                if (self.menu_selected != row) {
                    self.menu_selected = row;
                    self.invalidate();
                }
            }
        }
        if (!self.dragging and self.pressed != null and nowMs() - self.down_at >= 150 and (@abs(x - self.down_x) > 4 or @abs(y - self.down_y) > 4)) {
            self.damageIcon(self.pressed.?);
            self.dragging = true;
            self.damageDrag();
        }
        if (self.rubber) {
            const r = self.selectionRect();
            for (self.icons.items) |*ic| {
                ic.selected = ic.removed == null and r.intersects(self.geometry.rect(ic.cell));
            }
        }
        if (moved) {
            self.damageDrag();
            if (self.rubber) {
                self.dirty = true;
            }
        }
    }
    pub fn leave(self: *App) void {
        self.deletion.placement.grab = null;
        if (self.hover != null) {
            self.damageIcon(self.hover.?);
            self.hover = null;
        }
    }
    fn selectionRect(self: *App) grid.Rect {
        return .{ .x = @intFromFloat(@min(self.x, self.down_x)), .y = @intFromFloat(@min(self.y, self.down_y)), .w = @intFromFloat(@abs(self.x - self.down_x)), .h = @intFromFloat(@abs(self.y - self.down_y)) };
    }
    pub fn deselect(self: *App) void {
        for (self.icons.items) |*ic| ic.selected = false;
        self.invalidate();
    }
    pub fn button(self: *App, button_code: u32, pressed: bool) void {
        const was_menu = self.menu;
        const was_delete_dialog = self.edit == .trash;
        const was_renaming = self.edit == .rename;
        const menu_hit = was_menu and self.menu_layout.hit(self.x, self.y) != null;
        if (pressed) self.endLaunch();
        self.pointerButton(button_code, pressed);
        self.syncCursor();
        if (pressed) {
            self.host.keyboard(self.hit(self.x, self.y) != null or self.menu or self.edit != .none or menu_hit or was_delete_dialog or was_renaming);
        }
    }
    fn pointerButton(self: *App, button_code: u32, pressed: bool) void {
        self.invalidate();
        if (self.edit == .trash and button_code == 272 and self.deletion.pointerButton(self.geometry.w, self.geometry.h - self.geometry.bottom, self.x, self.y, pressed)) return;
        if (self.renameGeometry()) |g| {
            if (button_code != 272) return;
            if (!pressed) {
                self.rename_editor.selecting = false;
                return;
            }
            if (g.confirm.contains(self.x, self.y)) {
                self.finishEdit();
            } else if (g.cancel.contains(self.x, self.y)) {
                self.edit = .none;
            } else if (g.field.contains(self.x, self.y)) {
                self.rename_editor.point(g, self.x, self.shift);
                self.rename_editor.selecting = true;
            } else if (!g.panel.contains(self.x, self.y)) {
                self.edit = .none;
            }
            return;
        }
        if (!pressed) {
            if (button_code != 272) return;
            if (self.dragging) {
                if (self.pressed) |index| {
                    const target = self.geometry.snap(self.x, self.y);
                    const old = self.icons.items[index].cell;
                    for (self.icons.items, 0..) |*ic, i| {
                        if (i != index and ic.cell.col == target.col and ic.cell.row == target.row) ic.cell = old;
                    }
                    self.icons.items[index].cell = target;
                    self.persist();
                }
                self.last_icon = null;
            }
            self.pressed = null;
            self.dragging = false;
            self.rubber = false;
            return;
        }
        if (self.edit == .trash) {
            if (button_code == 272) self.deleteAction(self.deletion.geometry(self.geometry.w, self.geometry.h - self.geometry.bottom).hit(self.x, self.y));
            return;
        }
        if (self.edit != .none) {
            if (button_code == 272 and (self.edit == .add_app or self.edit == .open_with)) {
                const px = @divTrunc(self.geometry.w - 480, 2);
                const py = @divTrunc(self.geometry.h - 360, 2);
                if (self.x >= @as(f64, @floatFromInt(px)) and self.x < @as(f64, @floatFromInt(px + 480)) and self.y >= @as(f64, @floatFromInt(py + 64))) {
                    const row: usize = @intFromFloat(@floor((self.y - @as(f64, @floatFromInt(py + 64))) / 32));
                    if (row < 8) {
                        self.choice = (self.choice / 8) * 8 + row;
                        self.finishEdit();
                    }
                }
            }
            return;
        }
        if (self.menu) {
            if (button_code == 272) {
                if (self.menu_layout.hit(self.x, self.y)) |row| self.menuAction(row);
            }
            self.menu = false;
            return;
        }
        const hit_icon = self.hit(self.x, self.y);
        if (button_code == 273) {
            self.menu_icon = hit_icon;
            self.menu = true;
            self.menu_selected = 0;
            if (hit_icon) |i| {
                if (!self.icons.items[i].selected) {
                    self.deselect();
                    self.icons.items[i].selected = true;
                }
            } else self.deselect();
            self.menu_x = std.math.clamp(@as(i32, @intFromFloat(self.x)), 0, @max(0, self.geometry.w - context_menu.width));
            // Clamp above the taskbar's reserved strip (geometry.bottom), not
            // the raw output height: the taskbar renders on top of this
            // background layer, so a menu clamped only to geometry.h can end
            // up partly hidden underneath it.
            self.menu_y = std.math.clamp(@as(i32, @intFromFloat(self.y)), self.geometry.top, @max(self.geometry.top, self.geometry.h - self.geometry.bottom - Menu.height(self.menuLabels().len, hit_icon != null)));
            self.menu_layout.layout(self.menu_x, self.menu_y, self.menuLabels().len, hit_icon != null);
            return;
        }
        if (button_code != 272) return;
        self.down_x = self.x;
        self.down_y = self.y;
        self.down_at = nowMs();
        self.pressed = hit_icon;
        if (hit_icon) |i| {
            const was_selected = self.icons.items[i].selected;
            if (!self.ctrl) self.deselect();
            self.icons.items[i].selected = if (self.ctrl) !was_selected else true;
            if (!self.ctrl and self.last_icon == i and self.down_at - self.last_click <= 400) {
                self.openSelected();
                self.last_icon = null;
                self.pressed = null;
            } else {
                self.last_icon = i;
                self.last_click = self.down_at;
            }
        } else {
            if (!self.ctrl) self.deselect();
            self.rubber = true;
            self.last_icon = null;
        }
    }
    pub fn openSelected(self: *App) void {
        self.launch_token +%= 1;
        self.launch_after_id = self.host.newestWindow();
        self.launched = null;
        var launching = false;
        for (self.icons.items) |ic| if (ic.selected and ic.removed == null) {
            if (ic.item.untrusted) {
                self.notify("This launcher is not trusted. Right-click it and choose Allow Launching.", .{});
                continue;
            }
            self.worker.enqueue(.{ .kind = .launch, .path = ic.item.path, .value = ic.item.exec, .terminal = ic.item.terminal, .folder = ic.item.folder, .token = self.launch_token });
            launching = true;
        };
        if (!launching) return;
        self.launching_until = nowMs() + 30000;
        self.syncCursor();
    }
    /// Stops the busy state: its window appeared, it timed out, or the user
    /// moved on.
    fn endLaunch(self: *App) void {
        if (self.launching_until != 0) self.invalidate();
        self.launching_until = 0;
        self.launched = null;
        self.syncCursor();
    }
    fn wantedCursor(self: *App) host_mod.Cursor {
        if (self.dragging) return .grabbing;
        if (self.renameGeometry()) |g| {
            if (self.rename_editor.selecting or g.field.contains(self.x, self.y)) return .text;
        }
        return if (self.launching_until != 0) .busy else .normal;
    }
    fn syncCursor(self: *App) void {
        const wanted = self.wantedCursor();
        if (wanted == self.cursor) return;
        self.cursor = wanted;
        self.host.cursor(wanted);
    }
    fn updateLaunch(self: *App, now: i64) void {
        if (self.worker.takeLaunched()) |launched| {
            if (launched.token == self.launch_token) self.launched = launched;
        }
        if (self.launching_until == 0) return;
        if (now >= self.launching_until) return self.endLaunch();
        const launched = &(self.launched orelse return);
        if (self.host.windowAppeared(launched.pid, launched.app(), self.launch_after_id)) self.endLaunch();
    }
    /// Keyboard focus moved elsewhere. `refocusing` means a click already
    /// asked for it back, so open menus and edits survive the late leave.
    pub fn keyboardLeft(self: *App, refocusing: bool) void {
        self.ctrl = false;
        self.shift = false;
        if (!refocusing) {
            self.menu = false;
            self.deletion.deinit();
            self.edit = .none;
        }
        self.invalidate();
    }
    fn persist(self: *App) void {
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
    /// Which held keys the host repeats: text and caret keys while editing,
    /// menu, list and icon navigation otherwise. The delete dialog, Return,
    /// Escape and Ctrl shortcuts fire once.
    pub fn keyRepeats(self: *const App, sym: u32, utf8: []const u8) bool {
        if (self.edit == .trash or self.ctrl) return false;
        const vertical = sym == c.XKB_KEY_Up or sym == c.XKB_KEY_Down;
        if (self.menu) return vertical;
        const typing = switch (sym) {
            c.XKB_KEY_BackSpace, c.XKB_KEY_Delete, c.XKB_KEY_Left, c.XKB_KEY_Right => true,
            else => utf8.len > 0 and utf8[0] >= 32 and utf8[0] != 127,
        };
        if (self.edit == .rename) return typing;
        if (self.edit != .none) return typing or vertical;
        return vertical or sym == c.XKB_KEY_Left or sym == c.XKB_KEY_Right;
    }

    pub fn key(self: *App, sym: u32, utf8: []const u8) void {
        defer self.syncCursor();
        self.invalidate();
        if (self.edit == .trash) {
            self.deleteAction(self.deletion.key(sym));
            return;
        }
        if (sym == c.XKB_KEY_Escape) {
            self.edit = .none;
            self.menu = false;
            self.deselect();
            self.endLaunch();
            self.host.keyboard(false);
            return;
        }
        if (self.menu) {
            const count = self.menuLabels().len;
            if (sym == c.XKB_KEY_Down) self.menu_selected = (self.menu_selected + 1) % count else if (sym == c.XKB_KEY_Up) self.menu_selected = (self.menu_selected + count - 1) % count else if (sym == c.XKB_KEY_Return) {
                self.menuAction(self.menu_selected);
                self.menu = false;
            }
            return;
        }
        if (self.edit == .rename) {
            if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) self.finishEdit() else self.rename_editor.key(sym, utf8, self.ctrl, self.shift);
            return;
        }
        if (self.edit != .none) {
            if (self.ctrl and (sym == c.XKB_KEY_a or sym == c.XKB_KEY_A)) {
                self.edit_text.clearRetainingCapacity();
                self.choice = 0;
                return;
            }
            if (self.edit == .add_app or self.edit == .open_with) {
                if (sym == c.XKB_KEY_Down) {
                    if (self.choiceEntry(self.choice + 1) != null) self.choice += 1;
                    return;
                }
                if (sym == c.XKB_KEY_Up) {
                    self.choice -|= 1;
                    return;
                }
            }
            if (sym == c.XKB_KEY_Return) {
                self.finishEdit();
                return;
            }
            if (sym == c.XKB_KEY_BackSpace) {
                self.choice = 0;
                if (self.edit_text.items.len > 0) {
                    var n = self.edit_text.items.len - 1;
                    while (n > 0 and self.edit_text.items[n] & 0xc0 == 0x80) n -= 1;
                    self.edit_text.shrinkRetainingCapacity(n);
                }
            } else if (utf8.len > 0 and utf8[0] >= 32 and self.edit_text.items.len + utf8.len < 255) {
                self.choice = 0;
                self.edit_text.appendSlice(a, utf8) catch {};
            }
            return;
        }
        if (self.ctrl) {
            switch (sym) {
                c.XKB_KEY_a, c.XKB_KEY_A => {
                    for (self.icons.items) |*ic| {
                        ic.selected = ic.removed == null;
                    }
                },
                c.XKB_KEY_c, c.XKB_KEY_C => self.copy(false),
                c.XKB_KEY_x, c.XKB_KEY_X => self.copy(true),
                c.XKB_KEY_v, c.XKB_KEY_V => self.paste(),
                else => {},
            }
            return;
        }
        switch (sym) {
            c.XKB_KEY_Return => self.openSelected(),
            c.XKB_KEY_F2 => self.beginEdit(.rename),
            c.XKB_KEY_Delete => self.beginEdit(.trash),
            c.XKB_KEY_Left, c.XKB_KEY_Right, c.XKB_KEY_Up, c.XKB_KEY_Down => {
                var selected: ?usize = null;
                for (self.icons.items, 0..) |ic, i| if (ic.selected) {
                    selected = i;
                    break;
                };
                if (selected) |index| {
                    var target = self.icons.items[index].cell;
                    switch (sym) {
                        c.XKB_KEY_Left => target.col += 1,
                        c.XKB_KEY_Right => target.col -= 1,
                        c.XKB_KEY_Up => target.row -= 1,
                        else => target.row += 1,
                    }
                    for (self.icons.items, 0..) |ic, i| if (ic.removed == null and ic.cell.col == target.col and ic.cell.row == target.row) {
                        self.deselect();
                        self.icons.items[i].selected = true;
                        break;
                    };
                } else if (self.icons.items.len > 0) {
                    self.icons.items[0].selected = true;
                }
            },
            else => {},
        }
    }
    fn copy(self: *App, cut: bool) void {
        for (self.clipboard.items) |p| a.free(p);
        self.clipboard.clearRetainingCapacity();
        self.cut = cut;
        for (self.icons.items) |ic| if (ic.selected and ic.item.builtin == .none) {
            self.clipboard.append(a, a.dupe(u8, ic.item.path) catch continue) catch {};
        };
        self.host.publishSelection(self.clipboard.items, cut);
    }
    fn paste(self: *App) void {
        if (self.host.paste(self.worker.dir) == .local) self.pasteLocal();
    }
    fn pasteLocal(self: *App) void {
        for (self.clipboard.items) |path| {
            const dest = std.fmt.allocPrint(a, "{s}/{s}", .{ self.worker.dir, std.fs.path.basename(path) }) catch continue;
            defer a.free(dest);
            self.worker.enqueue(.{ .kind = if (self.cut) .move else .copy, .path = path, .value = dest });
        }
    }
    fn menuBuiltin(self: *const App) watcher.Builtin {
        const index = self.menu_icon orelse return .none;
        return if (index < self.icons.items.len) self.icons.items[index].item.builtin else .none;
    }
    fn menuLabels(self: *App) []const []const u8 {
        switch (self.menuBuiltin()) {
            .home => return &.{"Open"},
            .trash => return &.{ "Open", "Empty Trash" },
            .none => {},
        }
        const icon_labels = [_][]const u8{ "Open", "Open With…", "Cut", "Copy", "Rename", "Move to Trash", "Properties", "Allow Launching" };
        if (self.menu_icon) |index| return if (self.untrustedLauncher(index)) &icon_labels else icon_labels[0 .. icon_labels.len - 1];
        return &.{ "New Folder", "New File", "Add Application…", "Add File…", "Paste", "Refresh", "Change Wallpaper", "Desktop Settings" };
    }
    fn menuIcon(self: *App, row: usize) @import("ui").layout.IconId {
        const IconId = @import("ui").layout.IconId;
        if (self.menuBuiltin() != .none) return if (row == 0) .chevron_right else .trash;
        return if (self.menu_icon != null)
            ([_]IconId{ .chevron_right, .grid, .cut, .copy, .edit, .trash, .view_list, .checkmark })[row]
        else
            ([_]IconId{ .plus, .edit, .grid, .open, .paste, .refresh, .display, .settings })[row];
    }
    fn menuHint(self: *App, row: usize) ?[]const u8 {
        if (self.menuBuiltin() != .none) return if (row == 0) "ENTER" else null;
        return if (self.menu_icon != null)
            ([_]?[]const u8{ "ENTER", null, "CTRL+X", "CTRL+C", "F2", "DELETE", null, null })[row]
        else if (row == 4) "CTRL+V" else null;
    }
    fn untrustedLauncher(self: *const App, index: usize) bool {
        return index < self.icons.items.len and self.icons.items[index].item.untrusted;
    }
    fn menuAction(self: *App, row: usize) void {
        const builtin = self.menuBuiltin();
        if (builtin != .none) {
            if (row == 0) self.openSelected() else if (builtin == .trash and row == 1)
                self.worker.enqueue(.{ .kind = .empty_trash, .path = "" });
            return;
        }
        if (self.menu_icon != null) {
            switch (row) {
                0 => self.openSelected(),
                1 => self.beginEdit(.open_with),
                2 => self.copy(true),
                3 => self.copy(false),
                4 => self.beginEdit(.rename),
                5 => self.beginEdit(.trash),
                6 => self.beginEdit(.properties),
                // Allow Launching: the user marks the launcher executable,
                // after which it shows and runs as the application it names.
                7 => for (self.icons.items) |ic| if (ic.selected and ic.removed == null and ic.item.untrusted) {
                    self.worker.enqueue(.{ .kind = .trust, .path = ic.item.path });
                },
                else => {},
            }
        } else {
            switch (row) {
                0 => self.beginEdit(.folder),
                1 => self.beginEdit(.file),
                2 => self.beginEdit(.add_app),
                3 => self.beginEdit(.add_file),
                4 => self.paste(),
                5 => self.worker.requestRefresh(),
                6 => self.host.openAppearance() catch |err| switch (err) {
                    error.Unsupported => self.worker.enqueue(.{ .kind = .settings, .path = "" }),
                    else => self.notify("Could not open Appearance: {s}", .{@errorName(err)}),
                },
                7 => self.worker.enqueue(.{ .kind = .settings, .path = "" }),
                else => {},
            }
        }
    }
    fn beginEdit(self: *App, kind: @FieldType(App, "edit")) void {
        self.deletion.deinit();
        self.edit = kind;
        if (kind == .trash) {
            for (self.icons.items) |ic| {
                if (!ic.selected or ic.removed != null or ic.item.builtin != .none) continue;
                self.deletion.add(ic.item.path, ic.item.name, ic.item.folder, ic.item.bytes, if (self.deletion.paths.items.len == 0) ic.item.icon else null) catch {
                    self.deletion.deinit();
                    self.edit = .none;
                    return;
                };
            }
            if (self.deletion.paths.items.len == 0) self.edit = .none;
            return;
        }
        self.choice = 0;
        if (kind == .add_app or kind == .open_with) self.worker.enqueue(.{ .kind = .catalog, .path = "" });
        self.edit_text.clearRetainingCapacity();
        if (kind == .rename) {
            for (self.icons.items, 0..) |ic, i| if (ic.selected and ic.removed == null and ic.item.builtin == .none) {
                self.rename_editor.begin(std.fs.path.basename(ic.item.path), ic.item.folder) catch {
                    self.edit = .none;
                    return;
                };
                self.deselect();
                self.icons.items[i].selected = true;
                self.pressed = null;
                self.dragging = false;
                self.rubber = false;
                self.last_icon = null;
                return;
            };
            self.edit = .none;
        }
        if (kind == .folder or kind == .file) self.edit_text.appendSlice(a, if (kind == .folder) "New Folder" else "New File") catch {};
    }
    fn deleteAction(self: *App, action: deletion.Action) void {
        switch (action) {
            .cancel => {
                self.deletion.deinit();
                self.edit = .none;
            },
            .toggle => {
                self.deletion.permanent = !self.deletion.permanent;
                self.deletion.focus = .toggle;
            },
            .confirm => self.finishEdit(),
            .none => {},
        }
        self.invalidate();
    }
    fn finishEdit(self: *App) void {
        if (self.edit == .rename) {
            if (self.renameGeometry() == null) {
                self.edit = .none;
                return;
            }
            self.edit_text.clearRetainingCapacity();
            self.edit_text.appendSlice(a, self.rename_editor.value()) catch return;
        }
        if ((self.edit == .add_app or self.edit == .open_with) and self.choiceEntry(self.choice) == null) return;
        if (self.edit == .add_file and !std.fs.path.isAbsolute(self.edit_text.items)) return;
        if (self.edit == .file or self.edit == .folder or self.edit == .rename) {
            const name = self.edit_text.items;
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return;
        }
        defer self.edit = .none;
        if (self.edit == .trash) {
            for (self.deletion.paths.items) |path| {
                self.worker.enqueue(.{ .kind = if (self.deletion.permanent) .delete else .trash, .path = path });
            }
            self.deletion.deinit();
            return;
        }
        if (self.edit == .add_app or self.edit == .open_with) {
            const entry = self.choiceEntry(self.choice) orelse return;
            if (self.edit == .add_app) {
                const dest = std.fmt.allocPrint(a, "{s}/{s}", .{ self.worker.dir, std.fs.path.basename(entry.desktop_file_path) }) catch return;
                defer a.free(dest);
                self.worker.enqueue(.{ .kind = .copy, .path = entry.desktop_file_path, .value = dest });
            } else {
                for (self.icons.items) |ic| {
                    if (ic.selected) self.worker.enqueue(.{ .kind = .launch, .path = ic.item.path, .value = entry.exec, .terminal = entry.terminal, .launch_file = true });
                }
            }
            return;
        }
        if (self.edit == .add_file) {
            const path = self.edit_text.items;
            if (!std.fs.path.isAbsolute(path)) return;
            const dest = std.fmt.allocPrint(a, "{s}/{s}", .{ self.worker.dir, std.fs.path.basename(path) }) catch return;
            defer a.free(dest);
            self.worker.enqueue(.{ .kind = .link, .path = path, .value = dest });
            return;
        }
        if (self.edit == .properties) return;
        const name = self.edit_text.items;
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return;
        const dest = std.fmt.allocPrint(a, "{s}/{s}", .{ self.worker.dir, name }) catch return;
        defer a.free(dest);
        if (self.edit == .rename) {
            for (self.icons.items) |ic| if (ic.selected) {
                if (std.mem.eql(u8, ic.item.path, dest)) return;
                self.worker.enqueue(.{ .kind = .rename, .path = ic.item.path, .value = dest });
                break;
            };
        } else {
            self.worker.enqueue(.{ .kind = if (self.edit == .folder) .folder else .file, .path = dest });
        }
    }
    fn choiceEntry(self: *App, index: usize) ?@import("dotdesktop.zig").parser.AppEntry {
        var n: usize = 0;
        for (self.catalog) |entry| {
            if (self.edit_text.items.len > 0 and std.ascii.indexOfIgnoreCase(entry.name, self.edit_text.items) == null) continue;
            if (n == index) return entry;
            n += 1;
        }
        return null;
    }
    /// The selection band rasterized with its own bounds as the only clip. A
    /// repair can split the band's corners across several rectangular clips,
    /// and Cairo's arc coverage depends on the clip, so drawing it per pass
    /// left pixels one level off a freshly drawn band.
    fn rasterBand(self: *App, cr: *c.cairo_t) ?*c.cairo_pattern_t {
        const bounds = damage_mod.expand(self.selectionRect(), 2);
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        c.cairo_reset_clip(cr);
        c.cairo_rectangle(cr, @floatFromInt(bounds.x), @floatFromInt(bounds.y), @floatFromInt(bounds.w), @floatFromInt(bounds.h));
        c.cairo_clip(cr);
        c.cairo_push_group(cr);
        self.drawBand(cr);
        const band = c.cairo_pop_group(cr) orelse return null;
        if (c.cairo_pattern_status(band) != c.CAIRO_STATUS_SUCCESS) {
            c.cairo_pattern_destroy(band);
            return null;
        }
        return band;
    }
    fn drawBand(self: *App, cr: *c.cairo_t) void {
        const r = self.selectionRect();
        const rad: f64 = @min(@as(f64, damage_mod.rubberband_radius), @as(f64, @floatFromInt(@min(r.w, r.h))) / 2.0);
        rounded(cr, r.x, r.y, r.w, r.h, rad);
        shell_cairo.setSource(cr, appearance_theme.global.desktop_selection);
        c.cairo_fill_preserve(cr);
        shell_cairo.setSource(cr, appearance_theme.global.desktop_selection_border);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);
    }
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
    fn notify(self: *App, comptime format: []const u8, args: anytype) void {
        const message: []const u8 = std.fmt.bufPrint(&self.notice, format, args) catch "";
        self.notice_len = message.len;
        self.notice_until = nowMs() + 5000;
        self.invalidate();
    }
    pub fn tick(self: *App) bool {
        const now = nowMs();
        const error_len = self.worker.takeError(&self.notice);
        if (error_len > 0) {
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
    pub fn paint(self: *App, cr: *c.cairo_t, damage: *const Damage) void {
        self.paintAt(cr, damage, nowMs(), true);
    }
    fn paintAt(self: *App, cr: *c.cairo_t, damage: *const Damage, now: i64, cached: bool) void {
        const context = IconRaster.Context.from(cr);
        // One band raster for every repair pass: see `rasterBand`.
        self.band = if (self.rubber) self.rasterBand(cr) else null;
        defer if (self.band) |band| {
            c.cairo_pattern_destroy(band);
            self.band = null;
        };
        if (damage.full) return self.render(cr, damage, now, context, cached);
        // Union overlapping damage without turning disjoint regions into one
        // complex Cairo clip: each pixel needs one rectangular repaint pass.
        const region = c.cairo_region_create();
        defer c.cairo_region_destroy(region);
        for (damage.rects[0..damage.len]) |r| {
            const rect = c.cairo_rectangle_int_t{ .x = r.x, .y = r.y, .width = r.w, .height = r.h };
            _ = c.cairo_region_union_rectangle(region, &rect);
        }
        if (c.cairo_region_status(region) != c.CAIRO_STATUS_SUCCESS) {
            for (damage.rects[0..damage.len]) |r| self.paintRect(cr, r, now, context, cached);
            return;
        }
        var i: c_int = 0;
        while (i < c.cairo_region_num_rectangles(region)) : (i += 1) {
            var r: c.cairo_rectangle_int_t = undefined;
            c.cairo_region_get_rectangle(region, i, &r);
            self.paintRect(cr, .{ .x = r.x, .y = r.y, .w = r.width, .h = r.height }, now, context, cached);
        }
    }
    fn paintRect(self: *App, cr: *c.cairo_t, r: grid.Rect, now: i64, context: IconRaster.Context, cached: bool) void {
        // Complex clips change Cairo stroke coverage. Keep one timestamp and a
        // rectangular clip per pass, while sharing icon rasters across passes.
        c.cairo_save(cr);
        c.cairo_new_path(cr);
        // Snap the clip outward to whole device pixels. At a fractional scale
        // a logical edge would otherwise blend half-covered pixels with the
        // stale contents underneath. Paths live in device space, so building
        // it under the identity matrix survives restoring the transform.
        var x0: f64 = @floatFromInt(r.x);
        var y0: f64 = @floatFromInt(r.y);
        var x1: f64 = @floatFromInt(r.x + r.w);
        var y1: f64 = @floatFromInt(r.y + r.h);
        c.cairo_user_to_device(cr, &x0, &y0);
        c.cairo_user_to_device(cr, &x1, &y1);
        c.cairo_save(cr);
        c.cairo_identity_matrix(cr);
        c.cairo_rectangle(cr, @floor(@min(x0, x1)), @floor(@min(y0, y1)), @ceil(@max(x0, x1)) - @floor(@min(x0, x1)), @ceil(@max(y0, y1)) - @floor(@min(y0, y1)));
        c.cairo_restore(cr);
        c.cairo_clip(cr);
        var part = Damage{};
        part.clear();
        // Snapping can reach up to a device pixel past the logical rect.
        part.add(damage_mod.expand(r, 1));
        self.render(cr, &part, now, context, cached);
        c.cairo_restore(cr);
    }
    fn render(self: *App, cr: *c.cairo_t, damage: *const Damage, now: i64, context: IconRaster.Context, cached: bool) void {
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
        c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
        c.cairo_paint(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
        if (self.wallpaper) |im| @import("wallpaper.zig").render(im, cr, self.geometry.w, self.geometry.h);
        for (self.icons.items, 0..) |*ic, i| {
            const r = self.iconRect(i);
            if (!damage.intersects(r)) continue;
            const alpha = if (ic.removed) |t| 1 - std.math.clamp(@as(f64, @floatFromInt(now - t)) / 150, 0, 1) else std.math.clamp(@as(f64, @floatFromInt(now - ic.born)) / 200, 0, 1);
            const opacity = alpha * (if (self.dragging and self.pressed == i) @as(f64, 0.85) else 1);
            const name = ic.item.name;
            const raster_key = IconRaster.Key{
                .context = context,
                .rect = r,
                .hover = ic.hover_amount,
                .selection = ic.selection_amount,
                .pulse = if (now < self.launching_until and ic.selected) 1 + 0.035 * @sin(@as(f64, @floatFromInt(@mod(now, 800))) / 800.0 * 2 * std.math.pi) else 1,
                .renaming = self.edit == .rename and ic.selected,
            };
            const group = iconPattern(cr, ic, raster_key, name, cached);
            c.cairo_set_source(cr, group);
            c.cairo_paint_with_alpha(cr, opacity);
            c.cairo_pattern_destroy(group);
        }
        if (self.renameGeometry()) |g| {
            // Rasterize the complete overlay independently of the repair clip,
            // just like icons: clipping Cairo arcs changes their edge coverage.
            const bounds = damage_mod.expand(g.panel, 2);
            c.cairo_save(cr);
            c.cairo_reset_clip(cr);
            c.cairo_rectangle(cr, @floatFromInt(bounds.x), @floatFromInt(bounds.y), @floatFromInt(bounds.w), @floatFromInt(bounds.h));
            c.cairo_clip(cr);
            c.cairo_push_group(cr);
            self.rename_editor.draw(cr, g, self.x, self.y);
            const overlay = c.cairo_pop_group(cr);
            c.cairo_restore(cr);
            c.cairo_set_source(cr, overlay);
            c.cairo_paint(cr);
            c.cairo_pattern_destroy(overlay);
        }
        if (self.dragging) {
            const r = self.geometry.rect(self.geometry.snap(self.x, self.y));
            rounded(cr, r.x, r.y, r.w, r.h, 8);
            shell_cairo.setSource(cr, appearance_theme.global.desktop_drop_border);
            c.cairo_set_line_width(cr, 1);
            c.cairo_stroke(cr);
        }
        if (self.rubber) {
            if (self.band) |band| {
                c.cairo_set_source(cr, band);
                c.cairo_paint(cr);
            } else self.drawBand(cr);
        }
        if (self.menu) {
            const labels = self.menuLabels();
            context_menu.frame(cr, .{
                .x = @floatFromInt(self.menu_x),
                .y = @floatFromInt(self.menu_y),
                .w = context_menu.width,
                .h = @floatFromInt(Menu.height(labels.len, self.menu_icon != null)),
            }, true);
            for (labels, 0..) |s, i| {
                const row = self.menu_layout.rows[i];
                context_menu.row(cr, .{ .x = row.computed_x, .y = row.computed_y, .w = row.computed_width, .h = row.computed_height }, .{
                    .label = s,
                    .icon = self.menuIcon(i),
                    .hint = self.menuHint(i),
                    .selected = i == self.menu_selected,
                    .separator = Menu.separatorBefore(self.menu_icon != null, i),
                }, true);
            }
        }
        if (self.edit == .add_app or self.edit == .open_with) {
            const px = @divTrunc(self.geometry.w - 480, 2);
            const py = @divTrunc(self.geometry.h - 360, 2);
            rounded(cr, px, py, 480, 360, 10);
            shell_cairo.setSource(cr, appearance_theme.global.desktop_dialog_bg);
            c.cairo_fill(cr);
            label(cr, if (self.edit_text.items.len == 0) "Type to search applications — Enter chooses" else self.edit_text.items, px + 12, py + 12, 456, 40, false);
            var row: usize = 0;
            while (row < 8) : (row += 1) {
                const index = (self.choice / 8) * 8 + row;
                const entry = self.choiceEntry(index) orelse break;
                const y = py + 64 + @as(i32, @intCast(row)) * 32;
                if (index == self.choice) {
                    rounded(cr, px + 8, y, 464, 32, 4);
                    shell_cairo.setSource(cr, appearance_theme.global.desktop_selection);
                    c.cairo_fill(cr);
                }
                label(cr, entry.name, px + 12, y, 456, 32, false);
            }
        } else if (self.edit == .trash) {
            self.deletion.draw(cr, self.geometry.w, self.geometry.h - self.geometry.bottom, self.x, self.y, null);
        } else if (self.edit != .none and self.edit != .rename) {
            const x = @divTrunc(self.geometry.w - 420, 2);
            const y = @divTrunc(self.geometry.h - 120, 2);
            rounded(cr, x, y, 420, 120, 10);
            shell_cairo.setSource(cr, appearance_theme.global.desktop_dialog_bg);
            c.cairo_fill(cr);
            const title: []const u8 = switch (self.edit) {
                .properties => "Properties — Escape closes",
                .add_file => "Add File — enter an absolute path, then Enter",
                .rename => "Rename — Enter saves, Escape cancels",
                .folder => "New Folder — Enter creates",
                .file => "New File — Enter creates",
                else => "",
            };
            label(cr, title, x + 12, y + 12, 396, 32, false);
            var property_path = self.worker.dir;
            var details_buf: [128]u8 = undefined;
            var details: []const u8 = "";
            if (self.edit == .properties) for (self.icons.items) |ic| {
                if (ic.selected) {
                    property_path = ic.item.path;
                    details = std.fmt.bufPrint(&details_buf, "{s} · {d} bytes", .{ if (ic.item.folder) "Folder" else "File", ic.item.bytes }) catch "";
                    break;
                }
            };
            label(cr, if (self.edit == .properties) property_path else self.edit_text.items, x + 12, y + 44, 396, 32, false);
            if (self.edit == .properties) label(cr, details, x + 12, y + 78, 396, 26, false);
        }
        if (self.notice_until > now) {
            const w = @min(500, self.geometry.w - 48);
            const y = @max(24, self.geometry.h - self.geometry.bottom - 50);
            rounded(cr, 24, y, w, 36, 8);
            shell_cairo.setSource(cr, appearance_theme.global.desktop_notice_bg);
            c.cairo_fill(cr);
            label(cr, self.notice[0..self.notice_len], 32, y, w - 16, 36, false);
        }
    }
};
fn iconPattern(cr: *c.cairo_t, ic: *Icon, key: IconRaster.Key, name: []const u8, cached: bool) ?*c.cairo_pattern_t {
    if (cached and ic.raster.pattern != null and std.meta.eql(ic.raster.key, key) and
        (key.renaming or (ic.name_cache.surface != null and std.mem.eql(u8, ic.name_cache.name, name))))
    {
        return c.cairo_pattern_reference(ic.raster.pattern);
    }
    const r = key.rect;
    c.cairo_save(cr);
    // Unbounded groups allocate/clear/composite an output-sized image
    // for *every icon*. Retain the group for identical alpha blending,
    // but restrict its storage to this icon's bounds. Its raster clip
    // is independent of damage: clipping a rounded arc part-way across
    // the icon also changes Cairo's coverage rounding at scale 2.
    c.cairo_reset_clip(cr);
    c.cairo_rectangle(cr, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
    c.cairo_clip(cr);
    c.cairo_push_group(cr);
    if (ic.selection_amount > 0 or ic.hover_amount > 0) {
        rounded(cr, r.x, r.y, r.w, if (key.renaming) 68 else r.h, 8);
        const t = appearance_theme.global;
        var fill: [4]f32 = undefined;
        for (0..3) |i| fill[i] = @floatCast(t.desktop_hover[i] + (t.desktop_selected[i] - t.desktop_hover[i]) * ic.selection_amount);
        fill[3] = @floatCast(t.desktop_selected[3] * ic.selection_amount + t.desktop_hover[3] * ic.hover_amount * (1 - ic.selection_amount));
        shell_cairo.setSource(cr, fill);
        c.cairo_fill(cr);
    }
    c.cairo_save(cr);
    if (key.pulse != 1) {
        c.cairo_translate(cr, @floatFromInt(r.x + 48), @floatFromInt(r.y + 36));
        c.cairo_scale(cr, key.pulse, key.pulse);
        c.cairo_translate(cr, @floatFromInt(-r.x - 48), @floatFromInt(-r.y - 36));
    }
    if (ic.item.icon) |icon| {
        const surface = c.cairo_image_surface_create_for_data(@ptrCast(@constCast(icon.pixels.ptr)), c.CAIRO_FORMAT_ARGB32, icon.size, icon.size, icon.size * 4);
        defer c.cairo_surface_destroy(surface);
        // An icon loaded for this density (not pulsing) is copied 1:1.
        const raster = RasterScale.of(cr);
        if (raster.aligned and raster.pixels(56) == icon.size) {
            if (surface) |image| paintRaster(cr, image, r.x + 20, r.y + 8, raster);
        } else {
            c.cairo_save(cr);
            c.cairo_translate(cr, @floatFromInt(r.x + 20), @floatFromInt(r.y + 8));
            c.cairo_scale(cr, 56.0 / @as(f64, @floatFromInt(icon.size)), 56.0 / @as(f64, @floatFromInt(icon.size)));
            c.cairo_set_source_surface(cr, surface, 0, 0);
            c.cairo_paint(cr);
            c.cairo_restore(cr);
        }
    } else {
        rounded(cr, r.x + 20, r.y + 8, 56, 56, 12);
        const grad = c.cairo_pattern_create_linear(0, @floatFromInt(r.y), 0, @floatFromInt(r.y + 64));
        const start = appearance_theme.global.desktop_icon_start;
        const end = appearance_theme.global.desktop_icon_end;
        c.cairo_pattern_add_color_stop_rgba(grad, 0, start[0], start[1], start[2], start[3]);
        c.cairo_pattern_add_color_stop_rgba(grad, 1, end[0], end[1], end[2], end[3]);
        c.cairo_set_source(cr, grad);
        c.cairo_fill(cr);
        c.cairo_pattern_destroy(grad);
        const n = if (ic.item.name.len > 0) std.unicode.utf8ByteSequenceLength(ic.item.name[0]) catch 1 else 0;
        label(cr, ic.item.name[0..@min(n, ic.item.name.len)], r.x + 20, r.y + 20, 56, 26, false);
    }
    c.cairo_restore(cr);
    if (ic.selection_amount > 0 and !key.renaming) {
        rounded(cr, r.x + 4, r.y + 71, 88, 34, 3);
        var fill = appearance_theme.global.desktop_selection;
        fill[3] *= @floatCast(ic.selection_amount);
        shell_cairo.setSource(cr, fill);
        c.cairo_fill(cr);
    }
    if (!key.renaming) ic.name_cache.draw(cr, name, r.x + 4, r.y + 72);
    const group = c.cairo_pop_group(cr);
    c.cairo_restore(cr);
    if (cached and c.cairo_pattern_status(group) == c.CAIRO_STATUS_SUCCESS) {
        ic.raster.deinit();
        ic.raster.pattern = c.cairo_pattern_reference(group);
        ic.raster.key = key;
    }
    return group;
}

fn sameImage(current: ?@import("wallpaper.zig").Image, next: ?@import("wallpaper.zig").Image) bool {
    const x = current orelse return next == null;
    const y = next orelse return false;
    return x.w == y.w and x.h == y.h and x.mode == y.mode and std.mem.eql(u32, x.pixels, y.pixels);
}

fn copyItem(item: watcher.Item) !watcher.Item {
    var out = item;
    out.path = try a.dupe(u8, item.path);
    errdefer a.free(out.path);
    out.name = try a.dupe(u8, item.name);
    errdefer a.free(out.name);
    out.exec = try a.dupe(u8, item.exec);
    return out;
}
fn freeItem(item: watcher.Item) void {
    a.free(item.path);
    a.free(item.name);
    a.free(item.exec);
}
pub fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1000000);
}
pub fn rounded(cr: *c.cairo_t, x: i32, y: i32, w: i32, h: i32, r: f64) void {
    const xx: @TypeOf(r) = @floatFromInt(x);
    const yy: @TypeOf(r) = @floatFromInt(y);
    const ww: @TypeOf(r) = @floatFromInt(w);
    const hh: @TypeOf(r) = @floatFromInt(h);
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, xx + ww - r, yy + r, r, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, xx + ww - r, yy + hh - r, r, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, xx + r, yy + hh - r, r, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, xx + r, yy + r, r, std.math.pi, 3 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
}
/// One bounded raster per icon, including its selection/hover decoration. A
/// frame's damage can cross an icon repeatedly without rebuilding its curves,
/// icon texture and label; settled icons keep the same raster across frames.
const IconRaster = struct {
    pattern: ?*c.cairo_pattern_t = null,
    key: Key = undefined,

    const Context = struct {
        matrix: c.cairo_matrix_t,
        size: [2]i32,
        device_scale: [2]f64,
        device_offset: [2]f64,

        fn from(cr: *c.cairo_t) Context {
            const target = c.cairo_get_group_target(cr);
            var result: Context = undefined;
            c.cairo_get_matrix(cr, &result.matrix);
            result.size = .{ c.cairo_image_surface_get_width(target), c.cairo_image_surface_get_height(target) };
            c.cairo_surface_get_device_scale(target, &result.device_scale[0], &result.device_scale[1]);
            c.cairo_surface_get_device_offset(target, &result.device_offset[0], &result.device_offset[1]);
            return result;
        }
    };
    const Key = struct {
        context: Context,
        rect: grid.Rect,
        hover: f64,
        selection: f64,
        pulse: f64,
        renaming: bool,
    };

    fn deinit(self: *IconRaster) void {
        if (self.pattern) |pattern| c.cairo_pattern_destroy(pattern);
        self.pattern = null;
    }
};

const NameCache = struct {
    surface: ?*c.cairo_surface_t = null,
    name: []const u8 = &.{},
    scale: RasterScale = .{ .value = 0, .aligned = false },

    fn deinit(self: *NameCache) void {
        if (self.surface) |surface| c.cairo_surface_destroy(surface);
        a.free(self.name);
        self.* = .{};
    }

    fn draw(self: *NameCache, cr: *c.cairo_t, name: []const u8, x: i32, y: i32) void {
        const scale = RasterScale.of(cr);
        if (self.surface == null or !std.meta.eql(self.scale, scale) or !std.mem.eql(u8, self.name, name)) {
            self.deinit();
            const owned = a.dupe(u8, name) catch return drawName(cr, name, x, y);
            const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, scale.pixels(88), scale.pixels(32)) orelse {
                a.free(owned);
                return drawName(cr, name, x, y);
            };
            if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
                c.cairo_surface_destroy(surface);
                a.free(owned);
                return drawName(cr, name, x, y);
            }
            const cached_cr = c.cairo_create(surface).?;
            c.cairo_scale(cached_cr, scale.value, scale.value);
            drawName(cached_cr, name, 0, 0);
            c.cairo_destroy(cached_cr);
            self.* = .{ .surface = surface, .name = owned, .scale = scale };
        }
        paintRaster(cr, self.surface.?, x, y, self.scale);
    }
};

fn drawName(cr: *c.cairo_t, name: []const u8, x: i32, y: i32) void {
    var split: usize = name.len;
    if ((text.measureWidth(name, .manrope_bold, appearance_theme.global.desktop_text_size, 1) catch 0) > 88) {
        var it = std.mem.splitScalar(u8, name, ' ');
        var end: usize = 0;
        while (it.next()) |word| {
            const next = end + word.len;
            if (next > name.len) break;
            if ((text.measureWidth(name[0..next], .manrope_bold, appearance_theme.global.desktop_text_size, 1) catch 0) > 88) break;
            split = next;
            end = next + 1;
        }
    }
    label(cr, name[0..split], x, y, 88, 16, true);
    if (split < name.len) label(cr, std.mem.trimStart(u8, name[split..], " "), x, y + 16, 88, 16, true);
}
/// The scale to rasterize at for `cr`: exactly its device scale when that is
/// uniform (fractional outputs included), so `paintRaster` can copy pixels
/// 1:1; otherwise the next whole scale, resampled.
const RasterScale = struct {
    value: f64,
    aligned: bool,

    fn of(cr: *c.cairo_t) RasterScale {
        var m: c.cairo_matrix_t = undefined;
        c.cairo_get_matrix(cr, &m);
        if (m.xy == 0 and m.yx == 0 and m.xx == m.yy and m.xx >= 1 and m.xx <= 4) return .{ .value = m.xx, .aligned = true };
        return .{ .value = std.math.clamp(@ceil(@abs(m.xx)), 1, 4), .aligned = false };
    }

    fn pixels(self: RasterScale, logical: i32) i32 {
        return @intFromFloat(@ceil(@as(f64, @floatFromInt(logical)) * self.value));
    }
};

/// Paints a raster made at `scale` with its origin at logical (x, y). An
/// aligned raster lands on the nearest whole device pixel with no filtering,
/// so fractional scales stay as sharp as integer ones.
fn paintRaster(cr: *c.cairo_t, surface: *c.cairo_surface_t, x: i32, y: i32, scale: RasterScale) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    if (scale.aligned) {
        var dx: f64 = @floatFromInt(x);
        var dy: f64 = @floatFromInt(y);
        c.cairo_user_to_device(cr, &dx, &dy);
        c.cairo_identity_matrix(cr);
        c.cairo_set_source_surface(cr, surface, @round(dx), @round(dy));
    } else {
        c.cairo_translate(cr, @floatFromInt(x), @floatFromInt(y));
        c.cairo_scale(cr, 1.0 / scale.value, 1.0 / scale.value);
        c.cairo_set_source_surface(cr, surface, 0, 0);
    }
    c.cairo_paint(cr);
}

fn themeInk(color: [4]f32) text.Color {
    return .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] };
}

pub fn label(cr: *c.cairo_t, s: []const u8, x: i32, y: i32, w: i32, h: i32, shadow: bool) void {
    if (w <= 0 or h <= 0) return;
    const raster = RasterScale.of(cr);
    const scale: f32 = @floatCast(raster.value);
    const pw = raster.pixels(w);
    const ph = raster.pixels(h);
    const pixels = a.alloc(u32, @intCast(pw * ph)) catch return;
    defer a.free(pixels);
    @memset(pixels, 0);
    const tw = @min(w, text.measureWidth(s, .manrope_bold, appearance_theme.global.desktop_text_size, 1) catch w);
    const tx = @divTrunc(w - tw, 2);
    if (shadow) {
        for ([_]i32{ -1, 0, 1 }) |dx| for ([_]i32{ 0, 1, 2 }) |dy| {
            text.draw(pixels, pw, ph, .{ .x = @max(0, tx + dx), .y = dy, .w = w - @max(0, tx + dx), .h = h }, s, themeInk(appearance_theme.global.desktop_text_shadow), scale, .manrope_bold, appearance_theme.global.desktop_text_size) catch {};
        };
    }
    text.draw(pixels, pw, ph, .{ .x = tx, .y = 0, .w = w - tx, .h = h }, s, themeInk(appearance_theme.global.desktop_fg), scale, .manrope_bold, appearance_theme.global.desktop_text_size) catch {};
    const surface = c.cairo_image_surface_create_for_data(@ptrCast(pixels.ptr), c.CAIRO_FORMAT_ARGB32, pw, ph, pw * 4) orelse return;
    defer c.cairo_surface_destroy(surface);
    paintRaster(cr, surface, x, y, raster);
}

test "button release does not cancel the launch triggered by its press" {
    var app = App{ .worker = undefined, .launching_until = 30000 };
    app.button(272, false);
    try std.testing.expectEqual(@as(i64, 30000), app.launching_until);
}

test "desktop pointer motion repaints only when visible state changes" {
    var icons = [_]Icon{.{ .item = .{ .path = "", .name = "", .icon = null }, .cell = .{}, .born = 0 }};
    var app = App{ .worker = undefined, .icons = .{ .items = &icons, .capacity = icons.len }, .dirty = false };
    app.motion(200, 200);
    app.motion(300, 250);
    try std.testing.expect(!app.dirty);
    try std.testing.expectEqual(@as(f64, 300), app.x);
    const r = app.geometry.rect(.{});
    app.motion(@floatFromInt(r.x + 20), @floatFromInt(r.y + 20));
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(?usize, 0), app.hover);
    app.dirty = false;
    app.motion(@floatFromInt(r.x + 21), @floatFromInt(r.y + 21));
    try std.testing.expect(!app.dirty);
    app.leave();
    try std.testing.expect(app.dirty);
    app.dirty = false;
    app.leave();
    try std.testing.expect(!app.dirty);
    app.dirty = true; // Motion must retain invalidation from other sources.
    app.motion(300, 250);
    try std.testing.expect(app.dirty);
}

test "desktop motion keeps menu highlights and moving selections live" {
    var app = App{ .worker = undefined, .menu = true, .dirty = false };
    app.menu_layout.layout(100, 100, 3, false);
    app.motion(120, 110);
    try std.testing.expect(!app.dirty);
    app.motion(120, 140);
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(usize, 1), app.menu_selected);
    app.dirty = false;
    app.motion(125, 145);
    try std.testing.expect(!app.dirty);
    app.menu_layout.layout(100, 100, 7, true);
    try std.testing.expectEqual(@as(?usize, null), app.menu_layout.hit(120, 103));
    try std.testing.expectEqual(@as(?usize, null), app.menu_layout.hit(120, 173));
    try std.testing.expectEqual(@as(?usize, 2), app.menu_layout.hit(120, 178));
    try std.testing.expectEqual(@as(f32, context_menu.row_height), app.menu_layout.rows[2].computed_height);
    var builtin_icons = [_]Icon{
        .{ .item = .{ .path = "/home/test", .name = "Home", .icon = null, .builtin = .home }, .cell = .{}, .born = 0 },
        .{ .item = .{ .path = "/home/test/.local/share/Trash/files", .name = "Trash", .icon = null, .builtin = .trash }, .cell = .{ .row = 1 }, .born = 0 },
    };
    app.icons.items = &builtin_icons;
    app.menu_icon = 0;
    try std.testing.expectEqual(@as(usize, 1), app.menuLabels().len);
    try std.testing.expectEqualStrings("Open", app.menuLabels()[0]);
    app.menu_icon = 1;
    try std.testing.expectEqual(@as(usize, 2), app.menuLabels().len);
    try std.testing.expectEqualStrings("Open", app.menuLabels()[0]);
    try std.testing.expectEqualStrings("Empty Trash", app.menuLabels()[1]);
    try std.testing.expectEqual(@import("ui").layout.IconId.trash, app.menuIcon(1));
    try std.testing.expectEqual(@as(?[]const u8, null), app.menuHint(1));
    app.icons.items = &.{};
    app.menu_icon = null;
    app.menu = false;
    app.rubber = true;
    app.motion(200, 200);
    try std.testing.expect(app.dirty);
    app.dirty = false;
    app.motion(200, 200);
    try std.testing.expect(!app.dirty);
    app.rubber = false;
    app.pressed = 0;
    app.down_at = nowMs() - 200;
    app.motion(210, 210);
    try std.testing.expect(app.dragging and app.dirty);
    app.dirty = false;
    app.motion(220, 220);
    try std.testing.expect(app.dirty);
}

test "cached desktop names preserve raw label pixels across text and scale changes" {
    var cache = NameCache{};
    defer cache.deinit();
    for (1..5) |factor| {
        const scale: i32 = @intCast(factor);
        const w = 104 * scale;
        const h = 52 * scale;
        for ([_][]const u8{ "Short", "A long file name that wraps.txt", "日本語.desktop", "" }) |name| {
            const expected = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h).?;
            defer c.cairo_surface_destroy(expected);
            const actual = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h).?;
            defer c.cairo_surface_destroy(actual);
            const raw_cr = c.cairo_create(expected).?;
            defer c.cairo_destroy(raw_cr);
            const cached_cr = c.cairo_create(actual).?;
            defer c.cairo_destroy(cached_cr);
            for ([_]*c.cairo_t{ raw_cr, cached_cr }) |cr| {
                c.cairo_set_source_rgba(cr, 0.07, 0.13, 0.21, 0.7);
                c.cairo_paint(cr);
                c.cairo_scale(cr, @floatFromInt(scale), @floatFromInt(scale));
            }
            drawName(raw_cr, name, 7, 9);
            cache.draw(cached_cr, name, 7, 9);
            c.cairo_surface_flush(expected);
            c.cairo_surface_flush(actual);
            const len: usize = @intCast(w * h * 4);
            try std.testing.expectEqualSlices(u8, c.cairo_image_surface_get_data(expected)[0..len], c.cairo_image_surface_get_data(actual)[0..len]);
            const saved = cache.surface;
            cache.draw(cached_cr, name, 3, 5);
            try std.testing.expectEqual(saved, cache.surface);
        }
    }
}

test "rubberband damage coalesces motion before presentation" {
    var app = App{ .worker = undefined, .rubber = true, .down_x = 100, .down_y = 100, .x = 200, .y = 200 };
    app.presented();
    for (0..1000) |i| app.motion(@floatFromInt(200 + i), @floatFromInt(200 + i));
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(usize, 0), app.damage.len);
    app.prepareDamage();
    try std.testing.expect(!app.damage.full);
    // Up to four edge strips per band, plus both bands' rounded corners.
    try std.testing.expect(app.damage.len <= 16);
    try std.testing.expect(!app.damage.intersects(.{ .x = 130, .y = 130, .w = 20, .h = 20 }));
    app.presented();
    app.rubber = false;
    app.prepareDamage();
    try std.testing.expect(app.damage.intersects(.{ .x = 130, .y = 130, .w = 20, .h = 20 }));
}

test "icon group cache matches fresh pixels after visual and content changes" {
    var icons = [_]Icon{.{ .item = try copyItem(.{ .path = "", .name = "Alpha icon", .icon = null }), .cell = .{}, .born = 0 }};
    defer {
        freeItem(icons[0].item);
        icons[0].name_cache.deinit();
        icons[0].raster.deinit();
    }
    var app = App{ .worker = undefined, .geometry = .{ .w = 200, .h = 240 }, .icons = .{ .items = &icons, .capacity = icons.len } };
    defer app.edit_text.deinit(a);
    defer app.rename_editor.deinit();
    const ic = &icons[0];
    // Populate the cache through a small clip first, then reuse it on another
    // target's full clip. Damage must not affect the cached icon's raster bounds.
    const small = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 200, 240).?;
    defer c.cairo_surface_destroy(small);
    const small_cr = c.cairo_create(small).?;
    defer c.cairo_destroy(small_cr);
    var part = Damage{};
    part.clear();
    part.add(.{ .x = 150, .y = 30, .w = 20, .h = 60 });
    app.paintAt(small_cr, &part, 1000, true);
    const initial = ic.raster.pattern;
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1000);
    try std.testing.expectEqual(initial, ic.raster.pattern);

    for ([_][2]f64{ .{ 0.3, 0 }, .{ 1, 0 }, .{ 1, 0.4 }, .{ 0, 1 }, .{ 0, 0.2 }, .{ 0, 0 } }) |amount| {
        ic.hover_amount = amount[0];
        ic.selection_amount = amount[1];
        try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1000);
    }
    ic.selected = true;
    app.edit = .rename;
    try app.rename_editor.begin("Alpha icon", false);
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1000);
    app.rename_editor.key(c.XKB_KEY_End, "", false, false);
    app.rename_editor.key(0, " renamed", false, false);
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1000);
    ic.replaceItem(try copyItem(.{ .path = "", .name = "Beta icon", .icon = null }));
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1000);
    const blue = [_]u32{0xff2040e0} ** 4;
    const red = [_]u32{0xffe04020} ** 4;
    for ([_]?@import("../icon_cache.zig").Entry{ .{ .pixels = &blue, .size = 2 }, .{ .pixels = &red, .size = 2 }, null }) |icon| {
        ic.replaceItem(try copyItem(.{ .path = "", .name = "Beta icon", .icon = icon }));
        try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1000);
    }
    app.edit = .none;
    app.launching_until = 2000;
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1000);
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1200);
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1250);
    app.launching_until = 0;
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1200);
    const opaque_pattern = ic.raster.pattern;
    ic.born = 1150;
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1200);
    try std.testing.expectEqual(opaque_pattern, ic.raster.pattern);
    ic.born = 0;
    ic.removed = 1150;
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1200);
    try std.testing.expectEqual(opaque_pattern, ic.raster.pattern);
    ic.removed = null;
    app.dragging = true;
    app.pressed = 0;
    app.x = 128;
    app.y = 64;
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1200);
    try std.testing.expectEqual(opaque_pattern, ic.raster.pattern);
    app.dragging = false;
    app.pressed = null;
    for ([_]i32{ 2, 3, 1 }) |scale| try expectFreshIconPixels(&app, 200 * scale, 240 * scale, @floatFromInt(scale), 0, 1, 0, 1200);
    // Actual target dimensions can clip a group even with unchanged app geometry.
    try expectFreshIconPixels(&app, 110, 90, 1, 0, 1, 0, 1200);
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1200);
    try expectFreshIconPixels(&app, 200, 240, 1, -37, 1, 0, 1200);
    try expectFreshIconPixels(&app, 400, 480, 1, 0, 2, 0, 1200);
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, -19, 1200);
    ic.cell.row = 1;
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1200);
}

fn expectFreshIconPixels(app: *App, w: i32, h: i32, scale: f64, translate: f64, device_scale: f64, device_offset: f64, now: i64) !void {
    const actual = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h).?;
    defer c.cairo_surface_destroy(actual);
    const expected = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h).?;
    defer c.cairo_surface_destroy(expected);
    for ([_]*c.cairo_surface_t{ actual, expected }) |surface| {
        c.cairo_surface_set_device_scale(surface, device_scale, device_scale);
        c.cairo_surface_set_device_offset(surface, device_offset, device_offset);
    }
    const actual_cr = c.cairo_create(actual).?;
    defer c.cairo_destroy(actual_cr);
    const expected_cr = c.cairo_create(expected).?;
    defer c.cairo_destroy(expected_cr);
    for ([_]*c.cairo_t{ actual_cr, expected_cr }) |cr| {
        c.cairo_scale(cr, scale, scale);
        c.cairo_translate(cr, translate, translate);
    }
    const full = Damage{};
    app.paintAt(actual_cr, &full, now, true);
    // Always rebuild the reference group, even if the same App has a cache.
    app.paintAt(expected_cr, &full, now, false);
    c.cairo_surface_flush(actual);
    c.cairo_surface_flush(expected);
    const len: usize = @intCast(w * h * 4);
    try std.testing.expectEqualSlices(u8, c.cairo_image_surface_get_data(expected)[0..len], c.cairo_image_surface_get_data(actual)[0..len]);
}
