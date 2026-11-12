//! IPC v1 per-command parameter parsing for queries and actions.

const std = @import("std");
const commands = @import("commands.zig");
const output_transform = @import("config").output_transform;
const RectData = @import("protocol_data.zig").RectData;
const MatchWindowRulesParams = @import("protocol_data.zig").MatchWindowRulesParams;
const FractionCoord = @import("protocol_data.zig").FractionCoord;
const EventFilter = @import("protocol_results.zig").EventFilter;
const OutputConfigPatch = @import("protocol_results.zig").OutputConfigPatch;
const LayoutTarget = @import("protocol_results.zig").LayoutTarget;
const ServiceMode = @import("protocol_results.zig").ServiceMode;
const ParseError = @import("protocol_parse.zig").ParseError;
const parseU64 = @import("protocol_parse.zig").parseU64;
const parseOptU64 = @import("protocol_parse.zig").parseOptU64;
const parseU32 = @import("protocol_parse.zig").parseU32;
const parseOptU32 = @import("protocol_parse.zig").parseOptU32;
const parseOptI64 = @import("protocol_parse.zig").parseOptI64;
const parseI32 = @import("protocol_parse.zig").parseI32;
const parseGesturePhase = @import("protocol_parse.zig").parseGesturePhase;
const parseF64 = @import("protocol_parse.zig").parseF64;
const parseFractionCoord = @import("protocol_parse.zig").parseFractionCoord;
const parseVolume = @import("protocol_parse.zig").parseVolume;
const parseRect = @import("protocol_parse.zig").parseRect;
const emptyAction = @import("protocol_parse.zig").emptyAction;
const emptyRequest = @import("protocol_parse.zig").emptyRequest;
const parseWaitCondition = @import("protocol_wait.zig").parseWaitCondition;
const Action = @import("protocol.zig").Action;
const Request = @import("protocol.zig").Request;

