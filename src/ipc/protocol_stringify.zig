//! IPC v1 response and event serialization.

const std = @import("std");
const RequestId = @import("protocol_data.zig").RequestId;
const OutputData = @import("protocol_data.zig").OutputData;
const WorkspaceData = @import("protocol_data.zig").WorkspaceData;
const ScreenshotResult = @import("protocol_data.zig").ScreenshotResult;
const SinkInputData = @import("protocol_data.zig").SinkInputData;
const AudioStateData = @import("protocol_data.zig").AudioStateData;
const AnimationData = @import("protocol_data.zig").AnimationData;
const PanelStateData = @import("protocol_data.zig").PanelStateData;
const ShellStateData = @import("protocol_data.zig").ShellStateData;
const ShellDetailResult = @import("protocol_data.zig").ShellDetailResult;
const WindowDebugResult = @import("protocol_data.zig").WindowDebugResult;
const OpenRulesData = @import("protocol_data.zig").OpenRulesData;
const LiveRulesData = @import("protocol_data.zig").LiveRulesData;
const GetWindowRulesResult = @import("protocol_data.zig").GetWindowRulesResult;
const MatchWindowRulesResult = @import("protocol_data.zig").MatchWindowRulesResult;
const GetStateResult = @import("protocol_data.zig").GetStateResult;
const GetNotificationsResult = @import("protocol_data.zig").GetNotificationsResult;
const DumpBufferResult = @import("protocol_results.zig").DumpBufferResult;
const PerformanceStatsResult = @import("protocol_results.zig").PerformanceStatsResult;
const StartupStats = @import("protocol_results.zig").StartupStats;
const ServiceMode = @import("protocol_results.zig").ServiceMode;
const ResponsePayload = @import("protocol.zig").ResponsePayload;
const Response = @import("protocol.zig").Response;
const StateSnapshot = @import("protocol.zig").StateSnapshot;
const Event = @import("protocol.zig").Event;

pub fn stringifyResponse(response: Response, writer: anytype) !void {
    try stringifyResponseWithId(null, response, writer);
}

pub fn stringifyResponseWithId(id: ?RequestId, response: Response, writer: anytype) !void {
    try writer.writeByte('{');
    if (id) |i| {
        try writer.writeAll("\"id\":");
        try i.stringify(writer);
        try writer.writeByte(',');
    }
    switch (response) {
        .ok => |payload| {
            try writer.writeAll("\"Ok\":");
            try stringifyResponsePayload(payload, writer);
        },
        .err => |msg| {
            try writer.writeAll("\"Err\":");
            try writer.print("{f}", .{std.json.fmt(msg, .{})});
        },
    }
    try writer.writeAll("}\n");
}

