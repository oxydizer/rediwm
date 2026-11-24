//! IPC payload builders: windows, outputs, camera, shell state and lookups.

const std = @import("std");
const wlr = @import("wlroots");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const Toplevel = @import("../Toplevel.zig");
const output_tearing = @import("../output/tearing.zig");
const output_vrr = @import("../output/vrr.zig");
const output_hdr = @import("../output/hdr.zig");
const stats = @import("stats.zig");
const protocol = @import("protocol.zig");
const ui = @import("ui");
const controlCenterState = @import("handlers_panels.zig").controlCenterState;

pub fn cloneRequestId(rid: protocol.RequestId, allocator: std.mem.Allocator) !protocol.RequestId {
    return switch (rid) {
        .integer => |i| .{ .integer = i },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
    };
}

pub fn freeRequestId(rid: protocol.RequestId, allocator: std.mem.Allocator) void {
    switch (rid) {
        .string => |s| allocator.free(s),
        .integer => {},
    }
}

pub fn getBackendName(backend: *wlr.Backend) []const u8 {
    if (backend.isWl()) return "wayland";
    if (backend.isDrm()) return "drm";
    if (backend.isHeadless()) return "headless";
    if (backend.isX11()) return "x11";
    if (backend.isMulti()) return "multi";
    return "unknown";
}

pub fn getRendererName(renderer: *wlr.Renderer) []const u8 {
    if (renderer.isGles2()) return "gles2";
    if (renderer.isPixman()) return "pixman";
    return "unknown";
}

pub fn startupStats() protocol.StartupStats {
    const startup = @import("../startup.zig");
    const m = startup.marks;
    return .{
        .build_mode = m.build_mode,
        .renderer = m.renderer,
        .scale = m.scale,
        .output_count = m.output_count,
        .catalog_entries = m.catalog_entries,
        .autostart_count = m.autostart_count,
        .catalog_state = @tagName(m.catalog_state),
        .wallpaper_state = @tagName(m.wallpaper_state),
        .catalog_provisional = m.catalog_provisional,
        .catalog_loading = m.catalog_loading,
        .catalog_generation = m.catalog_generation,
        .renderer_ready_ns = startup.offset(m.renderer_ready_ns),
        .config_ready_ns = startup.offset(m.config_ready_ns),
        .catalog_cache_read_ns = startup.offset(m.catalog_cache_read_ns),
        .catalog_scan_ns = startup.offset(m.catalog_scan_ns),
        .wallpaper_decode_ns = startup.offset(m.wallpaper_decode_ns),
        .socket_ready_ns = startup.offset(m.socket_ready_ns),
        .ipc_ready_ns = startup.offset(m.ipc_ready_ns),
        .session_ready_ns = startup.offset(m.session_ready_ns),
        .session_clients_started_ns = startup.offset(m.session_clients_started_ns),
        .xwayland_ready_ns = startup.offset(m.xwayland_ready_ns),
        .first_presented_ns = startup.offset(m.first_presented_ns),
        .first_ipc_ns = startup.offset(m.first_ipc_ns),
        .first_input_ns = startup.offset(m.first_input_ns),
        .catalog_published_ns = startup.offset(m.catalog_published_ns),
        .wallpaper_presented_ns = startup.offset(m.wallpaper_presented_ns),
        .catalog_cache_read_duration_ns = m.catalog_cache_read_duration_ns,
        .catalog_scan_duration_ns = m.catalog_scan_duration_ns,
        .wallpaper_decode_duration_ns = m.wallpaper_decode_duration_ns,
        .backend_start_ns = startup.offset(m.backend_start_ns),
        .backend_ready_ns = startup.offset(m.backend_ready_ns),
        .input_ready_ns = startup.offset(m.input_ready_ns),
        .first_visible_ns = startup.offset(m.first_visible_ns),
        .services_started_ns = startup.offset(m.services_started_ns),
        .login_to_compositor_ns = startup.loginOffset(m.origin_ns),
        .login_to_visible_ns = startup.loginOffset(m.first_visible_ns),
        .reveal_done_ns = startup.offset(m.reveal_done_ns),
    };
}

