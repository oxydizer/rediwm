//! Files terminal controller. All terminal state stays in this client process.
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const model = @import("terminal/model.zig");
const tc = model.c;
const c = @import("c.zig").api;
const platform = @import("platform");
const ui = @import("ui");
const Rect = @import("header.zig").Rect;
const scrollbar = ui.widgets.scrollbar;
const splitter = ui.widgets.splitter;
const nowMs = @import("app_draw.zig").nowMs;
pub const Drawer = model.Drawer;
pub const header_height = 32;

pub fn terminalHeight(self: *App) i32 {
    if (self.chooser != null) return 0;
    return @min(self.terminal.pixels, terminalMaximum(self));
}
pub fn terminalMaximum(self: *App) i32 {
    const available = @max(0, self.h - self.footerHeight() - self.viewTop() - 48);
    // Header, padding and two normal terminal rows. A smaller window keeps
    // the session but gives input and all remaining space back to Files.
    return if (available >= 96) available else 0;
}
pub fn terminalRect(self: *App) Rect {
    const height = self.terminalHeight();
    return .{ .x = @floatFromInt(self.sidebarWidth()), .y = @floatFromInt(self.h - self.footerHeight() - height), .w = @floatFromInt(self.w - self.sidebarWidth()), .h = @floatFromInt(height) };
}
pub fn terminalBody(self: *App) Rect {
    const rect = self.terminalRect();
    return .{ .x = rect.x + 8, .y = rect.y + header_height + 6, .w = @max(0, rect.w - 16 - @as(f64, @floatFromInt(self.scrollbarGutter()))), .h = @max(0, rect.h - header_height - 12) };
}
pub fn terminalDropAt(self: *App, x: f64, y: f64) bool {
    if (self.chooser != null or self.dialog != null or self.menu != null or self.terminal.close_at != null or !self.terminal.visible or self.terminalHeight() <= 0) return false;
    const session = self.terminal.session orelse return false;
    return tc.ft_running(session) and self.terminalBody().contains(x, y);
}

/// Quote each absolute path as one shell word, with a trailing argument gap.
/// Control bytes cannot survive the terminal's paste filtering unchanged.
pub fn quotePaths(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    for (paths) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
        var size: usize = 3;
        for (path) |ch| {
            if (ch < 32 or ch == 127) return error.ControlCharacter;
            size += if (ch == '\'') @as(usize, 4) else 1;
            if (size > @import("transfer.zig").limit) return error.TooLong;
        }
        if (bytes.items.len > @import("transfer.zig").limit - size) return error.TooLong;
        try bytes.append(allocator, '\'');
        for (path) |ch| {
            if (ch == '\'') try bytes.appendSlice(allocator, "'\\''") else try bytes.append(allocator, ch);
        }
        try bytes.appendSlice(allocator, "' ");
    }
    return bytes.toOwnedSlice(allocator);
}

pub fn terminalDropPaths(self: *App, paths: []const []const u8) void {
    if (self.dialog != null or self.menu != null or !self.terminal.visible or self.terminal.close_at != null) return;
    const session = self.terminal.session orelse return;
    if (!tc.ft_running(session)) return;
    const bytes = quotePaths(self.allocator, paths) catch |err| {
        self.setStatusNotice(if (err == error.ControlCharacter) tr("Cannot insert paths containing control characters") else tr("The dropped paths are invalid or too long"), true);
        return;
    };
    defer self.allocator.free(bytes);
    if (!tc.ft_paste(session, bytes.ptr, bytes.len)) self.setStatusNotice(tr("Terminal paste exceeds the available input queue"), true);
    self.terminal.selection = null;
    self.terminalDamage();
}
/// Button indices: status toggle, collapse, external terminal, restart.
pub fn terminalControl(self: *App, index: usize) Rect {
    const rect = self.terminalRect();
    return switch (index) {
        0 => .{ .x = @floatFromInt(self.w - 32), .y = @floatFromInt(self.h - 25), .w = 28, .h = 24 },
        1 => .{ .x = rect.x + rect.w - 30, .y = rect.y + 3, .w = 26, .h = 26 },
        2 => .{ .x = rect.x + rect.w - 62, .y = rect.y + 3, .w = 26, .h = 26 },
        else => .{ .x = rect.x + rect.w - 150, .y = rect.y + 3, .w = 84, .h = 26 },
    };
}
pub fn terminalHit(self: *App, x: f64, y: f64) ?usize {
    if (self.chooser != null) return null;
    if (self.terminalControl(0).contains(x, y)) return 0;
    const rect = self.terminalRect();
    if (rect.h <= 0 or !rect.contains(x, y)) return null;
    for (1..4) |index| {
        if (index == 3 and !terminalRestartable(self)) continue;
        if (self.terminalControl(index).contains(x, y)) return index;
    }
    return null;
}
pub fn terminalRestartable(self: *App) bool {
    return if (self.terminal.session) |s| !tc.ft_running(s) and (tc.ft_exited(s) or tc.ft_error(s) != null) else self.terminal.error_message != null;
}
pub fn terminalDivider(self: *App) ?splitter.Geometry {
    const rect = self.terminalRect();
    if (rect.h <= 0) return null;
    return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 0, .axis = .horizontal };
}
pub fn overTerminalDivider(self: *App, x: f64, y: f64) bool {
    if (self.dialog != null or self.menu != null or !self.terminal.visible) return false;
    return if (self.terminalDivider()) |divider| divider.contains(x, y) else false;
}

