const std = @import("std");
const wlr = @import("wlroots");

const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const Toplevel = @import("../Toplevel.zig");
const protocol = @import("protocol.zig");
const stats = @import("stats.zig");
const scene_data = @import("../scene_data.zig");
const chrome = @import("../chrome.zig");
const ui = @import("ui");
const virtual_input_mod = @import("../input/virtual.zig");
const VirtualInput = virtual_input_mod.VirtualInput;
const Client = @import("server.zig").Client;
const actions = @import("../config_runtime/actions.zig");
const events = @import("events.zig");
const taskbar_items = @import("config").taskbar_items;
const handlers_queries = @import("handlers_queries.zig");
const handlers_panels = @import("handlers_panels.zig");
const handlers_widgets = @import("handlers_widgets.zig");
const handlers_data = @import("handlers_data.zig");
const handlers_state = @import("handlers_state.zig");
const handlers_inspect = @import("handlers_inspect.zig");
const handlers_input = @import("handlers_input.zig");
const handlers_windows = @import("handlers_windows.zig");
const handlers_frames = @import("handlers_frames.zig");
pub const getNightLight = handlers_queries.getNightLight;
pub const getIdleState = handlers_queries.getIdleState;
pub const getCaptureState = handlers_queries.getCaptureState;
pub const getWindowRules = handlers_queries.getWindowRules;
pub const matchWindowRules = handlers_queries.matchWindowRules;
pub const walkSceneTree = handlers_queries.walkSceneTree;
pub const ClipRect = handlers_panels.ClipRect;
pub const PanelRoot = handlers_panels.PanelRoot;
pub const PanelRegistryEntry = handlers_panels.PanelRegistryEntry;
pub const resolveStartMenu = handlers_panels.resolveStartMenu;
pub const resolveControlCenter = handlers_panels.resolveControlCenter;
pub const controlCenterState = handlers_panels.controlCenterState;
pub const resolvePowerMenu = handlers_panels.resolvePowerMenu;
pub const resolveDock = handlers_panels.resolveDock;
pub const panel_registry = handlers_panels.panel_registry;
pub const walkWidgetTree = handlers_widgets.walkWidgetTree;
pub const computeTargetPoint = handlers_widgets.computeTargetPoint;
pub const findWidgetInNodes = handlers_widgets.findWidgetInNodes;
pub const ResolveWidgetOutcome = handlers_widgets.ResolveWidgetOutcome;
pub const buildTaskbarWidgetTree = handlers_widgets.buildTaskbarWidgetTree;
pub const buildWindowWidgetTree = handlers_widgets.buildWindowWidgetTree;
pub const appendTabWidget = handlers_widgets.appendTabWidget;
pub const findVirtualWidgetNode = handlers_widgets.findVirtualWidgetNode;
pub const findWidgetNode = handlers_widgets.findWidgetNode;
pub const resolveWidget = handlers_widgets.resolveWidget;
pub const cloneRequestId = handlers_data.cloneRequestId;
pub const freeRequestId = handlers_data.freeRequestId;
pub const getBackendName = handlers_data.getBackendName;
pub const getRendererName = handlers_data.getRendererName;
pub const startupStats = handlers_data.startupStats;
pub const makeAudioStateData = handlers_data.makeAudioStateData;
pub const makeWindowData = handlers_data.makeWindowData;
pub const makeOutputData = handlers_data.makeOutputData;
pub const makeCameraData = handlers_data.makeCameraData;
pub const makeShellStateData = handlers_data.makeShellStateData;
pub const findToplevelById = handlers_data.findToplevelById;
pub const findFocusedToplevel = handlers_data.findFocusedToplevel;
pub const findOutputByName = handlers_data.findOutputByName;

pub fn automationEnabled(server: *const Server) bool {
    const ipc = server.ipc orelse return false;
    return ipc.automation;
}

