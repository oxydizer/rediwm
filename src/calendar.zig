// Local-time calendar opened by the taskbar clock. Repaint only on interaction,
// output geometry changes, or the taskbar's existing minute tick.
const std = @import("std");
const wlr = @import("wlroots");
const c = @cImport({
    @cInclude("time.h");
});
const Output = @import("Output.zig");
const gpa = @import("main.zig").gpa;
const PanelBuffer = @import("panel_buffer.zig").PanelBuffer;
const scene = @import("scene_data.zig");
const paint = @import("ui").paint;
const theme = @import("ui").theme;
const anim = @import("ui").anim;
const panel_present = @import("panel_present.zig");
const Anim = anim.Anim;
const slide_distance: f32 = 20;

pub const Calendar = struct {
    output: *Output,
    buffer_node: *wlr.SceneBuffer,
    node_data: scene.SceneData = undefined,
    year: i32,
    month: i32,
    factor: f32 = 1,
    slide: Anim = .{},
    panel_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    pub fn create(output: *Output) !*Calendar {
        const self = try gpa.create(Calendar);
        errdefer gpa.destroy(self);
        const node = try output.server.overlay_tree.createSceneBuffer(null);
        const tm = localNow();
        self.* = .{ .output = output, .buffer_node = node, .year = tm.tm_year + 1900, .month = tm.tm_mon + 1 };
        self.node_data = .{ .role = .{ .calendar = self } };
        self.slide.retargetTo(anim.nowMs(), 1, anim.curveFor(.panel_slide));
        scene.SceneData.attach(&self.node_data, &node.node);
        node.setFilterMode(.bilinear);
        self.refresh();
        return self;
    }

    pub fn tick(self: *Calendar, now_ms: i64) bool {
        _ = self.slide.sampleChanged(now_ms, anim.quantum_alpha);
        panel_present.applySlide(self.buffer_node, self.panel_box, self.slide.value(now_ms), if (self.output.server.config.compositor.taskbar_position == .top) -slide_distance else slide_distance);
        return !self.slide.settled(now_ms);
    }

    pub fn destroy(self: *Calendar) void {
        if (self.output.server.input.open_calendar == self) self.output.server.input.open_calendar = null;
        self.buffer_node.node.destroy();
        gpa.destroy(self);
    }

    pub fn navigate(self: *Calendar, delta: i32) void {
        const index = std.math.clamp(self.year * 12 + self.month - 1 + delta, 12, 9999 * 12 + 11);
        self.year = @divFloor(index, 12);
        self.month = @mod(index, 12) + 1;
        self.refresh();
    }

    pub fn press(self: *Calendar, sx: f64, sy: f64) void {
        const x = sx / self.factor;
        const y = sy / self.factor;
        if (y >= 112 and y < 152) {
            if (x >= 268 and x < 308) self.navigate(-1);
            if (x >= 310 and x < 350) self.navigate(1);
        } else if (y < 100) {
            const tm = localNow();
            self.year = tm.tm_year + 1900;
            self.month = tm.tm_mon + 1;
            self.refresh();
        }
    }

    pub fn refresh(self: *Calendar) void {
        var box: wlr.Box = undefined;
        self.output.server.output_layout.getBox(self.output.wlr_output, &box);
        const prefs = self.output.server.config.region;
        const start: usize = @intFromEnum(prefs.first_day_of_week);
        const first = monthOffset(self.year, self.month, prefs);
        const days = daysInMonth(self.year, self.month);
        const rows = @max(5, @divTrunc(first + days + 6, 7));
        const body_height: f32 = @floatFromInt(204 + rows * 38);
        const full_height = body_height + 16;
        const available_h = @max(1, box.height - @import("Taskbar.zig").barHeight() - 24);
        self.factor = @min(1, @min(@as(f32, @floatFromInt(@max(1, box.width - 24))) / 368, @as(f32, @floatFromInt(available_h)) / full_height));
        const width: i32 = @intFromFloat(@round(368 * self.factor));
        const height: i32 = @intFromFloat(@round(full_height * self.factor));
        const scale = self.output.wlr_output.scale;
        const buf = PanelBuffer.create(@max(1, width), @max(1, height), scale) catch return;
        defer buf.base.drop();
        var r: paint.Renderer = .{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = scale * self.factor };
        const t = theme.shellPalette();
        const fill = [4]f32{ t.window_bg[0], t.window_bg[1], t.window_bg[2], t.calendar_opacity };
        r.fillRect(0, 0, 368, body_height, .{ .color = fill, .radius = t.calendar_radius, .border_width = 1, .border_color = t.calendar_border });
        // The pointer joins the bottom border and points towards the clock.
        for (0..@intCast(buf.height)) |iy| {
            const y = (@as(f32, @floatFromInt(iy)) + 0.5) / r.scale;
            if (y < body_height - 1) continue;
            for (0..@intCast(buf.width)) |ix| {
                const x = (@as(f32, @floatFromInt(ix)) + 0.5) / r.scale;
                const distance = (@abs(x - 316) + y - body_height - 16) / @sqrt(@as(f32, 2));
                const coverage = std.math.clamp(0.5 - distance * r.scale, 0, 1);
                if (coverage == 0) continue;
                const inner = std.math.clamp((-distance - 1) * r.scale + 0.5, 0, 1);
                const border_mix = t.calendar_border[3] * (1 - inner);
                const alpha = (fill[3] + (1 - fill[3]) * border_mix) * coverage;
                var pixel: u32 = @as(u32, @intFromFloat(@round(alpha * 255))) << 24;
                for (0..3) |channel| {
                    const value = fill[channel] + (t.calendar_border[channel] - fill[channel]) * border_mix;
                    pixel |= @as(u32, @intFromFloat(@round(value * alpha * 255))) << @as(u5, @intCast(16 - channel * 8));
                }
                buf.pixels[iy * @as(usize, @intCast(buf.width)) + ix] = pixel;
            }
        }
        if (self.output.server.config.compositor.taskbar_position == .top) buf.flipVertical();
        const tm = localNow();
        var time: [32]u8 = undefined;
        var date: [96]u8 = undefined;
        _ = c.strftime(&time, time.len, prefs.timeFormat(), &tm);
        _ = c.strftime(&date, date.len, "%A, %B %-d, %Y", &tm);
        label(&r, 24, 17, 320, 44, std.mem.trimStart(u8, std.mem.sliceTo(&time, 0), " "), 36, t.window_fg, true);
        label(&r, 24, 65, 320, 25, std.mem.sliceTo(&date, 0), 16, t.window_dim, false);
        r.fillRect(20, 102, 328, 1, .{ .color = t.app_divider });
        var title: [40]u8 = undefined;
        label(&r, 24, 116, 238, 32, std.fmt.bufPrint(&title, "{s} {d}", .{ months[@intCast(self.month - 1)], self.year }) catch "", 16, t.text_secondary, true);
        label(&r, 282, 116, 24, 32, "‹", 26, t.text_secondary, false);
        label(&r, 324, 116, 24, 32, "›", 26, t.text_secondary, false);
        const weekdays = [_][]const u8{ "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT" };
        for (0..7) |i| centered(&r, @floatFromInt(i), 158, weekdays[(i + start) % 7], 10, t.window_dim);
        const previous = daysInMonth(if (self.month == 1) self.year - 1 else self.year, if (self.month == 1) 12 else self.month - 1);
        for (0..@intCast(rows * 7)) |i| {
            const n = @as(i32, @intCast(i)) - first + 1;
            const current = n >= 1 and n <= days;
            const day = if (n < 1) previous + n else if (n > days) n - days else n;
            const x: f32 = @floatFromInt(i % 7);
            const y: f32 = 188 + @as(f32, @floatFromInt(i / 7)) * 38;
            const today = current and self.year == tm.tm_year + 1900 and self.month == tm.tm_mon + 1 and day == tm.tm_mday;
            if (today) r.fillRect(20 + x * 47 + 5, y, 37, 37, .{ .color = t.accent, .radius = 6 });
            var number: [4]u8 = undefined;
            centered(&r, x, y, std.fmt.bufPrint(&number, "{d}", .{day}) catch "", 14, if (today) .{ 1, 1, 1, 1 } else if (current) t.text_secondary else t.faint);
        }
        self.buffer_node.setBuffer(&buf.base);
        self.buffer_node.setDestSize(@max(1, width), @max(1, height));
        self.panel_box = .{ .x = box.x + box.width - width - 12, .y = self.output.taskbarPopupY(height, 12), .width = @max(1, width), .height = @max(1, height) };
        panel_present.applySlide(self.buffer_node, self.panel_box, self.slide.value(anim.nowMs()), if (self.output.server.config.compositor.taskbar_position == .top) -slide_distance else slide_distance);
        self.output.wlr_output.scheduleFrame();
    }
};

