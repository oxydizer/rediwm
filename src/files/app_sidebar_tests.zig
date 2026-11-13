//! Files sidebar and list tests: column resizing, Places menus, pins, devices and file context actions.

const std = @import("std");
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const recent = @import("recent.zig");
const volumes_mod = @import("volumes.zig");
const deletion = @import("../delete_dialog.zig");
const pins_mod = @import("pins.zig");
const MenuKind = @import("app_model.zig").MenuKind;
const FileAction = @import("app_model.zig").FileAction;
const Sort = @import("app_model.zig").Sort;
const app_model = @import("app_model.zig");
const app_tests = @import("app_tests.zig");
const testApp = app_tests.testApp;
const testItems = app_tests.testItems;

test "sidebar accordion defaults to Places without changing Git branch expansion" {
    var app = try testApp();
    defer app.deinit();

    try std.testing.expectEqual(app_model.SidebarSection.places, app.sidebar_section);
    try std.testing.expect(!app.sidebar_section_selected);
    try std.testing.expect(app.git_expanded);
}

test "sidebar layout uses shared headers and only expanded visible body" {
    const body_heights = [_]i32{ 80, 40, 64, 120 };
    const visible = [_]bool{ true, true, false, true };

    const places_expanded = app_model.SidebarLayout.init(
        100,
        body_heights,
        visible,
        .places,
    );
    const places = places_expanded.cards[@intFromEnum(app_model.SidebarSection.places)];
    const disks = places_expanded.cards[@intFromEnum(app_model.SidebarSection.disks)];
    const git = places_expanded.cards[@intFromEnum(app_model.SidebarSection.git)];
    const transfers = places_expanded.cards[@intFromEnum(app_model.SidebarSection.transfers)];

    try std.testing.expectEqual(@as(i32, 100), places.y);
    try std.testing.expectEqual(@as(i32, 112), places.height());
    try std.testing.expectEqual(@as(i32, 220), disks.y);
    try std.testing.expectEqual(@as(i32, 32), disks.height());
    try std.testing.expect(!git.visible);
    try std.testing.expectEqual(@as(i32, 260), transfers.y);
    try std.testing.expectEqual(@as(i32, 32), transfers.height());

    const transfers_expanded = app_model.SidebarLayout.init(
        100,
        body_heights,
        visible,
        .transfers,
    );
    const collapsed_places = transfers_expanded.cards[@intFromEnum(app_model.SidebarSection.places)];
    const collapsed_disks = transfers_expanded.cards[@intFromEnum(app_model.SidebarSection.disks)];
    const expanded_transfers = transfers_expanded.cards[@intFromEnum(app_model.SidebarSection.transfers)];

    try std.testing.expectEqual(@as(i32, 32), collapsed_places.height());
    try std.testing.expectEqual(@as(i32, 140), collapsed_disks.y);
    try std.testing.expectEqual(@as(i32, 180), expanded_transfers.y);
    try std.testing.expectEqual(@as(i32, 152), expanded_transfers.height());
}

test "sidebar header clicks select sections without collapsing the active card" {
    var app = try testApp();
    defer app.deinit();

    try std.testing.expectEqual(app_model.SidebarSection.places, app.sidebar_section);
    try std.testing.expect(!app.sidebar_section_selected);

    const layout = app.sidebarLayout();
    const disks = layout.cards[@intFromEnum(app_model.SidebarSection.disks)];
    try std.testing.expect(disks.visible);
    const x: f64 = 32;
    const y: f64 = @floatFromInt(disks.y + @divTrunc(disks.header_height, 2));

    try std.testing.expectEqual(app_model.SidebarSection.disks, app.sidebarHeaderAt(x, y).?);
    app.handleMotion(x, y);
    app.handleButton(0x110, true);

    try std.testing.expectEqual(app_model.SidebarSection.disks, app.sidebar_section);
    try std.testing.expect(app.sidebar_section_selected);
    try std.testing.expect(app.sidebarLayout().cards[@intFromEnum(app_model.SidebarSection.disks)].expanded);

    // Recompute its position after Places collapses. Clicking the active
    // header is idempotent, not a collapse toggle.
    const selected_disks = app.sidebarLayout().cards[@intFromEnum(app_model.SidebarSection.disks)];
    const selected_y: f64 = @floatFromInt(selected_disks.y + @divTrunc(selected_disks.header_height, 2));
    app.handleMotion(x, selected_y);
    app.handleButton(0x110, true);
    try std.testing.expectEqual(app_model.SidebarSection.disks, app.sidebar_section);
    try std.testing.expect(app.sidebarLayout().cards[@intFromEnum(app_model.SidebarSection.disks)].expanded);

    const body_y: f64 = @floatFromInt(selected_disks.y + selected_disks.header_height + 1);
    try std.testing.expectEqual(@as(?app_model.SidebarSection, null), app.sidebarHeaderAt(x, body_y));
    try std.testing.expectEqual(@as(?app_model.SidebarSection, null), app.sidebarHeaderAt(-1, selected_y));
}

