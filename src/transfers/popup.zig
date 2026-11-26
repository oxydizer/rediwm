//! The Transfers panel above its taskbar item, in the Wi-Fi popup's frame:
//! a header with Pause all / Resume all, the last minute's total speed,
//! the running jobs, the finished ones and a footer. Rows are painted in
//! `popup_rows.zig`; this file keeps the state, input and frame.
//!
//! Cancel takes two presses: the first arms the row's button, which then
//! reads "Cancel" in the danger colour; anything else disarms it. Finished
//! jobs stay listed until "Clear" (the list is the panel's, not Files').
const i18n = @import("i18n");
const std = @import("std");
const popup_style = @import("../popup_style.zig");
const glass = @import("../glass.zig");
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const Output = @import("../Output.zig");
const scene = @import("../scene_data.zig");
const gpa = @import("../main.zig").gpa;
const PanelBuffer = @import("../panel_buffer.zig").PanelBuffer;
const paint = @import("ui").paint;
const theme = @import("ui").theme;
const scrollbar = @import("ui").widgets.scrollbar;
const button = @import("ui").widgets.button;
const Rect = @import("ui").widgets.field.Rect;
const anim = @import("ui").anim;
const present = @import("../panel_present.zig");
const model_mod = @import("model.zig");
const Client = @import("client.zig").Client;
const rows = @import("popup_rows.zig");
const glyphs = @import("glyphs.zig");

pub const width: f32 = 400;
pub const header: f32 = 64;
pub const graph_height: f32 = 108;
pub const footer: f32 = 60;
const slide_distance: f32 = 20;

pub const Focus = enum { pause_all, row, pause, cancel, resolve, choose, stop_seeding, destination, done_row, show, open_files, clear_done };
pub const Hit = struct { box: Rect, focus: Focus, id: u64 = 0 };

