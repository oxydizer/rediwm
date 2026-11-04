//! Desktop tests: launch, pointer motion, names, rubber band and icon caches.

const std = @import("std");
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const text = @import("ui").text;
const damage_mod = @import("damage.zig");
const Damage = damage_mod.Damage;
const rename = @import("rename.zig");
const deletion = @import("../delete_dialog.zig");
const context_menu = @import("ui").context_menu;
const a = std.heap.c_allocator;
const Icon = @import("app.zig").Icon;
const copyItem = @import("app_draw.zig").copyItem;
const freeItem = @import("app_draw.zig").freeItem;
const nowMs = @import("app_draw.zig").nowMs;
const NameCache = @import("app_draw.zig").NameCache;
const drawName = @import("app_draw.zig").drawName;
const label = @import("app_draw.zig").label;

test "button release does not cancel the launch triggered by its press" {
    var app = App{ .worker = undefined, .launching_until = 30000 };
    app.button(272, false);
    try std.testing.expectEqual(@as(i64, 30000), app.launching_until);
}

test "desktop shortcut picker searches, confirms separately and cancels without work" {
    const picker = @import("../files/open_with.zig");
    const entries = [_]@import("dotdesktop.zig").parser.AppEntry{
        .{ .id = "first.desktop", .desktop_file_path = "/apps/first.desktop", .name = "First App", .exec = "true" },
        .{ .id = "second.desktop", .desktop_file_path = "/apps/second.desktop", .name = "Second App", .exec = "true" },
    };
    var app = App{ .worker = undefined, .edit = .add_app, .applications = picker.State.initShortcuts(a, &entries) };
    defer app.deinit();
    try std.testing.expectEqual(@as(usize, 7), app.menuLabels().len);
    try std.testing.expectEqualStrings("Paste", app.menuLabels()[3]);
    try std.testing.expectEqualStrings("CTRL+V", app.menuHint(3).?);
    app.key(c.XKB_KEY_s, "S");
    app.key(c.XKB_KEY_e, "e");
    try std.testing.expectEqualStrings("second.desktop", app.applications.?.shortcut().?.id);
    app.key(c.XKB_KEY_space, " ");
    try std.testing.expect(app.applications.?.shortcut() == null);
    // An empty result cannot enqueue work, even on confirmation.
    app.key(c.XKB_KEY_Return, "");
    try std.testing.expectEqual(.add_app, app.edit);
    app.ctrl = true;
    app.key(c.XKB_KEY_a, "");
    app.ctrl = false;
    const g = app.applications.?.geometry(app.geometry.w, app.geometry.h - app.geometry.bottom);
    app.motion(g.box.x + g.list.x + 20, g.box.y + g.list.y + 40);
    app.button(272, true);
    app.button(272, false);
    try std.testing.expectEqualStrings("second.desktop", app.applications.?.shortcut().?.id);
    try std.testing.expectEqual(.add_app, app.edit);
    app.key(c.XKB_KEY_Tab, "");
    app.key(c.XKB_KEY_Return, "");
    try std.testing.expectEqual(.none, app.edit);
    try std.testing.expect(app.applications == null);
}

test "desktop pointer motion repaints only when visible state changes" {
    var icons = [_]Icon{.{ .item = .{ .path = "", .name = "", .icon = null }, .cell = .{}, .born = 0 }};
    var app = App{ .worker = undefined, .icons = .fromOwnedSlice(&icons), .dirty = false };
    app.motion(200, 200);
    app.motion(300, 250);
    try std.testing.expect(!app.dirty);
    try std.testing.expectEqual(@as(f64, 300), app.x);
    const r = app.geometry.rect(.{});
    app.motion(@floatFromInt(r.x + 20), @floatFromInt(r.y + 20));
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(?usize, 0), app.hover);
    app.dirty = false;
    app.motion(@floatFromInt(r.x + 21), @floatFromInt(r.y + 21));
    try std.testing.expect(!app.dirty);
    app.leave();
    try std.testing.expect(app.dirty);
    app.dirty = false;
    app.leave();
    try std.testing.expect(!app.dirty);
    app.dirty = true; // Motion must retain invalidation from other sources.
    app.motion(300, 250);
    try std.testing.expect(app.dirty);
}