test "list column resize pushes following columns and scrolls in Files and chooser" {
    for ([_]bool{ false, true }) |chooser| {
        var app = try testApp();
        defer app.deinit();
        if (chooser) try app.configureChooser(.{ .mode = .open });
        app.list_view = true;
        try testItems(&app, 20);
        const original = app.listWidths();
        const last = app.listColumn(4);
        const rect = app.listColumn(3);
        const x = rect.x + rect.w;
        const y = rect.y + 15;
        try std.testing.expectEqualStrings("col-resize", std.mem.span(app.pointerCursor(x, y)));
        app.handleMotion(x, y);
        app.handleButton(0x110, true);
        app.handleMotion(x + 120, y + 100);
        const widths = app.listWidths();
        for (original, 0..) |width, i| {
            try std.testing.expectApproxEqAbs(width + (if (i == 3) @as(f64, 120) else 0), widths[i], 0.001);
        }
        try std.testing.expectApproxEqAbs(last.x + 120, app.listColumn(4).x, 0.001);
        app.handleButton(0x110, false);
        try std.testing.expect(app.column_resize == null);
        try std.testing.expectEqual(Sort.name, app.sort_mode);
        const bar = app.horizontalScrollbar().?;
        try std.testing.expectEqual(@as(?usize, null), app.itemAt(bar.track.x + 40, bar.track.y + 1));
        try std.testing.expectEqual(@as(?[]const u8, null), app.dropDirectoryAt(bar.track.x + 40, bar.track.y + 1));
        const thumb_x = bar.thumb.x + bar.thumb.w / 2;
        const thumb_y = bar.thumb.y + bar.thumb.h / 2;
        app.handleMotion(thumb_x, thumb_y);
        app.handleButton(0x110, true);
        try std.testing.expect(app.horizontal_drag.active);
        app.handleMotion(@floatFromInt(app.w + 100), thumb_y);
        try std.testing.expectApproxEqAbs(@as(f64, 120), app.horizontalOffset(), 0.001);
        try std.testing.expectApproxEqAbs(last.x, app.listColumn(4).x, 0.001);
        app.handleButton(0x110, false);
        try std.testing.expect(!app.horizontal_drag.active);
        app.shift = true;
        app.handleWheel(-60, 1000);
        try std.testing.expectApproxEqAbs(@as(f64, 60), app.horizontalOffset(), 0.001);
        app.shift = false;
        app.handleHorizontalScroll(-1000);
        try std.testing.expectEqual(@as(f64, 0), app.horizontalOffset());
        app.resize(360, 400);
        try std.testing.expectEqualDeep(widths, app.listWidths());
        try std.testing.expect(app.horizontalScrollbar() != null);
        app.resize(1600, 600);
        try std.testing.expect(app.horizontalScrollbar() == null);
        try std.testing.expectEqual(@as(f64, 0), app.horizontalOffset());
        // Shrinking clamps only the dragged column.
        const name = app.listColumn(0);
        app.handleMotion(name.x + name.w, name.y + 15);
        app.handleButton(0x110, true);
        app.handleMotion(-1000, name.y + 15);
        app.handleButton(0x110, false);
        try std.testing.expectEqual(@as(f64, 64), app.listWidths()[0]);
        try std.testing.expectEqualSlices(f64, widths[1..], app.listWidths()[1..]);
        app.list_view = false;
        try std.testing.expect(app.horizontalScrollbar() == null);
    }
}

