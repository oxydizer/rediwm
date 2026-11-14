//! Files hover tests: retained hover repairs, item and sidebar hover glides, reflow and hover damage.

const std = @import("std");
const App = @import("app.zig").App;
const anim = @import("ui").anim;
const c = @import("c.zig").api;
const header = @import("header.zig");
const ui_theme = @import("ui").theme;
const clipDamage = @import("app_draw.zig").clipDamage;
const clipDamageRegions = @import("app_draw.zig").clipDamageRegions;
const app_tests = @import("app_tests.zig");
const testApp = app_tests.testApp;
const testItems = app_tests.testItems;
const pointOnItem = app_tests.pointOnItem;

test "retained hover repairs match complete Cairo rasters across isolated transitions" {
    const saved_theme = ui_theme.global;
    defer ui_theme.global = saved_theme;
    ui_theme.global.app_sidebar_selected_marker = .{ 1, 0.95, 0.84, 1 };
    ui_theme.global.app_sidebar_item_radius = 10;
    ui_theme.global.app_sidebar[3] = 0.5;
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    app.loading = false;
    try testItems(&app, 12);

    var points: std.ArrayList([2]f64) = .empty;
    defer points.deinit(std.testing.allocator);

    for ([_]bool{ false, true }) |list| {
        ui_theme.global.app_highlight_bevel = if (list) 7 else 0;
        app.list_view = list;

        points.clearRetainingCapacity();

        // Exercise the current list-column geometry.
        if (list) {
            for (App.column_labels, 0..) |_, i| {
                const rect = app.listColumn(i);
                try points.append(std.testing.allocator, .{
                    rect.x + rect.w / 2,
                    rect.y + rect.h / 2,
                });
            }
        }

        // Exercise toolbar controls using their current geometry.
        for (std.meta.tags(header.Action)) |action| {
            const rect = header.rect(app.w, app.inRepository(), action);
            if (rect.w <= 0 or rect.h <= 0) continue;
            try points.append(std.testing.allocator, .{
                rect.x + rect.w / 2,
                rect.y + rect.h / 2,
            });
        }

        // The breadcrumb/location field is a distinct interaction surface.
        const field = header.field(app.w);
        try points.append(std.testing.allocator, .{ field.x + 12, field.y + 18 });

        // Exercise visible sidebar rows without depending on their hover keys.
        for (0..app.rowCount()) |index| {
            if (!app.placeVisible(index)) continue;
            const rect = app.placeRect(index);
            if (rect.y + rect.h <= @as(f64, @floatFromInt(app.viewTop()))) continue;
            if (rect.y >= @as(f64, @floatFromInt(app.contentBottom()))) continue;
            try points.append(std.testing.allocator, .{
                rect.x + rect.w / 2,
                rect.y + rect.h / 2,
            });
        }

        // Exercise item hover in more than one cell.
        for ([_]usize{ 0, 5 }) |index| {
            const point = pointOnItem(&app, index);
            try points.append(std.testing.allocator, point);
        }

        // Leaving the window must also repair the retained image.
        try points.append(std.testing.allocator, .{ -1, -1 });

        for ([_]f64{ 1, 1.5 }) |scale| {
            const w: i32 = @intFromFloat(@as(f64, @floatFromInt(app.w)) * scale);
            const h: i32 = @intFromFloat(@as(f64, @floatFromInt(app.h)) * scale);
            const retained = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h).?;
            defer c.cairo_surface_destroy(retained);
            const reference = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h).?;
            defer c.cairo_surface_destroy(reference);
            const cr = c.cairo_create(retained).?;
            defer c.cairo_destroy(cr);
            const ref = c.cairo_create(reference).?;
            defer c.cairo_destroy(ref);
            c.cairo_scale(cr, scale, scale);
            c.cairo_scale(ref, scale, scale);
            var clock: i64 = 1000;
            for (points.items, 0..) |point, point_index| {
                // Settle the previous transition outside the window, then establish
                // a complete baseline. Each target is tested independently.
                app.handleMotion(-1, -1);
                app.stepHover(clock + 5000);
                app.render(cr);
                app.render(ref);
                app.dirty = false;
                app.paint_damage = null;
                clock += 6000;

                app.handleMotion(point[0], point[1]);
                for ([_]i64{ 0, 16, 32, 64, 100, 160, 5000 }) |elapsed| {
                    app.stepHover(clock + elapsed);
                    if (app.dirty) {
                        c.cairo_save(cr);
                        if (app.paint_damage) |rect| clipDamage(cr, rect);
                        app.render(cr);
                        c.cairo_restore(cr);
                        app.dirty = false;
                    }
                    app.render(ref);
                    c.cairo_surface_flush(retained);
                    c.cairo_surface_flush(reference);
                    const len: usize = @intCast(w * h * 4);
                    const actual = c.cairo_image_surface_get_data(retained)[0..len];
                    const expected = c.cairo_image_surface_get_data(reference)[0..len];
                    var mismatch_offset: ?usize = null;
                    for (actual, expected, 0..) |a, b, i| {
                        const delta = @abs(@as(i16, a) - @as(i16, b));
                if (delta > 0) {
                            mismatch_offset = i;
                            break;
                        }
                    }
                    if (mismatch_offset) |offset| {
                        const mismatch = offset / 4;
                        const channel = offset % 4;
                        const delta = @abs(
                            @as(i16, actual[offset]) - @as(i16, expected[offset]),
                        );
                        std.debug.print(
                            "hover mismatch list={any} scale={d} scenario={d} point={any} +{d}ms damage={any} pixel={d},{d} channel={d} actual={d} expected={d} delta={d}\n",
                            .{
                                list,
                                scale,
                                point_index,
                                point,
                                elapsed,
                                app.paint_damage,
                                mismatch % @as(usize, @intCast(w)),
                                mismatch / @as(usize, @intCast(w)),
                                channel,
                                actual[offset],
                                expected[offset],
                                delta,
                            },
                        );
                        _ = c.cairo_surface_write_to_png(retained, "/tmp/files-hover-actual.png");
                        _ = c.cairo_surface_write_to_png(reference, "/tmp/files-hover-expected.png");
                        return error.TestUnexpectedResult;
                    }
                }
                clock += 6000;
            }
        }
    }
}

