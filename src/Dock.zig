//! Optional output-local launcher. Retained rasters; animation uses output frames.
//! The last raster is kept (`retained`): an icon that animates repaints only its
//! own cell over it (`itemCell`, `changedCells`) and publishes only that damage.
//! Anything the dock draws outside every item's cell must key `base_key` instead.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const sn = @import("node.zig");
const ui = @import("ui");
const Output = @import("Output.zig");
const Server = @import("Server.zig");
const Toplevel = @import("Toplevel.zig");
const IconEntry = @import("icon_service.zig").Entry;
const PanelBuffer = @import("panel_buffer.zig").PanelBuffer;
const SceneData = @import("scene_data.zig").SceneData;
const glass = @import("glass.zig");
const apps = @import("start_menu/applications.zig");
const default_apps = @import("config_runtime/default_apps.zig");
const config = @import("config").loader;
const anim = ui.anim;
const gpa = @import("main.zig").gpa;
const Self = @This();
pub const max_items = 64;
/// Applications pinned to the dock by dragging them from the start menu.
pub const max_pins = 16;
/// `trash` follows `dock_show_trash`; the others `dock_hidden_shortcuts`.
pub const Shortcut = enum { applications, files, terminal, settings, trash };
pub const shortcut_count = std.enums.values(Shortcut).len;
/// The gap between the dock and its output edge, and the one between it and the
/// windows when it reserves its strip.
pub const edge_margin = 5;
pub const window_margin = 10;
/// Auto-hide: the outermost pixels of the edge that reveal the dock, how long
/// the pointer must stay (so a pass over the edge shows nothing) or stay away
/// (so a slip off the dock hides nothing), and how far the dock travels while
/// it fades.
pub const edge_band = 2;
pub const reveal_delay_ms = 120;
pub const hide_delay_ms = 400;
pub const slide_distance = 20;
/// How long the pointer rests on an icon before its tooltip (the window title)
/// shows.
pub const tooltip_delay_ms = 1500;

/// Scale the original 68px layout in logical pixels, independently of output scale.
pub const Metrics = struct {
    height: i32,

    pub fn size(self: Metrics, reference: f32) f32 {
        return reference * @as(f32, @floatFromInt(self.height)) / @as(f32, @floatFromInt(config.dock_height_default));
    }

    pub fn length(self: Metrics, reference: f32) i32 {
        return @max(1, @as(i32, @intFromFloat(@round(self.size(reference)))));
    }

    pub fn itemStep(self: Metrics) i32 {
        return self.length(56);
    }

    pub fn padding(self: Metrics) i32 {
        return self.length(12);
    }
};

/// A pinned application as the last rebuild resolved it. Strings are copies
/// (`pin_arena`), so they outlive the catalogue snapshot they came from.
const PinnedApp = struct {
    id: []const u8,
    name: []const u8,
    icon: []const u8,
    wm_class: ?[]const u8,
    /// Never 0: animations use 0 for "not a pin".
    hash: u64,
    /// Index in `dock_pinned_apps`, which also lists apps no longer installed.
    config_index: usize,

    pub fn match(self: PinnedApp) AppMatch {
        return .{ .id = self.id, .wm_class = self.wm_class };
    }
};

const ItemAnimation = struct {
    shortcut: ?Shortcut = null,
    pin: u64 = 0,
    id: u64 = 0,
    width: anim.Anim = .{},
    opacity: anim.Anim = .{ .property = .opacity },
    zoom: anim.Anim = .{ .from = 1, .to = 1 },
};

