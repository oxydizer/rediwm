//! Files in chooser mode: the portal file dialog's footer, filters and results.

const std = @import("std");
const io_thread_guard = @import("io_thread_guard.zig");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const header = @import("header.zig");
const shell_ui = @import("ui").cairo;
const ui_button = @import("ui").widgets.button;
const ui_theme = @import("ui").theme;
const app_requests = @import("app_requests.zig");
const io_requests = @import("io_requests.zig");
const chooser_mod = @import("chooser.zig");
const Focus = @import("app_model.zig").Focus;
const setSource = @import("app_draw.zig").setSource;
const drawEllipsis = @import("app_draw.zig").drawEllipsis;
const drawText = @import("app_draw.zig").drawText;

pub fn configureChooser(self: *App, options: chooser_mod.Options) !void {
    self.chooser = options;
    if (options.filters.len > 0) self.chooser.?.filter_index = @min(options.filter_index, options.filters.len - 1);
    for (options.filters) |filter| try self.chooser_filter_labels.append(self.allocator, filter.name);
    self.list_view = true;
    if (self.preferences_path) |path| self.allocator.free(path);
    self.preferences_path = null;
    self.setChooserName(options.current_name);
    for (options.choices) |choice| {
        var selected: []const u8 = if (choice.values.len == 0) "false" else choice.values[0].id;
        if (choice.values.len == 0 and std.mem.eql(u8, choice.selected, "true")) selected = "true";
        for (choice.values) |value| if (std.mem.eql(u8, choice.selected, value.id)) {
            selected = value.id;
        };
        try self.chooser_choices.append(self.allocator, selected);
    }
    self.h = @max(self.h, self.footerHeight() + 300);
    self.focus = if (options.mode == .save) .filename else .file_view;
    self.filename.selectStem();
    self.updateTitle();
}

pub fn setChooserName(self: *App, name: []const u8) void {
    self.filename.text.clearRetainingCapacity();
    self.filename.text.appendSlice(self.allocator, name) catch {};
    self.filename.cursor = self.filename.text.items.len;
    self.filename.anchor = self.filename.cursor;
    self.filename.select_all = false;
    self.filename.scroll = 0;
    self.overwrite_pending = false;
}

pub fn chooserRect(self: *App, index: usize) header.Rect {
    const width: f64 = @floatFromInt(self.w);
    const top: f64 = @floatFromInt(self.h - self.footerHeight());
    if (self.w >= 800) return switch (index) {
        0 => .{ .x = 96, .y = top + 24, .w = width - 508, .h = 36 },
        1 => .{ .x = width - 108, .y = top + 24, .w = 92, .h = 36 },
        2 => .{ .x = width - 210, .y = top + 24, .w = 92, .h = 36 },
        3 => .{ .x = width - 400, .y = top + 24, .w = 178, .h = 36 },
        else => .{ .x = 16, .y = top + 82 + @as(f64, @floatFromInt(index - 4)) * 36, .w = width - 32, .h = 32 },
    };
    return switch (index) {
        0 => .{ .x = 96, .y = top + 12, .w = width - 112, .h = 34 },
        1 => .{ .x = width - 108, .y = top + 60, .w = 92, .h = 36 },
        2 => .{ .x = width - 210, .y = top + 60, .w = 92, .h = 36 },
        3 => .{ .x = 16, .y = top + 60, .w = width - 242, .h = 36 },
        else => .{ .x = 16, .y = top + 108 + @as(f64, @floatFromInt(index - 4)) * 36, .w = width - 32, .h = 32 },
    };
}

pub fn cycleChooserFilter(self: *App, reverse: bool) void {
    const opts = &self.chooser.?;
    if (opts.filters.len == 0) return;
    opts.filter_index = (opts.filter_index + opts.filters.len + (if (reverse) @as(usize, 0) else 2) - 1) % opts.filters.len;
    self.rebuildView();
    self.invalidate();
}

