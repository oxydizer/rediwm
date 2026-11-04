//! Files sidebar rows: Places, pins and devices, their drops and actions.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const platform = @import("platform");
const recent = @import("recent.zig");
const volumes_mod = @import("volumes.zig");
const header = @import("header.zig");
const pins_mod = @import("pins.zig");
const places_start = App.places_start;
const pin_base = App.pin_base;
const Row = App.Row;
const formatSize = @import("app_draw.zig").formatSize;

pub fn deviceBase(self: *const App) usize {
    return pin_base + self.pins.items.items.len;
}

pub fn rowCount(self: *const App) usize {
    return self.deviceBase() + self.device_list.items.len;
}

pub fn rowKind(self: *const App, index: usize) Row {
    if (index < pin_base) return .{ .builtin = index };
    if (index < self.deviceBase()) return .{ .pin = index - pin_base };
    return .{ .device = index - self.deviceBase() };
}

pub fn pinIndex(self: *const App, index: usize) ?usize {
    return switch (self.rowKind(index)) {
        .pin => |j| j,
        else => null,
    };
}

pub fn isDeviceRow(self: *const App, index: usize) bool {
    return switch (self.rowKind(index)) {
        .device => true,
        else => false,
    };
}

pub fn placeStep(self: *App) i32 {
    return if (self.place_px >= 0) self.place_px else self.placeTargetStep();
}

// Fill each row's pitch, centred on the existing icon and label, so adjacent
// entries share a hit boundary instead of briefly fading out between rows.
pub fn placeRect(self: *App, index: usize) header.Rect {
    const height = self.placeStep();
    return .{
        .x = 10,
        .y = @floatFromInt(self.placeY(index) - @divTrunc(height - 30, 2)),
        .w = @floatFromInt(self.sidebarWidth() - 20 - (if (self.sidebarScrollbar() != null) self.scrollbarGutter() else @as(i32, 0))),
        .h = @floatFromInt(height),
    };
}

pub fn placePinnable(index: usize) bool {
    return index >= places_start and index < pin_base;
}

pub fn placeVisible(self: *App, index: usize) bool {
    return switch (self.rowKind(index)) {
        .builtin => if (index == 2 and !self.recentAvailable()) false else !placePinnable(index) or self.unpinned_places & (@as(u8, 1) << @as(u3, @intCast(index - places_start))) == 0,
        .pin => true,
        .device => |k| k < self.device_list.items.len,
    };
}

pub fn openPlace(self: *App, index: usize) void {
    if (index == 2) {
        self.navigate(recent.location);
        self.focus = .file_view;
        return;
    }
    switch (self.rowKind(index)) {
        .device => |k| {
            self.activateDevice(k);
            return;
        },
        .pin => |j| {
            self.openPin(j);
            return;
        },
        else => {},
    }
    var buf: [4096]u8 = undefined;
    if (self.placePath(index, &buf)) |path| {
        if (index == 1) std.Io.Dir.cwd().createDirPath(self.io, path) catch {
            self.setStatusNotice(tr("Could not open Trash"), true);
            return;
        };
        self.navigate(path);
    }
    self.focus = .file_view;
}

pub fn openPlaceWindow(self: *App, index: usize) void {
    if (self.chooser != null) return;
    var buf: [4096]u8 = undefined;
    const path = if (self.deviceAt(index)) |volume|
        volume.mount orelse return
    else
        self.placePath(index, &buf) orelse return;
    if (index == 1) std.Io.Dir.cwd().createDirPath(self.io, path) catch {
        self.setStatusNotice(tr("Could not open Trash"), true);
        return;
    };
    if (!recent.isLocation(path) and pins_mod.kindOf(path) != .dir) {
        self.setStatusNotice(tr("Could not open folder"), true);
        return;
    }
    var exe: [platform.exe.max_path]u8 = undefined;
    const executable: []const u8 = platform.exe.path(&exe) orelse "rediwm-files";
    var child = std.process.spawn(self.io, .{
        .argv = &.{ executable, path },
    }) catch {
        self.setStatusNotice(tr("Could not open new window"), true);
        return;
    };
    self.children.add(self.allocator, child.id.?) catch {
        child.kill(self.io);
        self.setStatusNotice(tr("Could not open new window"), true);
    };
}

