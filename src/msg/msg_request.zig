//! Serializing a parsed command as one v1 request line.

const std = @import("std");
const msg_cli = @import("msg_cli.zig");
const protocol = @import("protocol");
const Command = msg_cli.Command;

/// The request line for `command`; `doctor` is handled locally and never sent.
pub fn buildRequest(allocator: std.mem.Allocator, command: Command) !std.ArrayList(u8) {
    var req_buf = std.ArrayList(u8).empty;
    errdefer req_buf.deinit(allocator);

    switch (command) {
        .doctor => unreachable,
        .version => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"version\"}\n"),
        .capabilities => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"capabilities\"}\n"),
        .windows => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"windows\"}\n"),
        .outputs => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"outputs\"}\n"),
        .focused_window => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"focused_window\"}\n"),
        .workspaces => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"workspaces\"}\n"),
        .event_stream => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.events != null or p.window_id != null or p.output != null) {
                try bw.writeAll("{\"version\":1,\"command\":\"event_stream\",\"params\":{");
                var comma = false;
                if (p.events) |evs| {
                    try bw.writeAll("\"events\":[");
                    for (evs, 0..) |ev, i| {
                        if (i > 0) try bw.writeByte(',');
                        try bw.print("{f}", .{std.json.fmt(ev, .{})});
                    }
                    try bw.writeByte(']');
                    comma = true;
                }
                if (p.window_id) |wid| {
                    if (comma) try bw.writeByte(',');
                    try bw.print("\"window_id\":{d}", .{wid});
                    comma = true;
                }
                if (p.output) |out| {
                    if (comma) try bw.writeByte(',');
                    try bw.print("\"output\":{f}", .{std.json.fmt(out, .{})});
                    comma = true;
                }
                try bw.writeAll("}}\n");
            } else {
                try bw.writeAll("{\"version\":1,\"command\":\"event_stream\"}\n");
            }
        },
        .focus_window => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"focus_window\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .close_window => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.id) |id| {
                try bw.print("{{\"version\":1,\"command\":\"close_window\",\"params\":{{\"id\":{d}}}}}\n", .{id});
            } else {
                try bw.writeAll("{\"version\":1,\"command\":\"close_window\"}\n");
            }
        },
        .move_window_to => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"move_window_to\",\"params\":{{\"id\":{d}", .{p.id});
            if (p.x) |x| if (p.y) |y| try bw.print(",\"x\":{d},\"y\":{d}", .{ x, y });
            if (p.output) |output| try bw.print(",\"output\":{f}", .{std.json.fmt(output, .{})});
            try bw.writeAll("}}\n");
        },
        .spawn => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"spawn\",\"params\":{\"argv\":[");
            for (p.argv, 0..) |arg, i| {
                if (i > 0) try bw.writeByte(',');
                try bw.print("{f}", .{std.json.fmt(arg, .{})});
            }
            try bw.writeAll("]}}\n");
        },
        .move_cursor => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.output) |out| {
                try bw.print("{{\"version\":1,\"command\":\"move_cursor\",\"params\":{{\"x\":{d},\"y\":{d},\"output\":{f}}}}}\n", .{ p.x, p.y, std.json.fmt(out, .{}) });
            } else {
                try bw.print("{{\"version\":1,\"command\":\"move_cursor\",\"params\":{{\"x\":{d},\"y\":{d}}}}}\n", .{ p.x, p.y });
            }
        },
        .move_cursor_relative => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"move_cursor_relative\",\"params\":{{\"dx\":{d},\"dy\":{d}}}}}\n", .{ p.dx, p.dy });
        },
        .pointer_button => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"pointer_button\",\"params\":{{\"button\":{d},\"pressed\":{s}}}}}\n", .{ p.button, if (p.pressed) "true" else "false" });
        },
        .click => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"click\",\"params\":{{\"button\":{d}}}}}\n", .{p.button});
        },
        .scroll => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"scroll\",\"params\":{{\"dx\":{d},\"dy\":{d}}}}}\n", .{ p.dx, p.dy });
        },
        .key => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"key\",\"params\":{{\"keycode\":{d},\"pressed\":{s}}}}}\n", .{ p.keycode, if (p.pressed) "true" else "false" });
        },
        .key_press => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"key_press\",\"params\":{{\"key\":{f}}}}}\n", .{std.json.fmt(p.key, .{})});
        },
        .type_text => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"type_text\",\"params\":{{\"text\":{f}}}}}\n", .{std.json.fmt(p.text, .{})});
        },
        .drag => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.output) |out| {
                try bw.print("{{\"version\":1,\"command\":\"drag\",\"params\":{{\"from_x\":{d},\"from_y\":{d},\"to_x\":{d},\"to_y\":{d},\"button\":{d},\"output\":{f}}}}}\n", .{ p.from_x, p.from_y, p.to_x, p.to_y, p.button, std.json.fmt(out, .{}) });
            } else {
                try bw.print("{{\"version\":1,\"command\":\"drag\",\"params\":{{\"from_x\":{d},\"from_y\":{d},\"to_x\":{d},\"to_y\":{d},\"button\":{d}}}}}\n", .{ p.from_x, p.from_y, p.to_x, p.to_y, p.button });
            }
        },
        .screenshot => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"screenshot\",\"params\":{");
            var comma = false;
            if (p.output) |out| {
                try bw.print("\"output\":{f}", .{std.json.fmt(out, .{})});
                comma = true;
            }
            if (p.window_id) |wid| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"window_id\":{d}", .{wid});
                comma = true;
            }
            if (p.mode) |m| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"mode\":{f}", .{std.json.fmt(m, .{})});
                comma = true;
            }
            if (p.include_cursor) {
                if (comma) try bw.writeByte(',');
                try bw.writeAll("\"include_cursor\":true");
                comma = true;
            }
            if (p.path) |path| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"path\":{f}", .{std.json.fmt(path, .{})});
                comma = true;
            }
            try bw.writeAll("}}\n");
        },
        .set_master_volume => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"set_master_volume\",\"params\":{{\"volume\":{d}}}}}\n", .{p.volume});
        },
        .toggle_mute => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"toggle_mute\"}\n"),
        .set_app_volume => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"set_app_volume\",\"params\":{{\"index\":{d},\"volume\":{d}}}}}\n", .{ p.index, p.volume });
        },
        .set_app_mute => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"set_app_mute\",\"params\":{{\"index\":{d},\"muted\":{s}}}}}\n", .{ p.index, if (p.muted) "true" else "false" });
        },
        .get_audio_state => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_audio_state\"}\n"),
        .get_panel_stats => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_panel_stats\"}\n"),
        .reset_panel_stats => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"reset_panel_stats\"}\n"),
        .set_anim_time => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.ms) |ms| {
                try bw.print("{{\"version\":1,\"command\":\"set_anim_time\",\"params\":{{\"ms\":{d}}}}}\n", .{ms});
            } else {
                try bw.writeAll("{\"version\":1,\"command\":\"set_anim_time\",\"params\":{\"ms\":null}}\n");
            }
        },
        .open_start_menu => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"open_start_menu\"}\n"),
        .open_control_center => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"open_control_center\"}\n"),
        .open_power_menu => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"open_power_menu\"}\n"),
        .raw => |r| {
            try req_buf.appendSlice(allocator, r);
            if (!std.mem.endsWith(u8, r, "\n")) {
                try req_buf.append(allocator, '\n');
            }
        },
        .state => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_state\"}\n"),
        .describe => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"describe_ipc\"}\n"),
        .window_debug => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"get_window_debug\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .window_rules => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"get_window_rules\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .match_window_rules => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"match_window_rules\",\"params\":{");
            var comma = false;
            if (p.app_id) |app| {
                try bw.print("\"app_id\":{f}", .{std.json.fmt(app, .{})});
                comma = true;
            }
            if (p.title) |t| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"title\":{f}", .{std.json.fmt(t, .{})});
                comma = true;
            }
            if (p.x11_class) |cls| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"x11_class\":{f}", .{std.json.fmt(cls, .{})});
                comma = true;
            }
            if (p.x11_instance) |inst| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"x11_instance\":{f}", .{std.json.fmt(inst, .{})});
                comma = true;
            }
            if (p.backend) |b| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"backend\":{f}", .{std.json.fmt(b, .{})});
                comma = true;
            }
            if (p.dialog) |d| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"dialog\":{}", .{d});
            }
            try bw.writeAll("}}\n");
        },
        .night_light => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_night_light\"}\n"),
        .notifications => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_notifications\"}\n"),
        .shell_state => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.output) |out| {
                try bw.print("{{\"version\":1,\"command\":\"get_shell_state\",\"params\":{{\"output\":{f}}}}}\n", .{std.json.fmt(out, .{})});
            } else {
                try bw.writeAll("{\"version\":1,\"command\":\"get_shell_state\"}\n");
            }
        },
        .keyboard_layouts => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_keyboard_layouts\"}\n"),
        .switch_layout => |target| {
            const bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"switch_layout\",\"params\":{\"layout\":");
            switch (target) {
                .next => try bw.writeAll("\"next\""),
                .prev => try bw.writeAll("\"prev\""),
                .index => |idx| try bw.print("{d}", .{idx}),
            }
            try bw.writeAll("}}\n");
        },
        .input_sources => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_input_sources\"}\n"),
        .switch_input_source => |target| {
            const bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"switch_input_source\",\"params\":{\"source\":");
            switch (target) {
                .next => try bw.writeAll("\"next\""),
                .prev => try bw.writeAll("\"prev\""),
                .index => |idx| try bw.print("{d}", .{idx}),
            }
            try bw.writeAll("}}\n");
        },
        .text_input => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_text_input\"}\n"),
        .input_state => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_input_state\"}\n"),
        .hit_test => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.output) |out| {
                try bw.print("{{\"version\":1,\"command\":\"hit_test\",\"params\":{{\"x\":{d},\"y\":{d},\"output\":{f}}}}}\n", .{ p.x, p.y, std.json.fmt(out, .{}) });
            } else {
                try bw.print("{{\"version\":1,\"command\":\"hit_test\",\"params\":{{\"x\":{d},\"y\":{d}}}}}\n", .{ p.x, p.y });
            }
        },
        .scene_tree => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.max_depth) |md| {
                try bw.print("{{\"version\":1,\"command\":\"get_scene_tree\",\"params\":{{\"max_depth\":{d}}}}}\n", .{md});
            } else {
                try bw.writeAll("{\"version\":1,\"command\":\"get_scene_tree\"}\n");
            }
        },
        .layers => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_layer_surfaces\"}\n"),
        .panels => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"list_panels\"}\n"),
        .widget_tree => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"get_widget_tree\",\"params\":{{\"panel\":{f}}}}}\n", .{std.json.fmt(p.panel, .{})});
        },
        .config => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_config_status\"}\n"),
        .runtime => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_runtime_info\"}\n"),
        .perf => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_performance_stats\"}\n"),
        .perf_reset => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"reset_performance_stats\"}\n"),
        .wait => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"wait_for\",\"params\":{{\"condition\":{f}", .{std.json.fmt(p.condition, .{})});
            if (p.timeout_ms) |t| try bw.print(",\"timeout_ms\":{d}", .{t});
            if (p.window_id) |wid| try bw.print(",\"window_id\":{d}", .{wid});
            if (p.output) |out| try bw.print(",\"output\":{f}", .{std.json.fmt(out, .{})});
            try bw.writeAll("}}\n");
        },
        .wait_frame => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"wait_for_frame\",\"params\":{");
            var comma = false;
            if (p.output) |out| {
                try bw.print("\"output\":{f}", .{std.json.fmt(out, .{})});
                comma = true;
            }
            if (p.timeout_ms) |t| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"timeout_ms\":{d}", .{t});
            }
            try bw.writeAll("}}\n");
        },
        .dump_buffer => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"dump_buffer\",\"params\":{{\"target\":{f}", .{std.json.fmt(p.target, .{})});
            if (p.window_id) |wid| try bw.print(",\"window_id\":{d}", .{wid});
            if (p.output) |out| try bw.print(",\"output\":{f}", .{std.json.fmt(out, .{})});
            try bw.writeAll("}}\n");
        },
        .sample_pixels => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"sample_pixels\",\"params\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}", .{ p.x, p.y, p.width, p.height });
            if (p.output) |out| try bw.print(",\"output\":{f}", .{std.json.fmt(out, .{})});
            try bw.writeAll("}}\n");
        },
        .output_config => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"set_output_config\",\"params\":{{\"output\":{f}", .{std.json.fmt(p.output, .{})});
            inline for (.{ "width", "height", "refresh_mhz", "x", "y", "scale" }) |field| {
                if (@field(p, field)) |value| try bw.print(",\"{s}\":{d}", .{ field, value });
            }
            if (p.auto_scale) try bw.writeAll(",\"scale\":\"auto\"");
            if (p.auto_position) try bw.writeAll(",\"position\":\"auto\"");
            if (p.enabled) |value| try bw.print(",\"enabled\":{s}", .{if (value) "true" else "false"});
            if (p.primary) |value| try bw.print(",\"primary\":{s}", .{if (value) "true" else "false"});
            if (p.transform) |value| try bw.print(",\"transform\":\"{s}\"", .{protocol.outputTransformName(value)});
            try bw.writeAll("}}\n");
        },
        .maximize => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"maximize_window\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .minimize => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"minimize_window\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .restore => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"restore_window\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .fullscreen => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.output) |out| {
                try bw.print("{{\"version\":1,\"command\":\"fullscreen_window\",\"params\":{{\"id\":{d},\"output\":{f}}}}}\n", .{ p.id, std.json.fmt(out, .{}) });
            } else {
                try bw.print("{{\"version\":1,\"command\":\"fullscreen_window\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
            }
        },
        .set_zoom => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"set_window_zoom\",\"params\":{{\"id\":{d},\"percent\":{d}}}}}\n", .{ p.id, p.percent });
        },
        .close_panel => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"close_panel\",\"params\":{{\"panel\":{f}}}}}\n", .{std.json.fmt(p.panel, .{})});
        },
        .reload => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"reload_config\"}\n"),
        .launch => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"launch_app\",\"params\":{{\"desktop_id\":{f}}}}}\n", .{std.json.fmt(p.desktop_id, .{})});
        },
    }
    return req_buf;
}
