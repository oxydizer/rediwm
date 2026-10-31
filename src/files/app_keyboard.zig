//! Files keyboard input: file view, location bar and text editing keys.

const std = @import("std");
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const recent = @import("recent.zig");
const shell_key_repeat = @import("ui").key_repeat;
const fold = @import("ui").fold;
const nowMs = @import("app_draw.zig").nowMs;
const open_with = @import("open_with.zig");
const properties = @import("properties.zig");
const Editor = @import("editor.zig").Editor;

/// Which held keys the client repeats: typing and caret keys in the
/// search box, the location bar and dialog fields; moving through menus
/// and the file list. Delete, Return, Space and every shortcut fire once:
/// a held Delete must not trash file after file.
pub fn keyRepeats(self: *const App, sym: u32, utf8: []const u8) bool {
    if (sym == c.XKB_KEY_F4 and !self.ctrl and !self.alt and !self.shift) return false;
    if (self.dialog == null and self.menu == null and self.focus == .terminal) return !(self.ctrl and self.shift and (sym == c.XKB_KEY_c or sym == c.XKB_KEY_C or sym == c.XKB_KEY_v or sym == c.XKB_KEY_V));
    if (self.ctrl or self.alt) return false;
    const vertical = sym == c.XKB_KEY_Up or sym == c.XKB_KEY_Down;
    const typing = shell_key_repeat.editingKey(switch (sym) {
        c.XKB_KEY_BackSpace, c.XKB_KEY_Delete, c.XKB_KEY_Left, c.XKB_KEY_Right => true,
        else => false,
    }, utf8);
    if (self.dialog) |dlg| return if (dlg.kind == .open_with) vertical else dlg.kind != .properties and dlg.kind != .trash_confirm and dlg.kind != .conflict and dlg.kind != .terminal_close and typing;
    if (self.menu != null) return vertical;
    if (self.focus == .search or self.focus == .location_bar or self.focus == .filename) return typing;
    return vertical or sym == c.XKB_KEY_Left or sym == c.XKB_KEY_Right or
        sym == c.XKB_KEY_Page_Up or sym == c.XKB_KEY_Page_Down;
}

const type_select_timeout_ms: i64 = 1000;

fn sameFoldedText(a: []const u8, b: []const u8) bool {
    const options: fold.Options = .{ .turkish = @import("i18n").isTurkish() };
    return fold.startsWith(a, b, options) and fold.startsWith(b, a, options);
}

/// Select a matching visible name without opening it. The timestamp parameter
/// keeps timeout and cycling behavior deterministic in tests.
pub fn typeSelectAt(self: *App, utf8: []const u8, now_ms: i64) bool {
    if (utf8.len == 0 or self.focus != .file_view or self.ctrl or self.alt or
        self.chooser != null or self.transfer_view.active or self.items.items.len == 0)
    {
        return false;
    }

    const expired = self.type_select_len == 0 or
        now_ms - self.type_select_last_ms > type_select_timeout_ms;

    // Repeating the current single-character prefix cycles through matches.
    if (!expired and self.type_select_len == utf8.len and
        sameFoldedText(self.type_select_buffer[0..self.type_select_len], utf8))
    {
        self.type_select_last_ms = now_ms;
        const start = if (self.focused_index) |index|
            (index + 1) % self.items.items.len
        else
            0;
        const options: fold.Options = .{ .turkish = @import("i18n").isTurkish() };
        for (0..self.items.items.len) |offset| {
            const index = (start + offset) % self.items.items.len;
            if (fold.startsWith(self.items.items[index].text(), utf8, options)) {
                self.selectIndex(index);
                return true;
            }
        }
        return true;
    }

    if (expired or utf8.len > self.type_select_buffer.len - self.type_select_len) {
        self.type_select_len = 0;
    }
    if (utf8.len > self.type_select_buffer.len) return true;

    @memcpy(
        self.type_select_buffer[self.type_select_len..][0..utf8.len],
        utf8,
    );
    self.type_select_len += utf8.len;
    self.type_select_last_ms = now_ms;

    const prefix = self.type_select_buffer[0..self.type_select_len];
    const options: fold.Options = .{ .turkish = @import("i18n").isTurkish() };
    for (self.items.items, 0..) |item, index| {
        if (fold.startsWith(item.text(), prefix, options)) {
            self.selectIndex(index);
            break;
        }
    }
    return true;
}

