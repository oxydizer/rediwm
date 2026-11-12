const i18n = @import("i18n");
// Pointer controls read and change only the selected live device. Its stable
// identity selects a partial configuration record; keyboard and canvas controls
// remain global.
//
// Widget callbacks carry their owning Section explicitly.
const std = @import("std");

const layout = @import("ui").layout;
const ui_slider = @import("ui").widgets.slider;
const panel = @import("../panel.zig");
const Widget = layout.Widget;
const Input = @import("../../Input.zig");
const Pointer = @import("../../Pointer.zig");
const gpa = @import("../../main.zig").gpa;
const config = @import("config");
const libinput = @import("../../libinput.zig");
const xkb_registry = @import("../../input/xkb_registry.zig");

const bool_keys = [_][]const u8{ "natural_scroll", "left_handed", "tap_to_click", "tap_drag", "disable_while_typing" };

const default_speed_step: f32 = 0.1;
const default_delay_step: f32 = 50;
const default_rate_step: f32 = 5;

const pan_speed_values = [4]f32{ 1, 2, 3, 4 };
const pan_speed_labels = [_][]const u8{ "1x", "2x", "3x", "4x" };
const pan_speed_segmented_width: f32 = 180;

fn keyboardLayoutIndex(cfg: anytype, layouts: []const xkb_registry.Layout) ?usize {
    for (layouts, 0..) |item, i| {
        if (std.mem.eql(u8, item.name, cfg.xkb_layout)) return i;
    }
    return null;
}

fn loadKeyboardLayouts(s: *Section) void {
    const allocator = s.arena.allocator();
    s.keyboard_layouts = xkb_registry.enumerate(allocator) catch |err| {
        std.log.warn("could not enumerate XKB layouts: {}", .{err});
        s.keyboard_layouts = &.{};
        s.keyboard_layout_labels = &.{};
        return;
    };

    const labels = allocator.alloc([]const u8, s.keyboard_layouts.len) catch {
        s.keyboard_layouts = &.{};
        s.keyboard_layout_labels = &.{};
        return;
    };
    for (s.keyboard_layouts, 0..) |item, i| labels[i] = item.label;
    s.keyboard_layout_labels = labels;
}

pub const Section = struct {
    root: Widget = undefined,
    top_children: [2]Widget = undefined,
    row_storage: [7]Widget = undefined,
    row_count: usize = 0,
    selector_children: [4]Widget = undefined,
    selector_header_children: [2]Widget = undefined,
    speed_group_children: [2]Widget = undefined,
    speed_header_children: [2]Widget = undefined,
    speed_label_children: [2]Widget = undefined,
    bool_rows: [bool_keys.len]Widget = undefined,
    bool_row_children: [bool_keys.len][2]Widget = undefined,
    bool_label_children: [bool_keys.len][2]Widget = undefined,
    speed_value_buf: [16]u8 = undefined,
    layout_row_children: [2]Widget = undefined,
    keyboard_layouts: []xkb_registry.Layout = &.{},
    keyboard_layout_labels: [][]const u8 = &.{},
    pan_speed_row_children: [2]Widget = undefined,
    delay_row_children: [2]Widget = undefined,
    rate_row_children: [2]Widget = undefined,

    // Labels and token arrays belong to the section, never to a device or to
    // the replaceable configuration arena. Tokens are resolved again on use.
    arena: std.heap.ArenaAllocator = .init(gpa),
    device_ids: []u64 = &.{},
    device_labels: [][]const u8 = &.{},
    device_icons: []layout.IconId = &.{},
    show_all_devices: bool = false,
    selected_id: ?u64 = null,
    status: enum { none, unavailable, apply_failed, save_failed, rollback_failed, reset_failed, reset_restore_failed } = .none,
    input: *Input = undefined,
};

fn dimLabel(content: []const u8) Widget {
    return .{ .kind = .{ .text = .{ .content = content, .font_size = 13, .color = panel.palette().dim } } };
}

fn fgLabel(content: []const u8) Widget {
    return .{ .kind = .{ .text = .{ .content = content, .font_size = 13, .weight = 600, .color = panel.palette().fg } } };
}

fn row(children: []Widget) Widget {
    return .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = children };
}

fn refresh(s: *Section) void {
    if (s.input.server.input.open_control_center) |cc| cc.refresh();
}