pub fn makeAudioStateData(mgr: anytype, allocator: std.mem.Allocator) !protocol.AudioStateData {
    mgr.lock();
    defer mgr.unlock();

    var master_volume: f32 = 0;
    var master_muted = false;
    var default_sink: []const u8 = "";
    for (mgr.sinks.items) |s| {
        if (!s.is_default) continue;
        master_volume = s.volume;
        master_muted = s.muted;
        default_sink = try allocator.dupe(u8, s.description);
    }

    var streams = std.ArrayList(protocol.SinkInputData).empty;
    for (mgr.sink_inputs.items) |si| {
        try streams.append(allocator, .{
            .index = si.index,
            .name = try allocator.dupe(u8, si.name),
            .app_id = try allocator.dupe(u8, si.app_id),
            .pid = si.pid,
            .volume = si.volume,
            .muted = si.muted,
        });
    }

    return .{
        .master_volume = master_volume,
        .master_muted = master_muted,
        .default_sink = default_sink,
        .streams = try streams.toOwnedSlice(allocator),
    };
}

pub fn makeWindowData(server: *Server, toplevel: *Toplevel) protocol.WindowData {
    const is_focused = findFocusedToplevel(server) == toplevel;

    return .{
        .id = toplevel.id,
        .title = toplevel.titleOrNull(),
        .app_id = toplevel.appIdOrNull(),
        .sandbox = toplevel.sandboxInfo(),
        .pid = toplevel.clientPid(),
        .is_focused = is_focused,
        .is_urgent = toplevel.needs_attention,
        .is_minimized = toplevel.minimized,
        .tab_group = if (toplevel.tab_group != 0) toplevel.tab_group else null,
        .tab_active = !toplevel.tab_hidden,
        .is_maximized = toplevel.isMaximized(),
        .workspace_order = toplevel.workspace_order,
        .placement = if (toplevel.fullscreen) "fullscreen" else if (toplevel.maximized) "maximized" else if (toplevel.tile != null) "manual" else if (toplevel.auto_target != null) "automatic" else "floating",
        .floating_override = toplevel.auto_float_override,
        .workspace_id = if (server.world.workspaces.active) toplevel.workspace_id else 1,
        .tag = @import("../extra_protocols.zig").tag(toplevel.surface(), false),
        .description = @import("../extra_protocols.zig").tag(toplevel.surface(), true),
        .content_type = @import("../extra_protocols.zig").content(server, toplevel.surface()),
        .x = toplevel.x,
        .y = toplevel.y,
        .width = toplevel.logicalWidth(),
        .height = toplevel.logicalHeight(),
        .zoom_percent = if (server.world.workspaces.active) 100 else @import("../camera.zig").zoom_levels[toplevel.zoom_index],
        .backend = toplevel.backendName(),
        .x11_class = toplevel.x11Class(),
        .x11_instance = toplevel.x11Instance(),
        .placeholder = if (toplevel.backend == .placeholder) true else null,
    };
}

pub fn makeOutputData(server: *Server, output: *Output) protocol.OutputData {
    const name = std.mem.span(output.wlr_output.name);
    const make = if (output.wlr_output.make) |m| std.mem.span(m) else null;
    const model = if (output.wlr_output.model) |m| std.mem.span(m) else null;

    const default_out = server.getDefaultOutput();
    const is_focused = if (default_out) |d| d == output else false;

    var box: wlr.Box = undefined;
    server.output_layout.getBox(output.wlr_output, &box);

    const refresh_hz: f32 = if (output.wlr_output.refresh > 0)
        @as(f32, @floatFromInt(output.wlr_output.refresh)) / 1000.0
    else
        60.0;

    const transform_str = switch (output.wlr_output.transform) {
        .normal => "normal",
        .@"90" => "90",
        .@"180" => "180",
        .@"270" => "270",
        .flipped => "flipped",
        .flipped_90 => "flipped_90",
        .flipped_180 => "flipped_180",
        .flipped_270 => "flipped_270",
        else => "normal",
    };

    return .{
        .name = name,
        .make = make,
        .model = model,
        .enabled = output.wlr_output.enabled,
        .x = box.x,
        .y = box.y,
        .logical_width = box.width,
        .logical_height = box.height,
        .bottom_exclusion = if (server.config.compositor.taskbar_position == .bottom) (if (output.taskbar) |tb| tb.box.height else 0) else 0,
        .buffer_width = output.wlr_output.width,
        .buffer_height = output.wlr_output.height,
        .transform = transform_str,
        .scale = output.wlr_output.scale,
        .refresh_hz = refresh_hz,
        .is_focused = is_focused,
        .tearing_allowed = output_tearing.wanted(output),
        .tearing_active = output.tearing.active,
        .tearing_paused = output_tearing.paused(output),
        .adaptive_sync = @tagName(output_vrr.mode(output)),
        .adaptive_sync_supported = output_vrr.supported(output),
        .adaptive_sync_wanted = output_vrr.wanted(output),
        .adaptive_sync_active = output_vrr.active(output),
        .adaptive_sync_needs_modeset = output.vrr.needs_modeset,
        .hdr = @tagName(output_hdr.mode(output)),
        .hdr_supported = output_hdr.supported(output),
        .hdr_active = output_hdr.active(output),
        .hdr_linear = output_hdr.linear(output),
        .sdr_white = output_hdr.sdrWhite(output),
        .direct_scanout = if (server.scene_outputs.get(output.wlr_output)) |scene_output| scene_output.directScanout() else false,
    };
}

