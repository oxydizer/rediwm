//! Tests for the Files App: layout, hit testing, hover, scrolling and sidebar.

const std = @import("std");
const App = @import("app.zig").App;
const scrollbar = @import("ui").widgets.scrollbar;
const anim = @import("ui").anim;
const c = @import("c.zig").api;
const io_manager = @import("io_manager.zig");
const io_runtime = @import("io_runtime.zig");
const app_model = @import("app_model.zig");
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
        .transfer_tree_state = @import("app_transfer_tree.zig").State.init(std.testing.allocator),
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
        .transfer_tree_state = @import("app_transfer_tree.zig").State.init(allocator),
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

    // A virtual transfer directory must not leak entries from the retained
    // filesystem snapshot into its manifest-backed listing.
    const browse_root = try allocator.dupe(u8, "/destination/root/sub");
    defer allocator.free(browse_root);
    app.transfer_browse_root = browse_root;
    app.rebuildView();
    try std.testing.expectEqual(@as(usize, 0), app.items.items.len);
}

test "Unicode folder filtering and sorting retain folder size and date rules" {
    const listing = @import("app_listing.zig");
    var app: App = .{ .allocator = std.testing.allocator, .io = undefined, .environ = undefined, .theme_cfg = undefined, .worker = undefined, .history = .{ .allocator = std.testing.allocator, .current = "/" }, .home_dir = "/", .items_arena = undefined, .transfer_tree_state = @import("app_transfer_tree.zig").State.init(std.testing.allocator) };
    defer app.search.text.deinit(app.allocator);
    const source: worker_mod.Item = .{ .name = "CÁMARA — Терминал", .path = "/name", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 10, .mtime = 20, .icon_name = "" };
    for ([_][]const u8{ "camara", "Cámara", "терм", "ТЕРМ" }) |query| {
        app.search.text.clearRetainingCapacity();
        try app.search.text.appendSlice(app.allocator, query);
        try std.testing.expect(app.matches(source));
    }
    var a: ViewItem = .{ .name = "z", .path = "/z", .sort_key = "a", .is_dir = true, .is_symlink = false, .is_broken = false, .bytes = 10, .mtime = 40, .icon_name = "" };
    var b: ViewItem = .{ .name = "a", .path = "/a", .sort_key = "z", .is_dir = false, .is_symlink = false, .is_broken = false, .bytes = 100, .mtime = 30, .icon_name = "" };
    try std.testing.expect(listing.lessThan(.name, a, b));
    try std.testing.expect(listing.lessThan(.size, a, b));
    try std.testing.expect(listing.lessThan(.modified, a, b));
    try std.testing.expect(!listing.lessThan(.modified, b, a));
    try std.testing.expect(listing.lessThan(.modified_asc, a, b));
    try std.testing.expect(!listing.lessThan(.modified_asc, b, a));
    a.is_dir = false;
    try std.testing.expect(listing.lessThan(.modified, a, b));
    try std.testing.expect(listing.lessThan(.modified_asc, b, a));
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
        .transfer_tree_state = @import("app_transfer_tree.zig").State.init(std.testing.allocator),
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
        .transfer_tree_state = @import("app_transfer_tree.zig").State.init(std.testing.allocator),
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

test "transfer ghosts have no file actions or folder-size affordance" {
    var app = try testApp();
    defer app.deinit();

    const mem = app.items_arena.allocator();
    try app.items.append(app.allocator, .{
        .name = try mem.dupe(u8, "pending-folder"),
        .path = try mem.dupe(u8, "/tmp/pending-folder"),
        .is_dir = true,
        .is_symlink = false,
        .is_broken = false,
        .bytes = 0,
        .mtime = 0,
        .icon_name = "folder",
        .selected = true,
        .transfer_ghost = true,
        .transfer_state = .pending,
        .missing = true,
    });
    app.focused_index = 0;

    try std.testing.expectEqual(@as(usize, 0), app.fileActions().len);
    app.openMenu(.file, 20, 20);
    try std.testing.expect(app.menu == null);
    try std.testing.expect(app.sizeButtonRect(0) == null);

    app.toggleFolderSize(0);
    try std.testing.expectEqual(@as(usize, 0), app.folder_sizes.count());
    try std.testing.expect(app.dirsize_pool == null);

    // A completed manifest entry is no longer a ghost and remains actionable.
    try app.items.append(app.allocator, .{
        .name = try mem.dupe(u8, "completed.txt"),
        .path = try mem.dupe(u8, "/tmp/completed.txt"),
        .is_dir = false,
        .is_symlink = false,
        .is_broken = false,
        .bytes = 12,
        .mtime = 0,
        .icon_name = "text-x-generic",
        .selected = true,
        .transfer_state = .completed,
    });
    try std.testing.expect(app.fileActions().len > 0);
    app.openMenu(.file, 20, 20);
    try std.testing.expectEqual(@as(?MenuKind, .file), app.menu);
}

test "archive member context menu offers export for files and directory subtrees" {
    var app = try testApp();
    defer app.deinit();
    try app.history.navigateLocation("/tmp/package.zip/nested", "/tmp/package.zip".len);

    const mem = app.items_arena.allocator();
    try app.items.append(app.allocator, .{
        .name = try mem.dupe(u8, "payload.txt"),
        .path = try mem.dupe(u8, "/tmp/package.zip/nested/payload.txt"),
        .is_dir = false,
        .is_symlink = false,
        .is_broken = false,
        .bytes = 7,
        .mtime = 0,
        .icon_name = "text-x-generic",
        .selected = true,
    });

    try std.testing.expect(app.hasSelectedArchiveMembers());
    try std.testing.expectEqualSlices(FileAction, &.{ .open, .open_with, .copy, .extract_to }, app.fileActions());

    app.items.items[0].is_symlink = true;
    try std.testing.expect(!app.hasSelectedArchiveMembers());
    try std.testing.expectEqualSlices(FileAction, &.{.open}, app.fileActions());

    app.items.items[0].is_symlink = false;
    app.items.items[0].is_dir = true;
    try std.testing.expect(app.hasSelectedArchiveMembers());
    try std.testing.expectEqualSlices(
        FileAction,
        &.{ .open, .copy, .extract_to },
        app.fileActions(),
    );

    const mem2 = app.items_arena.allocator();
    try app.items.append(app.allocator, .{
        .name = try mem2.dupe(u8, "other.txt"),
        .path = try mem2.dupe(u8, "/tmp/package.zip/other.txt"),
        .is_dir = false,
        .is_symlink = false,
        .is_broken = false,
        .bytes = 5,
        .mtime = 0,
        .icon_name = "text-x-generic",
        .selected = true,
    });
    try std.testing.expect(app.hasSelectedArchiveMembers());
    try std.testing.expectEqualSlices(
        FileAction,
        &.{ .open, .copy, .extract_to },
        app.fileActions(),
    );
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

test "type select works in open chooser and updates filename" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 3);

    app.items.items[0].name = "alpha.txt";
    app.items.items[1].name = "Documents";
    app.items.items[1].is_dir = true;
    app.items.items[2].name = "zeta.txt";
    app.chooser = .{ .mode = .open };
    app.focus = .file_view;

    try std.testing.expect(app.typeSelectAt("z", 100));
    try std.testing.expectEqual(@as(?usize, 2), app.focused_index);
    try std.testing.expect(app.items.items[2].selected);
    try std.testing.expectEqualStrings("zeta.txt", app.filename.text.items);
}