test "sidebar menus unpin only Places and close gaps without changing selection" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 2);
    app.items.items[0].selected = true;
    const y = app.placeY(App.places_start);
    const last_place_y = app.placeY(App.pin_base - 1);
    app.handleMotion(70, @floatFromInt(y + 10));
    app.handleButton(0x111, true);
    try std.testing.expectEqual(MenuKind.sidebar, app.menu.?);
    try std.testing.expectEqualStrings("Open in New Window", app.menuLabels()[1]);
    try std.testing.expectEqualStrings("Unpin", app.menuLabels()[2]);
    try std.testing.expectEqualStrings("Properties", app.menuLabels()[3]);
    app.runMenu(3); // Properties must not alter pinned places.
    app.closeDialog();
    try std.testing.expect(app.placeVisible(App.places_start));
    app.openMenu(.sidebar, 70, @floatFromInt(y));
    app.runMenu(2);
    try std.testing.expect(!app.placeVisible(App.places_start));
    try std.testing.expectEqual(y, app.placeY(App.places_start + 1));
    try std.testing.expectEqual(@as(?usize, App.places_start + 1), app.placeAt(70, @floatFromInt(y + 10)));
    try std.testing.expectEqual(last_place_y - app.placeStep(), app.placeY(App.pin_base - 1));
    try std.testing.expect(app.items.items[0].selected);
    for ([_]usize{ 0, 1 }) |index| {
        app.menu_place = index;
        app.openMenu(.sidebar, 70, 140);
        try std.testing.expectEqual(@as(usize, if (index == 1) 4 else 3), app.menuLabels().len);
        try std.testing.expectEqualStrings("Properties", app.menuLabels()[app.menuLabels().len - 1]);
        if (index == 1) {
            try std.testing.expectEqualStrings("Empty Trash…", app.menuLabels()[2]);
            app.runMenu(2);
            try std.testing.expect(app.dialog.?.deletion.empty_trash);
            try std.testing.expect(app.dialog.?.deletion.permanent);
            try std.testing.expectEqual(deletion.Action.none, app.dialog.?.deletion.key(c.XKB_KEY_Tab));
            try std.testing.expectEqual(deletion.Action.confirm, app.dialog.?.deletion.key(c.XKB_KEY_Return));
            app.deleteAction(.toggle);
            try std.testing.expect(app.dialog.?.deletion.permanent);
            app.deleteAction(.cancel);
            try std.testing.expect(app.dialog == null);
            app.openMenu(.sidebar, 70, 140);
        }
        app.runMenu(app.menuLabels().len - 1);
        try std.testing.expect(app.placeVisible(index));
    }
    app.menu_place = 2;
    app.openMenu(.sidebar, 70, 210);
    try std.testing.expectEqualStrings("Open", app.menuLabels()[0]);
    try std.testing.expectEqualStrings("Open in New Window", app.menuLabels()[1]);
    try std.testing.expectEqual(@as(usize, 0), app.menuSeparatorSpace());
    app.menu = null;
    try std.testing.expect(app.placeVisible(2));
    try std.testing.expectEqual(app.placeY(1) + app.placeStep(), app.placeY(2));
    for (App.places_start..App.pin_base) |index| {
        app.menu_place = index;
        app.openMenu(.sidebar, 70, 140);
        app.runMenu(2);
    }
    try std.testing.expectEqual(@as(u8, 0x7f), app.unpinned_places);
    try std.testing.expectEqual(@as(?usize, null), app.placeAt(70, @floatFromInt(y + 10)));
    app.closeDialog();
    try app.history.navigate(recent.location);
    try std.testing.expect(!app.history.canUp());
    try std.testing.expect(!app.toolbarButtonEnabled(.new));
    try std.testing.expect(!app.toolbarButtonEnabled(.paste));
    try std.testing.expectEqual(Sort.modified, app.effectiveSort());
    try std.testing.expectEqual(@as(?[]const u8, null), app.dropDirectoryAt(500, 300));
    app.openNewFolderDialog();
    try std.testing.expect(app.dialog == null);
    try std.testing.expect(app.placeActive(2));
}