pub fn handleRequest(
    server: *Server,
    request_id: ?protocol.RequestId,
    request: protocol.Request,
    allocator: std.mem.Allocator,
    client: ?*Client,
) !protocol.Response {
    if (server.locker != null) return .{ .err = "SessionLocked" };
    if (client) |c_ptr| {
        if (c_ptr.sandbox) |sb| {
            const groups = server.config.sandboxAllowGroups(sb.app_id, sb.engine);
            if (!groups.contains(.ipc)) {
                return .{ .err = "PermissionDenied: sandboxed caller lacks ipc allowance" };
            }
            if (protocol.commands.requiresAutomation(request) and !groups.contains(.automation)) {
                return .{ .err = "PermissionDenied: sandboxed caller lacks automation allowance" };
            }
        }
    }
    if (protocol.commands.requiresAutomation(request) and !automationEnabled(server))
        return .{ .err = "AutomationDisabled: set [ipc] automation = true and restart rediwm" };
    if (server.polkit_dialog != null) switch (request) {
        .get_shell_state, .get_state, .get_input_state, .get_widget_tree, .outputs, .windows, .version, .capabilities, .event_stream, .event_stream_filtered => {},
        .action => |act| switch (act) {
            .wait_for_frame => {},
            else => return .{ .err = "AuthenticationActive" },
        },
        else => return .{ .err = "AuthenticationActive" },
    };
    switch (request) {
        .get_services => return @import("settings.zig").services(server, allocator),
        .get_sounds => return .{ .ok = .{ .sounds = try @import("../audio/sounds.zig").inspect(server, allocator) } },
        .get_wallpaper => return @import("settings.zig").wallpaper(server, allocator),
        .theme_list => {
            const packs = try @import("config").theme_pack.list(allocator, server.io, server.environ, server.config.path);
            var result: protocol.ResponsePayload = .{ .theme_packs = .{ .active = server.config.theme_base, .packs = &.{} } };
            const T = @typeInfo(@TypeOf(result.theme_packs.packs)).pointer.child;
            const rows = try allocator.alloc(T, packs.len);
            for (packs, rows) |p, *row| row.* = .{ .id = p.id, .name = p.name, .version = p.version, .user_installed = p.user_installed };
            result.theme_packs.packs = rows;
            return .{ .ok = result };
        },
        .get_theme => return @import("settings.zig").getTheme(server, allocator),
        .get_processes => return @import("processes.zig").start(server, request_id, client),
        .get_keyboard_layouts => return .{ .ok = .{ .keyboard_layouts = try @import("../input/layouts.zig").inspect(server, allocator) } },
        .get_input_sources => return .{ .ok = .{ .input_sources = try inputSourcesData(server, allocator) } },
        .version => {
            return .{ .ok = .{ .version = "0.1.0" } };
        },
        .capabilities => {
            const caps = &protocol.commands.capabilities;
            return .{ .ok = .{ .capabilities = caps } };
        },
        .describe_ipc => {
            const commands = &protocol.commands.descriptions;

            var unavailable = std.ArrayList([]const u8).empty;
            if (server.audio == null) try unavailable.append(allocator, "audio unavailable");
            if (server.virtual_input == null) try unavailable.append(allocator, "virtual input unavailable");
            if (server.screenshot_mgr == null) try unavailable.append(allocator, "screenshot manager unavailable");
            if (server.idle == null) try unavailable.append(allocator, "idle manager unavailable");
            if (!automationEnabled(server)) try unavailable.append(allocator, "automation disabled: synthetic input, screenshots, pixel reads and buffer dumps need [ipc] automation = true");

            return .{ .ok = .{ .describe_ipc = .{
                .protocol_version = "1",
                .build_version = "0.1.0",
                .backend = getBackendName(server.backend),
                .renderer = getRendererName(server.renderer),
                .commands = commands,
                .unavailable_reasons = try unavailable.toOwnedSlice(allocator),
            } } };
        },
        .windows => {
            var list = std.ArrayList(protocol.WindowData).empty;
            var it = server.world.toplevels.iterator(.forward);
            while (it.next()) |toplevel| {
                const win = makeWindowData(server, toplevel);
                try list.append(allocator, win);
            }
            const wins = try list.toOwnedSlice(allocator);
            return .{ .ok = .{ .windows = wins } };
        },
        .outputs => {
            var list = std.ArrayList(protocol.OutputData).empty;
            var it = server.outputs.iterator(.forward);
            while (it.next()) |output| {
                const out = makeOutputData(server, output);
                try list.append(allocator, out);
            }
            const outs = try list.toOwnedSlice(allocator);
            return .{ .ok = .{ .outputs = outs } };
        },
        .focused_window => {
            if (findFocusedToplevel(server)) |toplevel| {
                return .{ .ok = .{ .focused_window = makeWindowData(server, toplevel) } };
            } else {
                return .{ .ok = .{ .focused_window = null } };
            }
        },
        .workspaces => {
            return .{ .ok = .{ .workspaces = try server.world.workspaces.data(server, allocator) } };
        },
        .event_stream => {
            return .{ .ok = .handled };
        },
        .event_stream_filtered => {
            return .{ .ok = .handled };
        },
        .get_state, .get_window_debug, .get_shell_state, .get_text_input, .get_input_state => return handlers_state.handleStateRequest(server, request_id, request, allocator, client),
        .hit_test, .get_scene_tree, .get_layer_surfaces, .get_widget_tree, .list_panels, .get_config_status, .get_runtime_info => return handlers_inspect.handleInspectRequest(server, request_id, request, allocator, client),
        .get_idle_state => {
            return getIdleState(server, allocator);
        },
        .get_capture_state => {
            return getCaptureState(server, allocator);
        },
        .get_window_rules => |p| {
            return getWindowRules(server, p.id, allocator);
        },
        .match_window_rules => |p| {
            return matchWindowRules(server, p, allocator);
        },
        .get_night_light => {
            return getNightLight(server, allocator);
        },
        .get_notifications => {
            const notif_mgr = server.notifications orelse return .{ .err = "NotificationsUnavailable" };
            return .{ .ok = .{ .notifications = try notif_mgr.getNotificationsResult(allocator) } };
        },
        .action => |act| {
            return handleAction(server, request_id, act, allocator, client);
        },
    }
}

