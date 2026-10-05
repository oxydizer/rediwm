// The bottom taskbar: one CPU-rasterized strip per output, laid out and
// exclusive-zoned the way a wlr-layer-shell bottom panel would be, but drawn
// directly into the scene like the wallpaper and window chrome rather than
// through an actual layer-shell client (there is no external client here).
//
// Geometry is mapped from the taskbar spec: bar 64, chip 42 tall, icon tile 23,
// tray hit target 34, tray/tile gap 6, edge gutter 20 (all logical px @1x).
// Chips fit their icon and title, capped at 280px and sharing available space
// when crowded. Focus is indicated by a subtle neutral fill and border.
const std = @import("std");
const glass = @import("glass.zig");

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const col = @import("color.zig");

const c_time = @cImport({
    @cInclude("time.h");
});

const gpa = @import("main.zig").gpa;
const anim = @import("ui").anim;
const chrome = @import("chrome.zig");
const geometry = @import("geometry.zig");
const icon_service = @import("icon_service.zig");
const scene_data = @import("scene_data.zig");
const battery = @import("taskbar/battery.zig");
const taskbar_items = @import("config").taskbar_items;
const battery_highlight = @import("taskbar/battery_highlight.zig");
const battery_badge = @import("ui").widgets.battery;
const start_button = @import("taskbar/start_button.zig");
const text = @import("ui").text;
const ui_theme = @import("ui").theme;
const stats = @import("ipc/stats.zig");
const protocol = @import("ipc/protocol.zig");
const Output = @import("Output.zig");
const Server = @import("Server.zig");
const Toplevel = @import("Toplevel.zig");

const Anim = anim.Anim;
pub const nowMs = anim.nowMs;

const Taskbar = @This();

const log = std.log.scoped(.taskbar);

pub const default_bar_height: i32 = 54;
pub const bar_height: i32 = default_bar_height;
pub fn barHeight() i32 {
    return @intFromFloat(@round(ui_theme.global.taskbar_size));
}
const edge_pad: i32 = 20;
// Anchor sizes at the original 54px bar / 8px item gap (a
// 42px-tall chip with a 23px icon tile). Every other taskbar-item size below
// is a function of the live bar height and item gap, scaled from these two
// anchors, so shrinking `taskbar_size` (down to `min_bar_height`) or growing
// `chip_gap` shrinks the pills/tiles/tray targets together instead of
// clipping or leaving them floating in oversized empty space.
pub const min_bar_height: i32 = 36;
const base_chip_size: i32 = 42;
const icon_scale: f32 = 0.8 * 1.1;
const base_tile_size: f32 = 26 * icon_scale;
const tile_radius: f32 = 4;

fn chipGap() i32 {
    return @intFromFloat(@round(ui_theme.global.chip_gap));
}

// Top/bottom breathing room around each chip pill. Tied to the same
// "Window item gap" slider that spaces pills horizontally (chipGap above),
// so one control changes both at once; capped so a large gap can't collapse
// the pill down to nothing.
const default_chip_vertical_margin: f32 = (@as(f32, @floatFromInt(default_bar_height)) - @as(f32, @floatFromInt(base_chip_size))) / 2;
const max_chip_vertical_margin: f32 = 16.0;
fn chipVerticalMargin() f32 {
    const margin_per_gap_px = default_chip_vertical_margin / 8.0; // original 8px gap anchor
    return @min(ui_theme.global.chip_gap * margin_per_gap_px, max_chip_vertical_margin);
}

const min_chip_size: i32 = 18;
pub fn chipSize() i32 {
    const raw = @as(f32, @floatFromInt(barHeight())) - 2 * chipVerticalMargin();
    return @max(min_chip_size, @as(i32, @intFromFloat(@round(raw))));
}

const min_tile_size: i32 = 10;
fn tileSize() i32 {
    const ratio = base_tile_size / @as(f32, @floatFromInt(base_chip_size));
    return @max(min_tile_size, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(chipSize())) * ratio))));
}

fn chipPad() i32 {
    return @divTrunc(chipSize() - tileSize(), 2);
}
const icon_text_gap: i32 = 9;
const title_pad_right: i32 = 16;

const base_tray_hit: i32 = 34;
const min_tray_hit: i32 = 20;
fn trayHit() i32 {
    const ratio = @as(f32, @floatFromInt(base_tray_hit)) / @as(f32, @floatFromInt(base_chip_size));
    return @max(min_tray_hit, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(chipSize())) * ratio))));
}
const tray_radius: f32 = 5;
const tray_gap: i32 = 6;

// Same height as the chip row so the whole strip lines up.
pub fn buttonSize() i32 {
    return chipSize();
}
pub fn startButtonGap() i32 {
    return @intFromFloat(@round(ui_theme.global.start_button_gap));
}
pub fn startButtonLeft() i32 {
    return startButtonGap();
}
pub fn startButtonBox(bar: *Taskbar) wlr.Box {
    const size = buttonSize();
    return .{
        .x = bar.box.x + startButtonLeft(),
        .y = bar.box.y + @divTrunc(bar.box.height - size, 2),
        .width = size,
        .height = size,
    };
}
fn startIconSize() i32 {
    const configured: i32 = @intFromFloat(@round(ui_theme.global.start_button_icon_size));
    return @max(8, @min(configured, buttonSize()));
}
fn firstChipX() i32 {
    return startButtonLeft() + buttonSize() + startButtonGap();
}
const clock_gap: i32 = 16;
const chip_clock_gap: i32 = 16;
pub const paint_start: u8 = 1 << 0;
pub const paint_chips: u8 = 1 << 1;
pub const paint_tray: u8 = 1 << 2;
pub const paint_clock: u8 = 1 << 3;
pub const paint_hover: u8 = 1 << 4;
pub const paint_press: u8 = 1 << 5;
pub const paint_audio: u8 = 1 << 6;
pub const paint_capture: u8 = 1 << 7;
pub const capture_label = "Stop sharing";

const press_scale: f32 = 0.92;
const volume_scroll_step: f32 = 0.05;

server: *Server,
wlr_output: *wlr.Output,
tree: *wlr.SceneTree,
// The background remains the taskbar's full-width glass anchor. Foreground
// controls are separate scene buffers above it so their replacement damages
// only their own bounds.
buffer_node: *wlr.SceneBuffer,
start_node: *wlr.SceneBuffer,
clock_node: *wlr.SceneBuffer,
tray_nodes: [2]*wlr.SceneBuffer,
app_tray_node: *wlr.SceneBuffer,
app_tray_generation: u64 = 0,
capture_node: *wlr.SceneBuffer,
battery_node: *wlr.SceneBuffer,
battery_state: battery.State = .{},
battery_dirty: bool = true,
battery_shimmer: battery_highlight.Highlight = .{},
node_data: scene_data.SceneData = undefined,
timer: *wl.EventSource,
box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = default_bar_height },
dirty: bool = true,
paint_causes: u8 = 0,
background_dirty: bool = true,
start_dirty: bool = true,
clock_dirty: bool = true,
tray_dirty: [2]bool = .{ true, true },
capture_dirty: bool = true,
capture_sessions: usize = 0,

start: start_button.State = .{},
start_logo: ?icon_service.Entry = null,
chips: std.ArrayList(ChipState) = .empty,
tray: [2]TrayState = .{ .{ .kind = .volume }, .{ .kind = .wifi } },
capture_hover: Anim = .{},
capture_press: Anim = .{ .to = 1 },
hover_target: Target = .none,

// Cached master-volume display state, refreshed from `server.audio` only
// when its `generation` counter has moved since we last looked (see
// audio/pipewire.zig's module doc comment) — checked once per `tick()`
// rather than reaching into the AudioManager lock during every pixel of
// `render()`.
audio_generation_seen: u32 = 0,
audio_volume: f32 = 0,
audio_muted: bool = false,

clock_time: [16]u8 = [_]u8{0} ** 16,
clock_date: [16]u8 = [_]u8{0} ** 16,
// Layout and every tick ask for these; shaping them each time showed up in
// idle profiles. The clock's is dropped when its strings change.
clock_width: MeasuredWidth = .{},
capture_width: MeasuredWidth = .{},

const MeasuredWidth = struct {
    width: f32 = 0,
    scale: f32 = 0,
    font_generation: u32 = 0,
    valid: bool = false,

    fn get(self: *const MeasuredWidth, scale: f32) ?f32 {
        if (!self.valid or self.scale != scale or self.font_generation != text.font_generation) return null;
        return self.width;
    }

    fn put(self: *MeasuredWidth, scale: f32, width: f32) f32 {
        self.* = .{ .width = width, .scale = scale, .font_generation = text.font_generation, .valid = true };
        return width;
    }
};

const TrayKind = enum { volume, wifi };

pub const AppKind = enum { file_explorer, notes, terminal, settings, text_doc, browser, other };

const ChipState = struct {
    toplevel: *Toplevel,
    buffer_node: ?*wlr.SceneBuffer = null,
    dirty: bool = true,
    kind: AppKind = .other,
    // A real icon found via the XDG icon theme, when one exists; falls back
    // to the hand-drawn `tileStyle`/`glyphSd` tile below when null.
    icon: ?icon_service.Entry = null,
    target_x: f32 = 0,
    // Struct field defaults must be comptime; the anchor size is fine here
    // since `reconcile` always overwrites this with the live `chipSize()`
    // (via `sharedChipWidth`) right after construction.
    width: f32 = @floatFromInt(base_chip_size),
    flip: Anim = .{},
    hover: Anim = .{},
    press: Anim = .{ .to = 1 },
    // What the raster on screen was painted from; see `ChipMemo`.
    painted: ?ChipMemo = null,
    // That raster, still referenced here, and the sampled paint and placement
    // it used: a change of title alone copies it and repaints only the title.
    raster: ?*BarBuffer = null,
    raster_key: ?ChipRasterKey = null,

    pub fn renderX(self: ChipState, now_ms: i64) f32 {
        return self.target_x + self.flip.value(now_ms);
    }
};

// Inputs to a chip raster that `reconcile` can change, so a title change
// (terminal spinners, tab counters) repaints only its own chip. Hover and
// press curves mark chips dirty from `tick`, and `relayout` repaints
// everything. The theme fields are snapshotted because colour-only reskins
// arrive through here, like chrome.TitlebarMemo.
const ChipMemo = struct {
    x: f32,
    width: f32,
    active: bool,
    needs_attention: bool,
    kind: AppKind,
    icon: ?u64,
    title_hash: u64,
    scale: f32,
    bar_height: i32,
    chip_size: i32,
    tile_size: i32,
    chip_pad: i32,
    radius: f32,
    title_size: f32,
    font: []const u8,
    colors: [6][4]f32,

    fn capture(bar: *Taskbar, chip: *const ChipState, now_ms: i64) ChipMemo {
        const t = ui_theme.global;
        return .{
            .x = chip.renderX(now_ms),
            .width = chip.width,
            .active = chip.toplevel == bar.server.world.toplevels.first(),
            .needs_attention = chip.toplevel.needs_attention,
            .kind = chip.kind,
            .icon = if (chip.icon) |icon| icon.id else null,
            // Covers the monogram too: both fall back from title to app_id.
            .title_hash = std.hash.Wyhash.hash(0, chipTitle(chip.toplevel)),
            .scale = bar.wlr_output.scale,
            .bar_height = bar.box.height,
            .chip_size = chipSize(),
            .tile_size = tileSize(),
            .chip_pad = chipPad(),
            .radius = t.radius,
            .title_size = t.taskbar_title_size,
            .font = t.font,
            .colors = .{ t.taskbar_surface, t.taskbar_hover, t.surface_hover, t.taskbar_border, t.border_soft, t.window_fg },
        };
    }
};

// Chip raster inputs that `ChipMemo` leaves to the hover/press curves and
// FLIP offset, sampled as `ChipPaint` does, plus the buffer placement. Chips
// without an icon draw a monogram taken from the title into their tile.
const ChipRasterKey = struct {
    left: i32,
    width: i32,
    scale: f32,
    x: f32,
    fill: Color,
    border: Color,
    monogram: [4]u8 = @splat(0),
    monogram_len: usize = 0,

    fn capture(bar: *Taskbar, now_ms: i64, chip: *const ChipState, left: i32, width: i32) ChipRasterKey {
        const paint = ChipPaint.init(bar, now_ms, chip);
        var key: ChipRasterKey = .{
            .left = left,
            .width = width,
            .scale = bar.wlr_output.scale,
            .x = paint.x,
            .fill = paint.fill,
            .border = paint.border,
        };
        if (chip.icon == null and chip.kind == .other) {
            var storage: [4]u8 = undefined;
            const label = monogramOf(chip.toplevel, &storage);
            @memcpy(key.monogram[0..label.len], label);
            key.monogram_len = label.len;
        }
        return key;
    }
};

const TrayState = struct {
    kind: TrayKind,
    hover: Anim = .{},
    press: Anim = .{ .to = 1 },
};

pub const Target = union(enum) { none, clock, battery, start_button, chip: *Toplevel, tray: usize, capture_indicator };

