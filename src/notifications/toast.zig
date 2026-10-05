//! A single interactive notification toast card.
//! Rendered using the ui/ widget engine into a PanelBuffer scene node.
const std = @import("std");
const wlr = @import("wlroots");

const anim = @import("ui").anim;
const panel_buffer = @import("../panel_buffer.zig");
const panel_paint = @import("../panel_paint.zig");
const panel_present = @import("../panel_present.zig");
const scene_data = @import("../scene_data.zig");
const text_mod = @import("ui").text;
const ui = @import("ui");
const theme = @import("ui").theme;
const icon_service_mod = @import("../icon_service.zig");
const image_mod = @import("image.zig");

const PanelBuffer = panel_buffer.PanelBuffer;
const Anim = anim.Anim;
const Widget = ui.layout.Widget;

pub const ActionPair = struct {
    key: []const u8,
    label: []const u8,
};

pub const Toast = struct {
    arena: std.heap.ArenaAllocator,
    id: u32,
    app_name: []const u8,
    app_icon: []const u8,
    summary: []const u8,
    body: []const u8,
    actions: []ActionPair,
    urgency: u8, // 0 = low, 1 = normal, 2 = critical
    resident: bool,
    transient: bool,
    expire_timeout_ms: i32,
    created_at_ms: i64,
    expire_at_ms: ?i64,
    paused: bool = false,
    hovered: bool = false,

    image: ?image_mod.DecodedImage = null,
    icon_id: ?u64 = null,
    icon_entry: ?icon_service_mod.Entry = null,

    buffer_node: *wlr.SceneBuffer,
    node_data: scene_data.SceneData = undefined,
    panel_box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    slide: Anim = .{},
    flip: Anim = .{},
    target_x: f32 = 0,
    target_y: f32 = 0,
    width: f32 = 480,
    age_buffer: [32]u8 = undefined,
    age_minute: i64 = -1,
    age_widget: ?*Widget = null,
    height: f32 = 0,

    closing: bool = false,
    close_reason: u32 = 1, // 1 = expired, 2 = dismissed by user, 3 = closed by call
    dirty: bool = true,
    button_clicked: bool = false,

    background: panel_paint.Background = .{},
    root: Widget = undefined,
    manager_ptr: ?*anyopaque = null,

    const slide_distance: f32 = 30;

    pub fn create(
        allocator: std.mem.Allocator,
        parent_tree: *wlr.SceneTree,
        manager_ptr: *anyopaque,
        id: u32,
        app_name: []const u8,
        app_icon: []const u8,
        summary: []const u8,
        body: []const u8,
        actions: []const ActionPair,
        urgency: u8,
        resident: bool,
        transient: bool,
        expire_timeout_ms: i32,
        now_ms: i64,
        image: ?image_mod.DecodedImage,
    ) !*Toast {
        const toast = try allocator.create(Toast);
        errdefer allocator.destroy(toast);

        const node = try parent_tree.createSceneBuffer(null);
        errdefer node.node.destroy();
        node.setFilterMode(.bilinear);

        toast.* = .{
            .arena = undefined,
            .id = id,
            .app_name = "",
            .app_icon = "",
            .summary = "",
            .body = "",
            .actions = &.{},
            .urgency = urgency,
            .resident = resident,
            .transient = transient,
            .expire_timeout_ms = expire_timeout_ms,
            .created_at_ms = now_ms,
            .expire_at_ms = if (urgency == 2 or expire_timeout_ms == 0)
                null
            else if (expire_timeout_ms > 0)
                now_ms + expire_timeout_ms
            else
                now_ms + 5000,
            .image = image,
            .buffer_node = node,
            .manager_ptr = manager_ptr,
        };

        toast.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer toast.arena.deinit();
        const a = toast.arena.allocator();

        toast.app_name = try a.dupe(u8, app_name);
        toast.app_icon = try a.dupe(u8, app_icon);
        toast.summary = try a.dupe(u8, summary);
        toast.body = try a.dupe(u8, body);
        toast.actions = try a.alloc(ActionPair, actions.len);

        for (actions, 0..) |act, i| {
            toast.actions[i] = .{
                .key = try a.dupe(u8, act.key),
                .label = try a.dupe(u8, act.label),
            };
        }

        toast.node_data = .{ .role = .{ .toast = toast } };
        scene_data.SceneData.attach(&toast.node_data, &node.node);

        toast.slide = .initCurve(0, 1, now_ms, anim.curveFor(.toast_slide));

        try toast.buildTree();
        return toast;
    }

    pub fn deinit(toast: *Toast, allocator: std.mem.Allocator) void {
        ui.input.reset();
        toast.background.deinit(allocator);
        toast.buffer_node.node.destroy();
        if (toast.image) |*img| img.deinit(allocator);
        toast.arena.deinit();
        allocator.destroy(toast);
    }

    pub fn updateContent(
        toast: *Toast,
        app_name: []const u8,
        app_icon: []const u8,
        summary: []const u8,
        body: []const u8,
        actions: []const ActionPair,
        urgency: u8,
        resident: bool,
        transient: bool,
        expire_timeout_ms: i32,
        now_ms: i64,
        image: ?image_mod.DecodedImage,
    ) !void {
        const a = toast.arena.allocator();
        toast.app_name = try a.dupe(u8, app_name);
        toast.app_icon = try a.dupe(u8, app_icon);
        toast.summary = try a.dupe(u8, summary);
        toast.body = try a.dupe(u8, body);
        toast.actions = try a.alloc(ActionPair, actions.len);
        for (actions, 0..) |act, i| {
            toast.actions[i] = .{
                .key = try a.dupe(u8, act.key),
                .label = try a.dupe(u8, act.label),
            };
        }
        toast.urgency = urgency;
        toast.resident = resident;
        toast.transient = transient;
        toast.expire_timeout_ms = expire_timeout_ms;
        toast.created_at_ms = now_ms;
        toast.expire_at_ms = if (urgency == 2 or expire_timeout_ms == 0)
            null
        else if (expire_timeout_ms > 0)
            now_ms + expire_timeout_ms
        else
            now_ms + 5000;

        if (toast.image) |*prev| prev.deinit(toast.arena.child_allocator);
        toast.image = image;

        try toast.buildTree();
        toast.dirty = true;
    }

    pub fn buildTree(toast: *Toast) !void {
        const a = toast.arena.allocator();
        const t = theme.global;

        // A generous icon tile beside the text, like the other charcoal shell panels.
        const tile_children = try a.alloc(Widget, 1);
        tile_children[0] = .{
            .kind = .{ .image = .{
                .pixels = if (toast.image) |img| img.pixels else if (toast.icon_entry) |entry| entry.pixels else null,
                .width = if (toast.image) |img| img.width else if (toast.icon_entry) |entry| entry.size else 0,
                .height = if (toast.image) |img| img.height else if (toast.icon_entry) |entry| entry.size else 0,
                .radius = 6,
                .fallback_icon = .notification,
            } },
            .width = .{ .fixed = 40 },
            .height = .{ .fixed = 40 },
        };
        const header = try a.alloc(Widget, 3);
        header[0] = .{
            .kind = .{ .text = .{
                .content = if (toast.summary.len > 0) toast.summary else if (toast.app_name.len > 0) toast.app_name else "Notification",
                .font_size = 15,
                .weight = 600,
                .color = t.window_fg,
            } },
            .width = .{ .flex = 1 },
        };
        header[1] = .{
            .kind = .{ .text = .{ .content = "now", .font_size = 11, .color = t.window_dim } },
            .width = .{ .fixed = 52 },
        };
        toast.age_widget = &header[1];
        toast.age_minute = -1;
        header[2] = .{
            .kind = .{ .button = .{
                .variant = .chrome,
                .icon = .close,
                .owner = toast,
                .id = 999999,
                .on_click = handleCloseClick,
            } },
            .width = .{ .fixed = 24 },
            .height = .{ .fixed = 24 },
        };
        const lines = try wrapTextLines(a, toast.body, @max(1, toast.width - 104), 13);
        var action_count: usize = 0;
        for (toast.actions) |act| {
            if (!std.mem.eql(u8, act.key, "default")) action_count += 1;
        }
        const content = try a.alloc(Widget, 1 + lines.len + @as(usize, if (action_count > 0) 1 else 0));
        content[0] = .{
            .kind = .container,
            .direction = .row,
            .gap = 6,
            .@"align" = .center,
            .width = .{ .percent = 1 },
            .children = header,
        };
        for (lines, 0..) |line, i| {
            content[i + 1] = .{
                .kind = .{ .text = .{ .content = line, .font_size = 13, .color = t.window_dim } },
                .width = .{ .percent = 1 },
            };
        }
        if (action_count > 0) {
            const buttons = try a.alloc(Widget, action_count);
            var j: usize = 0;
            for (toast.actions, 0..) |act, i| {
                if (std.mem.eql(u8, act.key, "default")) continue;
                buttons[j] = .{
                    .kind = .{ .button = .{ .label = act.label, .owner = toast, .id = i, .on_click = handleActionClick } },
                    .width = .{ .flex = 1 },
                };
                j += 1;
            }
            content[content.len - 1] = .{
                .kind = .container,
                .direction = .row,
                .gap = 8,
                .width = .{ .percent = 1 },
                .children = buttons,
            };
        }
        const root_children = try a.alloc(Widget, 2);
        root_children[0] = .{
            .kind = .{ .rect = .{ .color = t.surface, .radius = 10 } },
            .padding = ui.layout.Edges.all(8),
            .width = .{ .fixed = 56 },
            .height = .{ .fixed = 56 },
            .children = tile_children,
        };
        root_children[1] = .{
            .kind = .container,
            .direction = .column,
            .gap = 5,
            .width = .{ .flex = 1 },
            .children = content,
        };

        const border_col = if (toast.urgency == 2)
            [4]f32{ 0.95, 0.25, 0.25, 0.95 } // Urgent red
        else
            t.border;

        toast.root = .{
            .kind = .{ .rect = .{
                .color = t.window_bg,
                .radius = 12,
                .border_width = if (toast.urgency == 2) 2 else 1,
                .border_color = border_col,
            } },
            .direction = .row,
            .padding = ui.layout.Edges.all(16),
            .@"align" = .center,
            .gap = 16,
            .width = .{ .fixed = toast.width },
            .children = root_children,
        };
        toast.root.linkParents();
    }

    pub fn updateAge(toast: *Toast, now_ms: i64) void {
        const minute = @max(0, @divTrunc(now_ms - toast.created_at_ms, 60000));
        if (minute == toast.age_minute) return;
        const widget = toast.age_widget orelse return;
        widget.kind.text.content = if (minute == 0) "now" else std.fmt.bufPrint(&toast.age_buffer, "{d}{s} ago", .{
            if (minute < 60) minute else @divTrunc(minute, 60),
            if (minute < 60) "m" else "h",
        }) catch "earlier";
        toast.age_minute = minute;
        widget.markPaintDirty();
        toast.dirty = true;
    }

    pub fn relayout(toast: *Toast, width: f32) void {
        toast.width = width;
        toast.root.width = .{ .fixed = width };
        ui.measure.measure(&toast.root, width, 2000);
        ui.arrange.arrange(&toast.root, 0, 0, width, toast.root.computed_height);
        toast.height = toast.root.computed_height;
    }

    pub fn renderX(toast: Toast, now_ms: i64) f32 {
        const t = toast.slide.value(now_ms);
        return toast.target_x + (1 - t) * slide_distance;
    }

    pub fn renderY(toast: Toast, now_ms: i64) f32 {
        return toast.target_y + toast.flip.value(now_ms);
    }

    pub fn opacity(toast: Toast, now_ms: i64) f32 {
        return std.math.clamp(toast.slide.value(now_ms), 0, 1);
    }

    pub fn paintContent(toast: *Toast, scale: f32, allocator: std.mem.Allocator) void {
        const pw: i32 = @intFromFloat(@round(toast.width));
        const ph: i32 = @intFromFloat(@round(toast.height));
        if (pw <= 0 or ph <= 0) return;

        const buf = PanelBuffer.createUninitialized(pw, ph, scale) catch return;
        var renderer = ui.paint.Renderer.init(buf.pixels, buf.width, buf.height, scale);
        toast.background.paint(allocator, &toast.root, &renderer);

        toast.buffer_node.setBuffer(&buf.base);
        toast.buffer_node.setDestSize(pw, ph);
        buf.base.drop();
        toast.dirty = false;
    }

    pub fn beginClose(toast: *Toast, now_ms: i64, reason: u32) void {
        if (toast.closing) return;
        toast.closing = true;
        toast.close_reason = reason;
        toast.slide.retargetTo(now_ms, 0, anim.curveFor(.toast_slide));
    }

    pub fn finishedClosing(toast: Toast, now_ms: i64) bool {
        return toast.closing and toast.slide.settled(now_ms);
    }

    pub fn setHovered(toast: *Toast, hovered: bool, now_ms: i64) void {
        if (toast.hovered == hovered) return;
        toast.hovered = hovered;
        if (hovered) {
            toast.paused = true;
        } else {
            toast.paused = false;
            // Reset expire timeout when unhovering
            if (toast.expire_timeout_ms > 0 and toast.urgency != 2) {
                toast.expire_at_ms = now_ms + toast.expire_timeout_ms;
            }
        }
    }

    pub fn pointerMotion(toast: *Toast, sx: f64, sy: f64) void {
        ui.input.pointerMotion(&toast.root, @floatCast(sx), @floatCast(sy));
        toast.dirty = true;
    }

    pub fn pointerButtonDown(toast: *Toast, sx: f64, sy: f64) void {
        toast.button_clicked = false;
        ui.input.pointerButtonDown(&toast.root, @floatCast(sx), @floatCast(sy));
        toast.dirty = true;
    }

    pub fn pointerButtonUp(toast: *Toast, sx: f64, sy: f64) void {
        toast.button_clicked = false;
        ui.input.pointerButtonUp(&toast.root, @floatCast(sx), @floatCast(sy));
        toast.dirty = true;

        if (!toast.button_clicked) {
            // Click was on notification body outside action buttons
            if (toast.findAction("default")) |def_key| {
                toast.dispatchAction(def_key);
            } else {
                // Clicking body dismisses notification
                toast.dispatchClose(2);
            }
        }
    }

    fn findAction(toast: Toast, key: []const u8) ?[]const u8 {
        for (toast.actions) |act| {
            if (std.mem.eql(u8, act.key, key)) return act.key;
        }
        return null;
    }

    fn dispatchAction(toast: *Toast, key: []const u8) void {
        const mgr_opaque = toast.manager_ptr orelse return;
        const Manager = @import("manager.zig").Manager;
        const mgr: *Manager = @ptrCast(@alignCast(mgr_opaque));
        mgr.invokeAction(toast.id, key);
    }

    fn dispatchClose(toast: *Toast, reason: u32) void {
        const mgr_opaque = toast.manager_ptr orelse return;
        const Manager = @import("manager.zig").Manager;
        const mgr: *Manager = @ptrCast(@alignCast(mgr_opaque));
        mgr.closeNotification(toast.id, reason);
    }
};

