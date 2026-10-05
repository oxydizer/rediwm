const std = @import("std");
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
const a = std.heap.c_allocator;
const Dialog = enum { none, save, trash, discard };
const Pending = union(enum) { none, close, select: usize };
const Action = enum { back, previous, next, rotate, crop, undo, smaller, larger, fit, actual, save, trash };
const labels = [_][]const u8{ "Back", "Previous", "Next", "Rotate", "Crop", "Undo edits", "Zoom out", "Zoom in", "Fit", "100%", "Save as", "Trash" };
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
    fn setTitle(self: *App) void {
        const raw_name = std.fs.path.basename(self.paths[self.selected]);
        const name = if (std.unicode.utf8ValidateSlice(raw_name)) raw_name else "Image";
        _ = std.fmt.bufPrintZ(&self.title, "{s}{s} — Images ({d}/{d})", .{ if (self.modified) "* " else "", name, self.position() + 1, self.count() }) catch {
            _ = std.fmt.bufPrintZ(&self.title, "Images ({d}/{d})", .{ self.position() + 1, self.count() }) catch unreachable;
        };
        self.title_changed = true;
    }
    fn queueRequests(self: *App) void {
        var jobs: [8]decoder.Job = undefined;
        var job_count: usize = 0;

        if (self.image == null) {
            jobs[job_count] = .{ .index = self.selected };
            job_count += 1;
        }

        // Speculatively preload immediate neighbors so navigation is instant
        const pos = self.position();
        const neighbors = [_]usize{
            self.indexAt(@min(pos + 1, self.count() - 1)),
            self.indexAt(pos -| 1),
            self.indexAt(@min(pos + 2, self.count() - 1)),
            self.indexAt(pos -| 2),
        };

        for (neighbors) |idx| {
            if (idx == self.selected) continue;
            if (self.image_cache.contains(idx)) continue;
            var already = false;
            for (jobs[0..job_count]) |j| {
                if (j.index == idx) {
                    already = true;
                    break;
                }
            }
            if (!already and job_count < jobs.len) {
                jobs[job_count] = .{ .index = idx };
                job_count += 1;
            }
        }

        self.generation = self.loader.request(jobs[0..job_count]);
    }
    fn select(self: *App, index: usize) void {
        if (self.original) |original| {
            if (self.image) |im| im.deinit();
            self.storeThumb(self.selected, decoder.makeThumbnail(original) catch null);
            self.image_cache.put(self.selected, original, self.image_stamp);
            self.original = null;
        } else if (self.image) |im| self.image_cache.put(self.selected, im, self.image_stamp);
        self.modified = false;
        self.crop_mode = false;
        self.crop_drag = false;
        self.notice_len = 0;
        self.selected = index;
        self.image_stamp = cache_mod.Stamp.read(self.paths[index]);
        self.image = self.image_cache.take(index, self.image_stamp);
        self.error_message = null;
        self.view.reset();
        self.dragging = false;
        self.setTitle();
        self.queueRequests();
        if (!self.cached(index)) {
            if (self.image) |im| self.storeThumb(index, decoder.makeThumbnail(im) catch null);
        }
        self.revealSelected();
        self.requestThumbnails();
        self.dirty = true;
    }
    fn thumbCount(self: *const App) usize {
        return @min(self.count(), @as(usize, @intCast(std.math.clamp(@divTrunc(self.w - 20, 156), 1, 32))));
    }
    fn thumbStart(self: *const App) usize {
        const n = self.thumbCount();
        return @min(self.strip_start orelse (self.position() -| (n / 2)), self.count() - n);
    }
    fn thumbHeight(self: *const App) f64 {
        return if (self.h < 360) 56 else 84;
    }
    fn thumbRect(self: *const App, slot: usize) Rect {
        const n: f64 = @floatFromInt(self.thumbCount());
        const width = (@as(f64, @floatFromInt(self.w)) - 32 - (n - 1) * 12) / n;
        return .{ .x = (@as(f64, @floatFromInt(self.w)) - (width + 12) * n + 12) / 2 + @as(f64, @floatFromInt(slot)) * (width + 12), .y = @as(f64, @floatFromInt(self.h - 32)) - self.thumbHeight(), .w = width, .h = self.thumbHeight() };
    }
    fn cached(self: *const App, index: usize) bool {
        for (self.thumbs) |slot| if (slot) |t| {
            if (t.index == index) return true;
        };
        return false;
    }
    fn thumbImage(self: *const App, index: usize) ?decoder.Image {
        for (self.thumbs) |slot| if (slot) |t| {
            if (t.index == index) return t.image;
        };
        return null;
    }
    fn requestThumbnails(self: *App) void {
        // Resizing only changes thumbnail requests, never restarts the main decode.
        var jobs: [32]decoder.Job = undefined;
        var n: usize = 0;
        const start = self.thumbStart();
        for (start..start + self.thumbCount()) |pos| {
            const i = self.indexAt(pos);
            // Check only when the strip changes, not on every paint or motion.
            const stamp = cache_mod.Stamp.read(self.paths[i]);
            for (&self.thumbs) |*slot| if (slot.*) |t| {
                if (t.index == i and !std.meta.eql(t.stamp, stamp)) {
                    if (t.image) |im| im.deinit();
                    slot.* = null;
                }
            };
            if (!self.cached(i)) {
                if (i == self.selected) {
                    if (self.image) |im| self.storeThumb(i, decoder.makeThumbnail(im) catch null);
                } else {
                    jobs[n] = .{ .index = i, .thumbnail = true };
                    n += 1;
                }
            }
        }
        self.thumbnail_generation = self.thumbnail_loader.request(jobs[0..n]);
    }
    pub fn sync(self: *App) void {
        self.syncOperation();
        if (self.closed) return;
        while (self.loader.take()) |result| {
            if (result.generation != self.generation) {
                if (result.image) |im| im.deinit();
            } else if (result.job.index == self.selected) {
                self.image = result.image;
                self.storeThumb(self.selected, if (self.image) |im| decoder.makeThumbnail(im) catch null else null);
                // Only cache pixels if the file remained unchanged throughout decoding.
                if (!std.meta.eql(self.image_stamp, cache_mod.Stamp.read(self.paths[self.selected]))) self.image_stamp = null;
                self.error_message = if (result.err) |err| switch (err) {
                    error.ImageTooLarge => "Image exceeds the 32 megapixel preview limit",
                    error.UnsupportedImage => "Unsupported image, missing decoder, or file unavailable",
                    else => "Could not read this image",
                } else null;
                self.dirty = true;
            } else {
                // Preloaded neighbor completed: cache it for instant display when navigated to
                if (result.image) |im| {
                    const stamp = cache_mod.Stamp.read(self.paths[result.job.index]);
                    if (std.meta.eql(stamp, result.stamp) and !self.cached(result.job.index)) {
                        self.storeThumbStamped(result.job.index, decoder.makeThumbnail(im) catch null, result.stamp);
                        self.dirty = true;
                    }
                    self.image_cache.put(result.job.index, im, if (std.meta.eql(stamp, result.stamp)) stamp else null);
                }
            }
        }
        while (self.thumbnail_loader.take()) |result| {
            if (result.generation != self.thumbnail_generation) {
                if (result.image) |im| im.deinit();
            } else {
                self.storeThumbStamped(result.job.index, result.image, result.stamp);
                self.dirty = true;
            }
        }
    }
    fn storeThumb(self: *App, index: usize, image: ?decoder.Image) void {
        self.storeThumbStamped(index, image, if (index == self.selected) self.image_stamp else cache_mod.Stamp.read(self.paths[index]));
    }
    fn storeThumbStamped(self: *App, index: usize, image: ?decoder.Image, stamp: ?cache_mod.Stamp) void {
        var slot: usize = self.thumbs.len - 1;
        for (self.thumbs, 0..) |entry, i| {
            if (entry == null) {
                slot = i;
                break;
            }
        }
        // Invalidated thumbnails leave holes; find an existing entry first.
        for (self.thumbs, 0..) |entry, i| {
            if (entry != null and entry.?.index == index) {
                slot = i;
                break;
            }
        }
        if (self.thumbs[slot]) |old| if (old.image) |im| im.deinit();
        var i = slot;
        while (i > 0) : (i -= 1) self.thumbs[i] = self.thumbs[i - 1];
        self.thumbs[0] = .{ .index = index, .image = image, .stamp = stamp };
    }
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
    fn canvas(self: *const App) Rect {
        const top = self.toolbarBottom() + 28;
        return .{ .x = 16, .y = top, .w = @floatFromInt(@max(1, self.w - 32)), .h = @max(1, @as(f64, @floatFromInt(self.h)) - top - self.thumbHeight() - 48) };
    }
    fn buttonRect(self: *const App, action: Action) Rect {
        const columns: usize = if (self.w < 740) 6 else 12;
        const width = (@as(f64, @floatFromInt(self.w)) - 24) / @as(f64, @floatFromInt(columns));
        const n = @intFromEnum(action);
        return .{ .x = 12 + @as(f64, @floatFromInt(n % columns)) * width, .y = 8 + @as(f64, @floatFromInt(n / columns)) * 40, .w = width - 4, .h = 36 };
    }
    fn hit(self: *const App, x: f64, y: f64) ?Action {
        inline for (std.meta.tags(Action)) |action| if (self.buttonRect(action).contains(x, y)) return action;
        return null;
    }
    fn clamp(self: *App) void {
        if (self.image) |im| self.view.clamp(self.canvas(), @floatFromInt(im.w), @floatFromInt(im.h));
    }
    fn zoom(self: *App, factor: f64, x: f64, y: f64) void {
        if (self.image) |im| {
            self.view.zoomAt(factor, x, y, self.canvas(), @floatFromInt(im.w), @floatFromInt(im.h));
            self.dirty = true;
        }
    }
    fn navigate(self: *App, forward: bool) void {
        const pos = self.position();
        const index = self.indexAt(if (forward) @min(pos + 1, self.count() - 1) else pos -| 1);
        if (index != self.selected) self.requestSelect(index);
    }
    fn perform(self: *App, act: Action) void {
        if (self.closed or self.operation != null or !self.enabled(act)) return;
        self.cancelDrag();
        const box = self.canvas();
        switch (act) {
            .back => self.requestClose(),
            .previous => self.navigate(false),
            .next => self.navigate(true),
            .rotate => {
                if (self.image) |im| self.replaceImage(edit.rotate(im) catch {
                    self.message("Could not rotate: not enough memory.");
                    return;
                });
            },
            .crop => if (self.crop_mode) self.applyCrop() else self.beginCrop(),
            .undo => self.undo(),
            .save => self.openSave(),
            .trash => {
                self.cancelDrag();
                self.trash_stamp = cache_mod.Stamp.read(self.paths[self.selected]);
                self.deletion.deinit();
                self.deletion.add(self.paths[self.selected], std.fs.path.basename(self.paths[self.selected]), false, if (self.trash_stamp) |stamp| stamp.size else 0, null) catch {
                    self.deletion.deinit();
                    self.message("Could not open the delete dialog.");
                    return;
                };
                self.deletion.permanent = self.shift;
                self.dialog = .trash;
                self.notice_len = 0;
            },
            .smaller => self.zoom(1.0 / 1.25, box.x + box.w / 2, box.y + box.h / 2),
            .larger => self.zoom(1.25, box.x + box.w / 2, box.y + box.h / 2),
            .fit => {
                self.view.fitting = true;
                self.view.pan_x = 0;
                self.view.pan_y = 0;
            },
            .actual => {
                self.view.fitting = false;
                self.view.zoom = 1 / @as(f64, @floatFromInt(self.scale));
                self.clamp();
            },
        }
        self.dirty = true;
    }
    /// Which held keys the client repeats: typing in the save dialog's name
    /// field; stepping through images and zooming otherwise. Delete, rotate,
    /// crop and the rest fire once.
    pub fn keyRepeats(self: *const App, sym: u32, utf8: []const u8) bool {
        if (self.ctrl or self.alt) return false;
        if (self.dialog != .none) return self.dialog == .save and @import("ui").key_repeat.editingKey(switch (sym) {
            c.XKB_KEY_BackSpace, c.XKB_KEY_Delete, c.XKB_KEY_Left, c.XKB_KEY_Right => true,
            else => false,
        }, utf8);
        if (self.crop_mode) return false;
        return switch (sym) {
            c.XKB_KEY_Left, c.XKB_KEY_Right, c.XKB_KEY_plus, c.XKB_KEY_equal, c.XKB_KEY_KP_Add, c.XKB_KEY_minus, c.XKB_KEY_KP_Subtract => true,
            else => false,
        };
    }

    pub fn handleKey(self: *App, sym: u32, utf8: []const u8) void {
        if (self.closed or self.operation != null) return;
        if (self.dialog == .trash) {
            self.deleteAction(self.deletion.key(sym));
            return;
        }
        if (self.dialog != .none) {
            self.cancelDrag();
            if (sym == c.XKB_KEY_Escape) {
                self.dialog = .none;
                self.pending = .none;
                self.notice_len = 0;
            } else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) self.confirmDialog() else if (self.dialog == .save) self.filename.key(a, sym, utf8, self.ctrl, self.shift, self.alt);
            self.dirty = true;
            return;
        }
        if (self.ctrl) {
            if (sym == c.XKB_KEY_s or sym == c.XKB_KEY_S) self.perform(.save);
            if (sym == c.XKB_KEY_z or sym == c.XKB_KEY_Z) self.perform(.undo);
            return;
        }
        if (self.alt) return;
        if (self.crop_mode) {
            if (sym == c.XKB_KEY_Escape) {
                self.crop_mode = false;
                self.crop_drag = false;
                self.dirty = true;
                return;
            }
            if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter) {
                self.applyCrop();
                return;
            }
        }
        switch (sym) {
            c.XKB_KEY_Escape, c.XKB_KEY_space => self.perform(.back),
            c.XKB_KEY_Left => self.perform(.previous),
            c.XKB_KEY_Right => self.perform(.next),
            c.XKB_KEY_r, c.XKB_KEY_R => self.perform(.rotate),
            c.XKB_KEY_c, c.XKB_KEY_C => self.perform(.crop),
            c.XKB_KEY_Delete => self.perform(.trash),
            c.XKB_KEY_plus, c.XKB_KEY_equal, c.XKB_KEY_KP_Add => self.perform(.larger),
            c.XKB_KEY_minus, c.XKB_KEY_KP_Subtract => self.perform(.smaller),
            c.XKB_KEY_f, c.XKB_KEY_F, c.XKB_KEY_0 => self.perform(.fit),
            c.XKB_KEY_1 => self.perform(.actual),
            c.XKB_KEY_Home => self.requestSelect(self.indexAt(0)),
            c.XKB_KEY_End => self.requestSelect(self.indexAt(self.count() - 1)),
            else => {},
        }
    }
    pub fn handleMotion(self: *App, x: f64, y: f64) void {
        if (self.closed) return;
        if (self.dialog == .trash) {
            if (self.deletion.motion(self.w, self.h, x, y)) self.dirty = true;
            const g = self.deletion.geometry(self.w, self.h);
            if (g.target(self.px, self.py) != g.target(x, y)) self.dirty = true;
        }
        const hover = if (self.dialog == .none and self.operation == null) self.hit(x, y) else null;
        if (hover != self.hover) {
            self.hover = hover;
            self.dirty = true;
        }
        if (self.operation != null or (self.dialog != .none and !self.filename_drag)) {
            self.px = x;
            self.py = y;
            return;
        }
        if (self.filename_drag) {
            self.px = x;
            self.py = y;
            self.placeCaret(true);
            self.dirty = true;
        } else if (self.strip_drag.active) self.dragStrip(x, y) else if (self.crop_drag) {
            const p = self.imagePoint(x, y);
            self.crop_rect = .{ .x = @min(p[0], self.crop_start[0]), .y = @min(p[1], self.crop_start[1]), .w = @abs(p[0] - self.crop_start[0]), .h = @abs(p[1] - self.crop_start[1]) };
            self.dirty = true;
        } else if (self.dragging) {
            self.view.pan_x += x - self.px;
            self.view.pan_y += y - self.py;
            self.clamp();
            self.dirty = true;
        }
        self.px = x;
        self.py = y;
    }
    pub fn handleButton(self: *App, button: u32, pressed: bool) void {
        if (self.closed or button != 0x110) return;
        if (self.dialog == .trash and self.deletion.pointerButton(self.w, self.h, self.px, self.py, pressed)) return;
        if (!pressed) {
            self.cancelDrag();
            return;
        }
        if (self.operation != null) return;
        if (self.dialog == .trash) {
            self.deletion.keyboard_focus = false;
            self.deleteAction(self.deletion.geometry(self.w, self.h).hit(self.px, self.py));
            return;
        }
        if (self.dialog != .none) {
            if (self.dialogButton(0).contains(self.px, self.py)) {
                self.dialog = .none;
                self.pending = .none;
                self.notice_len = 0;
            } else if (self.dialogButton(1).contains(self.px, self.py)) {
                if (self.dialog == .discard) self.finishPending() else self.confirmDialog();
            } else if (self.dialog == .discard and self.dialogButton(2).contains(self.px, self.py)) self.openSave() else if (self.dialog == .save and self.filenameRect().contains(self.px, self.py)) {
                self.placeCaret(self.shift);
                self.filename_drag = true;
            }
            self.dirty = true;
            return;
        }
        if (self.hit(self.px, self.py)) |act| {
            self.perform(act);
            return;
        }
        if (self.stripBar()) |bar| {
            const start: f32 = @floatFromInt(self.thumbStart());
            if (scrollbar.press(bar, @floatCast(self.px), @floatCast(self.py), start)) |action| {
                switch (action) {
                    .grab => self.strip_drag.begin(bar, @floatCast(self.px), @floatCast(self.py), start),
                    .page => |offset| self.scrollStrip(@intFromFloat(@round(offset))),
                }
                return;
            }
        }
        for (0..self.thumbCount()) |slot| {
            if (self.thumbRect(slot).contains(self.px, self.py)) {
                self.requestSelect(self.indexAt(self.thumbStart() + slot));
                return;
            }
        }
        if (self.crop_mode and self.imageRect().contains(self.px, self.py) and self.canvas().contains(self.px, self.py)) {
            self.crop_start = self.imagePoint(self.px, self.py);
            self.crop_rect = .{ .x = self.crop_start[0], .y = self.crop_start[1], .w = 0, .h = 0 };
            self.crop_drag = true;
            self.dirty = true;
        } else self.dragging = !self.crop_mode and self.image != null and self.canvas().contains(self.px, self.py) and !self.view.fitting;
    }
    pub fn cancelDrag(self: *App) void {
        self.deletion.placement.grab = null;
        if (self.dragging or self.strip_drag.active or self.crop_drag or self.filename_drag) self.dirty = true;
        self.dragging = false;
        self.strip_drag.end();
        self.crop_drag = false;
        self.filename_drag = false;
    }
    pub fn overFilmstrip(self: *const App) bool {
        return self.count() > 0 and self.py >= self.thumbRect(0).y - 8;
    }
    pub fn handleScroll(self: *App, amount: f64) void {
        if (self.closed or amount == 0 or self.dialog != .none or self.operation != null) return;
        if (self.overFilmstrip()) {
            self.scrollStrip(if (amount > 0) self.thumbStart() + 1 else self.thumbStart() -| 1);
        } else if (!self.crop_mode and self.canvas().contains(self.px, self.py)) self.zoom(if (amount < 0) 1.15 else 1.0 / 1.15, self.px, self.py);
    }
    fn count(self: *const App) usize {
        return if (self.order.capacity > 0) self.order.items.len else self.paths.len;
    }
    fn indexAt(self: *const App, pos: usize) usize {
        return if (self.order.capacity > 0) self.order.items[pos] else pos;
    }
    fn position(self: *const App) usize {
        if (self.order.capacity == 0) return self.selected;
        for (self.order.items, 0..) |idx, pos| if (idx == self.selected) return pos;
        return 0;
    }
    fn toolbarBottom(self: *const App) f64 {
        return if (self.w < 740) 84 else 44;
    }
    fn enabled(self: *const App, act: Action) bool {
        return switch (act) {
            .previous => self.position() > 0,
            .next => self.position() + 1 < self.count(),
            .rotate, .crop, .save => self.image != null,
            .smaller, .larger, .fit, .actual => self.image != null and !self.crop_mode,
            .undo => self.original != null,
            else => true,
        };
    }
    fn message(self: *App, msg: []const u8) void {
        const n = @min(msg.len, self.notice.len);
        @memcpy(self.notice[0..n], msg[0..n]);
        self.notice_len = n;
        self.dirty = true;
    }
    fn revealSelected(self: *App) void {
        const pos = self.position();
        const start = self.thumbStart();
        self.strip_start = if (pos < start) pos else if (pos >= start + self.thumbCount()) pos + 1 - self.thumbCount() else start;
    }
    pub fn stepAnimations(self: *App, now: i64) void {
        if (self.count() == 0) {
            self.animation_active = false;
            self.strip_appearance = .{};
            return;
        }
        const start = self.thumbStart();
        const pos = self.position();
        const visible = pos >= start and pos < start + self.thumbCount();
        self.selection_glide.setTarget(now, if (visible) .{ .col = @intCast(pos - start), .row = 0 } else null);
        const pitch: f32 = @floatCast(self.thumbRect(0).w + 12);
        if (self.selection_glide.step(now, 1 / (pitch * @as(f32, @floatFromInt(self.scale))), 1)) self.dirty = true;
        const bar = self.stripBar();
        const hovered = self.dialog == .none and if (bar) |b| b.overThumb(@floatCast(self.px), @floatCast(self.py)) else false;
        if (self.strip_appearance.step(now, start != self.strip_observed, hovered, self.strip_drag.active, bar != null)) self.dirty = true;
        self.strip_observed = start;
        self.animation_active = self.selection_glide.animating(now) or self.strip_appearance.active;
    }

    pub fn animationTimeout(self: *const App, now: i64) ?u32 {
        if (self.animation_active) return 16;
        if (self.strip_appearance.deadline) |deadline| return @intCast(std.math.clamp(deadline - now, 0, 60_000));
        return null;
    }

    /// The filmstrip's bar, centred in the margin under the thumbnails and
    /// scrolling by thumbnail; null while they all fit.
    fn stripBar(self: *const App) ?scrollbar.Geometry {
        if (self.count() == 0) return null;
        const strip = scrollbar.gutter(ui_theme.global.scrollbar_width);
        const track: scrollbar.Rect = .{ .x = 16, .y = @as(f32, @floatFromInt(self.h)) - 21 - strip / 2, .w = @floatFromInt(self.w - 32), .h = strip };
        return scrollbar.Geometry.compute(.horizontal, track, @floatFromInt(self.thumbCount()), @floatFromInt(self.count()), @floatFromInt(self.thumbStart()));
    }
    fn scrollStrip(self: *App, start: usize) void {
        const next = @min(start, self.count() - self.thumbCount());
        if (next == self.thumbStart()) return;
        self.strip_start = next;
        self.requestThumbnails();
        self.dirty = true;
    }
    fn dragStrip(self: *App, x: f64, y: f64) void {
        const bar = self.stripBar() orelse return;
        self.scrollStrip(@intFromFloat(@round(self.strip_drag.offsetAt(bar, @floatCast(x), @floatCast(y)))));
    }
    pub fn requestClose(self: *App) void {
        if (self.operation != null) {
            self.message("Please wait for the file operation to finish.");
            return;
        }
        self.cancelDrag();
        if (self.modified or self.hasCropSelection()) {
            self.pending = .close;
            self.dialog = .discard;
            self.notice_len = 0;
            self.dirty = true;
        } else self.closed = true;
    }
    fn requestSelect(self: *App, index: usize) void {
        if (index == self.selected or self.operation != null) return;
        self.cancelDrag();
        if (self.modified or self.hasCropSelection()) {
            self.pending = .{ .select = index };
            self.dialog = .discard;
            self.notice_len = 0;
            self.dirty = true;
        } else self.select(index);
    }
    fn finishPending(self: *App) void {
        const pending = self.pending;
        self.pending = .none;
        self.dialog = .none;
        switch (pending) {
            .none => {},
            .close => self.closed = true,
            .select => |index| self.select(index),
        }
        self.dirty = true;
    }
    fn replaceImage(self: *App, image: decoder.Image) void {
        self.cancelDrag();
        if (self.original == null) self.original = self.image else if (self.image) |im| im.deinit();
        self.image = image;
        self.modified = true;
        self.crop_mode = false;
        self.crop_drag = false;
        self.view.reset();
        self.storeThumb(self.selected, decoder.makeThumbnail(image) catch null);
        self.notice_len = 0;
        self.setTitle();
        self.dirty = true;
    }
    fn undo(self: *App) void {
        const original = self.original orelse return;
        if (self.image) |im| im.deinit();
        self.image = original;
        self.original = null;
        self.modified = false;
        self.crop_mode = false;
        self.crop_drag = false;
        self.view.reset();
        self.storeThumb(self.selected, decoder.makeThumbnail(original) catch null);
        self.message("Edits undone.");
        self.setTitle();
    }
    fn imageRect(self: *const App) Rect {
        const box = self.canvas();
        const im = self.image orelse return box;
        const z = self.view.scale(box, @floatFromInt(im.w), @floatFromInt(im.h));
        const w = @as(f64, @floatFromInt(im.w)) * z;
        const h = @as(f64, @floatFromInt(im.h)) * z;
        return .{ .x = box.x + (box.w - w) / 2 + self.view.pan_x, .y = box.y + (box.h - h) / 2 + self.view.pan_y, .w = w, .h = h };
    }
    fn imagePoint(self: *const App, x: f64, y: f64) [2]f64 {
        const im = self.image.?;
        const r = self.imageRect();
        return .{ std.math.clamp((x - r.x) * @as(f64, @floatFromInt(im.w)) / r.w, 0, @as(f64, @floatFromInt(im.w))), std.math.clamp((y - r.y) * @as(f64, @floatFromInt(im.h)) / r.h, 0, @as(f64, @floatFromInt(im.h))) };
    }
    fn beginCrop(self: *App) void {
        const im = self.image orelse return;
        self.crop_mode = true;
        self.view.reset();
        self.dragging = false;
        self.crop_rect = .{ .x = 0, .y = 0, .w = @floatFromInt(im.w), .h = @floatFromInt(im.h) };
        self.notice_len = 0;
        self.dirty = true;
    }
    fn hasCropSelection(self: *const App) bool {
        const im = self.image orelse return false;
        const r = self.crop_rect;
        return self.crop_mode and r.w >= 1 and r.h >= 1 and
            (r.x >= 1 or r.y >= 1 or @ceil(r.x + r.w) < @as(f64, @floatFromInt(im.w)) or @ceil(r.y + r.h) < @as(f64, @floatFromInt(im.h)));
    }
    fn applyCrop(self: *App) void {
        const im = self.image orelse return;
        const r = self.crop_rect;
        const x: i32 = @intFromFloat(@floor(r.x));
        const y: i32 = @intFromFloat(@floor(r.y));
        const w: i32 = @min(im.w, @as(i32, @intFromFloat(@ceil(r.x + r.w)))) - x;
        const h: i32 = @min(im.h, @as(i32, @intFromFloat(@ceil(r.y + r.h)))) - y;
        if (r.w < 1 or r.h < 1) {
            self.message("Drag a larger crop selection.");
            return;
        }
        if (x == 0 and y == 0 and w == im.w and h == im.h) {
            self.crop_mode = false;
            self.dirty = true;
            return;
        }
        self.replaceImage(edit.crop(im, x, y, w, h) catch {
            self.message("Could not crop this selection.");
            return;
        });
    }
    fn drawCrop(self: *const App, cr: *c.cairo_t) void {
        const im = self.image orelse return;
        const image = self.imageRect();
        const z = image.w / @as(f64, @floatFromInt(im.w));
        const r = Rect{ .x = image.x + self.crop_rect.x * z, .y = image.y + self.crop_rect.y * z, .w = self.crop_rect.w * z, .h = self.crop_rect.h * z };
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        const box = self.canvas();
        c.cairo_rectangle(cr, box.x, box.y, box.w, box.h);
        c.cairo_clip(cr);
        c.cairo_set_fill_rule(cr, c.CAIRO_FILL_RULE_EVEN_ODD);
        c.cairo_rectangle(cr, image.x, image.y, image.w, image.h);
        c.cairo_rectangle(cr, r.x, r.y, r.w, r.h);
        setSource(cr, ui_theme.global.image_crop_shade);
        c.cairo_fill(cr);
        setSource(cr, ui_theme.global.image_crop_border);
        c.cairo_set_line_width(cr, 1.5);
        c.cairo_rectangle(cr, r.x, r.y, r.w, r.h);
        c.cairo_stroke(cr);
        setSource(cr, ui_theme.global.image_crop_grid);
        c.cairo_set_line_width(cr, 1);
        for (1..3) |n| {
            const f = @as(f64, @floatFromInt(n)) / 3;
            c.cairo_move_to(cr, r.x + r.w * f, r.y);
            c.cairo_line_to(cr, r.x + r.w * f, r.y + r.h);
            c.cairo_move_to(cr, r.x, r.y + r.h * f);
            c.cairo_line_to(cr, r.x + r.w, r.y + r.h * f);
        }
        c.cairo_stroke(cr);
    }
    fn openSave(self: *App) void {
        if (self.image == null) return;
        self.cancelDrag();
        if (self.crop_mode) {
            self.applyCrop();
            if (self.crop_mode) return;
        }
        const path = self.paths[self.selected];
        const raw_base = std.fs.path.stem(path);
        var base_len = @min(raw_base.len, 230);
        while (base_len > 0 and base_len < raw_base.len and raw_base[base_len] & 0xc0 == 0x80) base_len -= 1;
        const base = if (std.unicode.utf8ValidateSlice(raw_base[0..base_len]) and std.mem.indexOfAny(u8, raw_base[0..base_len], "\r\n") == null) raw_base[0..base_len] else "image";
        const dir = std.fs.path.dirname(path) orelse ".";
        var buf: [4096]u8 = undefined;
        var name_buf: [1024]u8 = undefined;
        var suggested = false;
        for (0..10000) |n| {
            const name = if (n == 0) std.fmt.bufPrint(&name_buf, "{s}-edited.png", .{base}) catch "edited.png" else std.fmt.bufPrint(&name_buf, "{s}-edited-{d}.png", .{ base, n }) catch "edited.png";
            const dest = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch {
                self.message("The filename is too long.");
                return;
            };
            var st: c.struct_stat = undefined;
            if (c.lstat(dest, &st) == 0) continue;
            self.filename.set(a, name) catch {
                self.message("Not enough memory.");
                return;
            };
            self.filename.anchor = 0;
            self.filename.cursor = name.len - 4;
            suggested = true;
            break;
        }
        if (!suggested) {
            self.filename.set(a, "edited.png") catch {
                self.message("Not enough memory.");
                return;
            };
            self.filename.select_all = true;
        }
        self.dialog = .save;
        self.notice_len = 0;
        self.dirty = true;
    }
    fn deleteAction(self: *App, action: deletion.Action) void {
        switch (action) {
            .none => {},
            .cancel => {
                self.dialog = .none;
                self.deletion.deinit();
                self.notice_len = 0;
            },
            .toggle => self.deletion.permanent = !self.deletion.permanent,
            .confirm => self.confirmDialog(),
        }
        self.dirty = true;
    }

    fn confirmDialog(self: *App) void {
        switch (self.dialog) {
            .none => {},
            .discard => self.openSave(),
            .save => {
                const name = self.filename.text.items;
                if (name.len == 0 or !std.unicode.utf8ValidateSlice(name) or std.mem.indexOfScalar(u8, name, 0) != null) {
                    self.message("Enter a filename.");
                    return;
                }
                if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(name), ".png")) {
                    self.message("Use a .png filename to save a PNG copy.");
                    return;
                }
                if (!std.fs.path.isAbsolute(name)) @import("../files/ops.zig").validateFilename(name) catch {
                    self.message("Enter a filename or an absolute path.");
                    return;
                };
                const path = if (std.fs.path.isAbsolute(name)) a.dupeZ(u8, name) catch return else std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ std.fs.path.dirname(self.paths[self.selected]) orelse ".", name }, 0) catch return;
                defer a.free(path);
                self.operation = edit.Operation.start(.save, self.io, path, self.image, null) catch {
                    self.message("Could not start saving.");
                    return;
                };
                self.notice_len = 0;
                self.dirty = true;
            },
            .trash => {
                self.operation = edit.Operation.start(if (self.deletion.permanent) .delete else .trash, self.io, self.deletion.paths.items[0], null, self.trash_stamp) catch {
                    self.message("Could not start deleting this file.");
                    return;
                };
                self.notice_len = 0;
                self.dirty = true;
            },
        }
    }
    fn syncOperation(self: *App) void {
        const op = self.operation orelse return;
        if (!op.done.load(.acquire)) return;
        defer op.deinit();
        self.operation = null;
        self.dirty = true;
        if (op.err) |err| {
            if (err == error.FileChanged and op.kind != .save) {
                self.dialog = .none;
                self.deletion.deinit();
            }
            self.message(switch (err) {
                error.PathAlreadyExists => "That file already exists. Choose another name.",
                error.FileChanged => "The file changed. Please try again.",
                error.GioNotAvailable => "Trash is unavailable: install gio to use it.",
                else => if (op.kind == .save) "Could not save. Check the folder and permissions." else if (op.kind == .delete) "Could not delete. The file was kept." else "Could not move to Trash. The file was kept.",
            });
            return;
        }
        self.dialog = .none;
        if (op.kind != .save) self.deletion.deinit();
        if (op.kind == .save) {
            self.modified = false;
            self.setTitle();
            if (std.fmt.bufPrint(&self.notice, "Saved {s}", .{std.fs.path.basename(op.path)})) |saved_message| {
                self.notice_len = saved_message.len;
            } else |_| self.message("Saved PNG copy.");
            self.finishPending();
        } else {
            var pos = self.position();
            if (self.image) |im| im.deinit();
            self.image = null;
            if (self.original) |im| im.deinit();
            self.original = null;
            self.modified = false;
            // Command-line lists may contain the same pathname more than once.
            var i: usize = 0;
            while (i < self.order.items.len) {
                if (std.mem.eql(u8, self.paths[self.order.items[i]], op.path)) {
                    _ = self.order.orderedRemove(i);
                    if (i < pos) pos -= 1;
                } else i += 1;
            }
            if (self.count() == 0) {
                self.closed = true;
                return;
            }
            self.select(self.indexAt(@min(pos, self.count() - 1)));
            self.message("Moved to Trash.");
        }
    }
    fn dialogRect(self: *const App) Rect {
        const w = @min(560, @as(f64, @floatFromInt(self.w - 32)));
        const h: f64 = 204;
        return .{ .x = (@as(f64, @floatFromInt(self.w)) - w) / 2, .y = (@as(f64, @floatFromInt(self.h)) - h) / 2, .w = w, .h = h };
    }
    fn dialogButton(self: *const App, index: usize) Rect {
        const r = self.dialogRect();
        const n: f64 = if (self.dialog == .discard) 3 else 2;
        const w = (r.w - 40 - (n - 1) * 8) / n;
        return .{ .x = r.x + 20 + @as(f64, @floatFromInt(index)) * (w + 8), .y = r.y + r.h - 52, .w = w, .h = 32 };
    }
    fn filenameRect(self: *const App) Rect {
        const r = self.dialogRect();
        return .{ .x = r.x + 20, .y = r.y + 76, .w = r.w - 40, .h = 34 };
    }
    fn placeCaret(self: *App, extend: bool) void {
        const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 1, 1);
        defer c.cairo_surface_destroy(surface);
        const cr = c.cairo_create(surface) orelse return;
        defer c.cairo_destroy(cr);
        const target = self.px - self.filenameText().x + self.filename.scroll;
        const bytes = self.filename.text.items;
        var pos: usize = 0;
        while (pos < bytes.len) {
            const next = Editor.next(bytes, pos);
            if (target < (measureText(cr, bytes[0..pos], shell_ui.textSize(), false) + measureText(cr, bytes[0..next], shell_ui.textSize(), false)) / 2) break;
            pos = next;
        }
        self.filename.move(pos, extend);
    }
    /// Where the filename's text runs inside its field.
    fn filenameText(self: *const App) shell_ui.Rect {
        return ui_field.arrange(shellRect(self.filenameRect()), .{}, ui_theme.shellPalette()).text;
    }
    fn drawDialog(self: *App, cr: *c.cairo_t) void {
        if (self.dialog == .trash) {
            self.deletion.draw(cr, self.w, self.h, self.px, self.py, null);
            const note = if (self.operation != null) "Working…" else self.notice[0..self.notice_len];
            if (note.len > 0) {
                setSource(cr, ui_theme.global.window_fg);
                drawText(cr, note, 16, @floatFromInt(self.h - 8), shell_ui.statusSize(), false);
            }
            return;
        }
        setSource(cr, ui_theme.global.image_dialog_backdrop);
        c.cairo_paint(cr);
        const r = self.dialogRect();
        const t = ui_theme.shellPalette();
        // Frame, field and buttons are shell UI; the text goes on top.
        if (shell_ui.Layer.begin(cr, shellRect(r))) |begun| {
            var layer = begun;
            const lr = &layer.renderer;
            ui_dialog.paintFrame(lr, layer.local());
            if (self.dialog == .save) {
                const f = self.filenameRect();
                _ = ui_field.paintFrame(lr, .{ .x = @floatCast(f.x - r.x), .y = @floatCast(f.y - r.y), .w = @floatCast(f.w), .h = @floatCast(f.h) }, .{}, .{ .focused = true });
            }
            const n: usize = if (self.dialog == .discard) 3 else 2;
            for (0..n) |i| {
                const b = self.dialogButton(i);
                const label = if (i == 0) "Cancel" else if (self.dialog == .save or i == 2) "Save as…" else if (self.dialog == .trash) "Move to Trash" else "Discard";
                ui_button.paint(lr, .{ .x = @floatCast(b.x - r.x), .y = @floatCast(b.y - r.y), .w = @floatCast(b.w), .h = @floatCast(b.h) }, .{
                    .variant = if (i == 0) .secondary else .primary,
                    .label = label,
                }, .{ .pointer = if (b.contains(self.px, self.py)) .hover else .idle });
            }
            layer.finish();
        }
        setSource(cr, t.fg);
        const title = switch (self.dialog) {
            .save => "Save a PNG copy",
            .trash => "Move this image to Trash?",
            .discard => "Save your edits?",
            .none => "",
        };
        drawText(cr, title, r.x + 20, r.y + 30, shell_ui.textSize(), true);
        setSource(cr, t.fg);
        const description = switch (self.dialog) {
            .save => "Same folder, or enter an absolute path.",
            .trash => if (self.modified or self.hasCropSelection()) "Unsaved edits will be discarded." else "You can restore the file from Trash.",
            .discard => "This image has unsaved changes.",
            .none => "",
        };
        clippedText(cr, description, .{ .x = r.x + 20, .y = r.y + 42, .w = r.w - 40, .h = 25 }, shell_ui.textSize(), false);
        if (self.dialog == .save) {
            const area = self.filenameText();
            const field = self.filenameRect();
            c.cairo_save(cr);
            c.cairo_rectangle(cr, area.x, field.y, area.w, field.h);
            c.cairo_clip(cr);
            const bytes = self.filename.text.items;
            const caret = measureText(cr, bytes[0..self.filename.cursor], shell_ui.textSize(), false);
            self.filename.scroll = @max(0, @max(caret - area.w + 16, @min(self.filename.scroll, caret)));
            const x = area.x - self.filename.scroll;
            const m = shell_ui.fontMetrics(cr, shell_ui.textSize());
            const ink = m.ascent + m.descent;
            const top = field.y + (field.h - ink) / 2;
            const sel = self.filename.selection();
            if (sel[0] != sel[1]) {
                const start = measureText(cr, bytes[0..sel[0]], shell_ui.textSize(), false);
                const end = measureText(cr, bytes[0..sel[1]], shell_ui.textSize(), false);
                setSource(cr, t.selectionColor());
                c.cairo_rectangle(cr, x + start, top, end - start, ink);
                c.cairo_fill(cr);
            }
            setSource(cr, t.fg);
            drawText(cr, bytes, x, top + m.ascent, shell_ui.textSize(), false);
            setSource(cr, t.caretColor());
            c.cairo_rectangle(cr, x + caret, top, t.caret_width, ink);
            c.cairo_fill(cr);
            c.cairo_restore(cr);
        } else {
            setSource(cr, t.fg);
            clippedText(cr, std.fs.path.basename(self.paths[self.selected]), .{ .x = r.x + 20, .y = r.y + 76, .w = r.w - 40, .h = 30 }, shell_ui.textSize(), true);
        }
        const note = if (self.operation != null) "Working…" else self.notice[0..self.notice_len];
        setSource(cr, t.danger);
        clippedText(cr, note, .{ .x = r.x + 20, .y = r.y + 118, .w = r.w - 40, .h = 26 }, shell_ui.textSize(), false);
    }
    pub fn cursorName(self: *const App) [*:0]const u8 {
        if (self.operation != null) return "wait";
        if (self.dialog == .save and self.filenameRect().contains(self.px, self.py)) return "text";
        if (self.dialog != .none) return "default";
        if (self.crop_mode and self.canvas().contains(self.px, self.py)) return "crosshair";
        if (self.dragging or self.strip_drag.active) return "grabbing";
        if (self.canvas().contains(self.px, self.py) and !self.view.fitting) return "grab";
        return "default";
    }
    pub fn render(self: *App, cr: *c.cairo_t) void {
        const t = ui_theme.global;
        setSource(cr, t.app_toolbar);
        c.cairo_paint(cr);
        for (std.meta.tags(Action)) |act| {
            const r = self.buttonRect(act);
            const label = if (act == .crop and self.crop_mode) "Apply crop" else labels[@intFromEnum(act)];
            const opts: ui_button.Options = if (act == .crop and self.crop_mode)
                .{ .variant = .primary, .label = "Apply" }
            else if (self.w >= 1400)
                .{ .variant = .ghost, .leading_icon = glyph(act), .label = label }
            else if (act == .fit or act == .actual)
                .{ .variant = .ghost, .label = label }
            else
                .{ .variant = .ghost, .icon = glyph(act), .label = label };
            var layer = shell_ui.Layer.begin(cr, shellRect(r)) orelse continue;
            ui_button.paint(&layer.renderer, layer.local(), opts, .{
                .pointer = if (!self.enabled(act) or self.operation != null) .disabled else if (self.hover == act) .hover else .idle,
            });
            layer.finish();
        }
        const hint = if (self.operation) |op| (if (op.kind == .save) "Saving image…" else "Moving to Trash…") else if (self.hover) |act| (if (act == .crop and self.crop_mode) "Apply crop · Enter" else labels[@intFromEnum(act)]) else if (self.notice_len > 0) self.notice[0..self.notice_len] else if (self.crop_mode) "Drag to select · Enter: crop · Esc: cancel" else if (self.modified) "Unsaved edits · Ctrl+S: save · Ctrl+Z: undo" else "C: crop · Ctrl+S: save · Delete: trash";
        setSource(cr, t.window_fg);
        clippedText(cr, hint, .{ .x = 16, .y = self.toolbarBottom() + 2, .w = @floatFromInt(self.w - 32), .h = 22 }, shell_ui.statusSize(), false);
        const box = self.canvas();
        c.cairo_save(cr);
        rounded(cr, box, 8);
        c.cairo_clip(cr);
        setSource(cr, t.app_bg);
        c.cairo_paint(cr);
        if (self.image) |im| {
            const z = self.view.scale(box, @floatFromInt(im.w), @floatFromInt(im.h));
            const dims = self.view.dimensions(@floatFromInt(im.w), @floatFromInt(im.h));
            const cx = box.x + box.w / 2 + self.view.pan_x;
            const cy = box.y + box.h / 2 + self.view.pan_y;
            c.cairo_save(cr);
            c.cairo_rectangle(cr, cx - dims[0] * z / 2, cy - dims[1] * z / 2, dims[0] * z, dims[1] * z);
            c.cairo_clip(cr);
            checker(cr, box);
            c.cairo_restore(cr);
            c.cairo_translate(cr, cx, cy);
            c.cairo_rotate(cr, @as(f64, @floatFromInt(self.view.rotation)) * std.math.pi / 2.0);
            paintImage(cr, im, .{ .x = -@as(f64, @floatFromInt(im.w)) * z / 2, .y = -@as(f64, @floatFromInt(im.h)) * z / 2, .w = @as(f64, @floatFromInt(im.w)) * z, .h = @as(f64, @floatFromInt(im.h)) * z });
        } else {
            const msg = self.error_message orelse "Loading image…";
            setSource(cr, t.window_fg);
            drawText(cr, msg, box.x + @max(12, (box.w - measureText(cr, msg, shell_ui.textSize(), false)) / 2), box.y + box.h / 2, shell_ui.textSize(), false);
        }
        c.cairo_restore(cr);
        if (self.crop_mode) self.drawCrop(cr);
        for (0..self.thumbCount()) |slot| {
            const idx = self.indexAt(self.thumbStart() + slot);
            const r = self.thumbRect(slot);
            c.cairo_save(cr);
            rounded(cr, r, 7);
            c.cairo_clip(cr);
            setSource(cr, t.app_item);
            c.cairo_paint(cr);
            if (self.cached(idx)) {
                if (self.thumbImage(idx)) |im| {
                    const z = @min((r.w - 8) / @as(f64, @floatFromInt(im.w)), (r.h - 8) / @as(f64, @floatFromInt(im.h)));
                    const iw = @as(f64, @floatFromInt(im.w)) * z;
                    const ih = @as(f64, @floatFromInt(im.h)) * z;
                    paintImage(cr, im, .{ .x = r.x + (r.w - iw) / 2, .y = r.y + (r.h - ih) / 2, .w = iw, .h = ih });
                } else {
                    setSource(cr, t.window_fg);
                    drawText(cr, "?", r.x + r.w / 2 - 4, r.y + r.h / 2 + 5, 16, false);
                }
            }
            c.cairo_restore(cr);
            rounded(cr, r, 7);
            c.cairo_set_line_width(cr, 1);
            setSource(cr, t.app_item_border);
            c.cairo_stroke(cr);
        }
        const highlight = self.selection_glide.frame;
        if (highlight.alpha > 0 and self.count() > 0) {
            var r = self.thumbRect(0);
            r.x += @as(f64, highlight.col) * (r.w + 12);
            rounded(cr, r, 7);
            c.cairo_set_line_width(cr, 3);
            var color = ui_theme.shellPalette().accent;
            color[3] *= highlight.alpha;
            setSource(cr, color);
            c.cairo_stroke(cr);
        }
        if (self.stripBar()) |bar| shell_ui.drawScrollbar(cr, scrollbar.look(bar, self.strip_appearance, ui_theme.global.scrollbar_width, ui_theme.shellPalette()));
        var status: [160]u8 = undefined;
        const text = if (self.image) |im| std.fmt.bufPrint(&status, "{d} × {d}   ·   {d:.0}%   ·   {d} / {d}", .{ im.w, im.h, self.view.scale(box, @floatFromInt(im.w), @floatFromInt(im.h)) * @as(f64, @floatFromInt(self.scale)) * 100, self.position() + 1, self.count() }) catch "" else "Space / Esc to close  ·  Arrow keys to browse";
        setSource(cr, t.window_fg);
        drawText(cr, text, (@as(f64, @floatFromInt(self.w)) - measureText(cr, text, shell_ui.statusSize(), false)) / 2, @floatFromInt(self.h - 3), shell_ui.statusSize(), false);
        if (self.dialog != .none) self.drawDialog(cr);
    }
};
fn clippedText(cr: *c.cairo_t, str: []const u8, r: Rect, size: f64, bold: bool) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, r.x, r.y, r.w, r.h);
    c.cairo_clip(cr);
    drawText(cr, str, r.x, r.y + (r.h + size) / 2 - 2, size, bold);
}
fn rounded(cr: *c.cairo_t, r: Rect, radius: f64) void {
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, r.x + r.w - radius, r.y + radius, radius, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, r.x + r.w - radius, r.y + r.h - radius, radius, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, r.x + radius, r.y + r.h - radius, radius, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, r.x + radius, r.y + radius, radius, std.math.pi, std.math.pi * 1.5);
    c.cairo_close_path(cr);
}
fn paintImage(cr: *c.cairo_t, im: decoder.Image, r: Rect) void {
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
fn checker(cr: *c.cairo_t, r: Rect) void {
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
fn glyph(act: Action) IconId {
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

fn shellRect(r: Rect) shell_ui.Rect {
    return .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) };
}

fn setSource(cr: *c.cairo_t, color: [4]f32) void {
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