fn targetEql(a: Target, b: Target) bool {
    return switch (a) {
        .none => b == .none,
        .clock => b == .clock,
        .battery => b == .battery,
        .start_button => b == .start_button,
        .chip => |t| switch (b) {
            .chip => |t2| t == t2,
            else => false,
        },
        .tray => |i| switch (b) {
            .tray => |other| i == other,
            else => false,
        },
        .capture_indicator => b == .capture_indicator,
    };
}

pub fn create(server: *Server, wlr_output: *wlr.Output) !*Taskbar {
    const bar = try gpa.create(Taskbar);
    errdefer gpa.destroy(bar);

    const tree = try server.taskbar_tree.createSceneTree();
    errdefer tree.node.destroy();
    const buffer_node = try tree.createSceneBuffer(null);
    const start_node = try tree.createSceneBuffer(null);
    const clock_node = try tree.createSceneBuffer(null);
    var tray_nodes: [2]*wlr.SceneBuffer = undefined;
    for (&tray_nodes) |*node| node.* = try tree.createSceneBuffer(null);
    const app_tray_node = try tree.createSceneBuffer(null);
    const capture_node = try tree.createSceneBuffer(null);
    const battery_node = try tree.createSceneBuffer(null);
    // Preserve glyph coverage when fractional-scale destination rounding
    // makes the scene box differ from the raster by a device pixel.
    buffer_node.setFilterMode(.bilinear);
    _ = glass.Engine.attach(server.glass_engine, buffer_node, &buffer_node.node, .taskbar);

    bar.* = .{
        .server = server,
        .wlr_output = wlr_output,
        .tree = tree,
        .buffer_node = buffer_node,
        .start_node = start_node,
        .clock_node = clock_node,
        .tray_nodes = tray_nodes,
        .app_tray_node = app_tray_node,
        .capture_node = capture_node,
        .battery_node = battery_node,
        .battery_state = battery.read(server.io, gpa),
        .timer = undefined,
    };
    bar.node_data = .{ .role = .{ .taskbar = bar } };
    scene_data.SceneData.attach(&bar.node_data, &buffer_node.node);
    scene_data.SceneData.attach(&bar.node_data, &start_node.node);
    scene_data.SceneData.attach(&bar.node_data, &clock_node.node);
    for (tray_nodes) |node| scene_data.SceneData.attach(&bar.node_data, &node.node);
    scene_data.SceneData.attach(&bar.node_data, &app_tray_node.node);
    app_tray_node.setFilterMode(.bilinear);
    scene_data.SceneData.attach(&bar.node_data, &capture_node.node);
    capture_node.setFilterMode(.bilinear);
    capture_node.node.setEnabled(false);
    scene_data.SceneData.attach(&bar.node_data, &battery_node.node);
    battery_node.setFilterMode(.bilinear);
    battery_node.node.setEnabled(false);
    bar.refreshStartLogo();
    bar.timer = try server.wl_server.getEventLoop().addTimer(*Taskbar, onTick, bar);
    errdefer bar.timer.remove();
    _ = bar.updateClockStrings();
    bar.scheduleClockTick();
    return bar;
}

pub fn destroy(bar: *Taskbar) void {
    if (bar.server.tray) |tray_mgr| tray_mgr.closeMenu();
    bar.server.input.detachTaskbar(bar);
    bar.timer.remove();
    if (bar.start_logo) |e| bar.server.iconRelease(e.id);
    for (bar.chips.items) |chip| {
        if (chip.raster) |raster| raster.base.drop();
        if (chip.icon) |e| bar.server.iconRelease(e.id);
    }
    bar.chips.deinit(gpa);
    bar.tree.node.destroy();
    gpa.destroy(bar);
}

/// Takes a fresh `battery.read` snapshot; only a change requests a frame.
pub fn applyBattery(bar: *Taskbar, next: battery.State) void {
    if (std.meta.eql(next, bar.battery_state)) return;
    const layout_changed = (next.percent == null) != (bar.battery_state.percent == null);
    bar.battery_shimmer.update(bar.battery_state, next, nowMs());
    bar.battery_state = next;
    if (Output.fromWlr(bar.wlr_output)) |output| {
        if (next.percent == null) output.closeBattery() else if (output.battery_popup) |popup| popup.refresh();
    }
    bar.battery_dirty = true;
    if (layout_changed) {
        _ = bar.reconcile(nowMs());
        bar.tray_dirty = .{ true, true };
        bar.clock_dirty = true;
        bar.capture_dirty = true;
    }
    bar.markDirty(paint_tray);
    bar.wlr_output.scheduleFrame();
}

fn onTick(bar: *Taskbar) c_int {
    // Plug events arrive through Server's uevent socket; this catches the
    // capacity changes firmware does not announce.
    bar.applyBattery(battery.read(bar.server.io, gpa));
    if (bar.updateClockStrings()) {
        bar.clock_dirty = true;
        bar.markDirty(paint_clock);
        bar.wlr_output.scheduleFrame();
        stats.recordTaskbarClockFrameRequest();
    }
    if (Output.fromWlr(bar.wlr_output)) |output| {
        if (output.calendar) |calendar| calendar.refresh();
    }
    bar.scheduleClockTick();
    return 0;
}

fn markPaintCauseFromTarget(target: Target) u8 {
    return switch (target) {
        .none => 0,
        .clock => paint_clock,
        .battery => paint_tray,
        .start_button => paint_start,
        .chip => paint_chips,
        .tray => paint_tray,
        .capture_indicator => paint_capture,
    };
}

pub fn markDirty(bar: *Taskbar, cause: u8) void {
    bar.dirty = true;
    bar.paint_causes |= cause;
}

fn scheduleClockTick(bar: *Taskbar) void {
    var raw: c_time.time_t = c_time.time(null);
    var tm_storage: c_time.struct_tm = undefined;
    const tm = c_time.localtime_r(&raw, &tm_storage) orelse {
        bar.timer.timerUpdate(1000) catch |err| {
            log.err("scheduleClockTick: localtime failed: {}", .{err});
        };
        return;
    };

    const tm_sec = tm.*.tm_sec;
    if (tm_sec < 0 or tm_sec > 59) {
        bar.timer.timerUpdate(1000) catch |err| {
            log.err("scheduleClockTick: invalid tm_sec {}: {}", .{ tm_sec, err });
        };
        return;
    }

    // Keep updates aligned to the displayed minute boundary to avoid one-second
    // frame requests when the shown strings did not change. Battery capacity
    // shares this wakeup instead of adding its own.
    const delay_ms: c_int = @intCast((60 - tm_sec) * 1000 + 25);
    bar.timer.timerUpdate(delay_ms) catch |err| {
        log.err("scheduleClockTick: could not reschedule clock timer: {}", .{err});
    };
}

pub fn refreshClock(bar: *Taskbar) void {
    if (!bar.updateClockStrings()) return;
    bar.clock_dirty = true;
    // A wider/narrower clock moves every item to its left, including the tray.
    bar.tray_dirty = .{ true, true };
    bar.capture_dirty = true;
    const chips_changed = bar.reconcile(nowMs());
    bar.markDirty(paint_clock | paint_tray | paint_capture | (if (chips_changed) paint_chips else @as(u8, 0)));
    bar.wlr_output.scheduleFrame();
}

fn updateClockStrings(bar: *Taskbar) bool {
    var raw: c_time.time_t = c_time.time(null);
    var tm_storage: c_time.struct_tm = undefined;
    const tm = c_time.localtime_r(&raw, &tm_storage) orelse return false;

    var next_time: [16]u8 = undefined;
    var next_date: [16]u8 = undefined;
    if (c_time.strftime(&next_time, next_time.len, bar.server.config.region.timeFormat(), tm) == 0) return false;
    if (c_time.strftime(&next_date, next_date.len, "%a, %b %-d", tm) == 0) return false;

    const prev_time = std.mem.sliceTo(&bar.clock_time, 0);
    const prev_date = std.mem.sliceTo(&bar.clock_date, 0);
    const time = std.mem.sliceTo(&next_time, 0);
    const date = std.mem.sliceTo(&next_date, 0);
    if (std.mem.eql(u8, prev_time, time) and std.mem.eql(u8, prev_date, date)) return false;

    bar.clock_time = next_time;
    bar.clock_date = next_date;
    bar.clock_width.valid = false;
    return true;
}

// Repositions the strip along the configured output edge.
pub fn relayout(bar: *Taskbar, output_box: wlr.Box) void {
    if (bar.server.input.window_menu.bar == bar) bar.server.input.window_menu.close();
    if (bar.server.tray) |tray_mgr| tray_mgr.closeMenu();
    bar.refreshStartLogo();
    const h = barHeight();
    bar.box = .{
        .x = output_box.x,
        .y = if (bar.server.config.compositor.taskbar_position == .top) output_box.y else output_box.y + output_box.height - h,
        .width = output_box.width,
        .height = h,
    };
    bar.tree.node.setPosition(bar.box.x, bar.box.y);
    const now_ms = nowMs();
    bar.pointerLeave();
    _ = bar.reconcile(now_ms);
    bar.app_tray_generation = 0;
    bar.background_dirty = true;
    bar.start_dirty = true;
    bar.clock_dirty = true;
    bar.tray_dirty = .{ true, true };
    bar.capture_dirty = true;
    bar.battery_dirty = true;
    for (bar.chips.items) |*chip| chip.dirty = true;
    bar.render(now_ms, paint_start | paint_chips | paint_tray | paint_clock);
    bar.dirty = false;
    bar.paint_causes = 0;
    if (Output.fromWlr(bar.wlr_output)) |output| if (output.wifi_popup) |popup| {
        if (bar.itemBox(.network) == null) output.closeWifi() else popup.refresh();
    };
    if (Output.fromWlr(bar.wlr_output)) |output| if (output.battery_popup) |popup| {
        if (bar.itemBox(.battery) == null) output.closeBattery() else popup.refresh();
    };
}

// Called whenever world.toplevels changes shape or order (map, unmap,
// focus) or a window's identity changes. Rebuilds the chip list, starting
// FLIP animations for chips whose on-screen position actually moved, and
// repaints only chips whose pixels would differ.
pub fn notifyToplevelsChanged(bar: *Taskbar) void {
    bar.refreshStartLogo();
    if (bar.server.tray) |tray_mgr| {
        if (bar.app_tray_generation != tray_mgr.generation) bar.markDirty(paint_tray);
    }
    const chips_changed = bar.reconcile(nowMs());
    if (chips_changed) bar.markDirty(paint_chips);
    if (bar.dirty) bar.wlr_output.scheduleFrame();
}

fn clockColumnWidth(bar: *Taskbar) f32 {
    const scale = bar.wlr_output.scale;
    if (bar.clock_width.get(scale)) |width| return width;
    const time_str = std.mem.trimStart(u8, std.mem.sliceTo(&bar.clock_time, 0), " ");
    const date_str = std.mem.sliceTo(&bar.clock_date, 0);
    // Reserve room for the widest usual clock/date to keep the tray stable.
    const time_w = text.measureWidth(time_str, .manrope, 14, scale) catch null;
    const date_w = text.measureWidth(date_str, .manrope, 11, scale) catch null;
    const width: f32 = @floatFromInt(@max(80, @max(time_w orelse 0, date_w orelse 0) + 1));
    // A failed measurement is retried next time rather than remembered.
    if (time_w == null or date_w == null) return width;
    return bar.clock_width.put(scale, width);
}

fn rightLayout(bar: *Taskbar) taskbar_items.Layout {
    return taskbar_items.arrange(bar.server.config.compositor.taskbar_items, @floatFromInt(bar.box.width - edge_pad), .{ battery_width, @floatFromInt(trayHit()), @floatFromInt(trayHit()), bar.clockColumnWidth() }, bar.battery_state.percent != null, tray_gap, clock_gap);
}

pub fn itemBox(bar: *Taskbar, item: taskbar_items.Item) ?wlr.Box {
    const x = bar.rightLayout().x[@intFromEnum(item)] orelse return null;
    const width: i32 = switch (item) {
        .battery => battery_width,
        .clock => @intFromFloat(@ceil(bar.clockColumnWidth())),
        else => trayHit(),
    };
    return .{ .x = bar.box.x + @as(i32, @intFromFloat(@round(x))), .y = bar.box.y, .width = width, .height = bar.box.height };
}

fn chipsRightEdge(bar: *Taskbar) f32 {
    const left = bar.appTrayLeft();
    return left - @as(f32, @floatFromInt(chip_clock_gap));
}

const battery_width = battery_badge.width;

fn batteryX(bar: *Taskbar) f32 {
    return bar.rightLayout().x[@intFromEnum(taskbar_items.Item.battery)] orelse 0;
}

fn clockX(bar: *Taskbar) f32 {
    return bar.rightLayout().x[@intFromEnum(taskbar_items.Item.clock)] orelse 0;
}

fn trayItem(index: usize) taskbar_items.Item {
    return if (index == @intFromEnum(TrayKind.volume)) .volume else .network;
}