test "pins sit after Projects, take drops by gap and keep the rows in drawn order" {
    var app = try testApp();
    defer app.deinit();
    app.h = 1000;
    const step = app.placeStep();
    const places_bottom = app.placeY(App.pin_base - 1);
    app.pinDropped(0, &.{ "/usr", "/dev/null", "/usr/", "/nonexistent-rediwm-pin", "relative" });
    try std.testing.expectEqual(@as(usize, 2), app.pins.items.items.len);
    try std.testing.expectEqualStrings("usr", app.pins.items.items[0].name());
    try std.testing.expectEqual(pins_mod.Kind.file, app.pins.items.items[1].kind);

    // Pins take the rows after Projects; the devices follow.
    try std.testing.expectEqual(App.pin_base + 2, app.deviceBase());
    try std.testing.expectEqual(app.placeY(App.pin_base - 1) + step, app.placeY(App.pin_base));
    try std.testing.expectEqual(places_bottom + 2 * step, app.placeY(App.pin_base + 1));
    const volumes = [_]volumes_mod.Volume{.{ .id = "/b/sdb1", .label = "STICK", .mount = null, .size = 1 << 30, .kind = .stick }};
    app.device_list.items = &volumes;
    try std.testing.expectEqual(App.pin_base + 2, app.deviceBase());
    try std.testing.expectEqual(app.placeY(App.pin_base + 1) + 44 + step, app.placeY(app.deviceBase()));
    try std.testing.expectEqual(@as(?usize, App.pin_base + 1), app.placeAt(70, @floatFromInt(app.placeY(App.pin_base + 1) + 10)));
    app.handleMotion(70, @floatFromInt(app.placeY(App.pin_base + 1) + 10));
    try std.testing.expectEqual(@as(usize, 801), app.hoverKey());
    app.device_list.items = &.{};

    // A drag snaps to the nearest gap from anywhere on PLACES, and only there.
    const desktop: f64 = @floatFromInt(app.placeY(App.places_start) + 10);
    const first_gap = app.pinBoundary(0);
    try std.testing.expectEqual(@as(?usize, 0), app.pinSlotAt(70, desktop));
    try std.testing.expectEqual(@as(?usize, 0), app.pinSlotAt(70, first_gap + 4));
    try std.testing.expectEqual(@as(?usize, 1), app.pinSlotAt(70, app.pinBoundary(1) - 4));
    try std.testing.expectEqual(@as(?usize, 2), app.pinSlotAt(70, app.pinBoundary(2) + 10));
    try std.testing.expectEqual(@as(?usize, null), app.pinSlotAt(70, @floatFromInt(app.placeY(0) + 10)));
    try std.testing.expectEqual(@as(?usize, null), app.pinSlotAt(70, app.pinBoundary(2) + 40));
    try std.testing.expectEqual(@as(?usize, null), app.pinSlotAt(400, desktop));
    try std.testing.expect(app.dropMotion(70, first_gap + 4));
    try std.testing.expectEqual(@as(?usize, 0), app.pin_drop);
    try std.testing.expect(app.dirty);
    try std.testing.expectEqual(@as(?usize, 0), app.takePinDrop());
    try std.testing.expectEqual(@as(?usize, null), app.pin_drop);
    try std.testing.expect(!app.dropMotion(400, desktop));

    // The Trash row is a drop target of its own, above the pins' gaps.
    const trash_row: f64 = @floatFromInt(app.placeY(App.trash_place) + 10);
    try std.testing.expect(app.trashDropAt(70, trash_row));
    try std.testing.expect(!app.trashDropAt(70, @floatFromInt(app.placeY(0) + 10)));
    try std.testing.expect(!app.trashDropAt(70, desktop));
    try std.testing.expectEqual(@as(?usize, null), app.pinSlotAt(70, trash_row));
    app.dirty = false;
    app.setTrashDrop(true);
    try std.testing.expect(app.dirty);
    try std.testing.expect(app.takeTrashDrop());
    try std.testing.expect(!app.trash_drop);
    app.setTrashDrop(true);
    app.dropLeave();
    try std.testing.expect(!app.trash_drop);

    // Dropping on a gap inserts there; what is listed already, built in or
    // gone is refused.
    app.pinDropped(1, &.{"/etc"});
    try std.testing.expectEqualStrings("etc", app.pins.items.items[1].name());
    try std.testing.expectEqual(@as(usize, 3), app.pins.items.items.len);
    // The test app's home is /tmp.
    app.pinDropped(0, &.{"/tmp"});
    try std.testing.expectEqual(@as(usize, 3), app.pins.items.items.len);
    try std.testing.expectEqualStrings("Already in Places", app.status_notice.?);

    // Only a pin offers removal, which closes the gap again.
    app.menu_place = App.pin_base + 1;
    app.openMenu(.sidebar, 70, 140);
    try std.testing.expectEqualStrings("Open in New Window", app.menuLabels()[1]);
    try std.testing.expectEqualStrings("Remove from Places", app.menuLabels()[2]);
    app.runMenu(2);
    try std.testing.expectEqual(@as(usize, 2), app.pins.items.items.len);
    try std.testing.expectEqualStrings("null", app.pins.items.items[1].name());
    app.menu = .sidebar;
    try std.testing.expectEqualStrings("Remove from Places", app.menuLabels()[1]); // File pins keep their file actions.
    app.pins.items.items[1].kind = .missing;
    try std.testing.expectEqualStrings("Remove from Places", app.menuLabels()[1]);
    app.chooser = .{ .mode = .open };
    app.menu_place = App.pin_base;
    try std.testing.expectEqualStrings("Remove from Places", app.menuLabels()[1]);
    app.menu_place = 0;
    try std.testing.expectEqualStrings("Properties", app.menuLabels()[1]);
    try std.testing.expectEqual(places_bottom + 2 * step, app.placeY(App.pin_base + 1));
}