test "type select stays disabled while save chooser filename is focused" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 2);

    app.chooser = .{ .mode = .save };
    app.focus = .filename;

    try std.testing.expect(!app.typeSelectAt("f", 100));
    try std.testing.expectEqual(@as(?usize, null), app.focused_index);
}

test "type select works in save chooser when file list is focused" {
    var app = try testApp();
    defer app.deinit();
    try testItems(&app, 2);

    app.items.items[0].name = "alpha.txt";
    app.items.items[1].name = "Documents";
    app.items.items[1].is_dir = true;
    app.chooser = .{ .mode = .save };
    app.focus = .file_view;

    try std.testing.expect(app.typeSelectAt("d", 100));
    try std.testing.expectEqual(@as(?usize, 1), app.focused_index);
    try std.testing.expect(app.items.items[1].selected);
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

test {
    _ = @import("app_trash_tests.zig");
}

fn makeTransferTestTempDir(buffer: []u8) ![]const u8 {
    const template = "/tmp/rediwm_app_transfer_XXXXXX\x00";
    @memcpy(buffer[0..template.len], template);
    const result = c.mkdtemp(@ptrCast(buffer.ptr)) orelse return error.MkdtempFailed;
    return std.mem.span(@as([*:0]const u8, @ptrCast(result)));
}

fn transferTestJoin(
    allocator: std.mem.Allocator,
    parent: []const u8,
    name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
}

fn transferTestMkdir(path: []const u8) !void {
    const allocator = std.testing.allocator;
    const zpath = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(zpath);
    if (c.mkdir(zpath, 0o755) != 0) return error.MkdirFailed;
}

fn transferTestWriteFile(path: []const u8, contents: []const u8) !void {
    const allocator = std.testing.allocator;
    const zpath = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(zpath);
    const fd = c.open(
        zpath,
        c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC,
        @as(c_uint, 0o600),
    );
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    if (c.write(fd, contents.ptr, contents.len) != contents.len)
        return error.WriteFailed;
}

fn transferTestReadFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const zpath = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(zpath);
    const fd = c.open(zpath, c.O_RDONLY | c.O_CLOEXEC, @as(c_uint, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var buffer: [4096]u8 = undefined;
    const count = c.read(fd, &buffer, buffer.len);
    if (count < 0) return error.ReadFailed;
    return allocator.dupe(u8, buffer[0..@intCast(count)]);
}

fn writeArchivePublicationFixture(path: []const u8) !void {
    const api = @import("c_archive");
    const writer = api.archive_write_new() orelse return error.OutOfMemory;
    defer _ = api.archive_write_free(writer);

    try std.testing.expectEqual(
        @as(c_int, 0),
        api.archive_write_set_format_zip(writer),
    );
    const zpath = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(zpath);
    try std.testing.expectEqual(
        @as(c_int, 0),
        api.archive_write_open_filename(writer, zpath),
    );

    const entry = api.archive_entry_new() orelse return error.OutOfMemory;
    defer api.archive_entry_free(entry);
    api.archive_entry_set_pathname(entry, "nested/payload.txt");
    api.archive_entry_set_filetype(entry, c.S_IFREG);
    api.archive_entry_set_perm(entry, 0o644);
    api.archive_entry_set_size(entry, 7);
    try std.testing.expectEqual(
        @as(c_int, 0),
        api.archive_write_header(writer, entry),
    );
    try std.testing.expectEqual(
        @as(isize, 7),
        api.archive_write_data(writer, "payload", 7),
    );
    try std.testing.expectEqual(@as(c_int, 0), api.archive_write_close(writer));
}

fn waitForAppManagerJob(app: *App, job_id: io_manager.JobId) !void {
    const manager = app.io_manager.?;
    while (true) {
        app.stepDiscovery();
        app.stepOperations();
        if (manager.jobState(job_id).?.isTerminal()) return;

        var descriptors = [_]c.struct_pollfd{
            .{
                .fd = app.discoveryWakeFd(),
                .events = c.POLLIN,
                .revents = 0,
            },
            .{
                .fd = app.operationWakeFd(),
                .events = c.POLLIN,
                .revents = 0,
            },
        };
        const result = c.poll(&descriptors, @intCast(descriptors.len), 5_000);
        if (result == 0) return error.TimedOutWaitingForArchiveMember;
        if (result < 0 and std.c._errno().* != c.EINTR)
            return error.ArchiveMemberPollFailed;
    }
}

test "archive member extraction opens the selected file and retains its staging lease" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTransferTestTempDir(&temp_buffer);
    const source = try transferTestJoin(allocator, temp, "sample.zip");
    defer allocator.free(source);
    const member = try allocator.dupe(u8, "nested/payload.txt");
    defer allocator.free(member);
    const virtual_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ source, member },
    );
    defer allocator.free(virtual_path);
    defer {
        transferTestCleanup(source, false);
        transferTestCleanup(temp, true);
    }
    try writeArchivePublicationFixture(source);

    var runtime = io_runtime.Runtime.init(allocator);
    defer runtime.deinit();
    var app = try testApp();
    defer app.deinit();
    app.io_runtime = &runtime;
    app.io_manager = &runtime.manager;
    try app.history.navigateLocation(source, source.len);

    app.openArchiveMember(virtual_path, true);
    const job_id = app.active_io_copy_job orelse
        return error.ArchiveMemberExtractionDidNotStart;
    try std.testing.expect(app.active_io_copy_is_archive_member);
    try waitForAppManagerJob(&app, job_id);

    try std.testing.expectEqual(
        io_manager.JobState.completed,
        app.io_manager.?.jobState(job_id).?,
    );
    try std.testing.expect(app.active_io_copy_job == null);
    try std.testing.expectEqual(@as(usize, 0), app.archive_member_extractions.items.len);
    try std.testing.expectEqualStrings("Archive member opened", app.status_notice.?);
    const editor_path = app.editor_path orelse
        return error.ArchiveMemberWasNotOpenedInEditor;
    const contents = try transferTestReadFile(allocator, editor_path);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("payload", contents);
}