pub fn chooserClick(self: *App, x: f64, y: f64, button: u32) bool {
    if (y < @as(f64, @floatFromInt(self.h - self.footerHeight()))) {
        self.overwrite_pending = false;
        return false;
    }
    if (button != 0x110) return true;
    if (self.chooserRect(1).contains(x, y)) self.acceptChooser() else if (self.chooserRect(2).contains(x, y)) {
        if (self.overwrite_pending) self.overwrite_pending = false else self.chooser_done = true;
    } else if (self.chooserRect(0).contains(x, y) and self.chooser.?.mode != .folder) {
        self.overwrite_pending = false;
        self.focus = .filename;
        self.placeCaret(x, self.shift);
        self.text_dragging = true;
    } else if (self.chooserRect(3).contains(x, y)) {
        self.focus = .chooser_filter;
        if (self.chooser.?.filters.len > 0) {
            const r = self.chooserRect(3);
            self.openMenu(.chooser_filter, r.x, r.y - @as(f64, @floatFromInt(self.chooser.?.filters.len * 30 + 12)));
        }
    } else for (self.chooser.?.choices, 0..) |choice, i| {
        if (!self.chooserRect(i + 4).contains(x, y)) continue;
        if (choice.values.len == 0) {
            self.chooser_choices.items[i] = if (std.mem.eql(u8, self.chooser_choices.items[i], "true")) "false" else "true";
        } else {
            var next: usize = 0;
            for (choice.values, 0..) |value, j| if (std.mem.eql(u8, value.id, self.chooser_choices.items[i])) {
                next = (j + 1) % choice.values.len;
            };
            self.chooser_choices.items[i] = choice.values[next].id;
        }
        break;
    }
    self.invalidate();
    return true;
}

pub fn chooserKey(self: *App, sym: u32, utf8: []const u8) bool {
    if (sym == c.XKB_KEY_Escape and self.focus != .location_bar and self.focus != .search) {
        if (self.overwrite_pending) self.overwrite_pending = false else self.chooser_done = true;
        self.invalidate();
        return true;
    }
    if (sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab) {
        var order_buf: [14]Focus = undefined;
        const base = [_]Focus{ .location_bar, .file_view, .filename, .chooser_filter };
        @memcpy(order_buf[0..base.len], &base);
        const choices = self.chooser.?.choices.len;
        @memset(order_buf[4 .. 4 + choices], .chooser_choice);
        order_buf[4 + choices] = .chooser_cancel;
        order_buf[5 + choices] = .chooser_accept;
        const order = order_buf[0 .. 6 + choices];
        var index: usize = 0;
        for (order, 0..) |focus, i| if (focus == self.focus) {
            index = i;
        };
        if (self.focus == .chooser_choice) index = 4 + self.chooser_choice_index;
        index = (index + (if (self.shift) order.len - 1 else 1)) % order.len;
        self.focus = order[index];
        if (self.focus == .chooser_choice) self.chooser_choice_index = index - 4;
        if (self.focus == .filename) self.filename.selectStem();
        if (self.focus == .location_bar and self.search_visible) {
            self.search_visible = false;
            self.search.text.clearRetainingCapacity();
            self.search.cursor = 0;
            self.rebuildView();
        }
        self.invalidate();
        return true;
    }
    if (self.ctrl and (sym == c.XKB_KEY_l or sym == c.XKB_KEY_L or sym == c.XKB_KEY_f or sym == c.XKB_KEY_F)) return false;
    if (self.focus == .filename) {
        if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) self.acceptChooser() else {
            self.overwrite_pending = false;
            self.editKey(&self.filename, sym, utf8);
        }
        return true;
    }
    if (self.focus == .chooser_choice) {
        if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_space or sym == c.XKB_KEY_Right) {
            const r = self.chooserRect(self.chooser_choice_index + 4);
            _ = self.chooserClick(r.x + 1, r.y + 1, 0x110);
        }
        return true;
    }
    if (self.focus == .chooser_filter) {
        if (sym == c.XKB_KEY_space or sym == c.XKB_KEY_Return or sym == c.XKB_KEY_Right or sym == c.XKB_KEY_Left) self.cycleChooserFilter(sym == c.XKB_KEY_Left);
        return true;
    }
    if (self.focus == .chooser_accept or self.focus == .chooser_cancel) {
        if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_space) {
            if (self.focus == .chooser_accept) self.acceptChooser() else self.chooser_done = true;
        }
        return true;
    }
    if (self.focus == .file_view) {
        if (sym == c.XKB_KEY_F2 or sym == c.XKB_KEY_Delete or sym == c.XKB_KEY_Menu or sym == c.XKB_KEY_F10) return true;
        if (self.ctrl) switch (sym) {
            c.XKB_KEY_n, c.XKB_KEY_N => {
                if (self.shift) self.openNewFolderDialog();
                return true;
            },
            c.XKB_KEY_x, c.XKB_KEY_X, c.XKB_KEY_c, c.XKB_KEY_C, c.XKB_KEY_v, c.XKB_KEY_V => return true,
            c.XKB_KEY_a, c.XKB_KEY_A => if (!self.chooser.?.multiple) {
                return true;
            },
            else => {},
        };
        if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
            if (self.focused_index) |idx| {
                if (idx < self.items.items.len and self.items.items[idx].is_dir) {
                    self.activateItem(idx);
                    return true;
                }
            }
            self.acceptChooser();
            return true;
        }
    }
    return false;
}

