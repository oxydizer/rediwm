const std = @import("std");
const protocol = @import("ipc/protocol.zig");

test "parse standard queries" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(protocol.Request.version, try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"version\"}"));
    try std.testing.expectEqual(protocol.Request.capabilities, try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"capabilities\"}"));
    try std.testing.expectEqual(protocol.Request.windows, try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"windows\"}"));
    try std.testing.expectEqual(protocol.Request.outputs, try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"outputs\"}"));
    try std.testing.expectEqual(protocol.Request.focused_window, try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"focused_window\"}"));
    try std.testing.expectEqual(protocol.Request.event_stream, try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"event_stream\"}"));
    try std.testing.expectEqual(protocol.Request.workspaces, try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"workspaces\"}"));
}

test "parse actions" {
    const allocator = std.testing.allocator;

    const req1 = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"focus_window\",\"params\":{\"id\":42}}");
    switch (req1) {
        .action => |act| switch (act) {
            .focus_window => |p| try std.testing.expectEqual(@as(u64, 42), p.id),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const req2 = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"close_window\",\"params\":{\"id\":null}}");
    switch (req2) {
        .action => |act| switch (act) {
            .close_window => |p| try std.testing.expectEqual(@as(?u64, null), p.id),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const req3 = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"close_window\"}");
    switch (req3) {
        .action => |act| switch (act) {
            .close_window => |p| try std.testing.expectEqual(@as(?u64, null), p.id),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const req4 = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"move_window_to\",\"params\":{\"id\":7,\"x\":120,\"y\":340}}");
    switch (req4) {
        .action => |act| switch (act) {
            .move_window_to => |p| {
                try std.testing.expectEqual(@as(u64, 7), p.id);
                try std.testing.expectEqual(@as(i32, 120), p.x);
                try std.testing.expectEqual(@as(i32, 340), p.y);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const req5 = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"spawn\",\"params\":{\"argv\":[\"foot\",\"-e\",\"htop\"]}}");
    switch (req5) {
        .action => |act| switch (act) {
            .spawn => |p| {
                try std.testing.expectEqual(@as(usize, 3), p.argv.len);
                try std.testing.expectEqualSlices(u8, "foot", p.argv[0]);
                try std.testing.expectEqualSlices(u8, "-e", p.argv[1]);
                try std.testing.expectEqualSlices(u8, "htop", p.argv[2]);
                for (p.argv) |s| allocator.free(s);
                allocator.free(p.argv);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }
}

test "parse output transform configuration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const request = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_output_config\",\"params\":{\"output\":\"DP-1\",\"transform\":\"90\"}}");
    switch (request) {
        .action => |action| switch (action) {
            .set_output_config => |patch| try std.testing.expectEqual(@as(protocol.OutputConfigPatch, .{ .output = patch.output, .transform = .@"90" }), patch),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }
    try std.testing.expectError(error.InvalidRequest, protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_output_config\",\"params\":{\"output\":\"DP-1\",\"transform\":\"sideways\"}}"));
}

test "stringify response" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const resp = protocol.Response{ .ok = .{ .version = "0.1.0" } };
    try protocol.stringifyResponse(resp, bw);
    try std.testing.expectEqualSlices(u8, "{\"Ok\":{\"Version\":\"0.1.0\"}}\n", list.items);
}

test "stringify event" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const ev = protocol.Event{ .window_closed = .{ .seq = 3, .id = 42 } };
    try protocol.stringifyEvent(ev, bw);
    try std.testing.expectEqualSlices(u8, "{\"WindowClosed\":{\"seq\":3,\"id\":42}}\n", list.items);
}

test "parse virtual input actions" {
    const allocator = std.testing.allocator;

    const r_mc = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"move_cursor\",\"params\":{\"x\":100,\"y\":200,\"output\":\"HDMI-A-1\"}}");
    switch (r_mc) {
        .action => |act| switch (act) {
            .move_cursor => |p| {
                try std.testing.expectEqual(@as(i32, 100), p.x);
                try std.testing.expectEqual(@as(i32, 200), p.y);
                try std.testing.expectEqualSlices(u8, "HDMI-A-1", p.output.?);
                allocator.free(p.output.?);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_mcr = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"move_cursor_relative\",\"params\":{\"dx\":15,\"dy\":-5}}");
    switch (r_mcr) {
        .action => |act| switch (act) {
            .move_cursor_relative => |p| {
                try std.testing.expectEqual(@as(i32, 15), p.dx);
                try std.testing.expectEqual(@as(i32, -5), p.dy);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_pb = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"pointer_button\",\"params\":{\"button\":272,\"pressed\":true}}");
    switch (r_pb) {
        .action => |act| switch (act) {
            .pointer_button => |p| {
                try std.testing.expectEqual(@as(u32, 272), p.button);
                try std.testing.expectEqual(true, p.pressed);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_clk1 = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"click\",\"params\":{\"button\":273}}");
    switch (r_clk1) {
        .action => |act| switch (act) {
            .click => |p| try std.testing.expectEqual(@as(u32, 273), p.button),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_clk2 = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"click\"}");
    switch (r_clk2) {
        .action => |act| switch (act) {
            .click => |p| try std.testing.expectEqual(@as(u32, 0x110), p.button),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_sc = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"scroll\",\"params\":{\"dx\":0.0,\"dy\":15.5}}");
    switch (r_sc) {
        .action => |act| switch (act) {
            .scroll => |p| {
                try std.testing.expectEqual(@as(f64, 0.0), p.dx);
                try std.testing.expectEqual(@as(f64, 15.5), p.dy);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_k = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"key\",\"params\":{\"keycode\":28,\"pressed\":false}}");
    switch (r_k) {
        .action => |act| switch (act) {
            .key => |p| {
                try std.testing.expectEqual(@as(u32, 28), p.keycode);
                try std.testing.expectEqual(false, p.pressed);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_kp = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"key_press\",\"params\":{\"key\":\"Return\"}}");
    switch (r_kp) {
        .action => |act| switch (act) {
            .key_press => |p| {
                try std.testing.expectEqualSlices(u8, "Return", p.key);
                allocator.free(p.key);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_tt = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"type_text\",\"params\":{\"text\":\"echo hello\"}}");
    switch (r_tt) {
        .action => |act| switch (act) {
            .type_text => |p| {
                try std.testing.expectEqualSlices(u8, "echo hello", p.text);
                allocator.free(p.text);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_dg = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"drag\",\"params\":{\"from_x\":10,\"from_y\":20,\"to_x\":100,\"to_y\":200,\"button\":272}}");
    switch (r_dg) {
        .action => |act| switch (act) {
            .drag => |p| {
                try std.testing.expectEqual(@as(i32, 10), p.from_x);
                try std.testing.expectEqual(@as(i32, 20), p.from_y);
                try std.testing.expectEqual(@as(i32, 100), p.to_x);
                try std.testing.expectEqual(@as(i32, 200), p.to_y);
                try std.testing.expectEqual(@as(u32, 272), p.button);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }
}

test "parse screenshot action" {
    const allocator = std.testing.allocator;

    const r_sc1 = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"screenshot\"}");
    switch (r_sc1) {
        .action => |act| switch (act) {
            .screenshot => |p| {
                try std.testing.expectEqual(@as(?[]const u8, null), p.output);
                try std.testing.expectEqual(@as(?u64, null), p.window_id);
                try std.testing.expectEqual(false, p.include_cursor);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_sc2 = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"screenshot\",\"params\":{\"output\":\"WL-1\",\"window_id\":12,\"mode\":\"visible-region\",\"include_cursor\":true,\"path\":\"/tmp/shot.png\"}}");
    switch (r_sc2) {
        .action => |act| switch (act) {
            .screenshot => |p| {
                try std.testing.expectEqualSlices(u8, "WL-1", p.output.?);
                try std.testing.expectEqual(@as(?u64, 12), p.window_id);
                try std.testing.expectEqualSlices(u8, "visible-region", p.mode.?);
                try std.testing.expectEqual(true, p.include_cursor);
                try std.testing.expectEqualSlices(u8, "/tmp/shot.png", p.path.?);
                allocator.free(p.output.?);
                allocator.free(p.mode.?);
                allocator.free(p.path.?);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }
}

test "stringify screenshot response" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const sr = protocol.ScreenshotResult{
        .width = 1920,
        .height = 1080,
        .format = "png",
        .data = "SGVsbG8=",
        .path = null,
        .output_name = "WL-1",
        .capture_mode = "output",
        .frame_seq = 42,
    };
    const resp = protocol.Response{ .ok = .{ .screenshot = sr } };
    try protocol.stringifyResponse(resp, bw);

    const expected = "{\"Ok\":{\"Screenshot\":{\"width\":1920,\"height\":1080,\"format\":\"png\",\"data\":\"SGVsbG8=\",\"path\":null,\"output_name\":\"WL-1\",\"capture_mode\":\"output\",\"frame_seq\":42}}}\n";
    try std.testing.expectEqualSlices(u8, expected, list.items);
}

test "encode png and base64" {
    const allocator = std.testing.allocator;
    const encode = @import("screenshot/encode.zig");

    var pixels: [16]u32 = undefined;
    for (&pixels) |*p| p.* = 0xFF00FF00; // Opaque green premultiplied ARGB8888

    const png_bytes = try encode.encodePng(allocator, 4, 4, &pixels, 4);
    defer allocator.free(png_bytes);

    // Verify PNG header signature
    const sig = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    try std.testing.expect(png_bytes.len > sig.len);
    try std.testing.expectEqualSlices(u8, &sig, png_bytes[0..sig.len]);

    const b64 = try encode.encodeBase64(allocator, png_bytes);
    defer allocator.free(b64);
    try std.testing.expect(b64.len > 0);
}

test "parse camera actions" {
    const allocator = std.testing.allocator;

    const r_get = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"get_camera\"}");
    switch (r_get) {
        .action => |act| try std.testing.expectEqual(protocol.Action.get_camera, act),
        else => return error.TestFailed,
    }

    const r_reset = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"reset_camera\"}");
    switch (r_reset) {
        .action => |act| try std.testing.expectEqual(protocol.Action.reset_camera, act),
        else => return error.TestFailed,
    }

    const r_set = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_camera\",\"params\":{\"x\":250,\"y\":-150}}");
    switch (r_set) {
        .action => |act| switch (act) {
            .set_camera => |p| {
                try std.testing.expectEqual(@as(i32, 250), p.x);
                try std.testing.expectEqual(@as(i32, -150), p.y);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }
}

test "stringify camera response and event" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };

    const resp = protocol.Response{ .ok = .{ .camera = .{ .x = 100, .y = -50, .max_x = 1920, .max_y = 1080 } } };
    try protocol.stringifyResponse(resp, bw);
    try std.testing.expectEqualSlices(u8, "{\"Ok\":{\"Camera\":{\"x\":100,\"y\":-50,\"max_x\":1920,\"max_y\":1080,\"zoom_percent\":100}}}\n", list.items);

    list.clearRetainingCapacity();
    const ev = protocol.Event{ .camera_changed = .{ .seq = 7, .x = 200, .y = 100, .max_x = 1920, .max_y = 1080 } };
    try protocol.stringifyEvent(ev, bw);
    try std.testing.expectEqualSlices(u8, "{\"CameraChanged\":{\"seq\":7,\"x\":200,\"y\":100,\"max_x\":1920,\"max_y\":1080,\"zoom_percent\":100}}\n", list.items);
}

test "parse audio actions" {
    const allocator = std.testing.allocator;

    const r_vol = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_master_volume\",\"params\":{\"volume\":0.5}}");
    switch (r_vol) {
        .action => |act| switch (act) {
            .set_master_volume => |p| try std.testing.expectApproxEqAbs(@as(f32, 0.5), p.volume, 1e-6),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    // Integer JSON values must also be accepted for a float field.
    const r_vol_int = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_master_volume\",\"params\":{\"volume\":1}}");
    switch (r_vol_int) {
        .action => |act| switch (act) {
            .set_master_volume => |p| try std.testing.expectApproxEqAbs(@as(f32, 1.0), p.volume, 1e-6),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    try std.testing.expectError(error.InvalidRequest, protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_master_volume\",\"params\":{\"volume\":1.5}}"));

    const r_mute = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"toggle_mute\"}");
    switch (r_mute) {
        .action => |act| try std.testing.expectEqual(protocol.Action.toggle_mute, act),
        else => return error.TestFailed,
    }

    const r_app = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_app_volume\",\"params\":{\"index\":7,\"volume\":0.8}}");
    switch (r_app) {
        .action => |act| switch (act) {
            .set_app_volume => |p| {
                try std.testing.expectEqual(@as(u32, 7), p.index);
                try std.testing.expectApproxEqAbs(@as(f32, 0.8), p.volume, 1e-6);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_app_mute = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_app_mute\",\"params\":{\"index\":7,\"muted\":true}}");
    switch (r_app_mute) {
        .action => |act| switch (act) {
            .set_app_mute => |p| {
                try std.testing.expectEqual(@as(u32, 7), p.index);
                try std.testing.expectEqual(true, p.muted);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_get = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"get_audio_state\"}");
    switch (r_get) {
        .action => |act| try std.testing.expectEqual(protocol.Action.get_audio_state, act),
        else => return error.TestFailed,
    }

    const r_stats = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"get_panel_stats\"}");
    switch (r_stats) {
        .action => |act| try std.testing.expectEqual(protocol.Action.get_panel_stats, act),
        else => return error.TestFailed,
    }

    const r_anims = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"get_animations\"}");
    switch (r_anims) {
        .action => |act| try std.testing.expectEqual(protocol.Action.get_animations, act),
        else => return error.TestFailed,
    }

    const r_reset = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"reset_panel_stats\"}");
    switch (r_reset) {
        .action => |act| try std.testing.expectEqual(protocol.Action.reset_panel_stats, act),
        else => return error.TestFailed,
    }

    const r_pinch = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"pinch\",\"params\":{\"phase\":\"begin\",\"scale\":1.2,\"fingers\":2}}");
    switch (r_pinch) {
        .action => |act| switch (act) {
            .pinch => |p| {
                try std.testing.expectEqual(protocol.GesturePhase.begin, p.phase);
                try std.testing.expectApproxEqAbs(@as(f64, 1.2), p.scale, 1e-9);
                try std.testing.expectEqual(@as(u32, 2), p.fingers);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_swipe = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"swipe\",\"params\":{\"phase\":\"update\",\"dx\":12,\"dy\":-4}}");
    switch (r_swipe) {
        .action => |act| switch (act) {
            .swipe => |p| {
                try std.testing.expectEqual(protocol.GesturePhase.update, p.phase);
                try std.testing.expectApproxEqAbs(@as(f64, 12), p.dx, 1e-9);
                try std.testing.expectApproxEqAbs(@as(f64, -4), p.dy, 1e-9);
            },
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_time = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_anim_time\",\"params\":{\"ms\":110}}");
    switch (r_time) {
        .action => |act| switch (act) {
            .set_anim_time => |p| try std.testing.expectEqual(@as(?i64, 110), p.ms),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_clear = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_anim_time\",\"params\":{\"ms\":null}}");
    switch (r_clear) {
        .action => |act| switch (act) {
            .set_anim_time => |p| try std.testing.expectEqual(@as(?i64, null), p.ms),
            else => return error.TestFailed,
        },
        else => return error.TestFailed,
    }

    const r_open = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"open_start_menu\"}");
    switch (r_open) {
        .action => |act| try std.testing.expectEqual(protocol.Action.open_start_menu, act),
        else => return error.TestFailed,
    }
}

test "stringify audio state response" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const streams = [_]protocol.SinkInputData{
        .{ .index = 5, .name = "Firefox", .app_id = "org.mozilla.firefox", .pid = 1234, .volume = 0.8, .muted = false },
    };
    const resp = protocol.Response{ .ok = .{ .audio_state = .{
        .master_volume = 0.6,
        .master_muted = false,
        .default_sink = "Built-in Audio",
        .streams = &streams,
    } } };
    try protocol.stringifyResponse(resp, bw);

    const expected = "{\"Ok\":{\"AudioState\":{\"master_volume\":0.6,\"master_muted\":false,\"default_sink\":\"Built-in Audio\",\"streams\":[{\"index\":5,\"name\":\"Firefox\",\"app_id\":\"org.mozilla.firefox\",\"pid\":1234,\"volume\":0.8,\"muted\":false}]}}}\n";
    try std.testing.expectEqualSlices(u8, expected, list.items);
}

test "stringify performance stats includes edge sample counters" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const resp = protocol.Response{ .ok = .{ .performance_stats = .{
        .output_commits = 3,
        .output_failed_commits = 1,
        .titlebar_paints = 4,
        .footer_paints = 2,
        .edge_samples_attempted = 5,
        .edge_samples_succeeded = 4,
        .edge_samples_skipped = 9,
        .edge_sample_ns = 1234,
        .panel_paints = 0,
        .panel_allocated_bytes = 0,
        .panel_reused_bytes = 0,
        .icon_cache_hits = 0,
        .icon_cache_misses = 0,
        .icon_decode_ns = 0,
        .icon_decode_count = 0,
        .icon_decoded_bytes = 0,
        .icon_queue_depth_max = 0,
        .taskbar_paints = 1,
        .taskbar_paint_ns = 500,
        .taskbar_raster_pixels = 640,
        .taskbar_clock_frame_requests = 2,
        .taskbar_clock_paints = 1,
        .taskbar_start_paints = 0,
        .taskbar_chip_paints = 1,
        .taskbar_tray_paints = 0,
        .taskbar_hover_paints = 0,
        .taskbar_press_paints = 0,
        .taskbar_audio_paints = 0,
        .recent_errors_count = 0,
    } } };
    try protocol.stringifyResponse(resp, bw);

    const expected = "{\"Ok\":{\"PerformanceStats\":{\"output_commits\":3,\"output_failed_commits\":1,\"fps\":0.0,\"frame_time_ms\":0.0,\"missed_frames\":0,\"refresh_hz\":0.0,\"titlebar_paints\":4,\"footer_paints\":2,\"edge_samples_attempted\":5,\"edge_samples_succeeded\":4,\"edge_samples_skipped\":9,\"edge_sample_ns\":1234,\"panel_paints\":0,\"panel_allocated_bytes\":0,\"panel_reused_bytes\":0,\"icon_cache_hits\":0,\"icon_cache_misses\":0,\"icon_decode_ns\":0,\"icon_decode_count\":0,\"icon_decoded_bytes\":0,\"icon_queue_depth_max\":0,\"taskbar_paints\":1,\"taskbar_paint_ns\":500,\"taskbar_raster_pixels\":640,\"taskbar_clock_frame_requests\":2,\"taskbar_clock_paints\":1,\"taskbar_start_paints\":0,\"taskbar_chip_paints\":1,\"taskbar_tray_paints\":0,\"taskbar_hover_paints\":0,\"taskbar_press_paints\":0,\"taskbar_audio_paints\":0,\"recent_errors_count\":0,\"anim_frames_scheduled\":0,\"anim_wasted_wakeups\":0,\"anim_longest_ms\":0,\"anim_speed\":1,\"anim_enabled\":true,\"anim_reduced_motion\":false}}}\n";
    try std.testing.expectEqualSlices(u8, expected, list.items);

    // Live producers add work timings; preserve the legacy fixture above.
    var extended = resp;
    extended.ok.performance_stats.screenshot_selection = .{ .motion_events = 500, .updates = 2, .toolbar_paints = 1, .scene_nodes_created = 19 };
    extended.ok.performance_stats.frame_work = .{
        .cpu_frame = .{ .samples = 3, .total_samples = 3, .avg_ms = 3, .p50_ms = 3, .p95_ms = 5, .p99_ms = 5, .max_ms = 5 },
    };
    list.clearRetainingCapacity();
    try protocol.stringifyResponse(extended, bw);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, list.items, .{});
    defer parsed.deinit();
    const selection = parsed.value.object.get("Ok").?.object.get("PerformanceStats").?.object.get("screenshot_selection").?;
    try std.testing.expectEqual(@as(i64, 500), selection.object.get("motion_events").?.integer);
    try std.testing.expectEqual(@as(i64, 2), selection.object.get("updates").?.integer);
    const work = parsed.value.object.get("Ok").?.object.get("PerformanceStats").?.object.get("frame_work").?;
    try std.testing.expectEqual(@as(i64, 3), work.object.get("cpu_frame").?.object.get("samples").?.integer);
    try std.testing.expect(!work.object.get("gpu_timing_available").?.bool);
    try std.testing.expectEqual(@as(i64, 0), work.object.get("gpu_elapsed").?.object.get("samples").?.integer);
}

test "stringify panel stats response" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const resp = protocol.Response{ .ok = .{ .panel_stats = .{
        .paints = 1,
        .allocated_bytes = 4096,
        .reused_bytes = 2048,
        .paint_ns = 12345,
    } } };
    try protocol.stringifyResponse(resp, bw);

    const expected = "{\"Ok\":{\"PanelStats\":{\"paints\":1,\"allocated_bytes\":4096,\"reused_bytes\":2048,\"paint_ns\":12345}}}\n";
    try std.testing.expectEqualSlices(u8, expected, list.items);
}

test "stringify animations response" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const items = [_]protocol.AnimationData{
        .{ .site = "start_menu.slide", .value = 0.5, .velocity = 1.25, .target = 1, .settled = false, .curve = "spring" },
    };
    const resp = protocol.Response{ .ok = .{ .animations = &items } };
    try protocol.stringifyResponse(resp, bw);

    const expected = "{\"Ok\":{\"Animations\":[{\"site\":\"start_menu.slide\",\"value\":0.5,\"velocity\":1.25,\"target\":1,\"settled\":false,\"curve\":\"spring\"}]}}\n";
    try std.testing.expectEqualSlices(u8, expected, list.items);
}

test "zoom IPC accepts only supported levels" {
    const allocator = std.testing.allocator;
    const request = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_zoom\",\"params\":{\"percent\":55}}");
    try std.testing.expectEqual(@as(u8, 55), request.action.set_zoom.percent);
    try std.testing.expectError(error.InvalidRequest, protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_zoom\",\"params\":{\"percent\":101}}"));
}

test "v1 envelope with integer and string IDs" {
    const allocator = std.testing.allocator;

    const env1 = try protocol.parseEnvelope(allocator, "{\"version\":1,\"command\":\"get_state\",\"id\":123}");
    try std.testing.expectEqual(@as(i64, 123), env1.id.?.integer);
    try std.testing.expectEqual(protocol.Request.get_state, env1.request);

    const env2 = try protocol.parseEnvelope(allocator, "{\"version\":1,\"command\":\"focus_window\",\"params\":{\"id\":7},\"id\":\"req-42\"}");
    try std.testing.expectEqualSlices(u8, "req-42", env2.id.?.string);
    allocator.free(env2.id.?.string);
    try std.testing.expectEqual(@as(u64, 7), env2.request.action.focus_window.id);

    // Direct object request with id
    const env3 = try protocol.parseEnvelope(allocator, "{\"version\":1,\"command\":\"get_runtime_info\",\"id\":99,\"params\":{}}");
    try std.testing.expectEqual(@as(i64, 99), env3.id.?.integer);
    try std.testing.expectEqual(protocol.Request.get_runtime_info, env3.request);
}

test "integer validation rejects negative ids and out of range values" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidRequest, protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"focus_window\",\"params\":{\"id\":-1}}"));
    try std.testing.expectError(error.InvalidRequest, protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"move_window_to\",\"params\":{\"id\":-5,\"x\":10,\"y\":20}}"));
    try std.testing.expectError(error.InvalidRequest, protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"pointer_button\",\"params\":{\"button\":-1,\"pressed\":true}}"));
    try std.testing.expectError(error.InvalidRequest, protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"key\",\"params\":{\"keycode\":-10,\"pressed\":true}}"));
}

test "parse wait and targeted actions" {
    const allocator = std.testing.allocator;

    const req_wait = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"wait_for\",\"params\":{\"condition\":\"menu_opened\",\"timeout_ms\":3000}}");
    try std.testing.expectEqual(protocol.WaitCondition.menu_opened, req_wait.action.wait_for.condition);
    try std.testing.expectEqual(@as(u64, 3000), req_wait.action.wait_for.timeout_ms);

    const req_wff = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"wait_for_frame\",\"params\":{\"output\":\"WL-1\",\"timeout_ms\":2000}}");
    try std.testing.expectEqualSlices(u8, "WL-1", req_wff.action.wait_for_frame.output.?);
    try std.testing.expectEqual(@as(u64, 2000), req_wff.action.wait_for_frame.timeout_ms);
    allocator.free(req_wff.action.wait_for_frame.output.?);

    const req_max = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"maximize_window\",\"params\":{\"id\":42}}");
    try std.testing.expectEqual(@as(u64, 42), req_max.action.maximize_window.id);

    const req_min = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"minimize_window\",\"params\":{\"id\":42}}");
    try std.testing.expectEqual(@as(u64, 42), req_min.action.minimize_window.id);

    const req_rest = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"restore_window\",\"params\":{\"id\":42}}");
    try std.testing.expectEqual(@as(u64, 42), req_rest.action.restore_window.id);

    const req_sz = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"set_window_size\",\"params\":{\"id\":42,\"width\":800,\"height\":600}}");
    try std.testing.expectEqual(@as(u64, 42), req_sz.action.set_window_size.id);
    try std.testing.expectEqual(@as(i32, 800), req_sz.action.set_window_size.width);
    try std.testing.expectEqual(@as(i32, 600), req_sz.action.set_window_size.height);

    const req_cp = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"close_panel\",\"params\":{\"panel\":\"start_menu\"}}");
    try std.testing.expectEqualSlices(u8, "start_menu", req_cp.action.close_panel.panel);
    allocator.free(req_cp.action.close_panel.panel);

    const req_rel = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"reload_config\"}");
    try std.testing.expectEqual(protocol.Action.reload_config, req_rel.action);

    const req_app = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"launch_app\",\"params\":{\"desktop_id\":\"foot.desktop\"}}");
    try std.testing.expectEqualSlices(u8, "foot.desktop", req_app.action.launch_app.desktop_id);
    allocator.free(req_app.action.launch_app.desktop_id);

    const req_wp = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"wait_for\",\"params\":{\"condition\":{\"widget_present\":{\"path\":\"control_center/bluetooth\"}},\"timeout_ms\":1000}}");
    try std.testing.expectEqualSlices(u8, "control_center/bluetooth", req_wp.action.wait_for.condition.widget_present.path);
    allocator.free(req_wp.action.wait_for.condition.widget_present.path);

    const req_wa = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"wait_for\",\"params\":{\"condition\":{\"widget_absent\":{\"path\":\"control_center/bluetooth\"}},\"timeout_ms\":1000}}");
    try std.testing.expectEqualSlices(u8, "control_center/bluetooth", req_wa.action.wait_for.condition.widget_absent.path);
    allocator.free(req_wa.action.wait_for.condition.widget_absent.path);

    const req_ws = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"wait_for\",\"params\":{\"condition\":{\"widget_state\":{\"path\":\"control_center/wifi\",\"field\":\"on\",\"equals\":true}},\"timeout_ms\":1000}}");
    try std.testing.expectEqualSlices(u8, "control_center/wifi", req_ws.action.wait_for.condition.widget_state.path);
    try std.testing.expectEqualSlices(u8, "on", req_ws.action.wait_for.condition.widget_state.field);
    try std.testing.expectEqual(true, req_ws.action.wait_for.condition.widget_state.equals.boolean);
    allocator.free(req_ws.action.wait_for.condition.widget_state.path);
    allocator.free(req_ws.action.wait_for.condition.widget_state.field);

    const req_ps = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"wait_for\",\"params\":{\"condition\":{\"panel_settled\":{\"panel\":\"control_center\"}},\"timeout_ms\":1000}}");
    try std.testing.expectEqualSlices(u8, "control_center", req_ps.action.wait_for.condition.panel_settled.panel);
    allocator.free(req_ps.action.wait_for.condition.panel_settled.panel);
}