test "item hover glides between cells and rests without repaints or wakeups" {
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    app.loading = false;
    try testItems(&app, 12);
    app.dirty = false;

    // Nothing under the pointer: no highlight, no frame clock.
    app.stepHover(1000);
    try std.testing.expect(!app.hover_active and !app.dirty);

    // It fades in where the pointer landed.
    const first = pointOnItem(&app, 0);
    app.handleMotion(first[0], first[1]);
    try std.testing.expectEqual(@as(u64, 0), app.item_surface.hovered.?.id);
    try std.testing.expectEqual(@as(usize, 1000), app.hoverKey());
    app.dirty = false;
    app.stepHover(1000);
    try std.testing.expect(app.hover_active);
    app.stepHover(1050);
    try std.testing.expect(app.dirty and app.paint_damage != null);
    try std.testing.expect(app.item_hover.frame.alpha > 0 and app.item_hover.frame.alpha < 1);
    const card = app.itemHighlight(app.item_hover.frame);
    try std.testing.expect(app.paint_damage.?.contains(card.x + 1, card.y + 1) and app.paint_damage.?.contains(card.x + card.w - 2, card.y + card.h - 2));
    app.stepHover(4000);
    try std.testing.expectEqual(@as(f32, 1), app.item_hover.frame.alpha);
    try std.testing.expect(!app.hover_active);

    // At rest nothing repaints, however often it is sampled.
    app.dirty = false;
    app.stepHover(4100);
    app.stepHover(9000);
    try std.testing.expect(!app.dirty and !app.hover_active);

    // Moving to another item glides there rather than hopping.
    const per_row: usize = @intCast(app.columns());
    const to = pointOnItem(&app, 5);
    app.handleMotion(to[0], to[1]);
    app.stepHover(9100);
    app.stepHover(9150);
    const mid = app.item_hover.frame;
    const end_col: f32 = @floatFromInt(5 % per_row);
    const end_row: f32 = @floatFromInt(5 / per_row);
    try std.testing.expect(mid.col <= end_col and mid.row <= end_row);
    try std.testing.expect(mid.col > 0 or mid.row > 0);
    try std.testing.expect(mid.col < end_col or mid.row < end_row);
    try std.testing.expectEqual(@as(f32, 1), mid.alpha);
    try std.testing.expect(app.hover_active);
    app.stepHover(12000);
    try std.testing.expectEqual(end_col, app.item_hover.frame.col);
    try std.testing.expectEqual(end_row, app.item_hover.frame.row);
    try std.testing.expect(!app.hover_active);

    // A selected item paints its own fill: the highlight fades out.
    app.items.items[5].selected = true;
    try std.testing.expectEqual(@as(u64, 5), app.item_surface.hovered.?.id);
    try std.testing.expectEqual(@as(usize, 1005), app.hoverKey());
    app.stepHover(12100);
    app.stepHover(15000);
    try std.testing.expectEqual(@as(f32, 0), app.item_hover.frame.alpha);
    try std.testing.expect(!app.hover_active);

    // Leaving the window fades whatever is showing.
    app.items.items[5].selected = false;
    app.stepHover(15100);
    app.stepHover(18000);
    try std.testing.expectEqual(@as(f32, 1), app.item_hover.frame.alpha);
    app.handleMotion(-1, -1);
    app.stepHover(18100);
    app.stepHover(18150);
    try std.testing.expect(app.item_hover.frame.alpha < 1);
    app.stepHover(21000);
    try std.testing.expectEqual(@as(f32, 0), app.item_hover.frame.alpha);
    try std.testing.expect(!app.hover_active);

    // Modal UI owns the pointer.
    app.handleMotion(first[0], first[1]);
    app.menu = .background;
    app.stepHover(21100);
    app.stepHover(24000);
    try std.testing.expect(app.item_surface.hovered == null);
    try std.testing.expectEqual(@as(f32, 0), app.item_hover.frame.alpha);
}