test "desktop motion keeps menu highlights and moving selections live" {
    var app = App{ .worker = undefined, .menu = true, .dirty = false };
    app.menu_layout.layout(100, 100, 3, false);
    app.motion(120, 110);
    try std.testing.expect(!app.dirty);
    app.motion(120, 140);
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(usize, 1), app.menu_selected);
    app.dirty = false;
    app.motion(125, 145);
    try std.testing.expect(!app.dirty);
    app.menu_layout.layout(100, 100, 7, true);
    try std.testing.expectEqual(@as(?usize, null), app.menu_layout.hit(120, 103));
    try std.testing.expectEqual(@as(?usize, null), app.menu_layout.hit(120, 173));
    try std.testing.expectEqual(@as(?usize, 2), app.menu_layout.hit(120, 178));
    try std.testing.expectEqual(@as(f32, context_menu.row_height), app.menu_layout.rows[2].computed_height);
    var builtin_icons = [_]Icon{
        .{ .item = .{ .path = "/home/test", .name = "Home", .icon = null, .builtin = .home }, .cell = .{}, .born = 0 },
        .{ .item = .{ .path = "/home/test/.local/share/Trash/files", .name = "Trash", .icon = null, .builtin = .trash }, .cell = .{ .row = 1 }, .born = 0 },
    };
    app.icons.items = &builtin_icons;
    app.menu_icon = 0;
    try std.testing.expectEqual(@as(usize, 1), app.menuLabels().len);
    try std.testing.expectEqualStrings("Open", app.menuLabels()[0]);
    app.menu_icon = 1;
    try std.testing.expectEqual(@as(usize, 3), app.menuLabels().len);
    try std.testing.expectEqualStrings("Open", app.menuLabels()[0]);
    try std.testing.expectEqualStrings("Empty Trash…", app.menuLabels()[1]);
    try std.testing.expectEqual(@import("ui").layout.IconId.trash, app.menuIcon(1));
    try std.testing.expectEqual(@as(?[]const u8, null), app.menuHint(1));
    try std.testing.expectEqualStrings("Properties", app.menuLabels()[2]);
    try std.testing.expectEqual(@import("ui").layout.IconId.view_list, app.menuIcon(2));
    // Opening and cancelling must not enqueue work (the worker is undefined).
    app.menuAction(1);
    try std.testing.expect(app.edit == .trash);
    try std.testing.expect(app.deletion.empty_trash and app.deletion.permanent);
    app.deleteAction(.toggle);
    try std.testing.expect(app.deletion.permanent);
    app.deleteAction(.cancel);
    try std.testing.expect(app.edit == .none);
    try std.testing.expect(!app.deletion.empty_trash);
    app.icons.items = &.{};
    app.menu_icon = null;
    app.menu = false;
    app.rubber = true;
    app.motion(200, 200);
    try std.testing.expect(app.dirty);
    app.dirty = false;
    app.motion(200, 200);
    try std.testing.expect(!app.dirty);
    app.rubber = false;
    app.pressed = 0;
    app.down_at = nowMs() - 200;
    app.motion(210, 210);
    try std.testing.expect(app.dragging and app.dirty);
    app.dirty = false;
    app.motion(220, 220);
    try std.testing.expect(app.dirty);
}