fn selected(s: *Section, id: usize) ?*Pointer {
    // A queued callback from the old selection must not edit the new one.
    if (s.selected_id != id) return null;
    return Pointer.find(s.input, @intCast(id));
}

fn primaryPointer(input: *Input, pointer: *Pointer) bool {
    if (!libinput.isSettingsPointer(pointer.device)) return false;
    var it = input.pointers.iterator(.forward);
    while (it.next()) |other| {
        if (other != pointer and libinput.isTouchpadCompanion(pointer.device, other.device)) return false;
    }
    return true;
}

fn enumerate(s: *Section) void {
    _ = s.arena.reset(.retain_capacity);
    const a = s.arena.allocator();
    s.device_ids = &.{};
    s.device_labels = &.{};
    s.device_icons = &.{};
    const previous_selection = s.selected_id;
    s.selected_id = null;
    const count = s.input.pointers.length();
    const ids = a.alloc(u64, count) catch return;
    const labels = a.alloc([]const u8, count) catch return;
    const icons = a.alloc(layout.IconId, count) catch return;
    const duplicate = a.alloc(bool, count) catch return;
    var it = s.input.pointers.iterator(.forward);
    var n: usize = 0;
    var preferred: ?u64 = null;
    while (it.next()) |pointer| {
        if (!s.show_all_devices and !primaryPointer(s.input, pointer)) continue;
        const friendly = libinput.getFriendlyName(a, pointer.device) catch null;
        const raw_name = if (pointer.device.name) |p| std.mem.span(p) else "";
        const fallback_name = if (raw_name.len > 0) raw_name else i18n.tr("Pointer device");
        const label = friendly orelse (a.dupe(u8, fallback_name) catch break);
        ids[n] = pointer.id;
        labels[n] = label;
        icons[n] = switch (libinput.getKind(pointer.device)) {
            .mouse, .pointer => .mouse,
            .touchpad => .touchpad,
            .trackball => .trackball,
        };
        n += 1;
        if (preferred == null and pointer.persistentId() != null and
            (libinput.getPointerSpeed(pointer.device) != null or
                libinput.getNaturalScroll(pointer.device) != null or
                libinput.getLeftHanded(pointer.device) != null or
                libinput.getTapToClick(pointer.device) != null or
                libinput.getDisableWhileTyping(pointer.device) != null))
        {
            preferred = pointer.id;
        }
    }
    // Keep everyday names clean. Only simultaneous name collisions need a
    // live suffix; these labels never participate in configuration matching.
    @memset(duplicate[0..n], false);
    for (labels[0..n], 0..) |name, i| {
        for (labels[i + 1 .. n], i + 1..) |other, j| {
            if (std.mem.eql(u8, name, other)) {
                duplicate[i] = true;
                duplicate[j] = true;
            }
        }
    }
    for (duplicate[0..n], 0..) |collides, i| {
        if (!collides) continue;
        const pointer = Pointer.find(s.input, ids[i]) orelse continue;
        labels[i] = if (libinput.getSysname(pointer.device)) |sysname|
            std.fmt.allocPrint(a, "{s} ({s})", .{ labels[i], sysname }) catch labels[i]
        else
            std.fmt.allocPrint(a, "{s} ({d})", .{ labels[i], i + 1 }) catch labels[i];
    }
    s.device_ids = ids[0..n];
    s.device_labels = labels[0..n];
    s.device_icons = icons[0..n];
    if (previous_selection) |id| {
        if (std.mem.indexOfScalar(u64, s.device_ids, id) != null) {
            s.selected_id = id;
            return;
        }
    }
    // In the full list, prefer a configurable device over automation/nested
    // pointers when the previous selection disappeared.
    s.selected_id = preferred orelse (if (n > 0) ids[0] else null);
    s.status = .none;
}

fn statusText(s: *Section, pointer: ?*Pointer) []const u8 {
    return switch (s.status) {
        .apply_failed => i18n.tr("The device could not apply this setting."),
        .reset_failed => i18n.tr("Could not reset. The previous settings were restored."),
        .reset_restore_failed => i18n.tr("Could not reset or restore the previous settings."),
        .save_failed => i18n.tr("Could not save. The previous settings were restored."),
        .rollback_failed => i18n.tr("Could not save or restore the previous settings."),
        .unavailable => i18n.tr("This setting is unavailable on the selected device."),
        .none => if (pointer) |p|
            (if (p.persistentId() != null) i18n.tr("Settings apply only to this device.") else i18n.tr("No unique device identity; settings are unavailable."))
        else
            i18n.tr("No pointer devices connected."),
    };
}

