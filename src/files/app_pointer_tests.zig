//! Files pointer tests: wheel scrolling, drags and rubber-band selection, single-click opening, scrollbars, edge shadows, the sidebar divider and selection fades.

const std = @import("std");
const anim = @import("ui").anim;
const c = @import("c.zig").api;
const nowMs = @import("app_draw.zig").nowMs;
const app_tests = @import("app_tests.zig");
const ops_mod = @import("ops.zig");
const io_service = @import("io_service.zig");
const testApp = app_tests.testApp;
const testItems = app_tests.testItems;

/// A window linked to a service with no coordinator: what it sends stays
/// queued for the test to read.
const Linked = struct {
    service: io_service.Service = .{},
    handle: io_service.Handle = undefined,

    fn start(self: *Linked, app: anytype) !void {
        try self.service.init();
        self.handle = try self.service.registerWindow();
        app.service.handle = self.handle;
    }

    fn stop(self: *Linked, app: anytype) void {
        app.service.handle = null;
        while (self.service.tryReceiveCommand()) |routed| {
            var command = routed.command;
            command.deinitPayload();
        }
        self.handle.close();
        self.service.deinit();
    }

    /// The priority requests sent so far, as `job:entry`.
    fn priorities(self: *Linked, out: []u64) usize {
        var count: usize = 0;
        while (self.service.tryReceiveCommand()) |routed| {
            var command = routed.command;
            defer command.deinitPayload();
            if (command.kind != .prioritize_entry or count == out.len) continue;
            out[count] = command.job_id * 1000 + command.resource_id;
            count += 1;
        }
        return count;
    }
};

const ghost_job = 7;
const ghost_entry = 3;

/// Item `index` becomes a queued ghost file of a service copy.
fn attachEligibleCopyGhost(app: anytype, index: usize) void {
    app.items.items[index].transfer_ghost = true;
    app.items.items[index].transfer_job_id = ghost_job;
    app.items.items[index].transfer_entry_id = ghost_entry;
    app.items.items[index].transfer_state = .pending;
    app.items.items[index].missing = true;
}

test "copy ghost hover waits for dwell and asks the service once" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 1);
    var linked: Linked = .{};
    try linked.start(&app);
    defer linked.stop(&app);
    attachEligibleCopyGhost(&app, 0);

    const rect = app.itemIconRect(0);
    app.handleMotion(rect.x + rect.w / 2, rect.y + rect.h / 2);
    const deadline = app.transferHoverPriorityDeadline().?;

    // The dwell has not elapsed yet.
    app.stepTransferHoverPriority(deadline - 1);
    try std.testing.expectEqual(deadline, app.transferHoverPriorityDeadline().?);
    var sent: [4]u64 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linked.priorities(&sent));

    // At the deadline the preference is requested exactly once; leaving
    // afterwards does not take it back.
    app.stepTransferHoverPriority(deadline);
    try std.testing.expect(app.transferHoverPriorityDeadline() == null);
    app.stepTransferHoverPriority(deadline + 1000);
    app.handleMotion(-10, -10);
    try std.testing.expectEqual(@as(usize, 1), linked.priorities(&sent));
    try std.testing.expectEqual(@as(u64, ghost_job * 1000 + ghost_entry), sent[0]);
}

test "leaving a copy ghost before the hover dwell cancels its preference" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 1);
    var linked: Linked = .{};
    try linked.start(&app);
    defer linked.stop(&app);
    attachEligibleCopyGhost(&app, 0);

    const rect = app.itemIconRect(0);
    app.handleMotion(rect.x + rect.w / 2, rect.y + rect.h / 2);
    const deadline = app.transferHoverPriorityDeadline().?;

    app.handleMotion(-10, -10);
    try std.testing.expect(app.transferHoverPriorityDeadline() == null);
    app.stepTransferHoverPriority(deadline);
    var sent: [4]u64 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linked.priorities(&sent));
}

