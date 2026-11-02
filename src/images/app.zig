const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const c = @import("../files/c.zig").api;
const decoder = @import("loader.zig");
const view = @import("view.zig");
const cache_mod = @import("cache.zig");
const Rect = view.Rect;
const edit = @import("edit.zig");
const Editor = @import("../files/editor.zig").Editor;
const shell_ui = @import("ui").cairo;
const ui_button = @import("ui").widgets.button;
const ui_dialog = @import("ui").widgets.dialog;
const ui_field = @import("ui").widgets.field;
const deletion = @import("../delete_dialog.zig");
const anim = @import("ui").anim;
const hover_glide = @import("ui").hover_glide;
const scrollbar = @import("ui").widgets.scrollbar;
const ui_theme = @import("ui").theme;
const IconId = @import("ui").layout.IconId;
const app_thumbs = @import("app_thumbs.zig");
const app_input = @import("app_input.zig");
const app_edit = @import("app_edit.zig");
const app_dialogs = @import("app_dialogs.zig");
const app_render = @import("app_render.zig");
const a = std.heap.c_allocator;
const Dialog = enum { none, save, trash, discard };
const Pending = union(enum) { none, close, select: usize };
pub const Action = enum { back, previous, next, rotate, crop, undo, smaller, larger, fit, actual, save, trash };
pub const labels = [_]i18n.Message{ i18n.msg("Back"), i18n.msg("Previous"), i18n.msg("Next"), i18n.msg("Rotate"), i18n.msg("Crop"), i18n.msg("Undo edits"), i18n.msg("Zoom out"), i18n.msg("Zoom in"), i18n.msg("Fit"), i18n.msg("100%"), i18n.msg("Save as"), i18n.msg("Trash") };
const Thumb = struct { index: usize, image: ?decoder.Image, stamp: ?cache_mod.Stamp };