pub fn handleKey(self: *App, sym: u32, utf8: []const u8) void {
    self.cancelWheel();
    if (sym == c.XKB_KEY_Escape and self.selection_band != null) {
        for (self.items.items) |*it| it.selected = it.selected_before_band;
        self.cancelDrag();
        return;
    }
    self.cancelDrag();
    self.edit_revision += 1;
    if (self.dialog != null) {
        self.handleDialogKey(sym, utf8);
        return;
    }
    if (sym == c.XKB_KEY_F4 and !self.ctrl and !self.alt and !self.shift and self.chooser == null) {
        self.terminalToggle();
        return;
    }

    if (self.menu != null) {
        const count = self.menuLabels().len;
        if (sym == c.XKB_KEY_Escape) self.menu = null else if (sym == c.XKB_KEY_Down) self.menu_selected = (self.menu_selected + 1) % count else if (sym == c.XKB_KEY_Up) self.menu_selected = (self.menu_selected + count - 1) % count else if (sym == c.XKB_KEY_Return) self.runMenu(self.menu_selected);
        self.invalidate();
        return;
    }
    if (self.chooser != null and self.chooserKey(sym, utf8)) return;
    if (self.focus == .terminal) {
        self.terminalKey(sym, utf8);
        return;
    }
    if (self.transfer_view.active) {
        if (self.ctrl and (sym == c.XKB_KEY_l or sym == c.XKB_KEY_L)) self.leaveTransfers() else {
            self.transferPaneKey(sym);
            return;
        }
    }
    if (self.ctrl and (sym == c.XKB_KEY_f or sym == c.XKB_KEY_F)) {
        self.search_visible = true;
        self.focus = .search;
        self.search.select_all = true;
        self.invalidate();
        return;
    }
    if (self.ctrl and (sym == c.XKB_KEY_l or sym == c.XKB_KEY_L)) {
        self.search_visible = false;
        self.search.text.clearRetainingCapacity();
        self.search.cursor = 0;
        self.rebuildView();
        self.focus = .location_bar;
        self.location.select_all = true;
        self.invalidate();
        return;
    }
    if (self.focus == .search) {
        self.handleSearchKey(sym, utf8);
        return;
    }
    if (sym == c.XKB_KEY_Menu or (self.shift and sym == c.XKB_KEY_F10)) {
        self.openMenu(if (self.hasSelection()) .file else .background, @floatFromInt(self.sidebarWidth() + 24), @floatFromInt(self.contentTop() + 24));
        return;
    }
    if (self.focus == .location_bar) {
        self.handleLocationKey(sym, utf8);
        return;
    }

    if (!self.ctrl and !self.alt and sym == c.XKB_KEY_space) {
        if (self.focused_index) |index| if (self.torrentForItem(index)) |t| {
            self.toggleTorrent(t);
            return;
        };
    }

    // Navigation shortcuts with Alt
    if (self.alt) {
        if (sym == c.XKB_KEY_Return) {
            self.openSelectedProperties();
            return;
        }
        if (sym == c.XKB_KEY_Left) {
            self.back();
            return;
        } else if (sym == c.XKB_KEY_Right) {
            self.forward();
            return;
        } else if (sym == c.XKB_KEY_Up) {
            self.up();
            return;
        }
    }

    // Ctrl shortcuts
    if (self.ctrl) {
        if (self.shift and (sym == c.XKB_KEY_n or sym == c.XKB_KEY_N)) {
            self.openNewFolderDialog();
            return;
        } else if (sym == c.XKB_KEY_n or sym == c.XKB_KEY_N) {
            self.openNewFileDialog();
            return;
        } else if (sym == c.XKB_KEY_o or sym == c.XKB_KEY_O) {
            self.activateSelected();
            return;
        } else if (sym == c.XKB_KEY_c or sym == c.XKB_KEY_C) {
            self.copySelected();
            return;
        } else if (sym == c.XKB_KEY_x or sym == c.XKB_KEY_X) {
            self.cutSelected();
            return;
        } else if (sym == c.XKB_KEY_v or sym == c.XKB_KEY_V) {
            if (!self.isRecent()) self.paste_requested = true;
            return;
        } else if (sym == c.XKB_KEY_l or sym == c.XKB_KEY_L) {
            self.focus = .location_bar;
            self.location.select_all = true;
            self.invalidate();
            return;
        } else if (sym == c.XKB_KEY_h or sym == c.XKB_KEY_H) {
            self.toggleHidden();
            return;
        } else if (sym == c.XKB_KEY_a or sym == c.XKB_KEY_A) {
            for (self.items.items) |*it| it.selected = true;
            self.invalidate();
            return;
        }
    }

    if (sym == c.XKB_KEY_space and !self.ctrl and !self.alt and !self.shift) {
        self.previewSelected();
        return;
    }

    // General shortcuts
    if (sym == c.XKB_KEY_F5) {
        self.refresh();
        return;
    } else if (sym == c.XKB_KEY_F2) {
        self.openRenameDialog();
        return;
    } else if (sym == c.XKB_KEY_Delete) {
        self.openTrashConfirmDialogWithMode(self.shift);
        return;
    } else if (sym == c.XKB_KEY_Return) {
        self.activateSelected();
        return;
    } else if (sym == c.XKB_KEY_Escape) {
        if (self.search_visible) {
            self.runHeader(.search);
            return;
        }
        if (self.job_runner) |runner| {
            const prog = runner.pollProgress();
            if (prog.state == .running or prog.state == .waiting_conflict) {
                runner.cancel();
                self.setStatusNotice(@import("i18n").tr("Cancelling operation..."), false);
                self.invalidate();
                return;
            }
        }
        for (self.items.items) |*it| it.selected = false;
        self.selection_anchor = null;
        self.focused_index = null;
        self.invalidate();
        return;
    } else if (sym == c.XKB_KEY_Tab) {
        self.focus = if (self.search_visible) .search else .location_bar;
        self.location.select_all = true;
        self.invalidate();
        return;
    }

    // Arrow keys and scrolling in file view
    if (self.items.items.len == 0) return;
    if (typeSelectAt(self, utf8, nowMs())) return;

    if (sym == c.XKB_KEY_Down or sym == c.XKB_KEY_Right) {
        const step: usize = if (sym == c.XKB_KEY_Down) @intCast(self.columns()) else 1;
        const next_idx = if (self.focused_index) |idx| @min(self.items.items.len - 1, idx + step) else 0;
        self.selectIndex(next_idx);
    } else if (sym == c.XKB_KEY_Up or sym == c.XKB_KEY_Left) {
        const step: usize = if (sym == c.XKB_KEY_Up) @intCast(self.columns()) else 1;
        const prev_idx = if (self.focused_index) |idx| (if (idx > step) idx - step else 0) else 0;
        self.selectIndex(prev_idx);
    } else if (sym == c.XKB_KEY_Home) {
        self.selectIndex(0);
    } else if (sym == c.XKB_KEY_End) {
        const last_idx = self.items.items.len - 1;
        self.selectIndex(last_idx);
    } else if (sym == c.XKB_KEY_Page_Down) {
        const page_rows = @max(1, @divTrunc(self.contentBottom() - self.viewTop(), self.rowHeight())) * self.columns();
        const cur = self.focused_index orelse 0;
        const new_idx = @min(self.items.items.len - 1, cur + @as(usize, @intCast(@max(1, page_rows))));
        self.selectIndex(new_idx);
    } else if (sym == c.XKB_KEY_Page_Up) {
        const page_rows = @max(1, @divTrunc(self.contentBottom() - self.viewTop(), self.rowHeight())) * self.columns();
        const cur = self.focused_index orelse 0;
        const page_u = @as(usize, @intCast(@max(1, page_rows)));
        const new_idx = if (cur > page_u) cur - page_u else 0;
        self.selectIndex(new_idx);
    }
}

