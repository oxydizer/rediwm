//! IPC widget trees: walking, hit points, taskbar and window nodes, and widget resolution.

const std = @import("std");
const Server = @import("../Server.zig");
const Toplevel = @import("../Toplevel.zig");
const protocol = @import("protocol.zig");
const Taskbar = @import("../Taskbar.zig");
const chrome = @import("../chrome.zig");
const ui = @import("ui");
const taskbar_items = @import("config").taskbar_items;
const ClipRect = @import("handlers_panels.zig").ClipRect;
const panel_registry = @import("handlers_panels.zig").panel_registry;
const findToplevelById = @import("handlers_data.zig").findToplevelById;
const findFocusedToplevel = @import("handlers_data.zig").findFocusedToplevel;

fn widgetTextWidth(w: *const ui.layout.Widget, label: []const u8) f64 {
    return switch (w.kind) {
        .text => |style| if (style.sensitive) 0 else ui.measure.textNatural(label, style.family, style.weight, style.font_size).w,
        .button => |data| if (data.icon != null) 0 else ui.measure.textNatural(label, .sans, 600, ui.widgets.button.metrics(ui.widgets.button.optionsOf(data).size, ui.theme.global).font_size).w,
        .select, .segmented => ui.measure.textNatural(label, .sans, 600, ui.theme.global.font_size).w,
        else => ui.measure.textNatural(label, .sans, 400, ui.theme.global.font_size).w,
    };
}