pub const App = struct {
    paths: []const [:0]const u8,
    loader: *decoder.Loader,
    thumbnail_loader: *decoder.Loader,
    thumbnail_generation: u64 = 0,
    image_cache: cache_mod.Cache = .{},
    image_stamp: ?cache_mod.Stamp = null,
    selected: usize,
    generation: u64 = 0,
    image: ?decoder.Image = null,
    thumbs: [64]?Thumb = @splat(null),
    error_message: ?[]const u8 = null,
    w: i32 = 1080,
    h: i32 = 720,
    scale: i32 = 1,
    /// Fractional device pixels per logical pixel; `scale` is its ceiling.
    density: f64 = 1,
    dirty: bool = true,
    title_changed: bool = true,
    title: [1024:0]u8 = @splat(0),
    closed: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    dragging: bool = false,
    px: f64 = 0,
    py: f64 = 0,
    hover: ?Action = null,
    view: view.View = .{},
    io: std.Io = undefined,
    order: std.ArrayList(usize) = .empty,
    strip_start: ?usize = null,
    strip_drag: scrollbar.Drag = .{},
    selection_glide: hover_glide.Glide = .{},
    strip_appearance: scrollbar.Appearance = .{},
    strip_observed: usize = 0,
    animation_active: bool = false,
    deletion: deletion.State = .{},
    original: ?decoder.Image = null,
    modified: bool = false,
    crop_mode: bool = false,
    crop_drag: bool = false,
    filename_drag: bool = false,
    crop_start: [2]f64 = .{ 0, 0 },
    crop_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    dialog: Dialog = .none,
    pending: Pending = .none,
    filename: Editor = .{},
    notice: [1024]u8 = @splat(0),
    notice_len: usize = 0,
    operation: ?*edit.Operation = null,
    trash_stamp: ?cache_mod.Stamp = null,

    pub fn init(paths: []const [:0]const u8, selected: usize) !App {
        const loader = try decoder.Loader.init(paths);
        errdefer loader.deinit();
        const thumbnail_loader = try decoder.Loader.init(paths);
        errdefer thumbnail_loader.deinit();
        var self: App = .{ .paths = paths, .selected = selected, .loader = loader, .thumbnail_loader = thumbnail_loader };
        try self.order.ensureTotalCapacity(a, paths.len);
        for (0..paths.len) |i| self.order.appendAssumeCapacity(i);
        self.select(selected);
        return self;
    }
    pub fn deinit(self: *App) void {
        self.deletion.deinit();
        if (self.operation) |op| op.deinit();
        if (self.original) |im| im.deinit();
        self.filename.deinit(a);
        self.order.deinit(a);
        self.loader.deinit();
        self.thumbnail_loader.deinit();
        self.image_cache.deinit();
        if (self.image) |im| im.deinit();
        for (self.thumbs) |t| if (t) |thumb| {
            if (thumb.image) |im| im.deinit();
        };
    }
    pub fn getTitle(self: *App) [*:0]const u8 {
        return &self.title;
    }

    pub const setTitle = app_thumbs.setTitle;
    pub const queueRequests = app_thumbs.queueRequests;
    pub const select = app_thumbs.select;
    pub const thumbCount = app_thumbs.thumbCount;
    pub const thumbStart = app_thumbs.thumbStart;
    pub const thumbHeight = app_thumbs.thumbHeight;
    pub const thumbRect = app_thumbs.thumbRect;
    pub const cached = app_thumbs.cached;
    pub const thumbImage = app_thumbs.thumbImage;
    pub const requestThumbnails = app_thumbs.requestThumbnails;
    pub const sync = app_thumbs.sync;
    pub const storeThumb = app_thumbs.storeThumb;
    pub const storeThumbStamped = app_thumbs.storeThumbStamped;
    pub const stepAnimations = app_thumbs.stepAnimations;
    pub const animationTimeout = app_thumbs.animationTimeout;
    pub const stripBar = app_thumbs.stripBar;
    pub const scrollStrip = app_thumbs.scrollStrip;
    pub const dragStrip = app_thumbs.dragStrip;
    pub fn resize(self: *App, w: i32, h: i32) void {
        const old_count = self.thumbCount();
        self.w = w;
        self.h = h;
        self.clamp();
        if (self.thumbCount() != old_count) {
            self.selection_glide.reset();
            self.revealSelected();
            self.requestThumbnails();
        }
        self.dirty = true;
    }

    pub const canvas = app_input.canvas;
    pub const buttonRect = app_input.buttonRect;
    pub const buttonProximity = app_input.buttonProximity;
    pub const hit = app_input.hit;
    pub const clamp = app_input.clamp;
    pub const zoom = app_input.zoom;
    pub const navigate = app_input.navigate;
    pub const perform = app_input.perform;
    pub const keyRepeats = app_input.keyRepeats;
    pub const handleKey = app_input.handleKey;
    pub const handleMotion = app_input.handleMotion;
    pub const handleButton = app_input.handleButton;
    pub const cancelDrag = app_input.cancelDrag;
    pub const overFilmstrip = app_input.overFilmstrip;
    pub const handleScroll = app_input.handleScroll;
    pub const count = app_input.count;
    pub const indexAt = app_input.indexAt;
    pub const position = app_input.position;
    pub const toolbarBottom = app_input.toolbarBottom;
    pub const enabled = app_input.enabled;
    pub const message = app_input.message;
    pub const revealSelected = app_input.revealSelected;

    pub const requestClose = app_edit.requestClose;
    pub const requestSelect = app_edit.requestSelect;
    pub const finishPending = app_edit.finishPending;
    pub const replaceImage = app_edit.replaceImage;
    pub const undo = app_edit.undo;
    pub const imageRect = app_edit.imageRect;
    pub const imagePoint = app_edit.imagePoint;
    pub const beginCrop = app_edit.beginCrop;
    pub const hasCropSelection = app_edit.hasCropSelection;
    pub const applyCrop = app_edit.applyCrop;
    pub const drawCrop = app_edit.drawCrop;

    pub const openSave = app_dialogs.openSave;
    pub const deleteAction = app_dialogs.deleteAction;
    pub const confirmDialog = app_dialogs.confirmDialog;
    pub const syncOperation = app_dialogs.syncOperation;
    pub const dialogRect = app_dialogs.dialogRect;
    pub const dialogButton = app_dialogs.dialogButton;
    pub const filenameRect = app_dialogs.filenameRect;
    pub const placeCaret = app_dialogs.placeCaret;
    pub const filenameText = app_dialogs.filenameText;
    pub const drawDialog = app_dialogs.drawDialog;

    pub const cursorName = app_render.cursorName;
    pub const render = app_render.render;
};
pub fn clippedText(cr: *c.cairo_t, str: []const u8, r: Rect, size: f64, bold: bool) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, r.x, r.y, r.w, r.h);
    c.cairo_clip(cr);
    drawText(cr, str, r.x, r.y + (r.h + size) / 2 - 2, size, bold);
}
pub fn rounded(cr: *c.cairo_t, r: Rect, radius: f64) void {
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, r.x + r.w - radius, r.y + radius, radius, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, r.x + r.w - radius, r.y + r.h - radius, radius, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, r.x + radius, r.y + r.h - radius, radius, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, r.x + radius, r.y + radius, radius, std.math.pi, std.math.pi * 1.5);
    c.cairo_close_path(cr);
}
pub fn paintImage(cr: *c.cairo_t, im: decoder.Image, r: Rect) void {
    const surface = c.cairo_image_surface_create_for_data(@ptrCast(im.pixels.ptr), c.CAIRO_FORMAT_ARGB32, im.w, im.h, im.w * 4);
    defer c.cairo_surface_destroy(surface);
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_translate(cr, r.x, r.y);
    c.cairo_scale(cr, r.w / @as(f64, @floatFromInt(im.w)), r.h / @as(f64, @floatFromInt(im.h)));
    c.cairo_set_source_surface(cr, surface, 0, 0);
    c.cairo_pattern_set_filter(c.cairo_get_source(cr), c.CAIRO_FILTER_BILINEAR);
    c.cairo_rectangle(cr, 0, 0, @floatFromInt(im.w), @floatFromInt(im.h));
    c.cairo_fill(cr);
}
pub fn checker(cr: *c.cairo_t, r: Rect) void {
    setSource(cr, ui_theme.global.image_checker_dark);
    c.cairo_paint(cr);
    setSource(cr, ui_theme.global.image_checker_light);
    const cell: f64 = ui_theme.global.image_checker_size;
    var y: f64 = r.y;
    var row: usize = 0;
    while (y < r.y + r.h) : (y += cell) {
        var x = r.x + @as(f64, @floatFromInt(row % 2)) * cell;
        while (x < r.x + r.w) : (x += cell * 2) c.cairo_rectangle(cr, x, y, cell, cell);
        row += 1;
    }
    c.cairo_fill(cr);
}
/// Each toolbar action's glyph in the shell's icon set (ui/layout.zig).
pub fn glyph(act: Action) IconId {
    return switch (act) {
        .back, .previous => .chevron_left,
        .next => .chevron_right,
        .rotate => .rotate,
        .crop => .crop,
        .undo => .undo,
        .smaller => .zoom_out,
        .larger => .zoom_in,
        .fit, .actual => .fit,
        .save => .save,
        .trash => .trash,
    };
}