test "pressing over a copy ghost cancels its pending hover priority" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 1);
    var linked: Linked = .{};
    try linked.start(&app);
    defer linked.stop(&app);
    attachEligibleCopyGhost(&app, 0);

    const rect = app.itemIconRect(0);
    app.handleMotion(rect.x + rect.w / 2, rect.y + rect.h / 2);
    const deadline = app.transferHoverPriorityDeadline().?;

    app.handleButton(0x110, true);
    try std.testing.expect(app.transferHoverPriorityDeadline() == null);
    app.stepTransferHoverPriority(deadline);
    try std.testing.expect(app.transfer_hover_priority == null);
    var sent: [4]u64 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linked.priorities(&sent));
}

test "a copy ghost priority that cannot be sent clears its pending hover request" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 1);
    attachEligibleCopyGhost(&app, 0);

    const rect = app.itemIconRect(0);
    app.handleMotion(rect.x + rect.w / 2, rect.y + rect.h / 2);
    const deadline = app.transferHoverPriorityDeadline().?;

    // No service to ask.
    app.stepTransferHoverPriority(deadline);
    try std.testing.expect(app.transfer_hover_priority == null);
    try std.testing.expect(app.transferHoverPriorityDeadline() == null);
}

test "file dragging across a copy ghost does not arm hover priority" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 2);
    attachEligibleCopyGhost(&app, 1);

    const source = app.itemIconRect(0);
    const target = app.itemIconRect(1);
    app.handleMotion(target.x + target.w / 2, target.y + target.h / 2);
    try std.testing.expect(app.transferHoverPriorityDeadline() != null);

    app.handleMotion(source.x + source.w / 2, source.y + source.h / 2);
    app.handleButton(0x110, true);
    app.handleMotion(target.x + target.w / 2, target.y + target.h / 2);

    try std.testing.expect(app.drag_ready);
    try std.testing.expect(app.transferHoverPriorityDeadline() == null);
}

test "rubber-band selection across a copy ghost does not arm hover priority" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 1);
    attachEligibleCopyGhost(&app, 0);

    const target = app.itemIconRect(0);
    const top: f64 = @floatFromInt(app.viewTop() + app.itemInset());
    app.handleMotion(target.x + target.w / 2, target.y + target.h / 2);
    try std.testing.expect(app.transferHoverPriorityDeadline() != null);

    app.handleMotion(215, top - 5);
    app.handleButton(0x110, true);
    app.handleMotion(target.x + target.w / 2, target.y + target.h / 2);

    try std.testing.expect(app.selection_band != null);
    try std.testing.expect(app.transferHoverPriorityDeadline() == null);
}

test "Files: the second click of a double-click does not open the item again" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 20);
    const rect = app.itemIconRect(0);
    const x = rect.x + rect.w / 2;
    const y = rect.y + rect.h / 2;
    app.handleMotion(x, y);
    // Opened a moment ago: the press selects but does not arm another open.
    app.last_open_index = 0;
    app.last_open_time = nowMs();
    app.handleButton(0x110, true);
    try std.testing.expect(app.open_on_release == null and app.items.items[0].selected);
    app.cancelDrag();
    // Another item, or the interval passed: a click opens as usual.
    app.last_open_index = 1;
    app.handleButton(0x110, true);
    try std.testing.expectEqual(@as(?usize, 0), app.open_on_release);
    app.cancelDrag();
    app.last_open_index = 0;
    app.last_open_time = nowMs() - 500;
    app.handleButton(0x110, true);
    try std.testing.expectEqual(@as(?usize, 0), app.open_on_release);
    app.cancelDrag();
}