output: ?*Output = null,
tree: ?*sn.Tree = null,
node: ?*sn.Buffer = null,
/// Transparent, fixed-size anchor: glass follows the dock background, while
/// the painted buffer may extend inward to fit a fully enlarged icon.
glass_anchor: ?*sn.Buffer = null,
tooltip: ?*sn.Buffer = null,
glass_effect: ?*glass.Effect = null,
/// The glass corner radius of the last paint; its opacity follows `reveal`.
glass_radius: f32 = 0,
data: SceneData = undefined,
box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = config.dock_height_default },
position: @import("config").types.DockPosition = .bottom,
scale: f32 = 0,
dirty: bool = true,
/// The dock could be on screen: sized to fit, no lock, no fullscreen window.
/// With auto-hide it still shows only while `reveal` is above zero.
visible: bool = false,
/// Auto-hide. `pointer_near` is where the pointer wants the dock (at the edge,
/// or on a shown dock); `shown` is what the reveal heads for, which follows it
/// after a delay (`timer`, armed for `timer_target`). `reveal` runs 0 (away) to
/// 1 and drives the fade and slide; `parked` is hidden and settled, so nothing
/// is rebuilt or painted.
pointer_near: bool = false,
shown: bool = false,
timer: ?*wl.EventSource = null,
timer_target: ?bool = null,
/// The tooltip waits on `tip_timer` after the pointer moves onto an icon;
/// `tip_ready` is set once the delay has passed and held until it moves off.
tip_timer: ?*wl.EventSource = null,
tip_ready: bool = false,
tip_armed: bool = false,
reveal: anim.Anim = .{ .property = .opacity },
parked: bool = false,
root: ui.layout.Widget = .{ .kind = .container },
input_root: ui.layout.Widget = .{ .kind = .container },
buttons: [max_items]ui.layout.Widget = undefined,
ids: [max_items]u64 = @splat(0),
window_counts: [max_items]usize = @splat(0),
shortcuts: [max_items]?Shortcut = @splat(null),
/// Index into `pins` for the buttons that show a pinned application.
pin_of: [max_items]?u8 = @splat(null),
pins: [max_pins]PinnedApp = undefined,
pin_count: usize = 0,
pin_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
/// Button index the first pin occupies, where a drop at slot 0 lands.
pin_base: usize = 0,
/// Where a dragged application would be pinned: the gap before this pin.
drop_slot: ?usize = null,
animations: [max_items]ItemAnimation = @splat(.{}),
animating: bool = false,
count: usize = 0,
offset: usize = 0,
windows: usize = 0,
dispatcher: ui.input.Dispatcher = .{},
arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
/// Digests of what the dock and its tooltip show. Every window event rebuilds
/// the dock, but most (a title change) alter neither raster: then nothing is
/// repainted.
drawn: u64 = 0,
tip_drawn: u64 = 0,
/// The last complete raster (`gpa`-owned) and the keys it was painted from. An
/// animating icon repaints only its own cell on top of it, and only that cell is
/// published as damage; anything dock-wide repaints the lot.
retained: []u32 = &.{},
base_drawn: u64 = 0,
item_drawn: [max_items]u64 = @splat(0),
items_drawn: usize = 0,

pub fn deinit(self: *Self) void {
    if (self.timer) |timer| timer.remove();
    if (self.tip_timer) |timer| timer.remove();
    if (self.output) |output| if (output.server.input.window_menu.dock == self) output.server.input.window_menu.close();
    self.dispatcher.reset();
    if (self.tree) |tree| tree.node.destroy();
    self.arena.deinit();
    self.pin_arena.deinit();
    gpa.free(self.retained);
    self.* = .{};
}

fn ensureNodes(self: *Self, output: *Output) !void {
    if (self.tree != null) return;
    const tree = try output.server.taskbar_tree.createSceneTree();
    errdefer tree.node.destroy();
    const anchor_buffer = try PanelBuffer.create(1, 1, 1);
    defer anchor_buffer.base.drop();
    const anchor = try tree.createSceneBuffer(&anchor_buffer.base);
    anchor.point_accepts_input = ignoreInput;
    const node = try tree.createSceneBuffer(null);
    const tooltip = try tree.createSceneBuffer(null);
    node.setFilterMode(.bilinear);
    tooltip.setFilterMode(.bilinear);
    tooltip.point_accepts_input = ignoreInput;
    self.output = output;
    self.data = .{ .role = .{ .dock = self } };
    self.data.attach(&node.node);
    node.point_accepts_input = acceptsInput;
    self.tree = tree;
    self.node = node;
    self.glass_anchor = anchor;
    self.tooltip = tooltip;
    self.glass_effect = glass.Engine.attach(output.server.glass_engine, anchor, &anchor.node, .taskbar);
    // A dock that auto-hides starts away; one that does not, in place.
    self.reveal.cancel(if (output.server.config.compositor.dock_auto_hide) 0 else 1);
}

fn ignoreInput(_: *sn.Buffer, _: *f64, _: *f64) callconv(.c) bool {
    return false;
}

fn acceptsInput(node: *sn.Buffer, x: *f64, y: *f64) callconv(.c) bool {
    const self = SceneData.fromNode(&node.node).?.role.dock;
    const raster = self.rasterBox();
    const lx: f32 = @floatCast(x.* + @as(f64, @floatFromInt(raster.x)));
    const ly: f32 = @floatCast(y.* + @as(f64, @floatFromInt(raster.y)));
    return self.root.contains(lx, ly) or self.buttonAt(lx, ly) != null;
}