fn buildSelector(s: *Section, row_count: *usize) ?*Pointer {
    enumerate(s);
    const pointer = if (s.selected_id) |id| Pointer.find(s.input, id) else null;
    const index = if (s.selected_id) |id| std.mem.indexOfScalar(u64, s.device_ids, id) else null;
    const identity = if (pointer) |p| p.persistentId() else null;
    s.selector_header_children = .{
        fgLabel(i18n.tr("Pointer device")),
        .{ .name = "pointer_reset", .kind = .{ .button = .{
            .label = i18n.tr("Reset to defaults"),
            .owner = s,
            .id = if (pointer) |p| @intCast(p.id) else 0,
            .on_click = &onResetDevice,
            .state = if (config.input_device.hasOverrides(s.input.server.config.input_devices, identity)) .idle else .disabled,
        } }, .height = .{ .fixed = 32 } },
    };
    s.selector_children = .{
        row(&s.selector_header_children),
        .{
            .name = "pointer_device",
            .kind = .{
                .select = .{
                    .labels = s.device_labels,
                    .icons = s.device_icons,
                    // Also invalidate an open menu when replacement devices happen
                    // to reuse the same labels and event numbers.
                    .id = @intCast(std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(s.device_ids))),
                    .selected = index,
                    .disabled = s.device_ids.len == 0,
                    .placeholder = i18n.tr("No devices"),
                    .owner = s,
                    .on_change = &onDevicePicked,
                },
            },
            .width = .{ .percent = 1 },
        },
        dimLabel(statusText(s, pointer)),
        .{ .name = "pointer_show_all", .kind = .{ .checkbox = .{
            .label = i18n.tr("Show all devices"),
            .checked = s.show_all_devices,
            .owner = s,
            .on_change = &onShowAllDevices,
        } } },
    };
    layout.appendRow(&s.row_storage, row_count, .{ .kind = .container, .direction = .column, .gap = 8, .children = &s.selector_children });
    return pointer;
}

fn onShowAllDevices(owner: ?*anyopaque, _: usize, on: bool) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    s.show_all_devices = on;
    refresh(s);
}

fn onDevicePicked(owner: ?*anyopaque, generation: usize, index: usize) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    if (generation != std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(s.device_ids))) return;
    if (index >= s.device_ids.len) return;
    const id = s.device_ids[index];
    if (Pointer.find(s.input, id) == null) return refresh(s);
    s.selected_id = id;
    s.status = .none;
    refresh(s);
}

fn originLabel(s: *Section, pointer: ?*Pointer, comptime key: []const u8, supported: bool) Widget {
    const identity = if (pointer) |p| p.persistentId() else null;
    const custom = config.input_device.isOverridden(s.input.server.config.input_devices, identity, key);
    var label = dimLabel(if (!supported) i18n.tr("Not supported") else if (custom) i18n.tr("Custom") else i18n.tr("Default"));
    label.name = key ++ "_origin";
    label.kind.text.font_size = 11;
    return label;
}

fn markCustom(s: *Section, comptime key: []const u8) void {
    const label = if (comptime std.mem.eql(u8, key, "pointer_speed")) &s.speed_label_children[1] else blk: {
        inline for (bool_keys, 0..) |candidate, i| {
            if (comptime std.mem.eql(u8, candidate, key)) break :blk &s.bool_label_children[i][1];
        }
        unreachable;
    };
    label.kind.text.content = i18n.tr("Custom");
    label.markDirty();
    s.selector_header_children[1].kind.button.state = .idle;
    s.selector_header_children[1].markDirty();
}