/// A click on a pin: a folder is browsed, a file opened as a double-click
/// would (a file chooser browses the folder holding it instead).
pub fn openPin(self: *App, j: usize) void {
    if (j >= self.pins.items.items.len) return;
    const pin = &self.pins.items.items[j];
    pin.kind = pins_mod.kindOf(pin.path);
    self.focus = .file_view;
    switch (pin.kind) {
        .dir => self.navigate(pin.path),
        .file => if (self.chooser != null) {
            self.navigate(std.fs.path.dirname(pin.path) orelse "/");
        } else self.openFile(pin.path),
        .missing => {
            var buf: [160]u8 = undefined;
            self.setStatusNotice(i18n.fmt(&buf, tr("{name} is no longer there"), .{ .name = pin.name() }) catch tr("Not found"), true);
            self.invalidate();
        },
    }
}

pub fn placeAt(self: *App, x: f64, y: f64) ?usize {
    if (x < 0 or x >= @as(f64, @floatFromInt(self.sidebarWidth())) or
        y < @as(f64, @floatFromInt(self.contentTop())) or y >= @as(f64, @floatFromInt(self.h - self.sidebarFooter()))) return null;
    if (self.sidebarScrollbar()) |bar| {
        if (bar.overTrack(@floatCast(x), @floatCast(y))) return null;
    }
    for (0..self.rowCount()) |i| {
        if (!self.placeVisible(i)) continue;
        const row = self.placeRect(i);
        if (y >= row.y and y < row.y + row.h) return i;
    }
    return null;
}

/// Whether place `index` is the folder being shown; a device also when the
/// folder is inside it.
pub fn placeActive(self: *App, index: usize) bool {
    if (self.transfer_view.active) return false;
    if (self.deviceAt(index)) |volume| {
        const mount = volume.mount orelse return false;
        return volumes_mod.contains(mount, self.history.current);
    }
    var buf: [4096]u8 = undefined;
    const path = self.placePath(index, &buf) orelse return false;
    return std.mem.eql(u8, path, self.history.current);
}

pub fn deviceAt(self: *App, index: usize) ?*const volumes_mod.Volume {
    return switch (self.rowKind(index)) {
        .device => |k| if (k < self.device_list.items.len) &self.device_list.items[k] else null,
        else => null,
    };
}

/// Height DEVICES adds below Places, heading included.
pub fn deviceBlock(self: *App) i32 {
    const count: i32 = @intCast(self.device_list.items.len);
    return if (count == 0) 0 else 44 + count * self.placeStep();
}

/// The eject button at a mounted device row's right edge.
pub fn ejectRect(self: *App, index: usize) header.Rect {
    const row = self.placeRect(index);
    return .{ .x = row.x + row.w - 30, .y = row.y + (row.h - 26) / 2, .w = 26, .h = 26 };
}

/// The device whose eject button is at (`x`, `y`).
pub fn ejectAt(self: *App, x: f64, y: f64) ?usize {
    const index = self.placeAt(x, y) orelse return null;
    const volume = self.deviceAt(index) orelse return null;
    if (volume.mount == null or !self.ejectRect(index).contains(x, y)) return null;
    return index - self.deviceBase();
}

/// The y between pin rows `slot - 1` and `slot`: where the drop line sits.
pub fn pinBoundary(self: *App, slot: usize) f64 {
    return @floatFromInt(self.pinRowY(slot) - @divTrunc(self.placeStep() - 30, 2));
}