test "copying selected archive directories publishes real staged paths and retains their lease" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTransferTestTempDir(&temp_buffer);
    const source = try transferTestJoin(allocator, temp, "sample.zip");
    defer allocator.free(source);
    const destination = try transferTestJoin(allocator, temp, "destination");
    defer allocator.free(destination);
    const destination_nested = try transferTestJoin(
        allocator,
        destination,
        "nested",
    );
    defer allocator.free(destination_nested);
    const destination_file = try transferTestJoin(
        allocator,
        destination_nested,
        "payload.txt",
    );
    defer allocator.free(destination_file);
    const virtual_path = try std.fmt.allocPrint(
        allocator,
        "{s}/nested",
        .{source},
    );
    defer allocator.free(virtual_path);
    defer {
        transferTestCleanup(destination_file, false);
        transferTestCleanup(destination_nested, true);
        transferTestCleanup(destination, true);
        transferTestCleanup(source, false);
        transferTestCleanup(temp, true);
    }
    try writeArchivePublicationFixture(source);
    try transferTestMkdir(destination);

    const item_name = try allocator.dupe(u8, "nested");
    defer allocator.free(item_name);
    const item_path = try allocator.dupe(u8, virtual_path);
    defer allocator.free(item_path);

    var runtime = io_runtime.Runtime.init(allocator);
    defer runtime.deinit();
    const worker = try worker_mod.Worker.init(
        allocator,
        std.testing.io,
        std.process.Environ.empty,
        destination,
    );
    defer worker.deinit();
    var app = try testApp();
    defer app.deinit();
    app.worker = worker;
    app.io_runtime = &runtime;
    app.io_manager = &runtime.manager;
    try app.history.navigateLocation(source, source.len);
    try app.items.append(allocator, .{
        .name = item_name,
        .path = item_path,
        .is_dir = true,
        .is_symlink = false,
        .is_broken = false,
        .bytes = 0,
        .mtime = 0,
        .icon_name = "folder",
        .selected = true,
    });

    app.copySelected();
    const job_id = app.active_io_copy_job orelse
        return error.ArchiveClipboardExtractionDidNotStart;
    try std.testing.expect(app.active_io_copy_is_archive_clipboard);
    try waitForAppManagerJob(&app, job_id);

    try std.testing.expectEqual(
        io_manager.JobState.completed,
        app.io_manager.?.jobState(job_id).?,
    );
    try std.testing.expect(app.active_io_copy_job == null);
    try std.testing.expectEqual(@as(usize, 1), app.clipboard_paths.items.len);
    try std.testing.expect(app.clipboard_staging_lease != null);
    try std.testing.expect(!std.mem.eql(u8, virtual_path, app.clipboard_paths.items[0]));

    const staged_file = try transferTestJoin(
        allocator,
        app.clipboard_paths.items[0],
        "payload.txt",
    );
    defer allocator.free(staged_file);
    const contents = try transferTestReadFile(allocator, staged_file);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("payload", contents);

    try app.history.navigateLocation(destination, 0);
    app.executePasteLocal();
    const paste_job_id = app.active_io_copy_job orelse
        return error.ArchiveClipboardPasteDidNotStart;
    try waitForAppManagerJob(&app, paste_job_id);

    try std.testing.expectEqual(
        io_manager.JobState.completed,
        app.io_manager.?.jobState(paste_job_id).?,
    );
    try std.testing.expect(app.active_io_copy_job == null);
    try std.testing.expectEqual(@as(usize, 1), app.clipboard_paths.items.len);
    try std.testing.expect(app.clipboard_staging_lease != null);

    const pasted_contents = try transferTestReadFile(allocator, destination_file);
    defer allocator.free(pasted_contents);
    try std.testing.expectEqualStrings("payload", pasted_contents);

    const staged_contents = try transferTestReadFile(allocator, staged_file);
    defer allocator.free(staged_contents);
    try std.testing.expectEqualStrings("payload", staged_contents);

    const staging_path = try allocator.dupe(u8, app.clipboard_staging_lease.?.path);
    defer allocator.free(staging_path);
    app.clearClipboard();
    const staging_z = try allocator.dupeSentinel(u8, staging_path, 0);
    defer allocator.free(staging_z);
    var staging_stat: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(staging_z, &staging_stat) != 0);
}

test "dragging selected archive members publishes real staged paths and transfers its lease" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTransferTestTempDir(&temp_buffer);
    const source = try transferTestJoin(allocator, temp, "sample.zip");
    defer allocator.free(source);
    const virtual_path = try std.fmt.allocPrint(
        allocator,
        "{s}/nested/payload.txt",
        .{source},
    );
    defer allocator.free(virtual_path);
    defer {
        transferTestCleanup(source, false);
        transferTestCleanup(temp, true);
    }
    try writeArchivePublicationFixture(source);

    const item_name = try allocator.dupe(u8, "payload.txt");
    defer allocator.free(item_name);
    const item_path = try allocator.dupe(u8, virtual_path);
    defer allocator.free(item_path);

    var runtime = io_runtime.Runtime.init(allocator);
    defer runtime.deinit();
    var app = try testApp();
    defer app.deinit();
    app.io_runtime = &runtime;
    app.io_manager = &runtime.manager;
    try app.history.navigateLocation(source, source.len);
    try app.items.append(allocator, .{
        .name = item_name,
        .path = item_path,
        .is_dir = false,
        .is_symlink = false,
        .is_broken = false,
        .bytes = 7,
        .mtime = 0,
        .icon_name = "text-x-generic",
        .selected = true,
    });

    try app.startArchiveDragExport();
    const job_id = app.active_io_copy_job orelse
        return error.ArchiveDragExtractionDidNotStart;
    try std.testing.expect(app.active_io_copy_is_archive_drag);
    try waitForAppManagerJob(&app, job_id);

    try std.testing.expectEqual(
        io_manager.JobState.completed,
        app.io_manager.?.jobState(job_id).?,
    );
    try std.testing.expect(app.active_io_copy_job == null);
    try std.testing.expectEqual(@as(usize, 0), app.archive_exports.items.len);

    const staging_path = blk: {
        var drag_export = app.takeArchiveDragExport() orelse
            return error.ArchiveDragExportWasNotPublished;
        defer drag_export.deinit();

        try std.testing.expectEqual(@as(usize, 1), drag_export.paths.items.len);
        try std.testing.expect(drag_export.staging_lease != null);
        try std.testing.expect(
            !std.mem.eql(u8, virtual_path, drag_export.paths.items[0]),
        );

        const contents = try transferTestReadFile(
            allocator,
            drag_export.paths.items[0],
        );
        defer allocator.free(contents);
        try std.testing.expectEqualStrings("payload", contents);

        break :blk try allocator.dupe(
            u8,
            drag_export.staging_lease.?.path,
        );
    };
    defer allocator.free(staging_path);

    const staging_z = try allocator.dupeSentinel(u8, staging_path, 0);
    defer allocator.free(staging_z);
    var staging_stat: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(staging_z, &staging_stat) != 0);
}

