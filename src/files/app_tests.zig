//! Tests for the Files App: layout, hit testing, hover, scrolling and sidebar.

const std = @import("std");
const App = @import("app.zig").App;
const scrollbar = @import("ui").widgets.scrollbar;
const anim = @import("ui").anim;
const c = @import("c.zig").api;
const worker_mod = @import("worker.zig");
const history_mod = @import("history.zig");
const recent = @import("recent.zig");
const volumes_mod = @import("volumes.zig");
const icons = @import("../icon_cache.zig");
const deletion = @import("../delete_dialog.zig");
const header = @import("header.zig");
const ui_theme = @import("ui").theme;
const pins_mod = @import("pins.zig");
const column_labels = App.column_labels;
const places = App.places;
const places_start = App.places_start;
const pin_base = App.pin_base;
const MenuKind = @import("app_model.zig").MenuKind;
const FileAction = @import("app_model.zig").FileAction;
const Sort = @import("app_model.zig").Sort;
const SizeState = @import("app_model.zig").SizeState;
const ViewItem = @import("app_model.zig").ViewItem;
const nowMs = @import("app_draw.zig").nowMs;
const clipDamage = @import("app_draw.zig").clipDamage;
const measureText = @import("app_draw.zig").measureText;

test "grid hit testing respects gutters, scrolling and responsive columns" {
    var app = App{
        .allocator = std.testing.allocator,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = .{ .allocator = std.testing.allocator, .current = "/" },
        .home_dir = "/",
        .items_arena = undefined,
    };
    app.w = 960;
    app.h = 640;
    app.list_view = false;
    app.scroll_y = 0;
    var items: [20]ViewItem = undefined;
    app.items = .fromOwnedSlice(&items);
    try std.testing.expectEqual(@as(i32, 3), app.columns());
    try std.testing.expectEqual(@as(?usize, 0), app.itemAt(250, 158));
    try std.testing.expectEqual(@as(?usize, 1), app.itemAt(490, 158));
    try std.testing.expectEqual(@as(?usize, 3), app.itemAt(250, 308));
    try std.testing.expectEqual(@as(?usize, null), app.itemAt(220, 158));
    try std.testing.expectEqual(@as(?usize, null), app.itemAt(450, 158));
    try std.testing.expectEqual(@as(?usize, null), app.itemAt(250, 248));
    app.scroll_y = 156;
    try std.testing.expectEqual(@as(?usize, 3), app.itemAt(250, 158));
    app.revealIndex(19);
    try std.testing.expect(app.scroll_y > 156);
    app.resize(360, 240);
    try std.testing.expectEqual(@as(i32, 0), app.sidebarWidth());
    try std.testing.expectEqual(@as(i32, 1), app.columns());
    app.scroll_y = 0;
    try std.testing.expectEqual(@as(?usize, 0), app.itemAt(30, 180));
}