pub fn handleAction(
    server: *Server,
    request_id: ?protocol.RequestId,
    action: protocol.Action,
    allocator: std.mem.Allocator,
    client: ?*Client,
) !protocol.Response {
    switch (action) {
        .set_service_mode => |p| {
            const systemd = server.getSystemd() catch return .{ .err = "ServicesUnavailable" };
            systemd.setMode(p.service, p.mode) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .{ .service_mode = .{ .service = p.service, .mode = p.mode } } };
        },
        .play_sound => |p| return @import("../audio/sounds.zig").play(server, allocator, p.event) catch |err| .{ .err = @errorName(err) },
        .theme_apply => |p| {
            @import("../config_runtime/theme_pack.zig").apply(server, p.id) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .theme_install => |p| {
            @import("../config_runtime/theme_job.zig").start(server, if (p.replace) &.{ "install", p.path, "--replace" } else &.{ "install", p.path }, client, request_id) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .async_pending };
        },
        .set_wallpaper => |p| {
            @import("settings.zig").setWallpaper(server, p.path, p.persist) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .set_accent_color => |p| {
            @import("settings.zig").setAccent(server, p.color, p.persist) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .set_night_light => |p| {
            @import("settings.zig").setNightLight(server, p.enabled, p.temperature, p.persist) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .open_appearance => {
            server.openAppearance();
            return .{ .ok = .handled };
        },
        .focus_window, .close_window, .move_window_to, .spawn, .set_desktop_mode, .set_window_gap, .set_floating_apps, .set_workspace_layout, .switch_workspace, .move_to_workspace, .tiling_action, .maximize_window, .minimize_window, .restore_window, .fullscreen_window, .stop_xwayland, .set_window_size, .set_window_zoom => return handlers_windows.handleWindowAction(server, request_id, action, allocator, client),
        .move_cursor, .move_cursor_relative, .pointer_button, .click, .scroll, .pinch, .swipe, .key, .key_press, .type_text, .drag, .click_widget, .hover_widget => return handlers_input.handleInputAction(server, request_id, action, allocator, client),
        .screenshot, .stop_all_capture, .wait_for, .wait_for_frame, .dump_buffer, .sample_pixels, .get_performance_stats, .reset_performance_stats => return handlers_frames.handleFrameAction(server, request_id, action, allocator, client),
        .get_camera => {
            const cam = makeCameraData(server);
            return .{ .ok = .{ .camera = .{ .x = cam.x, .y = cam.y, .max_x = cam.max_x, .max_y = cam.max_y, .zoom_percent = cam.zoom_percent } } };
        },
        .set_camera => |p| {
            if (!server.input.canZoom() or server.input.cursor_mode == .pan) return .{ .err = "Busy" };
            server.world.springPan(@floatFromInt(p.x), @floatFromInt(p.y), .camera_pan);
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .set_zoom => |p| {
            if (!server.input.canZoom()) return .{ .err = "Busy" };
            for (@import("../camera.zig").zoom_levels, 0..) |percent, index| {
                if (@min(percent, 100) == p.percent) {
                    server.world.setZoom(index, server.input.cursor.x, server.input.cursor.y);
                    return .{ .ok = .handled };
                }
            }
            return .{ .err = "InvalidRequest" };
        },
        .reset_camera => {
            if (!server.input.canZoom() or server.input.cursor_mode == .pan) return .{ .err = "Busy" };
            server.world.resetCamera();
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .set_master_volume => |p| {
            const mgr = server.audio orelse return .{ .err = "Unsupported" };
            mgr.setMasterVolume(p.volume);
            return .{ .ok = .handled };
        },
        .toggle_mute => {
            const mgr = server.audio orelse return .{ .err = "Unsupported" };
            mgr.toggleMasterMute();
            return .{ .ok = .handled };
        },
        .set_app_volume => |p| {
            const mgr = server.audio orelse return .{ .err = "Unsupported" };
            mgr.setSinkInputVolume(p.index, p.volume);
            return .{ .ok = .handled };
        },
        .set_app_mute => |p| {
            const mgr = server.audio orelse return .{ .err = "Unsupported" };
            mgr.setSinkInputMute(p.index, p.muted);
            return .{ .ok = .handled };
        },
        .get_audio_state => {
            const mgr = server.audio orelse return .{ .err = "Unsupported" };
            return .{ .ok = .{ .audio_state = try makeAudioStateData(mgr, allocator) } };
        },
        .get_panel_stats => {
            const panel_s = @import("../panel_present.zig").snapshot();
            return .{ .ok = .{ .panel_stats = .{
                .paints = panel_s.paints,
                .allocated_bytes = panel_s.allocated_bytes,
                .reused_bytes = panel_s.reused_bytes,
                .paint_ns = panel_s.paint_ns,
            } } };
        },
        .get_animations => {
            return .{ .ok = .{ .animations = try @import("animations.zig").snapshot(server, allocator) } };
        },
        .reset_panel_stats => {
            @import("../panel_present.zig").reset();
            return .{ .ok = .handled };
        },
        .set_anim_time => |p| {
            @import("ui").anim.setNowMs(p.ms);
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .open_start_menu => {
            const output = server.getDefaultOutput() orelse return .{ .err = "NoOutput" };
            // Handles the already-open and mid-close cases itself, including
            // the keyboard routing and taskbar state a bare `reopen` misses.
            output.openStartMenu();
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .open_control_center => {
            const output = server.getDefaultOutput() orelse return .{ .err = "NoOutput" };
            output.toggleControlCenter();
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .open_power_menu => {
            const output = server.getDefaultOutput() orelse return .{ .err = "NoOutput" };
            output.openPowerMenu();
            server.scheduleFrames();
            return .{ .ok = .handled };
        },

        .close_panel => |p| {
            const out = server.getDefaultOutput() orelse return .{ .err = "NoOutput" };
            const panel = std.meta.stringToEnum(enum { start_menu, control_center, power_menu }, p.panel) orelse
                return .{ .err = "UnknownPanel" };
            switch (panel) {
                .start_menu => out.closeStartMenu(),
                .control_center => out.closeControlCenter(),
                .power_menu => out.closePowerMenu(),
            }
            server.scheduleFrames();
            return .{ .ok = .handled };
        },
        .restart_shell => {
            @import("../config_runtime/actions.zig").executeAction(server, .restart_shell);
            return .{ .ok = .handled };
        },
        .switch_layout => |target| {
            @import("../input/layouts.zig").switchLayout(server, target) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .switch_input_source => |target| {
            const sources = server.input_sources orelse return .{ .err = "Unsupported" };
            switch (target) {
                .next => sources.cycle(true),
                .prev => sources.cycle(false),
                .index => |index| if (!sources.select(index)) return .{ .err = "InvalidSourceIndex" },
            }
            return .{ .ok = .handled };
        },
        .reload_config => {
            @import("../config_runtime/watcher.zig").reloadConfig(server);
            return .{ .ok = .handled };
        },
        .launch_app => |p| {
            const launch_mod = @import("../start_menu/launch.zig");
            const snap = server.start_menu_catalog.retainSnapshot();
            defer snap.release();
            for (snap.entries) |*entry| {
                if (std.mem.eql(u8, entry.id, p.desktop_id)) {
                    try launch_mod.launchUris(allocator, server, entry, p.uris);
                    return .{ .ok = .handled };
                }
            }
            return .{ .err = "UnknownDesktopId" };
        },
        .get_idle_state => {
            return getIdleState(server, allocator);
        },
        .set_output_config => |p| {
            const output = findOutputByName(server, p.output) orelse return .{ .err = "UnknownOutput" };
            output.applyAndPersist(p) catch |err| return .{ .err = @errorName(err) };
            return .{ .ok = .handled };
        },
        .set_idle_config => |p| {
            if (server.idle) |im| {
                if (p.enabled) |e| im.config.enabled = e;
                if (p.blank_after_seconds) |b| im.config.blank_after_seconds = b;
                if (p.suspend_after_seconds) |s| im.config.suspend_after_seconds = s;
                im.recheckInhibitors();
                im.armNextTimeout();
                return .{ .ok = .handled };
            }
            return .{ .err = "IdleManagerNotAvailable" };
        },
        .advance_idle_time => |p| {
            if (server.idle) |im| {
                const current = im.clock.nowMs();
                const target = current + (@as(i64, p.seconds) * 1000);
                im.clock.mock_now_ms = target;
                im.tickTimer();
                return .{ .ok = .handled };
            }
            return .{ .err = "IdleManagerNotAvailable" };
        },
        .get_night_light => {
            return getNightLight(server, allocator);
        },
        .set_night_light_clock => |p| {
            server.night_light.setClockOverride(p.unix_seconds);
            return .{ .ok = .handled };
        },
        .dismiss_notification => |p| {
            const notif_mgr = server.notifications orelse return .{ .err = "NotificationsUnavailable" };
            const reason = p.reason orelse 2;
            notif_mgr.closeNotification(p.id, reason);
            return .{ .ok = .handled };
        },
        .invoke_notification_action => |p| {
            const notif_mgr = server.notifications orelse return .{ .err = "NotificationsUnavailable" };
            notif_mgr.invokeAction(p.id, p.action_key);
            return .{ .ok = .handled };
        },
        .set_dnd => |p| {
            const notif_mgr = server.notifications orelse return .{ .err = "NotificationsUnavailable" };
            notif_mgr.dnd = p.enabled;
            return .{ .ok = .handled };
        },
        .clear_notifications => {
            const notif_mgr = server.notifications orelse return .{ .err = "NotificationsUnavailable" };
            notif_mgr.clearNotifications("all");
            return .{ .ok = .handled };
        },
        .undo => {
            @import("../config_runtime/actions.zig").executeAction(server, .undo);
            return .{ .ok = .handled };
        },
    }
}

/// One pixel read in a little-endian 32-bit DRM `format`, as 0xAARRGGBB.
pub fn packedArgb(format: u32, pixel: u32) ?u32 {
    const argb8888: u32 = 0x34325241;
    const xrgb8888: u32 = 0x34325258;
    const abgr8888: u32 = 0x34324241;
    const xbgr8888: u32 = 0x34324258;
    const swapped = (pixel & 0xff00ff00) | ((pixel & 0xff) << 16) | ((pixel >> 16) & 0xff);
    return switch (format) {
        argb8888 => pixel,
        xrgb8888 => pixel | 0xff000000,
        abgr8888 => swapped,
        xbgr8888 => swapped | 0xff000000,
        else => null,
    };
}

test "sampled pixels are reported as 0xAARRGGBB from every 8-bit read format" {
    try std.testing.expectEqual(@as(?u32, 0x80112233), packedArgb(0x34325241, 0x80112233));
    try std.testing.expectEqual(@as(?u32, 0xff112233), packedArgb(0x34325258, 0x00112233));
    try std.testing.expectEqual(@as(?u32, 0x80112233), packedArgb(0x34324241, 0x80332211));
    try std.testing.expectEqual(@as(?u32, 0xff112233), packedArgb(0x34324258, 0x00332211));
    try std.testing.expectEqual(@as(?u32, null), packedArgb(0, 0));
}

/// `dump_buffer` targets; the panel tags double as `Output` field names.
pub const DumpTarget = enum {
    titlebar,
    taskbar,
    start_menu,
    control_center,
    power_menu,

    pub fn missingError(comptime target: DumpTarget) []const u8 {
        return switch (target) {
            .taskbar => "NoTaskbar",
            .start_menu => "StartMenuNotOpen",
            .control_center => "ControlCenterNotOpen",
            .power_menu => "PowerMenuNotOpen",
            .titlebar => @compileError("window targets have no panel"),
        };
    }
};

test {
    _ = @import("handlers_tests.zig");
}

/// The input source list as IPC reports it (also the `InputSourceChanged` body).
pub fn inputSourcesData(server: *Server, allocator: std.mem.Allocator) !protocol.InputSourcesData {
    const manager = server.input_sources orelse return .{};
    const list = manager.sources();
    const out = try allocator.alloc(protocol.InputSourceData, list.len);
    for (list, out) |source, *item| item.* = .{ .kind = @tagName(source.kind), .id = source.id, .name = source.name, .label = source.label };
    const active_layout: ?u32 = if (list.len == 0) null else @intCast(@min(manager.active_group, manager.layoutCount() -| 1));
    return .{
        .sources = out,
        .active = if (manager.activeIndex()) |index| @intCast(index) else null,
        .active_layout = active_layout,
        .fcitx_running = manager.fcitxRunning(),
    };
}