pub fn stringifyResponsePayload(payload: ResponsePayload, writer: anytype) !void {
    switch (payload) {
        .version => |v| {
            try writer.writeAll("{\"Version\":");
            try writer.print("{f}", .{std.json.fmt(v, .{})});
            try writer.writeByte('}');
        },
        .input_sources => |data| {
            try writer.print("{{\"InputSources\":{f}}}", .{std.json.fmt(data, .{})});
        },
        .keyboard_layouts => |layouts| {
            try writer.print("{{\"KeyboardLayouts\":{f}}}", .{std.json.fmt(layouts, .{})});
        },
        .capabilities => |caps| {
            try writer.writeAll("{\"Capabilities\":");
            try writer.print("{f}", .{std.json.fmt(caps, .{})});
            try writer.writeByte('}');
        },
        .describe_ipc => |d| {
            try writer.writeAll("{\"DescribeIPC\":");
            try writer.print("{f}", .{std.json.fmt(d, .{})});
            try writer.writeByte('}');
        },
        .windows => |wins| {
            try writer.writeAll("{\"Windows\":");
            try writer.print("{f}", .{std.json.fmt(wins, .{})});
            try writer.writeByte('}');
        },
        .outputs => |outs| {
            try writer.writeAll("{\"Outputs\":");
            try stringifyOutputs(outs, writer);
            try writer.writeByte('}');
        },
        .focused_window => |fw| {
            try writer.writeAll("{\"FocusedWindow\":");
            if (fw) |win| {
                try writer.print("{f}", .{std.json.fmt(win, .{})});
            } else {
                try writer.writeAll("null");
            }
            try writer.writeByte('}');
        },
        .workspaces => |ws| {
            try writer.writeAll("{\"Workspaces\":");
            try stringifyWorkspaces(ws, writer);
            try writer.writeByte('}');
        },
        .screenshot => |sr| {
            try writer.writeAll("{\"Screenshot\":");
            try stringifyScreenshotResult(sr, writer);
            try writer.writeByte('}');
        },
        .text_input => |data| {
            try writer.print("{{\"TextInput\":{f}}}", .{std.json.fmt(data, .{})});
        },
        .camera => |cam| {
            try writer.print("{{\"Camera\":{{\"x\":{d},\"y\":{d},\"max_x\":{d},\"max_y\":{d},\"zoom_percent\":{d}}}}}", .{ cam.x, cam.y, cam.max_x, cam.max_y, cam.zoom_percent });
        },
        .audio_state => |a| {
            try writer.writeAll("{\"AudioState\":");
            try stringifyAudioState(a, writer);
            try writer.writeByte('}');
        },
        .panel_stats => |s| {
            try writer.print("{{\"PanelStats\":{{\"paints\":{d},\"allocated_bytes\":{d},\"reused_bytes\":{d},\"paint_ns\":{d}}}}}", .{
                s.paints, s.allocated_bytes, s.reused_bytes, s.paint_ns,
            });
        },
        .animations => |items| {
            try writer.writeAll("{\"Animations\":");
            try stringifyAnimations(items, writer);
            try writer.writeByte('}');
        },
        .state => |st| {
            try writer.writeAll("{\"State\":");
            try stringifyGetState(st, writer);
            try writer.writeByte('}');
        },
        .wait_for => |wf| {
            try writer.writeAll("{\"WaitFor\":");
            try writer.print("{f}", .{std.json.fmt(wf, .{})});
            try writer.writeByte('}');
        },
        .wait_for_frame => |wff| {
            try writer.writeAll("{\"WaitForFrame\":");
            try writer.print("{f}", .{std.json.fmt(wff, .{})});
            try writer.writeByte('}');
        },
        .window_debug => |wd| {
            try writer.writeAll("{\"WindowDebug\":");
            try stringifyWindowDebug(wd, writer);
            try writer.writeByte('}');
        },
        .shell_state => |ss| {
            try writer.writeAll("{\"ShellState\":");
            try stringifyShellDetail(ss, writer);
            try writer.writeByte('}');
        },
        .input_state => |is| {
            try writer.writeAll("{\"InputState\":");
            try writer.print("{f}", .{std.json.fmt(is, .{})});
            try writer.writeByte('}');
        },
        .hit_test => |ht| {
            try writer.writeAll("{\"HitTest\":");
            try writer.print("{f}", .{std.json.fmt(ht, .{})});
            try writer.writeByte('}');
        },
        .scene_tree => |st| {
            try writer.writeAll("{\"SceneTree\":");
            try writer.print("{f}", .{std.json.fmt(st, .{})});
            try writer.writeByte('}');
        },
        .layer_surfaces => |ls| {
            try writer.writeAll("{\"LayerSurfaces\":");
            try writer.print("{f}", .{std.json.fmt(ls, .{})});
            try writer.writeByte('}');
        },
        .widget_tree => |wt| {
            try writer.writeAll("{\"WidgetTree\":");
            try writer.print("{f}", .{std.json.fmt(wt, .{})});
            try writer.writeByte('}');
        },
        .config_status => |cs| {
            try writer.writeAll("{\"ConfigStatus\":");
            try writer.print("{f}", .{std.json.fmt(cs, .{})});
            try writer.writeByte('}');
        },
        .runtime_info => |ri| {
            try writer.writeAll("{\"RuntimeInfo\":");
            try writer.print("{f}", .{std.json.fmt(ri, .{})});
            try writer.writeByte('}');
        },
        .dump_buffer => |db| {
            try writer.writeAll("{\"DumpBuffer\":");
            try stringifyDumpBuffer(db, writer);
            try writer.writeByte('}');
        },
        .sample_pixels => |sp| {
            try writer.writeAll("{\"SamplePixels\":");
            try writer.print("{f}", .{std.json.fmt(sp, .{})});
            try writer.writeByte('}');
        },
        .performance_stats => |ps| {
            try writer.writeAll("{\"PerformanceStats\":");
            try stringifyPerformanceStats(ps, writer);
            try writer.writeByte('}');
        },
        .idle_state => |idls| {
            try writer.writeAll("{\"IdleState\":");
            try writer.print("{f}", .{std.json.fmt(idls, .{})});
            try writer.writeByte('}');
        },
        .capture_state => |cs| {
            try writer.writeAll("{\"CaptureState\":");
            try writer.print("{f}", .{std.json.fmt(cs, .{})});
            try writer.writeByte('}');
        },
        .window_rules => |wr| {
            try writer.writeAll("{\"WindowRules\":");
            try stringifyWindowRules(wr, writer);
            try writer.writeByte('}');
        },
        .match_window_rules => |mwr| {
            try writer.writeAll("{\"MatchWindowRules\":");
            try stringifyMatchWindowRules(mwr, writer);
            try writer.writeByte('}');
        },
        .services => |value| {
            try writer.writeAll("{\"Services\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .theme_packs => |value| {
            try writer.writeAll("{\"ThemePacks\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .theme_job => |value| {
            try writer.writeAll("{\"ThemeJob\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .sounds => |value| {
            try writer.writeAll("{\"Sounds\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .wallpaper => |value| {
            try writer.writeAll("{\"Wallpaper\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .theme => |value| {
            try writer.writeAll("{\"Theme\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .processes => |value| {
            try writer.writeAll("{\"Processes\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .service_mode => |value| {
            try writer.writeAll("{\"ServiceMode\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .sound_playback => |value| {
            try writer.writeAll("{\"SoundPlayback\":");
            try writer.print("{f}", .{std.json.fmt(value, .{})});
            try writer.writeByte('}');
        },
        .night_light => |nl| {
            try writer.writeAll("{\"NightLight\":");
            try writer.print("{f}", .{std.json.fmt(nl, .{})});
            try writer.writeByte('}');
        },
        .notifications => |n| {
            try writer.writeAll("{\"Notifications\":");
            try stringifyNotifications(n, writer);
            try writer.writeByte('}');
        },
        .handled => {
            try writer.writeAll("\"Handled\"");
        },
        .async_pending => {
            try writer.writeAll("\"Handled\"");
        },
        .list_panels => |lp| {
            try writer.print("{{\"ListPanels\":{f}}}", .{std.json.fmt(lp, .{})});
        },
        .click_widget => |cw| {
            try writer.print("{{\"ClickWidget\":{f}}}", .{std.json.fmt(cw, .{})});
        },
        .hover_widget => |hw| {
            try writer.print("{{\"HoverWidget\":{f}}}", .{std.json.fmt(hw, .{})});
        },
    }
}

pub fn stringifySinkInput(si: SinkInputData, writer: anytype) !void {
    try writer.print("{{\"index\":{d},\"name\":{f},\"app_id\":{f},\"pid\":{d},\"volume\":{d},\"muted\":", .{
        si.index, std.json.fmt(si.name, .{}), std.json.fmt(si.app_id, .{}), si.pid, si.volume,
    });
    try writer.writeAll(if (si.muted) "true}" else "false}");
}

pub fn stringifyAnimations(items: []const AnimationData, writer: anytype) !void {
    try writer.writeByte('[');
    for (items, 0..) |a, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"site\":{f},\"value\":{d},\"velocity\":{d},\"target\":{d},\"settled\":{},\"curve\":{f}}}", .{
            std.json.fmt(a.site, .{}),
            a.value,
            a.velocity,
            a.target,
            a.settled,
            std.json.fmt(a.curve, .{}),
        });
    }
    try writer.writeByte(']');
}

pub fn stringifyAudioState(a: AudioStateData, writer: anytype) !void {
    try writer.print("{{\"master_volume\":{d},\"master_muted\":", .{a.master_volume});
    try writer.writeAll(if (a.master_muted) "true" else "false");
    try writer.print(",\"default_sink\":{f},\"streams\":[", .{std.json.fmt(a.default_sink, .{})});
    for (a.streams, 0..) |si, i| {
        if (i > 0) try writer.writeByte(',');
        try stringifySinkInput(si, writer);
    }
    try writer.writeAll("]}");
}

pub fn stringifyScreenshotResult(sr: ScreenshotResult, writer: anytype) !void {
    try writer.print("{{\"width\":{d},\"height\":{d},\"format\":{f},\"data\":", .{ sr.width, sr.height, std.json.fmt(sr.format, .{}) });
    if (sr.data) |d| {
        try writer.print("{f}", .{std.json.fmt(d, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"path\":");
    if (sr.path) |p| {
        try writer.print("{f}", .{std.json.fmt(p, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"output_name\":{f},\"capture_mode\":{f},\"frame_seq\":{d}", .{
        std.json.fmt(sr.output_name, .{}),
        std.json.fmt(sr.capture_mode, .{}),
        sr.frame_seq,
    });
    if (sr.crop_applied) |cr| {
        try writer.print(",\"crop_applied\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ cr.x, cr.y, cr.width, cr.height });
    }
    try writer.writeByte('}');
}

pub fn stringifyPanelState(ps: PanelStateData, writer: anytype) !void {
    try writer.print("{{\"state\":{f},\"progress\":{d},\"is_settled\":{},\"box\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{
        std.json.fmt(ps.state, .{}), ps.progress, ps.is_settled, ps.box.x, ps.box.y, ps.box.width, ps.box.height,
    });
    try writer.writeAll(",\"search_text\":");
    if (ps.search_text) |st| try writer.print("{f}", .{std.json.fmt(st, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"category\":");
    if (ps.category) |c| try writer.print("{f}", .{std.json.fmt(c, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"selected_index\":");
    if (ps.selected_index) |idx| try writer.print("{d}", .{idx}) else try writer.writeAll("null");
    try writer.writeAll(",\"result_count\":");
    if (ps.result_count) |cnt| try writer.print("{d}", .{cnt}) else try writer.writeAll("null");
    try writer.writeByte('}');
}

pub fn stringifyShellState(res: ShellStateData, writer: anytype) !void {
    try writer.writeAll("{\"start_menu\":");
    if (res.start_menu) |sm| try stringifyPanelState(sm, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"control_center\":");
    if (res.control_center) |cc| try stringifyPanelState(cc, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"power_menu\":");
    if (res.power_menu) |pm| try stringifyPanelState(pm, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"polkit_dialog\":");
    if (res.polkit_dialog) |dialog| try stringifyPanelState(dialog, writer) else try writer.writeAll("null");
    try writer.print(",\"taskbar_count\":{d}}}", .{res.taskbar_count});
}

pub fn stringifyGetState(res: GetStateResult, writer: anytype) !void {
    try writer.print("{{\"seq\":{d},\"session_id\":{f},\"focused_window_id\":", .{ res.seq, std.json.fmt(res.session_id, .{}) });
    if (res.focused_window_id) |id| try writer.print("{d}", .{id}) else try writer.writeAll("null");
    try writer.writeAll(",\"windows\":");
    try writer.print("{f}", .{std.json.fmt(res.windows, .{})});
    try writer.writeAll(",\"outputs\":");
    try stringifyOutputs(res.outputs, writer);
    try writer.print(",\"camera\":{{\"x\":{d},\"y\":{d},\"max_x\":{d},\"max_y\":{d},\"zoom_percent\":{d}}}", .{
        res.camera.x, res.camera.y, res.camera.max_x, res.camera.max_y, res.camera.zoom_percent,
    });
    try writer.writeAll(",\"shell\":");
    try stringifyShellState(res.shell, writer);
    try writer.writeAll(",\"workspaces\":");
    try stringifyWorkspaces(res.workspaces, writer);
    try writer.writeByte('}');
}

pub fn stringifyWindowDebug(res: WindowDebugResult, writer: anytype) !void {
    try writer.print("{{\"id\":{d},\"title\":", .{res.id});
    if (res.title) |t| try writer.print("{f}", .{std.json.fmt(t, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"app_id\":");
    if (res.app_id) |a| try writer.print("{f}", .{std.json.fmt(a, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"pid\":");
    if (res.pid) |p| try writer.print("{d}", .{p}) else try writer.writeAll("null");
    try writer.print(",\"client_box\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ res.client_box.x, res.client_box.y, res.client_box.width, res.client_box.height });
    try writer.print(",\"chrome_box\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ res.chrome_box.x, res.chrome_box.y, res.chrome_box.width, res.chrome_box.height });
    try writer.print(",\"titlebar_height\":{d},\"footer_height\":{d},\"frame_border\":{d},\"frame_radius\":{d}", .{ res.titlebar_height, res.footer_height, res.frame_border, res.frame_radius });
    try writer.print(",\"decoration_mode\":{f}", .{std.json.fmt(res.decoration_mode, .{})});
    try writer.print(",\"minimized\":{},\"maximized\":{},\"fullscreen\":{},\"is_resizing\":{},\"zoom_percent\":{d}", .{ res.minimized, res.maximized, res.fullscreen, res.is_resizing, res.zoom_percent });
    try writer.print(",\"effective_zoom\":{d},\"zoom_boosted\":{}", .{ res.effective_zoom, res.zoom_boosted });
    try writer.print(",\"source_box\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{ res.source_box.x, res.source_box.y, res.source_box.width, res.source_box.height });
    try writer.print(",\"buffer_width\":{d},\"buffer_height\":{d},\"buffer_scale\":{d},\"buffer_transform\":{f}", .{ res.buffer_width, res.buffer_height, res.buffer_scale, std.json.fmt(res.buffer_transform, .{}) });
    try writer.print(",\"configure_serial\":{d},\"ack_serial\":{d},\"outputs\":[", .{ res.configure_serial, res.ack_serial });
    for (res.outputs, 0..) |out_name, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{f}", .{std.json.fmt(out_name, .{})});
    }
    try writer.writeAll("],\"skirt_fill\":");
    if (res.skirt_fill) |fill| {
        try writer.print("[{d},{d},{d},{d}]", .{ fill[0], fill[1], fill[2], fill[3] });
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"edge_sample\":{f}", .{std.json.fmt(res.edge_sample, .{})});
    try writer.writeByte('}');
}

pub fn stringifyOpenRules(open: OpenRulesData, writer: anytype) !void {
    try writer.writeAll("{\"output\":");
    if (open.output) |o| try writer.print("{f}", .{std.json.fmt(o, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"x\":");
    if (open.x) |x| try writer.print("{d}", .{x}) else try writer.writeAll("null");
    try writer.writeAll(",\"y\":");
    if (open.y) |y| try writer.print("{d}", .{y}) else try writer.writeAll("null");
    try writer.writeAll(",\"center\":");
    if (open.center) |c| try writer.print("{}", .{c}) else try writer.writeAll("null");
    try writer.writeAll(",\"width\":");
    if (open.width) |w| try writer.print("{d}", .{w}) else try writer.writeAll("null");
    try writer.writeAll(",\"height\":");
    if (open.height) |h| try writer.print("{d}", .{h}) else try writer.writeAll("null");
    try writer.writeAll(",\"maximized\":");
    if (open.maximized) |m| try writer.print("{}", .{m}) else try writer.writeAll("null");
    try writer.writeAll(",\"fullscreen\":");
    if (open.fullscreen) |f| try writer.print("{}", .{f}) else try writer.writeAll("null");
    try writer.writeAll(",\"focus\":");
    if (open.focus) |fc| try writer.print("{}", .{fc}) else try writer.writeAll("null");
    try writer.writeAll(",\"depth\":");
    if (open.depth) |d| try writer.print("{d}", .{d}) else try writer.writeAll("null");
    try writer.writeByte('}');
}

pub fn stringifyLiveRules(live: LiveRulesData, writer: anytype) !void {
    try writer.writeAll("{\"opacity\":");
    if (live.opacity) |op| try writer.print("{d}", .{op}) else try writer.writeAll("null");
    try writer.writeAll(",\"effective_opacity\":");
    if (live.effective_opacity) |eo| try writer.print("{d}", .{eo}) else try writer.writeAll("null");
    try writer.writeAll(",\"decorations\":");
    if (live.decorations) |d| try writer.print("{f}", .{std.json.fmt(d, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"floating\":");
    if (live.floating) |value| try writer.print("{}", .{value}) else try writer.writeAll("null");
    try writer.writeAll(",\"skip_taskbar\":");
    if (live.skip_taskbar) |st| try writer.print("{}", .{st}) else try writer.writeAll("null");
    try writer.writeByte('}');
}

pub fn stringifyWindowRules(res: GetWindowRulesResult, writer: anytype) !void {
    try writer.print("{{\"window_id\":{d},\"matched_rules\":[", .{res.window_id});
    for (res.matched_rules, 0..) |rule_idx, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{d}", .{rule_idx});
    }
    try writer.writeAll("],\"open\":");
    try stringifyOpenRules(res.open, writer);
    try writer.writeAll(",\"live\":");
    try stringifyLiveRules(res.live, writer);
    try writer.print(",\"resolved_before_app_id\":{}}}", .{res.resolved_before_app_id});
}

pub fn stringifyMatchWindowRules(res: MatchWindowRulesResult, writer: anytype) !void {
    try writer.writeAll("{\"matched_rules\":[");
    for (res.matched_rules, 0..) |rule_idx, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{d}", .{rule_idx});
    }
    try writer.writeAll("],\"open\":");
    try stringifyOpenRules(res.open, writer);
    try writer.writeAll(",\"live\":");
    try stringifyLiveRules(res.live, writer);
    try writer.writeByte('}');
}

pub fn stringifyShellDetail(res: ShellDetailResult, writer: anytype) !void {
    try writer.writeAll("{\"start_menu\":");
    if (res.start_menu) |sm| try stringifyPanelState(sm, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"control_center\":");
    if (res.control_center) |cc| try stringifyPanelState(cc, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"power_menu\":");
    if (res.power_menu) |pm| try stringifyPanelState(pm, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"polkit_dialog\":");
    if (res.polkit_dialog) |dialog| try stringifyPanelState(dialog, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"taskbars\":[");
    for (res.taskbars, 0..) |tb, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"output\":{f},\"box\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}},\"start_button_box\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}},\"chips\":[", .{
            std.json.fmt(tb.output, .{}), tb.box.x, tb.box.y, tb.box.width, tb.box.height, tb.start_button_box.x, tb.start_button_box.y, tb.start_button_box.width, tb.start_button_box.height,
        });
        for (tb.chips, 0..) |chip, ci| {
            if (ci > 0) try writer.writeByte(',');
            try writer.print("{{\"window_id\":{d},\"title\":{f},\"box\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}},\"is_active\":{},\"is_urgent\":{}}}", .{
                chip.window_id, std.json.fmt(chip.title, .{}), chip.box.x, chip.box.y, chip.box.width, chip.box.height, chip.is_active, chip.is_urgent,
            });
        }
        try writer.print("],\"right_items\":{f},\"app_tray\":{f},\"tray_menu\":{f}}}", .{ std.json.fmt(tb.right_items, .{}), std.json.fmt(tb.app_tray, .{}), std.json.fmt(tb.tray_menu, .{}) });
    }
    try writer.writeAll("]}");
}

pub fn stringifyDumpBuffer(res: DumpBufferResult, writer: anytype) !void {
    try writer.print("{{\"target\":{f},\"width\":{d},\"height\":{d},\"stride\":{d},\"format\":{f},\"scale\":{d},\"premultiplied\":{},\"data\":", .{
        std.json.fmt(res.target, .{}), res.width, res.height, res.stride, std.json.fmt(res.format, .{}), res.scale, res.premultiplied,
    });
    if (res.data) |d| try writer.print("{f}", .{std.json.fmt(d, .{})}) else try writer.writeAll("null");
    try writer.writeByte('}');
}

// Split across two `print` calls: a single call tops out at 32 format
// arguments (see std.Io.Writer), and this response has grown past that.
pub fn stringifyPerformanceStats(res: PerformanceStatsResult, writer: anytype) !void {
    try writer.writeAll("{");
    if (res.screenshot_selection) |selection| {
        try writer.print("\"screenshot_selection\":{f},", .{std.json.fmt(selection, .{})});
    }
    if (res.frame_work) |work| {
        try writer.print("\"frame_work\":{f},", .{std.json.fmt(work, .{})});
    }
    if (res.desktop) |desktop| {
        try writer.print("\"desktop\":{f},", .{std.json.fmt(desktop, .{})});
    }
    if (res.output_skipped_commits) |skipped| {
        try writer.print("\"output_skipped_commits\":{d},", .{skipped});
    }
    if (res.glass_reblurs) |reblurs| {
        try writer.print("\"glass_reblurs\":{d},", .{reblurs});
    }
    try writer.print("\"output_commits\":{d},\"output_failed_commits\":{d},\"fps\":{d:.1},\"frame_time_ms\":{d:.1},\"missed_frames\":{d},\"refresh_hz\":{d:.1},\"titlebar_paints\":{d},\"footer_paints\":{d},\"edge_samples_attempted\":{d},\"edge_samples_succeeded\":{d},\"edge_samples_skipped\":{d},\"edge_sample_ns\":{d},\"panel_paints\":{d},\"panel_allocated_bytes\":{d},\"panel_reused_bytes\":{d},\"icon_cache_hits\":{d},\"icon_cache_misses\":{d},\"icon_decode_ns\":{d},\"icon_decode_count\":{d},\"icon_decoded_bytes\":{d},\"icon_queue_depth_max\":{d},", .{
        res.output_commits,
        res.output_failed_commits,
        res.fps,
        res.frame_time_ms,
        res.missed_frames,
        res.refresh_hz,
        res.titlebar_paints,
        res.footer_paints,
        res.edge_samples_attempted,
        res.edge_samples_succeeded,
        res.edge_samples_skipped,
        res.edge_sample_ns,
        res.panel_paints,
        res.panel_allocated_bytes,
        res.panel_reused_bytes,
        res.icon_cache_hits,
        res.icon_cache_misses,
        res.icon_decode_ns,
        res.icon_decode_count,
        res.icon_decoded_bytes,
        res.icon_queue_depth_max,
    });
    try writer.print("\"taskbar_paints\":{d},\"taskbar_paint_ns\":{d},\"taskbar_raster_pixels\":{d},\"taskbar_clock_frame_requests\":{d},\"taskbar_clock_paints\":{d},\"taskbar_start_paints\":{d},\"taskbar_chip_paints\":{d},\"taskbar_tray_paints\":{d},\"taskbar_hover_paints\":{d},\"taskbar_press_paints\":{d},\"taskbar_audio_paints\":{d},\"recent_errors_count\":{d},\"anim_frames_scheduled\":{d},\"anim_wasted_wakeups\":{d},\"anim_longest_ms\":{d},\"anim_speed\":{d},\"anim_enabled\":{},\"anim_reduced_motion\":{}", .{
        res.taskbar_paints,
        res.taskbar_paint_ns,
        res.taskbar_raster_pixels,
        res.taskbar_clock_frame_requests,
        res.taskbar_clock_paints,
        res.taskbar_start_paints,
        res.taskbar_chip_paints,
        res.taskbar_tray_paints,
        res.taskbar_hover_paints,
        res.taskbar_press_paints,
        res.taskbar_audio_paints,
        res.recent_errors_count,
        res.anim_frames_scheduled,
        res.anim_wasted_wakeups,
        res.anim_longest_ms,
        res.anim_speed,
        res.anim_enabled,
        res.anim_reduced_motion,
    });
    if (res.startup) |st| {
        try writer.writeAll(",\"startup\":");
        try stringifyStartup(st, writer);
    }
    try writer.writeByte('}');
}

pub fn stringifyStartup(st: StartupStats, writer: anytype) !void {
    try writer.print("{{\"build_mode\":{f},\"renderer\":{f},\"scale\":{d:.2},\"output_count\":{d},\"catalog_entries\":{d},\"autostart_count\":{d},\"catalog_state\":{f},\"wallpaper_state\":{f},\"catalog_provisional\":{},\"catalog_loading\":{},\"catalog_generation\":{d},", .{
        std.json.fmt(st.build_mode, .{}),
        std.json.fmt(st.renderer, .{}),
        st.scale,
        st.output_count,
        st.catalog_entries,
        st.autostart_count,
        std.json.fmt(st.catalog_state, .{}),
        std.json.fmt(st.wallpaper_state, .{}),
        st.catalog_provisional,
        st.catalog_loading,
        st.catalog_generation,
    });
    try writer.print("\"renderer_ready_ns\":{d},\"config_ready_ns\":{d},\"catalog_cache_read_ns\":{d},\"catalog_scan_ns\":{d},\"wallpaper_decode_ns\":{d},\"socket_ready_ns\":{d},\"ipc_ready_ns\":{d},\"session_ready_ns\":{d},\"session_clients_started_ns\":{d},\"xwayland_ready_ns\":{d},\"first_presented_ns\":{d},\"first_ipc_ns\":{d},\"first_input_ns\":{d},\"catalog_published_ns\":{d},\"wallpaper_presented_ns\":{d},\"catalog_cache_read_duration_ns\":{d},\"catalog_scan_duration_ns\":{d},\"wallpaper_decode_duration_ns\":{d},\"backend_start_ns\":{d},\"backend_ready_ns\":{d},\"input_ready_ns\":{d},\"first_visible_ns\":{d},\"services_started_ns\":{d},\"login_to_compositor_ns\":{d},\"login_to_visible_ns\":{d},\"reveal_done_ns\":{d}}}", .{
        st.renderer_ready_ns,
        st.config_ready_ns,
        st.catalog_cache_read_ns,
        st.catalog_scan_ns,
        st.wallpaper_decode_ns,
        st.socket_ready_ns,
        st.ipc_ready_ns,
        st.session_ready_ns,
        st.session_clients_started_ns,
        st.xwayland_ready_ns,
        st.first_presented_ns,
        st.first_ipc_ns,
        st.first_input_ns,
        st.catalog_published_ns,
        st.wallpaper_presented_ns,
        st.catalog_cache_read_duration_ns,
        st.catalog_scan_duration_ns,
        st.wallpaper_decode_duration_ns,
        st.backend_start_ns,
        st.backend_ready_ns,
        st.input_ready_ns,
        st.first_visible_ns,
        st.services_started_ns,
        st.login_to_compositor_ns,
        st.login_to_visible_ns,
        st.reveal_done_ns,
    });
}

pub fn stringifyNotifications(n: GetNotificationsResult, writer: anytype) !void {
    try writer.writeAll("{\"toasts\":[");
    for (n.toasts, 0..) |toast, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d},\"app_name\":{f},\"summary\":{f},\"body\":{f},\"app_icon\":{f},\"urgency\":{d},\"resident\":{},\"transient\":{},\"expire_at_ms\":", .{
            toast.id,
            std.json.fmt(toast.app_name, .{}),
            std.json.fmt(toast.summary, .{}),
            std.json.fmt(toast.body, .{}),
            std.json.fmt(toast.app_icon, .{}),
            toast.urgency,
            toast.resident,
            toast.transient,
        });
        if (toast.expire_at_ms) |exp| {
            try writer.print("{d}", .{exp});
        } else {
            try writer.writeAll("null");
        }
        try writer.print(",\"paused\":{},\"closing\":{}}}", .{ toast.paused, toast.closing });
    }
    try writer.writeAll("],\"history\":[");
    for (n.history, 0..) |rec, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d},\"app_name\":{f},\"summary\":{f},\"body\":{f},\"app_icon\":{f},\"urgency\":{d},\"time_ms\":{d},\"closed\":{},\"close_reason\":", .{
            rec.id,
            std.json.fmt(rec.app_name, .{}),
            std.json.fmt(rec.summary, .{}),
            std.json.fmt(rec.body, .{}),
            std.json.fmt(rec.app_icon, .{}),
            rec.urgency,
            rec.time_ms,
            rec.closed,
        });
        if (rec.close_reason) |cr| {
            try writer.print("{d}", .{cr});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
    }
    try writer.print("],\"dnd\":{}}}", .{n.dnd});
}

pub fn stringifyEvent(event: Event, writer: anytype) !void {
    switch (event) {
        inline .window_urgency_changed, .keyboard_layouts_changed, .keyboard_layout_switched, .input_source_changed, .config_loaded => |ev, tag| {
            const name = comptime switch (tag) {
                .window_urgency_changed => "WindowUrgencyChanged",
                .keyboard_layouts_changed => "KeyboardLayoutsChanged",
                .keyboard_layout_switched => "KeyboardLayoutSwitched",
                .input_source_changed => "InputSourceChanged",
                .config_loaded => "ConfigLoaded",
                else => unreachable,
            };
            try writer.print("{{\"{s}\":{f}}}\n", .{ name, std.json.fmt(ev, .{}) });
        },
        .polkit_prompt_opened, .polkit_prompt_closed => |ev| {
            const name = if (event == .polkit_prompt_opened) "PolkitPromptOpened" else "PolkitPromptClosed";
            try writer.print("{{\"{s}\":{{\"seq\":{d},\"time_ms\":{d}}}}}\n", .{ name, ev.seq, ev.time_ms });
        },
        .state_snapshot => |snap| {
            try writer.print("{{\"StateSnapshot\":{{\"seq\":{d}", .{snap.seq});
            if (snap.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(snap.session_id, .{})});
            if (snap.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{snap.time_ms});
            try writer.writeAll(",\"windows\":");
            try writer.print("{f}", .{std.json.fmt(snap.windows, .{})});
            try writer.writeAll(",\"outputs\":");
            try stringifyOutputs(snap.outputs, writer);
            try writer.writeAll(",\"workspaces\":");
            try stringifyWorkspaces(snap.workspaces, writer);
            try writer.writeAll(",\"focused_window_id\":");
            if (snap.focused_window_id) |id| {
                try writer.print("{d}", .{id});
            } else {
                try writer.writeAll("null");
            }
            if (snap.camera) |cam| {
                try writer.print(",\"camera\":{{\"x\":{d},\"y\":{d},\"max_x\":{d},\"max_y\":{d},\"zoom_percent\":{d}}}", .{ cam.x, cam.y, cam.max_x, cam.max_y, cam.zoom_percent });
            }
            if (snap.shell) |sh| {
                try writer.writeAll(",\"shell\":");
                try stringifyShellState(sh, writer);
            }
            try writer.writeAll("}}\n");
        },
        .window_opened => |ev| {
            try writer.print("{{\"WindowOpened\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.writeAll(",\"window\":");
            try writer.print("{f}", .{std.json.fmt(ev.window, .{})});
            try writer.writeAll("}}\n");
        },
        .window_closed => |ev| {
            try writer.print("{{\"WindowClosed\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"id\":{d}}}}}\n", .{ev.id});
        },
        .window_changed => |ev| {
            try writer.print("{{\"WindowChanged\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.writeAll(",\"window\":");
            try writer.print("{f}", .{std.json.fmt(ev.window, .{})});
            try writer.writeAll("}}\n");
        },
        .window_focused => |ev| {
            try writer.print("{{\"WindowFocused\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.writeAll(",\"id\":");
            if (ev.id) |id| {
                try writer.print("{d}", .{id});
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll("}}\n");
        },
        .window_moved => |ev| {
            try writer.print("{{\"WindowMoved\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"id\":{d},\"x\":{d},\"y\":{d}}}}}\n", .{ ev.id, ev.x, ev.y });
        },
        .output_added => |ev| {
            try writer.print("{{\"OutputAdded\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.writeAll(",\"output\":");
            try stringifyOutput(ev.output, writer);
            try writer.writeAll("}}\n");
        },
        .output_changed => |ev| {
            try writer.print("{{\"OutputChanged\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.writeAll(",\"output\":");
            try stringifyOutput(ev.output, writer);
            try writer.writeAll("}}\n");
        },
        .output_removed => |ev| {
            try writer.print("{{\"OutputRemoved\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"name\":{f}}}}}\n", .{std.json.fmt(ev.name, .{})});
        },
        .camera_changed => |ev| {
            try writer.print("{{\"CameraChanged\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"x\":{d},\"y\":{d},\"max_x\":{d},\"max_y\":{d},\"zoom_percent\":{d}}}}}\n", .{
                ev.x, ev.y, ev.max_x, ev.max_y, ev.zoom_percent,
            });
        },
        .notification_shown => |ev| {
            try writer.print("{{\"NotificationShown\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"id\":{d},\"app_name\":{f},\"summary\":{f},\"urgency\":{d}}}}}\n", .{
                ev.id,
                std.json.fmt(ev.app_name, .{}),
                std.json.fmt(ev.summary, .{}),
                ev.urgency,
            });
        },
        .notification_closed => |ev| {
            try writer.print("{{\"NotificationClosed\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"id\":{d},\"reason\":{d}}}}}\n", .{ ev.id, ev.reason });
        },
        .notification_action => |ev| {
            try writer.print("{{\"NotificationAction\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"id\":{d},\"action_key\":{f}}}}}\n", .{ ev.id, std.json.fmt(ev.action_key, .{}) });
        },
        .launch_started => |ev| {
            try writer.print("{{\"LaunchStarted\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"desktop_id\":{f}", .{std.json.fmt(ev.desktop_id, .{})});
            if (ev.pid) |pid| try writer.print(",\"pid\":{d}", .{pid}) else try writer.writeAll(",\"pid\":null");
            if (ev.placeholder_id) |phid| try writer.print(",\"placeholder_id\":{d}", .{phid}) else try writer.writeAll(",\"placeholder_id\":null");
            try writer.writeAll("}}\n");
        },
        .launch_matched => |ev| {
            try writer.print("{{\"LaunchMatched\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"desktop_id\":{f},\"window_id\":{d}", .{ std.json.fmt(ev.desktop_id, .{}), ev.window_id });
            if (ev.pid) |pid| try writer.print(",\"pid\":{d}", .{pid}) else try writer.writeAll(",\"pid\":null");
            try writer.writeAll("}}\n");
        },
        .launch_timeout => |ev| {
            try writer.print("{{\"LaunchTimeout\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"desktop_id\":{f}", .{std.json.fmt(ev.desktop_id, .{})});
            if (ev.pid) |pid| try writer.print(",\"pid\":{d}", .{pid}) else try writer.writeAll(",\"pid\":null");
            try writer.writeAll("}}\n");
        },
        .widget_changed => |ev| {
            try writer.print("{{\"WidgetChanged\":{{\"seq\":{d}", .{ev.seq});
            if (ev.time_ms > 0) try writer.print(",\"time_ms\":{d}", .{ev.time_ms});
            if (ev.session_id.len > 0) try writer.print(",\"session_id\":{f}", .{std.json.fmt(ev.session_id, .{})});
            try writer.print(",\"panel\":{f}", .{std.json.fmt(ev.panel, .{})});
            if (ev.path) |p| try writer.print(",\"path\":{f}", .{std.json.fmt(p, .{})}) else try writer.writeAll(",\"path\":null");
            if (ev.name) |n| try writer.print(",\"name\":{f}", .{std.json.fmt(n, .{})}) else try writer.writeAll(",\"name\":null");
            try writer.writeAll(",\"widget\":");
            try writer.print("{f}", .{std.json.fmt(ev.widget, .{})});
            try writer.writeAll("}}\n");
        },
    }
}

// Keep f32 formatting here: std.json widens f32 before printing, changing
// decoded values (for example 1.23456 to 1.2345600128173828).
pub fn stringifyOutput(out: OutputData, writer: anytype) !void {
    try writer.writeAll("{\"name\":");
    try writer.print("{f}", .{std.json.fmt(out.name, .{})});
    try writer.writeAll(",\"make\":");
    if (out.make) |m| try writer.print("{f}", .{std.json.fmt(m, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"model\":");
    if (out.model) |m| try writer.print("{f}", .{std.json.fmt(m, .{})}) else try writer.writeAll("null");
    try writer.writeAll(",\"enabled\":");
    try writer.writeAll(if (out.enabled) "true" else "false");
    try writer.print(",\"x\":{d},\"y\":{d},\"logical_width\":{d},\"logical_height\":{d},\"buffer_width\":{d},\"buffer_height\":{d},\"transform\":", .{ out.x, out.y, out.logical_width, out.logical_height, out.buffer_width, out.buffer_height });
    try writer.print("{f}", .{std.json.fmt(out.transform, .{})});
    try writer.print(",\"bottom_exclusion\":{d}", .{out.bottom_exclusion});
    try writer.print(",\"scale\":{d},\"refresh_hz\":{d},\"is_focused\":", .{ out.scale, out.refresh_hz });
    try writer.writeAll(if (out.is_focused) "true" else "false");
    try writer.writeByte('}');
}

pub fn stringifyOutputs(outs: []const OutputData, writer: anytype) !void {
    try writer.writeByte('[');
    for (outs, 0..) |out, i| {
        if (i > 0) try writer.writeByte(',');
        try stringifyOutput(out, writer);
    }
    try writer.writeByte(']');
}

pub fn stringifyWorkspaces(ws: []const WorkspaceData, writer: anytype) !void {
    try writer.print("{f}", .{std.json.fmt(ws, .{})});
}
