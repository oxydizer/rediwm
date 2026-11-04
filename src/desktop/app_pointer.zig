//! Desktop pointer input: motion, selection, clicks, launch feedback and cursor.

const std = @import("std");
const App = @import("app.zig").App;
const grid = @import("grid.zig");
const text = @import("ui").text;
const damage_mod = @import("damage.zig");
const rename = @import("rename.zig");
const deletion = @import("../delete_dialog.zig");
const host_mod = @import("host.zig");
const context_menu = @import("ui").context_menu;
const Menu = @import("menu.zig").Menu;
const nowMs = @import("app_draw.zig").nowMs;
const ui_theme = @import("ui").theme;
const widget_button = @import("ui").widgets.button;

fn proximityDistance(self: *App, index: usize, x: f64, y: f64) f32 {
    const r = self.iconRect(index);
    const sample = widget_button.sampleProximity(
        .{
            .x = @floatFromInt(r.x),
            .y = @floatFromInt(r.y),
            .w = @floatFromInt(r.w),
            .h = @floatFromInt(r.h),
        },
        @floatCast(x),
        @floatCast(y),
        .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(self.geometry.w),
            .h = @floatFromInt(self.geometry.h),
        },
    );
    return sample.distance;
}

fn damageProximityAt(self: *App, x: f64, y: f64) void {
    const t = ui_theme.global;
    if (!widget_button.proximityGlowVisible(t)) return;

    for (self.icons.items, 0..) |_, i| {
        if (self.iconRect(i).contains(x, y)) continue;
        if (proximityDistance(self, i, x, y) < t.border_glow_reach) {
            self.damageIcon(i);
        }
    }
}

pub fn motion(self: *App, x: f64, y: f64) void {
    self.pointerMotion(x, y);
    self.syncCursor();
}

pub fn pointerMotion(self: *App, x: f64, y: f64) void {
    if (self.edit == .add_app) {
        if (self.applications) |*picker| {
            const w = self.geometry.w;
            const h = self.geometry.h - self.geometry.bottom;
            const old_hit = picker.hit(w, h, self.x, self.y);
            if (picker.motion(w, h, x, y) or old_hit != picker.hit(w, h, x, y)) self.invalidate();
        }
        self.x = x;
        self.y = y;
        return;
    }
    if (self.edit == .trash_properties) {
        if (self.trash_card) |*card| {
            const w = self.geometry.w;
            const h = self.geometry.h - self.geometry.bottom;
            const old_hit = card.hit(w, h, self.x, self.y);
            if (card.motion(w, h, x, y) or old_hit != card.hit(w, h, x, y)) self.invalidate();
        }
        self.x = x;
        self.y = y;
        return;
    }
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
    const newly_present = !self.pointer_present;
    if (moved) {
        self.damageDrag();
        if (self.pointer_present) damageProximityAt(self, self.x, self.y);
    }
    self.x = x;
    self.y = y;
    self.pointer_present = true;
    if (moved or newly_present) damageProximityAt(self, x, y);
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
    if (self.pointer_present) damageProximityAt(self, self.x, self.y);
    self.pointer_present = false;
    self.deletion.placement.grab = null;
    if (self.trash_card) |*card| card.placement.grab = null;
    if (self.applications) |*picker| picker.placement.grab = null;
    if (self.hover != null) {
        self.damageIcon(self.hover.?);
        self.hover = null;
    }
}

pub fn selectionRect(self: *App) grid.Rect {
    return .{ .x = @intFromFloat(@min(self.x, self.down_x)), .y = @intFromFloat(@min(self.y, self.down_y)), .w = @intFromFloat(@abs(self.x - self.down_x)), .h = @intFromFloat(@abs(self.y - self.down_y)) };
}

pub fn deselect(self: *App) void {
    for (self.icons.items) |*ic| ic.selected = false;
    self.invalidate();
}

pub fn button(self: *App, button_code: u32, pressed: bool) void {
    const was_menu = self.menu;
    const was_delete_dialog = self.edit == .trash or self.edit == .trash_properties;
    const was_renaming = self.edit == .rename;
    const menu_hit = was_menu and self.menu_layout.hit(self.x, self.y) != null;
    if (pressed) self.endLaunch();
    self.pointerButton(button_code, pressed);
    self.syncCursor();
    if (pressed) {
        self.host.keyboard(self.hit(self.x, self.y) != null or self.menu or self.edit != .none or menu_hit or was_delete_dialog or was_renaming);
    }
}

pub fn pointerButton(self: *App, button_code: u32, pressed: bool) void {
    self.invalidate();
    if (self.edit == .add_app) {
        if (button_code == 272) {
            if (self.applications) |*picker| {
                const w = self.geometry.w;
                const h = self.geometry.h - self.geometry.bottom;
                if (picker.pointerButton(w, h, self.x, self.y, pressed)) return;
                if (pressed) {
                    const action = picker.click(w, h, self.x, self.y);
                    self.pickerAction(action);
                }
            }
        }
        return;
    }
    if (self.edit == .trash_properties) {
        if (button_code == 272) if (self.trash_card) |*card| {
            const w = self.geometry.w;
            const h = self.geometry.h - self.geometry.bottom;
            if (card.pointerButton(w, h, self.x, self.y, pressed)) return;
            if (pressed) self.trashPropertiesAction(card.click(w, h, self.x, self.y));
        };
        return;
    }
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
        if (button_code == 272 and self.edit == .open_with) {
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
pub fn endLaunch(self: *App) void {
    if (self.launching_until != 0) self.invalidate();
    self.launching_until = 0;
    self.launched = null;
    self.syncCursor();
}

pub fn wantedCursor(self: *App) host_mod.Cursor {
    if (self.dragging) return .grabbing;
    if (self.renameGeometry()) |g| {
        if (self.rename_editor.selecting or g.field.contains(self.x, self.y)) return .text;
    }
    return if (self.launching_until != 0) .busy else .normal;
}

pub fn syncCursor(self: *App) void {
    const wanted = self.wantedCursor();
    if (wanted == self.cursor) return;
    self.cursor = wanted;
    self.host.cursor(wanted);
}

pub fn updateLaunch(self: *App, now: i64) void {
    if (self.worker.takeLaunched()) |launched| {
        if (launched.token == self.launch_token) self.launched = launched;
    }
    if (self.launching_until == 0) return;
    if (now >= self.launching_until) return self.endLaunch();
    const launched = &(self.launched orelse return);
    if (self.host.windowAppeared(launched.pid, launched.app(), self.launch_after_id)) self.endLaunch();
}