test "cached desktop names preserve raw label pixels across text and scale changes" {
    var cache = NameCache{};
    defer cache.deinit();
    for (1..5) |factor| {
        const scale: i32 = @intCast(factor);
        const w = 104 * scale;
        const h = 52 * scale;
        for ([_][]const u8{ "Short", "A long file name that wraps.txt", "日本語.desktop", "" }) |name| {
            const expected = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h).?;
            defer c.cairo_surface_destroy(expected);
            const actual = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h).?;
            defer c.cairo_surface_destroy(actual);
            const raw_cr = c.cairo_create(expected).?;
            defer c.cairo_destroy(raw_cr);
            const cached_cr = c.cairo_create(actual).?;
            defer c.cairo_destroy(cached_cr);
            for ([_]*c.cairo_t{ raw_cr, cached_cr }) |cr| {
                c.cairo_set_source_rgba(cr, 0.07, 0.13, 0.21, 0.7);
                c.cairo_paint(cr);
                c.cairo_scale(cr, @floatFromInt(scale), @floatFromInt(scale));
            }
            drawName(raw_cr, name, 7, 9);
            cache.draw(cached_cr, name, 7, 9);
            c.cairo_surface_flush(expected);
            c.cairo_surface_flush(actual);
            const len: usize = @intCast(w * h * 4);
            try std.testing.expectEqualSlices(u8, c.cairo_image_surface_get_data(expected)[0..len], c.cairo_image_surface_get_data(actual)[0..len]);
            const saved = cache.surface;
            cache.draw(cached_cr, name, 3, 5);
            try std.testing.expectEqual(saved, cache.surface);
        }
    }
}

test "rubberband damage coalesces motion before presentation" {
    var app = App{ .worker = undefined, .rubber = true, .down_x = 100, .down_y = 100, .x = 200, .y = 200 };
    app.presented();
    for (0..1000) |i| app.motion(@floatFromInt(200 + i), @floatFromInt(200 + i));
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(usize, 0), app.damage.len);
    app.prepareDamage();
    try std.testing.expect(!app.damage.full);
    // Up to four edge strips per band, plus both bands' rounded corners.
    try std.testing.expect(app.damage.len <= 16);
    try std.testing.expect(!app.damage.intersects(.{ .x = 130, .y = 130, .w = 20, .h = 20 }));
    app.presented();
    app.rubber = false;
    app.prepareDamage();
    try std.testing.expect(app.damage.intersects(.{ .x = 130, .y = 130, .w = 20, .h = 20 }));
}