/// The gap among the pins where a drop at (`x`, `y`) would land, or null
/// off PLACES. Anywhere on the section snaps to the nearest gap, so the
/// first pin can be dropped without aiming at the strip under Projects.
pub fn pinSlotAt(self: *App, x: f64, y: f64) ?usize {
    if (self.dialog != null) return null;
    if (x < 0 or x >= @as(f64, @floatFromInt(self.sidebarWidth()))) return null;
    if (y < @as(f64, @floatFromInt(self.contentTop())) or y >= @as(f64, @floatFromInt(self.h - self.sidebarFooter()))) return null;
    if (self.sidebarScrollbar()) |bar| {
        if (x >= @as(f64, bar.track.x)) return null;
    }
    const step: f64 = @floatFromInt(self.placeStep());
    const count = self.pins.items.items.len;
    const top: f64 = @floatFromInt(self.placeY(places_start) - 30);
    if (y < top or y >= self.pinBoundary(count) + 16) return null;
    const nearest = @round((y - self.pinBoundary(0)) / step);
    return @intFromFloat(std.math.clamp(nearest, 0, @as(f64, @floatFromInt(count))));
}

pub fn setPinDrop(self: *App, slot: ?usize) void {
    if (std.meta.eql(self.pin_drop, slot)) return;
    const area: header.Rect = .{ .x = 0, .y = @floatFromInt(self.contentTop()), .w = @floatFromInt(self.sidebarWidth()), .h = @floatFromInt(self.h - self.contentTop() - self.sidebarFooter()) };
    for ([_]?usize{ self.pin_drop, slot }) |gap| {
        const at = gap orelse continue;
        self.damageHighlight(area, .{ .x = 0, .y = self.pinBoundary(at) - 6, .w = area.w, .h = 12 }, null);
    }
    self.pin_drop = slot;
}

/// A drag is over the window at (`x`, `y`). True when a drop there pins.
pub fn dropMotion(self: *App, x: f64, y: f64) bool {
    const slot = self.pinSlotAt(x, y);
    self.setPinDrop(slot);
    return slot != null;
}

/// Content drops use the folder under the pointer, or the displayed folder
/// on empty space. Archives, dialogs, and file choosers are not targets.
pub fn dropDirectoryAt(self: *App, x: f64, y: f64) ?[]const u8 {
    if (self.transfer_view.active) return null;
    if (self.chooser != null or self.dialog != null or self.menu != null or self.history.archive_len > 0) return null;
    if (self.job_state == .running or self.job_state == .waiting_conflict) return null;
    if (x < @as(f64, @floatFromInt(self.sidebarWidth())) or x >= @as(f64, @floatFromInt(self.w - self.scrollbarGutter())) or
        y < @as(f64, @floatFromInt(self.viewTop())) or y >= @as(f64, @floatFromInt(self.contentBottom()))) return null;
    if (self.itemAt(x, y)) |idx| {
        const item = self.items.items[idx];
        if (!item.is_dir or item.missing or item.is_broken) return null;
        return item.path;
    }
    return if (self.isRecent()) null else self.history.current;
}

pub fn highlightDrop(self: *App, x: f64, y: f64, accepted: bool) void {
    const idx = if (accepted) self.itemAt(x, y) else null;
    if (self.folder_drop == idx) return;
    const per_row: usize = @intCast(self.columns());
    for ([_]?usize{ self.folder_drop, idx }) |index| {
        const i = index orelse continue;
        var rect = self.itemHighlight(.{ .col = @floatFromInt(i % per_row), .row = @floatFromInt(i / per_row) });
        rect.x -= 2;
        rect.y -= 2;
        rect.w += 4;
        rect.h += 4;
        self.addDamage(self.clipToViewport(rect));
    }
    self.folder_drop = idx;
}

pub fn dropLeave(self: *App) void {
    self.highlightDrop(0, 0, false);
    self.setPinDrop(null);
    self.setTrashDrop(false);
}

