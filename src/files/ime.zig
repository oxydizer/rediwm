//! text-input-v3 for Files: the terminal drawer and the app's single-line
//! text fields (search, location bar, dialog fields and the chooser name).
//! Terminal commits go to the PTY and its preedit stays in the drawer; field
//! commits edit the active `Editor`, whose preedit is drawn at the caret
//! until the input method commits it.
const std = @import("std");
const wl = @import("wayland").client.wl;
const zwp = @import("wayland").client.zwp;
const app_mod = @import("app.zig");
const App = app_mod.App;
const Editor = @import("editor.zig").Editor;
const tc = @import("terminal/model.zig").c;

/// Where the current composition goes.
const Target = enum { none, terminal, editor };

pub const Ime = struct {
    app: *App,
    manager: ?*zwp.TextInputManagerV3 = null,
    /// The window's surface: with several windows on one connection the seat's
    /// enter and leave events name the surface, and only its own count.
    surface: ?*wl.Surface = null,
    input: ?*zwp.TextInputV3 = null,
    entered: bool = false,
    enabled: bool = false,
    serial: u32 = 0,
    revision: usize = 0,
    target: Target = .none,
    session: ?*tc.FT = null,
    editor: ?*Editor = null,
    cursor: usize = 0,
    anchor: usize = 0,
    before: usize = 0,
    after: usize = 0,
    method_change: bool = false,
    rectangle: [4]i32 = @splat(0),
    commit_text: std.ArrayList(u8) = .empty,
    preedit_text: std.ArrayList(u8) = .empty,
    has_commit: bool = false,
    has_preedit: bool = false,
    invalid: bool = false,
    // The last field state the cursor rectangle was measured from. Measuring
    // text needs a Cairo layout, so it runs only when one of these moves.
    field_scroll: f64 = 0,
    field_window: [2]i32 = .{ 0, 0 },
    field_sidebar: i32 = 0,
    field_view_y: i32 = 0,
    field_scale: i32 = 1,
    field_dialog: ?app_mod.DialogKind = null,

    pub fn setup(self: *Ime, seat: *wl.Seat) !void {
        if (self.manager) |manager| {
            self.input = try manager.getTextInput(seat);
            self.input.?.setListener(*Ime, event, self);
        }
    }
    pub fn deinit(self: *Ime) void {
        if (self.input) |input| input.destroy();
        if (self.manager) |manager| manager.destroy();
        self.commit_text.deinit(self.app.allocator);
        self.preedit_text.deinit(self.app.allocator);
    }
    fn clear(self: *Ime) void {
        self.commit_text.clearRetainingCapacity();
        self.preedit_text.clearRetainingCapacity();
        self.has_commit = false;
        self.has_preedit = false;
        self.invalid = false;
        self.before = 0;
        self.after = 0;
    }
    /// Drops local preedit from both the drawer and the app's fields.
    fn clearPreedit(self: *Ime) void {
        const app = self.app;
        if (app.preedit.items.len > 0 or app.preedit_editor != null) {
            app.preedit.clearRetainingCapacity();
            app.preedit_editor = null;
            app.invalidate();
        }
        if (app.terminal.preedit.items.len > 0) {
            app.terminal.preedit.clearRetainingCapacity();
            app.terminalDamage();
        }
    }
    /// The field that should receive composition right now.
    fn currentTarget(self: *Ime) Target {
        const app = self.app;
        if (app.menu != null) return .none;
        if (app.dialog != null) return if (app.activeEditor() != null) .editor else .none;
        if (app.focus == .terminal) return if (app.terminal.visible and app.terminal.session != null) .terminal else .none;
        return if (app.activeEditor() != null) .editor else .none;
    }
    fn event(input: *zwp.TextInputV3, ev: zwp.TextInputV3.Event, self: *Ime) void {
        switch (ev) {
            .enter => |entered| {
                if (entered.surface != self.surface) return;
                self.entered = true;
            },
            .leave => |left| {
                if (left.surface != self.surface) return;
                // enable belongs to the surface from enter: disable it before
                // dropping that surface, or the compositor still believes the
                // input is enabled and a later enable/commit after re-entering
                // changes nothing. No enable event then reaches the relay, so
                // the input method is never activated again (window switching
                // silently stops composition).
                if (self.enabled) {
                    input.disable();
                    input.commit();
                    self.serial +%= 1;
                }
                self.entered = false;
                self.enabled = false;
                self.clear();
                self.clearPreedit();
                self.app.invalidate();
            },
            .preedit_string => |e| {
                self.preedit_text.clearRetainingCapacity();
                self.has_preedit = true;
                if (e.text) |s| {
                    const bytes = std.mem.span(s);
                    if (bytes.len <= 4096 and std.unicode.utf8ValidateSlice(bytes)) self.preedit_text.appendSlice(self.app.allocator, bytes) catch {} else self.invalid = true;
                }
            },
            .commit_string => |e| {
                self.commit_text.clearRetainingCapacity();
                self.has_commit = true;
                if (e.text) |s| {
                    const bytes = std.mem.span(s);
                    if (bytes.len <= 4096 and std.unicode.utf8ValidateSlice(bytes)) self.commit_text.appendSlice(self.app.allocator, bytes) catch {} else self.invalid = true;
                }
            },
            .delete_surrounding_text => |e| {
                self.before = e.before_length;
                self.after = e.after_length;
            },
            .done => |e| {
                defer self.clear();
                if (self.invalid or e.serial != self.serial or !self.enabled) return;
                if (self.target == .terminal) self.applyTerminal();
                if (self.target == .editor) self.applyEditor();
            },
        }
    }
    fn applyTerminal(self: *Ime) void {
        const app = self.app;
        if (self.before != 0 or self.after != 0 or app.dialog != null or app.menu != null or
            app.focus != .terminal or !app.terminal.visible or
            self.session != app.terminal.session or self.revision != app.edit_revision) return;
        if (self.commit_text.items.len > 0) {
            // An IME commit is typed text, never paste or shell syntax.
            if (self.session) |session| tc.ft_key(session, 0, self.commit_text.items.ptr, self.commit_text.items.len, 0);
        }
        app.terminal.preedit.clearRetainingCapacity();
        if (self.has_preedit) app.terminal.preedit.appendSlice(app.allocator, self.preedit_text.items) catch {};
        app.terminalDamage();
    }
    fn applyEditor(self: *Ime) void {
        const app = self.app;
        const edit = app.activeEditor() orelse return;
        // Another field took focus, or the app changed the text after the
        // surrounding state this commit answers.
        const dialog_kind: ?app_mod.DialogKind = if (app.dialog) |*dlg| dlg.kind else null;
        if (edit != self.editor or dialog_kind != self.field_dialog or app.menu != null or
            self.revision != app.edit_revision or edit.cursor != self.cursor or edit.anchor != self.anchor) return;
        if (self.before > 0 or self.after > 0) {
            const text = edit.text.items;
            const selected = edit.selection();
            if (self.before > selected[0] or self.after > text.len - selected[1]) return;
            const start = selected[0] - self.before;
            const end = selected[1] + self.after;
            if ((start < text.len and text[start] & 0xc0 == 0x80) or (end < text.len and text[end] & 0xc0 == 0x80)) return;
            edit.select_all = false;
            edit.anchor = start;
            edit.cursor = end;
        }
        const insert = self.has_commit or self.before > 0 or self.after > 0 or
            (self.has_preedit and self.preedit_text.items.len > 0 and edit.cursor != edit.anchor);
        if (insert) {
            edit.insert(app.allocator, self.commit_text.items) catch {
                app.preedit.clearRetainingCapacity();
                app.preedit_editor = null;
                app.invalidate();
                return;
            };
            app.edit_revision += 1;
            self.method_change = true;
            if (app.focus == .filename) app.overwrite_pending = false;
            if (app.dialog == null and app.focus == .search) app.rebuildView();
        }
        app.preedit.clearRetainingCapacity();
        if (self.has_preedit and self.preedit_text.items.len > 0) {
            app.preedit.appendSlice(app.allocator, self.preedit_text.items) catch {};
            app.preedit_editor = edit;
        } else app.preedit_editor = null;
        app.invalidate();
    }
    /// The active field's caret rectangle in surface coordinates.
    fn fieldRectangle(self: *Ime, titlebar: i32) ?[4]i32 {
        const caret = self.app.editorCaretRect() orelse return null;
        return .{
            @intFromFloat(caret.x),
            @as(i32, @intFromFloat(caret.y)) + titlebar,
            @intFromFloat(@max(1, caret.w)),
            @intFromFloat(@max(1, caret.h)),
        };
    }
    pub fn sync(self: *Ime, titlebar: i32) void {
        const input = self.input orelse return;
        // enable/disable belong to the surface obtained from enter.
        const target: Target = if (self.entered) self.currentTarget() else .none;
        if (target == .none) {
            if (self.enabled) {
                input.disable();
                input.commit();
                self.serial +%= 1;
            }
            self.enabled = false;
            self.target = .none;
            self.session = null;
            self.editor = null;
            self.clear();
            self.clearPreedit();
            return;
        }
        if (target == .terminal) {
            const session = self.app.terminal.session orelse return;
            var row: c_int = 0;
            var col: c_int = 0;
            var shape: c_int = 0;
            _ = tc.ft_cursor(session, &row, &col, &shape);
            const body = self.app.terminalBody();
            const rect: [4]i32 = .{
                @intFromFloat(body.x + @as(f64, @floatFromInt(col)) * self.app.terminal.cell_w),
                @as(i32, @intFromFloat(body.y + @as(f64, @floatFromInt(row)) * self.app.terminal.cell_h)) + titlebar,
                @intFromFloat(self.app.terminal.cell_w),
                @intFromFloat(self.app.terminal.cell_h),
            };
            if (self.enabled and self.target == .terminal and self.session == session and
                self.revision == self.app.edit_revision and std.meta.eql(rect, self.rectangle)) return;
            if (!self.enabled or self.target != .terminal or self.session != session) {
                input.enable();
                self.clear();
                self.clearPreedit();
            }
            self.enabled = true;
            self.target = .terminal;
            self.session = session;
            self.editor = null;
            self.revision = self.app.edit_revision;
            self.rectangle = rect;
            input.setSurroundingText("", 0, 0);
            input.setContentType(.{ .multiline = true }, .terminal);
        } else {
            const edit = self.app.activeEditor() orelse return;
            const dialog_kind: ?app_mod.DialogKind = if (self.app.dialog) |*dlg| dlg.kind else null;
            const same = self.enabled and self.target == .editor and self.editor == edit and
                self.field_dialog == dialog_kind and
                self.revision == self.app.edit_revision and self.cursor == edit.cursor and
                self.anchor == edit.anchor and self.field_scroll == edit.scroll and
                self.field_window[0] == self.app.w and self.field_window[1] == self.app.h and
                self.field_sidebar == self.app.sidebarWidth() and self.field_view_y == self.app.scroll_y and
                self.field_scale == self.app.scale;
            if (same) return;
            const rect = self.fieldRectangle(titlebar) orelse return;
            if (!self.enabled or self.target != .editor or self.editor != edit or self.field_dialog != dialog_kind) {
                input.enable();
                self.clear();
                self.clearPreedit();
            }
            self.enabled = true;
            self.target = .editor;
            self.session = null;
            self.editor = edit;
            self.field_dialog = dialog_kind;
            self.revision = self.app.edit_revision;
            self.cursor = edit.cursor;
            self.anchor = edit.anchor;
            self.field_scroll = edit.scroll;
            self.field_window = .{ self.app.w, self.app.h };
            self.field_sidebar = self.app.sidebarWidth();
            self.field_view_y = self.app.scroll_y;
            self.field_scale = self.app.scale;
            self.rectangle = rect;
            setEditorSurrounding(input, edit);
            input.setContentType(.{}, .normal);
        }
        input.setTextChangeCause(if (self.method_change) .input_method else .other);
        self.method_change = false;
        input.setCursorRectangle(self.rectangle[0], self.rectangle[1], @max(1, self.rectangle[2]), @max(1, self.rectangle[3]));
        input.commit();
        self.serial +%= 1;
    }
};

/// Advertises the field's text around the selection. Indices are byte
/// offsets and must sit on code point boundaries; text-input-v3 messages are
/// bounded, so a long value is windowed like the Editor app's.
fn setEditorSurrounding(input: *zwp.TextInputV3, edit: *Editor) void {
    const text = edit.text.items;
    const selected = edit.selection();
    var cursor = edit.cursor;
    var anchor = edit.anchor;
    if (edit.select_all) {
        cursor = text.len;
        anchor = 0;
    }
    if (selected[1] - selected[0] > 3800) {
        // Re-enabling drops the previously advertised surrounding text.
        input.enable();
        return;
    }
    const spare = (3800 - (selected[1] - selected[0])) / 2;
    var start = selected[0] -| spare;
    while (start < text.len and text[start] & 0xc0 == 0x80) start += 1;
    var end = @min(text.len, start + 3800);
    while (end < text.len and text[end] & 0xc0 == 0x80) end -= 1;
    var surrounding: [4000:0]u8 = @splat(0);
    @memcpy(surrounding[0 .. end - start], text[start..end]);
    input.setSurroundingText(&surrounding, @intCast(cursor - start), @intCast(anchor - start));
}
