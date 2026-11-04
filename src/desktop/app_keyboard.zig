//! Desktop keyboard input.

const std = @import("std");
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const rename = @import("rename.zig");
const deletion = @import("../delete_dialog.zig");
const a = std.heap.c_allocator;

/// Keyboard focus moved elsewhere. `refocusing` means a click already
/// asked for it back, so open menus and edits survive the late leave.
pub fn keyboardLeft(self: *App, refocusing: bool) void {
    self.ctrl = false;
    self.shift = false;
    if (!refocusing) {
        self.menu = false;
        self.deletion.deinit();
        self.closeTrashCard();
        self.closePicker();
        self.edit = .none;
    }
    self.invalidate();
}

/// Which held keys the host repeats: text and caret keys while editing,
/// menu, list and icon navigation otherwise. The delete dialog, Return,
/// Escape and Ctrl shortcuts fire once.
pub fn keyRepeats(self: *const App, sym: u32, utf8: []const u8) bool {
    if (self.edit == .trash or self.edit == .trash_properties or self.edit == .folder or self.ctrl) return false;
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
    if (self.edit == .trash_properties) {
        if (self.trash_card) |*card| self.trashPropertiesAction(card.key(sym));
        return;
    }
    if (self.edit == .add_app) {
        if (self.applications) |*picker| {
            // Preserve application search from the desktop's original chooser.
            if (self.ctrl and (sym == c.XKB_KEY_a or sym == c.XKB_KEY_A)) {
                self.edit_text.clearRetainingCapacity();
                picker.search("");
            } else if (sym == c.XKB_KEY_BackSpace) {
                if (self.edit_text.items.len > 0) {
                    var n = self.edit_text.items.len - 1;
                    while (n > 0 and self.edit_text.items[n] & 0xc0 == 0x80) n -= 1;
                    self.edit_text.shrinkRetainingCapacity(n);
                }
                picker.search(self.edit_text.items);
            } else if (!self.ctrl and utf8.len > 0 and utf8[0] >= 32 and (sym != c.XKB_KEY_space or self.edit_text.items.len > 0) and self.edit_text.items.len + utf8.len < 255) {
                self.edit_text.appendSlice(a, utf8) catch {};
                picker.search(self.edit_text.items);
            } else {
                const action = picker.key(sym, self.shift, self.geometry.w, self.geometry.h - self.geometry.bottom);
                self.pickerAction(action);
            }
        }
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
    if (self.edit == .folder) return;
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
        if (self.edit == .open_with) {
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
