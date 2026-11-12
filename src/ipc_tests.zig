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

test {
    _ = @import("ipc/protocol_stringify_tests.zig");
}

test {
    _ = @import("ipc/protocol_parse_tests.zig");
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
        inline for (@typeInfo(T).@"union".field_names) |field_name| {
            if (comptime T == protocol.Request and registry.isInternalRequest(field_name)) continue;
            var count: usize = 0;
            inline for (registry.specs) |s| {
                if (comptime std.mem.eql(u8, @tagName(s.id), field_name)) count += 1;
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
        for (registry.descriptions) |desc| if (std.mem.eql(u8, desc.name, comptime s.wire())) {
            desc_count += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), cap_count);
        try std.testing.expectEqual(@as(usize, 1), desc_count);
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
        \\"action":"toggle_split","action_key":"default","phase":"begin","scale":1.2,"rotation":0,
        \\"fingers":2,"cancelled":false,"layout":"next","source":"next","path":"start_menu/settings","at":0.5,
        \\"service":"alpha.service","mode":"on","event":"bell","color":"#aabbcc","workspace":2,"automatic":true,"gap":12,"apps":["utility*"]}
    ;
    inline for (protocol.commands.specs) |s| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const input = try std.fmt.allocPrint(a, "{{\"version\":1,\"command\":\"{s}\",\"params\":{s}}}", .{ comptime s.wire(), if (s.id == .set_desktop_mode) "{\"mode\":\"workspaces\"}" else if (s.id == .theme_apply) "{\"id\":\"rediwm-dark\"}" else params });
        const request = try protocol.parseRequest(a, input);
        try std.testing.expectEqualStrings(@tagName(s.id), requestCommandName(request));
    }
}

fn encodeWithFailingAllocator(allocator: std.mem.Allocator) !void {
    const pixels = @as([16]u32, @splat(0xff123456));
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
    const source = try protocol.parseRequest(a, "{\"version\":1,\"command\":\"switch_input_source\",\"params\":{\"source\":2}}");
    try std.testing.expectEqual(@as(u32, 2), source.action.switch_input_source.index);
    try std.testing.expectEqual(protocol.LayoutTarget.prev, (try protocol.parseRequest(a, "{\"version\":1,\"command\":\"switch_input_source\",\"params\":{\"source\":\"prev\"}}")).action.switch_input_source);
    try std.testing.expectError(error.InvalidRequest, protocol.parseRequest(a, "{\"version\":1,\"command\":\"switch_input_source\",\"params\":{\"source\":\"first\"}}"));
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

test "tiling IPC accepts only the shared tiling actions" {
    const a = std.testing.allocator;
    const request = try protocol.parseRequest(a, "{\"version\":1,\"command\":\"tiling_action\",\"params\":{\"action\":\"toggle_floating\",\"id\":7}}");
    try std.testing.expectEqual(@as(?u64, 7), request.action.tiling_action.id);
    try std.testing.expect(request.action.tiling_action.action == .toggle_floating);
    inline for (.{
        "{\"action\":\"spawn\"}",
        "{\"action\":\"toggle_split\",\"id\":-1}",
        "{\"action\":42}",
        "{}",
    }) |params| {
        try std.testing.expectError(error.InvalidRequest, protocol.parseRequest(a, "{\"version\":1,\"command\":\"tiling_action\",\"params\":" ++ params ++ "}"));
    }
}

test "workspace controls validate IDs, spacing, patterns and mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = .{
        .{ "switch_workspace", "{\"workspace\":0}" },
        .{ "move_to_workspace", "{\"id\":7,\"workspace\":33}" },
        .{ "set_workspace_layout", "{\"workspace\":2,\"automatic\":1}" },
        .{ "set_window_gap", "{\"gap\":513}" },
        .{ "set_floating_apps", "{\"apps\":[true]}" },
        .{ "set_desktop_mode", "{\"mode\":\"unknown\"}" },
    };
    inline for (cases) |item| {
        const input = "{\"version\":1,\"command\":\"" ++ item[0] ++ "\",\"params\":" ++ item[1] ++ "}";
        try std.testing.expectError(error.InvalidRequest, protocol.parseRequest(a, input));
    }
}
