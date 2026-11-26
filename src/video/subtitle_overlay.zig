//! A transparent, input-empty strip between the video and its controls.
//! Only cue, geometry, scale or theme changes require a new shm buffer.
const std = @import("std");
const wl = @import("wayland").client.wl;
const wp = @import("wayland").client.wp;
const ui = @import("ui");
const Pool = @import("app_kit").window_buffer.Pool;
const font = ui.text.Font.manrope_bold;
const white: ui.text.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
const black: ui.text.Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };

pub const Overlay = struct {
    surface: *wl.Surface = undefined,
    sub: *wl.Subsurface = undefined,
    viewport: *wp.Viewport = undefined,
    pool: Pool = .{ .name = "video-subtitles" },
    video: ui.text.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    dirty: bool = true,
    attached: bool = false,
    bottom: i32 = 0,
    scale: f32 = 0,

    pub fn create(self: *Overlay, compositor: *wl.Compositor, subs: *wl.Subcompositor, vp: *wp.Viewporter, root: *wl.Surface, shm: *wl.Shm) !void {
        self.surface = try compositor.createSurface();
        self.sub = try subs.getSubsurface(self.surface, root);
        self.sub.setDesync();
        self.viewport = try vp.getViewport(self.surface);
        self.pool.shm = shm;
        const empty = try compositor.createRegion();
        self.surface.setInputRegion(empty);
        empty.destroy();
    }

    pub fn deinit(self: *Overlay) void {
        self.pool.deinit();
        self.viewport.destroy();
        self.sub.destroy();
        self.surface.destroy();
    }

    pub fn draw(self: *Overlay, root: *wl.Surface, text: []const u8, scale: f32, controls_top: ?i32) !void {
        const v = self.video;
        const bottom = @min(v.y + v.h, controls_top orelse v.y + v.h) - @max(2, @divTrunc(v.h, 30));
        if (text.len == 0 or bottom <= v.y or v.w < 8) {
            if (self.attached) {
                self.surface.attach(null, 0, 0);
                self.surface.commit();
                self.attached = false;
            }
            return;
        }
        if (self.attached and !self.dirty and self.scale == scale and self.bottom == bottom) return;
        const size = ui.cairo.textSize() * @max(1, @as(f32, @floatFromInt(v.h)) / 360);
        const line_h: i32 = @intFromFloat(@ceil(try ui.text.lineHeight(font, size, scale)) + 2);
        const outline: i32 = @max(1, @as(i32, @intFromFloat(@round(size / 16))));
        const pad = @max(outline + 1, @divTrunc(v.w, 24));
        const width = @max(1, v.w - 2 * pad);
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(std.heap.c_allocator);
        const available = bottom - v.y;
        const max_lines: usize = @intCast(@max(1, @divTrunc(available - 2 * outline, line_h)));
        var paragraphs = std.mem.splitScalar(u8, text, '\n');
        while (paragraphs.next()) |paragraph| {
            var rest = std.mem.trim(u8, paragraph, " \r\t");
            while (rest.len > 0 and lines.items.len < max_lines) {
                const n = try lineBreak(rest, width, size, scale);
                try lines.append(std.heap.c_allocator, std.mem.trimEnd(u8, rest[0..n], " \t"));
                rest = std.mem.trimStart(u8, rest[n..], " \t");
            }
            if (lines.items.len == max_lines) break;
        }
        const height = @min(available, @as(i32, @intCast(lines.items.len)) * line_h + 2 * outline);
        const px: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(v.w)) * scale));
        const py: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(height)) * scale));
        const buf = try self.pool.acquire(px, py) orelse return;
        const ptr: [*]u32 = @ptrCast(@alignCast(buf.memory));
        const pixels = ptr[0..@intCast(px * py)];
        @memset(pixels, 0);
        for (lines.items, 0..) |line, i| {
            const w = try ui.text.measureWidth(line, font, size, scale);
            const x = @max(pad, @divTrunc(v.w - w, 2));
            const y = @as(i32, @intCast(i)) * line_h + outline;
            const rect: ui.text.Rect = .{ .x = x, .y = y, .w = v.w - x, .h = line_h };
            for ([_]i32{ -outline, 0, outline }) |dy| {
                for ([_]i32{ -outline, 0, outline }) |dx| {
                    if (dx == 0 and dy == 0) continue;
                    var edge = rect;
                    edge.x += dx;
                    edge.y += dy;
                    try ui.text.draw(pixels, px, py, edge, line, black, scale, font, size);
                }
            }
            try ui.text.draw(pixels, px, py, rect, line, white, scale, font, size);
        }
        self.sub.setPosition(v.x, bottom - height);
        self.viewport.setDestination(v.w, height);
        self.pool.submit(buf);
        self.surface.attach(buf.wl_buffer, 0, 0);
        self.surface.damageBuffer(0, 0, px, py);
        self.surface.commit();
        root.commit(); // subsurface position belongs to the parent
        self.attached = true;
        self.dirty = false;
        self.scale = scale;
        self.bottom = bottom;
    }
};

fn lineBreak(line: []const u8, width: i32, size: f32, scale: f32) !usize {
    // Only shape a screenful, even for a file with one enormous line.
    const end = if (line.len > 2048) ui.text.previousUtf8Boundary(line, 2049) else line.len;
    const sample = line[0..end];
    if (try ui.text.measureWidth(sample, font, size, scale) <= width) return end;
    const offset = try ui.text.offsetAtX(sample, font, size, scale, @floatFromInt(width));
    const fit = @max(ui.text.nextClusterEnd(sample, 0), offset);
    if (fit < line.len and line[fit] != ' ') {
        if (std.mem.lastIndexOfAny(u8, sample[0..fit], " \t")) |space| {
            if (space > 0) return space;
        }
    }
    return fit;
}
