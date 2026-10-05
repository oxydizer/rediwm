// Control center "Input" section: mouse/touchpad pointer accel speed, natural
// scroll, tap-to-click (all via libinput device config, applied immediately
// to every pointer device) and keyboard repeat delay/rate (design doc Part 3,
// Section 3).
//
// Widget callbacks carry their owning Section explicitly.
const std = @import("std");
const wlr = @import("wlroots");

const layout = @import("ui").layout;
const ui_slider = @import("ui").widgets.slider;
const theme = @import("ui").theme;
const panel = @import("../panel.zig");
const Widget = layout.Widget;
const Input = @import("../../Input.zig");
const libinput = @import("../../libinput.zig");

const default_speed_step: f32 = 0.1;
const default_delay_step: f32 = 50;
const default_rate_step: f32 = 5;

const pan_speed_values = [4]f32{ 1, 2, 3, 4 };
const pan_speed_labels = [_][]const u8{ "1x", "2x", "3x", "4x" };
const pan_speed_segmented_width: f32 = 180;

const PointerKind = enum { mouse, touchpad };

pub const Section = struct {
    root: Widget = undefined,
    top_children: [2]Widget = undefined,
    row_storage: [8]Widget = undefined,
    row_count: usize = 0,
    mouse_speed_group_children: [2]Widget = undefined,
    mouse_speed_header_children: [2]Widget = undefined,
    touchpad_speed_group_children: [2]Widget = undefined,
    touchpad_speed_header_children: [2]Widget = undefined,
    touchpad_dwt_row_children: [2]Widget = undefined,
    speed_value_buf: [16]u8 = undefined,
    touchpad_speed_value_buf: [16]u8 = undefined,
    natural_row_children: [2]Widget = undefined,
    tap_row_children: [2]Widget = undefined,
    pan_speed_row_children: [2]Widget = undefined,
    delay_row_children: [2]Widget = undefined,
    rate_row_children: [2]Widget = undefined,

    input: *Input = undefined,
};

fn dimLabel(content: []const u8) Widget {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = content, .font_size = 13, .color = t.dim } } };
}

fn fgLabel(content: []const u8) Widget {
    const t = panel.palette();
    return .{ .kind = .{ .text = .{ .content = content, .font_size = 13, .weight = 600, .color = t.fg } } };
}

fn firstPointerValue(input: *Input, comptime getter: fn (*wlr.InputDevice) ?bool, fallback: bool) bool {
    var it = input.pointers.iterator(.forward);
    while (it.next()) |pointer| {
        if (getter(pointer.device)) |v| return v;
    }
    return fallback;
}

fn firstPointerValueForKind(input: *Input, kind: PointerKind, comptime getter: fn (*wlr.InputDevice) ?bool) ?bool {
    var it = input.pointers.iterator(.forward);
    while (it.next()) |pointer| {
        const is_touchpad = libinput.isTouchpad(pointer.device);
        if ((kind == .touchpad) != is_touchpad) continue;
        if (getter(pointer.device)) |v| return v;
    }
    return null;
}

fn firstPointerSpeedFor(input: *Input, kind: PointerKind) ?f32 {
    var it = input.pointers.iterator(.forward);
    while (it.next()) |pointer| {
        const is_touchpad = libinput.isTouchpad(pointer.device);
        if ((kind == .touchpad) != is_touchpad) continue;
        if (libinput.getPointerSpeed(pointer.device)) |v| return @floatCast(v);
    }
    return null;
}

