//! RediTerm: one terminal session per window, on the engine the Files drawer
//! uses (`files/terminal/`: libvterm, the PTY helper, the cell painter), in
//! the app kit's window host. The shell's exit closes the window.
const std = @import("std");
const ui = @import("ui");
const shell = ui.cairo;
const c = @import("c_gfx");
const platform = @import("platform");
const model = @import("../files/terminal/model.zig");
const paint = @import("../files/terminal/paint.zig");
const tc = model.c;
const nowMs = ui.key_repeat.nowMs;
const gpa = @import("memory").gpa;

/// Space between the window edge and the grid.
const pad = 6;
/// Scroll units (one wheel notch is 15) per line.
pub const wheel_step = 7.5;
/// How long a hung-up shell gets before it is killed, and again before the
/// window gives up on it.
const hangup_ms = 750;

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

    /// Where the shell starts, and the command run instead of it (`-e`).
    directory: [:0]const u8,
    command: ?[*:null]const ?[*:0]const u8 = null,
    session: ?*tc.FT = null,
    started: bool = false,
    failure: ?[]const u8 = null,
    metrics: paint.Metrics = .{},
    measured_density: f64 = 0,
    reported_focus: bool = false,
    clipboard: std.ArrayList(u8) = .empty,
    selection: ?model.Selection = null,
    selecting: bool = false,
    mouse_buttons: u8 = 0,
    mouse_x: f64 = -1,
    mouse_y: f64 = -1,
    wheel: f64 = 0,
    hangup_at: ?i64 = null,
    forced: bool = false,
    title: [256:0]u8 = @splat(0),

    pub fn deinit(self: *App) void {
        if (self.session) |session| tc.ft_free(session);
        self.session = null;
        self.clipboard.deinit(gpa);
    }

    pub fn getTitle(self: *App) [*:0]const u8 {
        return if (self.title[0] != 0) &self.title else "RediTerm";
    }

    /// The shell's own title (OSC 0/2), cut to whole UTF-8 characters.
    fn refreshTitle(self: *App) void {
        const session = self.session orelse return;
        const raw = std.mem.span(tc.ft_title(session));
        var len = @min(raw.len, self.title.len);
        while (len > 0 and !std.unicode.utf8ValidateSlice(raw[0..len])) len -= 1;
        const text = std.mem.trim(u8, raw[0..len], " ");
        if (std.mem.eql(u8, text, std.mem.sliceTo(&self.title, 0))) return;
        @memset(&self.title, 0);
        @memcpy(self.title[0..text.len], text);
    }

    pub fn requestClose(self: *App) void {
        const session = self.session orelse return self.quit();
        if (!tc.ft_running(session)) return self.quit();
        if (self.hangup_at != null) return;
        // A hangup first, so shells save their history and editors their state.
        tc.ft_close(session, false);
        self.hangup_at = nowMs() + hangup_ms;
    }

    fn quit(self: *App) void {
        self.closed = true;
    }

    fn finishClose(self: *App, now: i64) void {
        const at = self.hangup_at orelse return;
        const session = self.session orelse return self.quit();
        if (!tc.ft_running(session)) return self.quit();
        if (now < at) return;
        if (self.forced) return self.quit();
        tc.ft_close(session, true);
        self.forced = true;
        self.hangup_at = now + hangup_ms;
    }

    pub fn setSuspended(self: *App, suspended: bool) void {
        self.suspended = suspended;
        if (suspended) self.cancelDrag();
        self.dirty = true;
    }

    pub fn resize(self: *App, w: i32, h: i32) void {
        self.w = w;
        self.h = h;
        self.layout();
        self.dirty = true;
    }

    pub fn themeChanged(self: *App) void {
        if (self.session) |session| paint.applyPalette(session);
        self.measured_density = 0; // The text size may have changed too.
        self.layout();
    }

    /// Cell metrics for the current density and the grid that fits the
    /// window; the session starts with the first grid.
    fn layout(self: *App) void {
        if (self.measured_density != self.density) {
            self.metrics = paint.Metrics.measure(@floatCast(self.density));
            self.measured_density = self.density;
        }
        const cols: i32 = @intFromFloat(std.math.clamp(@floor(@as(f64, @floatFromInt(self.w - 2 * pad)) / self.metrics.cell_w), 2, 512));
        const rows: i32 = @intFromFloat(std.math.clamp(@floor(@as(f64, @floatFromInt(self.h - 2 * pad)) / self.metrics.cell_h), 1, 512));
        if (self.session) |session| {
            if (rows == tc.ft_rows(session) and cols == tc.ft_cols(session)) return;
            if (cols != tc.ft_cols(session)) self.selection = null;
            tc.ft_resize(session, rows, cols);
            self.dirty = true;
        } else if (!self.started) self.start(rows, cols);
    }

    fn start(self: *App, rows: i32, cols: i32) void {
        self.started = true;
        const session = tc.ft_new(rows, cols) orelse {
            self.failure = "Could not allocate the terminal";
            return;
        };
        self.session = session;
        paint.applyPalette(session);
        var helper_buf: [4096]u8 = undefined;
        // The Files helper sets up the PTY session in a fresh process.
        const helper = platform.exe.sibling(&helper_buf, "rediwm-files-terminal") orelse {
            self.failure = "The terminal helper is unavailable";
            return;
        };
        if (self.command) |argv|
            _ = tc.ft_start_command(session, helper, self.directory, @ptrCast(argv))
        else
            _ = tc.ft_start(session, helper, "", self.directory, false);
    }

    pub fn pollFds(self: *App, fds: []c.struct_pollfd) usize {
        const session = self.session orelse return 0;
        if (fds.len < 3) return 0;
        fds[0] = .{ .fd = tc.ft_pty(session), .events = @intCast(c.POLLIN | @as(c_int, if (tc.ft_wants_write(session)) c.POLLOUT else 0)), .revents = 0 };
        fds[1] = .{ .fd = tc.ft_channel(session), .events = @intCast(c.POLLIN | @as(c_int, if (tc.ft_wants_request(session)) c.POLLOUT else 0)), .revents = 0 };
        fds[2] = .{ .fd = tc.ft_exit_fd(session), .events = c.POLLIN, .revents = 0 };
        return 3;
    }

    pub fn pollReady(self: *App, fds: []const c.struct_pollfd) void {
        if (self.session) |session| {
            if (fds.len >= 3) tc.ft_io(session, fds[0].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0, fds[0].revents & c.POLLOUT != 0, fds[1].revents != 0, fds[2].revents != 0);
            if (tc.ft_changed(session)) self.dirty = true;
            self.refreshTitle();
            if (tc.ft_exited(session)) self.quit();
        }
        self.finishClose(nowMs());
    }

    pub fn timeoutMs(self: *App, now: i64) ?i64 {
        return if (self.hangup_at) |at| @max(0, at - now) else null;
    }

    pub const handleKey = @import("input.zig").handleKey;
    pub const keyRepeats = @import("input.zig").keyRepeats;
    pub const handleMotion = @import("input.zig").handleMotion;
    pub const handleButton = @import("input.zig").handleButton;
    pub const handleAxis = @import("input.zig").handleAxis;
    pub const cancelDrag = @import("input.zig").cancelDrag;

    pub fn cursorName(_: *App) [*:0]const u8 {
        return "text";
    }

    pub fn copySelection(self: *App) void {
        const session = self.session orelse return;
        const selection = self.selection orelse return;
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
        const session = self.session orelse return;
        if (!tc.ft_running(session)) return;
        // Bracketed paste; control bytes and ESC are dropped by the engine.
        _ = tc.ft_paste(session, bytes.ptr, bytes.len);
        self.selection = null;
        self.dirty = true;
    }

    pub fn render(self: *App, cr: *c.cairo_t) void {
        self.layout();
        if (self.session) |session| if (self.focused != self.reported_focus) {
            self.reported_focus = self.focused;
            tc.ft_focus(session, self.focused);
        };
        shell.setSource(cr, paint.background());
        c.cairo_rectangle(cr, 0, 0, @floatFromInt(self.w), @floatFromInt(self.h));
        c.cairo_fill(cr);
        if (self.session) |session| {
            const m = self.metrics;
            paint.paintCells(cr, session, .{
                .x = pad,
                .y = pad,
                .w = @as(f64, @floatFromInt(tc.ft_cols(session))) * m.cell_w,
                .h = @as(f64, @floatFromInt(tc.ft_rows(session))) * m.cell_h,
                .metrics = m,
                .selection = self.selection,
                .focused = self.focused,
                .hollow_cursor = true,
            });
        }
        const message = self.failure orelse if (self.session) |session| if (tc.ft_error(session)) |text| std.mem.span(text) else null else null;
        if (message) |text| {
            shell.setSource(cr, ui.theme.global.window_fg);
            shell.drawText(cr, text, pad + 8, pad + 8 + shell.textSize(), shell.textSize(), true);
        }
    }

    /// The grid position under a surface point, clamped into the grid.
    pub fn pointAt(self: *App, x: f64, y: f64) model.Point {
        const session = self.session.?;
        const row = std.math.clamp(@floor((y - pad) / self.metrics.cell_h), 0, @as(f64, @floatFromInt(tc.ft_rows(session) - 1)));
        const col = std.math.clamp(@floor((x - pad) / self.metrics.cell_w), 0, @as(f64, @floatFromInt(tc.ft_cols(session))));
        return .{ .line = tc.ft_line(session) - tc.ft_offset(session) + @as(i32, @intFromFloat(row)), .col = @intFromFloat(col) };
    }
};
