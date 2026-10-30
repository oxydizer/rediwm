//! Battery details from the taskbar snapshot; no hardware reads or timers here.
const i18n = @import("i18n");
const std = @import("std");
const popup_style = @import("popup_style.zig");
const glass = @import("glass.zig");
const wlr = @import("wlroots");
const sn = @import("node.zig");
const Output = @import("Output.zig");
const gpa = @import("main.zig").gpa;
const scene = @import("scene_data.zig");
const PanelBuffer = @import("panel_buffer.zig").PanelBuffer;
const paint = @import("ui").paint;
const theme = @import("ui").theme;
const checkbox = @import("ui").widgets.checkbox;
const Profile = @import("power_profiles.zig").Profile;
const anim = @import("ui").anim;
const panel_present = @import("panel_present.zig");
const Anim = anim.Anim;
const slide_distance: f32 = 20;

pub const Popup = struct {
    output: *Output,
    buffer_node: *sn.Buffer,
    node_data: scene.SceneData = undefined,
    glass_effect: ?*glass.Effect = null,
    factor: f32 = 1,
    slide: Anim = .{},
    panel_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    focused: ?usize = null,
    settings_button: @import("ui").layout.Widget = .{ .kind = .container },

    pub fn create(output: *Output) !*Popup {
        const self = try gpa.create(Popup);
        errdefer gpa.destroy(self);
        const node = try output.server.overlay_tree.createSceneBuffer(null);
        self.* = .{ .output = output, .buffer_node = node };
        self.node_data = .{ .role = .{ .battery_popup = self } };
        self.slide.retargetTo(anim.nowMs(), 1, anim.curveFor(.panel_slide));
        scene.SceneData.attach(&self.node_data, &node.node);
        node.setFilterMode(.bilinear);
        self.refresh();
        return self;
    }

    pub fn tick(self: *Popup, now_ms: i64) bool {
        _ = self.slide.sampleChanged(now_ms, anim.quantum_alpha);
        const t = self.slide.value(now_ms);
        panel_present.applySlide(self.buffer_node, self.panel_box, t, if (self.output.server.config.compositor.taskbar_position == .top) -slide_distance else slide_distance);
        popup_style.configureGlass(&self.glass_effect, self.output.server.glass_engine, self.buffer_node, self.factor);
        return !self.slide.settled(now_ms);
    }

    pub fn destroy(self: *Popup) void {
        if (self.output.server.input.open_battery == self) self.output.server.input.open_battery = null;
        self.buffer_node.node.destroy();
        gpa.destroy(self);
    }

    pub fn press(self: *Popup, sx: f64, sy: f64) void {
        const x = sx / self.factor;
        const y = sy / self.factor;
        if (@import("ui").input.hitTest(&self.settings_button, @floatCast(x), @floatCast(y)) != null) {
            self.openSettings();
            return;
        }
        if (x < 20 or x >= 348 or y < 366 or y >= 462) return;
        self.focused = @intFromFloat(@floor((y - 366) / 32));
        self.activate();
        self.refresh();
    }

    pub fn navigate(self: *Popup, backwards: bool) void {
        self.focused = if (self.focused) |f| (f + (if (backwards) @as(usize, 3) else 1)) % 4 else if (backwards) 3 else 0;
        self.refresh();
    }

    pub fn activate(self: *Popup) void {
        const index = self.focused orelse return;
        if (index == 3) return self.openSettings();
        if (self.output.server.power_profiles) |manager| manager.select(@fromBackingInt(@intCast(index)));
    }

    fn openSettings(self: *Popup) void {
        const output = self.output;
        const cc = output.server.input.open_control_center orelse (@import("control_center/ControlCenter.zig").create(output.server, output.wlr_output) catch return);
        cc.selectPage(.power);
        output.server.world.focus(cc.toplevel);
        output.closeBattery();
    }

    pub fn refresh(self: *Popup) void {
        const bar = self.output.taskbar orelse return;
        const anchor = bar.itemBox(.battery) orelse return;
        var box: wlr.Box = undefined;
        self.output.server.output_layout.getBox(self.output.wlr_output, &box);
        const available_h = @max(1, box.height - @import("Taskbar.zig").reservedHeight() - 24);
        self.factor = @min(1, @min(@as(f32, @floatFromInt(@max(1, box.width - 24))) / 368, @as(f32, @floatFromInt(available_h)) / 536));
        const width: i32 = @max(1, @as(i32, @intFromFloat(@round(368 * self.factor))));
        const height: i32 = @max(1, @as(i32, @intFromFloat(@round(536 * self.factor))));
        const left = std.math.clamp(anchor.x + @divTrunc(anchor.width, 2) - @divTrunc(width, 2), box.x + 12, @max(box.x + 12, box.x + box.width - width - 12));
        const tip = std.math.clamp(@as(f32, @floatFromInt(anchor.x + @divTrunc(anchor.width, 2) - left)) / self.factor, 24, 344);
        const scale = self.output.wlr_output.scale;
        const buf = PanelBuffer.create(width, height, scale) catch return;
        defer buf.base.drop();
        var r: paint.Renderer = .{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = scale * self.factor };
        const t = theme.shellPalette();
        r.palette = t;
        popup_style.background(&r, buf, 368, 536, 16, tip, self.output.server.config.compositor.taskbar_position == .top);
        const card_t = popup_style.cardPalette(t);
        const state = bar.battery_state;
        var pct: [16]u8 = undefined;
        const percent = if (state.percent) |p| std.fmt.bufPrint(&pct, "{d}%", .{p}) catch "" else "—";
        label(&r, 24, 16, 100, 38, percent, 27, t.window_fg, true);
        var estimate_buf: [192]u8 = undefined;
        const estimate = state.estimate(&estimate_buf);
        label(&r, 125, if (estimate != null) 14 else 18, 220, if (estimate != null) 24 else 36, state.status(), 16, t.window_dim, false);
        if (estimate) |value| label(&r, 125, 38, 220, 20, value, 12, t.window_dim, false);
        r.fillRect(20, 66, 328, 1, .{ .color = t.border });
        ring(&r, state.percent orelse 0);
        centered(&r, 136, 52, percent, 36, t.window_fg, true);
        centered(&r, 190, 28, state.status(), 14, t.window_dim, false);
        var health: [16]u8 = undefined;
        var capacity: [24]u8 = undefined;
        var cycles: [16]u8 = undefined;
        const values = [_][]const u8{
            if (state.health) |h| std.fmt.bufPrint(&health, "{d}%", .{h}) catch "" else i18n.tr("Unavailable"),
            if (state.full_wh) |wh| std.fmt.bufPrint(&capacity, "{d:.1} Wh", .{wh}) catch "" else i18n.tr("Unavailable"),
            if (state.cycles) |c| std.fmt.bufPrint(&cycles, "{d}", .{c}) catch "" else i18n.tr("Unavailable"),
        };
        for ([_][]const u8{ i18n.tr("Health"), i18n.tr("Full capacity"), i18n.tr("Cycles") }, values, 0..) |name, value, i| {
            const x: f32 = 20 + @as(f32, @floatFromInt(i)) * 112;
            if (t.popup_card_bg != null) popup_style.card(&r, x, 274, 104, 70) else r.fillRect(x, 274, 104, 70, .{ .color = t.surface_hover, .radius = 9 });
            label(&r, x + 10, 284, 90, 22, name, 12, card_t.window_dim, false);
            label(&r, x + 10, 307, 90, 28, value, if (std.mem.eql(u8, value, i18n.tr("Unavailable"))) 11 else 19, card_t.window_fg, true);
        }
        r.fillRect(20, 356, 328, 1, .{ .color = t.border });
        if (t.popup_card_bg != null) popup_style.card(&r, 20, 366, 328, 96);
        r.palette = card_t;
        const manager = self.output.server.power_profiles;
        const service_up = if (manager) |m| m.isAvailable() else false;
        if (!service_up) {
            label(&r, 28, 378, 310, 28, i18n.tr("Power profiles unavailable"), t.font_size, card_t.fg, true);
            label(&r, 28, 408, 310, 40, i18n.tr("No power profile service is running."), t.font_size - 1, card_t.faint, false);
        }
        for (0..if (service_up) 3 else 0) |i| {
            const profile: Profile = @fromBackingInt(@intCast(i));
            const enabled = if (manager) |m| m.supports(profile) else false;
            const selected = if (manager) |m| m.active == profile else false;
            const y: f32 = 366 + @as(f32, @floatFromInt(i)) * 32;
            if (self.focused == i) {
                const inset: f32 = if (t.popup_card_bg != null) 4 else 0;
                r.fillRect(20 + inset, y + inset, 328 - 2 * inset, 32 - 2 * inset, .{ .color = card_t.surface_hover, .radius = if (t.popup_card_bg != null) t.popup_card_radius else 5 });
            }
            if (selected) {
                checkbox.paint(&r, .{ .x = 28, .y = y, .w = 310, .h = 32 }, profile.label(), .{ .checked = true, .disabled = !enabled });
            } else {
                label(&r, 28 + checkbox.box_size + checkbox.gap, y, 282, 32, profile.label(), t.font_size, if (enabled) card_t.fg else card_t.faint, false);
            }
        }
        self.settings_button = .{ .name = "power_settings", .kind = .{ .button = .{ .label = i18n.tr("Power & Battery settings"), .state = if (self.focused == 3) .hover else .idle } }, .computed_x = 20, .computed_y = 474, .computed_width = 328, .computed_height = 36 };
        paint.paint(&self.settings_button, &r);
        self.buffer_node.setBuffer(&buf.base);
        self.buffer_node.setDestSize(width, height);
        self.panel_box = .{ .x = left, .y = self.output.taskbarPopupY(height, 12), .width = width, .height = height };
        self.buffer_node.node.setPosition(left, self.panel_box.y + panel_present.slideOffset(self.slide.value(anim.nowMs()), if (self.output.server.config.compositor.taskbar_position == .top) -slide_distance else slide_distance));
        popup_style.configureGlass(&self.glass_effect, self.output.server.glass_engine, self.buffer_node, self.factor);
        self.output.wlr_output.scheduleFrame();
    }
};