fn label(r: *paint.Renderer, x: f32, y: f32, w: f32, h: f32, value: []const u8, size: f32, color: [4]f32, bold: bool) void {
    r.drawText(x, y, w, h, .{ .content = value, .font_size = size, .color = color, .weight = if (bold) 700 else 400 });
}
fn centered(r: *paint.Renderer, column: f32, y: f32, value: []const u8, size: f32, color: [4]f32) void {
    const width = @import("ui").text.measureWidthF(value, .manrope, size, r.scale) catch 0;
    r.drawText(20 + column * 47 + (47 - width) / 2, y, width + 1, 37, .{ .content = value, .font_size = size, .color = color });
}
fn localNow() c.struct_tm {
    var raw = c.time(null);
    var tm: c.struct_tm = std.mem.zeroes(c.struct_tm);
    _ = c.localtime_r(&raw, &tm);
    return tm;
}
const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
pub fn daysInMonth(year: i32, month: i32) i32 {
    return switch (month) {
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}
fn monthOffset(year: i32, month: i32, prefs: @import("config").loader.RegionConfig) i32 {
    return @mod(firstWeekday(year, month) - @as(i32, @intFromEnum(prefs.first_day_of_week)), 7);
}
pub fn firstWeekday(year: i32, month: i32) i32 {
    const offsets = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const y = year - @as(i32, if (month < 3) 1 else 0);
    return @mod(y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400) + offsets[@intCast(month - 1)] + 1, 7);
}

test "calendar leap centuries and month alignment" {
    try std.testing.expectEqual(@as(i32, 29), daysInMonth(2000, 2));
    try std.testing.expectEqual(@as(i32, 28), daysInMonth(1900, 2));
    try std.testing.expectEqual(@as(i32, 29), daysInMonth(2024, 2));
    try std.testing.expectEqual(@as(i32, 4), firstWeekday(2025, 5));
    try std.testing.expectEqual(@as(i32, 0), firstWeekday(2026, 2));
    try std.testing.expectEqual(@as(i32, 6), firstWeekday(2026, 8));
    // February 2026 starts Sunday: Monday-first wraps into the last column.
    try std.testing.expectEqual(@as(i32, 6), monthOffset(2026, 2, .{ .first_day_of_week = .monday }));
    try std.testing.expectEqual(@as(i32, 0), monthOffset(2026, 8, .{ .first_day_of_week = .saturday }));
    // May 2026 needs six rows for Sunday-first, only five for Monday-first.
    for (0..7) |start| {
        const offset = monthOffset(2026, 5, .{ .first_day_of_week = @enumFromInt(start) });
        try std.testing.expectEqual(@mod(@as(i32, 5) - @as(i32, @intCast(start)), 7), offset);
    }
}