test "Sidebar separates Disks from Places; only mounted volumes eject" {
    var app = try testApp();
    defer app.deinit();
    app.h = 1000;
    const extent = app.sidebarExtent();
    const last_place_y = app.placeY(App.pin_base - 1);
    const volumes = [_]volumes_mod.Volume{
        .{ .id = "/b/sdb1", .label = "STICK", .mount = "/run/media/user/STICK", .size = 1 << 30, .kind = .stick },
        .{ .id = "/b/sda1", .label = "", .mount = null, .size = 500 << 30, .kind = .drive },
    };
    app.device_list.items = &volumes;
    const mounted = app.deviceBase();
    const unmounted = mounted + 1;
    const step = app.placeStep();
    try std.testing.expectEqual(last_place_y + 44 + step, app.placeY(mounted));
    try std.testing.expectEqual(app.placeY(mounted) + step, app.placeY(unmounted));
    // Places is expanded by default; the collapsed Disks card keeps its
    // compact height when volumes are added.
    try std.testing.expectEqual(extent, app.sidebarExtent());

    const row_y: f64 = @floatFromInt(app.placeY(mounted) + 10);
    try std.testing.expectEqual(@as(?usize, mounted), app.placeAt(70, row_y));
    const button = app.ejectRect(mounted);
    try std.testing.expectEqual(@as(?usize, 0), app.ejectAt(button.x + 5, button.y + 5));
    try std.testing.expectEqual(@as(?usize, null), app.ejectAt(70, row_y));
    const other = app.ejectRect(unmounted);
    try std.testing.expectEqual(@as(?usize, null), app.ejectAt(other.x + 5, other.y + 5));
    app.handleMotion(button.x + 5, button.y + 5);
    try std.testing.expectEqual(@as(usize, 700), app.hoverKey());
    app.handleMotion(70, row_y);
    try std.testing.expectEqual(@as(usize, 600), app.hoverKey());
    app.handleMotion(70, @floatFromInt(app.placeY(unmounted) + 10));
    try std.testing.expectEqual(@as(usize, 601), app.hoverKey());

    app.menu = .device;
    app.menu_place = mounted;
    try std.testing.expectEqualStrings("Open in New Window", app.menuLabels()[1]);
    try std.testing.expectEqualStrings("Eject", app.menuLabels()[2]);
    app.menu_place = unmounted;
    try std.testing.expectEqual(@as(usize, 1), app.menuLabels().len);
    try std.testing.expectEqualStrings("Mount", app.menuLabels()[0]);

    // Results end the operation and say what happened; a mount only opens
    // the volume if the view has not moved on meanwhile.
    var result = std.mem.zeroes(volumes_mod.Result);
    @memcpy(result.object[0..7], "/b/sdb1");
    app.device_op = .{ .id = try std.testing.allocator.dupe(u8, "/b/sdb1"), .unmount = true, .open = false, .navigation = app.navigation_count };
    result.ok = 1;
    app.deviceResult(&result);
    try std.testing.expect(app.device_op == null);
    try std.testing.expectEqualStrings("STICK can be safely removed", app.status_notice.?);
    app.device_op = .{ .id = try std.testing.allocator.dupe(u8, "/b/sdb1"), .unmount = true, .open = false, .navigation = app.navigation_count };
    result.ok = 0;
    @memcpy(result.code[0.."org.freedesktop.UDisks2.Error.DeviceBusy".len], "org.freedesktop.UDisks2.Error.DeviceBusy");
    app.deviceResult(&result);
    try std.testing.expectEqualStrings("STICK is busy", app.status_notice.?);
    result = std.mem.zeroes(volumes_mod.Result);
    @memcpy(result.object[0..7], "/b/sda1");
    @memcpy(result.path[0..6], "/mnt/a");
    result.ok = 1;
    app.device_op = .{ .id = try std.testing.allocator.dupe(u8, "/b/sda1"), .unmount = false, .open = true, .navigation = app.navigation_count -% 1 };
    app.deviceResult(&result);
    try std.testing.expectEqualStrings("500.0 GB Volume mounted", app.status_notice.?);
}