pub fn walkWidgetTree(
    w: *ui.layout.Widget,
    list: *std.ArrayList(protocol.WidgetNodeData),
    allocator: std.mem.Allocator,
    ancestor_path: []const u8,
    parent_index: ?usize,
    panel_x: i32,
    panel_y: i32,
    scroll_clip: ?ClipRect,
) !void {
    var label: ?[]const u8 = null;
    var semantic_id: ?[]const u8 = null;
    var is_focused = false;
    var is_disabled = false;
    var checked: ?bool = null;
    var on: ?bool = null;
    var value: ?f64 = null;
    var min: ?f64 = null;
    var max: ?f64 = null;
    var step: ?f64 = null;
    var selected_index: ?usize = null;
    var open: ?bool = null;
    var selected: ?bool = null;
    var text_length: ?usize = null;
    var scroll_offset: ?f64 = null;
    var content_size: ?f64 = null;

    switch (w.kind) {
        .button => |b| {
            label = b.label;
            semantic_id = try std.fmt.allocPrint(allocator, "btn_{s}", .{b.label});
            is_disabled = b.state == .disabled;
        },
        .text => |t| {
            label = t.content;
        },
        .row => |r| {
            semantic_id = try std.fmt.allocPrint(allocator, "row_{d}", .{r.id});
            is_focused = r.selected;
            is_disabled = r.state == .disabled;
            selected = r.selected;
        },
        .checkbox => |cb| {
            is_focused = ui.input.isFocused(w);
            is_disabled = cb.disabled;
            label = cb.label;
            semantic_id = try std.fmt.allocPrint(allocator, "cb_{s}", .{cb.label});
            checked = cb.checked;
            on = cb.checked;
        },
        .toggle => |tg| {
            is_disabled = tg.disabled;
            checked = tg.on;
            on = tg.on;
        },
        .slider => |s| {
            value = s.value;
            min = s.min;
            max = s.max;
            step = s.step;
        },
        .stepper => |st| {
            value = st.value;
            min = st.min;
            max = st.max;
            step = st.step;
        },
        .select => |s| {
            is_disabled = s.disabled;
            selected_index = s.selected;
            open = s.open;
        },
        .segmented => |seg| {
            selected_index = seg.selected;
        },
        .swatch => |sw| {
            selected = sw.selected;
        },
        .text_input => |ti| {
            is_focused = ui.input.isFocused(w);
            label = ti.placeholder;
            semantic_id = "text_input";
            text_length = ti.value.len;
        },
        // Expose focus for automation, never a secret's value or length.
        .secret_input => is_focused = ui.input.isFocused(w),
        .scroll_container => |sc| {
            scroll_offset = sc.scroll_offset;
            content_size = sc.content_size;
        },
        .arrangement => |a| {
            selected_index = a.selected;
        },
        else => {},
    }

    var path: ?[]const u8 = null;
    var child_ancestor_path = ancestor_path;
    if (w.name) |n| {
        if (ancestor_path.len > 0) {
            path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ancestor_path, n });
        } else {
            path = try allocator.dupe(u8, n);
        }
        child_ancestor_path = path.?;
    }

    const current_index = list.items.len;

    var visible = true;
    var clipped = false;
    if (scroll_clip) |clip| {
        const left = @max(w.computed_x, clip.x);
        const right = @min(w.computed_x + w.computed_width, clip.x + clip.width);
        const top = @max(w.computed_y, clip.y);
        const bottom = @min(w.computed_y + w.computed_height, clip.y + clip.height);
        const intersects = (right > left and bottom > top);
        if (!intersects) {
            visible = false;
            clipped = true;
        } else {
            visible = true;
            const fully_inside = (w.computed_x >= clip.x and
                w.computed_x + w.computed_width <= clip.x + clip.width and
                w.computed_y >= clip.y and
                w.computed_y + w.computed_height <= clip.y + clip.height);
            clipped = !fully_inside;
        }
    } else {
        visible = (w.computed_width > 0 and w.computed_height > 0);
        clipped = false;
    }

    try list.append(allocator, .{
        .id = @intFromPtr(w),
        .role = @tagName(w.kind),
        .name = w.name,
        .path = path,
        .parent_index = parent_index,
        .semantic_id = semantic_id,
        .label = label,
        .box = .{
            .x = @intFromFloat(w.computed_x),
            .y = @intFromFloat(w.computed_y),
            .width = @intFromFloat(w.computed_width),
            .height = @intFromFloat(w.computed_height),
        },
        .global_box = .{
            .x = panel_x + @as(i32, @intFromFloat(w.computed_x)),
            .y = panel_y + @as(i32, @intFromFloat(w.computed_y)),
            .width = @intFromFloat(w.computed_width),
            .height = @intFromFloat(w.computed_height),
        },
        .is_focused = is_focused,
        .is_disabled = is_disabled,
        .visible = visible,
        .clipped = clipped,
        .checked = checked,
        .on = on,
        .value = value,
        .min = min,
        .max = max,
        .step = step,
        .selected_index = selected_index,
        .open = open,
        .selected = selected,
        .text_length = text_length,
        .text_width = if (label) |value_text| widgetTextWidth(w, value_text) else null,
        .scroll_offset = scroll_offset,
        .content_size = content_size,
    });

    // Screens in an arrangement are painted, not child widgets: report each
    // as its own node so tests can find and drag them.
    if (w.kind == .arrangement) {
        for (w.kind.arrangement.items, 0..) |*item, i| {
            const tile = ui.widgets.arrangement.tileRect(w, i);
            const tile_box: protocol.RectData = .{
                .x = @intFromFloat(@round(tile.x)),
                .y = @intFromFloat(@round(tile.y)),
                .width = @intFromFloat(@round(tile.w)),
                .height = @intFromFloat(@round(tile.h)),
            };
            try list.append(allocator, .{
                .id = @intFromPtr(item),
                .role = "arrangement_item",
                .name = item.label,
                .path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ child_ancestor_path, item.label }),
                .parent_index = current_index,
                .label = item.label,
                .box = tile_box,
                .global_box = .{ .x = panel_x + tile_box.x, .y = panel_y + tile_box.y, .width = tile_box.width, .height = tile_box.height },
                .visible = visible,
                .clipped = clipped,
                .selected = w.kind.arrangement.selected == i,
            });
        }
    }

    const child_clip: ?ClipRect = if (w.kind == .scroll_container) blk: {
        const my_clip = ClipRect{
            .x = w.computed_x,
            .y = w.computed_y,
            .width = w.computed_width,
            .height = w.computed_height,
        };
        break :blk if (scroll_clip) |sc| sc.intersect(my_clip) else my_clip;
    } else scroll_clip;

    for (w.children) |*child| {
        try walkWidgetTree(child, list, allocator, child_ancestor_path, current_index, panel_x, panel_y, child_clip);
    }
}