test "search and sorting preserve visible selection across snapshot rebuilds" {
    const allocator = std.testing.allocator;
    var source = [_]worker_mod.Item{
        .{ .name = "zeta.txt", .path = "/zeta.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 200, .mtime = 1, .icon_name = "" },
        .{ .name = "alpha.txt", .path = "/alpha.txt", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 10, .mtime = 2, .icon_name = "" },
        .{ .name = "Documents", .path = "/Documents", .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 0, .mtime = 3, .icon_name = "" },
    };
    var snap = worker_mod.Snapshot{ .arena = undefined, .request_id = 1, .dir = "/", .items = &source };
    var app = App{
        .allocator = allocator,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = .{ .allocator = std.testing.allocator, .current = "/" },
        .home_dir = "/",
        .items_arena = std.heap.ArenaAllocator.init(allocator),
        .snapshot = &snap,
        .folder_sizes = std.StringHashMap(SizeState).init(allocator),
    };
    defer app.folder_sizes.deinit();
    defer app.items_arena.deinit();
    defer app.items.deinit(allocator);
    defer app.search.text.deinit(allocator);
    app.rebuildView();
    try std.testing.expectEqualStrings("Documents", app.items.items[0].name);
    app.items.items[1].selected = true;
    app.focused_index = 1;
    app.selection_anchor = 1;
    app.sort_mode = .size;
    app.rebuildView();
    try std.testing.expectEqualStrings("zeta.txt", app.items.items[1].name);
    try std.testing.expectEqual(@as(?usize, 2), app.focused_index);
    try std.testing.expect(app.items.items[2].selected);
    try app.search.text.appendSlice(allocator, "ALPHA");
    app.rebuildView();
    try std.testing.expectEqual(@as(usize, 1), app.items.items.len);
    try std.testing.expect(app.items.items[0].selected);
    app.folders_only = true;
    app.rebuildView();
    try std.testing.expectEqual(@as(usize, 0), app.items.items.len);
    try std.testing.expectEqual(@as(?usize, null), app.focused_index);
    app.search.text.clearRetainingCapacity();
    app.rebuildView();
    try std.testing.expectEqualStrings("Documents", app.items.items[0].name);
}

test "Unicode folder filtering and sorting retain folder size and date rules" {
    const listing = @import("app_listing.zig");
    var app: App = .{ .allocator = std.testing.allocator, .io = undefined, .environ = undefined, .theme_cfg = undefined, .worker = undefined, .history = .{ .allocator = std.testing.allocator, .current = "/" }, .home_dir = "/", .items_arena = undefined };
    defer app.search.text.deinit(app.allocator);
    const source: worker_mod.Item = .{ .name = "CÁMARA — Терминал", .path = "/name", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 10, .mtime = 20, .icon_name = "" };
    for ([_][]const u8{ "camara", "Cámara", "терм", "ТЕРМ" }) |query| {
        app.search.text.clearRetainingCapacity();
        try app.search.text.appendSlice(app.allocator, query);
        try std.testing.expect(app.matches(source));
    }
    var a: ViewItem = .{ .name = "z", .path = "/z", .sort_key = "a", .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 10, .mtime = 20, .icon_name = "" };
    var b: ViewItem = .{ .name = "a", .path = "/a", .sort_key = "z", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 100, .mtime = 30, .icon_name = "" };
    try std.testing.expect(listing.lessThan(.name, a, b));
    try std.testing.expect(listing.lessThan(.size, a, b));
    try std.testing.expect(listing.lessThan(.modified, b, a));
    try std.testing.expect(listing.lessThan(.modified_asc, a, b));
    a.is_dir = false;
    try std.testing.expect(listing.lessThan(.name, a, b));
    try std.testing.expect(listing.lessThan(.name_desc, b, a));
    try std.testing.expect(listing.lessThan(.size, b, a));
    b.bytes = a.bytes;
    try std.testing.expect(listing.lessThan(.size, a, b));
}

test "context menu stays inside the client and keyboard activation closes it" {
    var app = App{
        .allocator = std.testing.allocator,
        .io = undefined,
        .environ = undefined,
        .theme_cfg = undefined,
        .worker = undefined,
        .history = .{ .allocator = std.testing.allocator, .current = "/" },
        .home_dir = "/",
        .items_arena = undefined,
    };
    app.w = 360;
    for ([_]i32{ 240, 600 }) |height| {
        app.h = height;
        for ([_]MenuKind{ .file, .background }) |kind| {
            app.openMenu(kind, 359, @floatFromInt(height - 1));
            try std.testing.expect(app.menu_x >= 0 and app.menu_x + app.menuWidth() <= 360);
            try std.testing.expect(app.menu_y >= 0 and app.menu_y + app.menuHeight() <= @as(f64, @floatFromInt(height)));
            try std.testing.expectEqual(@as(?usize, null), app.menuHit(app.menu_x - 1, app.menu_y + 10));
            for (0..app.menuLabels().len) |i| {
                const row = app.menuRowRect(i);
                try std.testing.expectEqual(@as(?usize, i), app.menuHit(row.x + 20, row.y + row.h / 2));
                if (app.menuSeparatorBefore(i)) {
                    try std.testing.expectEqual(@as(?usize, null), app.menuHit(row.x + 20, row.y - 5));
                }
            }
        }
    }
    app.dialog = null;
    app.handleKey(c.XKB_KEY_Down, "");
    try std.testing.expectEqual(@as(usize, 1), app.menu_selected);
    app.handleKey(c.XKB_KEY_Escape, "");
    try std.testing.expectEqual(@as(?MenuKind, null), app.menu);
}

pub fn testApp() !App {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ = undefined,
        .theme_cfg = .{ .theme_name = "", .base_dirs = &.{} },
        .worker = undefined,
        .history = try history_mod.History.init(std.testing.allocator, "/tmp"),
        .home_dir = "/tmp",
        .items_arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .folder_sizes = std.StringHashMap(SizeState).init(std.testing.allocator),
    };
}

pub fn testItems(app: *App, count: usize) !void {
    for (0..count) |i| {
        const name = try std.fmt.allocPrint(app.items_arena.allocator(), "file-{d}.txt", .{i});
        try app.items.append(app.allocator, .{ .name = name, .path = name, .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = @intCast(i), .mtime = @intCast(i), .icon_name = "" });
    }
}

