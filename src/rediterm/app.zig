//! RediTerm in the app kit window host. Each tab owns a session on the
//! Files terminal engine (libvterm, the PTY helper, and the cell painter).
const std = @import("std");
const ui = @import("ui");
const shell = ui.cairo;
const c = @import("c_gfx");
const sessions = @import("sessions.zig");
const controls = @import("controls.zig");
const model = @import("../files/terminal/model.zig");
const paint = @import("../files/terminal/paint.zig");
const tc = model.c;
const nowMs = ui.key_repeat.nowMs;
const gpa = @import("memory").gpa;
const Region = ui.repaint.Region;
const Rect = ui.repaint.Rect;

/// Space between the window edge and the grid.
const pad = 6;
/// Scroll units (one wheel notch is 15) per line.
pub const wheel_step = 7.5;

pub const App = struct {
    // Read and written by the window host.
    w: i32 = 760,
    h: i32 = 460,
    scale: i32 = 1,
    density: f64 = 1,
    dirty: bool = true,
    closed: bool = false,
    suspended: bool = false,
    focused: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    clipboard_revision: u64 = 0,
    paste_requested: bool = false,
    /// While the caret glides: the host steps it on frame callbacks.
    animating: bool = false,

    /// Where the shell starts, and the command run instead of it (`-e`).
    directory: [:0]const u8,
    command: Command = null,
    started: bool = false,
    failure: ?[]const u8 = null,
    tabs: std.ArrayList(sessions.Tab) = .empty,
    next_id: u32 = 1,
    selected: usize = 0,
    closing: bool = false,
    strip_in_titlebar: bool = false,
    first_visible: usize = 0,
    menu_open: bool = false,
    menu_x: f64 = 0,
    menu_selected: bool = false,
    rows: i32 = 0,
    cols: i32 = 0,
    metrics: paint.Metrics = .{},
    measured_density: f64 = 0,
    reported_focus: bool = false,
    caret: ui.input.Caret = .{},
    caret_origin: ?CaretOrigin = null,
    /// What changed since the last frame beyond the engine's rows (`frameDamage`).
    damage: Region = .whole,
    /// The caret position for the frame being painted, and the box the
    /// caret covered in the last one.
    frame_caret: ?paint.CursorPosition = null,
    painted_caret: ?Rect = null,
    painted_selection: ?model.Selection = null,
    painted_message: ?[*]const u8 = null,
    clipboard: std.ArrayList(u8) = .empty,
    paste_tab: ?u32 = null,
    repeat_tab: ?u32 = null,
    selecting: bool = false,
    mouse_buttons: u8 = 0,
    mouse_x: f64 = -1,
    mouse_y: f64 = -1,
    pointer_hover: bool = false,
    wheel: f64 = 0,
    pub const Command = ?[*:null]const ?[*:0]const u8;
    pub const poll_slots = sessions.poll_slots;

    const CaretOrigin = struct {
        line: i64,
        row: c_int,
        shape: c_int,
        alternate: bool,

        fn follows(next: CaretOrigin, previous: CaretOrigin) bool {
            if (previous.alternate or next.alternate or previous.shape != next.shape) return false;
            // A newline at the bottom advances scrollback, keeping the same screen row.
            return (next.line == previous.line and next.row == previous.row + 1) or
                (next.line == previous.line + 1 and next.row == previous.row);
        }
    };

    pub fn deinit(self: *App) void {
        for (self.tabs.items) |tab| tab.deinit();
        self.tabs.deinit(gpa);
        self.clipboard.deinit(gpa);
    }

    pub const requestClose = sessions.requestClose;
    pub const pollFds = sessions.pollFds;
    pub const pollReady = sessions.pollReady;
    pub const timeoutMs = sessions.timeoutMs;
    pub const current = sessions.current;
    pub const inputTab = sessions.inputTab;
    pub const newTab = sessions.newTab;
    pub const selectTab = sessions.selectTab;
    pub const closeTab = sessions.closeTab;
    pub const titlebarTabHandler = controls.titlebarTabHandler;
    pub const publishTitlebarTabs = controls.publishTitlebarTabs;
    pub const revealTab = controls.revealTab;
    pub const damageStrip = controls.damageStrip;

    pub fn getTitle(self: *App) [*:0]const u8 {
        return if (self.current()) |tab| tab.name() else "RediTerm";
    }

    /// Release the old PTY's pointer grab and focus before changing selection.
    pub fn leaveTab(self: *App) void {
        self.cancelDrag();
        if (self.reported_focus) {
            if (self.current()) |tab| if (tab.session) |session| tc.ft_focus(session, false);
            self.reported_focus = false;
        }
        self.paste_tab = null;
        self.paste_requested = false;
        self.repeat_tab = null;
    }

    pub fn viewChanged(self: *App) void {
        self.menu_open = false;
        self.wheel = 0;
        self.resetCaret();
        self.revealTab();
        self.damage = .whole;
        self.dirty = true;
    }

    pub fn setTitlebarTabs(self: *App, enabled: bool) void {
        if (enabled == self.strip_in_titlebar) return;
        self.strip_in_titlebar = enabled;
        self.viewChanged();
    }

    pub fn setSuspended(self: *App, suspended: bool) void {
        self.suspended = suspended;
        if (suspended) {
            self.cancelDrag();
            self.menu_open = false;
            self.resetCaret();
        }
        self.damage = .whole;
        self.dirty = true;
    }

    pub fn resize(self: *App, w: i32, h: i32) void {
        self.w = w;
        self.h = h;
        self.layout();
        self.revealTab();
        self.damage = .whole;
        self.dirty = true;
    }

    pub fn themeChanged(self: *App) void {
        for (self.tabs.items) |tab| if (tab.session) |session| paint.applyPalette(session);
        self.measured_density = 0; // The text size may have changed too.
        self.layout();
        self.damage = .whole;
    }

    /// Cell metrics for the current density and the grid that fits the
    /// window; the session starts with the first grid.
    fn layout(self: *App) void {
        if (self.measured_density != self.density) {
            self.metrics = paint.Metrics.measure(@floatCast(self.density));
            self.measured_density = self.density;
            self.resetCaret();
            self.damage = .whole;
        }
        const cols: i32 = @intFromFloat(std.math.clamp(@floor(@as(f64, @floatFromInt(self.w - 2 * pad)) / self.metrics.cell_w), 2, 512));
        const rows: i32 = @intFromFloat(std.math.clamp(@floor((@as(f64, @floatFromInt(self.h - pad)) - self.gridTop()) / self.metrics.cell_h), 1, 512));
        if (rows != self.rows or cols != self.cols) {
            self.rows = rows;
            self.cols = cols;
            for (self.tabs.items) |*tab| tab.resize(rows, cols);
            self.resetCaret();
            self.dirty = true;
        }
        if (!self.started) {
            self.started = true;
            sessions.add(self, self.command);
        }
    }

    fn gridTop(self: *const App) f64 {
        return controls.inset(self) + pad;
    }

    fn resetCaret(self: *App) void {
        self.caret_origin = null;
        self.animating = false;
    }

    fn caretPosition(self: *App, session: *tc.FT) ?paint.CursorPosition {
        const target = if (self.focused) paint.Cursor.get(session) else null;
        const cursor = target orelse {
            self.resetCaret();
            return null;
        };
        const origin: CaretOrigin = .{
            .line = tc.ft_line(session),
            .row = cursor.row,
            .shape = cursor.shape,
            .alternate = tc.ft_alternate(session),
        };
        const now = nowMs();
        const x: f32 = @floatCast(@as(f64, @floatFromInt(cursor.col)) * self.metrics.cell_w);
        const y: f32 = @floatCast(@as(f64, @floatFromInt(cursor.row)) * self.metrics.cell_h);
        const motion_ms: i64 = ui.input.caret_config.motion_ms;
        if (!std.meta.eql(self.caret_origin, @as(?CaretOrigin, origin))) {
            const from_x = self.caret.offset(now);
            const from_y = self.caret.y.value(now);
            const newline = if (self.caret_origin) |previous| origin.follows(previous) else false;
            if (newline and motion_ms > 0 and (x != from_x or y != from_y) and @abs(y - from_y) <= ui.input.caret_snap_distance) {
                const duration = motion_ms + @divTrunc(motion_ms, 2);
                self.caret.x = .initDuration(from_x, x, now, duration, .out_cubic);
                self.caret.y = .initDuration(from_y, y, now, duration, .out_cubic);
                self.caret.last_move_ms = now;
            } else {
                self.caret.snap = true;
                self.caret.y.cancel(y);
            }
            self.caret_origin = origin;
        }
        if (self.caret.y.settled(now)) {
            self.caret.track(now, x);
        } else if (self.caret.x.to != x) {
            // A prompt can arrive during the glide. Both axes still land together.
            const elapsed: i64 = @intFromFloat(self.caret.y.elapsedEffective(now));
            self.caret.x = .initDuration(self.caret.offset(now), x, now, self.caret.y.settle_ms - elapsed, .out_cubic);
        }
        const moving = self.caret.moving(now);
        self.animating = moving;
        return if (moving) .{ .x = self.caret.offset(now), .y = self.caret.y.value(now) } else null;
    }

    pub const handleKey = @import("input.zig").handleKey;
    pub const keyRepeats = @import("input.zig").keyRepeats;
    pub const handleMotion = @import("input.zig").handleMotion;
    pub const handleButton = @import("input.zig").handleButton;
    pub const handleAxis = @import("input.zig").handleAxis;
    pub const cancelDrag = @import("input.zig").cancelDrag;

    pub fn cursorName(self: *App) [*:0]const u8 {
        return if (self.menu_open or self.mouse_y < controls.inset(self)) "default" else "text";
    }

    pub fn copySelection(self: *App) void {
        const tab = self.inputTab() orelse return;
        const session = tab.session orelse return;
        const selection = tab.selection orelse return;
        const bytes = paint.selectionText(gpa, session, selection) catch return;
        defer gpa.free(bytes);
        if (bytes.len == 0) return;
        self.clipboard.clearRetainingCapacity();
        self.clipboard.appendSlice(gpa, bytes) catch return;
        self.clipboard_revision += 1;
    }
    pub fn clipboardText(self: *App) []const u8 {
        return self.clipboard.items;
    }
    pub fn pasteText(self: *App, bytes: []const u8) void {
        const target = self.paste_tab;
        self.paste_tab = null;
        const tab = self.inputTab() orelse return;
        if (tab.id != target) return;
        const session = tab.session orelse return;
        if (!tc.ft_running(session)) return;
        // Bracketed paste; control bytes and ESC are dropped by the engine.
        _ = tc.ft_paste(session, bytes.ptr, bytes.len);
        tab.selection = null;
        self.dirty = true;
    }

    /// The rows the engine changed, the caret's old and new boxes and a
    /// changed selection; the frame repaints only those. Lays out first, so a
    /// new grid size is in it.
    pub fn frameDamage(self: *App) Region {
        self.layout();
        var region = self.damage;
        self.damage = .{};
        const message_ptr: ?[*]const u8 = if (self.message()) |text| text.ptr else null;
        if (message_ptr != self.painted_message) region = .whole;
        self.painted_message = message_ptr;
        const tab = self.current() orelse return region;
        const session = tab.session orelse {
            self.frame_caret = null;
            return region;
        };
        var rows: [512]u8 = undefined;
        const count: usize = @intCast(std.math.clamp(tc.ft_rows(session), 0, rows.len));
        if (tc.ft_take_damage(session, &rows, @intCast(count))) region = .whole;
        var row: usize = 0;
        while (row < count) {
            if (rows[row] == 0) {
                row += 1;
                continue;
            }
            const first = row;
            while (row < count and rows[row] != 0) row += 1;
            region.add(self.rowsRect(@intCast(first), @intCast(row)));
        }
        if (!std.meta.eql(tab.selection, self.painted_selection)) {
            if (self.painted_selection) |old| if (self.selectionRect(session, old)) |r| region.add(r);
            if (tab.selection) |new| if (self.selectionRect(session, new)) |r| region.add(r);
            self.painted_selection = tab.selection;
        }
        // Where the caret was and where it is now; a glide repaints just these.
        self.frame_caret = self.caretPosition(session);
        const caret = self.caretRect(session);
        if (self.painted_caret) |r| region.add(r);
        if (caret) |r| region.add(r);
        self.painted_caret = caret;
        return region;
    }

    /// Full-width band over grid rows [first, end), in content coordinates.
    fn rowsRect(self: *const App, first: i32, end: i32) Rect {
        const ch = self.metrics.cell_h;
        const top = self.gridTop() + @as(f64, @floatFromInt(first)) * ch;
        return .around(0, top, @floatFromInt(self.w), @as(f64, @floatFromInt(end - first)) * ch);
    }

    fn selectionRect(self: *const App, session: *tc.FT, selection: model.Selection) ?Rect {
        const ends = selection.ordered();
        const view_top = tc.ft_line(session) - tc.ft_offset(session);
        const rows: i64 = tc.ft_rows(session);
        const first = std.math.clamp(ends[0].line - view_top, 0, rows);
        const last = std.math.clamp(ends[1].line - view_top + 1, 0, rows);
        if (last <= first) return null;
        return self.rowsRect(@intCast(first), @intCast(last));
    }

    /// The box `paint.paintCursor` draws the caret in this frame.
    fn caretRect(self: *const App, session: *tc.FT) ?Rect {
        const cursor = paint.Cursor.get(session) orelse return null;
        const m = self.metrics;
        const rest: paint.CursorPosition = .{
            .x = @as(f64, @floatFromInt(cursor.col)) * m.cell_w,
            .y = @as(f64, @floatFromInt(cursor.row)) * m.cell_h,
        };
        const position = if (self.focused) self.frame_caret orelse rest else rest;
        return .around(pad + position.x, self.gridTop() + position.y, m.cell_w, m.cell_h);
    }

    fn message(self: *App) ?[]const u8 {
        const tab = self.current() orelse return self.failure;
        if (tab.failure) |text| return text;
        const session = tab.session orelse return null;
        return if (tc.ft_error(session)) |text| std.mem.span(text) else null;
    }

    pub fn render(self: *App, cr: *c.cairo_t) void {
        const tab = self.current();
        const focus = self.focused and self.inputTab() != null;
        if (tab) |active| if (active.session) |session| {
            if (focus != self.reported_focus) {
                self.reported_focus = focus;
                tc.ft_focus(session, focus);
            }
        };
        shell.setSource(cr, paint.background());
        c.cairo_rectangle(cr, 0, 0, @floatFromInt(self.w), @floatFromInt(self.h));
        c.cairo_fill(cr);
        if (tab) |active| if (active.session) |session| {
            const m = self.metrics;
            paint.paintCells(cr, session, .{
                .x = pad,
                .y = self.gridTop(),
                .w = @as(f64, @floatFromInt(tc.ft_cols(session))) * m.cell_w,
                .h = @as(f64, @floatFromInt(tc.ft_rows(session))) * m.cell_h,
                .metrics = m,
                .selection = active.selection,
                .focused = self.focused,
                .hollow_cursor = true,
                .cursor_position = self.frame_caret,
            });
        };
        if (self.message()) |text| {
            shell.setSource(cr, ui.theme.global.window_fg);
            shell.drawText(cr, text, pad + 8, self.gridTop() + 8 + shell.textSize(), shell.textSize(), true);
        }
        controls.render(self, cr);
    }

    /// The grid position under a surface point, clamped into the grid.
    pub fn pointAt(self: *const App, session: *tc.FT, x: f64, y: f64) model.Point {
        const row = std.math.clamp(@floor((y - self.gridTop()) / self.metrics.cell_h), 0, @as(f64, @floatFromInt(tc.ft_rows(session) - 1)));
        const col = std.math.clamp(@floor((x - pad) / self.metrics.cell_w), 0, @as(f64, @floatFromInt(tc.ft_cols(session))));
        return .{ .line = tc.ft_line(session) - tc.ft_offset(session) + @as(i32, @intFromFloat(row)), .col = @intFromFloat(col) };
    }
};
