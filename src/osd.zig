const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const sn = @import("node.zig");
const Output = @import("Output.zig");
const Server = @import("Server.zig");
const Toplevel = @import("Toplevel.zig");
const painter = @import("osd_paint.zig");
const PanelBuffer = @import("panel_buffer.zig").PanelBuffer;
const anim = @import("ui").anim;
const ui_input = @import("ui").input;
pub const State = painter.State;

node: ?*sn.Buffer = null,
timer: ?*wl.EventSource = null,
state: ?State = null,
painted_state: ?State = null,
painted_level: ?f32 = null,
level_anim: anim.Anim = .{},
last_kind: ?painter.Kind = null,
last_level: f32 = 0,
fade_start: ?i64 = null,
scale: f32 = 0,
const Osd = @This();
/// Gap between the OSD and the bottom of the work area, or the top of a dock.
const edge_gap = 20;
const dock_gap = 12;
const window_gap = 8;

pub fn show(server: *Server, state: State) void {
    const output = server.getDefaultOutput() orelse return;
    showOn(server, output, state);
}

pub fn showOn(server: *Server, output: *Output, state: State) void {
    if (server.locker) |lock| if (lock.greeter == null and lock.client == null) {
        switch (state.kind) {
            .volume, .brightness => {
                var outputs = server.outputs.iterator(.forward);
                while (outputs.next()) |other| other.osd.hide();
                lock.showControl(if (state.kind == .volume) .volume else .brightness);
                return;
            },
            else => {},
        }
    };
    var it = server.outputs.iterator(.forward);
    while (it.next()) |other| if (other != output) other.osd.hide();
    output.osd.present(output, state, true) catch |err| std.log.warn("OSD: {}", .{err});
}

pub fn showWindowZoom(window: *Toplevel, lx: f64, ly: f64) void {
    const server = window.server;
    if (server.locker != null) return;
    const frame = windowFrame(window);
    const center = frame.x + frame.width / 2;
    // A zoom anchored inside the frame keeps that point on the same output.
    const anchor_output = if (lx >= frame.x and lx < frame.x + frame.width and ly >= frame.y and ly < frame.y + frame.height)
        Output.atLayout(server, lx, ly)
    else
        null;
    const output = anchor_output orelse Output.atLayout(server, center, frame.y) orelse
        Output.atLayout(server, center, frame.y + frame.height / 2) orelse
        Output.atLayout(server, lx, ly) orelse return;
    const percent = @import("camera.zig").zoom_levels[window.zoom_index];
    showOn(server, output, .{ .kind = .window_zoom, .level = @as(f32, @floatFromInt(percent)) / 100, .window_id = window.id });
}

fn paintState(self: *Osd, output: *Output, state: State) !void {
    const node = self.node orelse return;
    const image = try PanelBuffer.create(painter.width(state.kind), painter.height(state.kind), output.wlr_output.scale);
    defer image.base.drop();
    var renderer = @import("ui").paint.Renderer.init(image.pixels, image.width, image.height, output.wlr_output.scale);
    painter.paint(&renderer, state);
    node.setBuffer(&image.base);
    self.painted_state = state;
    self.painted_level = state.level;
    self.scale = output.wlr_output.scale;
}