test "sidebar hover glides between places and leaves the current one to its own fill" {
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    app.loading = false;
    app.dirty = false;
    const places_card = app.sidebarLayout().cards[@intFromEnum(@import("app_model.zig").SidebarSection.places)];
    const places_source_top = app.contentTop() - app.sidebar_scroll;
    const places_screen_offset: f64 = @floatFromInt(places_card.y + places_card.header_height - places_source_top);
    // Home is the current place (history starts at home_dir).
    app.handleMotion(70, @as(f64, @floatFromInt(app.placeY(0))) + 10 + places_screen_offset);
    app.dirty = false;
    app.stepHover(1000);
    app.stepHover(4000);
    try std.testing.expectEqual(@as(f32, 0), app.nav_hover.frame.alpha);
    try std.testing.expect(!app.dirty and !app.hover_active);

    app.handleMotion(70, @as(f64, @floatFromInt(app.placeY(1))) + 10 + places_screen_offset);
    app.stepHover(5000);
    app.stepHover(5050);
    try std.testing.expect(app.dirty and app.paint_damage != null);
    app.stepHover(8000);
    try std.testing.expectEqual(@as(f32, 1), app.nav_hover.frame.alpha);
    try std.testing.expectEqual(@as(f32, 1), app.nav_hover.frame.row);
    var box = app.navHighlight(app.nav_hover.frame);
    try std.testing.expectEqual(app.placeRect(1).y, box.y);

    // Every pixel between adjacent entries retains a hover target, at both pitches.
    const original_height = app.h;
    for ([_]i32{ 500, 700 }) |height| {
        app.h = height;
        const first = app.placeRect(App.places_start);
        const next = app.placeRect(App.places_start + 1);
        try std.testing.expectEqual(first.y + first.h, next.y);
        var y = first.y;
        while (y < next.y + next.h) : (y += 1) {
            app.mouse_y = y + places_screen_offset;
            app.updateSidebarSurface();
            try std.testing.expect(app.hoveredPlace() != null);
        }
    }
    app.h = original_height;

    // Three places down: partway, the highlight sits between the two rows.
    app.handleMotion(70, @as(f64, @floatFromInt(app.placeY(4))) + 10 + places_screen_offset);
    app.stepHover(8100);
    app.stepHover(8150);
    const mid = app.nav_hover.frame;
    try std.testing.expect(mid.row > 1 and mid.row < 4);
    box = app.navHighlight(mid);
    try std.testing.expect(box.y > @as(f64, @floatFromInt(app.placeY(1))) and box.y < @as(f64, @floatFromInt(app.placeY(4))));
    try std.testing.expect(app.hover_active);
    app.stepHover(11000);
    try std.testing.expectEqual(@as(f32, 4), app.nav_hover.frame.row);
    try std.testing.expect(!app.hover_active);

    // Following scroll: the highlight is a place, not a pixel row.
    app.sidebar_scroll = 20;
    box = app.navHighlight(app.nav_hover.frame);
    try std.testing.expectEqual(app.placeRect(4).y, box.y);
}

