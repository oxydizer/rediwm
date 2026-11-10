//! Responsive system readouts; process actions remain persistent shared widgets.
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const ui = @import("ui");
const cairo = ui.cairo;
const theme = ui.theme;
const c = @import("../files/c.zig").api;
const app = @import("app.zig");
const App = app.App;
const Rect = cairo.Rect;
const proc = @import("proc.zig");

fn wide(self: *const App) bool {
    return self.w >= 1200;
}
fn columns(self: *const App) usize {
    return if (self.w < 900) 3 else 6;
}
fn metricHeight(self: *const App) f32 {
    return if (wide(self)) 82 else if (columns(self) == 3) 62 else 70;
}
pub fn height(self: *const App) f32 {
    return metricHeight(self) * @as(f32, @floatFromInt(6 / columns(self))) + (if (wide(self)) @as(f32, 16) else 62);
}
fn frame(self: *const App) Rect {
    return .{ .x = 16, .y = self.sections[4].computed_y + 8, .w = @floatFromInt(self.w - 32), .h = height(self) - 16 };
}
pub fn layout(self: *App) void {
    const box = frame(self);
    const y = if (wide(self)) box.y + (box.h - 38) / 2 else box.y + box.h - 44;
    const width: f32 = if (wide(self)) 140 else 124;
    for (self.footer[1..], 0..) |*control, index| {
        const x = box.x + box.w - 12 - (width + 10) * @as(f32, @floatFromInt(2 - index)) + 10;
        ui.measure.measure(control, width, 38);
        ui.arrange.arrange(control, x, y, width, 38);
    }
}

pub fn paint(self: *App, cr: *c.cairo_t) void {
    const box = frame(self);
    if (cairo.Layer.begin(cr, box)) |value| {
        var layer = value;
        layer.renderer.fillRect(0.5, 0.5, box.w - 1, box.h - 1, .{
            .color = theme.global.app_bar,
            .radius = theme.global.radius_md,
            .border_width = 1,
            .border_color = theme.global.app_divider,
        });
        layer.finish();
    }
    const count = columns(self);
    const available = box.w - (if (wide(self)) @as(f32, 316) else 0);
    const cell_w = available / @as(f32, @floatFromInt(count));
    for (0..6) |index| {
        const cell: Rect = .{
            .x = box.x + @as(f32, @floatFromInt(index % count)) * cell_w,
            .y = box.y + @as(f32, @floatFromInt(index / count)) * metricHeight(self),
            .w = cell_w,
            .h = metricHeight(self),
        };
        if (index % count > 0) rule(cr, cell.x, cell.y + 14, 1, cell.h - 28);
        paintMetric(self, cr, index, cell);
    }
    if (wide(self)) {
        rule(cr, box.x + available, box.y + 14, 1, box.h - 28);
    } else {
        rule(cr, box.x + 12, box.y + box.h - 48, box.w - 24, 1);
        if (count == 3) rule(cr, box.x + 12, box.y + metricHeight(self), box.w - 24, 1);
    }
}

fn paintMetric(self: *App, cr: *c.cairo_t, index: usize, cell: Rect) void {
    const snap = self.model.snapshot;
    const system: proc.System = if (snap) |s| s.system else .{};
    const labels = [_][]const u8{ tr("CPU"), tr("RAM"), tr("SWAP"), tr("NET"), tr("UPTIME"), tr("TEMP") };
    const colors = [_][4]f32{
        theme.global.danger,                                      theme.global.danger,    theme.global.app_git_added,
        theme.global.terminal_cyan orelse .{ 0.2, 0.78, 0.9, 1 }, theme.global.window_fg, theme.global.terminal_yellow orelse .{ 0.96, 0.75, 0.35, 1 },
    };
    var content: Rect = .{ .x = cell.x + 14, .y = cell.y + (cell.h - 48) / 2, .w = cell.w - 28, .h = 20 };
    if ((cell.w >= 190 and index == 0) or (cell.w >= 140 and index == 4)) {
        if (cairo.Layer.begin(cr, .{ .x = content.x, .y = cell.y + (cell.h - 26) / 2, .w = 26, .h = 26 })) |value| {
            var layer = value;
            layer.renderer.drawIcon(0, 0, 26, 26, .{ .id = if (index == 0) .power_performance else .clock, .color = colors[index] });
            layer.finish();
        }
        content.x += 36;
        content.w -= 36;
    }
    var title_box = content;
    if (index == 1 or index == 2) title_box.w = @max(0, title_box.w - 54);
    app.textBox(cr, labels[index], title_box, cairo.statusSize(), true, if (index == 0) colors[index] else theme.global.window_fg);
    var buf: [128]u8 = undefined;
    content.y += 22;
    content.h = 26;
    switch (index) {
        0 => {
            var count_buf: [48]u8 = undefined;
            const cpus = if (system.logical_cpus) |n| i18n.fmt(&count_buf, i18n.trn("{n} CPU", "{n} CPUs", n), .{ .n = n }) catch "—" else "—";
            const value = if (system.frequency_ghz) |ghz| std.fmt.bufPrint(&buf, "{s}  {d:.1} GHz", .{ cpus, ghz }) catch "—" else cpus;
            app.textBox(cr, value, content, cairo.textSize(), false, theme.global.window_fg);
        },
        1, 2 => {
            const mem = if (snap) |s| s.memory else null;
            const total: ?u64 = if (mem) |m| if (index == 1) m.total else m.swap_total else null;
            const used: ?u64 = if (mem) |m| if (index == 1) m.used() else if (m.swap_total != null and m.swap_free != null) m.swap_total.? -| m.swap_free.? else null else null;
            memory(cr, content, used, total, colors[index]);
        },
        3 => {
            const rate = if (snap) |s| s.network_rate else null;
            content.y -= 4;
            content.h = 18;
            app.textBox(cr, rateLabel(&buf, "↑", if (rate) |r| r.sent else null), content, cairo.statusSize(), false, colors[index]);
            content.y += 17;
            app.textBox(cr, rateLabel(&buf, "↓", if (rate) |r| r.received else null), content, cairo.statusSize(), false, theme.global.window_fg);
        },
        4 => {
            const value = if (system.uptime_seconds) |seconds| i18n.fmt(&buf, tr("{hours}h {minutes}m"), .{ .hours = seconds / 3600, .minutes = seconds / 60 % 60 }) catch "—" else "—";
            app.textBox(cr, value, content, cairo.textSize(), false, theme.global.window_fg);
        },
        5 => {
            content.y -= 4;
            content.h = 18;
            app.textBox(cr, temperatureLabel(&buf, tr("CPU"), system.temperature_c), content, cairo.statusSize(), false, colors[index]);
            content.y += 17;
            app.textBox(cr, temperatureLabel(&buf, tr("GPU"), system.gpu_temperature_c), content, cairo.statusSize(), false, colors[index]);
        },
        else => unreachable,
    }
}

