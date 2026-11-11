//! The taskbar's window actions, and the input source list its keyboard
//! layout item opens. Input owns one menu across all outputs.
const i18n = @import("i18n");
const std = @import("std");
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const Taskbar = @import("../Taskbar.zig");
const Toplevel = @import("../Toplevel.zig");
const Output = @import("../Output.zig");
const Dock = @import("../Dock.zig");
const Buffer = @import("../panel_buffer.zig").PanelBuffer;
const ui = @import("ui");
const gpa = @import("../main.zig").gpa;

pub const Menu = struct {
    bar: ?*Taskbar = null,
    output: ?*Output = null,
    dock: ?*Dock = null,
    shortcut: ?Dock.Shortcut = null,
    target: ?*Toplevel = null,
    /// The pinned app a dock button stands for, copied: the dock's own strings
    /// are replaced by a rebuild while the menu is open.
    pin_bytes: [512]u8 = undefined,
    pin_len: usize = 0,
    pinned: bool = false,
    node: ?*sn.Buffer = null,
    box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    selected: ?usize = null,
    close_hover: ?usize = null,
    window_ids: []u64 = &.{},
    first_row: usize = 0,
    visible_rows: usize = 0,
    picker_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    picker_root: ui.layout.Widget = .{ .kind = .container },
    /// The input source list (`openSources`): one row per source, then Settings.
    sources: bool = false,
    source_count: usize = 0,
    anchor_x: i32 = 0,

    const padding = 6;
    const row_height = 32;
    const separator = 7;
    const Action = enum {
        close,
        force_close,
        remove,
        unpin,

        fn label(action: Action) []const u8 {
            return switch (action) {
                .close => i18n.tr("Close"),
                .force_close => i18n.tr("Force Close"),
                .remove => i18n.tr("Remove from dock"),
                .unpin => i18n.tr("Unpin from dock"),
            };
        }
    };

    fn actions(self: *const Menu) []const Action {
        if (self.pinned) return if (self.target == null) &.{.unpin} else &.{ .close, .force_close, .unpin };
        // Only a shortcut can be removed; a running app always stays.
        if (self.shortcut != null and self.dock != null) return if (self.target == null) &.{.remove} else &.{ .close, .force_close, .remove };
        return &.{ .close, .force_close };
    }

    pub fn open(self: *Menu, bar: *Taskbar, target: *Toplevel, x: i32) void {
        const output = Output.fromWlr(bar.wlr_output) orelse return;
        self.openOn(output, bar, null, target, null, null, x, 0, &.{}, 0);
    }

    /// The input sources, anchored above (or below) the taskbar item at `x`.
    pub fn openSources(self: *Menu, bar: *Taskbar, x: i32) void {
        const sources = bar.server.input_sources orelse return;
        const output = Output.fromWlr(bar.wlr_output) orelse return;
        if (self.sources and self.node != null and self.bar == bar) {
            self.close();
            return;
        }
        self.openOn(output, bar, null, null, null, null, x - 140 + @divTrunc(Taskbar.trayHit(), 2), 0, &.{}, sources.sources().len);
        self.anchor_x = x;
    }

    /// The list or the active source changed while it is open.
    pub fn sourcesChanged(self: *Menu) void {
        if (!self.sources or self.node == null) return;
        const bar = self.bar orelse return;
        const count = if (bar.server.input_sources) |s| s.sources().len else 0;
        if (count != self.source_count) {
            // A new height; open again in place, keeping the keyboard selection.
            const selected = self.selected;
            const x = self.anchor_x;
            self.close();
            self.openSources(bar, x);
            if (selected) |i| if (i < self.itemCount()) {
                self.selected = i;
                self.paint();
            };
            return;
        }
        self.paint();
    }

    pub fn openDock(self: *Menu, dock: *Dock, target: ?*Toplevel, shortcut: ?Dock.Shortcut, pin: ?[]const u8, x: i32, y: i32) void {
        self.openOn(dock.output orelse return, null, dock, target, shortcut, pin, x, y, &.{}, 0);
    }

    pub fn openDockWindows(self: *Menu, dock: *Dock, ids: []const u64, shortcut: ?Dock.Shortcut, x: i32, y: i32) void {
        self.openOn(dock.output orelse return, null, dock, null, shortcut, null, x, y, ids, 0);
    }

    /// `sources` > 0 opens the input source list with that many sources.
    fn openOn(self: *Menu, output: *Output, bar: ?*Taskbar, dock: ?*Dock, target: ?*Toplevel, shortcut: ?Dock.Shortcut, pin: ?[]const u8, x: i32, pointer_y: i32, ids: []const u64, sources: usize) void {
        self.close();
        self.sources = sources > 0;
        self.source_count = sources;
        const server = output.server;
        const input = &server.input;
        if (input.open_start_menu) |other| if (Output.fromWlr(other.wlr_output)) |out| out.closeStartMenu();
        if (input.open_power_menu) |other| if (Output.fromWlr(other.wlr_output)) |out| out.closePowerMenu();
        if (input.open_wifi) |other| other.output.closeWifi();
        if (input.open_battery) |other| other.output.closeBattery();
        if (input.open_calendar) |other| other.output.closeCalendar();
        if (server.tray) |tray| tray.closeMenu();
        const bounds = output.dockAreaBox();
        const width = @min(if (ids.len > 0) @as(i32, 360) else if (self.sources) @as(i32, 280) else 216, bounds.width);
        self.node = server.overlay_tree.createSceneBuffer(null) catch return;
        if (ids.len > 0) self.window_ids = gpa.dupe(u64, ids) catch {
            self.close();
            return;
        };
        self.bar = bar;
        self.output = output;
        self.dock = dock;
        self.shortcut = shortcut;
        self.target = target;
        if (pin) |id| {
            self.pin_len = @min(id.len, self.pin_bytes.len);
            @memcpy(self.pin_bytes[0..self.pin_len], id[0..self.pin_len]);
            self.pinned = true;
        }
        const available_height = if (dock) |d| switch (d.position) {
            .top => bounds.y + bounds.height - d.box.y - d.box.height - 4,
            .bottom => d.box.y - bounds.y - 4,
            .left, .right => bounds.height,
        } else bounds.height;
        const capacity: usize = @intCast(@max(1, @divTrunc(available_height - 2 * padding + self.rowGap(), self.rowHeight() + self.rowGap())));
        self.visible_rows = if (ids.len > 0) @min(self.itemCount(), capacity) else self.itemCount();
        const count: i32 = @intCast(self.visible_rows);
        const height = padding * 2 + self.rowHeight() * count + self.rowGap() * (count - 1);
        var menu_x = if (ids.len > 0) x - @divTrunc(width, 2) else x;
        var y = output.taskbarPopupY(height, 4);
        if (dock) |d| switch (d.position) {
            .top => y = d.box.y + d.box.height + 4,
            .bottom => y = d.box.y - height - 4,
            .left => {
                menu_x = d.box.x + d.box.width + 4;
                y = pointer_y;
            },
            .right => {
                menu_x = d.box.x - width - 4;
                y = pointer_y;
            },
        };
        self.box = .{
            .x = std.math.clamp(menu_x, bounds.x, bounds.x + bounds.width - width),
            .y = std.math.clamp(y, bounds.y, @max(bounds.y, bounds.y + bounds.height - height)),
            .width = width,
            .height = height,
        };
        if (bar) |b| b.pointerLeave();
        if (dock) |d| d.leave();
        input.hovered_taskbar = null;
        input.seat.pointerClearFocus();
        input.setDefaultCursor();
        input.pointer_constraints.sync();
        self.paint();
    }

    pub fn close(self: *Menu) void {
        const was_sources = self.sources and self.node != null;
        const bar = self.bar;
        if (self.node) |node| node.node.destroy();
        gpa.free(self.window_ids);
        self.picker_arena.deinit();
        self.* = .{};
        if (was_sources) if (bar) |b| {
            b.tray_dirty[@backingInt(Taskbar.TrayKind.input_source)] = true;
            b.markDirty(Taskbar.paint_tray);
            b.wlr_output.scheduleFrame();
        };
    }

    pub fn references(self: *const Menu, top: *Toplevel) bool {
        return self.target == top or std.mem.indexOfScalar(u64, self.window_ids, top.id) != null;
    }

    pub fn iconsReady(self: *Menu) void {
        if (self.node != null and self.window_ids.len > 0) self.paint();
    }

    fn rowHeight(self: *const Menu) i32 {
        return if (self.window_ids.len > 0) 40 else row_height;
    }

    fn rowGap(self: *const Menu) i32 {
        return if (self.window_ids.len > 0 or self.sources) 2 else separator;
    }

    fn itemCount(self: *const Menu) usize {
        if (self.sources) return self.source_count + 1;
        return if (self.window_ids.len > 0) self.window_ids.len else self.actions().len;
    }

    fn rowY(self: *const Menu, index: usize) i32 {
        return padding + @as(i32, @intCast(index - self.first_row)) * (self.rowHeight() + self.rowGap());
    }

    fn hit(self: *const Menu, x: f64, y: f64) ?usize {
        const lx = x - @as(f64, @floatFromInt(self.box.x));
        const ly = y - @as(f64, @floatFromInt(self.box.y));
        if (lx < padding or lx >= @as(f64, @floatFromInt(self.box.width - padding))) return null;
        for (self.first_row..self.first_row + self.visible_rows) |i| {
            const top: f64 = @floatFromInt(self.rowY(i));
            if (ly >= top and ly < top + @as(f64, @floatFromInt(self.rowHeight()))) return i;
        }
        return null;
    }

    pub fn motion(self: *Menu, x: f64, y: f64) void {
        const next = self.hit(x, y);
        const close_hover = if (self.closeButtonAt(x, y)) |button| button.kind.button.id else null;
        if (self.selected == next and self.close_hover == close_hover) return;
        self.selected = next;
        self.close_hover = close_hover;
        self.paint();
    }

    fn closeButtonAt(self: *Menu, x: f64, y: f64) ?*ui.layout.Widget {
        if (self.window_ids.len == 0) return null;
        const widget = ui.input.hitTest(&self.picker_root, @floatCast(x - @as(f64, @floatFromInt(self.box.x))), @floatCast(y - @as(f64, @floatFromInt(self.box.y)))) orelse return null;
        return if (widget.kind == .button) widget else null;
    }

    fn closeWindow(owner: ?*anyopaque, index: usize) void {
        const self: *Menu = @ptrCast(@alignCast(owner orelse return));
        const top = self.findWindow(self.window_ids[index]);
        // Shell windows can destroy themselves synchronously when closed.
        self.close();
        if (top) |t| t.sendClose();
    }

    pub fn press(self: *Menu, x: f64, y: f64, button: u32) void {
        if (x < @as(f64, @floatFromInt(self.box.x)) or x >= @as(f64, @floatFromInt(self.box.x + self.box.width)) or
            y < @as(f64, @floatFromInt(self.box.y)) or y >= @as(f64, @floatFromInt(self.box.y + self.box.height)))
        {
            self.close();
            return;
        }
        if (button != 0x110) return;
        if (self.closeButtonAt(x, y)) |close_button| {
            ui.widgets.button.press(close_button);
            return;
        }
        self.selected = self.hit(x, y);
        self.activate();
    }

    pub fn key(self: *Menu, sym: u32) void {
        switch (sym) {
            0xff1b => self.close(), // Escape
            0xff0d, 0xff8d, 0x20 => self.activate(), // Return, keypad Enter, Space
            0xff52, 0xff54 => { // Up / Down skip the separator.
                self.close_hover = null;
                const count = self.itemCount();
                self.selected = if (self.selected) |i| (i + if (sym == 0xff54) @as(usize, 1) else count - 1) % count else if (sym == 0xff54) 0 else count - 1;
                if (self.selected.? < self.first_row) self.first_row = self.selected.?;
                if (self.selected.? >= self.first_row + self.visible_rows) self.first_row = self.selected.? + 1 - self.visible_rows;
                self.paint();
            },
            else => {},
        }
    }

    pub fn scroll(self: *Menu, delta: f32) void {
        if (self.window_ids.len == 0 or delta == 0) return;
        const next = if (delta > 0) @min(self.first_row + 1, self.itemCount() - self.visible_rows) else self.first_row -| 1;
        if (next == self.first_row) return;
        self.first_row = next;
        self.selected = null;
        self.close_hover = null;
        self.paint();
    }

    fn findWindow(self: *const Menu, id: u64) ?*Toplevel {
        const output = self.output orelse return null;
        var it = output.server.world.toplevels.iterator(.forward);
        while (it.next()) |top| if (top.id == id and top.in_world and !top.backend_gone and !top.closing) return top;
        return null;
    }

    fn activate(self: *Menu) void {
        const index = self.selected orelse return;
        if (self.sources) {
            const output = self.output.?;
            const count = self.source_count;
            self.close();
            if (index < count) {
                if (output.server.input_sources) |sources| _ = sources.select(index);
            } else output.openInputSettings();
            return;
        }
        if (self.window_ids.len > 0) {
            const top = self.findWindow(self.window_ids[index]);
            const output = self.output.?;
            // Closing the menu precedes focus callbacks and any dock rebuild.
            self.close();
            if (top) |t| {
                if (t.minimized) t.restore() else output.server.world.focus(t);
                output.server.world.navigateTo(t, output);
            }
            return;
        }
        const action = self.actions()[index];
        const target = self.target;
        const dock = self.dock;
        const shortcut = self.shortcut;
        const pin_bytes = self.pin_bytes;
        const pin = pin_bytes[0..self.pin_len];
        // Shell windows can destroy themselves synchronously when closed.
        self.close();
        switch (action) {
            .close => if (target) |t| t.sendClose(),
            .force_close => if (target) |t| t.forceClose(),
            .remove => if (dock) |d| if (shortcut) |s| d.removeShortcut(s),
            .unpin => if (dock) |d| d.unpinApp(pin),
        }
    }

    fn paint(self: *Menu) void {
        const output = self.output orelse return;
        const node = self.node orelse return;
        const scale = output.wlr_output.scale;
        const buf = Buffer.create(self.box.width, self.box.height, scale) catch return;
        defer buf.base.drop();
        var renderer = ui.paint.Renderer.init(buf.pixels, buf.width, buf.height, scale);
        const t = if (self.window_ids.len > 0) ui.theme.shellPalette() else ui.theme.global;
        renderer.palette = t;
        const width: f32 = @floatFromInt(self.box.width);
        renderer.fillRect(0, 0, width, @floatFromInt(self.box.height), .{ .color = if (self.window_ids.len > 0) t.start_menu_bg else t.window_bg, .radius = 12, .border_width = 1, .border_color = t.border });
        if (self.sources) self.paintSources(&renderer) else if (self.window_ids.len > 0) self.paintWindows(&renderer) else for (self.actions(), 0..) |action, i| {
            const y: f32 = @floatFromInt(self.rowY(i));
            if (i > 0) renderer.fillRect(12, y - 4, @max(0, width - 24), 1, .{ .color = t.border_soft });
            const row: ui.layout.Widget = .{
                .kind = .{ .row = .{ .state = if (self.selected == i) .hover else .idle } },
                .computed_x = padding,
                .computed_y = y,
                .computed_width = @max(0, width - 2 * padding),
                .computed_height = row_height,
            };
            ui.paint.paint(&row, &renderer);
            renderer.drawText(18, y, @max(0, width - 36), row_height, .{ .content = action.label(), .font_size = t.font_size, .color = if (action == .force_close) t.danger else t.window_fg });
        }
        node.setBuffer(&buf.base);
        node.setDestSize(self.box.width, self.box.height);
        node.setFilterMode(.bilinear);
        node.node.setPosition(self.box.x, self.box.y);
        node.node.raiseToTop();
    }

    /// One row per source: its indicator text in a small badge, its name and a
    /// check on the active one; then a row that opens Settings → Input. Named
    /// rows also serve IPC (`input_sources` panel).
    fn paintSources(self: *Menu, renderer: *ui.paint.Renderer) void {
        self.picker_root = .{ .kind = .container };
        _ = self.picker_arena.reset(.retain_capacity);
        const a = self.picker_arena.allocator();
        const output = self.output.?;
        const manager = output.server.input_sources orelse return;
        const list = manager.sources();
        const count = @min(list.len, self.source_count);
        const active = manager.activeIndex();
        const t = ui.theme.global;
        const width: f32 = @floatFromInt(self.box.width);
        const rows = a.alloc(ui.layout.Widget, count + 1) catch return;
        for (rows, 0..) |*row, index| {
            const y: f32 = @floatFromInt(self.rowY(index));
            const is_source = index < count;
            row.* = .{
                .name = if (is_source) std.fmt.allocPrint(a, "source_{d}", .{index}) catch return else "input_settings",
                .kind = .{ .row = .{ .state = if (self.selected == index) .hover else .idle, .selected = is_source and active == index } },
                .computed_x = padding,
                .computed_y = y,
                .computed_width = @max(0, width - 2 * padding),
                .computed_height = row_height,
            };
            if (index == count and count > 0) renderer.fillRect(12, y - 1, @max(0, width - 24), 1, .{ .color = t.border_soft });
            ui.paint.paint(row, renderer);
            if (!is_source) {
                renderer.drawIcon(18, y + 8, 16, 16, .{ .id = .settings, .color = t.window_fg });
                renderer.drawText(44, y, @max(0, width - 60), row_height, .{ .content = i18n.tr("Input settings…"), .font_size = t.font_size, .color = t.window_fg });
                continue;
            }
            const source = list[index];
            renderer.fillRect(16, y + 6, 36, row_height - 12, .{ .color = t.surface_hover, .radius = 5 });
            const label_w: f32 = @floatFromInt(ui.text.measureWidth(source.label, .manrope_heavy, t.font_size - 1, output.wlr_output.scale) catch 0);
            renderer.drawText(16 + @max(0, (36 - label_w) / 2), y, 36, row_height, .{ .content = source.label, .font_size = t.font_size - 1, .weight = 700, .color = t.window_fg });
            const dim = source.kind == .fcitx and !manager.fcitxRunning();
            renderer.drawText(62, y, @max(0, width - 100), row_height, .{ .content = source.name, .font_size = t.font_size, .color = if (dim) t.dim else t.window_fg });
            if (active == index) renderer.drawIcon(width - 34, y + 8, 16, 16, .{ .id = .checkmark, .color = t.accent });
        }
        self.picker_root = .{ .kind = .container, .computed_width = width, .computed_height = @floatFromInt(self.box.height), .children = rows };
    }

    fn paintWindows(self: *Menu, renderer: *ui.paint.Renderer) void {
        self.picker_root = .{ .kind = .container };
        _ = self.picker_arena.reset(.retain_capacity);
        const a = self.picker_arena.allocator();
        const rows = a.alloc(ui.layout.Widget, self.visible_rows) catch return;
        const output = self.output.?;
        const t = ui.theme.shellPalette();
        const width: f32 = @floatFromInt(self.box.width);
        const focused = @import("../ipc/handlers.zig").findFocusedToplevel(output.server);
        for (rows, self.first_row..) |*row, index| {
            const top = self.findWindow(self.window_ids[index]) orelse {
                row.* = .{ .kind = .container };
                continue;
            };
            const y: f32 = @floatFromInt(self.rowY(index));
            const children = a.alloc(ui.layout.Widget, 2) catch return;
            const close_x = @max(padding, width - padding - 32);
            children[0] = .{
                .kind = .{ .text = .{ .content = a.dupe(u8, top.title()) catch return, .font_size = t.font_size, .weight = 600, .color = t.window_fg } },
                .computed_x = 50,
                .computed_y = y,
                .computed_width = @max(0, close_x - 58),
                .computed_height = 40,
            };
            children[1] = .{
                .name = std.fmt.allocPrint(a, "close_window_{d}", .{top.id}) catch return,
                .kind = .{ .button = .{
                    .variant = .chrome,
                    .size = .sm,
                    .label = i18n.tr("Close window"),
                    .icon = .close,
                    .state = if (self.close_hover == index) .hover else .idle,
                    .owner = self,
                    .id = index,
                    .on_click = closeWindow,
                } },
                .computed_x = close_x,
                .computed_y = y + 6,
                .computed_width = 28,
                .computed_height = 28,
            };
            row.* = .{
                .name = std.fmt.allocPrint(a, "window_{d}", .{top.id}) catch return,
                .kind = .{ .row = .{ .state = if (self.selected == index) .hover else .idle, .selected = top == focused } },
                .computed_x = padding,
                .computed_y = y,
                .computed_width = @max(0, width - 2 * padding),
                .computed_height = 40,
                .children = children,
            };
            ui.paint.paint(row, renderer);
            const lookup = output.server.iconLookup(top.appId(), @intFromFloat(@ceil(24 * output.wlr_output.scale)));
            if (lookup == .ready) {
                const icon = lookup.ready;
                renderer.drawImageSmooth(18, y + 8, 24, 24, 0, .{ .pixels = icon.pixels, .width = icon.size, .height = icon.size });
            } else renderer.drawIcon(18, y + 8, 24, 24, .{ .id = if (self.shortcut) |shortcut| switch (shortcut) {
                .files => .folder,
                .terminal => .terminal,
                .settings => .settings,
                else => .document,
            } else .document, .color = t.window_fg });
        }
        self.picker_root = .{ .kind = .container, .computed_width = width, .computed_height = @floatFromInt(self.box.height), .children = rows };
        if (self.first_row > 0) renderer.drawIcon(width / 2 - 5, 1, 10, 5, .{ .id = .chevron_up, .color = t.window_fg });
        if (self.first_row + self.visible_rows < self.window_ids.len) renderer.drawIcon(width / 2 - 5, @floatFromInt(self.box.height - 6), 10, 5, .{ .id = .chevron_down, .color = t.window_fg });
    }
};