fn buildSpeed(s: *Section, pointer: ?*Pointer, row_count: *usize) void {
    const speed = if (pointer) |p| libinput.getPointerSpeed(p.device) else null;
    const editable = if (pointer) |p| p.persistentId() != null else false;
    const value: f32 = if (speed) |v| @floatCast(v) else 0;
    const formatted = std.fmt.bufPrint(&s.speed_value_buf, "{d:.1}", .{value}) catch "?";
    s.speed_label_children = .{ fgLabel(i18n.tr("Pointer speed")), originLabel(s, pointer, "pointer_speed", speed != null) };
    s.speed_header_children = .{
        .{ .kind = .container, .direction = .column, .width = .{ .flex = 1 }, .gap = 4, .children = &s.speed_label_children },
        if (speed != null) ui_slider.valuePill(formatted, 13, panel.palette().dim) else dimLabel(""),
    };
    s.speed_group_children[0] = row(&s.speed_header_children);
    var count: usize = 1;
    if (editable and speed != null) {
        s.speed_group_children[1] = .{ .name = "pointer_speed", .kind = .{ .slider = .{
            .value = value,
            .min = -1,
            .max = 1,
            .step = default_speed_step,
            .owner = s,
            .id = @intCast(pointer.?.id),
            .on_change = &onSpeedChanged,
        } } };
        count = 2;
    } else s.speed_header_children[1].name = "pointer_speed";
    layout.appendRow(&s.row_storage, row_count, .{ .kind = .container, .direction = .column, .gap = 8, .children = s.speed_group_children[0..count] });
}

fn buildToggle(s: *Section, pointer: ?*Pointer, index: usize, comptime key: []const u8, label: []const u8, comptime getter: anytype, comptime setter: anytype) Widget {
    const value = if (pointer) |p| getter(p.device) else null;
    const editable = if (pointer) |p| p.persistentId() != null else false;
    s.bool_label_children[index] = .{ fgLabel(label), originLabel(s, pointer, key, value != null) };
    s.bool_row_children[index] = .{
        .{ .kind = .container, .direction = .column, .gap = 4, .children = &s.bool_label_children[index] },
        .{
            .name = key,
            .kind = .{
                .toggle = .{
                    .on = value orelse false,
                    .disabled = value == null or !editable,
                    .owner = s,
                    .id = if (pointer) |p| @intCast(p.id) else 0,
                    .on_change = &struct {
                        fn changed(owner: ?*anyopaque, id: usize, on: bool) void {
                            const section: *Section = @ptrCast(@alignCast(owner orelse return));
                            _ = changeDevice(section, id, key, on, getter, setter);
                            // A rejected setter must restore the switch from the
                            // backend. Successful changes keep its slide animation.
                            if (section.status != .none) refresh(section);
                        }
                    }.changed,
                },
            },
        },
    };
    return row(&s.bool_row_children[index]);
}

/// Prepare memory before touching hardware or disk. Only publish the new
/// record after both operations succeed, so hotplug and reload see one state.
fn changeDevice(s: *Section, id: usize, comptime key: []const u8, value: config.input_device.Value(key), comptime getter: anytype, comptime setter: anytype) bool {
    const pointer = selected(s, id) orelse {
        refresh(s);
        return false;
    };
    const identity = pointer.persistentId() orelse {
        s.status = .unavailable;
        refresh(s);
        return false;
    };
    const previous = getter(pointer.device) orelse {
        s.status = .unavailable;
        refresh(s);
        return false;
    };
    const server = s.input.server;
    const prepared = config.input_device.prepareSet(&server.config, identity, key, value) catch {
        s.status = .apply_failed;
        refresh(s);
        return false;
    };
    const result = setter(pointer.device, value);
    if (result != .applied) {
        s.status = if (result == .unsupported) .unavailable else .apply_failed;
        refresh(s);
        return false;
    }
    config.setting_save.saveInputDevice(gpa, server.io, server.config.path, identity, key, value) catch |err| {
        std.log.warn("could not save device setting '{s}': {}", .{ key, err });
        s.status = if (setter(pointer.device, previous) == .applied) .save_failed else .rollback_failed;
        refresh(s);
        return false;
    };
    prepared.commit(&server.config);
    markCustom(s, key);
    const clear_error = s.status != .none;
    s.status = .none;
    if (clear_error) refresh(s);
    return true;
}