test "stringify WidgetChanged event" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const ev = protocol.Event{
        .widget_changed = .{
            .seq = 10,
            .time_ms = 1000,
            .session_id = "test-session",
            .panel = "control_center",
            .path = "control_center/wifi",
            .name = "wifi",
            .widget = .{
                .id = 1,
                .role = "toggle",
                .name = "wifi",
                .path = "control_center/wifi",
                .box = .{ .x = 10, .y = 20, .width = 30, .height = 40 },
                .on = true,
            },
        },
    };
    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    try protocol.stringifyEvent(ev, bw);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "\"WidgetChanged\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "\"control_center/wifi\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.items, "\"on\":true") != null);
}

test "parse state and inspection queries" {
    const allocator = std.testing.allocator;

    const r_desc = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"describe_ipc\"}");
    try std.testing.expectEqual(protocol.Request.describe_ipc, r_desc);

    const r_state = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"get_state\"}");
    try std.testing.expectEqual(protocol.Request.get_state, r_state);

    const r_windbg = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"get_window_debug\",\"params\":{\"id\":15}}");
    try std.testing.expectEqual(@as(u64, 15), r_windbg.get_window_debug.id);

    const r_hit = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"hit_test\",\"params\":{\"x\":500,\"y\":300}}");
    try std.testing.expectEqual(@as(i32, 500), r_hit.hit_test.x);
    try std.testing.expectEqual(@as(i32, 300), r_hit.hit_test.y);

    const r_input = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"get_input_state\"}");
    try std.testing.expectEqual(protocol.Request.get_input_state, r_input);

    const r_runtime = try protocol.parseRequest(allocator, "{\"version\":1,\"command\":\"get_runtime_info\"}");
    try std.testing.expectEqual(protocol.Request.get_runtime_info, r_runtime);
}