fn label(r: *paint.Renderer, x: f32, y: f32, w: f32, h: f32, value: []const u8, size: f32, color: [4]f32, bold: bool) void {
    r.drawText(x, y, w, h, .{ .content = value, .font_size = size, .color = color, .weight = if (bold) 700 else 400 });
}

fn centered(r: *paint.Renderer, y: f32, h: f32, value: []const u8, size: f32, color: [4]f32, bold: bool) void {
    const width = @import("ui").text.measureWidthF(value, if (bold) .manrope_bold else .manrope, size, r.scale) catch 0;
    label(r, (368 - width) / 2, y, width + 1, h, value, size, color, bold);
}

fn ring(r: *paint.Renderer, percent: u8) void {
    const color = if (percent <= 10) theme.global.danger else if (theme.global.popup_battery_ring) |color| color else if (percent <= 25) [4]f32{ 0.98, 0.8, 0.25, 1 } else [4]f32{ 32.0 / 255.0, 226.0 / 255.0, 157.0 / 255.0, 1 };
    for (0..@intCast(r.height)) |iy| {
        const y = (@as(f32, @floatFromInt(iy)) + 0.5) / r.scale - 168;
        if (@abs(y) > 96) continue;
        for (0..@intCast(r.width)) |ix| {
            const x = (@as(f32, @floatFromInt(ix)) + 0.5) / r.scale - 184;
            const distance = @abs(@sqrt(x * x + y * y) - 82) - 5;
            if (distance > 9) continue;
            const pixel = &r.pixels[iy * @as(usize, @intCast(r.width)) + ix];
            const coverage = std.math.clamp(0.5 - distance * r.scale, 0, 1);
            paint.blendPixel(pixel, .{ .r = 1, .g = 1, .b = 1, .a = 0.08 }, coverage);
            const angle = @mod(std.math.atan2(y, x) + std.math.pi / 2.0, 2 * std.math.pi);
            if (percent == 0 or angle > @as(f32, @floatFromInt(percent)) / 100 * (2 * std.math.pi)) continue;
            paint.blendPixel(pixel, .{ .r = color[0], .g = color[1], .b = color[2], .a = 0.12 }, std.math.clamp(1 - @max(0, distance) / 9, 0, 1));
            paint.blendPixel(pixel, .{ .r = color[0], .g = color[1], .b = color[2], .a = 1 }, coverage);
        }
    }
}