/// The drop happened: the gap it chose, with the line gone.
pub fn takePinDrop(self: *App) ?usize {
    const slot = self.pin_drop;
    self.setPinDrop(null);
    return slot;
}

pub fn builtinPlacePath(self: *App, path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    for (0..self.deviceBase()) |i| {
        if (self.pinIndex(i) != null or !self.placeVisible(i)) continue;
        const known = self.placePath(i, &buf) orelse continue;
        if (std.mem.eql(u8, known, path)) return true;
    }
    return false;
}

/// Pins what was dropped on gap `slot`, in order; what is already listed
/// or gone is skipped.
pub fn pinDropped(self: *App, slot: usize, paths: []const []const u8) void {
    self.reloadPins();
    var at = @min(slot, self.pins.items.items.len);
    var added: usize = 0;
    var listed = false;
    var full = false;
    var first: []const u8 = "";
    for (paths) |raw| {
        const path = pins_mod.normalize(raw) orelse continue;
        if (self.builtinPlacePath(path)) {
            listed = true;
            continue;
        }
        if (self.pins.insert(self.allocator, at, path)) {
            if (added == 0) first = self.pins.items.items[at].name();
            at += 1;
            added += 1;
        } else |err| switch (err) {
            error.Duplicate => listed = true,
            error.Full => full = true,
            error.OutOfMemory => break,
            error.Invalid, error.Missing => {},
        }
    }
    var buf: [200]u8 = undefined;
    if (added > 0) {
        self.savePins();
        self.pinsChanged();
        self.setStatusNotice(if (added == 1)
            i18n.fmt(&buf, tr("Added {value} to Places"), .{ .value = first }) catch tr("Added to Places")
        else
            i18n.fmt(&buf, tr("Added {value} items to Places"), .{ .value = added }) catch tr("Added to Places"), false);
    } else {
        self.setStatusNotice(if (full) tr("Places is full") else if (listed) tr("Already in Places") else tr("Nothing to add to Places"), true);
    }
}

pub fn removePin(self: *App, j: usize) void {
    if (j >= self.pins.items.items.len) return;
    // Another window may have changed the list since: find the pin by path.
    const path = self.allocator.dupe(u8, self.pins.items.items[j].path) catch return;
    defer self.allocator.free(path);
    self.reloadPins();
    if (self.pins.find(path)) |found| self.pins.remove(self.allocator, found);
    self.savePins();
    self.pinsChanged();
}

pub fn savePins(self: *App) void {
    const file = self.pins_path orelse return;
    self.pins.save(self.allocator, self.io, file) catch self.setStatusNotice(tr("Could not save Places"), true);
}

pub fn reloadPins(self: *App) void {
    const file = self.pins_path orelse return;
    var fresh = pins_mod.List.load(self.allocator, self.io, file);
    std.mem.swap(pins_mod.List, &self.pins, &fresh);
    fresh.deinit(self.allocator);
}

/// Rows moved: nothing indexed by one may outlive this.
pub fn pinsChanged(self: *App) void {
    if (self.menu == .sidebar) self.menu = null;
    self.nav_hover = .{};
    self.clampSidebarScroll();
    self.invalidate();
}

/// Picks up pins another window added or removed, and targets that came
/// or went. Cheap enough for every focus gain.
pub fn refreshPins(self: *App) void {
    const file = self.pins_path orelse return;
    var before = self.pins;
    defer before.deinit(self.allocator);
    self.pins = pins_mod.List.load(self.allocator, self.io, file);
    const a = before.items.items;
    const b = self.pins.items.items;
    if (a.len == b.len) {
        for (a, b) |x, y| {
            if (x.kind != y.kind or !std.mem.eql(u8, x.path, y.path)) break;
        } else return;
    }
    self.pinsChanged();
}