test "stringify response with id envelope" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    const resp = protocol.Response{ .ok = .handled };

    try protocol.stringifyResponseWithId(.{ .integer = 42 }, resp, bw);
    try std.testing.expectEqualSlices(u8, "{\"id\":42,\"Ok\":\"Handled\"}\n", list.items);

    list.clearRetainingCapacity();
    try protocol.stringifyResponseWithId(.{ .string = "query-1" }, resp, bw);
    try std.testing.expectEqualSlices(u8, "{\"id\":\"query-1\",\"Ok\":\"Handled\"}\n", list.items);
}

test "v1 commands with params and invalid IDs" {
    const allocator = std.testing.allocator;

    const env1 = try protocol.parseEnvelope(allocator, "{\"version\":1,\"command\":\"launch_app\",\"id\":1,\"params\":{\"desktop_id\":\"org.foot.terminal\"}}");
    try std.testing.expectEqual(@as(i64, 1), env1.id.?.integer);
    try std.testing.expectEqualSlices(u8, "org.foot.terminal", env1.request.action.launch_app.desktop_id);
    allocator.free(env1.request.action.launch_app.desktop_id);

    const env2 = try protocol.parseEnvelope(allocator, "{\"version\":1,\"command\":\"get_state\",\"id\":2}");
    try std.testing.expectEqual(@as(i64, 2), env2.id.?.integer);
    try std.testing.expectEqual(protocol.Request.get_state, env2.request);

    const env3 = try protocol.parseEnvelope(allocator, "{\"version\":1,\"command\":\"wait_for\",\"id\":\"abc\",\"params\":{\"condition\":\"menu_opened\",\"timeout_ms\":1000}}");
    try std.testing.expectEqualSlices(u8, "abc", env3.id.?.string);
    allocator.free(env3.id.?.string);
    try std.testing.expectEqual(protocol.WaitCondition.menu_opened, env3.request.action.wait_for.condition);
    try std.testing.expectEqual(@as(u64, 1000), env3.request.action.wait_for.timeout_ms);

    try std.testing.expectError(error.InvalidEnvelope, protocol.parseEnvelope(allocator, "{\"id\": 3, \"action\": \"ReloadConfig\", \"query\": \"GetState\"}"));
    try std.testing.expectError(error.InvalidRequestId, protocol.parseEnvelope(allocator, "{\"version\":1,\"command\":\"get_state\",\"id\":-5}"));
    try std.testing.expectError(error.InvalidRequestId, protocol.parseEnvelope(allocator, "{\"version\":1,\"command\":\"get_state\",\"id\":true}"));
    try std.testing.expectError(error.InvalidEnvelope, protocol.parseEnvelope(allocator, "{\"id\": 1, \"random_field\": 123}"));
    try std.testing.expectError(error.InvalidEnvelope, protocol.parseEnvelope(allocator, "{}"));
}