fn itemShown(bar: *Taskbar, item: taskbar_items.Item) bool {
    return bar.server.config.compositor.taskbar_items.shown(item) and (item != .battery or bar.battery_state.percent != null);
}

fn capturing(bar: *Taskbar) bool {
    const cm = bar.server.capture_mgr orelse return false;
    return cm.activeCount() > 0;
}

fn captureWidth(bar: *Taskbar) i32 {
    return @max(trayHit(), bar.captureLabelWidth() + 24);
}

fn captureLabelWidth(bar: *Taskbar) i32 {
    const scale = bar.wlr_output.scale;
    if (bar.capture_width.get(scale)) |width| return @intFromFloat(width);
    const width = text.measureWidth(capture_label, .manrope, 12, scale) catch return 80;
    return @intFromFloat(bar.capture_width.put(scale, @floatFromInt(width)));
}

fn captureX(bar: *Taskbar) f32 {
    return bar.rightLayout().left - @as(f32, @floatFromInt(tray_gap + bar.captureWidth()));
}

pub fn captureIndicatorBox(bar: *Taskbar) ?wlr.Box {
    if (!bar.capturing()) return null;
    const x = bar.captureX();
    return .{
        .x = bar.box.x + @as(i32, @intFromFloat(@round(x))),
        .y = bar.box.y + @divTrunc(bar.box.height - trayHit(), 2),
        .width = bar.captureWidth(),
        .height = trayHit(),
    };
}

fn sharedChipWidth(bar: *Taskbar, count: usize) f32 {
    const min_w: f32 = @floatFromInt(chipSize());
    const max_w = @max(min_w, ui_theme.global.chip_width);
    if (count == 0) return max_w;
    const available = chipsRightEdge(bar) - @as(f32, @floatFromInt(firstChipX()));
    const extra_gaps: usize = if (count > 1) count - 1 else 0;
    const gap_total = @as(f32, @floatFromInt(chipGap())) * @as(f32, @floatFromInt(extra_gaps));
    const each = (available - gap_total) / @as(f32, @floatFromInt(count));
    return @max(min_w, @min(max_w, each));
}

fn refreshStartLogo(bar: *Taskbar) void {
    const size_px = geometry.devicePixels(startIconSize(), bar.wlr_output.scale);
    const custom = ui_theme.global.start_button_icon;
    var lookup = bar.server.iconLookup(if (custom.len > 0) custom else start_button.builtin_logo, size_px);
    if (lookup != .ready and custom.len > 0) {
        lookup = bar.server.iconLookup(start_button.builtin_logo, size_px);
    }
    const old_id: ?u64 = if (bar.start_logo) |icon| icon.id else null;
    updateIcon(bar.server, &bar.start_logo, lookup);
    const new_id: ?u64 = if (bar.start_logo) |icon| icon.id else null;
    if (old_id != new_id) {
        bar.start_dirty = true;
        bar.markDirty(paint_start);
    }
}

// Keeps `IconService`'s refcount in sync with whichever icon `*held` last
// pointed at, mirroring `Toplevel.updateHeldIcon`. `held` is either
// `&bar.start_logo` or a chip's `&state.icon`.
fn updateIcon(server: *Server, held: *?icon_service.Entry, lookup: icon_service.Lookup) void {
    const new_icon: ?icon_service.Entry = switch (lookup) {
        .ready => |e| e,
        .pending, .missing => null,
    };
    const old_id: ?u64 = if (held.*) |e| e.id else null;
    const new_id: ?u64 = if (new_icon) |e| e.id else null;
    if (old_id != new_id) {
        if (old_id) |id| server.iconRelease(id);
        if (new_id) |id| server.iconAcquire(id);
    }
    held.* = new_icon;
}

// `world.toplevels` is the focus/raise stack (front = topmost), which
// reorders on every click. Chips must not visually shuffle when a window is
// merely focused or minimized, so we walk a copy sorted by each toplevel's
// stable creation-order `id` instead — the on-screen chip order then only
// changes when a window actually opens or closes.
fn taskbarOrderLessThan(_: void, a: *Toplevel, b: *Toplevel) bool {
    return (if (a.tab_group != 0) a.tab_group else a.id) < (if (b.tab_group != 0) b.tab_group else b.id);
}

// Returns whether any chip needs a frame: a new raster, a FLIP, or removal.
fn reconcile(bar: *Taskbar, now_ms: i64) bool {
    var changed = false;
    var visible: std.ArrayList(*Toplevel) = .empty;
    defer visible.deinit(gpa);
    var it = bar.server.world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        if (toplevel.tab_hidden or (toplevel.live_rules.skip_taskbar orelse false)) continue;
        visible.append(gpa, toplevel) catch break;
    }
    std.mem.sort(*Toplevel, visible.items, {}, taskbarOrderLessThan);

    const chip_w = sharedChipWidth(bar, visible.items.len);
    var next: std.ArrayList(ChipState) = .empty;
    var x: f32 = @floatFromInt(firstChipX());
    for (visible.items) |toplevel| {
        const new_target = x;
        var state: ChipState = found: {
            for (bar.chips.items, 0..) |chip, i| {
                if (chip.toplevel == toplevel) break :found bar.chips.orderedRemove(i);
            }
            break :found .{ .toplevel = toplevel, .target_x = new_target };
        };
        if (state.buffer_node == null) {
            const node = bar.tree.createSceneBuffer(null) catch |err| {
                log.err("reconcile: could not create chip buffer: {}", .{err});
                break;
            };
            node.setFilterMode(.bilinear);
            scene_data.SceneData.attach(&bar.node_data, &node.node);
            // Chips are created after the fixed tray/clock nodes, but their
            // original painter order was below those controls.
            node.node.placeBelow(&bar.clock_node.node);
            state.buffer_node = node;
        }
        const old_render = state.renderX(now_ms);
        state.kind = classify(toplevel);
        const app_id = toplevel.appId();
        updateIcon(bar.server, &state.icon, bar.server.iconLookup(app_id, geometry.devicePixels(tileSize(), bar.wlr_output.scale)));
        state.target_x = new_target;
        // Fixed width shared by every chip: it must not change when the
        // window's title changes, only when the width setting, available
        // space or number of open windows changes `chip_w` itself.
        state.width = chip_w;
        const delta = old_render - new_target;
        if (@abs(delta) >= 0.5) {
            // FLIP: the chip already occupies `delta` px away from its new
            // slot; ease that offset back to zero instead of jumping.
            state.flip = .initCurve(delta, 0, now_ms, anim.curveFor(.taskbar_flip));
            changed = true;
        }
        if (!state.dirty) {
            if (state.painted) |painted| {
                state.dirty = !std.meta.eql(painted, ChipMemo.capture(bar, &state, now_ms));
            } else state.dirty = true;
        }
        if (state.dirty) changed = true;
        next.append(gpa, state) catch break;
        x += state.width + @as(f32, @floatFromInt(chipGap()));
    }
    // Whatever is left belongs to windows that closed or left the taskbar.
    if (bar.chips.items.len > 0) changed = true;
    for (bar.chips.items) |chip| {
        if (chip.buffer_node) |node| node.node.destroy();
        if (chip.raster) |raster| raster.base.drop();
        if (chip.icon) |e| bar.server.iconRelease(e.id);
    }
    bar.chips.deinit(gpa);
    bar.chips = next;

    if (bar.hover_target == .chip) {
        var still_present = false;
        for (bar.chips.items) |chip| {
            if (chip.toplevel == bar.hover_target.chip) {
                still_present = true;
                break;
            }
        }
        if (!still_present) bar.hover_target = .none;
    }
    return changed;
}

// Runs once per output frame while anything is unsettled. Returns whether
// the caller should schedule another frame to keep the animation going.
pub fn tick(bar: *Taskbar, now_ms: i64) bool {
    var causes = bar.paint_causes;
    bar.paint_causes = 0;

    if (bar.server.audio) |mgr| {
        const gen = mgr.generation.load(.monotonic);
        if (gen != bar.audio_generation_seen) {
            bar.audio_generation_seen = gen;
            bar.audio_volume = mgr.getMasterVolume();
            bar.audio_muted = mgr.isMasterMuted();
            bar.tray_dirty[@intFromEnum(TrayKind.volume)] = true;
            causes |= paint_audio;
            bar.dirty = true;
        }
    }

    const sessions = if (bar.server.capture_mgr) |cm| cm.activeCount() else 0;
    if (sessions != bar.capture_sessions) {
        bar.capture_sessions = sessions;
        bar.capture_dirty = true;
        causes |= paint_capture | paint_chips;
        bar.dirty = true;
        _ = bar.reconcile(now_ms);
    }

    var animating = false;
    if (bar.battery_shimmer.sweep.sampleChanged(now_ms, anim.rasterPixelQuantum(bar.wlr_output.scale) / (battery_width + 46))) {
        if (bar.battery_state.percent != null) {
            bar.battery_dirty = true;
            causes |= paint_tray;
        }
    }
    if (!bar.battery_shimmer.sweep.settled(now_ms)) animating = true;
    // Press scales around the centre: convert the device-pixel step to the
    // amount that moves the outer edge by that distance.
    const press_quantum = 2 * anim.rasterPixelQuantum(bar.wlr_output.scale);
    const start_hover = bar.start.hover.sampleChanged(now_ms, anim.rasterAlphaQuantum());
    const start_open = bar.start.open_amt.sampleChanged(now_ms, anim.rasterAlphaQuantum());
    if (start_hover or start_open) {
        causes |= paint_start;
        if (start_hover) causes |= paint_hover;
        bar.start_dirty = true;
    }
    if (bar.start.animating(now_ms)) animating = true;

    for (bar.chips.items) |*chip| {
        const hover_moved = chip.hover.sampleChanged(now_ms, anim.rasterAlphaQuantum());
        const press_moved = chip.press.sampleChanged(now_ms, press_quantum / @max(chip.width, @as(f32, @floatFromInt(chipSize()))));
        if (hover_moved or press_moved) {
            causes |= paint_chips;
            if (hover_moved) causes |= paint_hover;
            if (press_moved) causes |= paint_press;
            chip.dirty = true;
        }
        // `flip` is the one chip curve with no `sampleChanged` above it (the
        // node position is applied straight from `renderX`), so it has to
        // record its own observation or it re-arms the output invisibly.
        const flip_live = anim.observeUnsettled(chip.flip, now_ms);
        if (flip_live or !chip.hover.settled(now_ms) or !chip.press.settled(now_ms)) {
            animating = true;
        }
        if (chip.buffer_node) |node| {
            node.node.setPosition(@as(i32, @intFromFloat(@round(chip.renderX(now_ms)))) - 2, 0);
        }
    }
    for (&bar.tray, 0..) |*t, i| {
        const hover_moved = t.hover.sampleChanged(now_ms, anim.rasterAlphaQuantum());
        const press_moved = t.press.sampleChanged(now_ms, press_quantum / @as(f32, @floatFromInt(trayHit())));
        if (hover_moved or press_moved) {
            causes |= paint_tray;
            if (hover_moved) causes |= paint_hover;
            if (press_moved) causes |= paint_press;
            bar.tray_dirty[i] = true;
        }
        if (!t.hover.settled(now_ms) or !t.press.settled(now_ms)) animating = true;
    }
    const cap_hover = bar.capture_hover.sampleChanged(now_ms, anim.rasterAlphaQuantum());
    const cap_press = bar.capture_press.sampleChanged(now_ms, press_quantum / @as(f32, @floatFromInt(@max(bar.captureWidth(), trayHit()))));
    if (cap_hover or cap_press) {
        causes |= paint_capture;
        if (cap_hover) causes |= paint_hover;
        if (cap_press) causes |= paint_press;
        bar.capture_dirty = true;
    }
    if (!bar.capture_hover.settled(now_ms) or !bar.capture_press.settled(now_ms)) animating = true;
    // A final changed sample still needs painting after the spring settles;
    // an unsettled sub-pixel tail alone does not need a raster pass.
    if (bar.dirty or causes != 0) {
        bar.render(now_ms, causes);
        bar.dirty = false;
        // An audio/capture event or `markDirty` repaints with no curve behind
        // it; say the picture moved or the frame reads as a wasted wakeup.
        anim.observeNoteChanged();
    }
    return animating;
}

pub fn captureAnimations(
    bar: *Taskbar,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(anim.LiveCapture),
    now_ms: i64,
) !void {
    try anim.captureIfLive(allocator, list, &bar.start.hover, .taskbar_hover, now_ms);
    try anim.captureIfLive(allocator, list, &bar.start.open_amt, .start_button, now_ms);
    try anim.captureIfLive(allocator, list, &bar.capture_hover, .taskbar_hover, now_ms);
    try anim.captureIfLive(allocator, list, &bar.capture_press, .taskbar_press, now_ms);
    for (bar.chips.items) |*chip| {
        try anim.captureIfLive(allocator, list, &chip.hover, .taskbar_hover, now_ms);
        try anim.captureIfLive(allocator, list, &chip.press, .taskbar_press, now_ms);
        try anim.captureIfLive(allocator, list, &chip.flip, .taskbar_flip, now_ms);
    }
    for (&bar.tray) |*t| {
        try anim.captureIfLive(allocator, list, &t.hover, .taskbar_hover, now_ms);
        try anim.captureIfLive(allocator, list, &t.press, .taskbar_press, now_ms);
    }
}