pub fn shellRect(r: Rect) shell_ui.Rect {
    return .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) };
}

pub fn setSource(cr: *c.cairo_t, color: [4]f32) void {
    c.cairo_set_source_rgba(cr, color[0], color[1], color[2], color[3]);
}
// Text goes through the shell's renderer (text.zig, Manrope), like Files.
pub fn drawText(cr: *c.cairo_t, str: []const u8, x: f64, y: f64, size: f64, bold: bool) void {
    if (!std.unicode.utf8ValidateSlice(str)) return;
    shell_ui.drawText(cr, str, x, y, size, bold);
}
pub fn measureText(cr: *c.cairo_t, str: []const u8, size: f64, bold: bool) f64 {
    if (!std.unicode.utf8ValidateSlice(str)) return 0;
    return shell_ui.measureText(cr, str, size, bold);
}

test "filmstrip keeps current image visible across narrow layouts" {
    const paths = [_][:0]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" };
    var app: App = .{ .paths = &paths, .selected = 0, .loader = undefined, .thumbnail_loader = undefined };
    for ([_]i32{ 360, 760, 1080, 2000, 3840 }) |width| {
        app.w = width;
        for (0..paths.len) |index| {
            app.selected = index;
            const start = app.thumbStart();
            try std.testing.expectApproxEqAbs(@as(f64, 16), app.thumbRect(0).x, 0.001);
            const last = app.thumbRect(app.thumbCount() - 1);
            try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(width - 16)), last.x + last.w, 0.001);
            try std.testing.expect(index >= start and index < start + app.thumbCount());
            for (0..app.thumbCount()) |slot| {
                const r = app.thumbRect(slot);
                try std.testing.expect(r.x >= 0 and r.x + r.w <= @as(f64, @floatFromInt(width)));
            }
        }
    }
}