test "sidebar surface owns place hover and clears modal and departed targets" {
    var app = try testApp();
    defer app.deinit();
    app.loading = false;

    const places_card = app.sidebarLayout().cards[@intFromEnum(@import("app_model.zig").SidebarSection.places)];
    const places_source_top = app.contentTop() - app.sidebar_scroll;
    const places_screen_offset: f64 = @floatFromInt(places_card.y + places_card.header_height - places_source_top);
    app.handleMotion(70, @as(f64, @floatFromInt(app.placeY(1))) + 10 + places_screen_offset);
    try std.testing.expectEqual(@as(u64, 301), app.sidebar_surface.hovered.?.id);
    try std.testing.expectEqual(@as(?usize, 1), app.hoveredPlace());

    // The current place keeps its identity for pointer damage, but paints
    // its own selected fill instead of receiving the hover glide.
    app.handleMotion(70, @as(f64, @floatFromInt(app.placeY(0))) + 10 + places_screen_offset);
    try std.testing.expectEqual(@as(u64, 300), app.sidebar_surface.hovered.?.id);
    try std.testing.expectEqual(@as(?usize, null), app.hoveredPlace());

    app.menu = .background;
    app.updateSidebarSurface();
    try std.testing.expect(app.sidebar_surface.hovered == null);
    try std.testing.expectEqual(@as(?usize, null), app.hoveredPlace());

    app.menu = null;
    app.handleMotion(-1, -1);
    try std.testing.expect(app.sidebar_surface.hovered == null);
    try std.testing.expectEqual(@as(?usize, null), app.hoveredPlace());
}

test "a grid that reflows forgets its item highlight" {
    const before = anim.currentSettings();
    defer anim.applySettings(before);
    anim.applySettings(.{ .reduced_motion = .off });
    var app = try testApp();
    defer app.deinit();
    app.loading = false;
    try testItems(&app, 12);
    const on = pointOnItem(&app, 3);
    app.handleMotion(on[0], on[1]);
    app.stepHover(1000);
    app.stepHover(4000);
    try std.testing.expectEqual(@as(f32, 1), app.item_hover.frame.alpha);

    // Column 3 of a grid is off the edge of a list: it must not slide in.
    app.list_view = true;
    app.dirty = false;
    app.stepHover(4100);
    try std.testing.expectEqual(@as(f32, 0), app.item_hover.frame.alpha);
    try std.testing.expect(app.dirty and app.paint_damage == null);
    const row = pointOnItem(&app, 3);
    app.handleMotion(row[0], row[1]);
    app.stepHover(4200);
    app.stepHover(7000);
    try std.testing.expectEqual(@as(f32, 0), app.item_hover.frame.col);
    try std.testing.expectEqual(@as(f32, 3), app.item_hover.frame.row);
}

test "hover damage covers this repaint only" {
    var app = try testApp();
    defer app.deinit();
    // Left over from the last paint: not pending.
    app.dirty = false;
    app.paint_damage = .{ .x = 0, .y = 0, .w = 900, .h = 500 };
    app.addDamage(.{ .x = 10, .y = 10, .w = 5, .h = 5 });
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(header.Rect{ .x = 10, .y = 10, .w = 5, .h = 5 }, app.paint_damage.?);
    // Pending damage accumulates.
    app.addDamage(.{ .x = 100, .y = 100, .w = 5, .h = 5 });
    try std.testing.expectEqual(header.Rect{ .x = 10, .y = 10, .w = 95, .h = 95 }, app.paint_damage.?);
    // A queued full repaint absorbs it.
    app.invalidate();
    app.addDamage(.{ .x = 10, .y = 10, .w = 5, .h = 5 });
    try std.testing.expect(app.dirty and app.paint_damage == null);
}

test "progress damage regions stay independent until ordinary damage arrives" {
    var app = try testApp();
    defer app.deinit();

    app.dirty = false;
    app.paint_damage = null;
    app.progress_damage_count = 0;

    const first: header.Rect = .{ .x = 10, .y = 20, .w = 30, .h = 12 };
    const second: header.Rect = .{ .x = 300, .y = 240, .w = 40, .h = 14 };

    app.addDamageRegion(first);
    app.addDamageRegion(second);

    try std.testing.expect(app.dirty);
    try std.testing.expect(app.paint_damage == null);
    try std.testing.expectEqual(@as(usize, 2), app.progress_damage_count);
    try std.testing.expectEqual(first, app.progress_damage_regions[0]);
    try std.testing.expectEqual(second, app.progress_damage_regions[1]);

    app.addDamage(.{ .x = 500, .y = 400, .w = 10, .h = 10 });
    try std.testing.expectEqual(@as(usize, 0), app.progress_damage_count);
    try std.testing.expect(app.paint_damage != null);

    app.invalidate();
    try std.testing.expectEqual(@as(usize, 0), app.progress_damage_count);
    try std.testing.expect(app.paint_damage == null);
}

