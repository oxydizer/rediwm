//! Files pointer tests: wheel scrolling, drags and rubber-band selection, single-click opening, scrollbars, edge shadows, the sidebar divider and selection fades.

const std = @import("std");
const anim = @import("ui").anim;
const c = @import("c.zig").api;
const nowMs = @import("app_draw.zig").nowMs;
const app_tests = @import("app_tests.zig");
const testApp = app_tests.testApp;
const testItems = app_tests.testItems;

test "Files: the second click of a double-click on an icon does not open it again" {
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

test "single-click opening targets only visible icons and cancels for selection or dragging" {
    for ([_]bool{ false, true }) |list| {
        var app = try testApp();
        defer app.deinit();
        app.list_view = list;
        try testItems(&app, 20);
        const rect = app.itemIconRect(0);
        const x = rect.x + rect.w / 2;
        const y = rect.y + rect.h / 2;
        try std.testing.expectEqualStrings("pointer", std.mem.span(app.pointerCursor(x, y)));
        try std.testing.expectEqualStrings("default", std.mem.span(app.pointerCursor(rect.x + rect.w + 8, y)));
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
        try std.testing.expect(app.singleClickIconAt(x, @floatFromInt(app.viewTop() - 1)) == null);
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