pub fn tick(self: *Self, output: *Output, now_ms: i64) bool {
    const server = output.server;
    if (!server.config.compositor.dock_enabled or server.greeter_mode or !output.isAvailable() or output.idle_blanked) {
        if (self.tree != null) self.deinit();
        return false;
    }
    self.ensureNodes(output) catch return false;
    const focused = @import("ipc/handlers.zig").findFocusedToplevel(server);
    // The dock sits beside the taskbar, not beside its own reserved strip.
    const area = output.dockAreaBox();
    const m: Metrics = .{ .height = @intCast(server.config.compositor.dock_height) };
    const position = server.config.compositor.dock_position;
    const visible = server.locker == null and fits(&server.config.compositor, area) and
        !(if (focused) |top| top.fullscreen and top.currentOutput() == output else false);
    if (self.visible != visible) {
        self.visible = visible;
        self.leave();
        self.dirty = true;
    }
    if (!visible) {
        self.tree.?.node.setEnabled(false);
        // Coming back (fullscreen ended, unlocked) starts from rest, not from a
        // reveal the pointer asked for before: it must not flash in.
        self.parked = false;
        self.pointer_near = false;
        self.shown = false;
        self.disarm();
        self.reveal.cancel(if (server.config.compositor.dock_auto_hide) 0 else 1);
        if (server.input.window_menu.dock == self) server.input.window_menu.close();
        return false;
    }
    const revealing = self.syncReveal(now_ms);
    if (self.parked) {
        // Away: the next reveal rebuilds and paints before the first frame it shows.
        self.tree.?.node.setEnabled(false);
        self.leave();
        return false;
    }
    if (self.dirty) self.resolvePins();
    const fixed_count = self.fixedCount();
    const available_length = if (position.vertical()) area.height else area.width;
    if (self.scale != output.wlr_output.scale) self.dirty = true;
    if (self.position != position or self.metrics().height != m.height) self.dirty = true;
    // Output geometry can change without a window or theme notification.
    const capacity: usize = @intCast(@min(max_items - fixed_count, @max(0, @divTrunc(available_length - m.padding() * 2 - 16, m.itemStep()) - @as(i32, @intCast(fixed_count)))));
    const wanted = @min(capacity, self.windows) + fixed_count;
    if ((if (position.vertical()) self.box.height else self.box.width) != @as(i32, @intCast(wanted)) * m.itemStep() + m.padding() * 2) self.dirty = true;
    const rebuilt = self.dirty;
    if (rebuilt) self.rebuild(capacity, area) catch return false;
    self.tree.?.node.setEnabled(self.count > 0);
    if (self.count == 0) {
        self.animating = false;
        return revealing;
    }
    self.place(area);
    if (rebuilt or self.animating) {
        self.paint(now_ms) catch return false;
    } else self.paintTooltip() catch {};
    self.applyReveal(now_ms);
    return self.animating or revealing;
}

const dock_reveal = @import("dock/reveal.zig");
pub const reservedStrip = dock_reveal.reservedStrip;
pub const footprint = dock_reveal.footprint;
pub const reserves = dock_reveal.reserves;
const fits = dock_reveal.fits;
const syncReveal = dock_reveal.syncReveal;
const applyReveal = dock_reveal.applyReveal;
pub const menuOpen = dock_reveal.menuOpen;
pub const nearPointer = dock_reveal.nearPointer;
pub const pointerAt = dock_reveal.pointerAt;
pub const retime = dock_reveal.retime;
pub const disarm = dock_reveal.disarm;

const dock_items = @import("dock/items.zig");
pub const hidden = dock_items.hidden;
pub const shownIn = dock_items.shownIn;
pub const shortcutShown = dock_items.shortcutShown;
pub const shortcutCount = dock_items.shortcutCount;
pub const fixedCount = dock_items.fixedCount;
const resolvePins = dock_items.resolvePins;
pub const pinFor = dock_items.pinFor;
pub const showsWindow = dock_items.showsWindow;
pub const openWindowPicker = dock_items.openWindowPicker;
pub const place = dock_items.place;
pub const metrics = dock_items.metrics;
pub const buttonCross = dock_items.buttonCross;
const AppMatch = dock_items.AppMatch;
pub const shortcutApps = dock_items.shortcutApps;
const rebuild = dock_items.rebuild;
pub const setButton = dock_items.setButton;
pub const topAt = dock_items.topAt;
pub const setButtonZoom = dock_items.setButtonZoom;
pub const zoomRange = dock_items.zoomRange;
pub const iconBox = dock_items.iconBox;
pub const rasterBox = dock_items.rasterBox;
pub const label = dock_items.label;