pub fn selectIndex(self: *App, index: usize) void {
    if (self.shift and (self.chooser == null or self.chooser.?.multiple)) {
        const anchor = self.selection_anchor orelse self.focused_index orelse index;
        self.selection_anchor = anchor;
        for (self.items.items, 0..) |*it, i| {
            const in_range = i >= @min(anchor, index) and i <= @max(anchor, index);
            it.selected = in_range or (self.ctrl and it.selected);
        }
    } else if (!self.ctrl or (self.chooser != null and !self.chooser.?.multiple)) {
        for (self.items.items, 0..) |*it, i| it.selected = i == index;
        self.selection_anchor = index;
    }
    self.focused_index = index;
    if (self.chooser != null and !self.items.items[index].is_dir) self.setChooserName(self.items.items[index].name);
    self.revealIndex(index);
}

pub fn handleLocationKey(self: *App, sym: u32, utf8: []const u8) void {
    if (sym == c.XKB_KEY_Escape) {
        self.location.text.clearRetainingCapacity();
        self.location.text.appendSlice(self.allocator, self.history.current) catch {};
        self.location.cursor = self.location.text.items.len;
        self.location.select_all = false;
        self.focus = .file_view;
        self.invalidate();
        return;
    } else if (sym == c.XKB_KEY_Return) {
        var raw = std.mem.trim(u8, self.location.text.items, " \t\r\n");
        if (raw.len == 0) raw = "/";

        // Expand ~ to home_dir
        var target_buf: [4096]u8 = undefined;
        var target: []const u8 = raw;
        if (std.mem.startsWith(u8, raw, "~")) {
            target = std.fmt.bufPrint(&target_buf, "{s}{s}", .{ self.home_dir, raw[1..] }) catch raw;
        }

        // Clean path
        const resolved = if (recent.isLocation(target)) target else std.fs.path.resolve(self.allocator, &.{target}) catch target;
        defer if (resolved.ptr != target.ptr) self.allocator.free(resolved);

        self.navigate(resolved);
        self.focus = .file_view;
        self.invalidate();
        return;
    } else if (sym == c.XKB_KEY_Tab) {
        self.focus = .file_view;
        self.invalidate();
        return;
    }
    self.editKey(&self.location, sym, utf8);
}