test "icon group cache matches fresh pixels after visual and content changes" {
    var icons = [_]Icon{.{ .item = try copyItem(.{ .path = "", .name = "Alpha icon", .icon = null }), .cell = .{}, .born = 0 }};
    defer {
        freeItem(icons[0].item);
        icons[0].name_cache.deinit();
        icons[0].raster.deinit();
    }
    var app = App{ .worker = undefined, .geometry = .{ .w = 200, .h = 240 }, .icons = .fromOwnedSlice(&icons) };
    defer app.edit_text.deinit(a);
    defer app.rename_editor.deinit();
    const ic = &icons[0];
    // Populate the cache through a small clip first, then reuse it on another
    // target's full clip. Damage must not affect the cached icon's raster bounds.
    const small = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 200, 240).?;
    defer c.cairo_surface_destroy(small);
    const small_cr = c.cairo_create(small).?;
    defer c.cairo_destroy(small_cr);
    var part = Damage{};
    part.clear();
    part.add(.{ .x = 150, .y = 30, .w = 20, .h = 60 });
    app.paintAt(small_cr, &part, 1000, true);
    const initial = ic.raster.pattern;
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1000);
    try std.testing.expectEqual(initial, ic.raster.pattern);

    for ([_][2]f64{ .{ 0.3, 0 }, .{ 1, 0 }, .{ 1, 0.4 }, .{ 0, 1 }, .{ 0, 0.2 }, .{ 0, 0 } }) |amount| {
        ic.hover_amount = amount[0];
        ic.selection_amount = amount[1];
        try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1000);
    }
    ic.selected = true;
    app.edit = .rename;
    try app.rename_editor.begin("Alpha icon", false);
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1000);
    app.rename_editor.key(c.XKB_KEY_End, "", false, false);
    app.rename_editor.key(0, " renamed", false, false);
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1000);
    ic.replaceItem(try copyItem(.{ .path = "", .name = "Beta icon", .icon = null }));
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1000);
    const blue = @as([4]u32, @splat(0xff2040e0));
    const red = @as([4]u32, @splat(0xffe04020));
    for ([_]?@import("../icon_cache.zig").Entry{ .{ .pixels = &blue, .size = 2 }, .{ .pixels = &red, .size = 2 }, null }) |icon| {
        ic.replaceItem(try copyItem(.{ .path = "", .name = "Beta icon", .icon = icon }));
        try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1000);
    }
    app.edit = .none;
    app.launching_until = 2000;
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1000);
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1200);
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1250);
    app.launching_until = 0;
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1200);
    const opaque_pattern = ic.raster.pattern;
    ic.born = 1150;
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1200);
    try std.testing.expectEqual(opaque_pattern, ic.raster.pattern);
    ic.born = 0;
    ic.removed = 1150;
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1200);
    try std.testing.expectEqual(opaque_pattern, ic.raster.pattern);
    ic.removed = null;
    app.dragging = true;
    app.pressed = 0;
    // The dragged icon is centred on the pointer: this puts it exactly on its cell.
    const cell = app.geometry.rect(.{});
    app.x = @floatFromInt(cell.x + @divTrunc(cell.w, 2));
    app.y = @floatFromInt(cell.y + 40);
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1200);
    try std.testing.expectEqual(opaque_pattern, ic.raster.pattern);
    app.dragging = false;
    app.pressed = null;
    for ([_]i32{ 2, 3, 1 }) |scale| try expectFreshIconPixels(&app, 200 * scale, 240 * scale, @floatFromInt(scale), 0, 1, 0, 1200);
    // Actual target dimensions can clip a group even with unchanged app geometry.
    try expectFreshIconPixels(&app, 110, 90, 1, 0, 1, 0, 1200);
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1200);
    try expectFreshIconPixels(&app, 200, 240, 1, -37, 1, 0, 1200);
    try expectFreshIconPixels(&app, 400, 480, 1, 0, 2, 0, 1200);
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, -19, 1200);
    ic.cell.row = 1;
    try expectFreshIconPixels(&app, 200, 240, 1, 0, 1, 0, 1200);
}

fn expectFreshIconPixels(app: *App, w: i32, h: i32, scale: f64, translate: f64, device_scale: f64, device_offset: f64, now: i64) !void {
    const actual = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h).?;
    defer c.cairo_surface_destroy(actual);
    const expected = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, w, h).?;
    defer c.cairo_surface_destroy(expected);
    for ([_]*c.cairo_surface_t{ actual, expected }) |surface| {
        c.cairo_surface_set_device_scale(surface, device_scale, device_scale);
        c.cairo_surface_set_device_offset(surface, device_offset, device_offset);
    }
    const actual_cr = c.cairo_create(actual).?;
    defer c.cairo_destroy(actual_cr);
    const expected_cr = c.cairo_create(expected).?;
    defer c.cairo_destroy(expected_cr);
    for ([_]*c.cairo_t{ actual_cr, expected_cr }) |cr| {
        c.cairo_scale(cr, scale, scale);
        c.cairo_translate(cr, translate, translate);
    }
    const full = Damage{};
    app.paintAt(actual_cr, &full, now, true);
    // Always rebuild the reference group, even if the same App has a cache.
    app.paintAt(expected_cr, &full, now, false);
    c.cairo_surface_flush(actual);
    c.cairo_surface_flush(expected);
    const len: usize = @intCast(w * h * 4);
    try std.testing.expectEqualSlices(u8, c.cairo_image_surface_get_data(expected)[0..len], c.cairo_image_surface_get_data(actual)[0..len]);
}