test "Open With uses staged archive paths and retains them after dialog cancellation" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTransferTestTempDir(&temp_buffer);
    const source = try transferTestJoin(allocator, temp, "sample.zip");
    defer allocator.free(source);
    const virtual_path = try std.fmt.allocPrint(
        allocator,
        "{s}/nested/payload.txt",
        .{source},
    );
    defer allocator.free(virtual_path);
    defer {
        transferTestCleanup(source, false);
        transferTestCleanup(temp, true);
    }
    try writeArchivePublicationFixture(source);

    const item_name = try allocator.dupe(u8, "payload.txt");
    defer allocator.free(item_name);
    const item_path = try allocator.dupe(u8, virtual_path);
    defer allocator.free(item_path);

    var runtime = io_runtime.Runtime.init(allocator);
    defer runtime.deinit();
    var app = try testApp();
    var app_live = true;
    defer if (app_live) app.deinit();
    app.io_runtime = &runtime;
    app.io_manager = &runtime.manager;
    try app.history.navigateLocation(source, source.len);
    try app.items.append(allocator, .{
        .name = item_name,
        .path = item_path,
        .is_dir = false,
        .is_symlink = false,
        .is_broken = false,
        .bytes = 7,
        .mtime = 0,
        .icon_name = "text-x-generic",
        .selected = true,
    });

    try std.testing.expect(app.canOpenWith());
    try app.startArchiveOpenWith();
    const job_id = app.active_io_copy_job orelse
        return error.ArchiveOpenWithExtractionDidNotStart;
    try waitForAppManagerJob(&app, job_id);

    try std.testing.expectEqual(
        io_manager.JobState.completed,
        app.io_manager.?.jobState(job_id).?,
    );
    try std.testing.expect(app.dialog != null and app.dialog.?.kind == .open_with);
    try std.testing.expectEqual(@as(usize, 1), app.archive_open_with_leases.items.len);
    const staged_path = try allocator.dupe(
        u8,
        app.dialog.?.applications.?.apps.paths[0],
    );
    defer allocator.free(staged_path);
    try std.testing.expect(!std.mem.eql(u8, virtual_path, staged_path));
    const contents = try transferTestReadFile(allocator, staged_path);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("payload", contents);

    app.openWithAction(.cancel);
    try std.testing.expect(app.dialog == null);
    const staging_z = try allocator.dupeSentinel(
        u8,
        app.archive_open_with_leases.items[0].path,
        0,
    );
    defer allocator.free(staging_z);
    var staging_stat: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.lstat(staging_z, &staging_stat));

    app.deinit();
    app_live = false;
    try std.testing.expect(c.lstat(staging_z, &staging_stat) != 0);
}

test "Escape cancels Manager-backed archive member extraction" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTransferTestTempDir(&temp_buffer);
    const source = try transferTestJoin(allocator, temp, "sample.zip");
    defer allocator.free(source);
    const virtual_path = try std.fmt.allocPrint(
        allocator,
        "{s}/nested/payload.txt",
        .{source},
    );
    defer allocator.free(virtual_path);
    defer {
        transferTestCleanup(source, false);
        transferTestCleanup(temp, true);
    }
    try writeArchivePublicationFixture(source);

    var runtime = io_runtime.Runtime.init(allocator);
    defer runtime.deinit();
    var app = try testApp();
    defer app.deinit();
    app.io_runtime = &runtime;
    app.io_manager = &runtime.manager;
    try app.history.navigateLocation(source, source.len);

    app.openArchiveMember(virtual_path, true);
    const job_id = app.active_io_copy_job orelse
        return error.ArchiveMemberExtractionDidNotStart;
    app.stepOperations();
    app.handleKey(c.XKB_KEY_Escape, "");
    try std.testing.expectEqualStrings("Cancelling operation...", app.status_notice.?);
    try waitForAppManagerJob(&app, job_id);

    try std.testing.expectEqual(
        io_manager.JobState.cancelled,
        app.io_manager.?.jobState(job_id).?,
    );
    try std.testing.expect(app.active_io_copy_job == null);
    try std.testing.expectEqual(@as(usize, 0), app.archive_member_extractions.items.len);
    try std.testing.expect(app.editor_path == null);
}

fn transferTestCleanup(path: []const u8, is_directory: bool) void {
    const allocator = std.heap.page_allocator;
    const zpath = allocator.dupeSentinel(u8, path, 0) catch return;
    defer allocator.free(zpath);
    if (is_directory) {
        _ = c.rmdir(zpath);
    } else {
        _ = c.unlink(zpath);
    }
}

fn transferTestSymlink(target: []const u8, path: []const u8) !void {
    const allocator = std.testing.allocator;
    const target_z = try allocator.dupeSentinel(u8, target, 0);
    defer allocator.free(target_z);
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);
    if (c.symlink(target_z, path_z) != 0) return error.SymlinkFailed;
}

test "multi-file copy requests use one Manager job and the operation Runtime" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTransferTestTempDir(&temp_buffer);

    const source_a = try transferTestJoin(allocator, temp, "first.txt");
    defer allocator.free(source_a);
    const source_b = try transferTestJoin(allocator, temp, "second.txt");
    defer allocator.free(source_b);
    const destination_dir = try transferTestJoin(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    const destination_a = try transferTestJoin(allocator, destination_dir, "first.txt");
    defer allocator.free(destination_a);
    const destination_b = try transferTestJoin(allocator, destination_dir, "second.txt");
    defer allocator.free(destination_b);
    defer {
        transferTestCleanup(destination_b, false);
        transferTestCleanup(destination_a, false);
        transferTestCleanup(source_b, false);
        transferTestCleanup(source_a, false);
        transferTestCleanup(destination_dir, true);
        transferTestCleanup(temp, true);
    }

    try transferTestMkdir(destination_dir);
    try transferTestWriteFile(source_a, "first Manager payload");
    try transferTestWriteFile(source_b, "second Manager payload");

    var runtime = io_runtime.Runtime.init(allocator);
    defer runtime.deinit();
    var app = try testApp();
    defer app.deinit();
    app.io_runtime = &runtime;
    app.io_manager = &runtime.manager;
    app.w = 800;
    app.h = 320;
    app.sidebar_expanded[@intFromEnum(app_model.SidebarSection.transfers)] = true;

    const paths = [_][]const u8{ source_a, source_b };
    try std.testing.expect(app.executeTransfer(.copy, &paths, destination_dir, false));
    const job_id = app.active_io_copy_job.?;
    const previous_sidebar_max = @max(
        0,
        app.sidebarExtent() - (app.h - app.sidebarFooter()),
    );
    try std.testing.expect(previous_sidebar_max > 0);
    app.sidebar_scroll = previous_sidebar_max;
    const manager = app.io_manager.?;
    const tree = manager.treeIndex(job_id).?;
    const roots = tree.roots();
    try std.testing.expectEqual(@as(usize, 2), roots.len);
    try std.testing.expectEqual(io_manager.JobState.queued, manager.jobState(job_id).?);
    try std.testing.expectEqual(io_manager.OperationState.pending, manager.entryOperationView(job_id, roots[0]).?.state);
    try std.testing.expectEqual(io_manager.OperationState.pending, manager.entryOperationView(job_id, roots[1]).?.state);

    while (true) {
        app.stepOperations();
        if (manager.jobState(job_id).?.isTerminal()) break;

        var descriptors = [_]c.struct_pollfd{.{
            .fd = app.operationWakeFd(),
            .events = c.POLLIN,
            .revents = 0,
        }};
        const result = c.poll(&descriptors, 1, 5_000);
        if (result == 0) return error.TimedOutWaitingForCopy;
        if (result < 0 and std.c._errno().* != c.EINTR)
            return error.OperationPollFailed;
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job_id).?);
    const new_sidebar_max = @max(
        0,
        app.sidebarExtent() - (app.h - app.sidebarFooter()),
    );
    try std.testing.expect(new_sidebar_max < previous_sidebar_max);
    try std.testing.expectEqual(new_sidebar_max, app.sidebar_scroll);
    const copied_a = try transferTestReadFile(allocator, destination_a);
    defer allocator.free(copied_a);
    const copied_b = try transferTestReadFile(allocator, destination_b);
    defer allocator.free(copied_b);
    try std.testing.expectEqualStrings("first Manager payload", copied_a);
    try std.testing.expectEqualStrings("second Manager payload", copied_b);
}