pub fn activeEditor(self: *App) ?*Editor {
    if (self.dialog) |*dlg| return switch (dlg.kind) {
        .new_folder, .new_file, .new_branch, .rename, .torrent_source, .torrent_destination => &dlg.edit,
        else => null,
    };
    return switch (self.focus) {
        .location_bar => &self.location,
        .search => &self.search,
        .filename => &self.filename,
        else => null,
    };
}

pub fn editKey(self: *App, edit: *Editor, sym: u32, utf8: []const u8) void {
    if (self.ctrl and (sym == c.XKB_KEY_c or sym == c.XKB_KEY_C or sym == c.XKB_KEY_x or sym == c.XKB_KEY_X)) {
        const sel = edit.selection();
        if (sel[0] != sel[1]) {
            self.clipboard_text.clearRetainingCapacity();
            self.clipboard_text.appendSlice(self.allocator, edit.text.items[sel[0]..sel[1]]) catch return;
            self.clearClipboard();
            self.clipboard_cut = false;
            self.clipboard_is_text = true;
            self.clipboard_revision += 1;
            if (sym == c.XKB_KEY_x or sym == c.XKB_KEY_X) edit.insert(self.allocator, "") catch {};
        }
    } else if (self.ctrl and (sym == c.XKB_KEY_v or sym == c.XKB_KEY_V)) {
        self.text_paste_requested = true;
    } else edit.key(self.allocator, sym, utf8, self.ctrl, self.shift, self.alt);
    self.invalidate();
}

pub fn pasteText(self: *App, bytes: []const u8) void {
    if (self.dialog == null and self.focus == .terminal and self.terminal.visible) {
        if (self.terminal.session) |session| {
            if (!@import("terminal/model.zig").c.ft_paste(session, bytes.ptr, bytes.len)) self.setStatusNotice("Terminal paste exceeds the available input queue", true);
            self.terminal.selection = null;
            self.terminalDamage();
        }
        return;
    }
    const edit = self.activeEditor() orelse return;
    if (self.focus == .filename) self.overwrite_pending = false;
    edit.insert(self.allocator, bytes) catch {
        self.setStatusNotice(@import("i18n").tr("Clipboard text is invalid or too long"), true);
        return;
    };
    self.edit_revision += 1;
    if (self.focus == .search and self.dialog == null) self.rebuildView();
    self.invalidate();
}

pub fn hasSelection(self: *App) bool {
    for (self.items.items) |item| {
        if (item.selected) return true;
    }
    return false;
}

pub fn handleSearchKey(self: *App, sym: u32, utf8: []const u8) void {
    if (sym == c.XKB_KEY_Escape) {
        self.search.text.clearRetainingCapacity();
        self.search.cursor = 0;
        self.search_visible = false;
        self.focus = .file_view;
    } else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_Down) {
        self.focus = .file_view;
        if (self.items.items.len > 0) {
            self.focused_index = 0;
            self.selection_anchor = 0;
            for (self.items.items, 0..) |*item, i| item.selected = i == 0;
            self.revealIndex(0);
        }
        self.invalidate();
        return;
    } else {
        self.editKey(&self.search, sym, utf8);
        self.scroll_y = 0;
    }
    self.rebuildView();
    self.invalidate();
}