test "multi-region Cairo clipping matches painting the regions individually" {
    const width: i32 = 120;
    const height: i32 = 80;
    const retained = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, width, height).?;
    defer c.cairo_surface_destroy(retained);
    const reference = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, width, height).?;
    defer c.cairo_surface_destroy(reference);

    const regions = [_]header.Rect{
        .{ .x = 8, .y = 8, .w = 24, .h = 18 },
        .{ .x = 82, .y = 54, .w = 26, .h = 16 },
    };

    const retained_cr = c.cairo_create(retained).?;
    defer c.cairo_destroy(retained_cr);
    const reference_cr = c.cairo_create(reference).?;
    defer c.cairo_destroy(reference_cr);

    for ([_]*c.cairo_t{ retained_cr, reference_cr }) |cr| {
        c.cairo_set_source_rgb(cr, 1, 1, 1);
        c.cairo_paint(cr);
    }

    c.cairo_save(retained_cr);
    clipDamageRegions(retained_cr, &regions);
    c.cairo_set_source_rgb(retained_cr, 0, 0, 0);
    c.cairo_paint(retained_cr);
    c.cairo_restore(retained_cr);

    c.cairo_set_source_rgb(reference_cr, 0, 0, 0);
    for (regions) |region| {
        c.cairo_rectangle(
            reference_cr,
            region.x,
            region.y,
            region.w,
            region.h,
        );
    }
    c.cairo_fill(reference_cr);

    c.cairo_surface_flush(retained);
    c.cairo_surface_flush(reference);

    const len: usize = @intCast(width * height * 4);
    const actual = c.cairo_image_surface_get_data(retained)[0..len];
    const expected = c.cairo_image_surface_get_data(reference)[0..len];
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "column surface owns list header hover and clears modal and departed targets" {
    var app = try testApp();
    defer app.deinit();
    app.loading = false;
    app.list_view = true;
    try testItems(&app, 12);

    const column = app.listColumn(1);
    const x = column.x + column.w / 2;
    const y = column.y + column.h / 2;

    app.handleMotion(x, y);
    try std.testing.expectEqual(@as(u64, 401), app.column_surface.hovered.?.id);
    try std.testing.expectEqual(@as(usize, 401), app.hoverKey());

    app.handleMotion(-1, -1);
    try std.testing.expect(app.column_surface.hovered == null);
    try std.testing.expectEqual(@as(usize, 0), app.hoverKey());

    app.handleMotion(x, y);
    try std.testing.expect(app.column_surface.hovered != null);
    app.menu = .background;
    app.updateColumnSurface();
    try std.testing.expect(app.column_surface.hovered == null);

    app.menu = null;
    app.transfer_view.active = true;
    app.updateColumnSurface();
    try std.testing.expect(app.column_surface.hovered == null);
}

test "toolbar surface owns enabled hover targets and clears disabled and departed targets" {
    var app = try testApp();
    defer app.deinit();

    const cut = header.rect(app.w, false, .cut);
    try std.testing.expect(!app.toolbarButtonEnabled(.cut));
    app.handleMotion(cut.x + cut.w / 2, cut.y + cut.h / 2);
    try std.testing.expect(app.toolbar_surface.hovered == null);

    const refresh = header.rect(app.w, false, .refresh);
    app.handleMotion(refresh.x + refresh.w / 2, refresh.y + refresh.h / 2);
    try std.testing.expectEqual(@as(u64, @backingInt(header.Action.refresh)), app.toolbar_surface.hovered.?.id);
    try std.testing.expectEqual(refresh.x, app.hoveredToolbarButton().?.x);

    app.handleMotion(-1, -1);
    try std.testing.expect(app.toolbar_surface.hovered == null);
    try std.testing.expect(app.hoveredToolbarButton() == null);
}