test "IPC registry covers public variants and all routes" {
    @setEvalBranchQuota(200_000);
    const registry = protocol.commands;
    inline for (.{ protocol.Request, protocol.Action }) |T| {
        inline for (std.meta.fields(T)) |field| {
            if (comptime T == protocol.Request and registry.isInternalRequest(field.name)) continue;
            var count: usize = 0;
            inline for (registry.specs) |s| {
                if (comptime std.mem.eql(u8, @tagName(s.id), field.name)) count += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), count);
        }
    }
    inline for (registry.specs) |s| {
        var cap_count: usize = 0;
        for (registry.capabilities) |cap| if (std.mem.eql(u8, cap, comptime s.wire())) {
            cap_count += 1;
        };
        var desc_count: usize = 0;
        for (registry.descriptions) |desc| if (std.mem.eql(u8, desc.name, @tagName(s.id))) {
            desc_count += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), cap_count);
        try std.testing.expectEqual(@as(usize, 1), desc_count);
    }
}

fn expectJsonEqual(expected: std.json.Value, actual: std.json.Value) !void {
    if (expected == .integer and actual == .float) return std.testing.expectEqual(@as(f64, @floatFromInt(expected.integer)), actual.float);
    if (expected == .float and actual == .integer) return std.testing.expectEqual(expected.float, @as(f64, @floatFromInt(actual.integer)));
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .object => |obj| {
            try std.testing.expectEqual(obj.count(), actual.object.count());
            var it = obj.iterator();
            while (it.next()) |entry| try expectJsonEqual(entry.value_ptr.*, actual.object.get(entry.key_ptr.*) orelse return error.TestUnexpectedResult);
        },
        .array => |arr| {
            try std.testing.expectEqual(arr.items.len, actual.array.items.len);
            for (arr.items, actual.array.items) |a, b| try expectJsonEqual(a, b);
        },
        .string, .number_string => |s| try std.testing.expectEqualStrings(s, if (actual == .string) actual.string else actual.number_string),
        .integer => |i| try std.testing.expectEqual(i, actual.integer),
        .float => |f| try std.testing.expectEqual(f, actual.float),
        .bool => |b| try std.testing.expectEqual(b, actual.bool),
        .null => {},
    }
}