pub fn computeTargetPoint(gbox: protocol.RectData, at: protocol.FractionCoord) protocol.PointData {
    const at_x = std.math.clamp(at.x, 0.0, 1.0);
    const at_y = std.math.clamp(at.y, 0.0, 1.0);

    const gx: f64 = @floatFromInt(gbox.x);
    const gy: f64 = @floatFromInt(gbox.y);
    const gw: f64 = @floatFromInt(gbox.width);
    const gh: f64 = @floatFromInt(gbox.height);

    const target_x = @as(i32, @intFromFloat(@round(gx + gw * at_x)));
    const target_y = @as(i32, @intFromFloat(@round(gy + gh * at_y)));

    return .{ .x = target_x, .y = target_y };
}

pub fn findWidgetInNodes(
    nodes: []const protocol.WidgetNodeData,
    target_path: []const u8,
    subpath: []const u8,
) ?protocol.WidgetNodeData {
    // 1. Try matching full path first
    for (nodes) |node| {
        if (node.path) |p| {
            if (std.mem.eql(u8, p, target_path)) return node;
        }
    }
    // 2. Try matching widget name (either target_path or subpath)
    for (nodes) |node| {
        if (node.name) |n| {
            if (std.mem.eql(u8, n, target_path) or std.mem.eql(u8, n, subpath)) return node;
        }
    }
    // 3. Try matching semantic_id (either target_path or subpath)
    for (nodes) |node| {
        if (node.semantic_id) |s| {
            if (std.mem.eql(u8, s, target_path) or std.mem.eql(u8, s, subpath)) return node;
        }
    }
    // 4. Try matching label (either target_path or subpath)
    for (nodes) |node| {
        if (node.label) |l| {
            if (std.mem.eql(u8, l, target_path) or std.mem.eql(u8, l, subpath)) return node;
        }
    }
    return null;
}

pub const ResolveWidgetOutcome = union(enum) {
    ok: protocol.WidgetNodeData,
    panel_not_open,
    not_found,
    not_visible,
    disabled,
};

