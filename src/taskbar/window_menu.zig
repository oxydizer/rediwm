//! The taskbar's window actions. Input owns one menu across all outputs.
const std = @import("std");
const wlr = @import("wlroots");
const Taskbar = @import("../Taskbar.zig");
const Toplevel = @import("../Toplevel.zig");
const Output = @import("../Output.zig");
const Buffer = @import("../panel_buffer.zig").PanelBuffer;
const ui = @import("ui");

pub const Menu = struct {
    bar: ?*Taskbar = null,
    target: ?*Toplevel = null,
    node: ?*wlr.SceneBuffer = null,
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    selected: ?usize = null,

    const padding = 6;
    const row_height = 32;
    const separator = 7;
    const height = padding * 2 + row_height * 2 + separator;
    const labels = [_][]const u8{ "Close", "Force Close" };

    pub fn open(self: *Menu, bar: *Taskbar, target: *Toplevel, x: i32) void {
        self.close();
        const output = Output.fromWlr(bar.wlr_output) orelse return;
        const input = &bar.server.input;
        if (input.open_start_menu) |other| if (Output.fromWlr(other.wlr_output)) |out| out.closeStartMenu();
        if (input.open_power_menu) |other| if (Output.fromWlr(other.wlr_output)) |out| out.closePowerMenu();
        if (input.open_wifi) |other| other.output.closeWifi();
        if (input.open_battery) |other| other.output.closeBattery();
        if (input.open_calendar) |other| other.output.closeCalendar();
        if (bar.server.tray) |tray| tray.closeMenu();
        const bounds = output.usableBox();
        const width = @min(216, bounds.width);
        self.node = bar.server.overlay_tree.createSceneBuffer(null) catch return;
        self.bar = bar;
        self.target = target;
        self.box = .{
            .x = std.math.clamp(x, bounds.x, bounds.x + bounds.width - width),
            .y = output.taskbarPopupY(height, 4),
            .width = width,
            .height = height,
        };
        bar.pointerLeave();
        input.hovered_taskbar = null;
        input.seat.pointerClearFocus();
        input.setDefaultCursor();
        input.pointer_constraints.sync();
        self.paint();
    }

    pub fn close(self: *Menu) void {
        if (self.node) |node| node.node.destroy();
        self.* = .{};
    }

    fn rowY(index: usize) i32 {
        return padding + @as(i32, @intCast(index)) * (row_height + separator);
    }

    fn hit(self: *const Menu, x: f64, y: f64) ?usize {
        const lx = x - @as(f64, @floatFromInt(self.box.x));
        const ly = y - @as(f64, @floatFromInt(self.box.y));
        if (lx < padding or lx >= @as(f64, @floatFromInt(self.box.width - padding))) return null;
        for (0..labels.len) |i| {
            const top: f64 = @floatFromInt(rowY(i));
            if (ly >= top and ly < top + row_height) return i;
        }
        return null;
    }

    pub fn motion(self: *Menu, x: f64, y: f64) void {
        const next = self.hit(x, y);
        if (self.selected == next) return;
        self.selected = next;
        self.paint();
    }

    pub fn press(self: *Menu, x: f64, y: f64, button: u32) void {
        if (x < @as(f64, @floatFromInt(self.box.x)) or x >= @as(f64, @floatFromInt(self.box.x + self.box.width)) or
            y < @as(f64, @floatFromInt(self.box.y)) or y >= @as(f64, @floatFromInt(self.box.y + self.box.height)))
        {
            self.close();
            return;
        }
        if (button != 0x110) return;
        self.selected = self.hit(x, y);
        self.activate();
    }

    pub fn key(self: *Menu, sym: u32) void {
        switch (sym) {
            0xff1b => self.close(), // Escape
            0xff0d, 0xff8d, 0x20 => self.activate(), // Return, keypad Enter, Space
            0xff52, 0xff54 => { // Up / Down skip the separator.
                self.selected = if (self.selected) |i| 1 - i else if (sym == 0xff54) 0 else 1;
                self.paint();
            },
            else => {},
        }
    }

    fn activate(self: *Menu) void {
        const index = self.selected orelse return;
        const target = self.target orelse return;
        // Shell windows can destroy themselves synchronously when closed.
        self.close();
        if (index == 0) target.sendClose() else target.forceClose();
    }

    fn paint(self: *Menu) void {
        const bar = self.bar orelse return;
        const node = self.node orelse return;
        const scale = bar.wlr_output.scale;
        const buf = Buffer.create(self.box.width, self.box.height, scale) catch return;
        defer buf.base.drop();
        var renderer = ui.paint.Renderer.init(buf.pixels, buf.width, buf.height, scale);
        const t = ui.theme.global;
        const width: f32 = @floatFromInt(self.box.width);
        renderer.fillRect(0, 0, width, height, .{ .color = t.window_bg, .radius = 12, .border_width = 1, .border_color = t.border });
        renderer.fillRect(12, padding + row_height + 3, @max(0, width - 24), 1, .{ .color = t.border_soft });
        for (labels, 0..) |label, i| {
            const y: f32 = @floatFromInt(rowY(i));
            const row: ui.layout.Widget = .{
                .kind = .{ .row = .{ .state = if (self.selected == i) .hover else .idle } },
                .computed_x = padding,
                .computed_y = y,
                .computed_width = @max(0, width - 2 * padding),
                .computed_height = row_height,
            };
            ui.paint.paint(&row, &renderer);
            renderer.drawText(18, y, @max(0, width - 36), row_height, .{ .content = label, .font_size = t.font_size, .color = if (i == 1) t.danger else t.window_fg });
        }
        node.setBuffer(&buf.base);
        node.setDestSize(self.box.width, self.box.height);
        node.setFilterMode(.bilinear);
        node.node.setPosition(self.box.x, self.box.y);
        node.node.raiseToTop();
    }
};