pub fn parseWaitForParams(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!Action {
    const cond_val = obj.get("condition") orelse return error.InvalidRequest;
    const condition = try parseWaitCondition(allocator, cond_val);
    var timeout_ms: u64 = 5000;
    if (obj.get("timeout_ms")) |t_val| timeout_ms = try parseU64(t_val);
    return .{ .wait_for = .{ .condition = condition, .timeout_ms = timeout_ms } };
}

pub fn parseWaitForFrameParams(allocator: std.mem.Allocator, params: ?std.json.ObjectMap) ParseError!Action {
    var output: ?[]const u8 = null;
    var timeout_ms: u64 = 5000;
    if (params) |p| {
        if (p.get("output")) |out_v| {
            if (out_v == .string) {
                if (out_v.string.len > 256) return error.InvalidRequest;
                output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
            } else if (out_v != .null) return error.InvalidRequest;
        }
        if (p.get("timeout_ms")) |t_val| timeout_ms = try parseU64(t_val);
    }
    return .{ .wait_for_frame = .{ .output = output, .timeout_ms = timeout_ms } };
}

pub fn parseDumpBufferParams(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!Action {
    const tgt_val = obj.get("target") orelse return error.InvalidRequest;
    if (tgt_val != .string or tgt_val.string.len > 64) return error.InvalidRequest;
    const target = allocator.dupe(u8, tgt_val.string) catch return error.OutOfMemory;
    var win_id: ?u64 = null;
    if (obj.get("window_id")) |win_v| win_id = try parseOptU64(win_v);
    var output: ?[]const u8 = null;
    if (obj.get("output")) |out_v| {
        if (out_v == .string) {
            if (out_v.string.len > 256) return error.InvalidRequest;
            output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
        } else if (out_v != .null) return error.InvalidRequest;
    }
    return .{ .dump_buffer = .{ .target = target, .window_id = win_id, .output = output } };
}

pub fn parseSamplePixelsParams(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!Action {
    const x_val = obj.get("x") orelse return error.InvalidRequest;
    const y_val = obj.get("y") orelse return error.InvalidRequest;
    var output: ?[]const u8 = null;
    if (obj.get("output")) |out_v| {
        if (out_v == .string) {
            if (out_v.string.len > 256) return error.InvalidRequest;
            output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
        } else if (out_v != .null) return error.InvalidRequest;
    }
    var width: u32 = 1;
    var height: u32 = 1;
    if (obj.get("width")) |w_val| width = try parseU32(w_val);
    if (obj.get("height")) |h_val| height = try parseU32(h_val);
    if (width == 0 or width > 1024 or height == 0 or height > 1024) return error.InvalidRequest;
    return .{ .sample_pixels = .{
        .output = output,
        .x = try parseI32(x_val),
        .y = try parseI32(y_val),
        .width = width,
        .height = height,
    } };
}

pub fn parseMatchWindowRules(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!Request {
    var params: MatchWindowRulesParams = .{};
    if (obj.get("app_id")) |v| {
        if (v == .string) params.app_id = allocator.dupe(u8, v.string) catch return error.OutOfMemory else if (v != .null) return error.InvalidRequest;
    }
    if (obj.get("title")) |v| {
        if (v == .string) params.title = allocator.dupe(u8, v.string) catch return error.OutOfMemory else if (v != .null) return error.InvalidRequest;
    }
    if (obj.get("x11_class") orelse obj.get("class")) |v| {
        if (v == .string) params.x11_class = allocator.dupe(u8, v.string) catch return error.OutOfMemory else if (v != .null) return error.InvalidRequest;
    }
    if (obj.get("x11_instance") orelse obj.get("instance")) |v| {
        if (v == .string) params.x11_instance = allocator.dupe(u8, v.string) catch return error.OutOfMemory else if (v != .null) return error.InvalidRequest;
    }
    if (obj.get("backend")) |v| {
        if (v == .string) params.backend = allocator.dupe(u8, v.string) catch return error.OutOfMemory else if (v != .null) return error.InvalidRequest;
    }
    if (obj.get("dialog")) |v| {
        if (v == .bool) params.dialog = v.bool else if (v != .null) return error.InvalidRequest;
    }
    return .{ .match_window_rules = params };
}

pub fn parseQueryParams(allocator: std.mem.Allocator, command_tag: commands.RouteTag(.query), params: ?std.json.ObjectMap) ParseError!Request {
    switch (command_tag) {
        .get_window_debug => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("window_id") orelse p.get("id") orelse return error.InvalidRequest;
            return .{ .get_window_debug = .{ .id = try parseU64(id_v) } };
        },
        .get_window_rules => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("window_id") orelse p.get("id") orelse return error.InvalidRequest;
            return .{ .get_window_rules = .{ .id = try parseU64(id_v) } };
        },
        .match_window_rules => {
            if (params) |p| {
                return parseMatchWindowRules(allocator, p);
            }
            return .{ .match_window_rules = .{} };
        },
        .get_shell_state => {
            var output: ?[]const u8 = null;
            if (params) |p| {
                if (p.get("output")) |out_v| {
                    if (out_v == .string) {
                        if (out_v.string.len > 256) return error.InvalidRequest;
                        output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                    } else if (out_v != .null) return error.InvalidRequest;
                }
            }
            return .{ .get_shell_state = .{ .output = output } };
        },

        .hit_test => {
            const p = params orelse return error.InvalidRequest;
            const x_v = p.get("x") orelse return error.InvalidRequest;
            const y_v = p.get("y") orelse return error.InvalidRequest;
            var output: ?[]const u8 = null;
            if (p.get("output")) |out_v| {
                if (out_v == .string) {
                    if (out_v.string.len > 256) return error.InvalidRequest;
                    output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                } else if (out_v != .null) return error.InvalidRequest;
            }
            return .{ .hit_test = .{
                .x = try parseI32(x_v),
                .y = try parseI32(y_v),
                .output = output,
            } };
        },
        .get_scene_tree => {
            var max_depth: ?u32 = null;
            if (params) |p| {
                if (p.get("max_depth")) |md_v| max_depth = try parseOptU32(md_v);
            }
            return .{ .get_scene_tree = .{ .max_depth = max_depth } };
        },

        .get_widget_tree => {
            const p = params orelse return error.InvalidRequest;
            const panel_v = p.get("panel") orelse return error.InvalidRequest;
            if (panel_v != .string or panel_v.string.len > 64) return error.InvalidRequest;
            const panel = allocator.dupe(u8, panel_v.string) catch return error.OutOfMemory;
            return .{ .get_widget_tree = .{ .panel = panel } };
        },

        .list_panels => {
            return .list_panels;
        },

        .event_stream => {
            if (params) |p| {
                var filter = EventFilter{};
                if (p.get("window_id")) |win_v| filter.window_id = try parseOptU64(win_v);
                if (p.get("output")) |out_v| {
                    if (out_v == .string) {
                        if (out_v.string.len > 256) return error.InvalidRequest;
                        filter.output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                    } else if (out_v != .null) return error.InvalidRequest;
                }
                const ev_list_v = p.get("events") orelse p.get("kinds");
                if (ev_list_v) |k_v| {
                    if (k_v == .array) {
                        var kinds_list = std.ArrayList([]const u8).empty;
                        for (k_v.array.items) |item| {
                            if (item == .string) {
                                const str = allocator.dupe(u8, item.string) catch return error.OutOfMemory;
                                kinds_list.append(allocator, str) catch return error.OutOfMemory;
                            }
                        }
                        filter.events = kinds_list.toOwnedSlice(allocator) catch return error.OutOfMemory;
                    }
                }
                return .{ .event_stream_filtered = filter };
            }
            return .event_stream;
        },
        inline else => |tag| return emptyRequest(@tagName(tag)),
    }
}

pub fn requiredText(allocator: std.mem.Allocator, p: std.json.ObjectMap, key: []const u8, max: usize) ParseError![]const u8 {
    const v = p.get(key) orelse return error.InvalidRequest;
    if (v != .string or v.string.len == 0 or v.string.len > max or std.mem.indexOfScalar(u8, v.string, 0) != null) return error.InvalidRequest;
    return allocator.dupe(u8, v.string);
}
pub fn persistParam(p: std.json.ObjectMap) ParseError!bool {
    const v = p.get("persist") orelse return true;
    if (v != .bool) return error.InvalidRequest;
    return v.bool;
}

pub fn parseActionParams(allocator: std.mem.Allocator, command_tag: commands.RouteTag(.action), params: ?std.json.ObjectMap) ParseError!Action {
    switch (command_tag) {
        .theme_apply => {
            const p = params orelse return error.InvalidRequest;
            return .{ .theme_apply = .{ .id = try requiredText(allocator, p, "id", 64) } };
        },
        .theme_install => {
            const p = params orelse return error.InvalidRequest;
            const r = p.get("replace");
            if (r != null and r.? != .bool) return error.InvalidRequest;
            return .{ .theme_install = .{ .path = try requiredText(allocator, p, "path", 4095), .replace = if (r) |v| v.bool else false } };
        },
        .switch_layout => {
            const p = params orelse return error.InvalidRequest;
            const value = p.get("layout") orelse return error.InvalidRequest;
            const target: LayoutTarget = switch (value) {
                .string => |name| if (std.ascii.eqlIgnoreCase(name, "next")) .next else if (std.ascii.eqlIgnoreCase(name, "prev")) .prev else return error.InvalidRequest,
                .integer => |idx| .{ .index = std.math.cast(u32, idx) orelse return error.InvalidRequest },
                else => return error.InvalidRequest,
            };
            return .{ .switch_layout = target };
        },
        .switch_input_source => {
            const p = params orelse return error.InvalidRequest;
            const value = p.get("source") orelse return error.InvalidRequest;
            const target: LayoutTarget = switch (value) {
                .string => |name| if (std.ascii.eqlIgnoreCase(name, "next")) .next else if (std.ascii.eqlIgnoreCase(name, "prev")) .prev else return error.InvalidRequest,
                .integer => |idx| .{ .index = std.math.cast(u32, idx) orelse return error.InvalidRequest },
                else => return error.InvalidRequest,
            };
            return .{ .switch_input_source = target };
        },
        .focus_window => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            return .{ .focus_window = .{ .id = try parseU64(id_v) } };
        },
        .close_window => {
            var id: ?u64 = null;
            if (params) |p| {
                if (p.get("id")) |id_v| id = try parseOptU64(id_v);
                if (id == null) {
                    if (p.get("window_id")) |id_v| id = try parseOptU64(id_v);
                }
            }
            return .{ .close_window = .{ .id = id } };
        },
        .move_window_to => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            const x_v = p.get("x");
            const y_v = p.get("y");
            const output_v = p.get("output");
            if ((x_v == null) != (y_v == null) and output_v == null) return error.InvalidRequest;
            var output: ?[]const u8 = null;
            if (x_v == null) {
                if (output_v) |value| {
                    if (value != .string or value.string.len == 0) return error.InvalidRequest;
                    output = try allocator.dupe(u8, value.string);
                }
            }
            if (x_v == null and output == null) return error.InvalidRequest;
            return .{ .move_window_to = .{
                .id = try parseU64(id_v),
                .x = if (x_v) |value| try parseI32(value) else 0,
                .y = if (y_v) |value| try parseI32(value) else 0,
                .output = output,
            } };
        },
        .spawn => {
            const p = params orelse return error.InvalidRequest;
            const argv_val = p.get("argv") orelse return error.InvalidRequest;
            if (argv_val != .array or argv_val.array.items.len > 256) return error.InvalidRequest;
            var list = std.ArrayList([]const u8).empty;
            for (argv_val.array.items) |item| {
                if (item != .string or item.string.len > 4096) return error.InvalidRequest;
                const str = allocator.dupe(u8, item.string) catch return error.OutOfMemory;
                list.append(allocator, str) catch return error.OutOfMemory;
            }
            return .{ .spawn = .{ .argv = list.toOwnedSlice(allocator) catch return error.OutOfMemory } };
        },
        .move_cursor => {
            const p = params orelse return error.InvalidRequest;
            const x_v = p.get("x") orelse return error.InvalidRequest;
            const y_v = p.get("y") orelse return error.InvalidRequest;
            var output: ?[]const u8 = null;
            if (p.get("output")) |out_v| {
                if (out_v == .string) {
                    if (out_v.string.len > 256) return error.InvalidRequest;
                    output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                } else if (out_v != .null) return error.InvalidRequest;
            }
            return .{ .move_cursor = .{
                .x = try parseI32(x_v),
                .y = try parseI32(y_v),
                .output = output,
            } };
        },
        .move_cursor_relative => {
            const p = params orelse return error.InvalidRequest;
            const dx_v = p.get("dx") orelse return error.InvalidRequest;
            const dy_v = p.get("dy") orelse return error.InvalidRequest;
            return .{ .move_cursor_relative = .{
                .dx = try parseI32(dx_v),
                .dy = try parseI32(dy_v),
            } };
        },
        .pointer_button => {
            const p = params orelse return error.InvalidRequest;
            const b_v = p.get("button") orelse return error.InvalidRequest;
            const pr_v = p.get("pressed") orelse return error.InvalidRequest;
            if (pr_v != .bool) return error.InvalidRequest;
            return .{ .pointer_button = .{ .button = try parseU32(b_v), .pressed = pr_v.bool } };
        },
        .click => {
            var btn: u32 = 0x110;
            if (params) |p| {
                if (p.get("button")) |b_v| btn = try parseU32(b_v);
            }
            return .{ .click = .{ .button = btn } };
        },
        .scroll => {
            const p = params orelse return error.InvalidRequest;
            const dx_v = p.get("dx") orelse return error.InvalidRequest;
            const dy_v = p.get("dy") orelse return error.InvalidRequest;
            return .{ .scroll = .{ .dx = try parseF64(dx_v), .dy = try parseF64(dy_v) } };
        },
        .pinch => {
            const p = params orelse return error.InvalidRequest;
            const phase = try parseGesturePhase(p.get("phase") orelse return error.InvalidRequest);
            var scale: f64 = 1;
            var dx: f64 = 0;
            var dy: f64 = 0;
            var rotation: f64 = 0;
            var fingers: u32 = 2;
            var cancelled = false;
            if (p.get("scale")) |v| scale = try parseF64(v);
            if (p.get("dx")) |v| dx = try parseF64(v);
            if (p.get("dy")) |v| dy = try parseF64(v);
            if (p.get("rotation")) |v| rotation = try parseF64(v);
            if (p.get("fingers")) |v| fingers = try parseU32(v);
            if (p.get("cancelled")) |v| {
                if (v != .bool) return error.InvalidRequest;
                cancelled = v.bool;
            }
            return .{ .pinch = .{
                .phase = phase,
                .scale = scale,
                .dx = dx,
                .dy = dy,
                .rotation = rotation,
                .fingers = fingers,
                .cancelled = cancelled,
            } };
        },
        .swipe => {
            const p = params orelse return error.InvalidRequest;
            const phase = try parseGesturePhase(p.get("phase") orelse return error.InvalidRequest);
            var dx: f64 = 0;
            var dy: f64 = 0;
            var fingers: u32 = 2;
            var cancelled = false;
            if (p.get("dx")) |v| dx = try parseF64(v);
            if (p.get("dy")) |v| dy = try parseF64(v);
            if (p.get("fingers")) |v| fingers = try parseU32(v);
            if (p.get("cancelled")) |v| {
                if (v != .bool) return error.InvalidRequest;
                cancelled = v.bool;
            }
            return .{ .swipe = .{
                .phase = phase,
                .dx = dx,
                .dy = dy,
                .fingers = fingers,
                .cancelled = cancelled,
            } };
        },
        .key => {
            const p = params orelse return error.InvalidRequest;
            const kc_v = p.get("keycode") orelse return error.InvalidRequest;
            const pr_v = p.get("pressed") orelse return error.InvalidRequest;
            if (pr_v != .bool) return error.InvalidRequest;
            return .{ .key = .{ .keycode = try parseU32(kc_v), .pressed = pr_v.bool } };
        },
        .key_press => {
            const p = params orelse return error.InvalidRequest;
            const k_v = p.get("key") orelse return error.InvalidRequest;
            if (k_v != .string or k_v.string.len > 64) return error.InvalidRequest;
            const key = allocator.dupe(u8, k_v.string) catch return error.OutOfMemory;
            return .{ .key_press = .{ .key = key } };
        },
        .type_text => {
            const p = params orelse return error.InvalidRequest;
            const t_v = p.get("text") orelse return error.InvalidRequest;
            if (t_v != .string or t_v.string.len > 65536) return error.InvalidRequest;
            const text = allocator.dupe(u8, t_v.string) catch return error.OutOfMemory;
            return .{ .type_text = .{ .text = text } };
        },
        .drag => {
            const p = params orelse return error.InvalidRequest;
            const fx_val = p.get("from_x") orelse return error.InvalidRequest;
            const fy_val = p.get("from_y") orelse return error.InvalidRequest;
            const tx_val = p.get("to_x") orelse return error.InvalidRequest;
            const ty_val = p.get("to_y") orelse return error.InvalidRequest;
            var button: u32 = 0x110;
            if (p.get("button")) |b_val| button = try parseU32(b_val);
            var output: ?[]const u8 = null;
            if (p.get("output")) |out_v| {
                if (out_v == .string) {
                    if (out_v.string.len > 256) return error.InvalidRequest;
                    output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                } else if (out_v != .null) return error.InvalidRequest;
            }
            return .{ .drag = .{
                .from_x = try parseI32(fx_val),
                .from_y = try parseI32(fy_val),
                .to_x = try parseI32(tx_val),
                .to_y = try parseI32(ty_val),
                .button = button,
                .output = output,
            } };
        },
        .screenshot => {
            var output: ?[]const u8 = null;
            var window_id: ?u64 = null;
            var mode: ?[]const u8 = null;
            var include_cursor: bool = false;
            var path: ?[]const u8 = null;
            var crop: ?RectData = null;
            var crop_space: ?[]const u8 = null;

            if (params) |p| {
                if (p.get("output")) |out_v| {
                    if (out_v == .string) {
                        if (out_v.string.len > 256) return error.InvalidRequest;
                        output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                    } else if (out_v != .null) return error.InvalidRequest;
                }
                if (p.get("window_id")) |win_v| window_id = try parseOptU64(win_v);
                if (p.get("mode")) |m_v| {
                    if (m_v == .string) {
                        if (m_v.string.len > 64) return error.InvalidRequest;
                        mode = allocator.dupe(u8, m_v.string) catch return error.OutOfMemory;
                    } else if (m_v != .null) return error.InvalidRequest;
                }
                if (p.get("include_cursor")) |ic_v| {
                    if (ic_v == .bool) include_cursor = ic_v.bool else return error.InvalidRequest;
                }
                if (p.get("path")) |pv| {
                    if (pv == .string) {
                        if (pv.string.len > 4096) return error.InvalidRequest;
                        path = allocator.dupe(u8, pv.string) catch return error.OutOfMemory;
                    } else if (pv != .null) return error.InvalidRequest;
                }
                if (p.get("crop")) |cr_v| {
                    if (cr_v != .null) crop = try parseRect(cr_v);
                }
                if (p.get("crop_space")) |cs_v| {
                    if (cs_v == .string) {
                        if (cs_v.string.len > 64) return error.InvalidRequest;
                        crop_space = allocator.dupe(u8, cs_v.string) catch return error.OutOfMemory;
                    } else if (cs_v != .null) return error.InvalidRequest;
                }
            }
            return .{ .screenshot = .{
                .output = output,
                .window_id = window_id,
                .mode = mode,
                .include_cursor = include_cursor,
                .path = path,
                .crop = crop,
                .crop_space = crop_space,
            } };
        },

        .set_camera => {
            const p = params orelse return error.InvalidRequest;
            const x_v = p.get("x") orelse return error.InvalidRequest;
            const y_v = p.get("y") orelse return error.InvalidRequest;
            return .{ .set_camera = .{
                .x = try parseI32(x_v),
                .y = try parseI32(y_v),
            } };
        },

        .set_zoom => {
            const p = params orelse return error.InvalidRequest;
            const pct_v = p.get("percent") orelse return error.InvalidRequest;
            if (pct_v != .integer) return error.InvalidRequest;
            if (pct_v.integer != 100 and pct_v.integer != 85 and pct_v.integer != 70 and pct_v.integer != 55) return error.InvalidRequest;
            return .{ .set_zoom = .{ .percent = @intCast(pct_v.integer) } };
        },
        .set_master_volume => {
            const p = params orelse return error.InvalidRequest;
            const vol_v = p.get("volume") orelse return error.InvalidRequest;
            return .{ .set_master_volume = .{ .volume = try parseVolume(vol_v) } };
        },

        .set_app_volume => {
            const p = params orelse return error.InvalidRequest;
            const idx_v = p.get("index") orelse return error.InvalidRequest;
            const vol_v = p.get("volume") orelse return error.InvalidRequest;
            return .{ .set_app_volume = .{
                .index = try parseU32(idx_v),
                .volume = try parseVolume(vol_v),
            } };
        },
        .set_app_mute => {
            const p = params orelse return error.InvalidRequest;
            const idx_v = p.get("index") orelse return error.InvalidRequest;
            const m_v = p.get("muted") orelse return error.InvalidRequest;
            if (m_v != .bool) return error.InvalidRequest;
            return .{ .set_app_mute = .{
                .index = try parseU32(idx_v),
                .muted = m_v.bool,
            } };
        },

        .set_anim_time => {
            const p = params orelse return error.InvalidRequest;
            const ms_val = p.get("ms") orelse return error.InvalidRequest;
            const ms: ?i64 = switch (ms_val) {
                .integer => |i| i,
                .null => null,
                else => return error.InvalidRequest,
            };
            return .{ .set_anim_time = .{ .ms = ms } };
        },

        .wait_for => {
            return parseWaitForParams(allocator, params orelse return error.InvalidRequest);
        },
        .wait_for_frame => {
            return parseWaitForFrameParams(allocator, params);
        },
        .dump_buffer => {
            return parseDumpBufferParams(allocator, params orelse return error.InvalidRequest);
        },
        .sample_pixels => {
            return parseSamplePixelsParams(allocator, params orelse return error.InvalidRequest);
        },

        .set_output_config => {
            const p = params orelse return error.InvalidRequest;
            const name = p.get("output") orelse return error.InvalidRequest;
            if (name != .string or name.string.len == 0) return error.InvalidRequest;
            var patch = OutputConfigPatch{ .output = try allocator.dupe(u8, name.string) };
            inline for (.{ "width", "height", "refresh_mhz", "x", "y" }) |field| {
                if (p.get(field)) |value| @field(patch, field) = try parseI32(value);
            }
            if (p.get("scale")) |value| {
                if (value == .string and std.mem.eql(u8, value.string, "auto")) {
                    patch.auto_scale = true;
                } else {
                    const scale = try parseF64(value);
                    if (scale < 1 or scale > 3) return error.InvalidRequest;
                    patch.scale = @floatCast(scale);
                }
            }
            if (p.get("position")) |value| {
                if (value != .string or !std.mem.eql(u8, value.string, "auto")) return error.InvalidRequest;
                patch.auto_position = true;
            }
            if (p.get("enabled")) |value| {
                if (value != .bool) return error.InvalidRequest;
                patch.enabled = value.bool;
            }
            if (p.get("primary")) |value| {
                if (value != .bool) return error.InvalidRequest;
                patch.primary = value.bool;
            }
            if (p.get("transform")) |value| {
                if (value != .string) return error.InvalidRequest;
                patch.transform = output_transform.parseName(value.string) catch return error.InvalidRequest;
            }
            patch.validate() catch return error.InvalidRequest;
            return .{ .set_output_config = patch };
        },
        .set_idle_config => {
            const p = params orelse return error.InvalidRequest;
            var enabled: ?bool = null;
            var blank: ?u32 = null;
            var suspend_sec: ?u32 = null;
            if (p.get("enabled")) |ev| {
                if (ev == .bool) enabled = ev.bool else return error.InvalidRequest;
            }
            if (p.get("blank_after_seconds")) |bv| blank = try parseU32(bv);
            if (p.get("suspend_after_seconds")) |sv| suspend_sec = try parseU32(sv);
            return .{ .set_idle_config = .{
                .enabled = enabled,
                .blank_after_seconds = blank,
                .suspend_after_seconds = suspend_sec,
            } };
        },
        .advance_idle_time => {
            const p = params orelse return error.InvalidRequest;
            const sec_v = p.get("seconds") orelse return error.InvalidRequest;
            return .{ .advance_idle_time = .{ .seconds = try parseU32(sec_v) } };
        },
        .set_service_mode => {
            const p = params orelse return error.InvalidRequest;
            const service = try requiredText(allocator, p, "service", 255);
            if (!std.mem.endsWith(u8, service, ".service") or std.mem.indexOfAny(u8, service, "/\\\n\r") != null or service[0] == '-') return error.InvalidRequest;
            const mode = p.get("mode") orelse return error.InvalidRequest;
            if (mode != .string) return error.InvalidRequest;
            return .{ .set_service_mode = .{ .service = service, .mode = std.meta.stringToEnum(ServiceMode, mode.string) orelse return error.InvalidRequest } };
        },
        .play_sound => {
            const p = params orelse return error.InvalidRequest;
            return .{ .play_sound = .{ .event = try requiredText(allocator, p, "event", 128) } };
        },
        .set_wallpaper => {
            const p = params orelse return error.InvalidRequest;
            const value = p.get("path") orelse return error.InvalidRequest;
            if (value != .string or value.string.len > 4096 or std.mem.indexOfScalar(u8, value.string, 0) != null) return error.InvalidRequest;
            return .{ .set_wallpaper = .{ .path = try allocator.dupe(u8, value.string), .persist = try persistParam(p) } };
        },
        .set_accent_color => {
            const p = params orelse return error.InvalidRequest;
            const value = p.get("color") orelse return error.InvalidRequest;
            if (value != .string or (value.string.len != 7 and value.string.len != 9) or value.string[0] != '#') return error.InvalidRequest;
            var color: [4]f32 = .{ 0, 0, 0, 1 };
            for (0..(value.string.len - 1) / 2) |i| {
                const channel = std.fmt.parseInt(u8, value.string[1 + i * 2 .. 3 + i * 2], 16) catch return error.InvalidRequest;
                color[i] = @as(f32, @floatFromInt(channel)) / 255;
            }
            return .{ .set_accent_color = .{ .color = color, .persist = try persistParam(p) } };
        },
        .set_night_light => {
            const p = params orelse return error.InvalidRequest;
            var enabled: ?bool = null;
            var temperature: ?u16 = null;
            if (p.get("enabled")) |v| {
                if (v != .bool) return error.InvalidRequest;
                enabled = v.bool;
            }
            if (p.get("temperature")) |v| {
                const n = try parseU32(v);
                if (n < 1700 or n > 10000) return error.InvalidRequest;
                temperature = @intCast(n);
            }
            if (enabled == null and temperature == null) return error.InvalidRequest;
            return .{ .set_night_light = .{ .enabled = enabled, .temperature = temperature, .persist = try persistParam(p) } };
        },
        .set_night_light_clock => {
            var sec: ?i64 = null;
            if (params) |p| {
                if (p.get("unix_seconds")) |sv| sec = try parseOptI64(sv);
            }
            return .{ .set_night_light_clock = .{ .unix_seconds = sec } };
        },
        .set_desktop_mode => {
            const p = params orelse return error.InvalidRequest;
            const mode = p.get("mode") orelse return error.InvalidRequest;
            if (mode != .string) return error.InvalidRequest;
            return .{ .set_desktop_mode = .{ .mode = std.meta.stringToEnum(@import("config").loader.DesktopMode, mode.string) orelse return error.InvalidRequest, .persist = try persistParam(p) } };
        },
        .switch_workspace, .move_to_workspace, .set_workspace_layout => {
            const p = params orelse return error.InvalidRequest;
            const id = try parseU32(p.get("workspace") orelse return error.InvalidRequest);
            if (id == 0 or id > 32) return error.InvalidRequest;
            switch (command_tag) {
                .switch_workspace => return .{ .switch_workspace = .{ .workspace = @intCast(id) } },
                .move_to_workspace => return .{ .move_to_workspace = .{ .id = try parseU64(p.get("id") orelse return error.InvalidRequest), .workspace = @intCast(id) } },
                else => {
                    const automatic = p.get("automatic") orelse return error.InvalidRequest;
                    if (automatic != .bool) return error.InvalidRequest;
                    return .{ .set_workspace_layout = .{ .workspace = @intCast(id), .automatic = automatic.bool } };
                },
            }
        },
        .set_window_gap => {
            const p = params orelse return error.InvalidRequest;
            const gap = try parseU32(p.get("gap") orelse return error.InvalidRequest);
            if (gap > 512) return error.InvalidRequest;
            return .{ .set_window_gap = .{ .gap = gap, .persist = try persistParam(p) } };
        },
        .set_floating_apps => {
            const p = params orelse return error.InvalidRequest;
            const values = p.get("apps") orelse return error.InvalidRequest;
            if (values != .array or values.array.items.len > 256) return error.InvalidRequest;
            const apps = try allocator.alloc([]const u8, values.array.items.len);
            for (values.array.items, apps) |value, *dest| {
                if (value != .string or value.string.len == 0 or value.string.len > 512) return error.InvalidRequest;
                dest.* = try allocator.dupe(u8, value.string);
            }
            return .{ .set_floating_apps = .{ .apps = apps, .persist = try persistParam(p) } };
        },
        .tiling_action => {
            const p = params orelse return error.InvalidRequest;
            const action = p.get("action") orelse return error.InvalidRequest;
            if (action != .string) return error.InvalidRequest;
            const tag = std.meta.stringToEnum(@import("config").keybinds.TilingAction, action.string) orelse return error.InvalidRequest;
            return .{ .tiling_action = .{ .action = tag, .id = if (p.get("id")) |id| try parseOptU64(id) else null } };
        },
        .maximize_window => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            return .{ .maximize_window = .{ .id = try parseU64(id_v) } };
        },
        .minimize_window => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            return .{ .minimize_window = .{ .id = try parseU64(id_v) } };
        },
        .restore_window => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            return .{ .restore_window = .{ .id = try parseU64(id_v) } };
        },
        .fullscreen_window => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            var output: ?[]const u8 = null;
            if (p.get("output")) |out_v| {
                if (out_v == .string) {
                    if (out_v.string.len > 256) return error.InvalidRequest;
                    output = allocator.dupe(u8, out_v.string) catch return error.OutOfMemory;
                } else if (out_v != .null) return error.InvalidRequest;
            }
            return .{ .fullscreen_window = .{ .id = try parseU64(id_v), .output = output } };
        },

        .set_window_size => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            const w_v = p.get("width") orelse return error.InvalidRequest;
            const h_v = p.get("height") orelse return error.InvalidRequest;
            return .{ .set_window_size = .{
                .id = try parseU64(id_v),
                .width = try parseI32(w_v),
                .height = try parseI32(h_v),
            } };
        },
        .set_window_zoom => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse p.get("window_id") orelse return error.InvalidRequest;
            const p_v = p.get("percent") orelse return error.InvalidRequest;
            if (p_v != .integer) return error.InvalidRequest;
            if (p_v.integer != 100 and p_v.integer != 85 and p_v.integer != 70 and p_v.integer != 55) return error.InvalidRequest;
            return .{ .set_window_zoom = .{
                .id = try parseU64(id_v),
                .percent = @intCast(p_v.integer),
            } };
        },
        .close_panel => {
            const p = params orelse return error.InvalidRequest;
            const p_v = p.get("panel") orelse return error.InvalidRequest;
            if (p_v != .string or p_v.string.len > 64) return error.InvalidRequest;
            const panel = allocator.dupe(u8, p_v.string) catch return error.OutOfMemory;
            return .{ .close_panel = .{ .panel = panel } };
        },

        .launch_app => {
            const p = params orelse return error.InvalidRequest;
            const d_val = p.get("desktop_id") orelse return error.InvalidRequest;
            if (d_val != .string or d_val.string.len > 256) return error.InvalidRequest;
            const desktop_id = allocator.dupe(u8, d_val.string) catch return error.OutOfMemory;
            var uris: []const []const u8 = &.{};
            if (p.get("uris")) |values| {
                if (values != .array or values.array.items.len > 128) return error.InvalidRequest;
                const list = try allocator.alloc([]const u8, values.array.items.len);
                for (values.array.items, list) |value, *item| {
                    if (value != .string or value.string.len > 8192) return error.InvalidRequest;
                    item.* = try allocator.dupe(u8, value.string);
                }
                uris = list;
            }
            return .{ .launch_app = .{ .desktop_id = desktop_id, .uris = uris } };
        },
        .dismiss_notification => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse return error.InvalidRequest;
            var reason: ?u32 = null;
            if (p.get("reason")) |r_v| reason = try parseOptU32(r_v);
            return .{ .dismiss_notification = .{ .id = try parseU32(id_v), .reason = reason } };
        },
        .invoke_notification_action => {
            const p = params orelse return error.InvalidRequest;
            const id_v = p.get("id") orelse return error.InvalidRequest;
            const key_v = p.get("action_key") orelse return error.InvalidRequest;
            if (key_v != .string or key_v.string.len > 256) return error.InvalidRequest;
            const action_key = allocator.dupe(u8, key_v.string) catch return error.OutOfMemory;
            return .{ .invoke_notification_action = .{ .id = try parseU32(id_v), .action_key = action_key } };
        },
        .set_dnd => {
            const p = params orelse return error.InvalidRequest;
            const en_v = p.get("enabled") orelse return error.InvalidRequest;
            if (en_v != .bool) return error.InvalidRequest;
            return .{ .set_dnd = .{ .enabled = en_v.bool } };
        },
        .click_widget => {
            const p = params orelse return error.InvalidRequest;
            const path_val = p.get("path") orelse return error.InvalidRequest;
            if (path_val != .string or path_val.string.len == 0) return error.InvalidRequest;
            const path = allocator.dupe(u8, path_val.string) catch return error.OutOfMemory;

            var button: ?u32 = null;
            if (p.get("button")) |b_v| {
                if (b_v != .null) button = try parseU32(b_v);
            }

            var at = FractionCoord{};
            if (p.get("at")) |at_v| {
                if (at_v != .null) at = try parseFractionCoord(at_v);
            }

            return .{ .click_widget = .{
                .path = path,
                .button = button,
                .at = at,
            } };
        },
        .hover_widget => {
            const p = params orelse return error.InvalidRequest;
            const path_val = p.get("path") orelse return error.InvalidRequest;
            if (path_val != .string or path_val.string.len == 0) return error.InvalidRequest;
            const path = allocator.dupe(u8, path_val.string) catch return error.OutOfMemory;

            var at = FractionCoord{};
            if (p.get("at")) |at_v| {
                if (at_v != .null) at = try parseFractionCoord(at_v);
            }

            return .{ .hover_widget = .{
                .path = path,
                .at = at,
            } };
        },
        inline else => |tag| return emptyAction(@tagName(tag)),
    }
}