pub fn acceptChooser(self: *App) void {
    self.collectChooser() catch {
        self.setStatusNotice(tr("Choose an accessible file or folder and a valid filename."), true);
    };
    self.invalidate();
}

/// Checks the choice on the I/O service; `finishChooser` acts on the
/// verdict. What needs no filesystem (names, the selection) is checked here.
pub fn collectChooser(self: *App) !void {
    const opts = self.chooser orelse return;
    if (app_requests.waiting(self, .chooser)) return;
    for (opts.files) |name| if (!chooser_mod.validName(name)) return error.InvalidName;
    var check: io_requests.ChooserCheck = .{
        .mode = switch (opts.mode) {
            .open => .open,
            .save => .save,
            .folder => .folder,
        },
        .parent = self.history.current,
        .overwrite_confirmed = self.overwrite_pending,
        .files = opts.files,
    };
    var named: ?[]u8 = null;
    errdefer if (named) |path| self.allocator.free(path);
    var selected: std.ArrayList([]const u8) = .empty;
    defer selected.deinit(self.allocator);
    if (opts.mode == .save or (opts.mode == .open and !opts.multiple and self.filename.text.items.len > 0)) {
        const name = self.filename.text.items;
        if (!chooser_mod.validName(name)) return error.InvalidName;
        named = if (self.isRecent()) selected: {
            // Recent spans directories, so the filename alone is not a path.
            for (self.items.items) |item| {
                if (item.selected and std.mem.eql(u8, item.name, name))
                    break :selected try self.allocator.dupe(u8, item.path);
            }
            return error.NoSelection;
        } else try std.fs.path.join(self.allocator, &.{ self.history.current, name });
        check.named = named;
    } else {
        for (self.items.items) |item| {
            if (!item.selected or item.is_broken or item.is_dir != (opts.mode == .folder)) continue;
            try selected.append(self.allocator, item.path);
            if (!opts.multiple) break;
        }
        check.selected = selected.items;
        if (opts.mode == .folder and !self.loading and self.error_message == null) check.fallback = self.history.current;
    }
    if (!app_requests.send(self, .{ .chooser = check }, .{ .chooser = .{ .named = named } })) return error.Unavailable;
    named = null;
}