test "Files wheel follows the shell spring, accumulates and reverses without lag" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 100);
    app.handleMotion(300, 200);
    app.handleWheel(40, 1000);
    try std.testing.expectEqual(@as(i32, 0), app.scroll_y);
    app.stepWheel(1040);
    try std.testing.expect(app.scroll_y > 0 and app.scroll_y < 40);
    app.handleWheel(40, 1040);
    try std.testing.expectEqual(@as(f32, 80), app.wheel_glide.to);
    app.stepWheel(1100);
    const at = app.wheel_glide.value(1100);
    app.handleWheel(-10, 1100);
    try std.testing.expectApproxEqAbs(at - 10, app.wheel_glide.to, 0.01);
    app.stepWheel(5000);
    try std.testing.expect(!app.wheel_glide.active());
    app.handleWheel(100000, 6000);
    app.stepWheel(10000);
    try std.testing.expectEqual(app.maxScroll(), app.scroll_y);
    app.handleWheel(-40, 11000);
    app.handleButton(0x110, false);
    try std.testing.expect(!app.wheel_glide.active());
}

test "file drag threshold preserves multi-selection and ordinary release collapses it" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 10);
    app.single_click_open = false;
    app.items.items[0].selected = true;
    app.items.items[1].selected = true;
    app.handleMotion(310, 158);
    app.handleButton(0x110, true);
    try std.testing.expect(app.items.items[1].selected);
    app.handleMotion(313, 158);
    try std.testing.expect(!app.drag_ready);
    app.handleMotion(330, 158);
    try std.testing.expect(app.drag_ready);
    app.handleButton(0x110, false);
    try std.testing.expect(app.items.items[1].selected);
    app.last_click_index = null;
    app.last_click_time = 0;
    app.handleMotion(310, 158);
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    try std.testing.expect(!app.items.items[1].selected);

    app.ctrl = true;
    app.last_click_index = null;
    app.handleButton(0x110, true);
    try std.testing.expect(app.items.items[0].selected);
    app.handleMotion(330, 158);
    try std.testing.expect(app.drag_ready);
    app.handleButton(0x110, false);
    try std.testing.expect(app.items.items[0].selected);
    app.handleMotion(310, 158);
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    try std.testing.expect(!app.items.items[0].selected);
}

test "single-click opening targets whole rows and cancels for selection or dragging" {
    for ([_]bool{ false, true }) |list| {
        var app = try testApp();
        defer app.deinit();
        app.list_view = list;
        try testItems(&app, 20);
        const rect = app.itemIconRect(0);
        const x = rect.x + rect.w / 2;
        const y = rect.y + rect.h / 2;
        try std.testing.expectEqualStrings("pointer", std.mem.span(app.pointerCursor(x, y)));
        try std.testing.expectEqualStrings("pointer", std.mem.span(app.pointerCursor(rect.x + rect.w + 8, y)));
        app.handleMotion(x, y);
        app.handleButton(0x110, true);
        try std.testing.expectEqual(@as(?usize, 0), app.open_on_release);
        app.handleMotion(x + 9, y);
        try std.testing.expect(app.drag_ready and app.open_on_release == null);
        app.handleButton(0x110, false);
        app.handleMotion(x, y);
        for (0..3) |modifier| {
            app.ctrl = modifier == 0;
            app.shift = modifier == 1;
            app.alt = modifier == 2;
            app.handleButton(0x110, true);
            try std.testing.expect(app.open_on_release == null);
            app.handleButton(0x110, false);
        }
        app.ctrl = false;
        app.shift = false;
        app.alt = false;
        app.handleButton(0x110, true);
        app.cancelDrag();
        try std.testing.expect(app.open_on_release == null);
        app.single_click_open = false;
        try std.testing.expectEqualStrings("default", std.mem.span(app.pointerCursor(x, y)));
        app.handleButton(0x110, true);
        try std.testing.expect(app.open_on_release == null);
        app.cancelDrag();
        app.single_click_open = true;
        app.scroll_y = @intFromFloat(rect.y + rect.h - app.viewTop());
        try std.testing.expect(app.singleClickItemAt(x, @floatFromInt(app.viewTop() - 1)) == null);
        if (list) {
            app.scroll_y = 0;
            app.scroll_x = 12;
            const shifted = app.itemIconRect(0);
            try std.testing.expectEqualStrings("pointer", std.mem.span(app.pointerCursor(shifted.x + 1, y)));
        }
    }
}