test "Delete shortcuts set permanent deletion mode only for Shift+Delete" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 1);

    app.focused_index = 0;
    app.handleKey(c.XKB_KEY_Delete, "");
    try std.testing.expect(app.dialog != null);
    try std.testing.expect(!app.dialog.?.deletion.permanent);

    app.closeDialog();
    app.shift = true;
    app.handleKey(c.XKB_KEY_Delete, "");
    try std.testing.expect(app.dialog != null);
    try std.testing.expect(app.dialog.?.deletion.permanent);
}

test "terminal drawer shares viewport geometry and preserves its preferred height" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 60);
    app.terminal.visible = true;
    app.terminal.requested_height = 220;
    app.terminal.pixels = 220;
    const bottom = app.contentBottom();
    try std.testing.expectEqual(app.h - app.footerHeight() - 220, bottom);
    try std.testing.expectEqual(@as(?usize, null), app.itemAt(260, @floatFromInt(bottom + 1)));
    try std.testing.expect(app.overTerminalDivider(300, @floatFromInt(bottom)));
    try std.testing.expectEqualStrings("row-resize", std.mem.span(app.pointerCursor(300, @floatFromInt(bottom))));
    app.list_view = true;
    app.column_widths = .{ 1000, 120, 120, 160, 180 };
    try std.testing.expectEqual(bottom - app.scrollbarGutter(), app.contentBottom());
    try std.testing.expectEqual(@as(f32, @floatFromInt(app.contentBottom())), app.horizontalScrollbar().?.track.y);
    app.resize(360, 240);
    try std.testing.expectEqual(@as(i32, 220), app.terminal.requested_height);
    try std.testing.expect(app.terminalHeight() <= app.terminalMaximum());
    try std.testing.expectEqual(@as(i32, 0), app.terminalHeight());
    try std.testing.expectEqual(app.h - app.footerHeight() - app.scrollbarGutter(), app.contentBottom());
    app.resize(960, 540);
    try std.testing.expectEqual(@as(i32, 220), app.terminalHeight());
}

test "terminal dropped paths quote shell metacharacters and reject lossy paste bytes" {
    const quotePaths = @import("app_terminal.zig").quotePaths;
    const allocator = std.testing.allocator;
    const quoted = try quotePaths(allocator, &.{ "/tmp/a space's 雪", "/tmp/\"$()`;\\" });
    defer allocator.free(quoted);
    try std.testing.expectEqualStrings("'/tmp/a space'\\''s 雪' '/tmp/\"$()`;\\' ", quoted);
    for ([_][]const u8{ "/tmp/new\nline", "/tmp/carriage\rreturn", "/tmp/tab\t", "/tmp/escape\x1b", "/tmp/delete\x7f" }) |path| {
        try std.testing.expectError(error.ControlCharacter, quotePaths(allocator, &.{ "/tmp/valid", path }));
    }
    try std.testing.expectError(error.InvalidPath, quotePaths(allocator, &.{"relative"}));
    const huge = try allocator.alloc(u8, @import("transfer.zig").limit);
    defer allocator.free(huge);
    @memset(huge, '\'');
    huge[0] = '/';
    try std.testing.expectError(error.TooLong, quotePaths(allocator, &.{huge}));
}

test "terminal keys, modal priority and chooser isolation" {
    const tc = @import("terminal/model.zig").c;
    var app = try testApp();
    defer app.deinit();
    app.terminal.session = tc.ft_new(4, 20) orelse return error.OutOfMemory;
    app.terminal.visible = true;
    app.focus = .terminal;
    app.ctrl = true;
    app.handleKey(c.XKB_KEY_c, "\x03");
    var bytes: [128]u8 = undefined;
    try std.testing.expectEqualStrings("\x03", bytes[0..tc.ft_take_output(app.terminal.session.?, &bytes, bytes.len)]);
    app.handleKey(c.XKB_KEY_l, "\x0c");
    try std.testing.expect(app.focus == .terminal);
    const sample = "copy";
    tc.ft_feed(app.terminal.session.?, sample, sample.len);
    app.terminal.selection = .{ .anchor = .{ .line = 0, .col = 0 }, .end = .{ .line = 0, .col = 4 } };
    app.handleKey(c.XKB_KEY_Control_L, "");
    app.shift = true;
    app.handleKey(c.XKB_KEY_Shift_L, "");
    app.handleKey(c.XKB_KEY_C, "\x03");
    try std.testing.expectEqualStrings("copy", app.clipboard_text.items);
    app.ctrl = false;
    app.shift = false;
    try std.testing.expect(!app.keyRepeats(c.XKB_KEY_F4, ""));
    app.dialog = .{ .kind = .terminal_close, .title = "Close terminal?" };
    app.handleKey(c.XKB_KEY_F4, "");
    try std.testing.expect(app.terminal.visible);
    app.handleKey(c.XKB_KEY_Escape, "");
    try std.testing.expect(app.focus == .terminal);
    app.handleKey(c.XKB_KEY_F4, "");
    try std.testing.expect(!app.terminal.visible);
    try std.testing.expect(app.focus == .file_view);
    app.chooser = .{ .mode = .open };
    app.handleKey(c.XKB_KEY_F4, "");
    try std.testing.expect(!app.terminal.visible);
    try std.testing.expectEqual(@as(?usize, null), app.terminalHit(940, 525));
}