pub fn buildTaskbarWidgetTree(
    server: *Server,
    bar: *Taskbar,
    widgets: *std.ArrayList(protocol.WidgetNodeData),
    allocator: std.mem.Allocator,
) !void {
    // 0: Root taskbar
    try widgets.append(allocator, .{
        .id = 1,
        .parent_index = null,
        .role = "taskbar",
        .name = "taskbar",
        .path = "taskbar",
        .box = .{ .x = 0, .y = 0, .width = bar.box.width, .height = bar.box.height },
        .global_box = .{ .x = bar.box.x, .y = bar.box.y, .width = bar.box.width, .height = bar.box.height },
        .visible = true,
        .is_disabled = false,
    });

    // 1: Start button
    const sbox = bar.startButtonBox();
    try widgets.append(allocator, .{
        .id = 2,
        .parent_index = 0,
        .role = "button",
        .name = "start",
        .path = "taskbar/start",
        .semantic_id = "btn_Start",
        .label = "Start",
        .box = .{ .x = sbox.x - bar.box.x, .y = sbox.y - bar.box.y, .width = sbox.width, .height = sbox.height },
        .global_box = .{ .x = sbox.x, .y = sbox.y, .width = sbox.width, .height = sbox.height },
        .visible = server.config.compositor.taskbar_items.shown(.start),
        .is_disabled = false,
    });

    // 2: Clock (if shown)
    if (bar.itemBox(.clock)) |cbox| {
        try widgets.append(allocator, .{
            .id = widgets.items.len + 1,
            .parent_index = 0,
            .role = "text",
            .name = "clock",
            .path = "taskbar/clock",
            .semantic_id = "clock",
            .label = "Clock",
            .box = .{ .x = cbox.x - bar.box.x, .y = cbox.y - bar.box.y, .width = cbox.width, .height = cbox.height },
            .global_box = .{ .x = cbox.x, .y = cbox.y, .width = cbox.width, .height = cbox.height },
            .visible = true,
            .is_disabled = false,
        });
    }

    // 3: Chips (taskbar/window/<id>)
    const focused_tl = findFocusedToplevel(server);
    // Same geometry as Taskbar.hitTest: animated x, themed chip height.
    const now_ms = Taskbar.nowMs();
    const ch = Taskbar.chipSize();
    for (bar.chips.items) |chip| {
        const cx = @as(i32, @intFromFloat(@round(chip.renderX(now_ms))));
        const cy = @divTrunc(bar.box.height - ch, 2);
        const cw = @as(i32, @intFromFloat(chip.width));

        const path_str = try std.fmt.allocPrint(allocator, "taskbar/window/{d}", .{chip.toplevel.id});
        const name_str = try std.fmt.allocPrint(allocator, "window/{d}", .{chip.toplevel.id});
        const sem_str = try std.fmt.allocPrint(allocator, "chip_{d}", .{chip.toplevel.id});
        const title_str = try allocator.dupe(u8, chip.toplevel.title());

        try widgets.append(allocator, .{
            .id = widgets.items.len + 1,
            .parent_index = 0,
            .role = "chip",
            .name = name_str,
            .path = path_str,
            .semantic_id = sem_str,
            .label = title_str,
            .box = .{ .x = cx, .y = cy, .width = cw, .height = ch },
            .global_box = .{ .x = bar.box.x + cx, .y = bar.box.y + cy, .width = cw, .height = ch },
            .visible = true,
            .is_disabled = false,
            .is_focused = (focused_tl == chip.toplevel),
        });
    }

    // 4: Tray items (taskbar/tray/<n>)
    if (bar.itemBox(.volume)) |vbox| {
        try widgets.append(allocator, .{
            .id = widgets.items.len + 1,
            .parent_index = 0,
            .role = "button",
            .name = "tray/0",
            .path = "taskbar/tray/0",
            .semantic_id = "tray_volume",
            .label = "Volume",
            .box = .{ .x = vbox.x - bar.box.x, .y = vbox.y - bar.box.y, .width = vbox.width, .height = vbox.height },
            .global_box = .{ .x = vbox.x, .y = vbox.y, .width = vbox.width, .height = vbox.height },
            .visible = true,
            .is_disabled = false,
        });
    }
    if (bar.itemBox(.wifi)) |nbox| {
        try widgets.append(allocator, .{
            .id = widgets.items.len + 1,
            .parent_index = 0,
            .role = "button",
            .name = "tray/1",
            .path = "taskbar/tray/1",
            .semantic_id = "tray_network",
            .label = "Wi-Fi",
            .box = .{ .x = nbox.x - bar.box.x, .y = nbox.y - bar.box.y, .width = nbox.width, .height = nbox.height },
            .global_box = .{ .x = nbox.x, .y = nbox.y, .width = nbox.width, .height = nbox.height },
            .visible = true,
            .is_disabled = false,
        });
    }

    if (bar.itemBox(.wired)) |wbox| {
        try widgets.append(allocator, .{
            .id = widgets.items.len + 1,
            .parent_index = 0,
            .role = "button",
            .name = "wired",
            .path = "taskbar/wired",
            .semantic_id = "tray_wired",
            .label = "Ethernet",
            .box = .{ .x = wbox.x - bar.box.x, .y = wbox.y - bar.box.y, .width = wbox.width, .height = wbox.height },
            .global_box = .{ .x = wbox.x, .y = wbox.y, .width = wbox.width, .height = wbox.height },
            .visible = true,
            .is_disabled = false,
        });
    }

    if (bar.itemBox(.input_source)) |source_box| {
        const label = if (server.input_sources) |sources| sources.activeLabel() else "";
        try widgets.append(allocator, .{
            .id = widgets.items.len + 1,
            .parent_index = 0,
            .role = "button",
            .name = "input_source",
            .path = "taskbar/input_source",
            .semantic_id = "tray_input_source",
            .label = try allocator.dupe(u8, label),
            .box = .{ .x = source_box.x - bar.box.x, .y = source_box.y - bar.box.y, .width = source_box.width, .height = source_box.height },
            .global_box = .{ .x = source_box.x, .y = source_box.y, .width = source_box.width, .height = source_box.height },
            .visible = true,
            .is_disabled = false,
        });
    }

    if (bar.itemBox(.power)) |pbox| {
        try widgets.append(allocator, .{
            .id = widgets.items.len + 1,
            .parent_index = 0,
            .role = "button",
            .name = "power",
            .path = "taskbar/power",
            .semantic_id = "btn_Power",
            .label = "Power",
            .box = .{ .x = pbox.x - bar.box.x, .y = pbox.y - bar.box.y, .width = pbox.width, .height = pbox.height },
            .global_box = .{ .x = pbox.x, .y = pbox.y, .width = pbox.width, .height = pbox.height },
            .visible = true,
            .is_disabled = false,
        });
    }

    // App tray items
    if (server.tray) |_| {
        for (0..bar.appTrayCount()) |i| {
            const abox = bar.appTrayBox(i);
            const path_str = try std.fmt.allocPrint(allocator, "taskbar/tray/{d}", .{2 + i});
            const name_str = try std.fmt.allocPrint(allocator, "tray/{d}", .{2 + i});
            try widgets.append(allocator, .{
                .id = widgets.items.len + 1,
                .parent_index = 0,
                .role = "button",
                .name = name_str,
                .path = path_str,
                .box = .{ .x = abox.x - bar.box.x, .y = abox.y - bar.box.y, .width = abox.width, .height = abox.height },
                .global_box = .{ .x = abox.x, .y = abox.y, .width = abox.width, .height = abox.height },
                .visible = true,
                .is_disabled = false,
            });
        }
    }
}

