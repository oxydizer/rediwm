//! The Files drawer around the shared terminal painter (`paint.zig`).
const std = @import("std");
const ui = @import("ui");
const theme = ui.theme;
const shell = ui.cairo;
const c = @import("../c.zig").api;
const tc = @import("model.zig").c;
const paint = @import("paint.zig");
const App = @import("../app.zig").App;
const draw = @import("../app_draw.zig");
const button = ui.widgets.button;

pub const applyPalette = paint.applyPalette;
fn control(self: *App, cr: *c.cairo_t, index: usize, icon: ?ui.layout.IconId, label: []const u8) void {
    const rect = self.terminalControl(index);
    var layer = shell.Layer.begin(cr, .{ .x = @floatCast(rect.x), .y = @floatCast(rect.y), .w = @floatCast(rect.w), .h = @floatCast(rect.h) }) orelse return;
    button.paint(&layer.renderer, layer.local(), .{ .variant = .ghost, .icon = icon, .label = label, .icon_scale = 0.65 }, .{ .pointer = if (self.dialog == null and self.menu == null and rect.contains(self.mouse_x, self.mouse_y)) .hover else .idle, .selected = index == 0 and self.terminal.visible });
    layer.finish();
}
pub fn render(self: *App, cr: *c.cairo_t) void {
    if (self.chooser != null) return;
    control(self, cr, 0, .terminal, "Terminal · F4");
    const rect = self.terminalRect();
    if (rect.h > 0) {
        c.cairo_save(cr);
        c.cairo_rectangle(cr, rect.x, rect.y, rect.w, rect.h);
        c.cairo_clip(cr);
        shell.setSource(cr, theme.global.terminal_bg orelse theme.global.app_bg);
        c.cairo_paint(cr);
        shell.setSource(cr, theme.global.app_bar);
        c.cairo_rectangle(cr, rect.x, rect.y, rect.w, 32);
        c.cairo_fill(cr);
        var status_buf: [4608]u8 = undefined;
        const message = terminalLabel(self, &status_buf);
        if (shell.Layer.begin(cr, .{ .x = @floatCast(rect.x + 12), .y = @floatCast(rect.y + 8), .w = 16, .h = 16 })) |value| {
            var layer = value;
            layer.renderer.drawIcon(0, 0, 16, 16, .{ .id = .terminal, .color = theme.global.window_fg });
            layer.finish();
        }
        shell.setSource(cr, theme.global.window_fg);
        draw.drawEllipsis(cr, message, rect.x + 38, rect.y + 22, @max(0, rect.w - if (self.terminalRestartable()) @as(f64, 200) else 110), shell.statusSize(), false);
        control(self, cr, 1, .chevron_down, "Hide terminal");
        control(self, cr, 2, .open, "Open external terminal");
        if (self.terminalRestartable()) control(self, cr, 3, null, "Restart");
        if (self.terminal.session) |session| paintCells(self, cr, session);
        c.cairo_restore(cr);
        if (self.terminalDivider()) |divider| shell.drawSplitter(cr, divider, self.terminal.resize != null or self.overTerminalDivider(self.mouse_x, self.mouse_y));
    }
    if (self.dialog == null and self.menu == null) if (self.terminalHit(self.mouse_x, self.mouse_y)) |index| {
        const label: []const u8 = switch (index) {
            0 => "Terminal · F4",
            1 => "Hide terminal · F4",
            2 => "Open external terminal",
            else => "Restart terminal",
        };
        const w = shell.measureText(cr, label, shell.statusSize(), false) + 16;
        const control_rect = self.terminalControl(index);
        const x = @max(4, @min(control_rect.x, @as(f64, @floatFromInt(self.w)) - w - 4));
        const y = @max(4, control_rect.y - 28);
        draw.roundedRect(cr, x, y, w, 24, 4);
        shell.setSource(cr, theme.global.app_divider);
        c.cairo_fill(cr);
        shell.setSource(cr, theme.global.window_fg);
        shell.drawText(cr, label, x + 8, y + 17, shell.statusSize(), false);
    };
}
pub fn terminalLabel(self: *App, buffer: []u8) []const u8 {
    if (self.terminal.error_message) |message| return message;
    const s = self.terminal.session orelse return "Terminal";
    if (tc.ft_error(s)) |message| return std.mem.span(message);
    if (tc.ft_exited(s)) return std.fmt.bufPrint(buffer, "Terminal · Exited ({d})", .{tc.ft_exit_status(s)}) catch "Terminal exited";
    const status = tc.ft_status(s).*;
    const known = std.mem.sliceTo(&status.path, 0);
    const path = if (known.len > 0) known else self.terminal.directory orelse self.home_dir;
    // Paths may contain literal newlines/control bytes, but the header is one line.
    var clean: [4096]u8 = undefined;
    const len = @min(path.len, clean.len);
    for (path[0..len], clean[0..len]) |ch, *out| out.* = if (ch < 32 or ch == 127) ' ' else ch;
    const label = if (std.unicode.utf8ValidateSlice(clean[0..len])) clean[0..len] else "Directory";
    const suffix: []const u8 = if (tc.ft_channel(s) < 0) " · Following unavailable" else if (status.magic == 0) " · Starting…" else if (status.flags & tc.FT_ERROR != 0) " · Folder unavailable" else if (tc.ft_pending(s)) " · Following pending" else "";
    return std.fmt.bufPrint(buffer, "Terminal · {s}{s}", .{ label, suffix }) catch "Terminal";
}
fn paintCells(self: *App, cr: *c.cairo_t, session: *tc.FT) void {
    const body = self.terminalBody();
    if (body.h <= 0 or body.w <= 0) return;
    const drawer = &self.terminal;
    paint.paintCells(cr, session, .{
        .x = body.x,
        .y = body.y,
        .w = body.w,
        .h = body.h,
        .metrics = .{ .cell_w = drawer.cell_w, .cell_h = drawer.cell_h, .ascent = drawer.ascent },
        .selection = drawer.selection,
        .focused = drawer.focused,
        .preedit = drawer.preedit.items,
    });
    if (self.terminalScrollbar()) |bar| shell.drawScrollbar(cr, ui.widgets.scrollbar.look(bar, drawer.bar, self.scrollbar_width, theme.shellPalette()));
}