fn present(self: *Osd, output: *Output, state: State, restart: bool) !void {
    if (!output.isLogicallyEnabled() or output.idle_blanked) {
        self.hide();
        return;
    }
    if (self.timer == null) self.timer = try output.server.wl_server.getEventLoop().addTimer(*Output, beginFade, output);
    if (self.node == null) {
        self.node = try output.server.overlay_tree.createSceneBuffer(null);
        self.node.?.point_accepts_input = ignoreInput;
        self.node.?.setFilterMode(.bilinear);
    }
    // Keep normal overlays inside the shell tree so isolated-window captures
    // exclude them. While locked, only this noninteractive buffer goes above
    // the opaque lock covers; the rest of the desktop remains covered.
    const parent = if (output.server.locker != null) output.server.lock_tree else output.server.overlay_tree;
    if (self.node.?.node.parent != parent) self.node.?.node.reparent(parent);

    const is_wide = painter.hasLevel(state.kind);
    const now = anim.nowMs();
    const motion_ms: i64 = @intCast(ui_input.caret_config.motion_ms);
    const is_visible = self.state != null and self.node.?.node.enabled;

    if (is_wide) {
        if (!is_visible) {
            if (self.last_kind == state.kind and @abs(state.level - self.last_level) <= 0.20 and motion_ms > 0) {
                self.level_anim = .initCurve(self.last_level, state.level, now, anim.curveFor(.osd_level));
            } else {
                self.level_anim = .{ .from = state.level, .to = state.level };
            }
        } else if (self.state.?.kind == state.kind) {
            if (motion_ms == 0 or @abs(state.level - self.level_anim.value(now)) > 0.20) {
                self.level_anim = .{ .from = state.level, .to = state.level };
            } else {
                self.level_anim.retargetTo(now, state.level, anim.curveFor(.osd_level));
            }
        } else {
            self.level_anim = .{ .from = state.level, .to = state.level };
        }
        self.last_kind = state.kind;
        self.last_level = state.level;
    }

    self.state = state;

    const cur_level = if (is_wide) self.level_anim.value(now) else state.level;
    var render_state = state;
    if (is_wide) render_state.level = cur_level;

    if (self.painted_state == null or !std.meta.eql(self.painted_state.?, render_state) or self.scale != output.wlr_output.scale) {
        try self.paintState(output, render_state);
    }
    if (state.window_id) |id| {
        if (!self.positionWindow(output, id)) return self.hide();
    } else self.position(output);
    self.node.?.node.setEnabled(true);
    self.node.?.node.raiseToTop();
    if (restart) {
        self.fade_start = null;
        self.node.?.setOpacity(1);
        try self.timer.?.timerUpdate(1100);
    }
    if (is_wide and !self.level_anim.settled(now)) {
        output.wlr_output.scheduleFrame();
    }
}

/// Bottom centre of the work area, or just above a dock on the bottom edge,
/// auto-hiding or not, so the two never overlap.
fn position(self: *Osd, output: *Output) void {
    const state = self.state orelse return;
    const box = output.usableBox();
    const width = @min(painter.width(state.kind), box.width);
    const height = @min(painter.height(state.kind), box.height);
    var bottom = box.y + box.height - edge_gap;
    if (output.server.config.compositor.dock_position == .bottom) {
        const area = output.dockAreaBox();
        const dock = @import("Dock.zig").footprint(output.server, area);
        if (dock > 0) bottom = area.y + area.height - dock - dock_gap;
    }
    self.node.?.setDestSize(width, height);
    self.node.?.node.setPosition(box.x + @divTrunc(box.width - width, 2), @max(box.y, bottom - height));
}

fn windowFrame(window: *const Toplevel) wlr.FBox {
    const node = &window.frame_tree.node;
    const origin = window.server.world.toLayout(@floatFromInt(node.x), @floatFromInt(node.y));
    const scale = window.zoom() * window.drag_lift_value;
    return .{
        .x = origin.x,
        .y = origin.y,
        .width = @as(f64, @floatFromInt(window.chrome_width)) * scale,
        .height = @as(f64, @floatFromInt(window.chrome_height)) * scale,
    };
}

fn positionWindow(self: *Osd, output: *Output, id: u64) bool {
    const server = output.server;
    if (server.locker != null or server.world.overview.active() or server.world.workspaces.active) return false;
    const window = server.findToplevelById(id) orelse return false;
    if (!window.in_world or window.closing or !window.frame_tree.node.enabled) return false;

    const frame = windowFrame(window);
    const screen = output.cached_box;
    if (frame.x >= @as(f64, @floatFromInt(screen.x + screen.width)) or frame.x + frame.width <= @as(f64, @floatFromInt(screen.x)) or
        frame.y >= @as(f64, @floatFromInt(screen.y + screen.height)) or frame.y + frame.height <= @as(f64, @floatFromInt(screen.y))) return false;

    const area = output.usableBox();
    const width = painter.width(.window_zoom);
    const height = painter.height(.window_zoom);
    if (area.width < width or area.height < height) return false;

    // The anchor follows the presented frame. The badge lives in layout units.
    const center: i32 = @intFromFloat(@round(frame.x + frame.width / 2));
    const top: i32 = @intFromFloat(@round(frame.y));
    const node = self.node.?;
    node.setDestSize(width, height);
    node.node.setPosition(
        std.math.clamp(center - @divTrunc(width, 2), area.x, area.x + area.width - width),
        std.math.clamp(top - window_gap - height, area.y, area.y + area.height - height),
    );
    return true;
}