test "multi-directory copy requests use one Manager job and incremental discovery" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTransferTestTempDir(&temp_buffer);

    const source_a = try transferTestJoin(allocator, temp, "alpha");
    defer allocator.free(source_a);
    const source_b = try transferTestJoin(allocator, temp, "beta");
    defer allocator.free(source_b);
    const source_a_file = try transferTestJoin(allocator, source_a, "first.txt");
    defer allocator.free(source_a_file);
    const source_b_nested = try transferTestJoin(allocator, source_b, "nested");
    defer allocator.free(source_b_nested);
    const source_b_file = try transferTestJoin(allocator, source_b_nested, "second.txt");
    defer allocator.free(source_b_file);

    const destination_dir = try transferTestJoin(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    const destination_a = try transferTestJoin(allocator, destination_dir, "alpha");
    defer allocator.free(destination_a);
    const destination_a_file = try transferTestJoin(allocator, destination_a, "first.txt");
    defer allocator.free(destination_a_file);
    const destination_b = try transferTestJoin(allocator, destination_dir, "beta");
    defer allocator.free(destination_b);
    const destination_b_nested = try transferTestJoin(allocator, destination_b, "nested");
    defer allocator.free(destination_b_nested);
    const destination_b_file = try transferTestJoin(allocator, destination_b_nested, "second.txt");
    defer allocator.free(destination_b_file);

    defer {
        transferTestCleanup(destination_b_file, false);
        transferTestCleanup(destination_b_nested, true);
        transferTestCleanup(destination_a_file, false);
        transferTestCleanup(destination_b, true);
        transferTestCleanup(destination_a, true);
        transferTestCleanup(source_b_file, false);
        transferTestCleanup(source_b_nested, true);
        transferTestCleanup(source_a_file, false);
        transferTestCleanup(source_b, true);
        transferTestCleanup(source_a, true);
        transferTestCleanup(destination_dir, true);
        transferTestCleanup(temp, true);
    }

    try transferTestMkdir(source_a);
    try transferTestMkdir(source_b);
    try transferTestMkdir(source_b_nested);
    try transferTestMkdir(destination_dir);
    try transferTestWriteFile(source_a_file, "first directory payload");
    try transferTestWriteFile(source_b_file, "nested directory payload");

    var runtime = io_runtime.Runtime.init(allocator);
    defer runtime.deinit();
    var app = try testApp();
    defer app.deinit();
    app.io_runtime = &runtime;
    app.io_manager = &runtime.manager;

    const paths = [_][]const u8{ source_a, source_b };
    try std.testing.expect(app.executeTransfer(.copy, &paths, destination_dir, false));

    const job_id = app.active_io_copy_job.?;
    const manager = app.io_manager.?;
    const tree = manager.treeIndex(job_id).?;
    const roots = tree.roots();
    try std.testing.expectEqual(@as(usize, 2), roots.len);
    try std.testing.expectEqual(io_manager.JobState.queued, manager.jobState(job_id).?);
    try std.testing.expectEqualStrings(
        source_a,
        manager.discoveryRootPath(job_id, roots[0]).?,
    );
    try std.testing.expectEqualStrings(
        source_b,
        manager.discoveryRootPath(job_id, roots[1]).?,
    );

    while (true) {
        app.stepDiscovery();
        app.stepOperations();
        if (manager.jobState(job_id).?.isTerminal()) break;

        var descriptors = [_]c.struct_pollfd{
            .{
                .fd = app.discoveryWakeFd(),
                .events = c.POLLIN,
                .revents = 0,
            },
            .{
                .fd = app.operationWakeFd(),
                .events = c.POLLIN,
                .revents = 0,
            },
        };
        const result = c.poll(&descriptors, @intCast(descriptors.len), 5_000);
        if (result == 0) return error.TimedOutWaitingForDirectoryCopy;
        if (result < 0 and std.c._errno().* != c.EINTR)
            return error.DirectoryCopyPollFailed;
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job_id).?);
    const copied_a = try transferTestReadFile(allocator, destination_a_file);
    defer allocator.free(copied_a);
    const copied_b = try transferTestReadFile(allocator, destination_b_file);
    defer allocator.free(copied_b);
    try std.testing.expectEqualStrings("first directory payload", copied_a);
    try std.testing.expectEqualStrings("nested directory payload", copied_b);
}

test "same-filesystem file and symlink moves use one Manager job" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTransferTestTempDir(&temp_buffer);

    const source_file = try transferTestJoin(allocator, temp, "move.txt");
    defer allocator.free(source_file);
    const source_link = try transferTestJoin(allocator, temp, "move-link");
    defer allocator.free(source_link);
    const destination_dir = try transferTestJoin(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    const destination_file = try transferTestJoin(allocator, destination_dir, "move.txt");
    defer allocator.free(destination_file);
    const destination_link = try transferTestJoin(allocator, destination_dir, "move-link");
    defer allocator.free(destination_link);
    defer {
        transferTestCleanup(destination_link, false);
        transferTestCleanup(destination_file, false);
        transferTestCleanup(source_link, false);
        transferTestCleanup(source_file, false);
        transferTestCleanup(destination_dir, true);
        transferTestCleanup(temp, true);
    }

    try transferTestMkdir(destination_dir);
    try transferTestWriteFile(source_file, "native rename payload");
    try transferTestSymlink("../literal-target", source_link);

    var runtime = io_runtime.Runtime.init(allocator);
    defer runtime.deinit();
    var app = try testApp();
    defer app.deinit();
    app.io_runtime = &runtime;
    app.io_manager = &runtime.manager;
    try app.clipboard_paths.append(allocator, try allocator.dupe(u8, source_file));
    try app.clipboard_paths.append(allocator, try allocator.dupe(u8, source_link));
    app.clipboard_cut = true;
    app.clipboard_revision = 7;

    const paths = [_][]const u8{ source_file, source_link };
    try std.testing.expect(app.executeTransfer(.move, &paths, destination_dir, true));
    const job_id = app.active_io_copy_job.?;
    const manager = app.io_manager.?;
    const tree = manager.treeIndex(job_id).?;
    const roots = tree.roots();
    try std.testing.expectEqual(@as(usize, 2), roots.len);
    try std.testing.expectEqual(io_manager.JobState.queued, manager.jobState(job_id).?);

    while (true) {
        app.stepOperations();
        if (manager.jobState(job_id).?.isTerminal()) break;

        var descriptors = [_]c.struct_pollfd{.{
            .fd = app.operationWakeFd(),
            .events = c.POLLIN,
            .revents = 0,
        }};
        const result = c.poll(&descriptors, 1, 5_000);
        if (result == 0) return error.TimedOutWaitingForMove;
        if (result < 0 and std.c._errno().* != c.EINTR)
            return error.MovePollFailed;
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job_id).?);
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_paths.items.len);
    try std.testing.expect(!app.clipboard_cut);

    var stat_buffer: c.struct_stat = undefined;
    const source_file_z = try allocator.dupeSentinel(u8, source_file, 0);
    defer allocator.free(source_file_z);
    const source_link_z = try allocator.dupeSentinel(u8, source_link, 0);
    defer allocator.free(source_link_z);
    try std.testing.expect(c.lstat(source_file_z, &stat_buffer) != 0);
    try std.testing.expect(c.lstat(source_link_z, &stat_buffer) != 0);

    const moved_contents = try transferTestReadFile(allocator, destination_file);
    defer allocator.free(moved_contents);
    try std.testing.expectEqualStrings("native rename payload", moved_contents);

    const destination_link_z = try allocator.dupeSentinel(u8, destination_link, 0);
    defer allocator.free(destination_link_z);
    var target_buffer: [128]u8 = undefined;
    const target_len = c.readlink(
        destination_link_z,
        &target_buffer,
        target_buffer.len,
    );
    try std.testing.expect(target_len >= 0);
    try std.testing.expectEqualStrings(
        "../literal-target",
        target_buffer[0..@intCast(target_len)],
    );
}