test "Files reduced motion scrolls immediately" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    var settings = saved;
    settings.reduced_motion = .on;
    anim.applySettings(settings);
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 100);
    app.handleMotion(300, 200);
    app.handleWheel(40, 1000);
    try std.testing.expectEqual(@as(i32, 40), app.scroll_y);
    try std.testing.expect(!app.wheel_glide.active());
}

test "background drag selects in grid and list with modifiers and reverse motion" {
    for ([_]bool{ false, true }) |list| {
        var app = try testApp();
        defer app.deinit();
        app.list_view = list;
        try testItems(&app, 20);
        const top: f64 = @floatFromInt(app.viewTop() + app.itemInset());
        // The left gutter is empty in both layouts.
        app.handleMotion(215, top - 5);
        app.handleButton(0x110, true);
        app.handleMotion(300, top + 15);
        try std.testing.expect(app.selection_band.?.active);
        try std.testing.expect(app.items.items[0].selected);
        try std.testing.expect(!app.items.items[1].selected);
        try std.testing.expect(!app.drag_ready);
        // Shrinking the rectangle removes items again.
        app.handleMotion(220, top - 3);
        try std.testing.expect(!app.items.items[0].selected);
        app.handleMotion(300, top + 15);
        app.handleButton(0x110, false);
        try std.testing.expect(app.selection_band == null);
        try std.testing.expect(app.items.items[0].selected);

        app.ctrl = true;
        app.items.items[2].selected = true;
        app.handleMotion(215, top - 5);
        app.handleButton(0x110, true);
        app.handleMotion(300, top + 15);
        try std.testing.expect(!app.items.items[0].selected);
        try std.testing.expect(app.items.items[2].selected);
        app.handleMotion(301, top + 16);
        try std.testing.expect(!app.items.items[0].selected); // No repeated toggling.
        app.handleButton(0x110, false);
        app.ctrl = false;
        app.shift = true;
        app.handleMotion(215, top - 5);
        app.handleButton(0x110, true);
        app.handleMotion(300, top + 15);
        try std.testing.expect(app.items.items[0].selected and app.items.items[2].selected);
        app.handleKey(c.XKB_KEY_Escape, "");
        try std.testing.expect(app.selection_band == null);
        try std.testing.expect(!app.items.items[0].selected and app.items.items[2].selected);
    }
}

test "selection edge scroll keeps a content anchor and stops on release" {
    var app = try testApp();
    defer app.deinit();
    app.list_view = true;
    try testItems(&app, 100);
    app.handleMotion(215, 150);
    app.handleButton(0x110, true);
    const anchor = app.selection_band.?.y;
    app.handleMotion(300, @floatFromInt(app.h - 30));
    try std.testing.expect(app.selectionNeedsScroll());
    app.stepSelection(app.selection_band.?.last_ms + 50);
    try std.testing.expect(app.scroll_y > 0);
    try std.testing.expectEqual(anchor, app.selection_band.?.y);
    app.handleButton(0x110, false);
    const offset = app.scroll_y;
    app.stepSelection(nowMs() + 500);
    try std.testing.expectEqual(offset, app.scroll_y);
    try std.testing.expect(!app.selectionNeedsScroll());
}