pub const Popup = struct {
    output: *Output,
    buffer_node: *sn.Buffer,
    node_data: scene.SceneData = undefined,
    glass_effect: ?*glass.Effect = null,
    factor: f32 = 1,
    height: f32 = 300,
    panel_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    slide: anim.Anim = .{},
    hits: [256]Hit = undefined,
    hit_count: usize = 0,
    hover: ?usize = null,
    /// Keyboard focus, by kind and job.
    focus: ?Focus = null,
    focus_id: u64 = 0,
    /// The expanded row, which shows its speed and destination.
    selected: ?u64 = null,
    /// The job whose cancel button waits for a second press.
    armed_cancel: ?u64 = null,
    scroll: f32 = 0,
    content_height: f32 = 0,
    list_top: f32 = header,

    pub fn create(output: *Output) !*Popup {
        const self = try gpa.create(Popup);
        errdefer gpa.destroy(self);
        const node = try output.server.overlay_tree.createSceneBuffer(null);
        self.* = .{ .output = output, .buffer_node = node };
        self.node_data = .{ .role = .{ .transfers_popup = self } };
        scene.SceneData.attach(&self.node_data, &node.node);
        node.setFilterMode(.bilinear);
        self.slide.retargetTo(anim.nowMs(), 1, anim.curveFor(.panel_slide));
        // The newest running job opens expanded, so its speed shows at once.
        if (self.client()) |c| {
            var i = c.model.liveJobs().len;
            while (i > 0) {
                i -= 1;
                const job = c.model.liveJobs()[i];
                if (job.state == .running and !job.conflict) {
                    self.selected = job.id;
                    break;
                }
            }
        }
        self.refresh();
        return self;
    }

    pub fn destroy(self: *Popup) void {
        if (self.output.server.input.open_transfers == self) self.output.server.input.open_transfers = null;
        self.buffer_node.node.destroy();
        gpa.destroy(self);
    }

    pub fn client(self: *Popup) ?*Client {
        return self.output.server.transfers;
    }

    pub fn tick(self: *Popup, now: i64) bool {
        _ = self.slide.sampleChanged(now, anim.quantum_alpha);
        present.applySlide(self.buffer_node, self.panel_box, self.slide.value(now), self.slideDistance());
        popup_style.configureGlass(&self.glass_effect, self.output.server.glass_engine, self.buffer_node, self.factor);
        return !self.slide.settled(now);
    }

    fn slideDistance(self: *Popup) f32 {
        return if (self.output.server.config.compositor.taskbar_position == .top) -slide_distance else slide_distance;
    }

    /// The model changed: drop state that names jobs that are gone.
    pub fn changed(self: *Popup) void {
        if (self.client()) |c| {
            if (self.armed_cancel) |id| if (c.model.find(id) == null) {
                self.armed_cancel = null;
            };
        }
        self.refresh();
    }

    pub fn motion(self: *Popup, sx: f64, sy: f64) void {
        const next = self.hit(@floatCast(sx / self.factor), @floatCast(sy / self.factor));
        if (next == self.hover) return;
        self.hover = next;
        self.refresh();
    }

    fn hit(self: *Popup, x: f32, y: f32) ?usize {
        var i = self.hit_count;
        while (i > 0) {
            i -= 1;
            const h = self.hits[i];
            if (!fixed(h.focus) and (y < self.list_top or y >= self.height - footer)) continue;
            if (x >= h.box.x and x < h.box.x + h.box.w and y >= h.box.y and y < h.box.y + h.box.h) return i;
        }
        return null;
    }

    /// Header and footer controls, outside the scrolled list.
    fn fixed(focus: Focus) bool {
        return focus == .pause_all or focus == .open_files or focus == .clear_done;
    }

    pub fn widgetAt(self: *Popup, sx: f64, sy: f64) ?[]const u8 {
        const index = self.hit(@floatCast(sx / self.factor), @floatCast(sy / self.factor)) orelse return null;
        return @tagName(self.hits[index].focus);
    }

    pub fn press(self: *Popup, sx: f64, sy: f64) void {
        const index = self.hit(@floatCast(sx / self.factor), @floatCast(sy / self.factor)) orelse {
            self.armed_cancel = null;
            return self.refresh();
        };
        self.focus = null;
        self.run(self.hits[index]);
    }

    pub fn scrollWheel(self: *Popup, delta: f32) void {
        self.scroll = std.math.clamp(self.scroll + delta, 0, self.maxScroll());
        self.hover = null;
        self.refresh();
    }

    fn maxScroll(self: *const Popup) f32 {
        return @max(0, self.content_height - (self.height - self.list_top - footer));
    }

    /// Tab and the arrows walk the controls in paint order.
    pub fn navigate(self: *Popup, backwards: bool) void {
        if (self.hit_count == 0) return;
        var index: usize = if (backwards) 0 else self.hit_count - 1;
        if (self.focus) |f| for (self.hits[0..self.hit_count], 0..) |h, i| if (h.focus == f and h.id == self.focus_id) {
            index = i;
            break;
        };
        index = (index + (if (backwards) self.hit_count - 1 else 1)) % self.hit_count;
        const next = self.hits[index];
        self.focus = next.focus;
        self.focus_id = next.id;
        if (!fixed(next.focus)) {
            const bottom = self.height - footer;
            if (next.box.y < self.list_top) self.scroll += next.box.y - self.list_top;
            if (next.box.y + next.box.h > bottom) self.scroll += next.box.y + next.box.h - bottom;
            self.scroll = std.math.clamp(self.scroll, 0, self.maxScroll());
        }
        self.refresh();
    }

    pub fn activate(self: *Popup) void {
        const f = self.focus orelse return;
        for (self.hits[0..self.hit_count]) |h| if (h.focus == f and h.id == self.focus_id) return self.run(h);
    }

    fn run(self: *Popup, h: Hit) void {
        const c = self.client() orelse return;
        if (h.focus != .cancel) self.armed_cancel = null;
        switch (h.focus) {
            .pause_all => {
                const s = c.model.summary();
                const resuming = s.all_paused;
                for (c.model.liveJobs()) |job| {
                    if (job.state.isTerminal() or job.state == .seeding or job.choose_files) continue;
                    if (resuming and job.state == .paused) c.control(.@"resume", job.id);
                    if (!resuming and job.state != .paused) c.control(.pause, job.id);
                }
            },
            .row => self.selected = if (self.selected == h.id) null else h.id,
            .pause => if (c.model.find(h.id)) |job| c.control(if (job.state == .paused) .@"resume" else .pause, job.id),
            .cancel => {
                if (self.armed_cancel == h.id) {
                    self.armed_cancel = null;
                    c.control(.cancel, h.id);
                } else self.armed_cancel = h.id;
            },
            .resolve => {
                const job = c.model.find(h.id) orelse return;
                const path = if (job.destination.len > 0) job.destination.slice() else home();
                c.openWindow(path, job.id);
                return self.output.closeTransfers();
            },
            // Files opens the download as a folder, to tick its files.
            .choose => {
                const job = c.model.find(h.id) orelse return;
                const path = if (job.destination.len > 0) job.destination.slice() else home();
                c.openWindow(path, job.id);
                return self.output.closeTransfers();
            },
            // Stopping a seeding download is pausing it: it then completes.
            .stop_seeding => c.control(.pause, h.id),
            .destination => {
                const job = c.model.find(h.id) orelse return;
                if (job.destination.len == 0) return;
                c.openWindow(job.destination.slice(), null);
                return self.output.closeTransfers();
            },
            .done_row, .show => {
                for (c.model.doneJobs()) |job| if (job.id == h.id and job.destination.len > 0) {
                    c.openWindow(job.destination.slice(), null);
                    return self.output.closeTransfers();
                };
            },
            .open_files => {
                c.openWindow(home(), null);
                return self.output.closeTransfers();
            },
            // Clearing may hide the item, which closes this panel.
            .clear_done => return c.clearDone(),
        }
        self.refresh();
    }

    pub fn addHit(self: *Popup, box: Rect, focus: Focus, id: u64) button.State {
        const i = self.hit_count;
        if (i == self.hits.len) return .{};
        self.hits[i] = .{ .box = box, .focus = focus, .id = id };
        self.hit_count += 1;
        return .{ .focused = self.focus == focus and self.focus_id == id, .pointer = if (self.hover == i) .hover else .idle };
    }

    pub fn refresh(self: *Popup) void {
        const bar = self.output.taskbar orelse return;
        const anchor = bar.itemBox(.transfers) orelse return;
        const c = self.client() orelse return;
        const model = &c.model;
        var output_box: wlr.Box = undefined;
        self.output.server.output_layout.getBox(self.output.wlr_output, &output_box);
        const room = @as(f32, @floatFromInt(@max(1, output_box.height - @import("../Taskbar.zig").barHeight() - 24)));
        self.factor = @min(1, @min(@as(f32, @floatFromInt(@max(1, output_box.width - 24))) / width, room / 240));
        const live = model.liveJobs();
        self.list_top = header + (if (live.len > 0) graph_height else 0);
        self.content_height = rows.contentHeight(self, model);
        self.height = @min(self.list_top + self.content_height + footer, @max(240, room / self.factor));
        self.scroll = std.math.clamp(self.scroll, 0, self.maxScroll());
        const w: i32 = @intFromFloat(@round(width * self.factor));
        const h: i32 = @intFromFloat(@round(self.height * self.factor));
        const left = std.math.clamp(anchor.x + @divTrunc(anchor.width - w, 2), output_box.x + 12, @max(output_box.x + 12, output_box.x + output_box.width - w - 12));
        self.panel_box = .{ .x = left, .y = self.output.taskbarPopupY(h, 12), .width = w, .height = h };
        const scale = self.output.wlr_output.scale;
        const buf = PanelBuffer.create(w, h, scale) catch return;
        defer buf.base.drop();
        var r: paint.Renderer = .{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = scale * self.factor };
        const t = theme.shellPalette();
        r.palette = t;
        const tip = std.math.clamp(@as(f32, @floatFromInt(anchor.x + @divTrunc(anchor.width, 2) - left)) / self.factor, 24, width - 24);
        popup_style.background(&r, buf, width, self.height, 12, tip, self.output.server.config.compositor.taskbar_position == .top);
        self.hit_count = 0;
        const summary = model.summary();
        self.paintHeader(&r, summary);
        if (live.len > 0) rows.paintTotal(&r, model);
        r.clip = .{ .x = 8, .y = self.list_top, .w = width - 16, .h = self.height - self.list_top - footer };
        rows.paintList(self, &r, model);
        r.clip = null;
        const viewport = self.height - self.list_top - footer;
        const strip = scrollbar.gutter(theme.global.scrollbar_width);
        if (scrollbar.Geometry.compute(.vertical, .{ .x = width - strip, .y = self.list_top, .w = strip, .h = viewport }, viewport, self.content_height, self.scroll)) |geometry|
            scrollbar.paint(&r, scrollbar.look(geometry, .{}, theme.global.scrollbar_width, t));
        self.paintFooter(&r, model);
        self.buffer_node.setBuffer(&buf.base);
        self.buffer_node.setDestSize(w, h);
        present.applySlide(self.buffer_node, self.panel_box, self.slide.value(anim.nowMs()), self.slideDistance());
        popup_style.configureGlass(&self.glass_effect, self.output.server.glass_engine, self.buffer_node, self.factor);
        self.output.wlr_output.scheduleFrame();
    }

    pub fn paintHeader(self: *Popup, r: *paint.Renderer, s: model_mod.Summary) void {
        const t = r.palette.?;
        const title = i18n.tr("Transfers");
        r.drawText(24, 14, 200, 38, .{ .content = title, .font_size = 21, .color = t.window_fg, .weight = 700 });
        const title_w = r.textWidth(.{ .content = title, .font_size = 21, .weight = 700, .color = t.window_fg });
        var count_buf: [64]u8 = undefined;
        const count = if (s.active == 0 and s.seeding == 0)
            i18n.tr("Idle")
        else if (s.active == 0)
            i18n.fmt(&count_buf, i18n.tr("{count} seeding"), .{ .count = s.seeding }) catch ""
        else
            i18n.fmt(&count_buf, i18n.tr("{count} active"), .{ .count = s.active }) catch "";
        r.drawText(24 + title_w + 10, 17, 140, 34, .{ .content = count, .font_size = 12, .color = t.window_dim, .family = .mono });
        if (s.active > 0) {
            const resume_all = s.all_paused;
            const box: Rect = .{ .x = width - 24 - 120, .y = 16, .w = 120, .h = 32 };
            button.paint(r, box, .{ .variant = .ghost, .size = .sm, .label = if (resume_all) i18n.tr("Resume all") else i18n.tr("Pause all"), .leading_icon = if (resume_all) .play else .pause }, self.addHit(box, .pause_all, 0));
        }
        r.fillRect(20, header - 1, width - 40, 1, .{ .color = t.border });
    }

    pub fn paintFooter(self: *Popup, r: *paint.Renderer, model: *const model_mod.Model) void {
        const t = r.palette.?;
        const top = self.height - footer;
        r.fillRect(20, top + 2, width - 40, 1, .{ .color = t.border });
        const files_box: Rect = .{ .x = 22, .y = top + 10, .w = 150, .h = 40 };
        button.paint(r, files_box, .{ .variant = .ghost, .leading_icon = .folder, .label = i18n.tr("Open Files"), .alignment = .left }, self.addHit(files_box, .open_files, 0));
        const done = model.doneJobs().len;
        if (done == 0) return;
        var label_buf: [64]u8 = undefined;
        const label = i18n.fmt(&label_buf, i18n.tr("Clear finished ({count})"), .{ .count = done }) catch "";
        const clear_box: Rect = .{ .x = width - 22 - 176, .y = top + 10, .w = 176, .h = 40 };
        button.paint(r, clear_box, .{ .variant = .ghost, .leading_icon = .trash, .label = label }, self.addHit(clear_box, .clear_done, 0));
    }
};

/// `$HOME`, where Files opens without a better place.
pub fn home() []const u8 {
    return if (std.c.getenv("HOME")) |value| std.mem.span(value) else "/";
}

comptime {
    _ = glyphs;
}