test "cross-filesystem file and symlink moves copy before detaching sources" {
    const allocator = std.testing.allocator;
    var source_temp_buffer: [256]u8 = undefined;
    const source_temp = try makeTransferTestTempDir(&source_temp_buffer);
    defer transferTestCleanup(source_temp, true);

    const destination_template = "/dev/shm/rediwm_app_transfer_XXXXXX\x00";
    var destination_temp_buffer: [256]u8 = undefined;
    @memcpy(destination_temp_buffer[0..destination_template.len], destination_template);
    const destination_temp_ptr = c.mkdtemp(@ptrCast(destination_temp_buffer[0..].ptr)) orelse
        return error.SkipZigTest;
    const destination_temp =
        std.mem.span(@as([*:0]const u8, @ptrCast(destination_temp_ptr)));
    defer transferTestCleanup(destination_temp, true);

    const destination_temp_z = try allocator.dupeSentinel(u8, destination_temp, 0);
    defer allocator.free(destination_temp_z);
    var destination_stat: c.struct_stat = undefined;
    if (c.stat(destination_temp_z, &destination_stat) != 0)
        return error.SkipZigTest;

    const source_file = try transferTestJoin(allocator, source_temp, "payload.bin");
    defer allocator.free(source_file);
    const source_file_z = try allocator.dupeSentinel(u8, source_file, 0);
    defer allocator.free(source_file_z);
    const source_link = try transferTestJoin(allocator, source_temp, "shortcut");
    defer allocator.free(source_link);
    const destination_file = try transferTestJoin(allocator, destination_temp, "payload.bin");
    defer allocator.free(destination_file);
    const destination_link = try transferTestJoin(allocator, destination_temp, "shortcut");
    defer allocator.free(destination_link);
    defer {
        transferTestCleanup(destination_link, false);
        transferTestCleanup(destination_file, false);
        transferTestCleanup(source_link, false);
        transferTestCleanup(source_file, false);
    }

    const source_temp_z = try allocator.dupeSentinel(u8, source_temp, 0);
    defer allocator.free(source_temp_z);
    var source_stat: c.struct_stat = undefined;
    if (c.stat(source_temp_z, &source_stat) != 0 or
        source_stat.st_dev == destination_stat.st_dev)
    {
        return error.SkipZigTest;
    }

    try transferTestWriteFile(source_file, "cross-filesystem payload");
    try transferTestSymlink("../literal-target", source_link);

    var runtime = io_runtime.Runtime.init(allocator);
    defer runtime.deinit();
    var app = try testApp();
    defer app.deinit();
    app.io_runtime = &runtime;
    app.io_manager = &runtime.manager;
    try app.clipboard_paths.append(allocator, try allocator.dupe(u8, source_file));
    try app.clipboard_paths.append(allocator, try allocator.dupe(u8, source_link));
    app.clipboard_cut = true;
    app.clipboard_revision = 19;

    const paths = [_][]const u8{ source_file, source_link };
    try std.testing.expect(app.executeTransfer(.move, &paths, destination_temp, true));
    const job_id = app.active_io_copy_job.?;
    const manager = app.io_manager.?;
    var snapshot = try manager.snapshotJob(allocator, job_id);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 4), snapshot.operations.len);
    try std.testing.expectEqual(io_manager.OperationKind.copy_file, snapshot.operations[0].kind);
    try std.testing.expectEqual(io_manager.OperationKind.detach_source, snapshot.operations[1].kind);
    try std.testing.expectEqual(io_manager.OperationKind.copy_symlink, snapshot.operations[2].kind);
    try std.testing.expectEqual(io_manager.OperationKind.detach_source, snapshot.operations[3].kind);

    while (true) {
        app.stepOperations();
        if (manager.jobState(job_id).?.isTerminal()) break;

        var descriptors = [_]c.struct_pollfd{.{
            .fd = app.operationWakeFd(),
            .events = c.POLLIN,
            .revents = 0,
        }};
        const result = c.poll(&descriptors, 1, 5_000);
        if (result == 0) return error.TimedOutWaitingForCrossFilesystemMove;
        if (result < 0 and std.c._errno().* != c.EINTR)
            return error.CrossFilesystemMovePollFailed;
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job_id).?);
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_paths.items.len);
    try std.testing.expect(!app.clipboard_cut);

    try std.testing.expect(c.lstat(source_file_z, &source_stat) != 0);
    const source_link_z = try allocator.dupeSentinel(u8, source_link, 0);
    defer allocator.free(source_link_z);
    try std.testing.expect(c.lstat(source_link_z, &source_stat) != 0);

    const moved_contents = try transferTestReadFile(allocator, destination_file);
    defer allocator.free(moved_contents);
    try std.testing.expectEqualStrings("cross-filesystem payload", moved_contents);

    const destination_link_z = try allocator.dupeSentinel(u8, destination_link, 0);
    defer allocator.free(destination_link_z);
    var target_buffer: [128]u8 = undefined;
    const target_len = c.readlink(destination_link_z, &target_buffer, target_buffer.len);
    try std.testing.expect(target_len >= 0);
    try std.testing.expectEqualStrings(
        "../literal-target",
        target_buffer[0..@intCast(target_len)],
    );
}