const dock_paint = @import("dock/paint.zig");
pub const hashValue = dock_paint.hashValue;
pub const paint = dock_paint.paint;
pub const iconRaster = dock_paint.iconRaster;
pub const background = dock_paint.background;
pub const cornerRadius = dock_paint.cornerRadius;
pub const itemCell = dock_paint.itemCell;
pub const changedCells = dock_paint.changedCells;
pub const paintDock = dock_paint.paintDock;
pub const paintItem = dock_paint.paintItem;
pub const paintMarks = dock_paint.paintMarks;

const dock_pointer = @import("dock/pointer.zig");
pub const restartTip = dock_pointer.restartTip;
pub const cancelTip = dock_pointer.cancelTip;
pub const paintTooltip = dock_pointer.paintTooltip;
pub const placeTooltip = dock_pointer.placeTooltip;
pub const motion = dock_pointer.motion;
pub const leave = dock_pointer.leave;
pub const repaint = dock_pointer.repaint;
pub const press = dock_pointer.press;
pub const buttonAt = dock_pointer.buttonAt;
pub const trashAt = dock_pointer.trashAt;
pub const clickPin = dock_pointer.clickPin;
pub const contextMenu = dock_pointer.contextMenu;
pub const removeShortcut = dock_pointer.removeShortcut;
pub const saveHidden = dock_pointer.saveHidden;
pub const clicked = dock_pointer.clicked;
pub const launchOrigin = dock_pointer.launchOrigin;

const dock_pins = @import("dock/pins.zig");
pub const dropSlotAt = dock_pins.dropSlotAt;
pub const reachable = dock_pins.reachable;
pub const pinIndex = dock_pins.pinIndex;
pub const staysPut = dock_pins.staysPut;
pub const pinIcon = dock_pins.pinIcon;
pub const movePin = dock_pins.movePin;
pub const setDropSlot = dock_pins.setDropSlot;
pub const pinApp = dock_pins.pinApp;
pub const unpinApp = dock_pins.unpinApp;
pub const savePinned = dock_pins.savePinned;

/// Windows, theme or icons changed: rebuild on the output's next frame. A
/// hidden dock rebuilds when it is shown again.
pub fn invalidate(self: *Self) void {
    self.dirty = true;
    if (self.visible and !self.parked) self.output.?.wlr_output.scheduleFrame();
}

pub fn scroll(self: *Self, delta: f64) void {
    // A pending rebuild may add windows; it clamps the offset.
    if (delta == 0 or (!self.dirty and self.windows + self.fixedCount() <= self.count)) return;
    if (delta > 0) self.offset +|= 1 else self.offset -|= 1;
    self.invalidate();
}

pub fn captureAnimations(self: *Self, allocator: std.mem.Allocator, list: *std.ArrayList(anim.LiveCapture), now_ms: i64) !void {
    for (self.animations[0..self.count]) |*pill| {
        try anim.captureIfLive(allocator, list, &pill.width, .taskbar_hover, now_ms);
        try anim.captureIfLive(allocator, list, &pill.opacity, .taskbar_hover, now_ms);
        try anim.captureIfLive(allocator, list, &pill.zoom, .dock_hover, now_ms);
    }
}

pub fn appendAnimations(self: *const Self, allocator: std.mem.Allocator, list: *std.ArrayList(@import("ipc/protocol.zig").AnimationData), now_ms: i64) !void {
    const output = self.output orelse return;
    const inspector = @import("ipc/animations.zig");
    for (self.animations[0..self.count], self.buttons[0..self.count]) |pill, button| {
        const prefix = try std.fmt.allocPrint(allocator, "dock.{s}.{s}", .{ std.mem.span(output.wlr_output.name), button.name orelse "item" });
        defer allocator.free(prefix);
        try inspector.appendLive(allocator, list, try std.fmt.allocPrint(allocator, "{s}.pill_width", .{prefix}), pill.width, now_ms);
        try inspector.appendLive(allocator, list, try std.fmt.allocPrint(allocator, "{s}.pill_opacity", .{prefix}), pill.opacity, now_ms);
        try inspector.appendLive(allocator, list, try std.fmt.allocPrint(allocator, "{s}.hover_zoom", .{prefix}), pill.zoom, now_ms);
    }
}
