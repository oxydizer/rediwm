//! A retained widget tree on a transparent strip above the video. Input is
//! in root coordinates; the child has an empty input region. Only redraw on
//! a released shm buffer, at most once per compositor frame callback.
const std = @import("std");
const wl = @import("wayland").client.wl;
const wp = @import("wayland").client.wp;
const ui = @import("ui");
const BufferPool = @import("app_kit").window_buffer.Pool;
const tr = @import("app_kit").i18n.tr;
const now = @import("clock.zig").now;
const Widget = ui.layout.Widget;
const ns = std.time.ns_per_s;
const Item = enum(usize) { elapsed, seek, remaining, play, mute, volume, percent, open, fullscreen, notice };

pub const Osd = struct {
    surface: ?*wl.Surface = null,
    sub: *wl.Subsurface = undefined,
    viewport: *wp.Viewport = undefined,
    pool: BufferPool = .{ .name = "video-controls" },
    callback: ?*wl.Callback = null,
    fractional: ?*wp.FractionalScaleV1 = null,
    density: f32 = 1,

    root: Widget = .{ .kind = .container },
    items: [std.enums.values(Item).len]Widget = undefined,
    dispatch: ui.input.Dispatcher = .{},
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    mouse_x: f32 = -1,
    mouse_y: f32 = -1,
    visible: bool = false,
    attached: bool = false,
    dirty: bool = true,
    hide_at: i64 = 0,
    click_at: ?i64 = null,
    click_x: f32 = 0,
    click_y: f32 = 0,
    video_press: bool = false,
    bar_press: bool = false,
    toggle: bool = false,
    fullscreen: bool = false,
    open: bool = false,
    toggle_subtitles: bool = false,
    relative: i64 = 0,
    steps: i32 = 0,
    seek_to: ?f32 = null,
    scrub_end: bool = false,
    volume: i32 = 100,
    muted: bool = false,
    wheel_remainder: f64 = 0,
    wheel_seek: bool = false,
    notice_until: ?i64 = null,
    second: i64 = -1,
    fraction: f32 = -1,
    was_paused: bool = false,
    elapsed_text: [24]u8 = undefined,
    remaining_text: [24]u8 = undefined,
    volume_text: [12]u8 = undefined,

    pub fn create(self: *Osd, compositor: *wl.Compositor, subcompositor: *wl.Subcompositor, viewporter: *wp.Viewporter, root: *wl.Surface, shm: *wl.Shm, scales: ?*wp.FractionalScaleManagerV1) !void {
        const surface = try compositor.createSurface();
        self.surface = surface;
        self.sub = try subcompositor.getSubsurface(surface, root);
        self.sub.setDesync();
        self.viewport = try viewporter.getViewport(surface);
        self.pool.shm = shm;
        const empty = try compositor.createRegion();
        surface.setInputRegion(empty);
        empty.destroy();
        if (scales) |mgr| {
            // Listen on the mapped root: the strip learns its density even
            // while it is hidden.
            self.fractional = try mgr.getFractionalScale(root);
            self.fractional.?.setListener(*Osd, scaleEvent, self);
        }
        for (&self.items, 0..) |*w, id| {
            const item: Item = @fromBackingInt(@intCast(id));
            w.* = switch (item) {
                .elapsed, .remaining, .percent, .notice => .{ .kind = .{ .text = .{ .content = "", .font_size = ui.cairo.statusSize(), .color = ui.theme.global.window_fg } } },
                .seek, .volume => .{ .kind = .{ .slider = .{ .value = 0, .min = 0, .max = if (item == .volume) 150 else 1, .owner = self, .id = id, .on_change = changed } } },
                else => .{ .kind = .{ .button = .{ .variant = .ghost, .size = .sm, .owner = self, .id = id, .on_click = clicked, .icon = switch (item) {
                    .open => .folder,
                    .mute => .volume,
                    .fullscreen => .maximize,
                    else => null,
                } } } },
            };
        }
        self.root.children = &self.items;
        self.root.linkParents();
        self.clearNotice();
    }

    fn scaleEvent(_: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, self: *Osd) void {
        self.density = std.math.clamp(@as(f32, @floatFromInt(event.preferred_scale.scale)) / 120, 0.25, 8);
        self.dirty = true;
    }

    pub fn deinit(self: *Osd) void {
        self.dispatch.reset();
        if (self.callback) |cb| cb.destroy();
        if (self.fractional) |scale| scale.destroy();
        self.pool.deinit();
        self.viewport.destroy();
        self.sub.destroy();
        self.surface.?.destroy();
    }

    fn get(self: *Osd, item: Item) *Widget {
        return &self.items[@backingInt(item)];
    }

    fn clicked(owner: ?*anyopaque, id: usize) void {
        const self: *Osd = @ptrCast(@alignCast(owner.?));
        switch (@as(Item, @fromBackingInt(@intCast(id)))) {
            .play => self.toggle = !self.toggle,
            .mute => self.muted = !self.muted,
            .open => self.open = true,
            .fullscreen => self.fullscreen = true,
            else => unreachable,
        }
        self.dirty = true;
    }

    fn changed(owner: ?*anyopaque, id: usize, value: f32) void {
        const self: *Osd = @ptrCast(@alignCast(owner.?));
        if (id == @backingInt(Item.seek)) {
            self.seek_to = value;
            self.get(.seek).kind.slider.value = value;
        } else self.setVolume(@intFromFloat(@round(value)));
        self.dirty = true;
    }

    pub fn setVolume(self: *Osd, percent: i32) void {
        self.volume = std.math.clamp(percent, 0, 150);
        self.muted = false;
        self.reveal();
    }

    pub fn reveal(self: *Osd) void {
        if (!self.visible) self.dirty = true;
        self.visible = true;
        self.hide_at = now() + 3 * ns;
    }

    pub fn message(self: *Osd, msg: []const u8) void {
        self.cancelPress();
        self.setLabel(.notice, msg);
        self.root.children = self.items[@backingInt(Item.play)..];
        self.notice_until = now() + 3 * ns;
        self.dirty = true;
        self.reveal();
    }

    pub fn clearNotice(self: *Osd) void {
        self.root.children = self.items[0..@backingInt(Item.notice)];
        self.notice_until = null;
        self.dirty = true;
    }

    pub fn movieChanged(self: *Osd) void {
        self.cancelPress();
        self.steps = 0;
        self.seek_to = null;
        self.scrub_end = false;
        self.click_at = null;
        self.relative = 0;
        self.toggle = false;
        self.clearNotice();
        self.reveal();
    }

    pub fn resize(self: *Osd, w: i32, h: i32) void {
        if (self.surface == null) return;
        self.width = @min(680, w -| @min(16, @divTrunc(w, 12)));
        self.height = @min(h, @as(i32, @intFromFloat(@ceil(54 + ui.cairo.statusSize() * 1.5))));
        self.x = @divTrunc(w - self.width, 2);
        self.y = @max(0, h - self.height - 8);
        self.sub.setPosition(self.x, self.y);
        self.viewport.setDestination(self.width, self.height);
        self.layout();
        self.dirty = true;
    }

    fn place(self: *Osd, id: Item, x: f32, y: f32, w: f32, h: f32) void {
        ui.arrange.arrange(self.get(id), x, y, @max(0, w), @max(0, h));
    }

    fn layout(self: *Osd) void {
        const width: f32 = @floatFromInt(self.width);
        const height: f32 = @floatFromInt(self.height);
        self.root.computed_width = width;
        self.root.computed_height = height;
        const pad: f32 = 7;
        const row = (height - 2 * pad) / 2;
        const label_w = @min(width * 0.26, 6.1 * ui.cairo.statusSize());
        self.place(.notice, pad, pad, width - 2 * pad, row);
        self.place(.elapsed, pad, pad, label_w, row);
        self.place(.seek, pad + label_w, pad, width - (pad + label_w) * 2, row);
        self.place(.remaining, width - pad - label_w, pad, label_w, row);
        const y = pad + row;
        const button_w = @min(36, width * 0.13);
        const play = @min(74, width * 0.25);
        self.place(.play, pad, y, play, row);
        self.place(.mute, pad + play, y, button_w, row);
        const volume_x = pad + play + button_w;
        const right = width - pad - button_w * 2;
        const label: f32 = if (width >= 300) @min(50, ui.cairo.statusSize() * 3.5) else 0;
        const vol_w = @min(130, right - volume_x - label - 4);
        self.place(.volume, volume_x, y, vol_w, row);
        self.place(.percent, volume_x + vol_w + 4, y, label, row);
        self.place(.open, right, y, button_w, row);
        self.place(.fullscreen, right + button_w, y, button_w, row);
    }

    fn localX(self: *Osd) f32 {
        return self.mouse_x - @as(f32, @floatFromInt(self.x));
    }
    fn localY(self: *Osd) f32 {
        return self.mouse_y - @as(f32, @floatFromInt(self.y));
    }

    pub fn motion(self: *Osd, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
        self.reveal();
        self.dispatch.pointerMotion(&self.root, self.localX(), self.localY());
        self.dirty = true;
    }

    pub fn leave(self: *Osd) void {
        self.cancelPress();
        self.mouse_x = -1;
        self.mouse_y = -1;
    }

    fn cancelPress(self: *Osd) void {
        if (self.surface == null) return;
        if (self.dragSeek()) self.scrub_end = true;
        if (self.dispatch.slider_drag) |w| ui.widgets.slider.endDrag(w);
        self.dispatch.pointerLeave(&self.root);
        if (self.dispatch.pressed) |w| ui.input.setButtonOrRowState(w, .idle);
        self.dispatch.reset();
        self.video_press = false;
        self.bar_press = false;
        self.dirty = true;
    }

    pub fn seekValue(self: *Osd) f32 {
        return self.get(.seek).kind.slider.value;
    }

    pub fn dragSeek(self: *Osd) bool {
        return self.dispatch.slider_drag == self.get(.seek);
    }

    pub fn button(self: *Osd, down: bool) void {
        const over = self.visible and self.root.contains(self.localX(), self.localY());
        self.reveal();
        if (down) {
            self.bar_press = over;
            self.video_press = !over;
            if (over) {
                self.dispatch.pointerButtonDown(&self.root, self.localX(), self.localY());
                // Grabbing the thumb at its existing value still pauses the
                // movie and freezes the target under the pointer.
                if (self.dragSeek()) self.seek_to = self.seekValue();
            }
        } else if (self.bar_press) {
            if (self.dragSeek()) {
                ui.widgets.slider.dragTo(self.get(.seek), self.localX());
                self.scrub_end = true;
            }
            self.dispatch.pointerButtonUp(&self.root, self.localX(), self.localY());
            self.bar_press = false;
        } else if (self.video_press) {
            self.video_press = false;
            if (!over) {
                const t = now();
                if (self.click_at != null and t <= self.click_at.? and @abs(self.mouse_x - self.click_x) <= 5 and @abs(self.mouse_y - self.click_y) <= 5) {
                    self.fullscreen = true;
                    self.click_at = null;
                } else {
                    if (self.click_at != null) self.toggle = !self.toggle;
                    self.click_at = t + 300 * std.time.ns_per_ms;
                    self.click_x = self.mouse_x;
                    self.click_y = self.mouse_y;
                }
            }
        }
        self.dirty = true;
    }

    pub fn scroll(self: *Osd, notches: f64) void {
        self.reveal();
        const seek = ui.input.hitTest(&self.root, self.localX(), self.localY()) == self.get(.seek);
        if (seek != self.wheel_seek) self.wheel_remainder = 0;
        self.wheel_seek = seek;
        self.wheel_remainder -= notches;
        const steps: i32 = @intFromFloat(@trunc(self.wheel_remainder));
        self.wheel_remainder -= @floatFromInt(steps);
        if (steps == 0) return;
        if (seek) self.relative += @as(i64, steps) * 5 else self.setVolume(self.volume + steps * 5);
    }

    pub fn tick(self: *Osd, t: i64) ?i64 {
        if (self.click_at) |due| if (t >= due) {
            self.toggle = !self.toggle;
            self.click_at = null;
        };
        var deadline = self.click_at;
        if (self.notice_until) |end| {
            if (t >= end) self.clearNotice() else deadline = @min(deadline orelse end, end);
        }
        if (self.visible and !self.bar_press) {
            if (t >= self.hide_at) {
                self.visible = false;
                self.clearNotice();
                self.dispatch.pointerLeave(&self.root);
            } else deadline = @min(deadline orelse self.hide_at, self.hide_at);
        }
        return deadline;
    }

    fn frame(cb: *wl.Callback, _: wl.Callback.Event, self: *Osd) void {
        cb.destroy();
        self.callback = null;
    }

    pub fn draw(self: *Osd, pos: i64, duration: i64, paused: bool) !?i64 {
        const surface = self.surface.?;
        if (!self.visible) {
            if (self.attached) {
                if (self.callback) |cb| cb.destroy();
                self.callback = null;
                surface.attach(null, 0, 0);
                surface.commit();
                self.attached = false;
            }
            return null;
        }
        if (self.width <= 0 or self.callback != null) return null;
        const t = @divTrunc(now(), std.time.ns_per_ms);
        const seek = &self.get(.seek).kind.slider;
        if (!seek.dragging) seek.value = if (duration > 0) std.math.clamp(@as(f32, @floatFromInt(pos)) / @as(f32, @floatFromInt(duration)), 0, 1) else 0;
        const display_pos = if (seek.dragging) @as(i64, @intFromFloat(@as(f64, @floatFromInt(duration)) * seek.value)) else pos;
        const sec = @divTrunc(@max(0, display_pos), ns);
        self.get(.volume).kind.slider.value = @floatFromInt(if (self.muted) @as(i32, 0) else self.volume);
        const revision = ui.layout.paint_revision;
        const anim = ui.widgets.scroll_container.stepBars(&self.root, t);
        const next = if (anim.deadline) |ms| ms * std.time.ns_per_ms else null;
        if (!self.dirty and revision == ui.layout.paint_revision and !anim.active and self.second == sec and self.fraction == seek.value and self.was_paused == paused) return next;
        const px: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(self.width)) * self.density));
        const py: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(self.height)) * self.density));
        const buf = try self.pool.acquire(px, py) orelse return next;
        self.get(.play).kind.button.label = if (paused) tr("Play") else tr("Pause");
        self.get(.mute).kind.button.icon = if (self.muted or self.volume == 0) .volume_muted else .volume;
        self.setLabel(.elapsed, timestamp(&self.elapsed_text, sec, false));
        self.setLabel(.remaining, timestamp(&self.remaining_text, @divTrunc(@max(0, duration - display_pos), ns), true));
        self.setLabel(.percent, std.fmt.bufPrint(&self.volume_text, "{d}%", .{if (self.muted) @as(i32, 0) else self.volume}) catch "");
        const pixels: [*]u32 = @ptrCast(@alignCast(buf.memory));
        var r = ui.paint.Renderer.init(pixels[0..@intCast(px * py)], px, py, self.density);
        @memset(r.pixels, 0);
        r.palette = ui.theme.shellPalette();
        r.fillRect(0, 0, self.root.computed_width, self.root.computed_height, .{ .color = ui.theme.global.app_bg, .radius = 8 });
        ui.input.active_dispatcher = &self.dispatch;
        defer ui.input.active_dispatcher = null;
        ui.paint.paint(&self.root, &r);
        self.callback = try surface.frame();
        self.callback.?.setListener(*Osd, frame, self);
        self.pool.submit(buf);
        surface.attach(buf.wl_buffer, 0, 0);
        surface.damageBuffer(0, 0, px, py);
        surface.commit();
        self.attached = true;
        self.dirty = false;
        self.second = sec;
        self.was_paused = paused;
        self.fraction = seek.value;
        return next;
    }

    fn setLabel(self: *Osd, id: Item, label: []const u8) void {
        const text = &self.get(id).kind.text;
        text.content = label;
        text.font_size = ui.cairo.statusSize();
        text.color = ui.theme.global.window_fg;
    }
};

fn timestamp(buf: []u8, sec: i64, remaining: bool) []const u8 {
    const prefix: []const u8 = if (remaining) "−" else "";
    const minutes = @divTrunc(sec, 60);
    if (minutes >= 60) return std.fmt.bufPrint(buf, "{s}{d}:{d:0>2}:{d:0>2}", .{ prefix, @divTrunc(minutes, 60), @as(u64, @intCast(@mod(minutes, 60))), @as(u64, @intCast(@mod(sec, 60))) }) catch "";
    return std.fmt.bufPrint(buf, "{s}{d}:{d:0>2}", .{ prefix, minutes, @as(u64, @intCast(@mod(sec, 60))) }) catch "";
}