test "scrollbar gutter hover, outside drag, release and resize preserve layout" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 100);
    app.list_view = true;
    const column = app.listColumn(0);
    app.handleMotion(@floatFromInt(app.w - 7), @floatFromInt(app.viewTop() + 10));
    app.stepScrollbar(0);
    app.stepScrollbar(180);
    try std.testing.expectEqual(@as(f32, 1), app.scroll_appearance.wide);
    try std.testing.expectEqualDeep(column, app.listColumn(0));
    app.handleButton(0x110, true);
    try std.testing.expect(app.scroll_drag.active);
    app.handleMotion(-20, @floatFromInt(app.h + 100));
    app.stepScrollbar(200);
    try std.testing.expectEqual(app.maxScroll(), app.scroll_y);
    try std.testing.expectEqual(@as(f32, 1), app.scroll_appearance.accent);
    app.handleButton(0x110, false);
    app.stepScrollbar(220);
    app.stepScrollbar(600);
    app.stepScrollbar(800);
    try std.testing.expectEqual(@as(f32, 0), app.scroll_appearance.wide);
    try std.testing.expect(!app.scroll_appearance.active);
    app.h = 10000;
    app.clampScroll();
    app.stepScrollbar(1000);
    try std.testing.expectEqual(@as(i32, 0), app.scroll_y);
    try std.testing.expect(app.scroll_appearance.deadline == null);
}

test "viewport edge shadows at top middle bottom and when content fits" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 100);
    app.list_view = true;
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, app.w, app.h).?;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface).?;
    defer c.cairo_destroy(cr);
    const stride: usize = @intCast(c.cairo_image_surface_get_stride(surface));
    const pixels = c.cairo_image_surface_get_data(surface);
    const x: usize = @intCast(app.sidebarWidth() + 10);
    for ([_]i32{ 0, @divTrunc(app.maxScroll(), 2), app.maxScroll() }) |offset| {
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
        c.cairo_paint(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
        app.scroll_y = offset;
        app.renderScrollEdges(cr, app.h - app.viewTop() - app.footerHeight());
        c.cairo_surface_flush(surface);
        const top: usize = @intCast(app.viewTop());
        const bottom: usize = @intCast(app.h - app.footerHeight() - 1);
        try std.testing.expectEqual(offset > 0, pixels[top * stride + x * 4 + 3] > 0);
        try std.testing.expectEqual(offset < app.maxScroll(), pixels[bottom * stride + x * 4 + 3] > 0);
        try std.testing.expectEqual(@as(u8, 0), pixels[(top - 1) * stride + x * 4 + 3]);
        try std.testing.expectEqual(@as(u8, 0), pixels[top * stride + 4 + 3]);
        try std.testing.expectEqual(@as(u8, 0), pixels[(top + 12) * stride + x * 4 + 3]);
    }
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
    app.h = 10000;
    app.clampScroll();
    app.renderScrollEdges(cr, app.h - app.viewTop() - app.footerHeight());
    c.cairo_surface_flush(surface);
    try std.testing.expectEqual(@as(u8, 0), pixels[@as(usize, @intCast(app.viewTop())) * stride + x * 4 + 3]);
}