pub fn buildWindowWidgetTree(
    server: *Server,
    toplevel: *Toplevel,
    widgets: *std.ArrayList(protocol.WidgetNodeData),
    allocator: std.mem.Allocator,
) !void {
    const pt = toplevel.frameWorld(0, 0);
    const ww = @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_width)) * toplevel.worldScale())));
    const wh = @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.chrome_height)) * toplevel.worldScale())));
    const is_visible = @import("../window_tabs.zig").visible(toplevel) and toplevel.in_world;
    const is_focused = (findFocusedToplevel(server) == toplevel);

    // 0: Window root
    const win_path = try std.fmt.allocPrint(allocator, "window/{d}", .{toplevel.id});
    const title_str = try allocator.dupe(u8, toplevel.title());
    try widgets.append(allocator, .{
        .id = 1,
        .parent_index = null,
        .role = "window",
        .name = "window",
        .path = win_path,
        .label = title_str,
        .box = .{ .x = 0, .y = 0, .width = toplevel.chrome_width, .height = toplevel.chrome_height },
        .global_box = .{ .x = @as(i32, @intFromFloat(@round(pt.x))), .y = @as(i32, @intFromFloat(@round(pt.y))), .width = ww, .height = wh },
        .visible = is_visible,
        .is_focused = is_focused,
        .is_disabled = false,
    });

    if (!toplevel.hasServerDecorations()) return;

    // 1: Titlebar
    const tbh = @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(toplevel.titlebarHeight())) * toplevel.worldScale())));
    const tb_path = try std.fmt.allocPrint(allocator, "window/{d}/titlebar", .{toplevel.id});
    try widgets.append(allocator, .{
        .id = 2,
        .parent_index = 0,
        .role = "titlebar",
        .name = "titlebar",
        .path = tb_path,
        .label = try allocator.dupe(u8, toplevel.title()),
        .box = .{ .x = 0, .y = 0, .width = toplevel.chrome_width, .height = toplevel.titlebarHeight() },
        .global_box = .{ .x = @as(i32, @intFromFloat(@round(pt.x))), .y = @as(i32, @intFromFloat(@round(pt.y))), .width = ww, .height = tbh },
        .visible = is_visible,
        .is_focused = is_focused,
        .is_disabled = false,
    });

    // 2, 3, 4: Controls (close, maximize, minimize)
    const controls = [_]struct { name: []const u8, kind: chrome.ControlKind }{
        .{ .name = "close", .kind = .close },
        .{ .name = "maximize", .kind = .maximize },
        .{ .name = "minimize", .kind = .minimize },
    };

    for (controls) |c| {
        const crect = chrome.controlRectScaled(toplevel.chrome_width - toplevel.controlInsets().right, c.kind, toplevel.chromeDensity());
        const cpt = toplevel.frameWorld(@floatFromInt(crect.x), @floatFromInt(crect.y));
        const cw = @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(crect.w)) * toplevel.worldScale())));
        const ch = @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(crect.h)) * toplevel.worldScale())));

        const c_path = try std.fmt.allocPrint(allocator, "window/{d}/{s}", .{ toplevel.id, c.name });
        const c_sem = try std.fmt.allocPrint(allocator, "btn_{s}", .{c.name});

        try widgets.append(allocator, .{
            .id = widgets.items.len + 1,
            .parent_index = 0,
            .role = "button",
            .name = c.name,
            .path = c_path,
            .semantic_id = c_sem,
            .label = c.name,
            .box = .{ .x = crect.x, .y = crect.y, .width = crect.w, .height = crect.h },
            .global_box = .{ .x = @as(i32, @intFromFloat(@round(cpt.x))), .y = @as(i32, @intFromFloat(@round(cpt.y))), .width = cw, .height = ch },
            .visible = is_visible,
            .is_disabled = false,
            .is_focused = is_focused,
        });
    }
    var tab_storage: [@import("../window_tabs.zig").max_tabs]@import("../chrome_tabs.zig").Tab = undefined;
    const strip = toplevel.tabStrip(&tab_storage);
    if (strip.tabs.len > 0) {
        const geom = @import("../chrome_tabs.zig").geometry(toplevel.chrome_width, toplevel.chromeDensity(), strip);
        for (strip.tabs[geom.first..][0..geom.count], 0..) |tab, i| {
            try appendTabWidget(toplevel, widgets, allocator, try std.fmt.allocPrint(allocator, "tab/{d}", .{tab.id}), tab.title, geom.tab(i), is_visible, tab.active, false);
            try appendTabWidget(toplevel, widgets, allocator, try std.fmt.allocPrint(allocator, "tab/{d}/close", .{tab.id}), "Close tab", geom.close(i), is_visible, false, false);
        }
        try appendTabWidget(toplevel, widgets, allocator, "tab_new", "New tab", geom.plus, is_visible, false, strip.notice == .opening);
        if (geom.previous) |rect| try appendTabWidget(toplevel, widgets, allocator, "tab_previous", "Previous tab", rect, is_visible, false, false);
        if (geom.next) |rect| try appendTabWidget(toplevel, widgets, allocator, "tab_next", "Next tab", rect, is_visible, false, false);
    }
}