test "response serializers preserve baseline fields rounding and omissions" {
    @setEvalBranchQuota(200_000);
    const fixtures = @import("ipc_serializer_fixtures.zig");
    var lines = std.mem.splitScalar(u8, @embedFile("ipc_serializers.jsonl"), '\n');
    inline for (std.meta.fields(protocol.ResponsePayload)) |field| {
        inline for (.{ false, true }) |populated| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const payload = @unionInit(protocol.ResponsePayload, field.name, fixtures.sample(field.type, populated));
            var list: std.ArrayList(u8) = .empty;
            try protocol.stringifyResponse(.{ .ok = payload }, protocol.BufferWriter{ .list = &list, .allocator = a });
            const actual = try std.json.parseFromSlice(std.json.Value, a, list.items, .{});
            const expected = try std.json.parseFromSlice(std.json.Value, a, lines.next().?, .{});
            expectJsonEqual(expected.value, actual.value) catch |err| {
                std.debug.print("serializer {s}, populated={}\n", .{ field.name, populated });
                return err;
            };
        }
    }
}

fn requestCommandName(request: protocol.Request) []const u8 {
    return switch (request) {
        .action => |action| @tagName(action),
        .event_stream_filtered => "event_stream",
        else => @tagName(request),
    };
}

test "every v1 command parses" {
    @setEvalBranchQuota(500_000);
    // A shared valid parameter set exercises extraction through every route.
    // A future command requiring a new parameter must extend the fixture.
    const params =
        \\{"id":7,"window_id":8,"x":12,"y":23,"dx":-2,"dy":3,
        \\"from_x":1,"from_y":2,"to_x":3,"to_y":4,"width":10,"height":20,
        \\"percent":85,"output":"HEADLESS-1","panel":"start_menu","target":"titlebar",
        \\"argv":["foot"],"button":272,"pressed":true,"keycode":30,"key":"Super+a",
        \\"text":"hi","volume":0.7,"index":1,"muted":false,"ms":null,
        \\"condition":"menu_opened","timeout_ms":42,"seconds":2,"enabled":true,
        \\"blank_after_seconds":600,"suspend_after_seconds":0,"desktop_id":"example.desktop",
        \\"action_key":"default","phase":"begin","scale":1.2,"rotation":0,
        \\"fingers":2,"cancelled":false,"layout":"next","path":"start_menu/settings","at":0.5,
        \\"service":"alpha.service","mode":"on","event":"bell","color":"#aabbcc"}
    ;
    inline for (protocol.commands.specs) |s| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const input = try std.fmt.allocPrint(a, "{{\"version\":1,\"command\":\"{s}\",\"params\":{s}}}", .{ comptime s.wire(), params });
        const request = try protocol.parseRequest(a, input);
        try std.testing.expectEqualStrings(@tagName(s.id), requestCommandName(request));
    }
}

