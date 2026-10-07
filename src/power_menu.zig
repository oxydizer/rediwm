// Centered session-action cards with system uptime.
const std = @import("std");
const glass = @import("glass.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const col = @import("color.zig");

const gpa = @import("main.zig").gpa;
const anim = @import("ui").anim;
const text_mod = @import("ui").text;
const panel_buffer = @import("panel_buffer.zig");
const panel_paint = @import("panel_paint.zig");
const panel_present = @import("panel_present.zig");
const scene_data = @import("scene_data.zig");
const PanelBuffer = panel_buffer.PanelBuffer;
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const actions = @import("config_runtime/actions.zig");
const power_session = @import("session/power.zig");
const ui = @import("ui");
const layout = ui.layout;
const Widget = layout.Widget;
const theme = ui.theme;

const Anim = anim.Anim;
const log = std.log.scoped(.power_menu);

const icon_size: f32 = 32;
const tile_width: f32 = 128;
const tile_height: f32 = 128;
const tile_gap: f32 = 20;
const panel_padding: f32 = 32;
const panel_radius: f32 = 16;
const label_size: f32 = 15;
const uptime_size: f32 = 13;
const panel_width: f32 = panel_padding * 2 + tile_width * tiles.len + tile_gap * (tiles.len - 1);

// The generic layout engine measures text width at scale 1, but font hinting
// at other output scales can round a run's advance a pixel or two wider than
// that. Every other label has slack around it to absorb this; the uptime
// label is flush against the panel's right edge with none, so it needs an
// explicit margin or it clips into an ellipsis on scaled outputs.
const uptime_width_slack: f32 = 4;

const slide_distance: f32 = 16;
// The glass blur itself stays constantly at full strength — only the
// panel's scene-buffer opacity and the scrim fade with `slide`.
const glass_opacity: f32 = 1;
// How dark the rest of the screen gets behind the modal, at full open.

const State = enum { opening, open, selecting, closing };

const Tile = struct {
    name: []const u8,
    icon: layout.IconId,
    label: []const u8,
    action: actions.Action,
    // Null for tiles that don't go through logind (Lock, Log Out) and are
    // always offered; set for tiles whose availability tracks a
    // power_session.Manager capability.
    power_kind: ?power_session.Kind = null,
};

// Order matches how the menu reads left to right.
const tiles = [_]Tile{
    .{ .name = "lock", .icon = .lock, .label = "Lock", .action = .lock_screen },
    .{ .name = "logout", .icon = .logout, .label = "Log Out", .action = .quit },
    .{ .name = "restart", .icon = .reboot, .label = "Restart", .action = .reboot, .power_kind = .reboot },
    .{ .name = "suspend", .icon = .@"suspend", .label = "Suspend", .action = .@"suspend", .power_kind = .@"suspend" },
    .{ .name = "poweroff", .icon = .power, .label = "Power Off", .action = .poweroff, .power_kind = .poweroff },
};

pub const PowerMenu = struct {
    server: *Server,
    wlr_output: *wlr.Output,
    // Full-output dimming rect behind the panel, so the modal reads as truly
    // modal rather than just another floating panel. Purely decorative —
    // outside-click dismissal is driven by cursor-vs-panel_box math in
    // Input.zig, not by hit-testing this node.
    scrim: *wlr.SceneRect,
    buffer_node: *wlr.SceneBuffer,
    glass_effect: ?*glass.Effect = null,
    node_data: scene_data.SceneData = undefined,

    state: State = .opening,
    slide: Anim = .{},
    selection: Anim = .{},
    highlight_pos: Anim = .{},
    highlight_alpha: Anim = .{ .property = .opacity },
    highlight_target: ?usize = null,
    selected: ?usize = null,
    keyboard_focus: ?usize = null,
    selection_origin: [2]f32 = .{ 0, 0 },
    selection_presented: bool = false,
    dirty: bool = true,
    background: panel_paint.Background = .{},
    panel_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    root: Widget = undefined,
    root_children: [2]Widget = undefined,
    cards: [tiles.len]Widget = undefined,
    tile_pairs: [tiles.len][2]Widget = undefined,
    header_children: [2]Widget = undefined,
    uptime_text: [64]u8 = undefined,
    uptime_minutes: ?i64 = null,
    uptime_timer: ?*wl.EventSource = null,

    pub fn create(server: *Server, wlr_output: *wlr.Output) !*PowerMenu {
        const menu = try gpa.create(PowerMenu);
        errdefer gpa.destroy(menu);

        // Created first so it stacks below the panel buffer (later siblings
        // paint on top).
        const scrim = try col.createRect(server.overlay_tree, 0, 0, .transparent);
        errdefer scrim.node.destroy();

        const buffer_node = try server.overlay_tree.createSceneBuffer(null);
        errdefer buffer_node.node.destroy();
        buffer_node.setFilterMode(.bilinear);

        menu.* = .{
            .server = server,
            .wlr_output = wlr_output,
            .scrim = scrim,
            .buffer_node = buffer_node,
            .glass_effect = glass.Engine.attach(server.glass_engine, buffer_node, &buffer_node.node, .panel),
        };
        menu.node_data = .{ .role = .{ .power_menu = menu } };
        scene_data.SceneData.attach(&menu.node_data, &buffer_node.node);

        menu.buildTree();
        menu.slide.retargetTo(anim.nowMs(), 1, anim.curveFor(.panel_slide));
        menu.relayout();
        // Query CanPowerOff/CanReboot/CanSuspend fresh on every open rather
        // than at compositor startup: this menu is opened rarely enough that
        // one extra bus round trip is free, and it means a policy change
        // made while the compositor was running (e.g. a new inhibitor) still
        // shows up correctly. onProbeCapability (session/power.zig) calls
        // refreshCapabilities() again once each reply lands; this first call
        // just reflects whatever is already known (often nothing yet).
        if (server.power) |pm| pm.probeCapabilities();
        menu.refreshCapabilities();
        menu.uptime_timer = server.wl_server.getEventLoop().addTimer(*PowerMenu, onUptimeTimer, menu) catch null;
        if (menu.uptime_timer) |timer| timer.timerUpdate(1000) catch {};
        return menu;
    }

    /// Called by session/power.zig once logind capabilities are known or
    /// change, and once from `create()` for a freshly opened menu. Disables
    /// tiles logind reports as unavailable, replacing their label
    /// with why (e.g. "Not supported"), and re-enables them if policy allows
    /// it again later. Lock and Log Out never depend on logind, so they are
    /// always left enabled.
    pub fn refreshCapabilities(menu: *PowerMenu) void {
        const t = theme.global;
        var changed = false;
        for (tiles, 0..) |tile, i| {
            const kind = tile.power_kind orelse continue;
            const pm = menu.server.power orelse continue;
            const available = pm.isAvailable(kind);
            const label = if (available) tile.label else (pm.unavailableExplanation(kind) orelse tile.label);
            const color = if (available) t.fg else t.window_fg;
            const want_state: layout.ButtonState = if (available) .idle else .disabled;

            if (!std.mem.eql(u8, menu.tile_pairs[i][1].kind.text.content, label)) {
                menu.tile_pairs[i][1].kind.text.content = label;
                changed = true;
            }
            if (!std.meta.eql(menu.tile_pairs[i][0].kind.icon.color, color)) {
                menu.tile_pairs[i][0].kind.icon.color = color;
                menu.tile_pairs[i][1].kind.text.color = color;
                changed = true;
            }
            // Never stomp a state mid-interaction (hover/press); the next
            // pointer-leave or click settles it back to idle/disabled anyway.
            const row_state = menu.cards[i].kind.row.state;
            if (row_state != .hover and row_state != .press and row_state != want_state) {
                menu.cards[i].kind.row.state = want_state;
                changed = true;
            }
            if (!available and menu.keyboard_focus == i) menu.keyboard_focus = null;
        }
        if (!changed) return;
        for (&menu.cards) |*card| card.markPaintDirty();
        menu.syncHighlight();
        menu.relayout();
    }

    pub fn destroy(menu: *PowerMenu) void {
        if (menu.uptime_timer) |timer| timer.remove();
        ui.input.reset();
        if (menu.server.input.open_power_menu == menu) {
            menu.server.input.open_power_menu = null;
        }
        menu.scrim.node.destroy();
        menu.background.deinit(gpa);
        menu.buffer_node.node.destroy();
        PanelBuffer.drainPool();
        gpa.destroy(menu);
    }

    fn buildTree(menu: *PowerMenu) void {
        const t = theme.global;
        for (tiles, 0..) |tile, i| {
            const base = layout.RectStyle{
                .color = .{ 0, 0, 0, 0 },
                .radius = 12,
                .border_width = 2,
                .border_color = t.border_soft,
            };
            menu.tile_pairs[i] = .{
                .{
                    .kind = .{ .icon = .{ .id = tile.icon, .color = t.fg } },
                    .width = .{ .fixed = icon_size },
                    .height = .{ .fixed = icon_size },
                },
                .{ .kind = .{ .text = .{ .content = tile.label, .font_size = label_size, .color = t.fg } } },
            };
            menu.cards[i] = .{
                .name = tile.name,
                .kind = .{ .row = .{ .owner = menu, .id = i, .on_click = onTileClick, .background = base } },
                .direction = .column,
                .@"align" = .center,
                .justify = .center,
                .gap = 22,
                .width = .{ .flex = 1 },
                .height = .{ .fixed = tile_height },
                .children = &menu.tile_pairs[i],
            };
        }
        menu.header_children = .{
            .{ .kind = .{ .icon = .{ .id = .clock, .color = t.window_fg } }, .width = .{ .fixed = 15 }, .height = .{ .fixed = 15 } },
            .{ .kind = .{ .text = .{ .content = "Uptime unavailable", .font_size = uptime_size, .color = t.window_fg } } },
        };
        menu.root_children = .{
            .{ .kind = .container, .direction = .row, .@"align" = .center, .justify = .end, .gap = 10, .height = .{ .fixed = 20 }, .children = &menu.header_children },
            .{ .kind = .container, .direction = .row, .gap = tile_gap, .height = .{ .fixed = tile_height }, .children = &menu.cards },
        };
        menu.root = .{
            .kind = .{ .rect = .{ .color = t.window_bg, .radius = panel_radius, .border_width = 1, .border_color = t.border } },
            .direction = .column,
            .@"align" = .stretch,
            .gap = 20,
            .padding = .{ .top = 20, .bottom = panel_padding, .left = panel_padding, .right = panel_padding },
            .width = .{ .fixed = panel_width },
            .height = .auto,
            .children = &menu.root_children,
        };
        _ = menu.updateUptime();
        menu.root.linkParents();
    }

    /// Requests a full relayout+repaint, e.g. after the output resizes.
    pub fn relayout(menu: *PowerMenu) void {
        menu.background.invalidate();
        var output_box: wlr.Box = undefined;
        menu.server.output_layout.getBox(menu.wlr_output, &output_box);
        if (output_box.width <= 0 or output_box.height <= 0) return;

        const target_width: f32 = @max(1, @min(panel_width, @as(f32, @floatFromInt(output_box.width)) - 40));
        // Stack cards on narrow outputs instead of clipping the rightmost actions.
        const narrow = target_width < 460;
        menu.root_children[1].direction = if (narrow) .column else .row;
        menu.root_children[1].@"align" = .stretch;
        menu.root_children[1].height = .{ .fixed = if (narrow) tiles.len * 72 + (tiles.len - 1) * 10 else tile_height };
        menu.root_children[1].gap = if (narrow) 10 else tile_gap;
        for (&menu.cards) |*card| {
            card.width = if (narrow) .auto else .{ .flex = 1 };
            card.height = .{ .fixed = if (narrow) 72 else tile_height };
            card.direction = if (narrow) .row else .column;
        }
        menu.root_children[1].children = &menu.cards;
        menu.root.width = .{ .fixed = target_width };
        ui.measure.measure(&menu.root, target_width, @floatFromInt(output_box.height));
        const target_height = menu.root.computed_height;
        ui.arrange.arrange(&menu.root, 0, 0, target_width, target_height);

        menu.panel_box = .{
            .x = output_box.x + @as(i32, @intFromFloat(@round((@as(f32, @floatFromInt(output_box.width)) - target_width) / 2))),
            .y = output_box.y + @as(i32, @intFromFloat(@round((@as(f32, @floatFromInt(output_box.height)) - target_height) / 2))),
            .width = @intFromFloat(target_width),
            .height = @intFromFloat(target_height),
        };
        if (menu.selected) |id| {
            menu.selection_origin = .{ menu.cards[id].computed_x, menu.cards[id].computed_y };
            menu.root_children[1].children = menu.cards[id .. id + 1];
            menu.positionSelection(anim.nowMs());
        }
        menu.scrim.setSize(output_box.width, output_box.height);
        menu.scrim.node.setPosition(output_box.x, output_box.y);
        menu.dirty = true;
        menu.paintContent();
        menu.applyPresentation(anim.nowMs());
    }

    fn updateUptime(menu: *PowerMenu) bool {
        var ts: std.posix.timespec = undefined;
        if (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.BOOTTIME, &ts)) != .SUCCESS) return false;
        const minutes = @divTrunc(@max(0, ts.sec), 60);
        if (menu.uptime_minutes == minutes) return false;
        menu.uptime_minutes = minutes;
        const content = std.fmt.bufPrint(&menu.uptime_text, "Uptime {d}h {d}m", .{ @divTrunc(minutes, 60), @mod(minutes, 60) }) catch unreachable;
        menu.header_children[1].kind.text.content = content;
        const natural = text_mod.measureWidth(content, .manrope, uptime_size, 1.0) catch 0;
        menu.header_children[1].min_width = @as(f32, @floatFromInt(natural)) + uptime_width_slack;
        return true;
    }

    fn onUptimeTimer(menu: *PowerMenu) c_int {
        if ((menu.state == .opening or menu.state == .open) and menu.updateUptime()) {
            menu.relayout();
            menu.wlr_output.scheduleFrame();
        }
        if (menu.uptime_timer) |timer| timer.timerUpdate(1000) catch {};
        return 0;
    }

    pub fn tick(menu: *PowerMenu, now_ms: i64) bool {
        if (menu.state == .selecting) {
            // Give the centered endpoint a presented frame and a short pause
            // before a session action can replace or terminate the compositor.
            if (menu.selection_presented and now_ms >= menu.selection.settle_ms + 70) {
                const action = tiles[menu.selected.?].action;
                if (Output.fromWlr(menu.wlr_output)) |output| output.closePowerMenu();
                actions.executeAction(menu.server, action);
                return !anim.clockOverridden();
            }
            if (menu.selection.sampleChanged(now_ms, anim.quantum_alpha) or !menu.selection_presented) {
                menu.positionSelection(now_ms);
                menu.root_children[1].markPaintDirty();
                menu.cards[menu.selected.?].markPaintDirty();
                menu.dirty = true;
            }
        }
        // Sample both tracks even when the other changed. The normal output
        // frame loop drives the glide; a settled highlight needs no timer.
        const moved = menu.highlight_pos.sampleChanged(now_ms, anim.rasterPixelQuantum(menu.wlr_output.scale) / (tile_width + tile_gap));
        const faded = menu.highlight_alpha.sampleChanged(now_ms, anim.rasterAlphaQuantum());
        if (moved or faded) {
            menu.root_children[1].markPaintDirty();
            menu.dirty = true;
        }
        if (menu.dirty) menu.paintContent();
        if (menu.state == .selecting and !menu.dirty and menu.selection.settled(now_ms)) menu.selection_presented = true;
        menu.applyPresentation(now_ms);
        _ = menu.slide.sampleChanged(now_ms, anim.quantum_alpha);
        const animating = !menu.slide.settled(now_ms) or !menu.highlight_pos.settled(now_ms) or !menu.highlight_alpha.settled(now_ms) or menu.state == .selecting;
        return menu.dirty or (animating and !anim.clockOverridden());
    }

    fn positionSelection(menu: *PowerMenu, now_ms: i64) void {
        const card = &menu.cards[menu.selected orelse return];
        const progress = menu.selection.value(now_ms);
        const x = (@as(f32, @floatFromInt(menu.panel_box.width)) - card.computed_width) / 2;
        const y = (@as(f32, @floatFromInt(menu.panel_box.height)) - card.computed_height) / 2;
        ui.arrange.arrange(card, menu.selection_origin[0] + (x - menu.selection_origin[0]) * progress, menu.selection_origin[1] + (y - menu.selection_origin[1]) * progress, card.computed_width, card.computed_height);
    }

    fn select(menu: *PowerMenu, id: usize) void {
        if (id >= tiles.len or (menu.state != .open and menu.state != .opening)) return;
        if (menu.cards[id].kind.row.state == .disabled) return;
        menu.state = .selecting;
        menu.selected = id;
        menu.selection_origin = .{ menu.cards[id].computed_x, menu.cards[id].computed_y };
        menu.keyboard_focus = id;
        menu.cards[id].kind.row.state = .idle;
        menu.syncHighlight();
        menu.root_children[1].children = menu.cards[id .. id + 1];
        menu.selection.retarget(anim.nowMs(), 1, 180, .out_cubic);
        // Removing siblings needs their old pixels cleared as well.
        menu.requestRepaint();
    }

    pub fn navigate(menu: *PowerMenu, forward: bool) void {
        if (menu.state != .open and menu.state != .opening) return;
        ui.input.reset();
        var id: usize = if (menu.keyboard_focus) |cur|
            (cur + (if (forward) @as(usize, 1) else tiles.len - 1)) % tiles.len
        else if (forward) 0 else tiles.len - 1;
        // Disabled tiles (logind reports the action unavailable) are not a
        // stop on the keyboard-nav ring; skip past them, bounded so an
        // all-disabled menu (shouldn't happen: Lock/Log Out never disable)
        // can't spin forever.
        var steps: usize = 0;
        while (menu.cards[id].kind.row.state == .disabled and steps < tiles.len) : (steps += 1) {
            id = (id + (if (forward) @as(usize, 1) else tiles.len - 1)) % tiles.len;
        }
        menu.keyboard_focus = id;
        for (&menu.cards) |*card| {
            if (card.kind.row.state != .disabled) card.kind.row.state = .idle;
        }
        menu.syncHighlight();
    }

    pub fn activateFocused(menu: *PowerMenu) void {
        if (menu.keyboard_focus) |id| menu.select(id);
    }

    fn syncHighlight(menu: *PowerMenu) void {
        var target: ?usize = null;
        for (&menu.cards, 0..) |*card, i| {
            // Disabled actions retain their neutral text and icon colours;
            // neither pointer motion nor keyboard focus highlights them.
            if (card.kind.row.state == .disabled) {
                if (card.kind.row.selected) {
                    card.kind.row.selected = false;
                    card.markPaintDirty();
                    menu.requestWidgetRepaint();
                }
                continue;
            }
            const focused = menu.keyboard_focus == i;
            const highlighted = focused or card.kind.row.state == .hover or card.kind.row.state == .press;
            if (highlighted) target = i;
            const color = if (highlighted) theme.global.danger else theme.global.fg;
            if (card.kind.row.selected != focused or !std.meta.eql(menu.tile_pairs[i][0].kind.icon.color, color)) {
                card.kind.row.selected = focused;
                menu.tile_pairs[i][0].kind.icon.color = color;
                card.markPaintDirty();
                menu.requestWidgetRepaint();
            }
        }
        if (target != menu.highlight_target) {
            menu.highlight_target = target;
            const now = anim.nowMs();
            if (target) |id| {
                const slot: f32 = @floatFromInt(id);
                if (menu.highlight_alpha.value(now) <= 0.01) {
                    menu.highlight_pos.cancel(slot);
                } else {
                    menu.highlight_pos.retargetTo(now, slot, anim.curveFor(.titlebar_chip));
                }
                menu.highlight_alpha.retargetTo(now, 1, anim.curveFor(.titlebar_chip_fade));
            } else menu.highlight_alpha.retargetTo(now, 0, anim.curveFor(.titlebar_chip_fade));
            menu.root_children[1].markPaintDirty();
            menu.requestWidgetRepaint();
        }
    }

    fn paintHighlight(menu: *PowerMenu, renderer: *ui.paint.Renderer) void {
        const now = anim.nowMs();
        const alpha = std.math.clamp(menu.highlight_alpha.value(now), 0, 1);
        if (alpha <= 0) return;
        // Slot interpolation also follows the vertical layout on narrow
        // outputs. During selection the outline travels with the chosen card.
        const slot = std.math.clamp(menu.highlight_pos.value(now), 0, @as(f32, @floatFromInt(tiles.len - 1)));
        const index: usize = @intFromFloat(@floor(slot));
        const a = &menu.cards[menu.selected orelse index];
        const b = &menu.cards[menu.selected orelse @min(index + 1, tiles.len - 1)];
        const fraction = slot - @as(f32, @floatFromInt(index));
        var border = theme.global.danger;
        border[3] *= alpha;
        const pressed = if (menu.highlight_target) |id| menu.cards[id].kind.row.state == .press else false;
        renderer.fillRect(
            a.computed_x + (b.computed_x - a.computed_x) * fraction,
            a.computed_y + (b.computed_y - a.computed_y) * fraction,
            a.computed_width + (b.computed_width - a.computed_width) * fraction,
            a.computed_height + (b.computed_height - a.computed_height) * fraction,
            .{ .color = .{ 0, 0, 0, 0 }, .radius = 12, .border_width = if (pressed) 3 else 2.5, .border_color = border },
        );
    }

    fn requestWidgetRepaint(menu: *PowerMenu) void {
        menu.dirty = true;
        menu.wlr_output.scheduleFrame();
    }

    pub fn requestRepaint(menu: *PowerMenu) void {
        menu.background.invalidate();
        menu.dirty = true;
        menu.wlr_output.scheduleFrame();
    }

    pub fn beginClose(menu: *PowerMenu) void {
        if (menu.state == .closing) return;
        menu.state = .closing;
        menu.slide.retargetTo(anim.nowMs(), 0, anim.curveFor(.panel_slide));
        menu.wlr_output.scheduleFrame();
    }

    pub fn finishedClosing(menu: *PowerMenu, now_ms: i64) bool {
        return menu.state == .closing and menu.slide.settled(now_ms);
    }

    fn paintContent(menu: *PowerMenu) void {
        if (menu.panel_box.width <= 0 or menu.panel_box.height <= 0) return;
        const scale = menu.wlr_output.scale;
        const buf = PanelBuffer.createUninitialized(menu.panel_box.width, menu.panel_box.height, scale) catch |err| {
            log.err("PowerMenu.paintContent: could not create panel buffer: {}", .{err});
            return;
        };

        const t0 = panel_present.nowNs();
        var renderer = ui.paint.Renderer.init(buf.pixels, buf.width, buf.height, scale);
        menu.background.paintIncremental(gpa, &menu.root, &renderer);
        // Keep the moving outline out of the retained pixels. Each glide
        // frame repairs the entire card strip before painting it again.
        menu.paintHighlight(&renderer);
        const elapsed_ns = panel_present.nowNs() -| t0;

        buf.publish(menu.buffer_node, scale, menu.background.damage);
        menu.buffer_node.setDestSize(menu.panel_box.width, menu.panel_box.height);
        buf.base.drop();
        panel_present.addPaint(elapsed_ns);
        menu.dirty = false;
    }

    fn applyPresentation(menu: *PowerMenu, now_ms: i64) void {
        if (menu.panel_box.width <= 0 or menu.panel_box.height <= 0) return;
        const t = menu.slide.value(now_ms);
        panel_present.applySlide(menu.buffer_node, menu.panel_box, t, slide_distance);
        // The blur itself stays fully applied throughout — only the panel's
        // scene-buffer opacity and the scrim animate with `t`.
        glass.Effect.configure(menu.glass_effect, panel_radius, glass_opacity);
        const backdrop = theme.global.power_menu_backdrop;
        const scrim_alpha = backdrop[3] * std.math.clamp(t, 0, 1);
        if (menu.scrim.color[3] != scrim_alpha) {
            col.setRect(menu.scrim, col.Straight.fromRgba(.{ backdrop[0], backdrop[1], backdrop[2], scrim_alpha }).premultiply());
        }
        if (menu.state == .opening and (menu.slide.settled(now_ms) or panel_present.slideOffset(t, slide_distance) == 0)) menu.state = .open;
    }

    // ---- Pointer entry points, called from Input.zig ----

    pub fn pointerMotion(menu: *PowerMenu, sx: f64, sy: f64) void {
        if (menu.state == .selecting or menu.state == .closing) return;
        const revision = ui.layout.paint_revision;
        menu.keyboard_focus = null;
        ui.input.pointerMotion(&menu.root, @floatCast(sx), @floatCast(sy));
        menu.syncHighlight();
        if (revision != ui.layout.paint_revision) menu.requestWidgetRepaint();
    }

    pub fn pointerButtonDown(menu: *PowerMenu, sx: f64, sy: f64) void {
        if (menu.state == .selecting or menu.state == .closing) return;
        menu.keyboard_focus = null;
        ui.input.pointerButtonDown(&menu.root, @floatCast(sx), @floatCast(sy));
        menu.syncHighlight();
        menu.requestRepaint();
    }

    pub fn pointerButtonUp(menu: *PowerMenu, sx: f64, sy: f64) void {
        if (menu.state == .selecting or menu.state == .closing) return;
        ui.input.pointerButtonUp(&menu.root, @floatCast(sx), @floatCast(sy));
        if (menu.state == .selecting) menu.cards[menu.selected.?].kind.row.state = .idle;
        menu.requestRepaint();
    }

    pub fn containsPoint(menu: *PowerMenu, lx: f64, ly: f64) bool {
        const box = menu.panel_box;
        return lx >= @as(f64, @floatFromInt(box.x)) and lx < @as(f64, @floatFromInt(box.x + box.width)) and
            ly >= @as(f64, @floatFromInt(box.y)) and ly < @as(f64, @floatFromInt(box.y + box.height));
    }
};

fn onTileClick(owner: ?*anyopaque, id: usize) void {
    const menu: *PowerMenu = @ptrCast(@alignCast(owner orelse return));
    menu.select(id);
}