test "File context actions distinguish files, folders and symlinks" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 2);
    app.items.items[0].selected = true;
    app.items.items[0].is_dir = false;
    app.menu = .file;
    try std.testing.expectEqual(@as(usize, 8), app.menuLabels().len);
    try std.testing.expectEqualStrings("Open With…", app.menuLabels()[1]);
    try std.testing.expectEqualStrings("Cut", app.menuLabels()[2]);
    try std.testing.expectEqualStrings("Properties", app.menuLabels()[7]);
    try std.testing.expectEqualStrings("F2", app.menuHint(5).?);
    try std.testing.expectEqual(@as(usize, 14), app.menuSeparatorSpace());
    app.items.items[0].is_symlink = true;
    try std.testing.expect(app.canOpenWith());
    app.items.items[0].is_broken = true;
    try std.testing.expect(!app.canOpenWith());
    app.items.items[0].is_broken = false;
    app.items.items[1].selected = true;
    app.items.items[1].is_dir = true;
    try std.testing.expectEqualStrings("Calculate size", app.menuLabels()[6]);
    try std.testing.expectEqualStrings("Cut", app.menuLabels()[1]);
    app.items.items[1].is_symlink = true;
    try std.testing.expectEqual(@as(usize, 7), app.menuLabels().len);
    app.items.items[1].selected = false;
    app.items.items[0].name = "Hub.AppImage";
    app.items.items[0].path = "/Hub.AppImage";
    try std.testing.expectEqualStrings("/Hub.AppImage", app.selectedAppImage().?);
    try std.testing.expectEqualStrings("Add to applications", app.menuLabels()[2]);
    app.items.items[1].selected = true;
    try std.testing.expect(app.selectedAppImage() == null);
    app.items.items[1].selected = false;
    app.items.items[0].missing = true;
    try std.testing.expect(app.selectedAppImage() == null);
    app.items.items[0].missing = false;
    app.chooser = .{ .mode = .open };
    try std.testing.expect(app.selectedAppImage() == null);
    app.chooser = null;
    app.items.items[0].name = "example.ZIP";
    app.items.items[0].path = "/example.ZIP";
    try std.testing.expectEqualStrings("Extract", app.menuLabels()[2]);
    try std.testing.expectEqualStrings("Extract to…", app.menuLabels()[3]);
    try std.testing.expectEqual(FileAction.rename, app.fileActions()[7]);
    app.items.items[1].selected = true;
    try std.testing.expect(app.selectedArchive() == null);
    app.items.items[1].selected = false;
    try app.history.navigateLocation("/example.ZIP", "/example.ZIP".len);
    app.menu = .file;
    try std.testing.expectEqualSlices(FileAction, &.{.open}, app.fileActions());
    app.openNewFolderDialog();
    app.openRenameDialog();
    try std.testing.expect(app.dialog == null);
    try std.testing.expect(!app.executePaste(.copy, &.{"/tmp/a"}));
}