fn encodeWithFailingAllocator(allocator: std.mem.Allocator) !void {
    const pixels = [_]u32{0xff123456} ** 16;
    const bytes = try @import("screenshot/encode.zig").encodePng(allocator, 4, 4, &pixels, 4);
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 20);
    // A successful PNG must include its IEND chunk, never a partial callback buffer.
    try std.testing.expectEqualStrings("IEND", bytes[bytes.len - 8 .. bytes.len - 4]);
}

test "PNG callback allocation failures cannot publish empty or truncated images" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, encodeWithFailingAllocator, .{});
}

test "polkit lifecycle events contain only sequence and time" {
    const allocator = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    const bw = protocol.BufferWriter{ .list = &list, .allocator = allocator };
    try protocol.stringifyEvent(.{ .polkit_prompt_opened = .{ .seq = 7, .time_ms = 42 } }, bw);
    try protocol.stringifyEvent(.{ .polkit_prompt_closed = .{ .seq = 8, .time_ms = 43 } }, bw);
    try std.testing.expectEqualStrings("{\"PolkitPromptOpened\":{\"seq\":7,\"time_ms\":42}}\n{\"PolkitPromptClosed\":{\"seq\":8,\"time_ms\":43}}\n", list.items);
}

test "layout switch validates targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const next = try protocol.parseRequest(a, "{\"version\":1,\"command\":\"switch_layout\",\"params\":{\"layout\":\"next\"}}");
    try std.testing.expectEqual(protocol.LayoutTarget.next, next.action.switch_layout);
    const prev = try protocol.parseRequest(a, "{\"version\":1,\"command\":\"switch_layout\",\"params\":{\"layout\":\"Prev\"}}");
    try std.testing.expectEqual(protocol.LayoutTarget.prev, prev.action.switch_layout);
    const indexed = try protocol.parseRequest(a, "{\"version\":1,\"command\":\"switch_layout\",\"params\":{\"layout\":0}}");
    try std.testing.expectEqual(@as(u32, 0), indexed.action.switch_layout.index);
    for ([_][]const u8{ "-1", "4294967296", "1.5", "null", "true", "\"wrong\"" }) |value| {
        const json = try std.fmt.allocPrint(a, "{{\"version\":1,\"command\":\"switch_layout\",\"params\":{{\"layout\":{s}}}}}", .{value});
        try std.testing.expectError(error.InvalidRequest, protocol.parseRequest(a, json));
    }
    try std.testing.expectError(error.InvalidRequest, protocol.parseRequest(a, "{\"version\":1,\"command\":\"switch_layout\",\"params\":{}}"));
}