test "directory move refuses a selected mountpoint instead of using JobRunner" {
    const allocator = std.testing.allocator;
    const source = "/dev/shm";
    const destination = "/tmp";

    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);
    const parent_z = try allocator.dupeSentinel(u8, "/dev", 0);
    defer allocator.free(parent_z);
    var source_stat: c.struct_stat = undefined;
    var parent_stat: c.struct_stat = undefined;
    if (c.lstat(source_z, &source_stat) != 0 or
        c.stat(parent_z, &parent_stat) != 0 or
        source_stat.st_dev == parent_stat.st_dev)
    {
        return error.SkipZigTest;
    }

    var runtime = io_runtime.Runtime.init(allocator);
    defer runtime.deinit();
    var app = try testApp();
    defer app.deinit();
    app.io_runtime = &runtime;
    app.io_manager = &runtime.manager;

    const paths = [_][]const u8{source};
    try std.testing.expect(app.executeTransfer(.move, &paths, destination, false));
    try std.testing.expect(app.active_io_copy_job == null);
    try std.testing.expectEqualStrings(
        "Cannot move a mounted directory",
        app.status_notice.?,
    );
}

test "same-filesystem nested directory moves use one Manager job and detach sources" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTransferTestTempDir(&temp_buffer);

    const source = try transferTestJoin(allocator, temp, "alpha");
    defer allocator.free(source);
    const source_nested = try transferTestJoin(allocator, source, "nested");
    defer allocator.free(source_nested);
    const source_file = try transferTestJoin(allocator, source_nested, "payload.txt");
    defer allocator.free(source_file);

    const destination_dir = try transferTestJoin(allocator, temp, "destination");
    defer allocator.free(destination_dir);
    const destination = try transferTestJoin(allocator, destination_dir, "alpha");
    defer allocator.free(destination);
    const destination_nested = try transferTestJoin(allocator, destination, "nested");
    defer allocator.free(destination_nested);
    const destination_file = try transferTestJoin(
        allocator,
        destination_nested,
        "payload.txt",
    );
    defer allocator.free(destination_file);

    defer {
        transferTestCleanup(destination_file, false);
        transferTestCleanup(destination_nested, true);
        transferTestCleanup(destination, true);
        transferTestCleanup(source_file, false);
        transferTestCleanup(source_nested, true);
        transferTestCleanup(source, true);
        transferTestCleanup(destination_dir, true);
        transferTestCleanup(temp, true);
    }

    try transferTestMkdir(source);
    try transferTestMkdir(source_nested);
    try transferTestMkdir(destination_dir);
    try transferTestWriteFile(source_file, "nested directory move payload");

    var runtime = io_runtime.Runtime.init(allocator);
    defer runtime.deinit();
    var app = try testApp();
    defer app.deinit();
    app.io_runtime = &runtime;
    app.io_manager = &runtime.manager;
    try app.clipboard_paths.append(allocator, try allocator.dupe(u8, source));
    app.clipboard_cut = true;
    app.clipboard_revision = 11;

    const paths = [_][]const u8{source};
    try std.testing.expect(app.executeTransfer(.move, &paths, destination_dir, true));
    const job_id = app.active_io_copy_job.?;
    const manager = app.io_manager.?;
    const tree = manager.treeIndex(job_id).?;
    const roots = tree.roots();
    try std.testing.expectEqual(@as(usize, 1), roots.len);
    const root_id = roots[0];
    try std.testing.expectEqual(io_manager.JobState.queued, manager.jobState(job_id).?);
    try std.testing.expectEqual(
        io_manager.OperationState.pending,
        manager.sourceDetachOperationState(job_id, root_id).?,
    );

    while (true) {
        app.stepDiscovery();
        app.stepOperations();
        if (manager.jobState(job_id).?.isTerminal()) break;

        var descriptors = [_]c.struct_pollfd{
            .{
                .fd = app.discoveryWakeFd(),
                .events = c.POLLIN,
                .revents = 0,
            },
            .{
                .fd = app.operationWakeFd(),
                .events = c.POLLIN,
                .revents = 0,
            },
        };
        const result = c.poll(&descriptors, @intCast(descriptors.len), 5_000);
        if (result == 0) return error.TimedOutWaitingForDirectoryMove;
        if (result < 0 and std.c._errno().* != c.EINTR)
            return error.DirectoryMovePollFailed;
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job_id).?);
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.sourceDetachOperationState(job_id, root_id).?,
    );
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_paths.items.len);
    try std.testing.expect(!app.clipboard_cut);
    try std.testing.expectEqualStrings("Folder moved", app.status_notice.?);

    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);
    var source_stat: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(source_z, &source_stat) != 0);

    const moved_contents = try transferTestReadFile(allocator, destination_file);
    defer allocator.free(moved_contents);
    try std.testing.expectEqualStrings("nested directory move payload", moved_contents);
}