test "toolbar proximity uses shared button geometry and damages in-button motion" {
    var app = try testApp();
    defer app.deinit();

    const rect = header.rect(app.w, false, .refresh);
    const x = rect.x + rect.w / 2;
    const y = rect.y + rect.h / 2;

    app.handleMotion(x, y);
    const sample = app.toolbarButtonProximity(.refresh, x, y);
    try std.testing.expectEqual(@as(f32, 0), sample.distance);
    try std.testing.expectEqual(@as(f32, @floatCast(rect.w / 2)), sample.x);
    try std.testing.expectEqual(@as(f32, @floatCast(rect.h / 2)), sample.y);

    // Moving within the same button does not change hoverKey. Proximity
    // still changes and must queue damage for the button.
    app.dirty = false;
    app.paint_damage = null;
    app.handleMotion(x + 1, y);
    try std.testing.expect(app.dirty);
    try std.testing.expect(app.paint_damage != null);
    try std.testing.expect(app.paint_damage.?.contains(x, y));
}

test "dialog surface owns generic modal button hover targets" {
    var app = try testApp();
    defer app.deinit();

    const dw: f64 = @min(440, @as(f64, @floatFromInt(app.w)) - 24);
    const dx = (@as(f64, @floatFromInt(app.w)) - dw) / 2;
    const dy = (@as(f64, @floatFromInt(app.h)) - 130) / 2;

    const generic_kinds = [_]@import("app_model.zig").DialogKind{
        .terminal_close,
        .new_folder,
        .new_file,
        .new_branch,
    };

    for (generic_kinds) |kind| {
        app.dialog = .{ .kind = kind, .title = "Test" };

        app.mouse_x = dx + dw - 144;
        app.mouse_y = dy + 98;
        app.updateDialogSurface();
        try std.testing.expectEqual(@as(u64, 1), app.dialog_surface.hovered.?.id);
        try std.testing.expectEqual(@as(usize, 1), app.hoverKey());

        app.mouse_x = dx + dw - 56;
        app.updateDialogSurface();
        try std.testing.expectEqual(@as(u64, 2), app.dialog_surface.hovered.?.id);
        try std.testing.expectEqual(@as(usize, 2), app.hoverKey());
    }

    app.dialog = .{
        .kind = .conflict,
        .title = "Conflict",
    };

    const button_w = (dw - 48) / 3;
    for (0..3) |i| {
        app.mouse_x = dx + 16 + @as(f64, @floatFromInt(i)) * (button_w + 8) + button_w / 2;
        app.mouse_y = dy + 98;
        app.updateDialogSurface();
        try std.testing.expectEqual(@as(u64, @intCast(i + 1)), app.dialog_surface.hovered.?.id);
        try std.testing.expectEqual(i + 1, app.hoverKey());
    }

    // A specialized dialog keeps its own interaction path.
    app.dialog = .{ .kind = .transfers, .title = "Transfers" };
    app.updateDialogSurface();
    try std.testing.expect(app.dialog_surface.hovered == null);

    // Closing a dialog clears any retained dialog target.
    app.dialog = .{ .kind = .terminal_close, .title = "Close terminal?" };
    app.mouse_x = dx + dw - 144;
    app.mouse_y = dy + 98;
    app.updateDialogSurface();
    try std.testing.expect(app.dialog_surface.hovered != null);
    app.closeDialog();
    try std.testing.expect(app.dialog_surface.hovered == null);
}

test "dialog surface owns inline rename buttons and clears departed targets" {
    var app = try testApp();
    defer app.deinit();

    app.dialog = .{ .kind = .rename, .title = "Rename" };
    const card = app.renameCard().?;

    app.mouse_x = card.confirm.x + card.confirm.w / 2;
    app.mouse_y = card.confirm.y + card.confirm.h / 2;
    app.updateDialogSurface();
    try std.testing.expectEqual(@as(u64, 1), app.dialog_surface.hovered.?.id);
    try std.testing.expectEqual(@as(usize, 1), app.hoverKey());

    app.mouse_x = card.cancel.x + card.cancel.w / 2;
    app.mouse_y = card.cancel.y + card.cancel.h / 2;
    app.updateDialogSurface();
    try std.testing.expectEqual(@as(u64, 2), app.dialog_surface.hovered.?.id);
    try std.testing.expectEqual(@as(usize, 2), app.hoverKey());

    app.handleMotion(-1, -1);
    try std.testing.expect(app.dialog_surface.hovered == null);
    try std.testing.expectEqual(@as(usize, 0), app.hoverKey());
}