test "filmstrip selection glides and scrollbar feedback settles without idle timers" {
    const saved = anim.currentSettings();
    defer anim.applySettings(saved);
    anim.applySettings(.{ .reduced_motion = .off });
    const paths = [_][:0]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" };
    var app: App = .{ .paths = &paths, .selected = 0, .strip_start = 0, .loader = undefined, .thumbnail_loader = undefined };
    app.stepAnimations(0);
    app.stepAnimations(10000);
    try std.testing.expect(app.animationTimeout(10000) == null);
    app.selected = 1;
    app.stepAnimations(10010);
    app.stepAnimations(10060);
    try std.testing.expect(app.selection_glide.frame.col > 0 and app.selection_glide.frame.col < 1);
    app.stepAnimations(20000);
    try std.testing.expectEqual(@as(f32, 1), app.selection_glide.frame.col);
    const bar = app.stripBar().?;
    app.px = @as(f64, bar.thumb.x) + 5;
    app.py = @as(f64, bar.thumb.y) + 5;
    app.stepAnimations(20010);
    app.stepAnimations(20200);
    try std.testing.expectEqual(@as(f32, 1), app.strip_appearance.accent);
    try std.testing.expectEqual(@as(f32, 9), app.strip_appearance.width(8));
    app.px = -1;
    app.py = -1;
    app.strip_start = 1;
    app.stepAnimations(20210);
    app.stepAnimations(20400);
    try std.testing.expectEqual(@as(f32, 0.35), app.strip_appearance.accent);
    try std.testing.expect(app.animationTimeout(20400) != null);
    app.stepAnimations(20610);
    app.stepAnimations(21000);
    try std.testing.expect(app.animationTimeout(21000) == null);
    anim.applySettings(.{ .reduced_motion = .on });
    app.selected = 2;
    app.stepAnimations(22000);
    try std.testing.expectEqual(@as(f32, 1), app.selection_glide.frame.col);
    try std.testing.expect(app.animationTimeout(22000) == null);
}

test "image delete dialog shares keyboard navigation and cancel preserves the image" {
    const paths = [_][:0]const u8{"/nonexistent/image.png"};
    var app: App = .{ .paths = &paths, .selected = 0, .loader = undefined, .thumbnail_loader = undefined };
    defer app.deletion.deinit();
    app.handleKey(c.XKB_KEY_Delete, "");
    try std.testing.expectEqual(Dialog.trash, app.dialog);
    try std.testing.expectEqualStrings(paths[0], app.deletion.paths.items[0]);
    const initial = app.deletion.geometry(app.w, app.h);
    app.handleMotion(initial.x + 100, initial.y + 20);
    app.handleButton(0x110, true);
    app.dirty = false;
    app.handleMotion(initial.x + 170, initial.y + 60);
    const moved = app.deletion.geometry(app.w, app.h);
    try std.testing.expectEqual(initial.x + 70, moved.x);
    try std.testing.expectEqual(initial.y + 40, moved.y);
    try std.testing.expect(app.dirty);
    // Motion outside the host keeps the card reachable; release ends the grab.
    app.handleMotion(-100, -100);
    const edge = app.deletion.geometry(app.w, app.h);
    try std.testing.expectEqual(@as(f64, 8), edge.x);
    try std.testing.expectEqual(@as(f64, 8), edge.y);
    app.handleButton(0x110, false);
    app.handleMotion(400, 300);
    try std.testing.expectEqual(edge, app.deletion.geometry(app.w, app.h));
    app.handleMotion(edge.x + 100, edge.y + 20);
    app.handleButton(0x110, true);
    app.cancelDrag();
    app.handleMotion(400, 300);
    try std.testing.expectEqual(edge, app.deletion.geometry(app.w, app.h));
    // A body control still receives its click after movement.
    app.handleMotion(edge.x + edge.toggle.x + 5, edge.y + edge.toggle.y + 5);
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    try std.testing.expect(app.deletion.permanent);
    try std.testing.expect(app.deletion.placement.grab == null);
    app.handleButton(0x110, true);
    app.handleButton(0x110, false);
    try std.testing.expect(!app.deletion.permanent);
    app.handleKey(c.XKB_KEY_Tab, "");
    app.handleKey(c.XKB_KEY_space, "");
    try std.testing.expect(app.deletion.permanent);
    app.handleKey(c.XKB_KEY_Escape, "");
    try std.testing.expectEqual(Dialog.none, app.dialog);
    try std.testing.expectEqual(@as(usize, 0), app.deletion.paths.items.len);
    try std.testing.expect(app.operation == null and !app.closed);
}