pub fn appendAnimations(
    bar: *const Taskbar,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(protocol.AnimationData),
    now_ms: i64,
) !void {
    try appendLive(allocator, list, "taskbar.battery.highlight", bar.battery_shimmer.sweep, now_ms);
    try appendLive(allocator, list, "taskbar.start.hover", bar.start.hover, now_ms);
    try appendLive(allocator, list, "taskbar.start.open", bar.start.open_amt, now_ms);
    try appendLive(allocator, list, "taskbar.capture.hover", bar.capture_hover, now_ms);
    try appendLive(allocator, list, "taskbar.capture.press", bar.capture_press, now_ms);
    for (bar.chips.items) |chip| {
        const id = chip.toplevel.id;
        const hover_site = try std.fmt.allocPrint(allocator, "taskbar.chip.{d}.hover", .{id});
        try appendLive(allocator, list, hover_site, chip.hover, now_ms);
        const press_site = try std.fmt.allocPrint(allocator, "taskbar.chip.{d}.press", .{id});
        try appendLive(allocator, list, press_site, chip.press, now_ms);
        const flip_site = try std.fmt.allocPrint(allocator, "taskbar.chip.{d}.flip", .{id});
        try appendLive(allocator, list, flip_site, chip.flip, now_ms);
    }
    for (&bar.tray) |t| {
        const hover_site = try std.fmt.allocPrint(allocator, "taskbar.tray.{s}.hover", .{@tagName(t.kind)});
        try appendLive(allocator, list, hover_site, t.hover, now_ms);
        const press_site = try std.fmt.allocPrint(allocator, "taskbar.tray.{s}.press", .{@tagName(t.kind)});
        try appendLive(allocator, list, press_site, t.press, now_ms);
    }
}

fn appendLive(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(protocol.AnimationData),
    site: []const u8,
    a: Anim,
    now_ms: i64,
) !void {
    if (!a.active()) return;
    try list.append(allocator, .{
        .site = site,
        .value = a.value(now_ms),
        .velocity = a.velocity(now_ms),
        .target = a.to,
        .settled = a.settled(now_ms),
        .curve = a.curveName(),
    });
}

fn trayPositions(bar: *Taskbar) [2]f32 {
    const positions = bar.rightLayout().x;
    return .{ positions[@intFromEnum(taskbar_items.Item.volume)] orelse 0, positions[@intFromEnum(taskbar_items.Item.network)] orelse 0 };
}

pub fn hitTest(bar: *Taskbar, sx: f64, sy: f64) Target {
    const bh = bar.box.height;
    if (sy < 0 or sy >= @as(f64, @floatFromInt(bh))) return .none;
    if (bar.itemShown(.clock) and sx >= bar.clockX() and sx < bar.clockX() + bar.clockColumnWidth()) return .clock;
    if (bar.itemShown(.battery) and sx >= bar.batteryX() and sx < bar.batteryX() + battery_width) return .battery;
    if (start_button.hitTest(sx, sy, bh, startButtonLeft(), buttonSize())) return .start_button;
    const now_ms = nowMs();
    for (bar.chips.items) |chip| {
        const x = chip.renderX(now_ms);
        if (sx >= x and sx < x + @as(f64, chip.width)) return .{ .chip = chip.toplevel };
    }
    const positions = bar.trayPositions();
    const ty: f64 = @floatFromInt(@divTrunc(bh - trayHit(), 2));
    if (sy >= ty and sy < ty + @as(f64, @floatFromInt(trayHit()))) {
        if (bar.capturing()) {
            const cx = bar.captureX();
            const cw: f64 = @floatFromInt(bar.captureWidth());
            if (sx >= cx and sx < cx + cw) return .capture_indicator;
        }
        for (positions, 0..) |tx, i| {
            if (!bar.itemShown(trayItem(i))) continue;
            if (sx >= tx and sx < tx + @as(f64, @floatFromInt(trayHit()))) return .{ .tray = i };
        }
    }
    return .none;
}

pub fn pointerMotion(bar: *Taskbar, sx: f64, sy: f64) void {
    const target = bar.hitTest(sx, sy);
    if (targetEql(target, bar.hover_target)) return;
    const now_ms = nowMs();
    const old = markPaintCauseFromTarget(bar.hover_target);
    bar.setHover(bar.hover_target, 0, now_ms);
    bar.setHover(target, 1, now_ms);
    const next = markPaintCauseFromTarget(target);
    bar.hover_target = target;
    _ = bar.server.world.peekTarget();
    bar.server.scheduleFrames();
    bar.markDirty(old | next | paint_hover);
    bar.wlr_output.scheduleFrame();
}

pub fn pointerLeave(bar: *Taskbar) void {
    bar.pointerMotion(-1, -1);
}

fn setHover(bar: *Taskbar, target: Target, to: f32, now_ms: i64) void {
    switch (target) {
        .none, .clock, .battery => {},
        .start_button => {
            bar.start.hover.retargetTo(now_ms, to, anim.curveFor(.taskbar_hover));
            bar.start_dirty = true;
        },
        .chip => |toplevel| {
            for (bar.chips.items) |*chip| {
                if (chip.toplevel == toplevel) {
                    chip.hover.retargetTo(now_ms, to, anim.curveFor(.taskbar_hover));
                    chip.dirty = true;
                    break;
                }
            }
        },
        .tray => |i| {
            bar.tray[i].hover.retargetTo(now_ms, to, anim.curveFor(.taskbar_hover));
            bar.tray_dirty[i] = true;
        },
        .capture_indicator => {
            bar.capture_hover.retargetTo(now_ms, to, anim.curveFor(.taskbar_hover));
            bar.capture_dirty = true;
        },
    }
}

// Clicks act on press, matching Input.cursorButton's existing convention
// (window chrome and focus both act on press; release is never routed
// further than clearing the cursor mode).
pub fn pointerPress(bar: *Taskbar, sx: f64, sy: f64) void {
    const now_ms = nowMs();
    var did_mutate = false;
    switch (bar.hitTest(sx, sy)) {
        .none => {},
        .clock => if (Output.fromWlr(bar.wlr_output)) |output| output.toggleCalendar(),
        .battery => if (Output.fromWlr(bar.wlr_output)) |output| output.toggleBattery(),
        .start_button => {
            bar.markDirty(paint_start | paint_press);
            bar.start_dirty = true;
            did_mutate = true;
            if (Output.fromWlr(bar.wlr_output)) |output| output.toggleStartMenu();
        },
        .chip => |toplevel| {
            bar.markDirty(paint_chips | paint_press);
            did_mutate = true;
            for (bar.chips.items) |*chip| {
                if (chip.toplevel == toplevel) {
                    chip.dirty = true;
                    chip.press.pulseTo(now_ms, press_scale, 1, anim.curveFor(.taskbar_press));
                    break;
                }
            }
            if (Output.fromWlr(bar.wlr_output)) |output| {
                const world = &bar.server.world;
                const focused = @import("ipc/handlers.zig").findFocusedToplevel(bar.server) == toplevel;
                if (!toplevel.minimized and focused and world.isWindowVisible(toplevel, output)) {
                    toplevel.minimize();
                } else {
                    if (toplevel.minimized) toplevel.restore() else world.focus(toplevel);
                    world.navigateTo(toplevel, output);
                }
            }
        },
        .tray => |i| {
            bar.markDirty(paint_tray | paint_press);
            bar.tray_dirty[i] = true;
            did_mutate = true;
            bar.tray[i].press.pulseTo(now_ms, press_scale, 1, anim.curveFor(.taskbar_press));
            if (@as(TrayKind, @enumFromInt(i)) == .wifi) {
                if (Output.fromWlr(bar.wlr_output)) |out| out.toggleWifi();
            }
            if (@as(TrayKind, @enumFromInt(i)) == .volume) {
                if (bar.server.audio) |mgr| {
                    mgr.toggleMasterMute();
                    bar.audio_muted = mgr.isMasterMuted();
                }
            }
        },
        .capture_indicator => {
            bar.markDirty(paint_capture | paint_press);
            bar.capture_dirty = true;
            did_mutate = true;
            bar.capture_press.pulseTo(now_ms, press_scale, 1, anim.curveFor(.taskbar_press));
            if (bar.server.capture_mgr) |cm| cm.stopAll();
        },
    }
    if (did_mutate) bar.wlr_output.scheduleFrame();
}

/// Scroll wheel over the volume tray icon: ±`volume_scroll_step` per tick.
/// Called from Input.processAxis's scroll-hit switch — the taskbar itself
/// has no other scrollable surface, so this is the only scroll case it needs.
pub fn scrollVolume(bar: *Taskbar, sx: f64, sy: f64, delta_px: f32) void {
    const idx = switch (bar.hitTest(sx, sy)) {
        .tray => |i| i,
        else => return,
    };
    if (@as(TrayKind, @enumFromInt(idx)) != .volume) return;
    const mgr = bar.server.audio orelse return;
    // Natural convention: scrolling up (negative delta) raises volume.
    const direction: f32 = if (delta_px < 0) 1 else -1;
    mgr.setMasterVolume(std.math.clamp(mgr.getMasterVolume() + direction * volume_scroll_step, 0, 1));
    bar.tray_dirty[@intFromEnum(TrayKind.volume)] = true;
    bar.markDirty(paint_tray);
    bar.wlr_output.scheduleFrame();
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn matchesAny(app_id: []const u8, title: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCase(app_id, needle) or containsIgnoreCase(title, needle)) return true;
    }
    return false;
}

// Fallback path for when icon_cache.get() finds no real XDG-theme icon for
// the client's app_id (see reconcile()): classifies by app_id/title against
// the demo suite this spec was drawn from, so there's still a themed tile
// with a recognizable glyph rather than a bare monogram in the common case.
fn classify(toplevel: *Toplevel) AppKind {
    const app_id = toplevel.appId();
    const title = toplevel.title();
    if (matchesAny(app_id, title, &.{ "term", "foot", "alacritty", "kitty", "konsole", "xterm" })) return .terminal;
    if (matchesAny(app_id, title, &.{ "file", "explorer", "nautilus", "files", "dolphin" })) return .file_explorer;
    if (matchesAny(app_id, title, &.{"note"})) return .notes;
    if (matchesAny(app_id, title, &.{ "setting", "config" })) return .settings;
    if (matchesAny(app_id, title, &.{ "browser", "firefox", "chrom", "web" })) return .browser;
    if (matchesAny(app_id, title, &.{ "text", "doc", "edit", "gedit", "vim", "emacs", "write" })) return .text_doc;
    return .other;
}

fn chipTitle(toplevel: *Toplevel) []const u8 {
    const window_title = toplevel.title();
    if (window_title.len > 0) return window_title;
    const app_id = toplevel.appId();
    if (app_id.len > 0) return app_id;
    return "";
}

fn monogramOf(toplevel: *Toplevel, storage: *[4]u8) []const u8 {
    const title = toplevel.title();
    const app_id = toplevel.appId();
    const source = if (title.len > 0) title else if (app_id.len > 0) app_id else "?";
    const first = source[0];
    if (first < 0x80) {
        storage[0] = std.ascii.toUpper(first);
        return storage[0..1];
    }
    var end: usize = 1;
    while (end < source.len and end < 4 and (source[end] & 0xc0) == 0x80) : (end += 1) {}
    @memcpy(storage[0..end], source[0..end]);
    return storage[0..end];
}