test "urgency event has stable window identity and boolean state" {
    const a = std.testing.allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(a);
    const writer = protocol.BufferWriter{ .list = &list, .allocator = a };
    try protocol.stringifyEvent(.{ .window_urgency_changed = .{ .seq = 9, .id = 42, .urgent = true } }, writer);
    try std.testing.expectEqualStrings("{\"WindowUrgencyChanged\":{\"seq\":9,\"id\":42,\"urgent\":true}}\n", list.items);
}

test "window tab metadata is explicit and omitted for ordinary windows" {
    const a = std.testing.allocator;
    var window: protocol.WindowData = .{ .id = 4, .is_focused = false, .is_minimized = false, .is_maximized = false, .x = 0, .y = 0, .width = 400, .height = 300 };
    const ordinary = try std.json.Stringify.valueAlloc(a, window, .{});
    defer a.free(ordinary);
    try std.testing.expect(std.mem.indexOf(u8, ordinary, "tab_group") == null);
    window.tag = "settings";
    window.description = "Settings window";
    window.content_type = "video";
    window.tab_group = 2;
    window.tab_active = false;
    const grouped = try std.json.Stringify.valueAlloc(a, window, .{});
    defer a.free(grouped);
    try std.testing.expect(std.mem.indexOf(u8, grouped, "\"tab_group\":2,\"tab_active\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, grouped, "\"tag\":\"settings\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, grouped, "\"description\":\"Settings window\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, grouped, "\"content_type\":\"video\"") != null);
}

test "v1 rejects legacy envelopes names versions and ambiguous fields" {
    const invalid = [_][]const u8{
        "\"Windows\"",
        "{\"Windows\":{}}",
        "{\"Action\":{\"MoveCursor\":{\"x\":1,\"y\":2}}}",
        "{\"request\":\"Windows\"}",
        "{\"query\":\"windows\"}",
        "{\"action\":\"move_cursor\",\"params\":{\"x\":1,\"y\":2}}",
        "{\"command\":\"windows\"}",
        "{\"version\":2,\"command\":\"windows\"}",
        "{\"version\":\"1\",\"command\":\"windows\"}",
        "{\"version\":1,\"command\":\"Windows\"}",
        "{\"version\":1,\"command\":\"state\"}",
        "{\"version\":1,\"command\":\"windows\",\"query\":\"outputs\"}",
        "{\"version\":1,\"command\":\"windows\",\"params\":null}",
        "{\"version\":1,\"command\":\"windows\",\"command\":\"outputs\"}",
    };
    for (invalid) |input| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        if (protocol.parseEnvelope(arena.allocator(), input)) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