test "cross-filesystem nested directory moves use one Manager job and detach sources" {
    const allocator = std.testing.allocator;
    var source_temp_buffer: [256]u8 = undefined;
    const source_temp = try makeTransferTestTempDir(&source_temp_buffer);
    defer transferTestCleanup(source_temp, true);

    const destination_template = "/dev/shm/rediwm_directory_move_XXXXXX\x00";
    var destination_temp_buffer: [256]u8 = undefined;
    @memcpy(destination_temp_buffer[0..destination_template.len], destination_template);
    const destination_temp_ptr = c.mkdtemp(@ptrCast(destination_temp_buffer[0..].ptr)) orelse
        return error.SkipZigTest;
    const destination_temp =
        std.mem.span(@as([*:0]const u8, @ptrCast(destination_temp_ptr)));
    defer transferTestCleanup(destination_temp, true);

    const source_temp_z = try allocator.dupeSentinel(u8, source_temp, 0);
    defer allocator.free(source_temp_z);
    const destination_temp_z = try allocator.dupeSentinel(u8, destination_temp, 0);
    defer allocator.free(destination_temp_z);
    var source_stat: c.struct_stat = undefined;
    var destination_stat: c.struct_stat = undefined;
    if (c.stat(source_temp_z, &source_stat) != 0 or
        c.stat(destination_temp_z, &destination_stat) != 0 or
        source_stat.st_dev == destination_stat.st_dev)
    {
        return error.SkipZigTest;
    }

    const source = try transferTestJoin(allocator, source_temp, "alpha");
    defer allocator.free(source);
    const source_nested = try transferTestJoin(allocator, source, "nested");
    defer allocator.free(source_nested);
    const source_file = try transferTestJoin(allocator, source_nested, "payload.txt");
    defer allocator.free(source_file);
    const source_link = try transferTestJoin(allocator, source_nested, "shortcut");
    defer allocator.free(source_link);

    const destination = try transferTestJoin(allocator, destination_temp, "alpha");
    defer allocator.free(destination);
    const destination_nested = try transferTestJoin(allocator, destination, "nested");
    defer allocator.free(destination_nested);
    const destination_file = try transferTestJoin(
        allocator,
        destination_nested,
        "payload.txt",
    );
    defer allocator.free(destination_file);
    const destination_link = try transferTestJoin(allocator, destination_nested, "shortcut");
    defer allocator.free(destination_link);

    defer {
        transferTestCleanup(destination_link, false);
        transferTestCleanup(destination_file, false);
        transferTestCleanup(destination_nested, true);
        transferTestCleanup(destination, true);
        transferTestCleanup(source_link, false);
        transferTestCleanup(source_file, false);
        transferTestCleanup(source_nested, true);
        transferTestCleanup(source, true);
    }

    try transferTestMkdir(source);
    try transferTestMkdir(source_nested);
    try transferTestWriteFile(source_file, "cross-filesystem directory payload");
    try transferTestSymlink("../literal-target", source_link);

    var runtime = io_runtime.Runtime.init(allocator);
    defer runtime.deinit();
    var app = try testApp();
    defer app.deinit();
    app.io_runtime = &runtime;
    app.io_manager = &runtime.manager;
    try app.clipboard_paths.append(allocator, try allocator.dupe(u8, source));
    app.clipboard_cut = true;
    app.clipboard_revision = 23;

    const paths = [_][]const u8{source};
    try std.testing.expect(app.executeTransfer(.move, &paths, destination_temp, true));
    const job_id = app.active_io_copy_job.?;
    const manager = app.io_manager.?;
    const tree = manager.treeIndex(job_id).?;
    const roots = tree.roots();
    try std.testing.expectEqual(@as(usize, 1), roots.len);
    const root_id = roots[0];
    try std.testing.expectEqual(io_manager.JobState.queued, manager.jobState(job_id).?);
    try std.testing.expectEqual(
        io_manager.OperationState.pending,
        manager.sourceDetachOperationState(job_id, root_id).?,
    );

    while (true) {
        app.stepDiscovery();
        app.stepOperations();
        if (manager.jobState(job_id).?.isTerminal()) break;

        var descriptors = [_]c.struct_pollfd{
            .{
                .fd = app.discoveryWakeFd(),
                .events = c.POLLIN,
                .revents = 0,
            },
            .{
                .fd = app.operationWakeFd(),
                .events = c.POLLIN,
                .revents = 0,
            },
        };
        const result = c.poll(&descriptors, @intCast(descriptors.len), 5_000);
        if (result == 0) return error.TimedOutWaitingForCrossFilesystemDirectoryMove;
        if (result < 0 and std.c._errno().* != c.EINTR)
            return error.CrossFilesystemDirectoryMovePollFailed;
    }

    try std.testing.expectEqual(io_manager.JobState.completed, manager.jobState(job_id).?);
    try std.testing.expectEqual(
        io_manager.OperationState.completed,
        manager.sourceDetachOperationState(job_id, root_id).?,
    );
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_paths.items.len);
    try std.testing.expect(!app.clipboard_cut);
    try std.testing.expectEqualStrings("Folder moved", app.status_notice.?);

    const source_z = try allocator.dupeSentinel(u8, source, 0);
    defer allocator.free(source_z);
    const source_nested_z = try allocator.dupeSentinel(u8, source_nested, 0);
    defer allocator.free(source_nested_z);
    const source_file_z = try allocator.dupeSentinel(u8, source_file, 0);
    defer allocator.free(source_file_z);
    const source_link_z = try allocator.dupeSentinel(u8, source_link, 0);
    defer allocator.free(source_link_z);
    var removed_stat: c.struct_stat = undefined;
    try std.testing.expect(c.lstat(source_z, &removed_stat) != 0);
    try std.testing.expect(c.lstat(source_nested_z, &removed_stat) != 0);
    try std.testing.expect(c.lstat(source_file_z, &removed_stat) != 0);
    try std.testing.expect(c.lstat(source_link_z, &removed_stat) != 0);

    const moved_contents = try transferTestReadFile(allocator, destination_file);
    defer allocator.free(moved_contents);
    try std.testing.expectEqualStrings("cross-filesystem directory payload", moved_contents);

    const destination_link_z = try allocator.dupeSentinel(u8, destination_link, 0);
    defer allocator.free(destination_link_z);
    var target_buffer: [128]u8 = undefined;
    const target_len = c.readlink(destination_link_z, &target_buffer, target_buffer.len);
    try std.testing.expect(target_len >= 0);
    try std.testing.expectEqualStrings(
        "../literal-target",
        target_buffer[0..@intCast(target_len)],
    );
}

test "archive publication scans roots, discovers descendants and drains the barrier" {
    const allocator = std.testing.allocator;
    var temp_buffer: [256]u8 = undefined;
    const temp = try makeTransferTestTempDir(&temp_buffer);

    const source = try transferTestJoin(allocator, temp, "sample.zip");
    defer allocator.free(source);
    const destination = try transferTestJoin(allocator, temp, "destination");
    defer allocator.free(destination);
    const nested = try transferTestJoin(allocator, destination, "nested");
    defer allocator.free(nested);
    const payload = try transferTestJoin(allocator, nested, "payload.txt");
    defer allocator.free(payload);

    defer {
        transferTestCleanup(payload, false);
        transferTestCleanup(nested, true);
        transferTestCleanup(destination, true);
        transferTestCleanup(source, false);
        transferTestCleanup(temp, true);
    }

    try writeArchivePublicationFixture(source);
    try transferTestMkdir(destination);

    var runtime = io_runtime.Runtime.init(allocator);
    defer runtime.deinit();
    var app = try testApp();
    defer app.deinit();
    app.io_runtime = &runtime;
    app.io_manager = &runtime.manager;

    const manager = app.io_manager.?;
    app.startExtraction(source, destination);
    const job = app.active_io_copy_job orelse
        return error.ArchiveExtractionDidNotStart;
    try std.testing.expect(app.active_io_copy_is_archive);
    try std.testing.expect(!app.job_was_running);
    try std.testing.expectEqualStrings("Extracting archive", app.status_notice.?);

    while (true) {
        app.stepDiscovery();
        app.stepOperations();
        if (manager.jobState(job).?.isTerminal()) break;

        var descriptors = [_]c.struct_pollfd{
            .{
                .fd = app.discoveryWakeFd(),
                .events = c.POLLIN,
                .revents = 0,
            },
            .{
                .fd = app.operationWakeFd(),
                .events = c.POLLIN,
                .revents = 0,
            },
        };
        const result = c.poll(&descriptors, @intCast(descriptors.len), 5_000);
        if (result == 0) return error.TimedOutWaitingForArchivePublication;
        if (result < 0 and std.c._errno().* != c.EINTR)
            return error.ArchivePublicationPollFailed;
    }

    try std.testing.expectEqual(
        io_manager.JobState.completed,
        manager.jobState(job).?,
    );
    try std.testing.expect(app.active_io_copy_job == null);
    try std.testing.expectEqualStrings("Archive extracted", app.status_notice.?);
    try std.testing.expectEqual(@as(usize, 0), app.archive_publications.items.len);

    const contents = try transferTestReadFile(allocator, payload);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("payload", contents);
}