fn indexOfNearest(values: []const f32, v: f32) usize {
    var best: usize = 0;
    var best_d = @abs(values[0] - v);
    for (values, 0..) |candidate, i| {
        const d = @abs(candidate - v);
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return best;
}

fn hasTouchpad(input: *Input) bool {
    var it = input.pointers.iterator(.forward);
    while (it.next()) |pointer| {
        if (libinput.isTouchpad(pointer.device)) return true;
    }
    return false;
}

fn applyPointerSpeedTo(input: *Input, kind: PointerKind, speed: f32) void {
    var it = input.pointers.iterator(.forward);
    while (it.next()) |pointer| {
        const is_touchpad = libinput.isTouchpad(pointer.device);
        if ((kind == .touchpad) != is_touchpad) continue;
        libinput.setPointerSpeed(pointer.device, speed);
    }
}

fn applyPointerDisableWhileTypingTo(input: *Input, kind: PointerKind, on: bool) void {
    var it = input.pointers.iterator(.forward);
    while (it.next()) |pointer| {
        const is_touchpad = libinput.isTouchpad(pointer.device);
        if ((kind == .touchpad) != is_touchpad) continue;
        libinput.setDisableWhileTyping(pointer.device, on);
    }
}

fn fallbackMouseSpeed(input: *Input) f32 {
    return input.server.config.input.pointer_speed;
}

fn fallbackTouchpadSpeed(input: *Input) f32 {
    return input.server.config.input.pointer_speed_touchpad;
}

fn fallbackMouseDisableWhileTyping(input: *Input) bool {
    return input.server.config.input.disable_while_typing;
}

fn fallbackTouchpadDisableWhileTyping(input: *Input) bool {
    return input.server.config.input.disable_while_typing_touchpad;
}

fn pointerSpeedFor(input: *Input, kind: PointerKind) f32 {
    return firstPointerSpeedFor(input, kind) orelse switch (kind) {
        .mouse => fallbackMouseSpeed(input),
        .touchpad => fallbackTouchpadSpeed(input),
    };
}

fn pointerDisableWhileTypingFor(input: *Input, kind: PointerKind) bool {
    return firstPointerValueForKind(input, kind, libinput.getDisableWhileTyping) orelse switch (kind) {
        .mouse => fallbackMouseDisableWhileTyping(input),
        .touchpad => fallbackTouchpadDisableWhileTyping(input),
    };
}

fn firstKeyboardRepeat(input: *Input) struct { delay: f32, rate: f32 } {
    if (input.keyboards.first()) |kb| {
        const wlr_kb = kb.device.toKeyboard();
        return .{ .delay = @floatFromInt(wlr_kb.repeat_info.delay), .rate = @floatFromInt(wlr_kb.repeat_info.rate) };
    }
    return .{ .delay = @floatFromInt(input.server.config.input.key_repeat_delay), .rate = @floatFromInt(input.server.config.input.key_repeat_rate) };
}

pub fn build(out: *Section, input: *Input) void {
    out.input = input;

    const show_touchpad = hasTouchpad(input);
    const mouse_speed = pointerSpeedFor(input, .mouse);
    const touchpad_speed = pointerSpeedFor(input, .touchpad);
    const touchpad_disable_while_typing = pointerDisableWhileTypingFor(input, .touchpad);
    const natural = firstPointerValue(input, libinput.getNaturalScroll, input.server.config.input.natural_scroll);
    const tap = firstPointerValue(input, libinput.getTapToClick, input.server.config.input.tap_to_click);
    const repeat = firstKeyboardRepeat(input);

    var row_count: usize = 0;

    const mouse_speed_str = std.fmt.bufPrint(&out.speed_value_buf, "{d:.1}", .{mouse_speed}) catch "0.0";
    out.mouse_speed_header_children = .{ fgLabel("Mouse speed"), ui_slider.valuePill(mouse_speed_str, 13, panel.palette().dim) };
    const mouse_speed_header: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.mouse_speed_header_children };
    const mouse_speed_slider: Widget = .{ .name = "mouse_speed", .kind = .{ .slider = .{ .value = mouse_speed, .min = -1, .max = 1, .step = default_speed_step, .owner = out, .on_change = &onMouseSpeedChanged } } };
    out.mouse_speed_group_children = .{ mouse_speed_header, mouse_speed_slider };
    layout.appendRow(&out.row_storage, &row_count, .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.mouse_speed_group_children });

    if (show_touchpad) {
        const touchpad_speed_str = std.fmt.bufPrint(&out.touchpad_speed_value_buf, "{d:.1}", .{touchpad_speed}) catch "0.0";
        out.touchpad_speed_header_children = .{
            fgLabel("Touchpad speed"),
            ui_slider.valuePill(touchpad_speed_str, 13, panel.palette().dim),
        };
        const touchpad_speed_header: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .children = &out.touchpad_speed_header_children };
        const touchpad_speed_slider: Widget = .{ .name = "touchpad_speed", .kind = .{ .slider = .{ .value = touchpad_speed, .min = -1, .max = 1, .step = default_speed_step, .owner = out, .on_change = &onTouchpadSpeedChanged } } };
        out.touchpad_speed_group_children = .{ touchpad_speed_header, touchpad_speed_slider };
        layout.appendRow(&out.row_storage, &row_count, .{ .kind = .container, .direction = .column, .gap = 8, .children = &out.touchpad_speed_group_children });

        out.touchpad_dwt_row_children = .{
            fgLabel("Disable touchpad while typing"),
            .{ .name = "touchpad_disable_while_typing", .kind = .{ .toggle = .{ .on = touchpad_disable_while_typing, .owner = out, .on_change = &onTouchpadDisableWhileTypingChanged } } },
        };
        const touchpad_dwt_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.touchpad_dwt_row_children };
        layout.appendRow(&out.row_storage, &row_count, touchpad_dwt_row);
    }

    out.natural_row_children = .{ fgLabel("Natural scroll"), .{ .name = "natural_scroll", .kind = .{ .toggle = .{ .on = natural, .owner = out, .on_change = &onNaturalScrollChanged } } } };
    const natural_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.natural_row_children };
    layout.appendRow(&out.row_storage, &row_count, natural_row);

    out.tap_row_children = .{ fgLabel("Tap to click"), .{ .name = "tap_to_click", .kind = .{ .toggle = .{ .on = tap, .owner = out, .on_change = &onTapToClickChanged } } } };
    const tap_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.tap_row_children };
    layout.appendRow(&out.row_storage, &row_count, tap_row);

    out.pan_speed_row_children = .{
        fgLabel("Pan speed"),
        .{
            .name = "pan_speed",
            .kind = .{ .segmented = .{ .labels = &pan_speed_labels, .selected = indexOfNearest(&pan_speed_values, input.server.config.input.pan_speed), .owner = out, .on_change = &onPanSpeedChanged } },
            .width = .{ .fixed = pan_speed_segmented_width },
        },
    };
    const pan_speed_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.pan_speed_row_children };
    layout.appendRow(&out.row_storage, &row_count, pan_speed_row);

    out.delay_row_children = .{
        fgLabel("Repeat delay"),
        .{ .name = "repeat_delay", .kind = .{ .stepper = .{ .value = repeat.delay, .min = 100, .max = 2000, .step = default_delay_step, .unit = "ms", .owner = out, .on_change = &onRepeatDelayChanged } } },
    };
    const delay_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.delay_row_children };
    layout.appendRow(&out.row_storage, &row_count, delay_row);

    out.rate_row_children = .{
        fgLabel("Repeat rate"),
        .{ .name = "repeat_rate", .kind = .{ .stepper = .{ .value = repeat.rate, .min = 1, .max = 100, .step = default_rate_step, .unit = "/s", .owner = out, .on_change = &onRepeatRateChanged } } },
    };
    const rate_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.rate_row_children };
    layout.appendRow(&out.row_storage, &row_count, rate_row);

    out.row_count = row_count;
    const pal = panel.palette();
    out.top_children = .{
        .{ .kind = .{ .text = .{ .content = "INPUT", .font_size = 12, .weight = 700, .color = pal.dim } } },
        .{ .name = "input", .kind = .container, .direction = .column, .gap = 12, .children = out.row_storage[0..row_count] },
    };
    out.root = .{ .name = "input", .kind = .container, .direction = .column, .gap = 8, .children = &out.top_children };
}