test "address search and dialog share selection editing without file shortcuts" {
    var app = try testApp();
    defer app.deinit();
    try app.location.set(app.allocator, "/tmp/été");
    app.focus = .location_bar;
    app.ctrl = true;
    app.handleKey(c.XKB_KEY_a, "a");
    app.handleKey(c.XKB_KEY_c, "c");
    try std.testing.expectEqualStrings("/tmp/été", app.clipboard_text.items);
    try std.testing.expect(app.clipboard_is_text);
    app.handleKey(c.XKB_KEY_x, "x");
    try std.testing.expectEqualStrings("", app.location.text.items);
    app.pasteText("/tmp/雪");
    app.ctrl = false;
    app.shift = true;
    app.handleKey(c.XKB_KEY_Left, "");
    app.ctrl = true;
    app.handleKey(c.XKB_KEY_x, "x");
    try std.testing.expectEqualStrings("雪", app.clipboard_text.items);
    try std.testing.expectEqualStrings("/tmp/", app.location.text.items);
    app.handleKey(c.XKB_KEY_v, "v");
    try std.testing.expect(app.text_paste_requested and !app.paste_requested);
    app.ctrl = false;
    app.shift = false;
    app.handleKey(c.XKB_KEY_Escape, "");
    try std.testing.expectEqualStrings("/tmp", app.location.text.items);
    app.ctrl = true;
    app.handleKey(c.XKB_KEY_f, "f");
    app.pasteText("query");
    app.handleKey(c.XKB_KEY_a, "a");
    app.handleKey(c.XKB_KEY_c, "c");
    try std.testing.expectEqualStrings("query", app.clipboard_text.items);
    app.openNewFileDialog();
    app.handleKey(c.XKB_KEY_a, "a");
    app.pasteText("filename.txt");
    app.handleKey(c.XKB_KEY_c, "c"); // no selection: leave clipboard alone
    try std.testing.expectEqualStrings("query", app.clipboard_text.items);
    try std.testing.expectEqualStrings("filename.txt", app.dialog.?.edit.text.items);
}

test "pointer caret selection and long-path scrolling at both raster scales" {
    var app = try testApp();
    defer app.deinit();
    app.w = 360;
    app.h = 240;
    try app.location.set(app.allocator, "/tmp/abcdefghijklmnopqrstuvwxyz/abcdefghijklmnopqrstuvwxyz/abcdefghijklmnopqrstuvwxyz/雪");
    app.focus = .location_bar;
    for ([_]i32{ 1, 2 }) |scale| {
        app.scale = scale;
        const surf = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 720, 480).?;
        defer c.cairo_surface_destroy(surf);
        const cr = c.cairo_create(surf).?;
        defer c.cairo_destroy(cr);
        c.cairo_scale(cr, @floatFromInt(scale), @floatFromInt(scale));
        app.renderEditor(cr, &app.location, header.field(app.w), true, false);
        try std.testing.expect(app.location.scroll > 0);
        app.location.scroll = 0;
        app.placeCaret(App.textArea(header.field(app.w), false).x, false);
        try std.testing.expectEqual(@as(usize, 0), app.location.cursor);
        const pen = measureText(cr, "/tmp/", App.fieldFontSize(), false);
        app.placeCaret(App.textArea(header.field(app.w), false).x + pen, true);
        const sel = app.location.selection();
        try std.testing.expectEqualStrings("/tmp/", app.location.text.items[sel[0]..sel[1]]);
        app.location.move(app.location.text.items.len, false);
    }
}