pub fn appendTabWidget(top: *Toplevel, widgets: *std.ArrayList(protocol.WidgetNodeData), a: std.mem.Allocator, name: []const u8, label: []const u8, rect: @import("ui").widgets.button.Rect, visible: bool, selected: bool, disabled: bool) !void {
    const point = top.frameWorld(rect.x, rect.y);
    try widgets.append(a, .{
        .id = widgets.items.len + 1,
        .parent_index = 1,
        .role = "button",
        .name = name,
        .path = try std.fmt.allocPrint(a, "window/{d}/{s}", .{ top.id, name }),
        .label = try a.dupe(u8, label),
        .box = .{ .x = @intFromFloat(@round(rect.x)), .y = @intFromFloat(@round(rect.y)), .width = @intFromFloat(@round(rect.w)), .height = @intFromFloat(@round(rect.h)) },
        .global_box = .{ .x = @intFromFloat(@round(point.x)), .y = @intFromFloat(@round(point.y)), .width = @intFromFloat(@round(rect.w * top.worldScale())), .height = @intFromFloat(@round(rect.h * top.worldScale())) },
        .visible = visible,
        .is_focused = selected,
        .is_disabled = disabled,
    });
}

pub fn findVirtualWidgetNode(
    server: *Server,
    path: []const u8,
    allocator: std.mem.Allocator,
) !?protocol.WidgetNodeData {
    const is_tb = std.mem.eql(u8, path, "taskbar") or std.mem.startsWith(u8, path, "taskbar/") or
        std.mem.startsWith(u8, path, "tray/") or std.mem.eql(u8, path, "start");
    if (is_tb) {
        var tb: ?*Taskbar = if (server.getDefaultOutput()) |out| out.taskbar else null;
        if (tb == null) {
            var it = server.outputs.iterator(.forward);
            while (it.next()) |out| {
                if (out.taskbar) |t| {
                    tb = t;
                    break;
                }
            }
        }
        const bar = tb orelse return null;
        var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
        defer widgets.deinit(allocator);
        try buildTaskbarWidgetTree(server, bar, &widgets, allocator);

        if (std.mem.eql(u8, path, "taskbar")) return widgets.items[0];
        const subpath = if (std.mem.startsWith(u8, path, "taskbar/"))
            path["taskbar/".len..]
        else
            path;
        for (widgets.items) |w| {
            if (w.path) |wp| {
                if (std.mem.eql(u8, wp, path)) return w;
            }
            if (w.name) |wn| {
                if (std.mem.eql(u8, wn, subpath)) return w;
            }
        }
        // Aliases
        if (std.mem.eql(u8, subpath, "start_button") or std.mem.eql(u8, subpath, "start")) {
            for (widgets.items) |w| {
                if (w.name != null and std.mem.eql(u8, w.name.?, "start")) return w;
            }
        }
        if (std.mem.eql(u8, subpath, "tray/volume") or std.mem.eql(u8, subpath, "tray/0")) {
            for (widgets.items) |w| {
                if (w.name != null and std.mem.eql(u8, w.name.?, "tray/0")) return w;
            }
        }
        if (std.mem.eql(u8, subpath, "tray/network") or std.mem.eql(u8, subpath, "tray/wifi") or std.mem.eql(u8, subpath, "tray/1")) {
            for (widgets.items) |w| {
                if (w.name != null and std.mem.eql(u8, w.name.?, "tray/1")) return w;
            }
        }
        return null;
    }

    if (std.mem.startsWith(u8, path, "window/") or std.mem.eql(u8, path, "window")) {
        var target_tl: ?*Toplevel = null;
        var control_str: ?[]const u8 = null;
        if (std.mem.startsWith(u8, path, "window/")) {
            const rest = path["window/".len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash_idx| {
                const id_str = rest[0..slash_idx];
                control_str = rest[slash_idx + 1 ..];
                if (std.fmt.parseInt(u64, id_str, 10)) |id| {
                    target_tl = findToplevelById(server, id);
                } else |_| return null;
            } else {
                if (std.fmt.parseInt(u64, rest, 10)) |id| {
                    target_tl = findToplevelById(server, id);
                } else |_| {
                    target_tl = findFocusedToplevel(server) orelse server.world.toplevels.first();
                    control_str = rest;
                }
            }
        } else {
            target_tl = findFocusedToplevel(server) orelse server.world.toplevels.first();
        }

        const toplevel = target_tl orelse return null;
        var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
        defer widgets.deinit(allocator);
        try buildWindowWidgetTree(server, toplevel, &widgets, allocator);

        if (control_str) |cname| {
            for (widgets.items) |w| {
                if (w.name) |wn| {
                    if (std.mem.eql(u8, wn, cname)) return w;
                }
            }
            return null;
        } else {
            return widgets.items[0];
        }
    }

    return null;
}

pub fn findWidgetNode(
    server: *Server,
    path: []const u8,
    allocator: std.mem.Allocator,
) !?protocol.WidgetNodeData {
    if (std.mem.eql(u8, path, "taskbar") or std.mem.startsWith(u8, path, "taskbar/") or
        std.mem.startsWith(u8, path, "tray/") or std.mem.eql(u8, path, "start") or
        std.mem.eql(u8, path, "window") or std.mem.startsWith(u8, path, "window/"))
    {
        return findVirtualWidgetNode(server, path, allocator);
    }

    const def_out = server.getDefaultOutput() orelse return null;

    if (std.mem.indexOfScalar(u8, path, '/')) |slash_idx| {
        const prefix = path[0..slash_idx];
        const subpath = path[slash_idx + 1 ..];

        for (panel_registry) |entry| {
            if (std.mem.eql(u8, entry.name, prefix)) {
                const resolved = entry.resolve(def_out) orelse return null;
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                defer widgets.deinit(allocator);
                try walkWidgetTree(resolved.root, &widgets, allocator, entry.name, null, resolved.box.x, resolved.box.y, null);

                return findWidgetInNodes(widgets.items, path, subpath);
            }
        }
        return null;
    } else {
        // Path has no slash. Check if path is a known panel name.
        for (panel_registry) |entry| {
            if (std.mem.eql(u8, entry.name, path)) {
                const resolved = entry.resolve(def_out) orelse return null;
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                defer widgets.deinit(allocator);
                try walkWidgetTree(resolved.root, &widgets, allocator, entry.name, null, resolved.box.x, resolved.box.y, null);

                if (findWidgetInNodes(widgets.items, path, path)) |matched| {
                    return matched;
                }
                if (widgets.items.len > 0) {
                    var root_node = widgets.items[0];
                    root_node.path = path;
                    root_node.name = path;
                    return root_node;
                }
                return null;
            }
        }

        // Otherwise search all currently open panels
        for (panel_registry) |entry| {
            if (entry.resolve(def_out)) |resolved| {
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                defer widgets.deinit(allocator);
                try walkWidgetTree(resolved.root, &widgets, allocator, entry.name, null, resolved.box.x, resolved.box.y, null);

                if (findWidgetInNodes(widgets.items, path, path)) |matched| {
                    return matched;
                }
            }
        }

        // Also search taskbar virtual widgets
        if (def_out.taskbar) |bar| {
            var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
            defer widgets.deinit(allocator);
            if (buildTaskbarWidgetTree(server, bar, &widgets, allocator)) |_| {
                if (findWidgetInNodes(widgets.items, path, path)) |matched| {
                    return matched;
                }
            } else |_| {}
        }

        return null;
    }
}

pub fn resolveWidget(
    server: *Server,
    path: []const u8,
    allocator: std.mem.Allocator,
) !ResolveWidgetOutcome {
    if (std.mem.eql(u8, path, "taskbar") or std.mem.startsWith(u8, path, "taskbar/") or
        std.mem.startsWith(u8, path, "tray/") or std.mem.eql(u8, path, "start") or
        std.mem.eql(u8, path, "window") or std.mem.startsWith(u8, path, "window/"))
    {
        const def_out = server.getDefaultOutput();
        if (std.mem.startsWith(u8, path, "taskbar") or std.mem.startsWith(u8, path, "tray/") or std.mem.eql(u8, path, "start")) {
            if (def_out == null or def_out.?.taskbar == null) return .panel_not_open;
        }
        const node_opt = try findVirtualWidgetNode(server, path, allocator);
        const node = node_opt orelse return .not_found;
        if (!node.visible) return .not_visible;
        if (node.is_disabled) return .disabled;
        return .{ .ok = node };
    }

    const def_out = server.getDefaultOutput() orelse return .panel_not_open;

    if (std.mem.indexOfScalar(u8, path, '/')) |slash_idx| {
        const prefix = path[0..slash_idx];
        const subpath = path[slash_idx + 1 ..];

        for (panel_registry) |entry| {
            if (std.mem.eql(u8, entry.name, prefix)) {
                const resolved = entry.resolve(def_out) orelse return .panel_not_open;
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                defer widgets.deinit(allocator);
                try walkWidgetTree(resolved.root, &widgets, allocator, entry.name, null, resolved.box.x, resolved.box.y, null);

                const matched = findWidgetInNodes(widgets.items, path, subpath) orelse return .not_found;
                if (!matched.visible) return .not_visible;
                if (matched.is_disabled) return .disabled;
                return .{ .ok = matched };
            }
        }
        return .not_found;
    } else {
        // Path has no slash. Check if path is a known panel name.
        for (panel_registry) |entry| {
            if (std.mem.eql(u8, entry.name, path)) {
                const resolved = entry.resolve(def_out) orelse return .panel_not_open;
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                defer widgets.deinit(allocator);
                try walkWidgetTree(resolved.root, &widgets, allocator, entry.name, null, resolved.box.x, resolved.box.y, null);

                if (findWidgetInNodes(widgets.items, path, path)) |matched| {
                    if (!matched.visible) return .not_visible;
                    if (matched.is_disabled) return .disabled;
                    return .{ .ok = matched };
                }
                if (widgets.items.len > 0) {
                    var root_node = widgets.items[0];
                    root_node.path = path;
                    root_node.name = path;
                    if (!root_node.visible) return .not_visible;
                    if (root_node.is_disabled) return .disabled;
                    return .{ .ok = root_node };
                }
                return .not_found;
            }
        }

        // Otherwise search all currently open panels
        for (panel_registry) |entry| {
            if (entry.resolve(def_out)) |resolved| {
                var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
                defer widgets.deinit(allocator);
                try walkWidgetTree(resolved.root, &widgets, allocator, entry.name, null, resolved.box.x, resolved.box.y, null);

                if (findWidgetInNodes(widgets.items, path, path)) |matched| {
                    if (!matched.visible) return .not_visible;
                    if (matched.is_disabled) return .disabled;
                    return .{ .ok = matched };
                }
            }
        }

        // Also search taskbar virtual widgets
        if (def_out.taskbar) |bar| {
            var widgets = std.ArrayList(protocol.WidgetNodeData).empty;
            defer widgets.deinit(allocator);
            if (buildTaskbarWidgetTree(server, bar, &widgets, allocator)) |_| {
                if (findWidgetInNodes(widgets.items, path, path)) |matched| {
                    if (!matched.visible) return .not_visible;
                    if (matched.is_disabled) return .disabled;
                    return .{ .ok = matched };
                }
            } else |_| {}
        }

        return .not_found;
    }
}