pub fn tick(self: *Osd, output: *Output, now: i64) bool {
    const state = self.state orelse return false;
    if (state.window_id) |id| {
        if (!self.positionWindow(output, id)) {
            self.hide();
            return false;
        }
    }
    const parent = if (output.server.locker != null) output.server.lock_tree else output.server.overlay_tree;
    if (self.node) |node| {
        if (node.node.parent != parent) node.node.reparent(parent);
    }
    const is_wide = painter.hasLevel(state.kind);
    var dirty = false;
    var render_state = state;
    const level_stepped = is_wide and self.level_anim.sampleChanged(now, anim.rasterPixelQuantum(output.wlr_output.scale) / painter.slider_width);
    if (is_wide) render_state.level = self.level_anim.value(now);
    const appearance_changed = self.painted_state == null or self.painted_state.?.kind != render_state.kind or self.scale != output.wlr_output.scale;
    if (appearance_changed or (level_stepped and (self.painted_state == null or !std.meta.eql(self.painted_state.?, render_state)))) {
        self.paintState(output, render_state) catch return false;
        dirty = true;
    }
    var fade_animating = false;
    if (self.fade_start) |start| {
        const opacity = 1 - @as(f32, @floatFromInt(@max(0, now - start))) / 180;
        if (opacity <= 0) {
            self.hide();
            return false;
        }
        self.node.?.setOpacity(opacity);
        fade_animating = true;
    }
    const level_animating = is_wide and !self.level_anim.settled(now);
    const animating = level_animating or fade_animating;
    return dirty or (animating and !anim.clockOverridden());
}

fn beginFade(output: *Output) c_int {
    output.osd.fade_start = anim.nowMs();
    output.wlr_output.scheduleFrame();
    return 0;
}

pub fn hide(self: *Osd) void {
    if (self.node) |node| node.node.setEnabled(false);
    if (self.timer) |timer| timer.timerUpdate(0) catch {};
    self.state = null;
    self.painted_state = null;
    self.painted_level = null;
    self.fade_start = null;
}

pub fn deinit(self: *Osd) void {
    if (self.timer) |timer| timer.remove();
    if (self.node) |node| node.node.destroy();
    self.* = .{};
}

pub fn refreshAudio(server: *Server) void {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        const old = output.osd.state orelse continue;
        if (old.kind != .volume and old.kind != .microphone) continue;
        const next = @import("hardware_keys.zig").audioState(server, old.kind == .microphone) orelse {
            output.osd.hide();
            continue;
        };
        output.osd.present(output, next, false) catch {};
    }
}

fn ignoreInput(_: *sn.Buffer, _: *f64, _: *f64) callconv(.c) bool {
    return false;
}

test "OSD is noninteractive, stays above lock covers, rescales and releases its timer" {
    const display = try wl.Server.create();
    defer display.destroy();
    const backend = try wlr.Backend.createHeadless(display.getEventLoop());
    defer backend.destroy();
    const layout = try wlr.OutputLayout.create(display);
    defer layout.destroy();
    var fixture = try sn.TestScene.create();
    defer fixture.destroy();
    defer PanelBuffer.drainPool();
    var server: Server = undefined;
    server.wl_server = display;
    server.scene_outputs = undefined;
    server.output_layout = layout;
    server.overlay_tree = try fixture.nodes.tree.createSceneTree();
    server.lock_tree = try fixture.nodes.tree.createSceneTree();
    server.locker = null;
    const output = try backend.headlessAddOutput(1280, 720);
    var mode = wlr.Output.State.init();
    defer mode.finish();
    mode.setEnabled(true);
    try std.testing.expect(output.commitState(&mode));
    _ = try layout.add(output, -1280, 100);
    var out = Output{ .server = &server, .wlr_output = output, .lock_view = undefined };
    defer out.osd.deinit();
    try out.osd.present(&out, .{ .kind = .volume, .level = 0.7 }, true);
    const node = out.osd.node.?;
    try std.testing.expect(node.node.parent == server.overlay_tree);
    try std.testing.expectEqual(@as(i32, -1280 + 488), node.node.x);
    var x: f64 = 10;
    var y: f64 = 10;
    try std.testing.expect(!node.point_accepts_input.?(node, &x, &y));
    // Only the OSD leaves the ordinary overlay tree while a lock exists.
    var lock: @import("session/lock.zig").Lock = undefined;
    server.locker = &lock;
    try out.osd.present(&out, .{ .kind = .microphone, .active = true }, true);
    try std.testing.expect(node.node.parent == server.lock_tree);
    try std.testing.expectEqual(@as(i32, 76), node.dst_width);
    mode.setScale(1.5);
    try std.testing.expect(output.commitState(&mode));
    try out.osd.present(&out, .{ .kind = .caps_lock, .active = true }, true);
    try std.testing.expectEqual(@as(i32, 114), node.getBuffer().?.width);
    server.locker = null;
    _ = out.osd.tick(&out, 0);
    try std.testing.expect(node.node.parent == server.overlay_tree);
    out.osd.fade_start = 0;
    try std.testing.expect(out.osd.tick(&out, 90));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), node.opacity, 0.001);
    try std.testing.expect(!out.osd.tick(&out, 180));
    try std.testing.expect(!node.node.enabled);
    // Deinit is idempotent and leaves no timer referring to the output.
    out.osd.deinit();
    try display.getEventLoop().dispatch(0);
}