/// What the sidebar and status line call a volume.
pub fn deviceLabel(volume: *const volumes_mod.Volume, buf: []u8) []const u8 {
    if (volume.label.len > 0) return volume.label;
    var size: [32]u8 = undefined;
    const bytes: i64 = @intCast(@min(volume.size, std.math.maxInt(i64)));
    return i18n.fmt(buf, tr("{size} Volume"), .{ .size = formatSize(bytes, &size) }) catch tr("Volume");
}

/// Starts watching for volumes. Once, after the window exists.
pub fn startDevices(self: *App) void {
    if (self.devices != null or volumes_mod.disabled(self.environ)) return;
    self.devices = volumes_mod.Monitor.start();
}

/// Readable when `drainDevices` has news; -1 before `startDevices`.
pub fn devicesWakeFd(self: *const App) c_int {
    return if (self.devices) |monitor| monitor.wakeFd() else -1;
}

pub fn drainDevices(self: *App) void {
    const monitor = self.devices orelse return;
    // Clear first: anything that lands after is a wake for the next loop.
    monitor.clearWake();
    const changed = monitor.take(self.allocator, &self.device_list) catch false;
    if (changed) {
        // Row indices moved: nothing indexed by one may outlive this.
        if (self.menu == .device) self.menu = null;
        self.nav_hover = .{};
        self.clampSidebarScroll();
        self.invalidate();
    }
    while (monitor.nextResult()) |result| self.deviceResult(&result);
}

pub fn startDeviceOp(self: *App, volume: *const volumes_mod.Volume, unmount: bool, open: bool) void {
    const monitor = self.devices orelse return;
    if (self.device_op != null) return;
    const id = self.allocator.dupe(u8, volume.id) catch return;
    self.device_op = .{ .id = id, .unmount = unmount, .open = open, .navigation = self.navigation_count };
    if (unmount) monitor.unmount(volume.id) else monitor.mount(volume.id);
    // Unmounting waits for pending writes, which can take a while.
    self.setStatusNotice(if (unmount) tr("Ejecting…") else tr("Mounting…"), false);
}

/// A click on a device row: browse it, mounting it first when it is not.
pub fn activateDevice(self: *App, k: usize) void {
    if (k >= self.device_list.items.len) return;
    const volume = &self.device_list.items[k];
    self.focus = .file_view;
    if (volume.mount) |mount| {
        self.navigate(mount);
    } else {
        self.startDeviceOp(volume, false, true);
    }
}

/// Unmounts a device. It stays listed, unmounted, while it is attached.
pub fn ejectDevice(self: *App, k: usize) void {
    if (k >= self.device_list.items.len) return;
    const volume = &self.device_list.items[k];
    const mount = volume.mount orelse return;
    if (self.device_op != null) return;
    if (self.job_state == .running) {
        self.setStatusNotice(tr("Finish the running file operation first"), true);
        return;
    }
    // The window must not be what keeps the volume busy.
    if (volumes_mod.contains(mount, self.history.current)) self.home();
    self.startDeviceOp(volume, true, false);
}

pub fn deviceResult(self: *App, result: *const volumes_mod.Result) void {
    const op = self.device_op orelse return;
    self.device_op = null;
    defer self.allocator.free(op.id);
    var label_buf: [96]u8 = undefined;
    const name = if (self.device_list.find(volumes_mod.resultId(result))) |volume| deviceLabel(volume, &label_buf) else tr("Device");
    var buf: [160]u8 = undefined;
    if (result.ok == 0) {
        self.setStatusNotice(volumes_mod.failureMessage(&buf, result, name), true);
    } else if (op.unmount) {
        self.setStatusNotice(i18n.fmt(&buf, tr("{name} can be safely removed"), .{ .name = name }) catch tr("Ejected"), false);
    } else if (op.open and op.navigation == self.navigation_count and volumes_mod.resultPath(result).len > 0) {
        self.navigate(volumes_mod.resultPath(result));
    } else {
        self.setStatusNotice(i18n.fmt(&buf, tr("{name} mounted"), .{ .name = name }) catch tr("Mounted"), false);
    }
}
