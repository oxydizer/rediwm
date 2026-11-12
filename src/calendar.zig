// Local-time calendar opened by the taskbar clock. Repaint only on interaction,
// output geometry changes, or the taskbar's existing minute tick.
const std = @import("std");
const wlr = @import("wlroots");
const sn = @import("node.zig");
const i18n = @import("i18n");
const c = @import("c");
const Output = @import("Output.zig");
const gpa = @import("main.zig").gpa;
const PanelBuffer = @import("panel_buffer.zig").PanelBuffer;
const scene = @import("scene_data.zig");
const paint = @import("ui").paint;
const theme = @import("ui").theme;
const anim = @import("ui").anim;
const panel_present = @import("panel_present.zig");
const Anim = anim.Anim;
const glass = @import("glass.zig");
const popup_style = @import("popup_style.zig");
const slide_distance: f32 = 20;

pub const Calendar = struct {
    output: *Output,
    buffer_node: *sn.Buffer,
    glass_effect: ?*glass.Effect = null,
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
        popup_style.configureGlass(&self.glass_effect, self.output.server.glass_engine, self.buffer_node, self.factor);
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
        const locale = timeLocale(gpa, prefs.formats) orelse return;
        defer c.freelocale(locale);
        const start: usize = @intFromEnum(prefs.first_day_of_week);
        const first = monthOffset(self.year, self.month, prefs);
        const days = daysInMonth(self.year, self.month);
        const rows = @max(5, @divTrunc(first + days + 6, 7));
        const body_height: f32 = @floatFromInt(204 + rows * 38);
        const full_height = body_height + 16;
        const available_h = @max(1, box.height - @import("Taskbar.zig").reservedHeight() - 24);
        self.factor = @min(1, @min(@as(f32, @floatFromInt(@max(1, box.width - 24))) / 368, @as(f32, @floatFromInt(available_h)) / full_height));
        const width: i32 = @intFromFloat(@round(368 * self.factor));
        const height: i32 = @intFromFloat(@round(full_height * self.factor));
        // Centred over the clock wherever the taskbar puts it, kept on the
        // output; the pointer aims at the clock. Without one (hidden clock, no
        // taskbar) it keeps to the right edge.
        const right = box.x + box.width - width - 12;
        const clock = if (self.output.taskbar) |bar| bar.itemBox(.clock) else null;
        const left = if (clock) |anchor|
            std.math.clamp(anchor.x + @divTrunc(anchor.width - width, 2), box.x + 12, @max(box.x + 12, right))
        else
            right;
        const tip: f32 = if (clock) |anchor|
            std.math.clamp(@as(f32, @floatFromInt(anchor.x + @divTrunc(anchor.width, 2) - left)) / self.factor, 24, 344)
        else
            316;
        const scale = self.output.wlr_output.scale;
        const buf = PanelBuffer.create(@max(1, width), @max(1, height), scale) catch return;
        defer buf.base.drop();
        var r: paint.Renderer = .{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = scale * self.factor };
        var t = theme.shellPalette();
        const popup_surface = t.popup_bg != null or t.popup_blur;
        r.palette = t;
        if (popup_surface) {
            popup_style.background(&r, buf, 368, full_height, 16, tip, self.output.server.config.compositor.taskbar_position == .top);
            t.text_secondary = t.window_fg;
            t.faint = t.window_dim;
        } else {
            const fill = [4]f32{ t.window_bg[0], t.window_bg[1], t.window_bg[2], t.calendar_opacity };
            r.fillRect(0, 0, 368, body_height, .{ .color = fill, .radius = t.calendar_radius, .border_width = 1, .border_color = t.calendar_border });
            // The pointer joins the bottom border and points towards the clock.
            for (0..@intCast(buf.height)) |iy| {
                const y = (@as(f32, @floatFromInt(iy)) + 0.5) / r.scale;
                if (y < body_height - 1) continue;
                for (0..@intCast(buf.width)) |ix| {
                    const x = (@as(f32, @floatFromInt(ix)) + 0.5) / r.scale;
                    const distance = (@abs(x - tip) + y - body_height - 16) / @sqrt(@as(f32, 2));
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
        }
        const tm = localNow();
        var time: [64]u8 = undefined;
        var date: [192]u8 = undefined;
        label(&r, 24, 17, 320, 44, std.mem.trimStart(u8, formatDate(&time, prefs.timeFormat(), &tm, locale), " "), 36, t.window_fg, true);
        label(&r, 24, 65, 320, 25, formatDate(&date, i18n.trc("date", "%A, %B %-d, %Y"), &tm, locale), 16, t.window_dim, false);
        r.fillRect(20, 102, 328, 1, .{ .color = t.app_divider });
        var title: [128]u8 = undefined;
        var viewed = tm;
        viewed.tm_year = self.year - 1900;
        viewed.tm_mon = self.month - 1;
        label(&r, 24, 116, 238, 32, formatDate(&title, i18n.trc("date", "%B %Y"), &viewed, locale), 16, t.text_secondary, true);
        label(&r, 282, 116, 24, 32, "‹", 26, t.text_secondary, false);
        label(&r, 324, 116, 24, 32, "›", 26, t.text_secondary, false);
        for (0..7) |i| centered(&r, @floatFromInt(i), 158, weekdayName(locale, (i + start) % 7), 10, t.window_dim);
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
            centered(&r, x, y, std.fmt.bufPrint(&number, "{d}", .{day}) catch "", 14, if (today) t.on_accent else if (current) t.text_secondary else t.faint);
        }
        self.buffer_node.setBuffer(&buf.base);
        self.buffer_node.setDestSize(@max(1, width), @max(1, height));
        self.panel_box = .{ .x = left, .y = self.output.taskbarPopupY(height, 12), .width = @max(1, width), .height = @max(1, height) };
        panel_present.applySlide(self.buffer_node, self.panel_box, self.slide.value(anim.nowMs()), if (self.output.server.config.compositor.taskbar_position == .top) -slide_distance else slide_distance);
        popup_style.configureGlass(&self.glass_effect, self.output.server.glass_engine, self.buffer_node, self.factor);
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
fn timeLocale(allocator: std.mem.Allocator, name: []const u8) c.locale_t {
    const terminated = allocator.dupeSentinel(u8, name, 0) catch return null;
    defer allocator.free(terminated);
    // Locale objects are private to this paint. Reloading formats updates an
    // already-open calendar without changing libc's process-wide locale.
    return c.newlocale(c.LC_TIME_MASK, terminated, null) orelse c.newlocale(c.LC_TIME_MASK, "C", null);
}

fn weekdayName(locale: c.locale_t, day: usize) []const u8 {
    return std.mem.span(c.nl_langinfo_l(@as(c.nl_item, c.ABDAY_1) + @as(c.nl_item, @intCast(day)), locale));
}

fn formatDate(destination: []u8, pattern: []const u8, tm: *const c.struct_tm, locale: c.locale_t) []const u8 {
    var terminated: [256]u8 = undefined;
    if (pattern.len >= terminated.len or std.mem.indexOfScalar(u8, pattern, 0) != null) return "";
    @memcpy(terminated[0..pattern.len], pattern);
    terminated[pattern.len] = 0;
    const length = c.strftime_l(destination.ptr, destination.len, @ptrCast(&terminated), tm, locale);
    return destination[0..length];
}
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

test "calendar dates use a private regional locale and bounded translated patterns" {
    const locale = timeLocale(std.testing.allocator, "C") orelse return error.LocaleUnavailable;
    defer c.freelocale(locale);
    const tm = std.mem.zeroInit(c.struct_tm, .{ .tm_year = 126, .tm_mon = 9, .tm_mday = 20, .tm_wday = 2 });
    var buffer: [192]u8 = undefined;
    try std.testing.expectEqualStrings("Tuesday, October 20, 2026", formatDate(&buffer, "%A, %B %-d, %Y", &tm, locale));
    try std.testing.expectEqualStrings("20 de October de 2026", formatDate(&buffer, "%-d de %B de %Y", &tm, locale));
    try std.testing.expectEqualStrings("October 2026", formatDate(&buffer, "%B %Y", &tm, locale));
    try std.testing.expectEqualStrings("Sun", weekdayName(locale, 0));
    try std.testing.expectEqualStrings("Sat", weekdayName(locale, 6));
    try std.testing.expectEqualStrings("", formatDate(buffer[0..2], "%B", &tm, locale));
    try std.testing.expectEqualStrings("", formatDate(&buffer, "bad\x00format", &tm, locale));
    const fallback = timeLocale(std.testing.allocator, "rediwm_nonexistent_locale") orelse return error.LocaleUnavailable;
    defer c.freelocale(fallback);
    try std.testing.expectEqualStrings("October 2026", formatDate(&buffer, "%B %Y", &tm, fallback));
}