fn rememberDirectory(self: *App) void {
    if (self.terminal.navigation == self.navigation_count) return;
    self.terminal.navigation = self.navigation_count;
    if (self.isRecent() or self.history.archive_len != 0) return;
    if (self.trash_dir) |trash| {
        const current = self.history.current;
        if (std.mem.eql(u8, current, trash) or (std.mem.startsWith(u8, current, trash) and current.len > trash.len and current[trash.len] == '/')) return;
    }
    const path_z = self.allocator.dupeSentinel(u8, self.history.current, 0) catch return;
    defer self.allocator.free(path_z);
    var path_buf: [4096]u8 = undefined;
    const real = c.realpath(path_z, &path_buf) orelse return;
    var stat: c.struct_stat = undefined;
    if (c.stat(real, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFDIR) return;
    const resolved = std.mem.span(real);
    if (self.terminal.directory) |old| if (std.mem.eql(u8, old, resolved)) return;
    const owned = self.allocator.dupeSentinel(u8, resolved, 0) catch return;
    if (self.terminal.directory) |old| self.allocator.free(old);
    self.terminal.directory = owned;
    if (self.terminal.session) |session| _ = tc.ft_follow(session, owned);
}

/// Client processes necessarily have WAYLAND_DISPLAY. Only a native login
/// (or an explicit override) places a scope; isolated/nested tests never do.
pub fn terminalScopes(self: *App) bool {
    const policy = @import("../session/launch_policy.zig");
    const flag = self.environ.getPosix("REDIWM_APP_SCOPES");
    if (policy.isTruthy(flag)) return true;
    if (policy.isFalsy(flag)) return false;
    var view = policy.viewFromEnviron(self.environ);
    view.host_display = null;
    return policy.isTruthy(view.login_session) and !policy.isNested(view);
}
pub fn terminalHelper(self: *App, name: []const u8, buffer: []u8) ![:0]u8 {
    _ = self;
    const helper = platform.exe.sibling(buffer, name) orelse return error.NoExecutable;
    return buffer[0..helper.len :0];
}
pub fn terminalStart(self: *App) void {
    if (self.chooser != null or self.terminal.close_at != null) return;
    if (self.terminal.session) |old| {
        if (tc.ft_running(old)) return;
        tc.ft_free(old);
        self.terminal.session = null;
    }
    self.edit_revision += 1;
    self.terminal.error_message = null;
    self.terminal.selection = null;
    const session = tc.ft_new(12, 80) orelse {
        self.terminal.error_message = tr("Could not allocate terminal");
        self.invalidate();
        return;
    };
    self.terminal.session = session;
    self.terminal.generation = std.math.maxInt(u64);
    rememberDirectory(self);
    const directory = self.terminal.directory orelse self.allocator.dupeSentinel(u8, self.home_dir, 0) catch {
        self.terminal.error_message = tr("No terminal directory");
        return;
    };
    defer if (self.terminal.directory == null) self.allocator.free(directory);
    var helper_buf: [4096]u8 = undefined;
    var plugin_buf: [4096]u8 = undefined;
    const helper = self.terminalHelper("rediwm-files-terminal", &helper_buf) catch {
        self.terminal.error_message = tr("Terminal helper is unavailable");
        return;
    };
    const plugin = self.terminalHelper("../lib/rediwm/files-bash.so", &plugin_buf) catch "";
    _ = tc.ft_start(session, helper, plugin, directory, self.terminalScopes());
    self.invalidate();
}
pub fn terminalToggle(self: *App) void {
    if (self.chooser != null or self.dialog != null or self.terminal.close_at != null) return;
    if (!self.terminal.visible and self.terminalMaximum() == 0) {
        self.setStatusNotice(tr("Enlarge this window to show the terminal"), false);
        return;
    }
    self.cancelDrag();
    self.menu = null;
    self.terminal.visible = !self.terminal.visible;
    self.focus = if (self.terminal.visible) .terminal else .file_view;
    self.edit_revision += 1;
    if (self.terminal.visible) {
        if (self.terminal.requested_height == 0) self.terminal.requested_height = @max(100, @divTrunc(self.h - self.footerHeight() - self.contentTop(), 3));
        if (self.terminal.session == null and self.terminal.error_message == null) self.terminalStart();
    }
    self.invalidate();
    self.terminalStep(nowMs());
}

pub fn terminalStep(self: *App, now: i64) void {
    if (self.chooser != null) return;
    rememberDirectory(self);
    const target = if (self.terminal.visible) @min(self.terminal.requested_height, self.terminalMaximum()) else 0;
    if (target == 0 and self.focus == .terminal) self.focus = .file_view;
    if (self.terminal.glide.to != @as(f32, @floatFromInt(target))) self.terminal.glide.retargetTo(now, @floatFromInt(target), ui.anim.curveFor(.panel_slide));
    const pixels: i32 = if (self.terminal.glide.settled(now)) target else @intFromFloat(@round(self.terminal.glide.value(now)));
    if (pixels != self.terminal.pixels) {
        self.terminal.pixels = pixels;
        self.clampScroll();
        self.invalidate();
    }
    self.terminal.active = !self.terminal.glide.settled(now);
    if (self.terminal.session) |session| {
        const size = ui.cairo.textSize();
        const scale: f32 = @floatFromInt(self.scale);
        self.terminal.cell_w = @max(1, ui.text.measureWidthF("M", .mono, size, scale) catch 9);
        const metrics = ui.text.verticalMetrics(.mono, size, scale) catch null;
        self.terminal.ascent = if (metrics) |m| m.ascent else size;
        self.terminal.cell_h = @ceil(if (metrics) |m| m.ascent + m.descent + 2 else size + 5);
        const body = self.terminalBody();
        // During a slide, use the final height and clip to the moving boundary;
        // no intermediate 0-row PTYs and no sequence of reflowing prompts.
        const final_height: f64 = @floatFromInt(@max(self.terminalHeight(), target));
        const rows: i32 = @intFromFloat(@floor(@max(0, final_height - header_height - 12) / self.terminal.cell_h));
        const cols: i32 = @intFromFloat(@floor(body.w / self.terminal.cell_w));
        if (self.terminal.visible and rows > 0 and cols >= 2) {
            const old_cols = tc.ft_cols(session);
            tc.ft_resize(session, @min(512, rows), @min(512, cols));
            if (old_cols != tc.ft_cols(session)) self.terminal.selection = null;
        }
        const focused = self.terminal.visible and self.focus == .terminal and self.dialog == null and self.menu == null and self.terminal.window_focused;
        if (focused != self.terminal.focused) {
            self.terminal.focused = focused;
            tc.ft_focus(session, focused);
        }
        if (self.terminal.generation != self.theme_cfg.generation) {
            @import("terminal/render.zig").applyPalette(session);
            self.terminal.generation = self.theme_cfg.generation;
        }
        const bar = self.terminalScrollbar();
        const hovered = if (bar) |b| self.dialog == null and b.overThumb(@floatCast(self.mouse_x), @floatCast(self.mouse_y)) else false;
        if (self.terminal.bar.step(now, self.terminal.observed_offset != tc.ft_offset(session), hovered, self.terminal.scroll_drag.active, self.terminal.visible and bar != null)) self.terminalDamage();
        self.terminal.observed_offset = tc.ft_offset(session);
        if (tc.ft_changed(session)) self.terminalDamage();
    }
}
pub fn terminalDamage(self: *App) void {
    if (self.terminalHeight() > 0) {
        var rect = self.terminalRect();
        // The shared splitter paints just above the drawer's boundary.
        rect.y -= 2;
        rect.h += 2;
        self.addDamage(rect);
    }
}
pub fn terminalScrollbar(self: *App) ?scrollbar.Geometry {
    const session = self.terminal.session orelse return null;
    const body = self.terminalBody();
    if (body.h <= 0) return null;
    return scrollbar.Geometry.compute(.vertical, .{ .x = @floatCast(body.x + body.w + 4), .y = @floatCast(body.y), .w = @floatFromInt(self.scrollbarGutter()), .h = @floatCast(body.h) }, @floatFromInt(tc.ft_rows(session)), @floatFromInt(tc.ft_rows(session) + tc.ft_history(session)), @floatFromInt(tc.ft_history(session) - tc.ft_offset(session)));
}
pub fn terminalKey(self: *App, sym: u32, utf8: []const u8) void {
    // Modifier presses carry no terminal input. In particular, Ctrl+Shift
    // must preserve the selection until the following copy key arrives.
    switch (sym) {
        c.XKB_KEY_Shift_L,
        c.XKB_KEY_Shift_R,
        c.XKB_KEY_Control_L,
        c.XKB_KEY_Control_R,
        c.XKB_KEY_Alt_L,
        c.XKB_KEY_Alt_R,
        c.XKB_KEY_Meta_L,
        c.XKB_KEY_Meta_R,
        c.XKB_KEY_Super_L,
        c.XKB_KEY_Super_R,
        c.XKB_KEY_Hyper_L,
        c.XKB_KEY_Hyper_R,
        c.XKB_KEY_Caps_Lock,
        c.XKB_KEY_Num_Lock,
        c.XKB_KEY_Scroll_Lock,
        c.XKB_KEY_ISO_Level3_Shift,
        c.XKB_KEY_ISO_Level5_Shift,
        c.XKB_KEY_Mode_switch,
        => return,
        else => {},
    }
    const session = self.terminal.session orelse return;
    if (self.ctrl and self.shift and (sym == c.XKB_KEY_c or sym == c.XKB_KEY_C)) {
        terminalCopy(self);
    } else if (self.ctrl and self.shift and (sym == c.XKB_KEY_v or sym == c.XKB_KEY_V)) {
        self.text_paste_requested = true;
    } else if (self.shift and (sym == c.XKB_KEY_Page_Up or sym == c.XKB_KEY_Page_Down)) {
        tc.ft_scroll(session, (if (sym == c.XKB_KEY_Page_Up) @as(i32, 1) else -1) * @max(1, tc.ft_rows(session) - 1));
    } else {
        self.terminal.selection = null;
        tc.ft_key(session, sym, utf8.ptr, utf8.len, terminalModifiers(self));
    }
    self.terminalDamage();
}
pub fn terminalModifiers(self: *App) c_int {
    return @as(c_int, if (self.shift) 1 else 0) | @as(c_int, if (self.alt) 2 else 0) | @as(c_int, if (self.ctrl) 4 else 0);
}
pub fn terminalCopy(self: *App) void {
    const session = self.terminal.session orelse return;
    const selection = self.terminal.selection orelse return;
    const ends = selection.ordered();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(self.allocator);
    var line = @max(ends[0].line, tc.ft_line(session) - tc.ft_history(session));
    const last_line = @min(ends[1].line, tc.ft_line(session) + tc.ft_rows(session) - 1);
    while (line <= last_line) : (line += 1) {
        const start = if (line == ends[0].line) ends[0].col else 0;
        const end = if (line == ends[1].line) ends[1].col else tc.ft_cols(session);
        const begin = bytes.items.len;
        var col = start;
        while (col < end) : (col += 1) {
            var cell: tc.FT_Cell = undefined;
            if (!tc.ft_cell_at(session, line, col, &cell) or cell.width == 0) continue;
            if (cell.chars[0] == 0) bytes.append(self.allocator, ' ') catch return else for (cell.chars) |ch| {
                if (ch == 0 or ch == std.math.maxInt(u32)) break;
                var encoded: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(ch), &encoded) catch continue;
                bytes.appendSlice(self.allocator, encoded[0..len]) catch return;
            }
            if (bytes.items.len > 1024 * 1024 - 32) return;
        }
        if (!tc.ft_wrapped_at(session, line)) {
            while (bytes.items.len > begin and bytes.items[bytes.items.len - 1] == ' ') _ = bytes.pop();
            if (line < last_line) bytes.append(self.allocator, '\n') catch return;
        }
    }
    self.clipboard_text.clearRetainingCapacity();
    self.clipboard_text.appendSlice(self.allocator, bytes.items) catch return;
    self.clearClipboard();
    self.clipboard_cut = false;
    self.clipboard_is_text = true;
    self.clipboard_revision += 1;
}

