//! Items: shortcuts, resolved pins, window matching and the window picker, item layout and hover zoom geometry.

const std = @import("std");
const wlr = @import("wlroots");
const ui = @import("ui");
const Toplevel = @import("../Toplevel.zig");
const apps = @import("../start_menu/applications.zig");
const default_apps = @import("../config_runtime/default_apps.zig");
const config = @import("config").loader;
const anim = ui.anim;
const gpa = @import("../main.zig").gpa;
const Self = @import("../Dock.zig");
const max_pins = Self.max_pins;
const Shortcut = Self.Shortcut;
const shortcut_count = Self.shortcut_count;
const Metrics = Self.Metrics;
const clicked = Self.clicked;

pub fn hidden(items: []const []const u8, name: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

pub fn shownIn(c: *const config.CompositorConfig, shortcut: Shortcut) bool {
    if (shortcut == .trash) return c.dock_show_trash;
    return !hidden(c.dock_hidden_shortcuts, @tagName(shortcut));
}

pub fn shortcutShown(self: *const Self, shortcut: Shortcut) bool {
    return shownIn(&self.output.?.server.config.compositor, shortcut);
}

pub fn shortcutCount(self: *const Self) usize {
    var count: usize = 0;
    for (std.enums.values(Shortcut)) |shortcut| if (self.shortcutShown(shortcut)) {
        count += 1;
    };
    return count;
}

/// Buttons that always show, whatever windows are open.
pub fn fixedCount(self: *const Self) usize {
    return self.shortcutCount() + self.pin_count;
}

/// Looks the configured pins up in the catalogue; apps that are no longer
/// installed stay in the config but are not shown.
pub fn resolvePins(self: *Self) void {
    _ = self.pin_arena.reset(.retain_capacity);
    self.pin_count = 0;
    const server = self.output.?.server;
    const configured = server.config.compositor.dock_pinned_apps;
    if (configured.len == 0) return;
    const snapshot = server.start_menu_catalog.retainSnapshot();
    defer snapshot.release();
    const a = self.pin_arena.allocator();
    for (configured, 0..) |id, config_index| {
        if (self.pin_count == max_pins) break;
        const entry = default_apps.find(snapshot.entries, id) orelse continue;
        self.pins[self.pin_count] = .{
            .id = a.dupe(u8, entry.id) catch return,
            .name = a.dupe(u8, entry.name) catch return,
            .icon = a.dupe(u8, entry.icon orelse entry.id) catch return,
            .wm_class = if (entry.startup_wm_class) |class| a.dupe(u8, class) catch return else null,
            .hash = std.hash.Wyhash.hash(0, entry.id) | 1,
            .config_index = config_index,
        };
        self.pin_count += 1;
    }
}

pub fn pinFor(self: *const Self, top: *Toplevel) ?usize {
    for (self.pins[0..self.pin_count], 0..) |pin, i| if (pin.match().matches(top)) return i;
    return null;
}

/// The window standing for an app on its dock button: the focused one, then a
/// visible one, then the most recent.
pub fn prefer(current: ?*Toplevel, top: *Toplevel, focused: ?*Toplevel) bool {
    const held = current orelse return true;
    return held != focused and (top == focused or (held.minimized and !top.minimized));
}

pub fn showsWindow(self: *const Self, top: *Toplevel) bool {
    const output = self.output.?;
    return top.in_world and !top.closing and !top.backend_gone and !top.tab_hidden and
        @import("../workspaces.zig").visible(top) and !(top.live_rules.skip_taskbar orelse false) and
        (!output.server.world.workspaces.active or top.currentOutput() == output);
}

/// Use the same membership as the badge, including minimized windows.
pub fn openWindowPicker(self: *Self, index: usize) bool {
    const output = self.output.?;
    const target = self.topAt(index) orelse return false;
    if (self.pin_of[index] == null and self.shortcuts[index] == null and target.appId().len == 0) return false;
    const snapshot = output.server.start_menu_catalog.retainSnapshot();
    defer snapshot.release();
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const matches = self.shortcutApps(snapshot.entries, scratch.allocator());
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(gpa);
    var it = output.server.world.toplevels.iterator(.forward);
    while (it.next()) |top| {
        if (!self.showsWindow(top)) continue;
        const same = if (self.pin_of[index]) |pin|
            self.pinFor(top) == pin
        else if (self.shortcuts[index]) |shortcut|
            self.pinFor(top) == null and matches[@intFromEnum(shortcut)].matches(top)
        else
            std.mem.eql(u8, @import("../window_tabs.zig").identity(top.appId()), @import("../window_tabs.zig").identity(target.appId()));
        if (same) ids.append(gpa, top.id) catch return false;
    }
    if (ids.items.len < 2) return false;
    std.mem.sort(u64, ids.items, {}, std.sort.asc(u64));
    const button = &self.buttons[index];
    output.server.input.window_menu.openDockWindows(self, ids.items, self.shortcuts[index], self.box.x + @as(i32, @intFromFloat(button.computed_x + button.computed_width / 2)), self.box.y + @as(i32, @intFromFloat(button.computed_y + button.computed_height / 2)));
    return output.server.input.window_menu.node != null;
}

/// Where the dock rests in `area`: centred along and flush with its edge.
pub fn place(self: *Self, area: wlr.Box) void {
    self.box.x = area.x + @divTrunc(area.width - self.box.width, 2);
    self.box.y = area.y + @divTrunc(area.height - self.box.height, 2);
    switch (self.position) {
        .top => self.box.y = area.y,
        .bottom => self.box.y = area.y + area.height - self.box.height,
        .left => self.box.x = area.x,
        .right => self.box.x = area.x + area.width - self.box.width,
    }
}

pub fn metrics(self: *const Self) Metrics {
    return .{ .height = if (self.position.vertical()) self.box.width else self.box.height };
}

/// Put the running indicator on the output-edge side of each upright icon.
pub fn buttonCross(self: *const Self) i32 {
    const m = self.metrics();
    return if (self.position == .top or self.position == .left) m.height - m.length(8) - m.length(48) else m.length(8);
}

pub const AppMatch = struct {
    id: []const u8 = "",
    wm_class: ?[]const u8 = null,

    fn fromEntry(entry: *const apps.AppEntry) AppMatch {
        return .{ .id = entry.id, .wm_class = entry.startup_wm_class };
    }

    fn matches(self: AppMatch, top: *Toplevel) bool {
        return @import("../placeholder_match.zig").matchesAppId(@import("../window_tabs.zig").identity(top.appId()), self.wm_class, self.id);
    }
};

/// Resolve the same preferred applications and fallbacks as launchPreferred.
/// Snapshot strings stay alive for this rebuild; parsed argv lives in scratch.
pub fn shortcutApps(self: *Self, entries: []const apps.AppEntry, scratch: std.mem.Allocator) [shortcut_count]AppMatch {
    const server = self.output.?.server;
    var matches: [shortcut_count]AppMatch = .{ .{}, .{ .id = "rediwm-files" }, .{ .id = "foot" }, .{ .id = Toplevel.settings_app_id }, .{} };
    if (default_apps.find(entries, server.config.compositor.default_file_manager)) |entry| matches[@intFromEnum(Shortcut.files)] = .fromEntry(entry);
    if (default_apps.find(entries, server.config.compositor.default_terminal)) |entry| {
        matches[@intFromEnum(Shortcut.terminal)] = .fromEntry(entry);
    } else {
        const parseExec = @import("../start_menu/launch.zig").parseExec;
        const argv = parseExec(scratch, server.environ.getPosix("TERMINAL") orelse "foot", null) catch return matches;
        if (argv.len == 0) return matches;
        const executable = std.fs.path.basename(argv[0]);
        matches[@intFromEnum(Shortcut.terminal)] = .{ .id = executable };
        for (entries) |*entry| {
            if (!default_apps.matches(entry.*, .terminal)) continue;
            const command = parseExec(scratch, entry.exec, entry) catch continue;
            if (command.len > 0 and std.mem.eql(u8, std.fs.path.basename(command[0]), executable)) {
                matches[@intFromEnum(Shortcut.terminal)] = .fromEntry(entry);
                break;
            }
        }
    }
    return matches;
}

pub fn rebuild(self: *Self, capacity: usize, area: wlr.Box) !void {
    const output = self.output.?;
    const previous_animations = self.animations;
    const previous_count = self.count;
    const snapshot = output.server.start_menu_catalog.retainSnapshot();
    defer snapshot.release();
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const matches = self.shortcutApps(snapshot.entries, scratch.allocator());
    var targets: [shortcut_count]?*Toplevel = @splat(null);
    var pin_targets: [max_pins]?*Toplevel = @splat(null);
    var shortcut_counts: [shortcut_count]usize = @splat(0);
    var pin_counts: [max_pins]usize = @splat(0);
    var app_counts = std.StringHashMap(usize).init(scratch.allocator());
    const focused = @import("../ipc/handlers.zig").findFocusedToplevel(output.server);
    var tops: std.ArrayList(*Toplevel) = .empty;
    defer tops.deinit(gpa);
    var it = output.server.world.toplevels.iterator(.forward);
    windows: while (it.next()) |top| {
        if (!self.showsWindow(top)) continue;
        // Every running app shows: on its pin, on its shortcut, or as a window.
        if (self.pinFor(top)) |pin| {
            pin_counts[pin] += 1;
            if (prefer(pin_targets[pin], top, focused)) pin_targets[pin] = top;
            continue;
        }
        for ([_]Shortcut{ .files, .terminal, .settings }) |shortcut| {
            // A removed shortcut is only a launcher gone: its app, once
            // running, is an ordinary window button.
            if (!self.shortcutShown(shortcut) or !matches[@intFromEnum(shortcut)].matches(top)) continue;
            shortcut_counts[@intFromEnum(shortcut)] += 1;
            const target = &targets[@intFromEnum(shortcut)];
            if (prefer(target.*, top, focused)) target.* = top;
            continue :windows;
        }
        try tops.append(gpa, top);
        const app_id = @import("../window_tabs.zig").identity(top.appId());
        if (app_id.len > 0) {
            const entry = try app_counts.getOrPut(app_id);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
    }
    std.mem.sort(*Toplevel, tops.items, {}, struct {
        fn less(_: void, a: *Toplevel, b: *Toplevel) bool {
            return a.id < b.id;
        }
    }.less);
    self.windows = tops.items.len;
    self.offset = @min(self.offset, self.windows -| capacity);
    const window_count = @min(capacity, self.windows);
    self.count = window_count + self.fixedCount();
    self.position = output.server.config.compositor.dock_position;
    const m: Metrics = .{ .height = @intCast(output.server.config.compositor.dock_height) };
    const length = @as(i32, @intCast(self.count)) * m.itemStep() + m.padding() * 2;
    self.box.width = if (self.position.vertical()) m.height else length;
    self.box.height = if (self.position.vertical()) length else m.height;
    self.scale = output.wlr_output.scale;
    const hovered = self.dispatcher.hovered != null;
    self.dispatcher.reset();
    _ = self.arena.reset(.retain_capacity);
    self.root = .{ .kind = .container, .children = self.buttons[0..self.count], .computed_width = @floatFromInt(self.box.width), .computed_height = @floatFromInt(self.box.height) };
    const raster = self.rasterBox();
    self.input_root = .{ .kind = .container, .children = self.buttons[0..self.count], .computed_x = @floatFromInt(raster.x), .computed_y = @floatFromInt(raster.y), .computed_width = @floatFromInt(raster.width), .computed_height = @floatFromInt(raster.height) };
    var index: usize = 0;
    self.pin_of = @splat(null);
    self.window_counts = @splat(0);
    for ([_]Shortcut{ .applications, .files, .terminal }) |shortcut| {
        if (!self.shortcutShown(shortcut)) continue;
        self.setButton(index, shortcut, if (targets[@intFromEnum(shortcut)]) |top| top.id else 0);
        self.window_counts[index] = shortcut_counts[@intFromEnum(shortcut)];
        index += 1;
    }
    self.pin_base = index;
    for (pin_targets[0..self.pin_count], 0..) |target, pin| {
        self.pin_of[index] = @intCast(pin);
        self.setButton(index, null, if (target) |top| top.id else 0);
        self.window_counts[index] = pin_counts[pin];
        index += 1;
    }
    for (tops.items[self.offset .. self.offset + window_count]) |top| {
        self.setButton(index, null, top.id);
        self.window_counts[index] = app_counts.get(@import("../window_tabs.zig").identity(top.appId())) orelse 1;
        index += 1;
    }
    if (self.shortcutShown(.settings)) {
        self.setButton(index, .settings, if (targets[@intFromEnum(Shortcut.settings)]) |top| top.id else 0);
        self.window_counts[index] = shortcut_counts[@intFromEnum(Shortcut.settings)];
        index += 1;
    }
    // The trash is the dock's last item, past a divider; no window is its.
    if (self.shortcutShown(.trash)) self.setButton(index, .trash, 0);
    for (self.animations[0..self.count], 0..) |*pill, i| {
        const shortcut = self.shortcuts[i];
        const id = self.ids[i];
        const pin: u64 = if (self.pin_of[i]) |p| self.pins[p].hash else 0;
        pill.* = .{ .shortcut = shortcut, .pin = pin, .id = id };
        // Widget indexes move as windows open or items are removed. A
        // shortcut or pin keeps its animation when its representative window changes.
        for (previous_animations[0..previous_count]) |previous| {
            if (previous.shortcut == shortcut and previous.pin == pin and (shortcut != null or pin != 0 or previous.id == id)) {
                pill.* = previous;
                break;
            }
        }
        const range = self.zoomRange();
        self.setButtonZoom(i, std.math.clamp(pill.zoom.value(anim.nowMs()), range.min, range.max));
    }
    // The pointer rests on a replaced button: hover it before painting, so
    // the rebuild paints once.
    if (hovered) {
        self.place(area);
        const cursor = output.server.input.cursor;
        self.dispatcher.pointerMotion(&self.input_root, @floatCast(cursor.x - @as(f64, @floatFromInt(self.box.x))), @floatCast(cursor.y - @as(f64, @floatFromInt(self.box.y))));
    }
    self.dirty = false;
}

pub fn setButton(self: *Self, index: usize, shortcut: ?Shortcut, id: u64) void {
    const m = self.metrics();
    self.ids[index] = id;
    self.shortcuts[index] = shortcut;
    self.buttons[index] = .{
        .name = if (shortcut) |s| @tagName(s) else if (self.pin_of[index]) |p|
            std.fmt.allocPrint(self.arena.allocator(), "pin_{s}", .{self.pins[p].id}) catch "pin"
        else
            std.fmt.allocPrint(self.arena.allocator(), "window_{d}", .{id}) catch "window",
        .kind = .{ .button = .{ .label = self.arena.allocator().dupe(u8, self.label(index)) catch "Application", .variant = .ghost, .owner = self, .id = index, .on_click = clicked } },
        .computed_x = @floatFromInt(if (self.position.vertical()) self.buttonCross() else @as(i32, @intCast(index)) * m.itemStep() + m.padding()),
        .computed_y = @floatFromInt(if (self.position.vertical()) @as(i32, @intCast(index)) * m.itemStep() + m.padding() else self.buttonCross()),
        .computed_width = @floatFromInt(m.length(48)),
        .computed_height = @floatFromInt(m.length(48)),
    };
}

pub fn topAt(self: *Self, index: usize) ?*Toplevel {
    const id = self.ids[index];
    if (id == 0) return null;
    var it = self.output.?.server.world.toplevels.iterator(.forward);
    while (it.next()) |top| if (top.id == id and top.in_world and !top.backend_gone and !top.closing) return top;
    return null;
}

pub fn setButtonZoom(self: *Self, index: usize, zoom: f32) void {
    const m = self.metrics();
    const base: f32 = @floatFromInt(m.length(48));
    const icon = self.iconBox(index, zoom, 36);
    const button = &self.buttons[index];
    const along: f32 = @floatFromInt(@as(i32, @intCast(index)) * m.itemStep() + m.padding());
    const cross: f32 = @floatFromInt(self.buttonCross());
    const x = if (self.position.vertical()) cross else along;
    const y = if (self.position.vertical()) along else cross;
    button.computed_x = @min(x, icon.x);
    button.computed_y = @min(y, icon.y);
    button.computed_width = @max(x + base, icon.x + icon.w) - button.computed_x;
    button.computed_height = @max(y + base, icon.y + icon.h) - button.computed_y;
}

/// How far a hovered icon's zoom may go while its spring overshoots past
/// `dock_hover_zoom` or dips under rest on the way back. Rasters and cells are
/// sized for `max`, so a bounce never needs a larger buffer or upsamples icons.
pub fn zoomRange(self: *const Self) struct { min: f32, max: f32 } {
    const hover_zoom = self.output.?.server.config.compositor.dock_hover_zoom;
    const headroom = (hover_zoom - 1) * 0.3;
    return .{ .min = 1 - headroom, .max = hover_zoom + headroom };
}

/// Keep the icon's screen-edge side fixed as it grows toward the desktop.
pub fn iconBox(self: *const Self, index: usize, zoom: f32, reference: f32) ui.layout.Widget.PaintBounds {
    const m = self.metrics();
    const base: f32 = @floatFromInt(m.length(reference));
    const side = base * zoom;
    const along = @as(f32, @floatFromInt(@as(i32, @intCast(index)) * m.itemStep() + m.padding())) + @as(f32, @floatFromInt(m.length(48))) / 2;
    const inward: f32 = if (self.position == .bottom or self.position == .right) -1 else 1;
    const cross = @as(f32, @floatFromInt(self.buttonCross())) + @as(f32, @floatFromInt(m.length(48))) / 2 + inward * (side - base) / 2;
    return .{ .x = (if (self.position.vertical()) cross else along) - side / 2, .y = (if (self.position.vertical()) along else cross) - side / 2, .w = side, .h = side };
}

/// Only the foreground raster extends beyond the background at large zooms.
pub fn rasterBox(self: *const Self) wlr.Box {
    const icon = self.iconBox(0, self.zoomRange().max, 36);
    const m = self.metrics();
    const cross = if (self.position.vertical()) icon.x else icon.y;
    const before: i32 = @intFromFloat(@ceil(@max(0, -cross)));
    const after: i32 = @intFromFloat(@ceil(@max(0, cross + icon.w - @as(f32, @floatFromInt(m.height)))));
    return if (self.position.vertical())
        .{ .x = -before, .y = 0, .width = self.box.width + before + after, .height = self.box.height }
    else
        .{ .x = 0, .y = -before, .width = self.box.width, .height = self.box.height + before + after };
}

pub fn label(self: *Self, index: usize) []const u8 {
    if (self.shortcuts[index]) |shortcut| return switch (shortcut) {
        .applications => @import("i18n").tr("Applications"),
        .files => @import("i18n").tr("Files"),
        .terminal => @import("i18n").tr("Terminal"),
        .settings => @import("i18n").tr("Settings"),
        .trash => @import("i18n").tr("Trash"),
    };
    if (self.pin_of[index]) |p| return self.pins[p].name;
    return if (self.topAt(index)) |top| top.title() else @import("i18n").tr("Application");
}