test "OSD sound and brightness glides smoothly between levels" {
    const display = try wl.Server.create();
    defer display.destroy();
    const backend = try wlr.Backend.createHeadless(display.getEventLoop());
    defer backend.destroy();
    const layout = try wlr.OutputLayout.create(display);
    defer layout.destroy();
    var fixture = try sn.TestScene.create();
    defer fixture.destroy();
    defer PanelBuffer.drainPool();
    var server: Server = undefined;
    server.wl_server = display;
    server.scene_outputs = undefined;
    server.output_layout = layout;
    server.overlay_tree = try fixture.nodes.tree.createSceneTree();
    server.lock_tree = try fixture.nodes.tree.createSceneTree();
    server.locker = null;
    const output = try backend.headlessAddOutput(1280, 720);
    var mode = wlr.Output.State.init();
    defer mode.finish();
    mode.setEnabled(true);
    try std.testing.expect(output.commitState(&mode));
    _ = try layout.add(output, 0, 0);
    var out = Output{ .server = &server, .wlr_output = output, .lock_view = undefined };
    defer out.osd.deinit();

    anim.setNowMs(1000);
    defer anim.setNowMs(null);

    // Initial appearance snaps to 0.50
    try out.osd.present(&out, .{ .kind = .volume, .level = 0.50 }, true);
    try std.testing.expectEqual(@as(f32, 0.50), out.osd.painted_level.?);
    try std.testing.expect(out.osd.level_anim.settled(1000));

    // Volume update arrives at t=1000 while visible: spring toward 0.55
    try out.osd.present(&out, .{ .kind = .volume, .level = 0.55 }, false);
    try std.testing.expect(!out.osd.level_anim.settled(1000));
    try std.testing.expectEqual(@as(f32, 0.55), out.osd.level_anim.to);
    const settle_at = 1000 + out.osd.level_anim.settle_ms;

    _ = out.osd.tick(&out, 1040);
    try std.testing.expect(out.osd.painted_level.? > 0.50);
    try std.testing.expect(out.osd.painted_level.? < 0.55);
    try std.testing.expect(!out.osd.level_anim.settled(1040));

    _ = out.osd.tick(&out, settle_at);
    try std.testing.expectEqual(@as(f32, 0.55), out.osd.painted_level.?);
    try std.testing.expect(out.osd.level_anim.settled(settle_at));
    try std.testing.expect(!out.osd.tick(&out, settle_at));

    // Rapid retargeting keeps velocity: bump while in-flight, then again.
    anim.setNowMs(1100);
    try out.osd.present(&out, .{ .kind = .volume, .level = 0.60 }, false);
    const mid = out.osd.level_anim.value(1100);
    _ = out.osd.tick(&out, 1140);
    anim.setNowMs(1140);
    try out.osd.present(&out, .{ .kind = .volume, .level = 0.65 }, false);
    try std.testing.expectApproxEqAbs(out.osd.level_anim.from, out.osd.level_anim.value(1140), 0.001);
    try std.testing.expect(out.osd.level_anim.from > mid);
    try std.testing.expect(out.osd.level_anim.from < 0.65);
    try std.testing.expectEqual(@as(f32, 0.65), out.osd.level_anim.to);
}