fn temperatureLabel(buf: []u8, label: []const u8, temperature: ?f64) []const u8 {
    return if (temperature) |value|
        std.fmt.bufPrint(buf, "{s}  {d:.0}°C", .{ label, value }) catch "—"
    else
        std.fmt.bufPrint(buf, "{s}  —", .{label}) catch "—";
}

fn memory(cr: *c.cairo_t, content: Rect, used: ?u64, total: ?u64, color: [4]f32) void {
    if (used == null or total == null) return app.textBox(cr, "—", content, cairo.textSize(), false, theme.global.window_fg);
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var unit: usize = 0;
    var divisor: f64 = 1;
    while (@as(f64, @floatFromInt(total.?)) / divisor >= 1024 and unit + 1 < units.len) : (unit += 1) divisor *= 1024;
    var buf: [64]u8 = undefined;
    const value = std.fmt.bufPrint(&buf, "{d:.1}", .{@as(f64, @floatFromInt(used.?)) / divisor}) catch "—";
    app.textBox(cr, value, content, cairo.textSize(), false, color);
    var tail = content;
    const advance: f32 = @floatCast(cairo.measureText(cr, value, cairo.textSize(), false));
    tail.x += advance;
    tail.w = @max(0, tail.w - advance);
    const suffix = std.fmt.bufPrint(&buf, " / {d:.1} {s}", .{ @as(f64, @floatFromInt(total.?)) / divisor, units[unit] }) catch "—";
    app.textBox(cr, suffix, tail, cairo.textSize(), false, theme.global.window_fg);
    const percentage = if (total.? == 0) 0 else @as(f64, @floatFromInt(used.?)) * 100 / @as(f64, @floatFromInt(total.?));
    const percent = std.fmt.bufPrint(&buf, "{d:.1}%", .{percentage}) catch "—";
    const width: f32 = @floatCast(cairo.measureText(cr, percent, cairo.statusSize(), false));
    // Put the percentage beside the title so both values fit at normal widths.
    app.textBox(cr, percent, .{ .x = content.x + content.w - width, .y = content.y - 22, .w = width + 1, .h = 20 }, cairo.statusSize(), false, theme.global.window_fg);
}

fn rateLabel(buf: []u8, arrow: []const u8, rate: ?f64) []const u8 {
    const value = rate orelse return std.fmt.bufPrint(buf, "{s} —", .{arrow}) catch "—";
    var size_buf: [32]u8 = undefined;
    const bytes: u64 = @intFromFloat(@min(@as(f64, @floatFromInt(std.math.maxInt(u64) - 4096)), @max(0, value)));
    return std.fmt.bufPrint(buf, "{s} {s}/s", .{ arrow, app.bytesLabel(&size_buf, bytes) }) catch "—";
}

pub fn paintStatus(self: *App, cr: *c.cairo_t) void {
    const box = frame(self);
    var buf: [256]u8 = undefined;
    const status = if (self.notice.len > 0) self.notice else blk: {
        const snap = self.model.snapshot orelse break :blk tr("Collecting processes…");
        break :blk i18n.fmt(&buf, i18n.trn("{n} process{status}", "{n} processes{status}", self.model.rows.items.len), .{
            .n = self.model.rows.items.len,
            .status = if (self.paused) tr(" · Paused") else if (snap.failed) tr(" · Process data unavailable") else if (snap.truncated) tr(" · List limited") else if (snap.unavailable > 0) tr(" · Some processes unavailable") else "",
        }) catch tr("Processes");
    };
    const status_box: Rect = if (wide(self)) .{ .x = 16, .y = @floatFromInt(self.h - 26), .w = @floatFromInt(self.w - 32), .h = 24 } else .{ .x = box.x + 14, .y = box.y + box.h - 44, .w = @max(0, self.footer[1].computed_x - box.x - 28), .h = 38 };
    app.textBox(cr, status, status_box, cairo.statusSize(), false, theme.global.window_fg);
    if (!wide(self)) app.textBox(cr, tr("CPU: 100% = one core · Memory: resident · Ctrl+F search · Delete end · Shift+Delete force quit"), .{ .x = 16, .y = @floatFromInt(self.h - 26), .w = @floatFromInt(self.w - 32), .h = 24 }, cairo.statusSize(), false, theme.global.window_fg);
}

fn rule(cr: *c.cairo_t, x: f32, y: f32, w: f32, h: f32) void {
    cairo.setSource(cr, theme.global.app_divider);
    c.cairo_rectangle(cr, x, y, w, h);
    c.cairo_fill(cr);
}