// ---- Colors (design-system tokens shared with chrome.zig where noted) ----
const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    // Exact CSS tints; glass.c supplies the filtered backdrop underneath.
    fn bar_fill() Color {
        return fromRgba(ui_theme.global.taskbar_bg);
    }
    fn hairline() Color {
        return fromRgba(ui_theme.global.border_soft);
    }
    fn chip_idle() Color {
        return fromRgba(ui_theme.global.taskbar_surface);
    }
    fn hover_fill() Color {
        return fromRgba(ui_theme.global.surface_hover);
    }
    fn active_fill() Color {
        return fromRgba(ui_theme.global.taskbar_hover).scaled(2.8);
    }
    pub fn fromRgba(c: [4]f32) Color {
        return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
    }
    fn chip_title_idle() text.Color {
        return textColor(fromRgba(ui_theme.global.window_fg));
    }
    fn tray_icon() Color {
        return fromRgba(ui_theme.global.window_fg);
    }
    fn tray_icon_hover() Color {
        return fromRgba(ui_theme.global.window_fg);
    }
    const glyph = Color{ .r = 1, .g = 1, .b = 1, .a = 0.96 };
    fn clock_time() text.Color {
        return textColor(fromRgba(ui_theme.global.window_fg));
    }
    fn clock_date() text.Color {
        return textColor(fromRgba(ui_theme.global.window_dim));
    }

    pub fn over(source: Color, destination: Color) Color {
        const alpha = source.a + destination.a * (1 - source.a);
        if (alpha == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        return .{
            .r = (source.r * source.a + destination.r * destination.a * (1 - source.a)) / alpha,
            .g = (source.g * source.a + destination.g * destination.a * (1 - source.a)) / alpha,
            .b = (source.b * source.a + destination.b * destination.a * (1 - source.a)) / alpha,
            .a = alpha,
        };
    }

    pub fn lerp(from: Color, to: Color, t: f32) Color {
        const ct = clamp01(t);
        return .{
            .r = from.r + (to.r - from.r) * ct,
            .g = from.g + (to.g - from.g) * ct,
            .b = from.b + (to.b - from.b) * ct,
            .a = from.a + (to.a - from.a) * ct,
        };
    }

    pub fn scaled(color: Color, alpha: f32) Color {
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = clamp01(color.a * alpha) };
    }

    // Unpacks a premultiplied 0xAARRGGBB sample (icon_cache.Entry.pixels'
    // format) back to this struct's straight alpha, so it can go through the
    // existing `.over()` blend unchanged.
    fn fromPremultiplied(sample: u32) Color {
        const a: f32 = @as(f32, @floatFromInt((sample >> 24) & 0xff)) / 255.0;
        if (a == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const r: f32 = @as(f32, @floatFromInt((sample >> 16) & 0xff)) / 255.0;
        const g: f32 = @as(f32, @floatFromInt((sample >> 8) & 0xff)) / 255.0;
        const b: f32 = @as(f32, @floatFromInt(sample & 0xff)) / 255.0;
        return .{ .r = r / a, .g = g / a, .b = b / a, .a = a };
    }

    fn argb(color: Color) u32 {
        return (col.Straight{ .r = color.r, .g = color.g, .b = color.b, .a = color.a }).argb();
    }
};

// ---- Tile fills, straight from the App Fills table (135deg gradients) ----
const Fill = union(enum) { solid: Color, gradient: struct { a: Color, b: Color } };

fn hex(r: u8, g: u8, b: u8) Color {
    return .{ .r = @as(f32, @floatFromInt(r)) / 255.0, .g = @as(f32, @floatFromInt(g)) / 255.0, .b = @as(f32, @floatFromInt(b)) / 255.0, .a = 1 };
}

const TileStyle = struct { fill: Fill, hairline: bool };

fn tileStyle(kind: AppKind) TileStyle {
    return switch (kind) {
        .file_explorer => .{ .fill = .{ .gradient = .{ .a = hex(0x22, 0xd3, 0xee), .b = hex(0x08, 0x91, 0xb2) } }, .hairline = false },
        .notes => .{ .fill = .{ .gradient = .{ .a = hex(0xfb, 0xbf, 0x24), .b = hex(0xd9, 0x76, 0x06) } }, .hairline = false },
        .terminal => .{ .fill = .{ .solid = hex(0x0d, 0x11, 0x17) }, .hairline = true },
        .settings, .other => .{ .fill = .{ .solid = Color{ .r = 1, .g = 1, .b = 1, .a = 0.08 } }, .hairline = true },
        .text_doc => .{ .fill = .{ .gradient = .{ .a = hex(0x60, 0xa5, 0xfa), .b = hex(0x25, 0x63, 0xeb) } }, .hairline = false },
        .browser => .{ .fill = .{ .gradient = .{ .a = hex(0x38, 0xbd, 0xf8), .b = hex(0x63, 0x66, 0xf1) } }, .hairline = false },
    };
}

fn textColor(color: Color) text.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

fn gradientColor(a: Color, b: Color, px: f32, py: f32, x: f32, y: f32, w: f32, h: f32) Color {
    // A 135deg (top-left to bottom-right) diagonal, which for a square tile
    // is just the averaged normalized projection onto both axes.
    const t = clamp01(((px - x) / w + (py - y) / h) / 2);
    return Color.lerp(a, b, t);
}

// ---- SDF primitives and per-app glyphs (26x26 tile, coords tile-centered) ----
fn sdCircle(px: f32, py: f32, cx: f32, cy: f32, r: f32) f32 {
    return @sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy)) - r;
}

// Terminal and the unrecognized-client fallback are stamped as text
// afterward (">_" and a monogram) instead of hand-drawn vectors.
fn glyphSd(kind: AppKind, gx: f32, gy: f32) ?f32 {
    return switch (kind) {
        .file_explorer => @min(
            chrome.sdRoundedBox(gx, gy, -8, -3, 16, 9, 2),
            chrome.sdRoundedBox(gx, gy, -8, -6, 7, 4, 1),
        ),
        .notes => @min(
            @min(
                chrome.sdRoundedBox(gx, gy, -7, -6, 14, 2, 1),
                chrome.sdRoundedBox(gx, gy, -7, -1, 14, 2, 1),
            ),
            chrome.sdRoundedBox(gx, gy, -7, 4, 10, 2, 1),
        ),
        .settings => @min(
            @abs(sdCircle(gx, gy, 0, 0, 7)) - 1.6,
            sdCircle(gx, gy, 0, 0, 2),
        ),
        .text_doc => @min(
            @min(
                @abs(chrome.sdRoundedBox(gx, gy, -7, -9, 14, 18, 2)) - 1.4,
                chrome.sdRoundedBox(gx, gy, -4, -3, 8, 1.6, 0.8),
            ),
            chrome.sdRoundedBox(gx, gy, -4, 1, 8, 1.6, 0.8),
        ),
        .browser => @min(
            @min(
                @abs(sdCircle(gx, gy, 0, 0, 9)) - 1.6,
                chrome.sdRoundedBox(gx, gy, -9, -0.8, 18, 1.6, 0.8),
            ),
            chrome.sdRoundedBox(gx, gy, -0.8, -9, 1.6, 18, 0.8),
        ),
        .terminal, .other => null,
    };
}

fn edgeCoverage(distance: f32, scale: f32) f32 {
    return clamp01(0.5 - distance * scale);
}

fn clamp01(value: f32) f32 {
    return @max(0, @min(1, value));
}

// ---- The buffer itself: same data-pointer wlr.Buffer technique as
// chrome.ChromeBuffer, recreated wholesale on every repaint. ----
const BarBuffer = struct {
    base: wlr.Buffer,
    width: i32,
    height: i32,
    logical_width: i32,
    scale: f32,
    pixels: []u32,

    const drm_format_argb8888: u32 = 0x34325241;

    const impl = wlr.Buffer.Impl{
        .destroy = destroyBuffer,
        .get_dmabuf = null,
        .get_shm = null,
        .begin_data_ptr_access = beginDataPtrAccess,
        .end_data_ptr_access = endDataPtrAccess,
    };

    fn create(logical_width: i32, logical_height: i32, scale: f32) !*BarBuffer {
        const buf = try gpa.create(BarBuffer);
        errdefer gpa.destroy(buf);

        const width = geometry.devicePixels(logical_width, scale);
        const height = geometry.devicePixels(logical_height, scale);
        const length: usize = @intCast(width * height);
        const pixels = try gpa.alloc(u32, length);
        errdefer gpa.free(pixels);

        buf.* = .{ .base = undefined, .width = width, .height = height, .logical_width = logical_width, .scale = scale, .pixels = pixels };
        buf.base.init(&impl, width, height);
        return buf;
    }

    fn destroyBuffer(base: *wlr.Buffer) callconv(.c) void {
        const buf: *BarBuffer = @fieldParentPtr("base", base);
        gpa.free(buf.pixels);
        gpa.destroy(buf);
    }

    fn beginDataPtrAccess(base: *wlr.Buffer, _: u32, data: **anyopaque, format: *u32, stride: *usize) callconv(.c) bool {
        const buf: *BarBuffer = @fieldParentPtr("base", base);
        data.* = @ptrCast(buf.pixels.ptr);
        format.* = drm_format_argb8888;
        stride.* = @as(usize, @intCast(buf.width)) * @sizeOf(u32);
        return true;
    }

    fn endDataPtrAccess(_: *wlr.Buffer) callconv(.c) void {}
};

const Part = union(enum) { background, start, clock, chip: *const ChipState, tray: usize, capture, battery };

fn render(bar: *Taskbar, now_ms: i64, causes: u8) void {
    if (bar.box.width <= 0) return;
    bar.renderAppTray();
    const bh = bar.box.height;
    if (bar.background_dirty) {
        renderPart(bar, now_ms, .background, 0, 0, bar.box.width, bh, bar.buffer_node, null);
        bar.background_dirty = false;
    }
    if (bar.start_dirty) {
        renderPart(bar, now_ms, .start, startButtonLeft() - 2, 0, buttonSize() + 4, bh, bar.start_node, null);
        bar.start_dirty = false;
    }
    const positions = bar.trayPositions();
    for (positions, 0..) |x, i| {
        bar.tray_nodes[i].node.setEnabled(bar.itemShown(trayItem(i)));
        if (!bar.itemShown(trayItem(i)) or !bar.tray_dirty[i]) continue;
        const left: i32 = @as(i32, @intFromFloat(@floor(x))) - 2;
        renderPart(bar, now_ms, .{ .tray = i }, left, 0, trayHit() + 4, bh, bar.tray_nodes[i], null);
        if (i == @intFromEnum(TrayKind.volume) and (causes & paint_audio) != 0) stats.recordTaskbarAudioPaint();
        bar.tray_dirty[i] = false;
    }
    bar.clock_node.node.setEnabled(bar.itemShown(.clock));
    if (bar.itemShown(.clock) and bar.clock_dirty) {
        const left: i32 = @intFromFloat(@floor(bar.clockX()));
        renderPart(bar, now_ms, .clock, left, 0, @intFromFloat(@ceil(clockColumnWidth(bar))), bh, bar.clock_node, null);
        bar.clock_dirty = false;
    }
    if (bar.itemShown(.battery)) {
        const left: i32 = @intFromFloat(@floor(bar.batteryX()));
        // Keep the node aligned with the configured item order.
        bar.battery_node.node.setPosition(left, 0);
        if (bar.battery_dirty) {
            renderPart(bar, now_ms, .battery, left, 0, battery_width, bh, bar.battery_node, null);
            bar.battery_dirty = false;
        }
        bar.battery_node.node.setEnabled(true);
    } else bar.battery_node.node.setEnabled(false);
    if (bar.capturing()) {
        if (bar.capture_dirty) {
            const x = bar.captureX();
            const left: i32 = @as(i32, @intFromFloat(@floor(x))) - 2;
            renderPart(bar, now_ms, .capture, left, 0, bar.captureWidth() + 4, bh, bar.capture_node, null);
            bar.capture_node.node.setEnabled(true);
            bar.capture_dirty = false;
        }
    } else {
        bar.capture_node.node.setEnabled(false);
        bar.capture_dirty = false;
    }
    for (bar.chips.items) |*chip| if (chip.dirty) {
        const left: i32 = @as(i32, @intFromFloat(@round(chip.renderX(now_ms)))) - 2;
        const width: i32 = @as(i32, @intFromFloat(@ceil(chip.width))) + 4;
        const memo = ChipMemo.capture(bar, chip, now_ms);
        if (chip.buffer_node) |node| {
            const key = ChipRasterKey.capture(bar, now_ms, chip, left, width);
            if (!repaintChipTitle(bar, now_ms, chip, memo, key, bh, node))
                renderPart(bar, now_ms, .{ .chip = chip }, left, 0, width, bh, node, &chip.raster);
            chip.raster_key = key;
        }
        chip.painted = memo;
        chip.dirty = false;
    };
    if ((causes & paint_hover) != 0) stats.recordTaskbarHoverPaint();
    if ((causes & paint_press) != 0) stats.recordTaskbarPressPaint();
}