test "keyboard ranges and focus-only movement in grid and list" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 60);
    for ([_]bool{ false, true }) |list| {
        app.list_view = list;
        app.ctrl = false;
        app.shift = false;
        app.handleKey(c.XKB_KEY_Home, "");
        app.shift = true;
        app.handleKey(c.XKB_KEY_Right, "");
        app.handleKey(c.XKB_KEY_Right, "");
        try std.testing.expect(app.items.items[0].selected and app.items.items[1].selected and app.items.items[2].selected);
        app.handleKey(c.XKB_KEY_Left, "");
        try std.testing.expect(!app.items.items[2].selected);
        app.shift = false;
        app.ctrl = true;
        app.handleKey(c.XKB_KEY_End, "");
        try std.testing.expectEqual(@as(?usize, 59), app.focused_index);
        try std.testing.expect(app.items.items[0].selected and !app.items.items[59].selected);
        app.ctrl = false;
        app.shift = true;
        app.handleKey(c.XKB_KEY_Page_Up, "");
        try std.testing.expectEqual(@as(?usize, 0), app.selection_anchor);
        try std.testing.expect(app.items.items[0].selected);
    }
}

test "type select extends prefixes and matches displayed labels case insensitively" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 4);
    app.focus = .file_view;
    app.items.items[0].name = "Daisy";
    app.items.items[1].name = "different";
    app.items.items[1].label = "Documents";
    app.items.items[2].name = "Other";
    app.items.items[3].name = "unrelated";

    try std.testing.expect(app.typeSelectAt("d", 100));
    try std.testing.expectEqual(@as(?usize, 0), app.focused_index);
    try std.testing.expect(app.typeSelectAt("O", 200));
    try std.testing.expectEqual(@as(?usize, 1), app.focused_index);
}

test "type select cycles repeated letters and resets after timeout" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 4);
    app.focus = .file_view;
    app.items.items[0].name = "cat";
    app.items.items[1].name = "car";
    app.items.items[2].name = "Cow";
    app.items.items[3].name = "Other";

    try std.testing.expect(app.typeSelectAt("c", 100));
    try std.testing.expectEqual(@as(?usize, 0), app.focused_index);
    try std.testing.expect(app.typeSelectAt("C", 200));
    try std.testing.expectEqual(@as(?usize, 1), app.focused_index);
    try std.testing.expect(app.typeSelectAt("c", 300));
    try std.testing.expectEqual(@as(?usize, 2), app.focused_index);
    try std.testing.expect(app.typeSelectAt("c", 400));
    try std.testing.expectEqual(@as(?usize, 0), app.focused_index);

    try std.testing.expect(app.typeSelectAt("o", 1500));
    try std.testing.expectEqual(@as(?usize, 3), app.focused_index);
}

test "type select matches Croatian letters case insensitively" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 3);
    app.focus = .file_view;
    app.items.items[0].name = "žirafa";
    app.items.items[1].name = "čarobnjak";
    app.items.items[2].name = "ostalo";

    try std.testing.expect(app.typeSelectAt("Č", 100));
    try std.testing.expectEqual(@as(?usize, 1), app.focused_index);
}

test "history restores names and scroll while tolerating removed items" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 80);
    app.loading = false;
    app.scroll_y = 200;
    app.items.items[12].selected = true;
    app.items.items[13].selected = true;
    app.focused_index = 13;
    app.selection_anchor = 12;
    app.rememberView();
    try app.history.navigate("/elsewhere");
    _ = try app.history.back();
    _ = app.items.orderedRemove(13);
    for (app.items.items) |*item| item.selected = false;
    app.focused_index = null;
    app.selection_anchor = null;
    app.scroll_y = 0;
    app.restoreView();
    try std.testing.expectEqual(@as(i32, 200), app.scroll_y);
    try std.testing.expect(app.items.items[12].selected);
    try std.testing.expectEqual(@as(?usize, null), app.focused_index);
    try std.testing.expectEqual(@as(?usize, 12), app.selection_anchor);
}

test {
    _ = @import("app_hover_tests.zig");
}

/// A point inside item `idx`'s card, wherever the layout put it.
pub fn pointOnItem(app: *App, idx: usize) [2]f64 {
    const per_row: usize = @intCast(app.columns());
    const box = app.itemHighlight(.{ .col = @floatFromInt(idx % per_row), .row = @floatFromInt(idx / per_row), .alpha = 1 });
    return .{ box.x + 10, box.y + 10 };
}

test {
    _ = @import("app_pointer_tests.zig");
}

test {
    _ = @import("app_sidebar_tests.zig");
}

test {
    _ = @import("app_views_tests.zig");
}
