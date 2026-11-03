//! Screenshots, frame waits, buffer dumps, pixel samples and performance stats.

const std = @import("std");
const wlr = @import("wlroots");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const protocol = @import("protocol.zig");
const stats = @import("stats.zig");
const Client = @import("server.zig").Client;
const handlers_data = @import("handlers_data.zig");
const startupStats = handlers_data.startupStats;
const findToplevelById = handlers_data.findToplevelById;
const findOutputByName = handlers_data.findOutputByName;
const handlers = @import("handlers.zig");
const handleAction = handlers.handleAction;
const packedArgb = handlers.packedArgb;
const DumpTarget = handlers.DumpTarget;

pub fn handleFrameAction(
    server: *Server,
    request_id: ?protocol.RequestId,
    action: protocol.Action,
    allocator: std.mem.Allocator,
    client: ?*Client,
) !protocol.Response {
    switch (action) {
        .screenshot => |p| {
            const sm = server.screenshot_mgr orelse return .{ .err = "Unsupported" };
            return sm.queueRequest(p, if (client) |c| c.id else null, request_id);
        },
        .stop_all_capture => {
            const cm = server.capture_mgr orelse return .{ .err = "Unsupported" };
            cm.stopAll();
            return .{ .ok = .handled };
        },
        // Phase 1 waits
        .wait_for => |p| {
            const c = client orelse return .{ .err = "ClientRequired" };
            const ipc = server.ipc orelse return .{ .err = "IpcNotRunning" };
            return ipc.wait_mgr.registerCondition(c.id, request_id, p.condition, p.timeout_ms);
        },
        .wait_for_frame => |p| {
            const c = client orelse return .{ .err = "ClientRequired" };
            const ipc = server.ipc orelse return .{ .err = "IpcNotRunning" };
            return ipc.wait_mgr.registerFrame(c.id, request_id, p.output, p.timeout_ms);
        },

        // Phase 3 captures/stats
        .dump_buffer => |p| {
            var target_buf: ?*wlr.Buffer = null;
            var scale: f32 = 1;

            const target = std.meta.stringToEnum(DumpTarget, p.target) orelse return .{ .err = "UnknownTarget" };
            switch (target) {
                .titlebar => {
                    const win_id = p.window_id orelse return .{ .err = "InvalidRequest: titlebar requires window_id" };
                    const toplevel = findToplevelById(server, win_id) orelse return .{ .err = "UnknownWindow" };
                    if (!toplevel.hasServerDecorations()) return .{ .err = "WindowHasNoServerDecorations" };
                    scale = toplevel.render_scale;
                    target_buf = toplevel.titlebar_buffer.getBuffer();
                },
                // Each tag names the Output field holding that panel.
                .control_center => {
                    const cc = server.input.open_control_center orelse return .{ .err = comptime DumpTarget.control_center.missingError() };
                    scale = cc.painted_scale;
                    target_buf = cc.buffer_node.getBuffer();
                },
                inline .taskbar, .start_menu, .power_menu => |tag| {
                    const out = if (p.output) |name| findOutputByName(server, name) else server.getDefaultOutput();
                    const target_out = out orelse return .{ .err = "NoOutput" };
                    scale = target_out.wlr_output.scale;
                    const panel = @field(target_out, @tagName(tag)) orelse return .{ .err = comptime tag.missingError() };
                    target_buf = panel.buffer_node.getBuffer();
                },
            }

            const buf = target_buf orelse return .{ .err = "BufferNotAttached" };
            var data_ptr: *anyopaque = undefined;
            var format: u32 = 0;
            // A panel presented through its texture (`presentOwned`) is a client
            // buffer with no CPU mapping on GLES2; its raster is packed ARGB8888.
            var stride: usize = @as(usize, @intCast(buf.width)) * @sizeOf(u32);
            if (buf.beginDataPtrAccess(0, &data_ptr, &format, &stride)) buf.endDataPtrAccess();

            return .{ .ok = .{ .dump_buffer = .{
                .target = p.target,
                .width = @intCast(buf.width),
                .height = @intCast(buf.height),
                .stride = @intCast(stride),
                .format = "argb8888",
                .scale = scale,
                .premultiplied = true,
                .data = null,
            } } };
        },
        .sample_pixels => |p| {
            const target_out: *Output = if (p.output) |name|
                findOutputByName(server, name) orelse return .{ .err = "UnknownOutput" }
            else
                server.getDefaultOutput() orelse return .{ .err = "NoOutput" };

            const scene_output = server.scene_outputs.get(target_out.wlr_output) orelse return .{ .err = "NoSceneOutput" };
            var state = wlr.Output.State.init();
            defer state.finish();
            if (!server.buildOutputState(scene_output, &state)) return .{ .err = "CaptureFailed: scene render failed" };
            const buffer = state.buffer orelse return .{ .err = "CaptureFailed: missing frame buffer" };
            const texture = wlr.Texture.fromBuffer(server.renderer, buffer) orelse return .{ .err = "CaptureFailed: texture creation failed" };
            defer texture.destroy();

            const format = texture.preferredReadFormat();
            const count = p.width * p.height;
            const pixels = try allocator.alloc(u32, count);
            const ok = texture.readPixels(&.{
                .data = @ptrCast(pixels.ptr),
                .format = format,
                .stride = @intCast(p.width * @sizeOf(u32)),
                .dst_x = 0,
                .dst_y = 0,
                .src_box = .{ .x = p.x, .y = p.y, .width = @intCast(p.width), .height = @intCast(p.height) },
            });
            if (!ok) return .{ .err = "ReadPixelsFailed" };
            // The reply is packed 0xAARRGGBB whatever the renderer prefers to read
            // (GLES2 reads ABGR8888, bytes R, G, B, A).
            for (pixels) |*pixel| pixel.* = packedArgb(format, pixel.*) orelse return .{ .err = "ReadPixelsFailed: unsupported read format" };

            return .{ .ok = .{ .sample_pixels = .{
                .output = std.mem.span(target_out.wlr_output.name),
                .x = p.x,
                .y = p.y,
                .width = p.width,
                .height = p.height,
                .pixels = pixels,
                .gpu_readback = true,
            } } };
        },
        .get_performance_stats => {
            server.ensureGpuTimer();
            if (server.gpu_timer) |timer| timer.collect(&server.gpu_recent);
            const panel_s = @import("../panel_present.zig").snapshot();
            const timing = stats.global_stats.timing();
            return .{ .ok = .{ .performance_stats = .{
                .frame_work = stats.global_stats.frameWork(server.gpu_timer != null),
                .screenshot_selection = stats.global_stats.screenshot_selection,
                .output_commits = stats.global_stats.output_commits,
                .output_failed_commits = stats.global_stats.output_failed_commits,
                .fps = timing.fps,
                .frame_time_ms = timing.frame_time_ms,
                .missed_frames = timing.missed_frames,
                .refresh_hz = timing.refresh_hz,
                .titlebar_paints = stats.global_stats.titlebar_paints,
                .footer_paints = stats.global_stats.footer_paints,
                .edge_samples_attempted = stats.global_stats.edge_samples_attempted,
                .edge_samples_succeeded = stats.global_stats.edge_samples_succeeded,
                .edge_samples_skipped = stats.global_stats.edge_samples_skipped,
                .edge_sample_ns = stats.global_stats.edge_sample_ns,
                .panel_paints = panel_s.paints,
                .panel_allocated_bytes = panel_s.allocated_bytes,
                .panel_reused_bytes = panel_s.reused_bytes,
                .icon_cache_hits = stats.global_stats.icon_cache_hits,
                .icon_cache_misses = stats.global_stats.icon_cache_misses,
                .icon_decode_ns = stats.global_stats.icon_decode_ns,
                .icon_decode_count = stats.global_stats.icon_decode_count,
                .icon_decoded_bytes = stats.global_stats.icon_decoded_bytes,
                .icon_queue_depth_max = stats.global_stats.icon_queue_depth_max,
                .taskbar_paints = stats.global_stats.taskbar_paints,
                .taskbar_paint_ns = stats.global_stats.taskbar_paint_ns,
                .taskbar_raster_pixels = stats.global_stats.taskbar_raster_pixels,
                .taskbar_clock_frame_requests = stats.global_stats.taskbar_clock_frame_requests,
                .taskbar_clock_paints = stats.global_stats.taskbar_clock_paints,
                .taskbar_start_paints = stats.global_stats.taskbar_start_paints,
                .taskbar_chip_paints = stats.global_stats.taskbar_chip_paints,
                .taskbar_tray_paints = stats.global_stats.taskbar_tray_paints,
                .taskbar_hover_paints = stats.global_stats.taskbar_hover_paints,
                .taskbar_press_paints = stats.global_stats.taskbar_press_paints,
                .taskbar_audio_paints = stats.global_stats.taskbar_audio_paints,
                .recent_errors_count = stats.global_stats.errors_count,
                .anim_frames_scheduled = stats.global_stats.anim_frames_scheduled,
                .anim_wasted_wakeups = stats.global_stats.anim_wasted_wakeups,
                .anim_longest_ms = stats.global_stats.anim_longest_ms,
                .anim_speed = @import("ui").anim.speed(),
                .anim_enabled = @import("ui").anim.enabled(),
                .anim_reduced_motion = @import("ui").anim.reducedMotion(),
                .startup = startupStats(),
                .desktop = stats.global_stats.desktop,
                .output_skipped_commits = stats.global_stats.output_skipped_commits,
                .glass_reblurs = @import("../scene_output.zig").reblurs.*,
            } } };
        },
        .reset_performance_stats => {
            server.ensureGpuTimer();
            stats.global_stats.reset();
            @import("../panel_present.zig").reset();
            @import("../scene_output.zig").reblurs.* = 0;
            return .{ .ok = .handled };
        },

        else => unreachable,
    }
}