/// `retain`, when given, keeps a reference to the new raster there (replacing
/// the one it held) instead of leaving the scene node as its only owner.
fn renderPart(bar: *Taskbar, now_ms: i64, part: Part, origin_x: i32, origin_y: i32, logical_width: i32, logical_height: i32, node: *wlr.SceneBuffer, retain: ?*?*BarBuffer) void {
    const started = stats.nowNs();
    const scale = bar.wlr_output.scale;
    const buf = BarBuffer.create(logical_width, logical_height, scale) catch |err| {
        log.err("renderPart: could not create taskbar buffer: {}", .{err});
        // What is retained no longer matches the screen.
        if (retain) |slot| if (slot.*) |old| {
            old.base.drop();
            slot.* = null;
        };
        return;
    };
    const stride: usize = @intCast(buf.width);
    // Animation easing and theme resolution are constant across this raster.
    // In particular, renderX solves a Bezier curve during FLIP: doing that
    // for every device pixel stalls the input loop on fractional-scale bars.
    const chip_paint: ?ChipPaint = switch (part) {
        .chip => |chip| ChipPaint.init(bar, now_ms, chip),
        else => null,
    };
    const sampled_start: start_button.Paint = if (part == .start) .init(bar.start, now_ms) else .{ .hover = 0, .open_amt = 0 };
    const hover = switch (part) {
        .tray => |i| bar.tray[i].hover.value(now_ms),
        .capture => bar.capture_hover.value(now_ms),
        else => 0,
    };
    const press = switch (part) {
        .tray => |i| bar.tray[i].press.value(now_ms),
        .capture => bar.capture_press.value(now_ms),
        else => 1,
    };
    // Layout measures the clock text. Never repeat it for each raster pixel.
    const part_x: f32 = switch (part) {
        .tray => |i| bar.trayPositions()[i],
        .capture => bar.captureX(),
        .battery => @floor(bar.batteryX()),
        else => 0,
    };
    const battery_progress = if (part == .battery) bar.battery_shimmer.sweep.value(now_ms) else 1;
    const part_width: f32 = if (part == .capture) @floatFromInt(bar.captureWidth()) else @floatFromInt(trayHit());
    if (chip_paint) |*paint| fillChipColumns(paint, buf.pixels, buf.width, buf.height, origin_x, origin_y, 0, stride, scale) else for (0..@intCast(buf.height)) |dy| {
        const py = @as(f32, @floatFromInt(origin_y)) + (@as(f32, @floatFromInt(dy)) + 0.5) / scale;
        for (0..stride) |dx| {
            const px = @as(f32, @floatFromInt(origin_x)) + (@as(f32, @floatFromInt(dx)) + 0.5) / scale;
            buf.pixels[dy * stride + dx] = if (part == .battery)
                paintBatteryPixel(bar, px - part_x, py, scale, battery_progress).argb()
            else
                paintPartPixel(bar, sampled_start, hover, press, part_x, part_width, part, px, py, scale).argb();
        }
    }
    if (part == .tray) {
        const i = part.tray;
        const color = if (i == @intFromEnum(TrayKind.volume) and bar.audio_muted)
            Color.fromRgba(ui_theme.global.danger)
        else
            Color.lerp(Color.tray_icon(), Color.tray_icon_hover(), hover);
        const size = 20 * press;
        var renderer = @import("ui").paint.Renderer.init(buf.pixels, buf.width, buf.height, scale);
        renderer.drawIcon(bar.trayPositions()[i] + @as(f32, @floatFromInt(trayHit())) / 2 - size / 2 - @as(f32, @floatFromInt(origin_x)), @as(f32, @floatFromInt(bar.box.height)) / 2 - size / 2 - @as(f32, @floatFromInt(origin_y)), size, size, .{ .id = if (i == @intFromEnum(TrayKind.wifi)) .wifi else if (bar.audio_muted) .volume_muted else .volume, .color = .{ color.r, color.g, color.b, color.a } });
    }
    drawPartText(bar, now_ms, part, buf, origin_x, origin_y);
    node.node.setPosition(origin_x, origin_y);
    node.setBuffer(&buf.base);
    node.setDestSize(logical_width, logical_height);
    if (retain) |slot| {
        if (slot.*) |old| old.base.drop();
        slot.* = buf;
    } else buf.base.drop();
    stats.recordTaskbarPaint(stats.nowNs() -% started, @as(u64, @intCast(buf.width)) * @as(u64, @intCast(buf.height)), switch (part) {
        .background => 0,
        .start => paint_start,
        .clock => paint_clock,
        .chip => paint_chips,
        .tray => paint_tray,
        .capture => 0,
        .battery => paint_tray,
    });
}

fn paintPartPixel(bar: *Taskbar, sampled_start: start_button.Paint, hover: f32, press: f32, part_x: f32, part_width: f32, part: Part, px: f32, py: f32, scale: f32) Color {
    switch (part) {
        .background => {
            var color = Color.bar_fill();
            if (py < 1) color = Color.hairline().over(color);
            return color;
        },
        .start => {
            const btn_size = buttonSize();
            var color = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
            if (start_button.paintPixel(sampled_start, px, py, bar.box.height, scale, startButtonLeft(), btn_size)) |sb| color = (Color{ .r = sb.r, .g = sb.g, .b = sb.b, .a = sb.a }).over(color);
            if (bar.start_logo) |icon| {
                const mapped = start_button.mapPoint(sampled_start, px, py, bar.box.height, startButtonLeft(), btn_size);
                const pad: f32 = @floatFromInt(@divTrunc(btn_size - startIconSize(), 2));
                const ix: i32 = @intFromFloat(@floor((mapped.x - (mapped.box_x + pad)) * scale));
                const iy: i32 = @intFromFloat(@floor((mapped.y - (mapped.box_y + pad)) * scale));
                if (ix >= 0 and ix < icon.size and iy >= 0 and iy < icon.size) {
                    var sample = Color.fromPremultiplied(icon.pixels[@intCast(iy * icon.size + ix)]);
                    if (ui_theme.global.start_button_icon.len == 0) {
                        if (ui_theme.global.start_button_logo_color) |tint| sample = Color.fromRgba(tint).scaled(sample.a);
                    }
                    color = sample.over(color);
                }
            }
            return color;
        },
        .battery => unreachable, // Animation sampled once per raster.
        .clock => return .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .chip => unreachable, // Prepared once by renderPart.
        .tray => return paintTrayPixel(bar, hover, press, part_x, px, py, scale),
        .capture => return paintCapturePixel(bar, hover, press, part_x, part_width, px, py, scale),
    }
}

// The badge artwork is `ui.widgets.battery`'s; this only places it in the bar.
// `x` is measured from the badge's left edge, `py` from the bar's top.
fn paintBatteryPixel(bar: *Taskbar, x: f32, py: f32, scale: f32, progress: f32) Color {
    const trh: f32 = @floatFromInt(trayHit());
    const c = battery_badge.sample(x, py - @as(f32, @floatFromInt(bar.box.height - trayHit())) / 2, scale, .{
        .percent = bar.battery_state.percent orelse 0,
        .plugged = bar.battery_state.plugged,
        .shimmer = progress,
        .height = trh,
    }, battery_badge.Colors.of(ui_theme.global));
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
}

fn paintCapturePixel(bar: *Taskbar, hover: f32, press: f32, tx: f32, tw: f32, px: f32, py: f32, scale: f32) Color {
    const tray_y: f32 = @floatFromInt(@divTrunc(bar.box.height - trayHit(), 2));
    const bcx = tx + tw / 2;
    const bcy = tray_y + @as(f32, @floatFromInt(trayHit())) / 2;
    const lx = (px - bcx) / press + bcx;
    const ly = (py - bcy) / press + bcy;
    var color = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const cov = edgeCoverage(chrome.sdRoundedBox(lx, ly, tx, tray_y, tw, @floatFromInt(trayHit()), tray_radius), scale);
    if (cov > 0) {
        const fill = Color.lerp(Color.fromRgba(ui_theme.global.danger), Color.fromRgba(ui_theme.global.window_close_hover), hover);
        color = fill.scaled(cov).over(color);
    }
    return color;
}

const ChipPaint = struct {
    chip: *const ChipState,
    x: f32,
    fill: Color,
    border: Color,
    bar_height: i32,
    flat: ChipFlat = .{},

    fn init(bar: *Taskbar, now_ms: i64, chip: *const ChipState) ChipPaint {
        const active = chip.toplevel == bar.server.world.toplevels.first();
        const hover = chip.hover.value(now_ms);
        const press_strength = std.math.clamp((1 - chip.press.value(now_ms)) / (1 - press_scale), 0, 1);
        const style = @import("taskbar/chip_style.zig").look(Color, active, chip.toplevel.needs_attention, hover, press_strength);
        var paint: ChipPaint = .{
            .chip = chip,
            .x = chip.renderX(now_ms),
            .fill = style.fill,
            .border = style.border,
            .bar_height = bar.box.height,
        };
        paint.flat = .init(&paint, bar.wlr_output.scale);
        return paint;
    }
};

// Most of a chip is empty or flat fill. Pixels at least one logical pixel
// from every edge and from the icon tile get exactly what `paintChipPixel`
// computes there, without its three SDFs, which were most of the raster
// time. One pixel of distance saturates coverage only from scale 0.75 up.
const ChipFlat = struct {
    enabled: bool = false,
    outer: Rect = undefined,
    // The inner rounded box, shrunk by the margin, minus its corners.
    band_h: Rect = undefined,
    band_v: Rect = undefined,
    tile: Rect = undefined,
    fill: u32 = 0,

    const Rect = struct {
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,

        fn contains(r: Rect, x: f32, y: f32) bool {
            return x >= r.x0 and x <= r.x1 and y >= r.y0 and y <= r.y1;
        }
    };

    fn init(paint: *const ChipPaint, scale: f32) ChipFlat {
        const x = paint.x;
        const y: f32 = @floatFromInt(@divTrunc(paint.bar_height - chipSize(), 2));
        const w = paint.chip.width;
        const h: f32 = @floatFromInt(chipSize());
        // `paintChipPixel`'s inner box, with sdRoundedBox's radius clamp.
        const iw = w - 2;
        const ih = h - 2;
        const corner = @max(1, @min(@max(0, ui_theme.global.radius - 1), @min(iw, ih) / 2));
        const tile_x = x + @as(f32, @floatFromInt(chipPad()));
        const tile_y = y + @as(f32, @floatFromInt(chipPad()));
        const tile: f32 = @floatFromInt(tileSize());
        const clear: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        return .{
            .enabled = scale >= 0.75,
            .outer = .{ .x0 = x - 1, .y0 = y - 1, .x1 = x + w + 1, .y1 = y + h + 1 },
            .band_h = .{ .x0 = x + 1 + corner, .y0 = y + 2, .x1 = x + 1 + iw - corner, .y1 = y + ih },
            .band_v = .{ .x0 = x + 2, .y0 = y + 1 + corner, .x1 = x + iw, .y1 = y + 1 + ih - corner },
            .tile = .{ .x0 = tile_x - 1, .y0 = tile_y - 1, .x1 = tile_x + tile + 1, .y1 = tile_y + tile + 1 },
            // The same expression `paintChipPixel` evaluates at full coverage.
            .fill = Color.lerp(paint.border, paint.fill, 1).scaled(1).over(clear).argb(),
        };
    }
};

fn chipPixelArgb(paint: *const ChipPaint, px: f32, py: f32, scale: f32) u32 {
    const flat = &paint.flat;
    if (flat.enabled and !flat.tile.contains(px, py)) {
        if (!flat.outer.contains(px, py)) return 0;
        if (flat.band_h.contains(px, py) or flat.band_v.contains(px, py)) return flat.fill;
    }
    return paintChipPixel(paint, px, py, scale).argb();
}

fn paintChipPixel(paint: *const ChipPaint, px: f32, py: f32, scale: f32) Color {
    const chip = paint.chip;
    const cx = paint.x;
    const chip_y: f32 = @floatFromInt(@divTrunc(paint.bar_height - chipSize(), 2));
    const lx = px;
    const ly = py;
    var color = @import("taskbar/chip_style.zig").pixel(Color, lx, ly, cx, chip_y, chip.width, @floatFromInt(chipSize()), ui_theme.global.radius, scale, paint.fill, paint.border);
    const tile_x = cx + @as(f32, @floatFromInt(chipPad()));
    const tile_y = chip_y + @as(f32, @floatFromInt(chipPad()));
    const tile_cov = edgeCoverage(chrome.sdRoundedBox(lx, ly, tile_x, tile_y, @floatFromInt(tileSize()), @floatFromInt(tileSize()), tile_radius), scale);
    if (tile_cov == 0) return color;
    if (chip.icon) |icon| {
        const ix: i32 = @intFromFloat(@floor((lx - tile_x) * scale));
        const iy: i32 = @intFromFloat(@floor((ly - tile_y) * scale));
        if (ix >= 0 and ix < icon.size and iy >= 0 and iy < icon.size) color = Color.fromPremultiplied(icon.pixels[@intCast(iy * icon.size + ix)]).scaled(tile_cov).over(color);
    } else {
        const style = tileStyle(chip.kind);
        const fill = switch (style.fill) {
            .solid => |v| v,
            .gradient => |g| gradientColor(g.a, g.b, lx, ly, tile_x, tile_y, @floatFromInt(tileSize()), @floatFromInt(tileSize())),
        };
        color = fill.scaled(tile_cov).over(color);
        if (style.hairline) {
            const stroke = edgeCoverage(@abs(chrome.sdRoundedBox(lx, ly, tile_x, tile_y, @floatFromInt(tileSize()), @floatFromInt(tileSize()), tile_radius)) - 0.6, scale);
            if (stroke > 0) color = Color.hairline().scaled(stroke).over(color);
        }
        if (glyphSd(chip.kind, (lx - tile_x - @as(f32, @floatFromInt(tileSize())) / 2) / icon_scale, (ly - tile_y - @as(f32, @floatFromInt(tileSize())) / 2) / icon_scale)) |sd| {
            const glyph_cov = edgeCoverage(sd * icon_scale, scale);
            if (glyph_cov > 0) color = Color.glyph.scaled(glyph_cov).over(color);
        }
    }
    return color;
}