const reset_fields = .{
    .{ "pointer_speed", libinput.getPointerSpeed, libinput.setPointerSpeed },
    .{ "natural_scroll", libinput.getNaturalScroll, libinput.setNaturalScroll },
    .{ "left_handed", libinput.getLeftHanded, libinput.setLeftHanded },
    .{ "tap_to_click", libinput.getTapToClick, libinput.setTapToClick },
    .{ "tap_drag", libinput.getTapDrag, libinput.setTapDrag },
    .{ "disable_while_typing", libinput.getDisableWhileTyping, libinput.setDisableWhileTyping },
};

const DeviceSnapshot = struct {
    pointer_speed: ?f64 = null,
    natural_scroll: ?bool = null,
    left_handed: ?bool = null,
    tap_to_click: ?bool = null,
    tap_drag: ?bool = null,
    disable_while_typing: ?bool = null,
};

fn restoreDevice(pointer: *Pointer, previous: DeviceSnapshot, changed: u8) bool {
    var restored = true;
    inline for (reset_fields, 0..) |field, i| {
        if (changed & (@as(u8, 1) << i) != 0) {
            if (field[2](pointer.device, @field(previous, field[0]).?) != .applied) restored = false;
        }
    }
    return restored;
}

fn onResetDevice(owner: ?*anyopaque, id: usize) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    const pointer = selected(s, id) orelse return refresh(s);
    const identity = pointer.persistentId() orelse return refresh(s);
    const server = s.input.server;
    if (!config.input_device.hasOverrides(server.config.input_devices, identity)) return refresh(s);
    const prepared = config.input_device.prepareReset(&server.config, identity) catch {
        s.status = .apply_failed;
        return refresh(s);
    };
    var previous: DeviceSnapshot = .{};
    inline for (reset_fields) |field| @field(previous, field[0]) = field[1](pointer.device);
    const defaults = config.input_device.resolve(server.config.input, &.{}, null, libinput.isTouchpad(pointer.device));
    var changed: u8 = 0;
    inline for (reset_fields, 0..) |field, i| {
        if (@field(previous, field[0])) |before| {
            const value = @field(defaults, field[0]);
            if (before != value) {
                if (field[2](pointer.device, value) != .applied) {
                    s.status = if (restoreDevice(pointer, previous, changed)) .reset_failed else .reset_restore_failed;
                    return refresh(s);
                }
                changed |= @as(u8, 1) << i;
            }
        }
    }
    config.setting_save.resetInputDevice(gpa, server.io, server.config.path, identity) catch |err| {
        std.log.warn("could not reset device settings: {}", .{err});
        s.status = if (restoreDevice(pointer, previous, changed)) .save_failed else .rollback_failed;
        return refresh(s);
    };
    prepared.commit(&server.config);
    s.status = .none;
    refresh(s);
}

fn onSpeedChanged(owner: ?*anyopaque, id: usize, value: f32) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    if (!changeDevice(s, id, "pointer_speed", value, libinput.getPointerSpeed, libinput.setPointerSpeed)) return;
    s.speed_header_children[1].kind.text.content = std.fmt.bufPrint(&s.speed_value_buf, "{d:.1}", .{value}) catch "?";
    s.speed_header_children[1].markDirty();
}