pub fn makeCameraData(server: *Server) protocol.CameraData {
    const now = @import("ui").anim.nowMs();
    const cam = server.world.sampledCamera(now);
    const offset = @import("../camera.zig").appliedOffset(cam);
    const max_xi: i32 = @intFromFloat(server.world.bounds.max_x);
    const max_yi: i32 = @intFromFloat(server.world.bounds.max_y);
    return .{
        .x = offset.x,
        .y = offset.y,
        .max_x = max_xi,
        .max_y = max_yi,
        .zoom_percent = server.world.camera.targetPercent(),
    };
}

pub fn makeShellStateData(server: *Server) protocol.ShellStateData {
    var shell = protocol.ShellStateData{};
    const now = @import("ui").anim.nowMs();
    if (server.getDefaultOutput()) |out| {
        if (out.start_menu) |sm| {
            shell.start_menu = .{
                .state = @tagName(sm.state),
                .progress = sm.slide.value(now),
                .is_settled = (sm.state == .open and sm.slide.settled(now)),
                .box = .{ .x = sm.panel_box.x, .y = sm.panel_box.y, .width = sm.panel_box.width, .height = sm.panel_box.height },
                .search_text = if (sm.model.query.items.len > 0) sm.model.query.items else null,
                .category = @tagName(sm.model.category),
                .selected_index = @intCast(sm.model.selected_index),
                .result_count = sm.model.results.len,
            };
        }
        if (server.input.open_control_center) |cc| {
            shell.control_center = controlCenterState(cc, now);
        }
        if (out.power_menu) |pm| {
            shell.power_menu = .{
                .state = @tagName(pm.state),
                .progress = pm.slide.value(now),
                .is_settled = (pm.state == .open and pm.slide.settled(now)),
                .box = .{ .x = pm.panel_box.x, .y = pm.panel_box.y, .width = pm.panel_box.width, .height = pm.panel_box.height },
            };
        }
    }
    var tb_count: usize = 0;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |o| {
        if (o.taskbar != null) tb_count += 1;
    }
    if (server.polkit_dialog) |dialog| shell.polkit_dialog = .{
        .state = if (dialog.ended) "failed" else if (dialog.waiting) "waiting" else "prompt",
        .box = .{ .x = dialog.panel_box.x, .y = dialog.panel_box.y, .width = dialog.panel_box.width, .height = dialog.panel_box.height },
    };
    shell.taskbar_count = tb_count;
    return shell;
}

pub fn findToplevelById(server: *Server, id: u64) ?*Toplevel {
    var it = server.world.toplevels.iterator(.forward);
    while (it.next()) |toplevel| {
        if (toplevel.id == id) return toplevel;
    }
    return null;
}

pub fn findFocusedToplevel(server: *Server) ?*Toplevel {
    if (server.input.seat.keyboard_state.focused_surface) |surface| {
        const top = Toplevel.fromSurface(server, surface) orelse return null;
        return if (@import("../workspaces.zig").visible(top)) top else null;
    }
    // The settings window is focused without a wl_surface.
    if (server.input.open_control_center) |cc| if (cc.hasKeyboardFocus()) return cc.toplevel;
    return null;
}

pub fn findOutputByName(server: *Server, name: []const u8) ?*Output {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |output| {
        const out_name = std.mem.span(output.wlr_output.name);
        if (std.mem.eql(u8, out_name, name)) return output;
    }
    return null;
}