fn paintTrayPixel(bar: *Taskbar, hover: f32, press: f32, tx: f32, px: f32, py: f32, scale: f32) Color {
    const tray_y: f32 = @floatFromInt(@divTrunc(bar.box.height - trayHit(), 2));
    const bcx = tx + @as(f32, @floatFromInt(trayHit())) / 2;
    const bcy = tray_y + @as(f32, @floatFromInt(trayHit())) / 2;
    const lx = (px - bcx) / press + bcx;
    const ly = (py - bcy) / press + bcy;
    var color = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    if (hover > 0) {
        const cov = edgeCoverage(chrome.sdRoundedBox(lx, ly, tx, tray_y, @floatFromInt(trayHit()), @floatFromInt(trayHit()), tray_radius), scale);
        if (cov > 0) color = Color.hover_fill().scaled(hover * cov).over(color);
    }
    // SVG glyphs are painted once after this background raster.
    return color;
}

/// Chip pixels for device columns `x0..x1` of a raster whose logical origin
/// is (`origin_x`, `origin_y`). Full and title-only chip repaints share it,
/// so both evaluate exactly the same expressions.
fn fillChipColumns(paint: *const ChipPaint, pixels: []u32, width: i32, height: i32, origin_x: i32, origin_y: i32, x0: usize, x1: usize, scale: f32) void {
    const stride: usize = @intCast(width);
    for (0..@intCast(height)) |dy| {
        const py = @as(f32, @floatFromInt(origin_y)) + (@as(f32, @floatFromInt(dy)) + 0.5) / scale;
        for (x0..x1) |dx| {
            const px = @as(f32, @floatFromInt(origin_x)) + (@as(f32, @floatFromInt(dx)) + 0.5) / scale;
            pixels[dy * stride + dx] = chipPixelArgb(paint, px, py, scale);
        }
    }
}

/// The chip title's box in raster-local logical pixels, or null when the chip
/// is too narrow to show one. `cx` is the chip's rounded left edge.
fn chipTitleRect(cx: i32, bar_h: i32, chip_width: f32, origin_x: i32, origin_y: i32) ?text.Rect {
    const tw: i32 = @as(i32, @intFromFloat(@round(chip_width))) - chipPad() - tileSize() - icon_text_gap - title_pad_right;
    if (tw < 16) return null;
    const cy = @divTrunc(bar_h - chipSize(), 2);
    return .{ .x = cx + chipPad() + tileSize() + icon_text_gap - origin_x, .y = cy - origin_y, .w = tw, .h = chipSize() };
}

fn chipTitleColor(bar: *Taskbar, chip: *const ChipState) text.Color {
    return if (chip.toplevel == bar.server.world.toplevels.first()) Color.clock_time() else Color.chip_title_idle();
}

fn drawChipTitle(pixels: []u32, width: i32, height: i32, rect: text.Rect, title: []const u8, color: text.Color, scale: f32) void {
    if (title.len == 0) return;
    // Keep a font-metric baseline: animated title glyphs change their ink
    // bounds, which must not shift the rest of the title up and down.
    text.draw(pixels, width, height, rect, title, color, scale, .manrope, ui_theme.global.taskbar_title_size) catch {};
}

/// Text is clipped to `rect`, so repainting that rect's device columns first
/// removes every pixel an earlier title touched.
fn paintChipTitleColumns(paint: *const ChipPaint, pixels: []u32, width: i32, height: i32, origin_x: i32, rect: text.Rect, title: []const u8, color: text.Color, scale: f32) void {
    // The same rounding text.drawOpts applies to its clip.
    const x0: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(rect.x)) * scale));
    const x1: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(rect.x + rect.w)) * scale));
    fillChipColumns(paint, pixels, width, height, origin_x, 0, @intCast(std.math.clamp(x0, 0, width)), @intCast(std.math.clamp(x1, 0, width)), scale);
    drawChipTitle(pixels, width, height, rect, title, color, scale);
}

/// Terminals animate their titles several times a second. When nothing but
/// the title changed, copy the previous raster and repaint only the title
/// box instead of the pill's edge and icon SDFs. False means a full raster
/// is needed.
fn repaintChipTitle(bar: *Taskbar, now_ms: i64, chip: *ChipState, memo: ChipMemo, key: ChipRasterKey, bar_h: i32, node: *wlr.SceneBuffer) bool {
    const previous = chip.raster orelse return false;
    const previous_key = chip.raster_key orelse return false;
    var painted = chip.painted orelse return false;
    if (!std.meta.eql(previous_key, key)) return false;
    painted.title_hash = memo.title_hash;
    if (!std.meta.eql(painted, memo)) return false;

    const started = stats.nowNs();
    const scale = bar.wlr_output.scale;
    const buf = BarBuffer.create(key.width, bar_h, scale) catch return false;
    if (buf.pixels.len != previous.pixels.len) {
        buf.base.drop();
        return false;
    }
    @memcpy(buf.pixels, previous.pixels);
    const cx: i32 = @intFromFloat(@round(chip.renderX(now_ms)));
    if (chipTitleRect(cx, bar.box.height, chip.width, key.left, 0)) |rect| {
        const paint = ChipPaint.init(bar, now_ms, chip);
        paintChipTitleColumns(&paint, buf.pixels, buf.width, buf.height, key.left, rect, chipTitle(chip.toplevel), chipTitleColor(bar, chip), scale);
    }
    node.node.setPosition(key.left, 0);
    node.setBuffer(&buf.base);
    node.setDestSize(key.width, bar_h);
    previous.base.drop();
    chip.raster = buf;
    stats.recordTaskbarPaint(stats.nowNs() -% started, @as(u64, @intCast(buf.width)) * @as(u64, @intCast(buf.height)), paint_chips);
    return true;
}

// Standalone status labels align their visible ink with adjacent icons.
fn drawCenteredText(pixels: []u32, width: i32, height: i32, rect: text.Rect, label: []const u8, color: text.Color, scale: f32, font: text.Font, size: f32) !void {
    try text.drawOpts(pixels, width, height, label, color, scale, font, size, .{ .rect = rect, .center_ink = true });
}

fn drawPartText(bar: *Taskbar, now_ms: i64, part: Part, buf: *BarBuffer, ox: i32, oy: i32) void {
    const scale = bar.wlr_output.scale;
    const local = struct {
        fn box(x: i32, y: i32, w: i32, h: i32, origin_x: i32, origin_y: i32) text.Rect {
            return .{ .x = x - origin_x, .y = y - origin_y, .w = w, .h = h };
        }
    }.box;
    switch (part) {
        .start => if (bar.start_logo == null) {
            const btn_size = buttonSize();
            const w = text.measureWidth("R", .mono_bold, start_button.glyph_size_px, scale) catch 0;
            drawCenteredText(buf.pixels, buf.width, buf.height, local(startButtonLeft() + @divTrunc(btn_size - w, 2), @intFromFloat(@round(start_button.top(bar.box.height, btn_size))), btn_size, btn_size, ox, oy), "R", textColor(Color.fromRgba(ui_theme.global.start_button_logo_color orelse .{ 1, 1, 1, 1 })), scale, .mono_bold, start_button.glyph_size_px) catch {};
        },
        .clock => {
            const time = std.mem.trimStart(u8, std.mem.sliceTo(&bar.clock_time, 0), " ");
            const date = std.mem.sliceTo(&bar.clock_date, 0);
            const tw = text.measureWidth(time, .manrope, 14, scale) catch 0;
            const dw = text.measureWidth(date, .manrope, 11, scale) catch 0;
            // Keep both lines left-aligned, with the wider line at the column's
            // right edge rather than leaving the reserved width empty there.
            const right: i32 = @intFromFloat(@round(bar.clockX() + bar.clockColumnWidth()));
            const left = right - @max(tw, dw) - 1;
            const clock_h: i32 = 37;
            const time_y = @divTrunc(bar.box.height - clock_h, 2);
            const date_y = time_y + 21;
            drawCenteredText(buf.pixels, buf.width, buf.height, local(left, time_y, tw + 1, 20, ox, oy), time, Color.clock_time(), scale, .manrope, 14) catch {};
            drawCenteredText(buf.pixels, buf.width, buf.height, local(left, date_y, dw + 1, 16, ox, oy), date, Color.clock_date(), scale, .manrope, 11) catch {};
        },
        .chip => |chip| {
            const cx: i32 = @intFromFloat(@round(chip.renderX(now_ms)));
            const cy = @divTrunc(bar.box.height - chipSize(), 2);
            if (chip.icon == null and (chip.kind == .terminal or chip.kind == .other)) {
                var storage: [4]u8 = undefined;
                const label: []const u8 = if (chip.kind == .terminal) ">_" else monogramOf(chip.toplevel, &storage);
                const w = text.measureWidth(label, .manrope, 14 * icon_scale, scale) catch 0;
                if (w > 0) drawCenteredText(buf.pixels, buf.width, buf.height, local(cx + chipPad() + @divTrunc(tileSize() - w, 2), cy + chipPad(), tileSize(), tileSize(), ox, oy), label, textColor(Color.glyph), scale, .manrope, 14 * icon_scale) catch {};
            }
            if (chipTitleRect(cx, bar.box.height, chip.width, ox, oy)) |rect| drawChipTitle(buf.pixels, buf.width, buf.height, rect, chipTitle(chip.toplevel), chipTitleColor(bar, chip), scale);
        },
        .tray => {},
        .capture => {
            const tx: i32 = @intFromFloat(@round(bar.captureX()));
            const tw = bar.captureWidth();
            const label_w = text.measureWidth(capture_label, .manrope, 12, scale) catch 0;
            drawCenteredText(
                buf.pixels,
                buf.width,
                buf.height,
                local(tx + @divTrunc(tw - label_w, 2), @divTrunc(bar.box.height - trayHit(), 2), tw, trayHit(), ox, oy),
                capture_label,
                .{ .r = 1, .g = 1, .b = 1, .a = 1 },
                scale,
                .manrope,
                12,
            ) catch {};
        },
        .battery => {
            var label_buf: [8]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{d}%", .{bar.battery_state.percent orelse 0}) catch unreachable;
            drawCenteredText(buf.pixels, buf.width, buf.height, .{ .x = @intFromFloat(battery_badge.label_x), .y = @divTrunc(bar.box.height - trayHit(), 2), .w = @intFromFloat(battery_badge.label_w), .h = trayHit() }, label, Color.clock_time(), scale, .manrope, battery_badge.label_size) catch {};
        },
        .background => {},
    }
}

// Theme-driven item sizing must reproduce the default 42/23/34px layout
// at the defaults, then scale down as the bar shrinks or the item
// gap grows, staying at or above the floors that keep pills/tiles/targets
// legible and non-overlapping.
test "chip/tile/tray sizing matches default theme" {
    const saved = ui_theme.global;
    defer ui_theme.global = saved;
    ui_theme.global = .{};

    try std.testing.expectEqual(@as(i32, base_chip_size), chipSize());
    try std.testing.expectEqual(@as(i32, @intFromFloat(@round(base_tile_size))), tileSize());
    try std.testing.expectEqual(@as(i32, 9), chipPad());
    try std.testing.expectEqual(@as(i32, base_tray_hit), trayHit());
    try std.testing.expectEqual(chipSize(), buttonSize());
}

test "shrinking the bar to its floor shrinks items without collapsing them" {
    const saved = ui_theme.global;
    defer ui_theme.global = saved;
    ui_theme.global = .{};
    ui_theme.global.taskbar_size = @floatFromInt(min_bar_height);

    try std.testing.expect(chipSize() < base_chip_size);
    try std.testing.expect(chipSize() >= min_chip_size);
    try std.testing.expect(tileSize() >= min_tile_size);
    try std.testing.expect(trayHit() >= min_tray_hit);
    try std.testing.expect(chipPad() >= 0);
}

test "a large item gap grows the pill's vertical margin up to the cap" {
    const saved = ui_theme.global;
    defer ui_theme.global = saved;
    ui_theme.global = .{};
    ui_theme.global.chip_gap = 1000;

    try std.testing.expectEqual(max_chip_vertical_margin, chipVerticalMargin());
    try std.testing.expect(chipSize() >= min_chip_size);
}

test "start button gap and icon size are theme-driven and icon is capped to the button" {
    const saved = ui_theme.global;
    defer ui_theme.global = saved;
    ui_theme.global = .{};

    try std.testing.expectEqual(@as(i32, 4), startButtonGap());
    try std.testing.expectEqual(@as(i32, 4), startButtonLeft());
    try std.testing.expectEqual(@as(i32, 4 + buttonSize() + 4), firstChipX());
    try std.testing.expectEqual(@as(i32, base_chip_size), startIconSize());

    ui_theme.global.start_button_gap = 24;
    try std.testing.expectEqual(@as(i32, 24), startButtonLeft());
    try std.testing.expectEqual(@as(i32, 24 + buttonSize() + 24), firstChipX());
    ui_theme.global.start_button_gap = 16;

    // A configured icon size larger than the (shrunk) button must not
    // overflow the button it is centered in.
    ui_theme.global.taskbar_size = @floatFromInt(min_bar_height);
    ui_theme.global.start_button_icon_size = 42;
    try std.testing.expect(startIconSize() <= buttonSize());
}