fn pointAt(self: *App, x: f64, y: f64) model.Point {
    const session = self.terminal.session.?;
    const body = self.terminalBody();
    return .{ .line = tc.ft_line(session) - tc.ft_offset(session) + @as(i32, @intFromFloat(std.math.clamp(@floor((y - body.y) / self.terminal.cell_h), 0, @as(f64, @floatFromInt(tc.ft_rows(session) - 1))))), .col = @intFromFloat(std.math.clamp(@floor((x - body.x) / self.terminal.cell_w), 0, @as(f64, @floatFromInt(tc.ft_cols(session))))) };
}
pub fn terminalMotion(self: *App, x: f64, y: f64) bool {
    if (self.dialog != null or self.menu != null) return false;
    if (self.terminal.resize) |drag| {
        self.terminal.requested_height = drag.heightAt(y, @min(96, self.terminalMaximum()), self.terminalMaximum());
        self.terminal.pixels = self.terminal.requested_height;
        self.terminal.glide.cancel(@floatFromInt(self.terminal.pixels));
        self.clampScroll();
        self.invalidate();
        return true;
    }
    const session = self.terminal.session orelse return false;
    if (self.terminal.scroll_drag.active) {
        if (self.terminalScrollbar()) |bar| {
            const offset: i32 = @intFromFloat(@round(self.terminal.scroll_drag.offsetAt(bar, @floatCast(x), @floatCast(y))));
            tc.ft_scroll(session, tc.ft_history(session) - offset - tc.ft_offset(session));
        }
        self.terminalDamage();
        return true;
    }
    if (self.terminal.selecting) {
        if (self.terminal.selection) |*selection| selection.end = pointAt(self, x, y);
        self.terminalDamage();
        return true;
    }
    if (self.terminal.mouse_buttons != 0 or (self.terminalHeight() > 0 and self.terminalBody().contains(x, y) and !self.shift and tc.ft_mouse_mode(session) != 0)) {
        const p = pointAt(self, x, y);
        tc.ft_mouse(session, @intCast(p.line - tc.ft_line(session) + tc.ft_offset(session)), p.col, 0, false, self.terminalModifiers());
        if (self.terminal.mouse_buttons != 0) return true;
    }
    return false;
}
pub fn terminalButton(self: *App, button: u32, pressed: bool) bool {
    if (self.chooser != null or self.dialog != null or self.menu != null) return false;
    const x = self.mouse_x;
    const y = self.mouse_y;
    const mouse_button: c_int = switch (button) {
        0x110 => 1,
        0x112 => 2,
        0x111 => 3,
        else => 0,
    };
    const mouse_bit: u8 = if (mouse_button > 0) @as(u8, 1) << @intCast(mouse_button - 1) else 0;
    if (!pressed and self.terminal.mouse_buttons & mouse_bit != 0) {
        if (self.terminal.session) |session| {
            const p = pointAt(self, x, y);
            tc.ft_mouse(session, @intCast(p.line - tc.ft_line(session) + tc.ft_offset(session)), p.col, mouse_button, false, self.terminalModifiers());
        }
        self.terminal.mouse_buttons &= ~mouse_bit;
        return true;
    }
    if (!pressed and (self.terminal.resize != null or self.terminal.selecting or self.terminal.scroll_drag.active)) {
        if (self.terminal.resize != null) self.savePreferences();
        self.terminal.resize = null;
        self.terminal.selecting = false;
        self.terminal.scroll_drag.end();
        self.terminalDamage();
        return true;
    }
    if (button == 0x110 and pressed) {
        if (self.terminalHit(x, y)) |index| {
            self.edit_revision += 1;
            switch (index) {
                0, 1 => self.terminalToggle(),
                2 => self.terminalExternal(),
                else => self.terminalStart(),
            }
            return true;
        }
        if (self.overTerminalDivider(x, y)) {
            self.terminal.resize = .{ .origin = y, .width = self.terminalHeight() };
            return true;
        }
    }
    if (self.terminalHeight() <= 0 or !self.terminalRect().contains(x, y)) return false;
    if (pressed) {
        self.focus = .terminal;
        self.edit_revision += 1;
        self.terminalDamage();
    }
    const session = self.terminal.session orelse return true;
    if (!self.terminalBody().contains(x, y) and !self.terminal.selecting) {
        if (self.terminalScrollbar()) |bar| {
            if (pressed and button == 0x110) if (scrollbar.press(bar, @floatCast(x), @floatCast(y), @floatFromInt(tc.ft_history(session) - tc.ft_offset(session)))) |action| switch (action) {
                .grab => self.terminal.scroll_drag.begin(bar, @floatCast(x), @floatCast(y), @floatFromInt(tc.ft_history(session) - tc.ft_offset(session))),
                .page => |offset| tc.ft_scroll(session, tc.ft_history(session) - @as(i32, @intFromFloat(@round(offset))) - tc.ft_offset(session)),
            };
        }
        return true;
    }
    const p = pointAt(self, x, y);
    if (!self.shift and tc.ft_mouse_mode(session) != 0) {
        tc.ft_mouse(session, @intCast(p.line - tc.ft_line(session) + tc.ft_offset(session)), p.col, mouse_button, pressed, self.terminalModifiers());
        if (pressed) self.terminal.mouse_buttons |= mouse_bit;
    } else if (button == 0x110 and pressed) {
        self.terminal.selection = .{ .anchor = p, .end = p };
        self.terminal.selecting = true;
    }
    return true;
}
pub fn terminalCancelPointer(self: *App) void {
    if (self.terminal.mouse_buttons != 0) if (self.terminal.session) |session| {
        const p = pointAt(self, self.mouse_x, self.mouse_y);
        for (0..3) |index| {
            if (self.terminal.mouse_buttons & (@as(u8, 1) << @intCast(index)) != 0) tc.ft_mouse(session, @intCast(p.line - tc.ft_line(session) + tc.ft_offset(session)), p.col, @intCast(index + 1), false, self.terminalModifiers());
        }
    };
    self.terminal.mouse_buttons = 0;
}
pub fn terminalWheel(self: *App, delta: f64) bool {
    if (self.dialog != null or self.menu != null or self.terminalHeight() <= 0 or !self.terminalRect().contains(self.mouse_x, self.mouse_y)) return false;
    if (self.terminal.session) |session| {
        const lines: i32 = @intFromFloat(@max(1, @ceil(@abs(delta) / 33)));
        if (!self.shift and tc.ft_mouse_mode(session) != 0) {
            const p = pointAt(self, self.mouse_x, self.mouse_y);
            for (0..@intCast(@min(lines, 16))) |_| tc.ft_mouse(session, @intCast(p.line - tc.ft_line(session) + tc.ft_offset(session)), p.col, if (delta < 0) 4 else 5, true, self.terminalModifiers());
        } else tc.ft_scroll(session, if (delta < 0) lines else -lines);
        self.terminalDamage();
    }
    return true;
}
pub fn terminalRequestClose(self: *App) void {
    if (self.terminal.close_at != null) return;
    if (self.terminal.session) |session| if (tc.ft_running(session)) {
        if (self.dialog != null) return;
        // Asked of the kernel now, not of the integration snapshot, which
        // cannot prove that no job began since it arrived. Hidden and
        // unintegrated shells count; an idle shell is just hung up.
        if (!tc.ft_active(session)) return self.terminalConfirmClose();
        self.dialog = .{ .kind = .terminal_close, .title = tr("Close terminal session?") };
        self.invalidate();
        return;
    };
    self.closed = true;
}
pub fn terminalConfirmClose(self: *App) void {
    self.closeDialog();
    if (self.terminal.session) |session| if (tc.ft_running(session)) {
        tc.ft_close(session, false);
        self.terminal.close_at = nowMs() + 750;
        return;
    };
    self.closed = true;
}
pub fn terminalFinishClose(self: *App, now: i64) void {
    const at = self.terminal.close_at orelse return;
    if (self.terminal.session) |session| {
        if (tc.ft_running(session) and now < at) return;
        if (tc.ft_running(session) and !self.terminal.close_forced) {
            tc.ft_close(session, true);
            self.terminal.close_forced = true;
            self.terminal.close_at = now + 750;
            return;
        }
    }
    self.closed = true;
}
pub fn terminalExternal(self: *App) void {
    @import("terminal/external.zig").launch(self) catch self.setStatusNotice("Could not open external terminal", true);
}
pub const renderTerminal = @import("terminal/render.zig").render;