test "sidebar divider resizes within limits without selecting or sorting" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 2);
    app.resize(960, 540);
    app.stepLayout(0);
    app.items.items[0].selected = true;
    const sort = app.sort_mode;
    const y: f64 = @floatFromInt(app.contentTop() + 15);
    // Grab slightly off the line: starting a drag must not jump the width.
    app.handleMotion(210, y);
    try std.testing.expectEqualStrings("col-resize", std.mem.span(app.pointerCursor(210, y)));
    app.handleButton(0x110, true);
    try std.testing.expect(app.sidebar_resize != null);
    app.handleMotion(210, y);
    try std.testing.expectEqual(@as(i32, 208), app.sidebarWidth());
    app.handleMotion(342, y);
    try std.testing.expectEqual(@as(i32, 340), app.sidebarWidth());
    app.stepLayout(1000);
    try std.testing.expectEqual(@as(i32, 340), app.sidebarWidth());
    app.handleMotion(10000, -50);
    try std.testing.expectEqual(@as(i32, 480), app.sidebarWidth());
    try std.testing.expectEqualStrings("col-resize", std.mem.span(app.pointerCursor(10000, -50)));
    app.handleMotion(-10000, y);
    try std.testing.expectEqual(@as(i32, 160), app.sidebarWidth());
    app.handleMotion(342, y);
    app.handleButton(0x110, false);
    try std.testing.expect(app.sidebar_resize == null and app.selection_band == null and app.drag_origin == null);
    try std.testing.expect(app.items.items[0].selected and !app.items.items[1].selected);
    try std.testing.expectEqual(sort, app.sort_mode);
    app.handleMotion(400, y);
    try std.testing.expectEqual(@as(i32, 340), app.sidebarWidth());
    // Window resizes clamp the drawn width but retain the user's preference.
    app.resize(500, 540);
    try std.testing.expectEqual(@as(i32, 250), app.sidebarWidth());
    app.resize(960, 540);
    try std.testing.expectEqual(@as(i32, 340), app.sidebarWidth());
    app.handleMotion(340, y);
    app.handleButton(0x110, true);
    app.handleKey(c.XKB_KEY_Escape, "");
    try std.testing.expect(app.sidebar_resize == null);
    app.handleMotion(500, y);
    try std.testing.expectEqual(@as(i32, 340), app.sidebarWidth());
    app.openMenu(.background, 400, y);
    try std.testing.expect(!app.overSidebarDivider(340, y));
    app.menu = null;
    try std.testing.expect(!app.overSidebarDivider(340, 20));
    try std.testing.expect(app.overSidebarDivider(340, @floatFromInt(app.h - 1)));
    app.resize(360, 540);
    app.stepLayout(2000);
    app.stepLayout(3000);
    try std.testing.expectEqual(@as(i32, 0), app.sidebarWidth());
    try std.testing.expect(app.sidebarDivider() == null);
    app.resize(960, 540);
    try std.testing.expectEqual(@as(i32, 340), app.sidebarWidth());
}

test "sidebar scrollbar pages, drags outside and resets on resize" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    app.resize(700, 300);
    const bar = app.sidebarScrollbar().?;
    app.handleMotion(@as(f64, bar.thumb.x) + 5, @as(f64, bar.thumb.y) + 5);
    app.stepScrollbar(0);
    app.stepScrollbar(180);
    try std.testing.expectEqual(@as(f32, 1), app.sidebar_scroll_appearance.wide);
    app.handleButton(0x110, true);
    try std.testing.expect(app.sidebar_scroll_drag.active);
    app.handleMotion(-20, 600);
    try std.testing.expectEqual(@as(i32, @intFromFloat(bar.max_offset)), app.sidebar_scroll);
    try std.testing.expectEqual(@as(i32, 0), app.scroll_y);
    app.handleButton(0x110, false);
    try std.testing.expect(!app.sidebar_scroll_drag.active);
    app.handleMotion(@as(f64, bar.track.x) + 5, @as(f64, bar.track.y) + 1);
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    try std.testing.expect(@as(f32, @floatFromInt(app.sidebar_scroll)) < bar.max_offset);
    app.resize(700, 900);
    app.stepScrollbar(1000);
    app.stepScrollbar(2000);
    try std.testing.expect(app.sidebarScrollbar() == null);
    try std.testing.expectEqual(@as(i32, 0), app.sidebar_scroll);
    try std.testing.expect(!app.sidebar_scroll_appearance.active);
    try std.testing.expect(app.sidebar_scroll_appearance.deadline == null);
    app.resize(360, 240);
    try std.testing.expect(app.sidebarScrollbar() == null);
}