test "chip flat-fill fast path is bit-identical to the full SDF raster" {
    const saved = ui_theme.global;
    defer ui_theme.global = saved;
    ui_theme.global = .{};

    var icon_pixels: [64 * 64]u32 = undefined;
    for (&icon_pixels, 0..) |*p, i| p.* = if (i % 7 == 0) 0x80402010 else 0xff3366cc;
    const icon: icon_service.Entry = .{ .id = 1, .pixels = &icon_pixels, .size = 64 };

    var fast: usize = 0;
    var total: usize = 0;
    for ([_]f32{ 0, 0.5, 1, 5, 12 }) |radius| {
        ui_theme.global.radius = radius;
        for ([_]f32{ 0.75, 1, 1.25, 1.5, 2, 3 }) |scale| {
            for ([_]f32{ 78, 78.3, 366.5 }) |x| {
                for ([_]?icon_service.Entry{ null, icon }) |chip_icon| {
                    for ([_]AppKind{ .terminal, .browser }) |kind| {
                        const chip: ChipState = .{ .toplevel = undefined, .kind = kind, .icon = chip_icon, .width = 280.25 };
                        var paint: ChipPaint = .{
                            .chip = &chip,
                            .x = x,
                            .fill = Color.fromRgba(ui_theme.global.taskbar_hover),
                            .border = Color.fromRgba(ui_theme.global.taskbar_border).scaled(1.6),
                            .bar_height = default_bar_height,
                        };
                        paint.flat = .init(&paint, scale);
                        const origin_x = @round(x) - 2;
                        const width = geometry.devicePixels(@as(i32, @intFromFloat(@ceil(chip.width))) + 4, scale);
                        const height = geometry.devicePixels(default_bar_height, scale);
                        for (0..@intCast(height)) |dy| {
                            const py = (@as(f32, @floatFromInt(dy)) + 0.5) / scale;
                            for (0..@intCast(width)) |dx| {
                                const px = origin_x + (@as(f32, @floatFromInt(dx)) + 0.5) / scale;
                                const want = paintChipPixel(&paint, px, py, scale).argb();
                                try std.testing.expectEqual(want, chipPixelArgb(&paint, px, py, scale));
                                total += 1;
                                if (!paint.flat.tile.contains(px, py) and (!paint.flat.outer.contains(px, py) or
                                    paint.flat.band_h.contains(px, py) or paint.flat.band_v.contains(px, py))) fast += 1;
                            }
                        }
                    }
                }
            }
        }
    }
    // Guards against the fast path silently switching itself off.
    try std.testing.expect(fast * 10 > total * 8);
}

test "title-only chip repaints exactly match complete chip rasters" {
    const saved = ui_theme.global;
    defer ui_theme.global = saved;
    ui_theme.global = .{};

    var icon_pixels: [64 * 64]u32 = undefined;
    for (&icon_pixels, 0..) |*p, i| p.* = if (i % 7 == 0) 0x80402010 else 0xff3366cc;
    const icon: icon_service.Entry = .{ .id = 1, .pixels = &icon_pixels, .size = 64 };
    const titles = [_][]const u8{
        "Terminal",
        "Working \u{2801}",
        "Working \u{28c0}",
        "Working \u{28ff}",
        "\u{280b} Working on a task that is long enough to be ellipsized in the chip",
        "",
        "\u{2819} Working \u{2014} claude",
        "A",
    };
    const color: text.Color = .{ .r = 0.9, .g = 0.92, .b = 0.95, .a = 1 };
    for ([_]f32{ 1, 1.25, 1.5, 2 }) |scale| {
        for ([_]f32{ 78, 78.3, 366.5 }) |x| {
            for ([_]f32{ 152, 280.25 }) |chip_width| {
                const chip: ChipState = .{ .toplevel = undefined, .kind = .browser, .icon = icon, .width = chip_width };
                var paint: ChipPaint = .{
                    .chip = &chip,
                    .x = x,
                    .fill = Color.fromRgba(ui_theme.global.taskbar_hover),
                    .border = Color.fromRgba(ui_theme.global.taskbar_border).scaled(1.6),
                    .bar_height = default_bar_height,
                };
                paint.flat = .init(&paint, scale);
                const cx: i32 = @intFromFloat(@round(x));
                const origin_x = cx - 2;
                const width = geometry.devicePixels(@as(i32, @intFromFloat(@ceil(chip_width))) + 4, scale);
                const height = geometry.devicePixels(default_bar_height, scale);
                const len: usize = @intCast(width * height);
                const rect = chipTitleRect(cx, default_bar_height, chip_width, origin_x, 0).?;
                const previous = try std.testing.allocator.alloc(u32, len);
                defer std.testing.allocator.free(previous);
                const expected = try std.testing.allocator.alloc(u32, len);
                defer std.testing.allocator.free(expected);
                const updated = try std.testing.allocator.alloc(u32, len);
                defer std.testing.allocator.free(updated);
                for (titles, 0..) |before, i| {
                    const after = titles[(i + 1) % titles.len];
                    // Full rasters, as renderPart paints a chip with an icon.
                    fillChipColumns(&paint, previous, width, height, origin_x, 0, 0, @intCast(width), scale);
                    drawChipTitle(previous, width, height, rect, before, color, scale);
                    fillChipColumns(&paint, expected, width, height, origin_x, 0, 0, @intCast(width), scale);
                    drawChipTitle(expected, width, height, rect, after, color, scale);
                    @memcpy(updated, previous);
                    paintChipTitleColumns(&paint, updated, width, height, origin_x, rect, after, color, scale);
                    try std.testing.expectEqualSlices(u32, expected, updated);
                    if (std.mem.startsWith(u8, before, "Working ") and std.mem.startsWith(u8, after, "Working ")) {
                        // Changing spinner bounds must not move the unchanged words.
                        const left: usize = @intCast(geometry.devicePixels(rect.x, scale));
                        const prefix_width = try text.measureWidthF("Working", .manrope, ui_theme.global.taskbar_title_size, scale);
                        const right = left + @as(usize, @intFromFloat(@floor(prefix_width * scale)));
                        const stride: usize = @intCast(width);
                        for (0..@intCast(height)) |row| {
                            try std.testing.expectEqualSlices(u32, previous[row * stride + left .. row * stride + right], updated[row * stride + left .. row * stride + right]);
                        }
                    }
                }
            }
        }
    }
}

test "battery artwork remains centered as taskbar height and item gap change" {
    const saved = ui_theme.global;
    defer ui_theme.global = saved;
    for ([_]i32{ 36, 54, 84 }) |height| {
        for ([_]f32{ 0, 8, 24 }) |gap| {
            ui_theme.global = .{ .taskbar_size = @floatFromInt(height), .chip_gap = gap };
            var bar: Taskbar = undefined;
            bar.box.height = height;
            bar.battery_state = .{ .percent = 100, .plugged = true };
            for ([_]f32{ 1, 1.5, 2 }) |scale| {
                const h = geometry.devicePixels(height, scale);
                var top = h;
                var bottom: i32 = -1;
                for (0..@intCast(h)) |row| {
                    const y = (@as(f32, @floatFromInt(row)) + 0.5) / scale;
                    const pixel = paintBatteryPixel(&bar, 20, y, scale, 1);
                    if (pixel.g > 0.5 and pixel.r < 0.2) {
                        top = @min(top, @as(i32, @intCast(row)));
                        bottom = @max(bottom, @as(i32, @intCast(row)));
                    }
                }
                try std.testing.expect(bottom >= top);
                try std.testing.expect(@abs(top + bottom + 1 - h) <= 1);
            }
        }
    }
}

pub fn appTrayCount(bar: *Taskbar) usize {
    const mgr = bar.server.tray orelse return 0;
    const right = if (bar.capturing()) bar.captureX() else bar.rightLayout().left;
    const room = @max(0, right - @as(f32, @floatFromInt(firstChipX() + 80)));
    return @min(mgr.visibleCount(), @as(usize, @intFromFloat(room / @as(f32, @floatFromInt(trayHit() + tray_gap)))));
}

fn appTrayLeft(bar: *Taskbar) f32 {
    const right = if (bar.capturing()) bar.captureX() else bar.rightLayout().left;
    return right - @as(f32, @floatFromInt(bar.appTrayCount() * @as(usize, @intCast(trayHit() + tray_gap))));
}

pub fn appTrayBox(bar: *Taskbar, index: usize) wlr.Box {
    return .{ .x = bar.box.x + @as(i32, @intFromFloat(bar.appTrayLeft())) + @as(i32, @intCast(index)) * (trayHit() + tray_gap), .y = bar.box.y + @divTrunc(bar.box.height - trayHit(), 2), .width = trayHit(), .height = trayHit() };
}

pub fn appTrayAt(bar: *Taskbar, sx: f64, sy: f64) ?usize {
    for (0..bar.appTrayCount()) |i| {
        const b = bar.appTrayBox(i);
        const x: f64 = @floatFromInt(b.x - bar.box.x);
        const y: f64 = @floatFromInt(b.y - bar.box.y);
        if (sx >= x and sx < x + @as(f64, @floatFromInt(b.width)) and sy >= y and sy < y + @as(f64, @floatFromInt(b.height))) return i;
    }
    return null;
}

fn renderAppTray(bar: *Taskbar) void {
    const mgr = bar.server.tray orelse {
        bar.app_tray_node.node.setEnabled(false);
        return;
    };
    const count = bar.appTrayCount();
    bar.app_tray_node.node.setEnabled(count > 0);
    const left: i32 = @intFromFloat(bar.appTrayLeft());
    bar.app_tray_node.node.setPosition(left, 0);
    if (count == 0 or (bar.app_tray_generation == mgr.generation and !bar.background_dirty)) return;
    const width: i32 = @as(i32, @intCast(count)) * (trayHit() + tray_gap);
    const scale = bar.wlr_output.scale;
    const buf = BarBuffer.create(width, bar.box.height, scale) catch return;
    defer buf.base.drop();
    @memset(buf.pixels, 0);
    const size: i32 = @min(22, trayHit() - 4);
    for (0..count) |i| {
        const item = mgr.visibleItem(i) orelse continue;
        var pixels: []const u32 = item.pixels;
        var sw = item.width;
        var sh = item.height;
        if (item.attention and item.attention_pixels.len > 0) {
            pixels = item.attention_pixels;
            sw = item.attention_width;
            sh = item.attention_height;
        }
        const icon_name = if (item.attention and item.attention_icon.len > 0) item.attention_icon else if (item.attention and item.attention_pixels.len > 0) "" else item.icon;
        const icon_size: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(size)) * scale));
        var lookup: icon_service.Lookup = if (icon_name.len > 0) bar.server.iconLookup(icon_name, icon_size) else .missing;
        if (icon_name.len > 0 and icon_name[0] != '/' and item.icon_theme_path.len > 0) {
            // Resolve application-private indicator directories on the existing
            // icon worker, never synchronously decode from the rendering loop.
            var path_buf: [4096]u8 = undefined;
            for ([_][]const u8{ "", ".png", ".svg" }) |extension| {
                const full = std.fmt.bufPrint(&path_buf, "{s}/{s}{s}", .{ item.icon_theme_path, icon_name, extension }) catch continue;
                const candidate = bar.server.iconLookup(full, icon_size);
                if (candidate == .ready) {
                    lookup = candidate;
                    break;
                }
            }
        }
        if (icon_name.len > 0) switch (lookup) {
            .ready => |entry| {
                pixels = entry.pixels;
                sw = entry.size;
                sh = entry.size;
            },
            else => {},
        };
        const x = @as(i32, @intCast(i)) * (trayHit() + tray_gap) + @divTrunc(trayHit() - size, 2);
        const y = @divTrunc(bar.box.height - size, 2);
        if (pixels.len == 0 or sw <= 0 or sh <= 0) {
            text.draw(buf.pixels, buf.width, buf.height, .{ .x = x, .y = y, .w = size, .h = size }, "●", Color.clock_time(), scale, .manrope, 16) catch {};
            continue;
        }
        const dw: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(size)) * scale));
        const dx: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(x)) * scale));
        const dy: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(y)) * scale));
        var py: i32 = 0;
        while (py < dw) : (py += 1) {
            var px: i32 = 0;
            while (px < dw) : (px += 1) {
                const src: usize = @intCast(@divTrunc(py * sh, dw) * sw + @divTrunc(px * sw, dw));
                const dest: usize = @intCast((dy + py) * buf.width + dx + px);
                buf.pixels[dest] = pixels[src];
            }
        }
    }
    bar.app_tray_node.setBuffer(&buf.base);
    bar.app_tray_node.setDestSize(width, bar.box.height);
    bar.app_tray_generation = mgr.generation;
}