fn onMouseSpeedChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    applyPointerSpeedTo(s.input, .mouse, value);
    persist(s, "pointer_speed", value);
    const formatted = std.fmt.bufPrint(&s.speed_value_buf, "{d:.1}", .{value}) catch "?";
    s.mouse_speed_header_children[1].kind.text.content = formatted;
    s.mouse_speed_header_children[1].markDirty();
}

fn onTouchpadSpeedChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    applyPointerSpeedTo(s.input, .touchpad, value);
    persist(s, "pointer_speed_touchpad", value);
    const formatted = std.fmt.bufPrint(&s.touchpad_speed_value_buf, "{d:.1}", .{value}) catch "?";
    s.touchpad_speed_header_children[1].kind.text.content = formatted;
    s.touchpad_speed_header_children[1].markDirty();
}

fn onTouchpadDisableWhileTypingChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    applyPointerDisableWhileTypingTo(s.input, .touchpad, on);
    persist(s, "disable_while_typing_touchpad", on);
}

fn onNaturalScrollChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    var it = s.input.pointers.iterator(.forward);
    while (it.next()) |pointer| libinput.setNaturalScroll(pointer.device, on);
    persist(s, "natural_scroll", on);
}

fn onTapToClickChanged(owner: ?*anyopaque, _: usize, on: bool) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    var it = s.input.pointers.iterator(.forward);
    while (it.next()) |pointer| libinput.setTapToClick(pointer.device, on);
    persist(s, "tap_to_click", on);
}

fn onPanSpeedChanged(owner: ?*anyopaque, _: usize, index: usize) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    persist(s, "pan_speed", pan_speed_values[index]);
}

fn applyRepeatInfo(s: *Section) void {
    const delay: i32 = @intFromFloat(s.delay_row_children[1].kind.stepper.value);
    const rate: i32 = @intFromFloat(s.rate_row_children[1].kind.stepper.value);
    var it = s.input.keyboards.iterator(.forward);
    while (it.next()) |kb| kb.device.toKeyboard().setRepeatInfo(rate, delay);
}

fn onRepeatDelayChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    applyRepeatInfo(s);
    persist(s, "key_repeat_delay", @intFromFloat(value));
}

fn onRepeatRateChanged(owner: ?*anyopaque, _: usize, value: f32) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    applyRepeatInfo(s);
    persist(s, "key_repeat_rate", @intFromFloat(value));
}

fn persist(s: *Section, comptime key: []const u8, value: @FieldType(@import("config").loader.InputConfig, key)) void {
    const server = s.input.server;
    // Keep hotplug and panel rebuilds consistent with the live setting too.
    @field(server.config.input, key) = value;
    @import("config").setting_save.saveInput(@import("../../main.zig").gpa, server.io, server.config.path, key, value) catch |err| {
        std.log.warn("could not save input setting '{s}': {}", .{ key, err });
    };
}