test "Transfers scroll extent includes a row per running service job" {
    var app = try testApp();
    defer app.deinit();

    app.transfer_view.active = true;
    const idle_height = app.contentHeight();

    for ([_]@import("io_service.zig").JobState{ .running, .paused, .waiting }) |state| {
        app.service.jobs.apply(.{ .id = 1, .kind = .copy, .state = state });
        try std.testing.expectEqual(idle_height + app.rowHeight(), app.contentHeight());
    }
    app.service.jobs.apply(.{ .id = 2, .kind = .move, .state = .queued });
    try std.testing.expectEqual(idle_height + 2 * app.rowHeight(), app.contentHeight());

    app.service.jobs.apply(.{ .id = 1, .kind = .copy, .state = .completed });
    app.service.jobs.apply(.{ .id = 2, .kind = .move, .state = .cancelled });
    try std.testing.expectEqual(idle_height, app.contentHeight());
}

test "Transfers toolbar pauses, resumes and cancels a selected file operation" {
    var service: io_service.Service = .{};
    try service.init();
    defer service.deinit();
    var app = try testApp();
    defer app.deinit();
    var handle = try service.registerWindow();
    app.service.handle = handle;
    defer {
        app.service.handle = null;
        handle.close();
        // What no coordinator took, so the Service can end.
        while (service.tryReceiveCommand()) |routed| {
            var command = routed.command;
            command.deinitPayload();
        }
    }

    app.transfer_view.active = true;
    app.transfer_view.row = 0;
    app.service.jobs.apply(.{ .id = 5, .kind = .copy, .state = .running, .started_at_ms = 1 });

    const scale = @min(1.0, @max(0.0, (@as(f32, @floatFromInt(app.w)) - 64) / 424));
    const add_width = 112 * scale;
    const pause_x: f64 = 12 + add_width + 8 + 1;
    const cancel_x: f64 = 12 + add_width + 8 + 92 * scale + 8 + 1;

    const Expect = struct {
        fn command(s: *io_service.Service, kind: io_service.CommandKind) !void {
            const routed = s.tryReceiveCommand() orelse return error.NoCommand;
            try std.testing.expectEqual(kind, routed.command.kind);
            try std.testing.expectEqual(@as(u64, 5), routed.command.job_id);
        }
    };
    try std.testing.expect(app.transferPaneClick(pause_x, 65, 0x110));
    try Expect.command(&service, .pause_job);

    app.service.jobs.apply(.{ .id = 5, .kind = .copy, .state = .paused, .started_at_ms = 1 });
    try std.testing.expect(app.transferPaneClick(pause_x, 65, 0x110));
    try Expect.command(&service, .resume_job);

    try std.testing.expect(app.transferPaneClick(cancel_x, 65, 0x110));
    try Expect.command(&service, .cancel_job);
}

test "file selection fades in and out while logical selection is immediate" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 2);
    app.mouse_x = -1;
    app.mouse_y = -1;
    app.items.items[0].selected = true;
    app.stepHover(1000);
    try std.testing.expect(app.items.items[0].selected);
    try std.testing.expectEqual(@as(f32, 0), app.items.items[0].selection_fill.alpha);
    app.stepHover(1050);
    const alpha = app.items.items[0].selection_fill.alpha;
    try std.testing.expect(alpha > 0 and alpha < 1);
    app.items.items[0].selected = false;
    app.stepHover(1050);
    try std.testing.expectEqual(alpha, app.items.items[0].selection_fill.alpha);
    app.stepHover(4000);
    try std.testing.expectEqual(@as(f32, 0), app.items.items[0].selection_fill.alpha);
    try std.testing.expect(!app.hover_active);
    app.items.items[1].selected = true;
    app.stepHover(5000);
    app.stepHover(8000);
    try std.testing.expectEqual(@as(f32, 1), app.items.items[1].selection_fill.alpha);
    app.dirty = false;
    app.stepHover(9000);
    try std.testing.expect(!app.dirty and !app.hover_active);
    anim.applySettings(.{ .enabled = false });
    app.items.items[1].selected = false;
    app.stepHover(10000);
    try std.testing.expectEqual(@as(f32, 0), app.items.items[1].selection_fill.alpha);
}