/// The service checked the choice (`collectChooser`).
pub fn finishChooser(self: *App, named: ?[]const u8, result: *io_requests.ChooserResult) void {
    switch (result.verdict) {
        .navigate => if (named) |path| self.navigate(path),
        .confirm_overwrite => self.overwrite_pending = true,
        .inaccessible, .no_selection => self.setStatusNotice(tr("Choose an accessible file or folder and a valid filename."), true),
        .accept => {
            for (self.chooser_paths.items) |path| self.allocator.free(path);
            self.chooser_paths.clearRetainingCapacity();
            for (result.paths) |path| {
                self.chooser_paths.append(self.allocator, path) catch {
                    self.allocator.free(path);
                    continue;
                };
            }
            // The paths now belong to the chooser.
            self.allocator.free(result.paths);
            result.paths = &.{};
            self.chooser_done = true;
            self.chooser_accepted = true;
        },
    }
    self.invalidate();
}

pub fn renderChooser(self: *App, cr: *c.cairo_t) void {
    const opts = self.chooser.?;
    const top: f64 = @floatFromInt(self.h - self.footerHeight());
    setSource(cr, ui_theme.global.app_bar);
    c.cairo_rectangle(cr, 0, top, @floatFromInt(self.w), @floatFromInt(self.footerHeight()));
    c.cairo_fill(cr);
    setSource(cr, ui_theme.global.app_divider);
    c.cairo_rectangle(cr, 0, top, @floatFromInt(self.w), 1);
    c.cairo_fill(cr);
    setSource(cr, ui_theme.global.window_fg);
    drawText(cr, if (opts.mode == .folder) tr("Folder:") else tr("File name:"), 16, self.chooserRect(0).y + 23, shell_ui.textSize(), false);
    if (opts.mode == .folder) {
        drawEllipsis(cr, self.history.current, 96, self.chooserRect(0).y + 23, self.chooserRect(0).w, shell_ui.textSize(), false);
    } else self.renderEditor(cr, &self.filename, self.chooserRect(0), self.focus == .filename, false);
    for (1..4) |i| {
        const r = self.chooserRect(i);
        const text = switch (i) {
            1 => if (self.overwrite_pending) tr("Replace") else if (opts.accept_label.len > 0) opts.accept_label else switch (opts.mode) {
                .open => tr("Open"),
                .save => tr("Save"),
                .folder => tr("Select"),
            },
            2 => tr("Cancel"),
            else => if (opts.filters.len == 0) tr("All files") else opts.filters[opts.filter_index].name,
        };
        var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) }) orelse continue;
        ui_button.paint(&layer.renderer, layer.local(), .{ .label = text, .variant = if (i == 1) .primary else .secondary, .alignment = if (i == 3) .left else .center, .trailing_icon = if (i == 3 and opts.filters.len > 0) .chevron_down else null }, .{ .pointer = if (i == 3 and opts.filters.len == 0) .disabled else if (r.contains(self.mouse_x, self.mouse_y)) .hover else .idle, .selected = self.focus == (switch (i) {
            1 => Focus.chooser_accept,
            2 => Focus.chooser_cancel,
            else => Focus.chooser_filter,
        }) });
        layer.finish();
    }
    for (opts.choices, 0..) |choice, i| {
        var buf: [512]u8 = undefined;
        var value_label = self.chooser_choices.items[i];
        for (choice.values) |value| if (std.mem.eql(u8, value.id, value_label)) {
            value_label = value.label;
            break;
        };
        const label = std.fmt.bufPrint(&buf, "{s}: {s}", .{ choice.label, value_label }) catch choice.label;
        const r = self.chooserRect(i + 4);
        var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) }) orelse continue;
        ui_button.paint(&layer.renderer, layer.local(), .{ .label = label }, .{ .selected = self.focus == .chooser_choice and self.chooser_choice_index == i, .pointer = if (r.contains(self.mouse_x, self.mouse_y)) .hover else .idle });
        layer.finish();
    }
    if (self.overwrite_pending or self.status_notice != null) {
        setSource(cr, ui_theme.global.window_fg);
        drawEllipsis(cr, if (self.overwrite_pending) tr("A file with this name exists. Replace it?") else self.status_notice.?, 16, top + (if (self.w >= 800) @as(f64, 78) else 56), @floatFromInt(self.w - 32), shell_ui.textSize(), false);
    }
}