fn indexOfNearest(values: []const f32, v: f32) usize {
    var best: usize = 0;
    var best_d = @abs(values[0] - v);
    for (values, 0..) |candidate, i| {
        const d = @abs(candidate - v);
        if (d < best_d) {
            best = i;
            best_d = d;
        }
    }
    return best;
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
    var row_count: usize = 0;
    const pointer = buildSelector(out, &row_count);
    loadKeyboardLayouts(out);
    buildSpeed(out, pointer, &row_count);
    out.bool_rows = .{
        buildToggle(out, pointer, 0, "natural_scroll", i18n.tr("Natural scroll"), libinput.getNaturalScroll, libinput.setNaturalScroll),
        buildToggle(out, pointer, 1, "left_handed", i18n.tr("Left-handed mode"), libinput.getLeftHanded, libinput.setLeftHanded),
        buildToggle(out, pointer, 2, "tap_to_click", i18n.tr("Tap to click"), libinput.getTapToClick, libinput.setTapToClick),
        buildToggle(out, pointer, 3, "tap_drag", i18n.tr("Tap and drag"), libinput.getTapDrag, libinput.setTapDrag),
        buildToggle(out, pointer, 4, "disable_while_typing", i18n.tr("Disable while typing"), libinput.getDisableWhileTyping, libinput.setDisableWhileTyping),
    };
    layout.appendRow(&out.row_storage, &row_count, .{ .kind = .container, .direction = .column, .gap = 10, .children = &out.bool_rows });
    const repeat = firstKeyboardRepeat(input);

    out.pan_speed_row_children = .{
        fgLabel(i18n.tr("Pan speed")),
        .{
            .name = "pan_speed",
            .kind = .{ .segmented = .{ .labels = &pan_speed_labels, .selected = indexOfNearest(&pan_speed_values, input.server.config.input.pan_speed), .owner = out, .on_change = &onPanSpeedChanged } },
            .width = .{ .fixed = pan_speed_segmented_width },
        },
    };
    const pan_speed_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.pan_speed_row_children };
    layout.appendRow(&out.row_storage, &row_count, pan_speed_row);

    out.layout_row_children = .{
        fgLabel(i18n.tr("Language")),
        .{
            .name = "keyboard_language",
            .kind = .{ .select = .{
                .labels = out.keyboard_layout_labels,
                .selected = keyboardLayoutIndex(input.server.config.input, out.keyboard_layouts),
                .disabled = out.keyboard_layouts.len == 0,
                .placeholder = if (out.keyboard_layouts.len == 0)
                    i18n.tr("Keyboard layouts unavailable")
                else
                    i18n.tr("Custom (config file)"),
                .owner = out,
                .on_change = &onKeyboardLayoutPicked,
            } },
            .width = .{ .fixed = 220 },
        },
    };
    const layout_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.layout_row_children };
    layout.appendRow(&out.row_storage, &row_count, layout_row);

    out.delay_row_children = .{
        fgLabel(i18n.tr("Repeat delay")),
        .{ .name = "repeat_delay", .kind = .{ .stepper = .{ .value = repeat.delay, .min = 100, .max = 2000, .step = default_delay_step, .unit = "ms", .owner = out, .on_change = &onRepeatDelayChanged } } },
    };
    const delay_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.delay_row_children };
    layout.appendRow(&out.row_storage, &row_count, delay_row);

    out.rate_row_children = .{
        fgLabel(i18n.tr("Repeat rate")),
        .{ .name = "repeat_rate", .kind = .{ .stepper = .{ .value = repeat.rate, .min = 1, .max = 100, .step = default_rate_step, .unit = "/s", .owner = out, .on_change = &onRepeatRateChanged } } },
    };
    const rate_row: Widget = .{ .kind = .container, .direction = .row, .justify = .space_between, .@"align" = .center, .children = &out.rate_row_children };
    layout.appendRow(&out.row_storage, &row_count, rate_row);

    out.row_count = row_count;
    const pal = panel.palette();
    out.top_children = .{
        .{ .kind = .{ .text = .{ .content = i18n.tr("INPUT"), .font_size = 12, .weight = 700, .color = pal.dim } } },
        .{ .name = "input", .kind = .container, .direction = .column, .gap = 12, .children = out.row_storage[0..row_count] },
    };
    out.root = .{ .name = "input", .kind = .container, .direction = .column, .gap = 8, .children = &out.top_children };
}

// Only the file is written here: the reload diffs it against the live config
// and recompiles the keymap on every keyboard (`config_runtime/apply.zig`).
fn onKeyboardLayoutPicked(owner: ?*anyopaque, _: usize, index: usize) void {
    const s: *Section = @ptrCast(@alignCast(owner orelse return));
    if (index >= s.keyboard_layouts.len) return;

    const server = s.input.server;
    const choice = s.keyboard_layouts[index];
    if (std.mem.eql(u8, server.config.input.xkb_layout, choice.name)) return;

    const save = @import("config").setting_save;
    save.saveInput(gpa, server.io, server.config.path, "xkb_layout", choice.name) catch |err| {
        std.log.warn("could not save keyboard layout: {}", .{err});
        return;
    };
    // Variants belong to a specific base layout. Do not carry one over when
    // the user selects a different language/layout.
    save.saveInput(gpa, server.io, server.config.path, "xkb_variant", "") catch |err| {
        std.log.warn("could not clear keyboard variant: {}", .{err});
    };
    @import("../../config_runtime/watcher.zig").reloadConfig(server);
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