fn handleCloseClick(owner: ?*anyopaque, _: usize) void {
    const toast: *Toast = @ptrCast(@alignCast(owner orelse return));
    toast.button_clicked = true;
    toast.dispatchClose(2); // 2 = dismissed by user
}

fn handleActionClick(owner: ?*anyopaque, action_idx: usize) void {
    const toast: *Toast = @ptrCast(@alignCast(owner orelse return));
    toast.button_clicked = true;
    if (action_idx < toast.actions.len) {
        toast.dispatchAction(toast.actions[action_idx].key);
    }
}

fn wrapTextLines(allocator: std.mem.Allocator, text: []const u8, max_width: f32, font_size: f32) ![][]const u8 {
    if (text.len == 0) return &[_][]const u8{};

    var list: std.ArrayList([]const u8) = .empty;
    var line_it = std.mem.splitScalar(u8, text, '\n');
    const space_w = text_mod.measureWidthF(" ", .manrope, font_size, 1.0) catch 4.0;

    while (line_it.next()) |para| {
        if (para.len == 0) {
            try list.append(allocator, "");
            continue;
        }

        var word_it = std.mem.splitScalar(u8, para, ' ');
        var current_line_start: usize = 0;
        var current_line_len: usize = 0;
        var current_w: f32 = 0;

        while (word_it.next()) |word| {
            if (word.len == 0) continue;
            const word_w = text_mod.measureWidthF(word, .manrope, font_size, 1.0) catch 0.0;

            if (current_line_len > 0 and current_w + space_w + word_w > max_width) {
                try list.append(allocator, para[current_line_start .. current_line_start + current_line_len]);
                const word_offset = @intFromPtr(word.ptr) - @intFromPtr(para.ptr);
                current_line_start = word_offset;
                current_line_len = word.len;
                current_w = word_w;
                if (list.items.len >= 4) break; // Limit to 4 lines
            } else {
                if (current_line_len == 0) {
                    current_line_start = @intFromPtr(word.ptr) - @intFromPtr(para.ptr);
                    current_line_len = word.len;
                    current_w = word_w;
                } else {
                    current_line_len = (@intFromPtr(word.ptr) + word.len) - (@intFromPtr(para.ptr) + current_line_start);
                    current_w += space_w + word_w;
                }
            }
        }

        if (current_line_len > 0 and list.items.len < 4) {
            try list.append(allocator, para[current_line_start .. current_line_start + current_line_len]);
        }
        if (list.items.len >= 4) break;
    }

    return list.toOwnedSlice(allocator);
}

test "wrapTextLines breaks long strings into lines" {
    const allocator = std.testing.allocator;
    const sample = "This is a notification with a fairly long body text that should wrap cleanly across multiple lines.";
    const lines = try wrapTextLines(allocator, sample, 200, 13);
    defer allocator.free(lines);
    try std.testing.expect(lines.len >= 2);
}
