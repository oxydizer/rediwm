const std = @import("std");
const c = @import("../files/c.zig").api;
const ui = @import("ui").cairo;
const theme = @import("ui").theme;
const scrollbar = @import("ui").widgets.scrollbar;
const button = @import("ui").widgets.button;
const field = @import("ui").widgets.field;
const dialog = @import("ui").widgets.dialog;
const menu = @import("ui").context_menu;
const p = @import("pango.zig");
const Document = @import("document.zig").Document;
const op = @import("operation.zig");
const a = std.heap.c_allocator;
const top: f64 = 40;
const status_h: f64 = 26;
const tab_w: f64 = 176;
const Action = enum { new, open, save, save_as, find, wrap };
const labels = [_][]const u8{ "New", "Open", "Save", "Save As", "Find", "Word Wrap" };
const Tab = struct {
    id: usize,
    doc: Document = .{},
    path: ?[:0]u8 = null,
    stamp: ?op.Stamp = null,
    scroll: f64 = 0,
    scroll_x: f64 = 0,
    layout: ?*p.Layout = null,
    layout_revision: usize = std.math.maxInt(usize),
    layout_width: i32 = 0,
    layout_scale: i32 = 0,
    height: i32 = 0,
    width: i32 = 0,
    fn deinit(t: *Tab) void {
        t.doc.deinit();
        if (t.path) |path| a.free(path);
        if (t.layout) |layout| p.g_object_unref(layout);
        a.destroy(t);
    }
    fn name(t: *Tab) []const u8 {
        return if (t.path) |path| std.fs.path.basename(path) else "Untitled";
    }
};
pub const App = struct {
    tabs: std.ArrayList(*Tab) = .empty,
    selected: usize = 0,
    next_id: usize = 1,
    first_tab: usize = 0,
    w: i32 = 900,
    h: i32 = 620,
    scale: i32 = 1,
    dirty: bool = true,
    title_changed: bool = true,
    closed: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    focused: bool = false,
    caret_visible: bool = true,
    caret_dirty: bool = false,
    caret_activity: usize = 0,
    menu_open: bool = false,
    menu_selected: ?usize = null,
    menu_anchor: f64 = 0,
    has_titlebar: bool = true,
    dragging: bool = false,
    scroll_drag: scrollbar.Drag = .{},
    bar_appearance: scrollbar.Appearance = .{},
    /// The scroll position and tab the scrollbar last saw: only a scroll within
    /// the same tab shows feedback, not switching to a tab scrolled elsewhere.
    bar_observed: f64 = 0,
    bar_tab: ?*Tab = null,
    px: f64 = 0,
    py: f64 = 0,
    wrap: bool = true,
    io: std.Io,
    operation: ?*op.Operation = null,
    queue: std.ArrayList([:0]u8) = .empty,
    close_tab: ?usize = null,
    close_all: bool = false,
    close_choice: usize = 2,
    notice: [512]u8 = @splat(0),
    notice_len: usize = 0,
    title: [1024:0]u8 = @splat(0),
    find_open: bool = false,
    query: @import("../files/editor.zig").Editor = .{},
    clipboard: std.ArrayList(u8) = .empty,
    clipboard_revision: usize = 0,
    paste_requested: bool = false,
    preedit: std.ArrayList(u8) = .empty,

    pub fn init(io: std.Io) !App {
        var self: App = .{ .io = io };
        try self.newTab();
        return self;
    }
    pub fn deinit(self: *App) void {
        if (self.operation) |job| job.deinit();
        for (self.tabs.items) |t| t.deinit();
        self.tabs.deinit(a);
        for (self.queue.items) |path| a.free(path);
        self.queue.deinit(a);
        self.query.deinit(a);
        self.clipboard.deinit(a);
        self.preedit.deinit(a);
    }
    fn current(self: *App) *Tab {
        return self.tabs.items[self.selected];
    }
    pub fn tabId(self: *App) usize {
        return self.current().id;
    }
    pub fn editRevision(self: *App) usize {
        return self.current().doc.revision;
    }
    pub fn document(self: *App) *Document {
        return &self.current().doc;
    }
    fn findTab(self: *App, id: usize) ?usize {
        for (self.tabs.items, 0..) |t, i| if (t.id == id) return i;
        return null;
    }
    pub fn newTab(self: *App) !void {
        if (self.close_tab != null) return;
        const t = try a.create(Tab);
        errdefer a.destroy(t);
        t.* = .{ .id = self.next_id };
        self.next_id += 1;
        try self.tabs.append(a, t);
        self.selected = self.tabs.items.len - 1;
        self.changed();
    }
    fn changed(self: *App) void {
        self.dirty = true;
        if (self.tabs.items.len == 0) return;
        const t = self.current();
        const name = if (std.unicode.utf8ValidateSlice(t.name())) t.name() else "Text file";
        var title: [1024:0]u8 = undefined;
        const value = std.fmt.bufPrintZ(&title, "{s}{s} — Text Editor ({d}/{d})", .{ if (t.doc.modified()) "* " else "", name, self.selected + 1, self.tabs.items.len }) catch "Text Editor";
        // Resizing and moving the caret do not change the window title. Avoid
        // sending a redundant set_title alongside every resize buffer commit.
        if (!std.mem.eql(u8, std.mem.span(self.getTitle()), value)) {
            @memcpy(self.title[0..value.len], value);
            self.title[value.len] = 0;
            self.title_changed = true;
        }
        const visible: usize = @intFromFloat(@max(1, @floor((self.tabRight() - 2) / tab_w)));
        if (self.selected < self.first_tab) self.first_tab = self.selected;
        if (self.selected >= self.first_tab + visible) self.first_tab = self.selected - visible + 1;
    }
    pub const CaretState = struct {
        active: bool,
        tab: usize,
        revision: usize,
        cursor: usize,
        anchor: usize,
        find: bool,
        query_hash: u64,
        activity: usize,
    };
    pub fn caretState(self: *App) CaretState {
        const d = self.document();
        const r = self.inputRectangle();
        const in_view = @as(f64, @floatFromInt(r.y + r.height)) > self.viewTop() and @as(f64, @floatFromInt(r.y)) < self.viewTop() + self.viewHeight();
        return .{
            .active = self.focused and !self.menu_open and self.close_tab == null and self.preedit.items.len == 0 and (self.find_open or (d.cursor == d.anchor and in_view)),
            .tab = self.tabId(),
            .revision = d.revision,
            .cursor = if (self.find_open) self.query.cursor else d.cursor,
            .anchor = if (self.find_open) self.query.anchor else d.anchor,
            .find = self.find_open,
            .activity = self.caret_activity,
            .query_hash = if (self.find_open) std.hash.Wyhash.hash(0, self.query.text.items) else 0,
        };
    }
    pub fn caretDamage(self: *App) p.Rectangle {
        if (self.find_open) return .{ .x = 12, .y = 43, .width = self.w - 24, .height = 30 };
        var r = self.inputRectangle();
        r.x -= 1;
        r.y -= 1;
        r.width += 3;
        r.height += 2;
        return r;
    }
    pub fn getTitle(self: *App) [*:0]const u8 {
        return &self.title;
    }
    pub fn message(self: *App, value: []const u8) void {
        self.notice_len = @min(value.len, self.notice.len);
        @memcpy(self.notice[0..self.notice_len], value[0..self.notice_len]);
        self.dirty = true;
    }
    fn failure(self: *App, err: anyerror) void {
        self.message(switch (err) {
            error.FileChanged => "File changed on disk. Use Save As to keep your edits in another file.",
            error.BinaryFile => "This file contains binary data and cannot be edited as text.",
            error.UnsupportedEncoding => "This file is not valid UTF-8 text.",
            error.FileTooLarge => "Text files are limited to 16 MiB.",
            error.PermissionDenied => "Permission denied. Try Save As in a writable folder.",
            error.HardLinkedFile => "This file has multiple hard links. Use Save As to create a separate copy.",
            else => @errorName(err),
        });
    }
    pub fn open(self: *App, path: []const u8) void {
        if (self.close_tab == null) for (self.tabs.items, 0..) |t, i| {
            if (t.path != null and std.mem.eql(u8, t.path.?, path)) {
                self.selected = i;
                self.changed();
                return;
            }
        };
        const owned = a.dupeZ(u8, path) catch return;
        self.queue.append(a, owned) catch {
            a.free(owned);
            return;
        };
    }
    pub fn sync(self: *App) void {
        if (self.operation) |job| {
            if (!job.done.load(.acquire)) return;
            self.operation = null;
            defer job.deinit();
            self.dirty = true;
            if (job.err) |err| {
                self.close_all = false;
                self.failure(err);
                return;
            }
            if (job.cancelled) {
                self.close_all = false;
                return;
            }
            switch (job.kind) {
                .load => {
                    for (self.tabs.items, 0..) |t, i| if (t.path != null and std.mem.eql(u8, t.path.?, job.path)) {
                        self.selected = i;
                        self.changed();
                        return;
                    };
                    if (self.current().path != null or self.current().doc.text.items.len > 0 or self.current().doc.modified()) self.newTab() catch return;
                    const t = self.current();
                    const path = a.dupeZ(u8, job.path) catch return;
                    t.doc.deinit();
                    t.doc = job.document.?;
                    job.document = null;
                    t.path = path;
                    t.stamp = job.stamp;
                    t.layout_revision = std.math.maxInt(usize);
                    self.notice_len = 0;
                    self.changed();
                },
                .save => if (self.findTab(job.tab_id)) |i| {
                    const t = self.tabs.items[i];
                    const path = a.dupeZ(u8, job.path) catch return;
                    if (t.path) |old| a.free(old);
                    t.path = path;
                    t.stamp = job.stamp;
                    if (t.doc.revision == job.revision) t.doc.saved = t.doc.position;
                    self.message("Saved");
                    self.changed();
                    if (self.close_tab == t.id and !t.doc.modified()) self.finishClose();
                },
                .open_dialog => self.open(job.path),
                .save_dialog => if (self.findTab(job.tab_id)) |i| {
                    for (self.tabs.items) |other| if (other.id != job.tab_id and other.path != null and std.mem.eql(u8, other.path.?, job.path)) {
                        self.message("That file is open in another tab. Choose a different name.");
                        return;
                    };
                    self.startSave(self.tabs.items[i], job.path, job.stamp);
                },
            }
        }
        if (self.operation == null and self.queue.items.len > 0 and self.close_tab == null) {
            const path = self.queue.orderedRemove(0);
            defer a.free(path);
            self.operation = op.Operation.start(.load, self.io, 0, path, "", null) catch |err| {
                self.failure(err);
                return;
            };
            self.message("Opening…");
        }
    }
    fn choose(self: *App, saving: bool) void {
        if (self.operation != null) return;
        const t = self.current();
        self.operation = op.Operation.start(if (saving) .save_dialog else .open_dialog, self.io, t.id, t.path orelse "", "", null) catch |err| {
            self.failure(err);
            return;
        };
    }
    fn startSave(self: *App, t: *Tab, path: []const u8, stamp: ?op.Stamp) void {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(a);
        if (t.doc.bom) bytes.appendSlice(a, "\xef\xbb\xbf") catch return;
        bytes.appendSlice(a, t.doc.text.items) catch return;
        self.operation = op.Operation.start(.save, self.io, t.id, path, bytes.items, stamp) catch |err| {
            self.failure(err);
            return;
        };
        self.operation.?.revision = t.doc.revision;
        self.message("Saving…");
    }
    fn save(self: *App, as: bool) void {
        if (self.operation != null) return;
        const t = self.current();
        if (as or t.path == null) self.choose(true) else self.startSave(t, t.path.?, t.stamp);
    }
    pub fn requestClose(self: *App) void {
        if (self.operation != null) {
            self.message("Finish the file dialog or operation before closing.");
            return;
        }
        self.close_all = true;
        self.closeSelected();
    }
    fn closeSelected(self: *App) void {
        if (self.operation != null) return;
        self.close_tab = self.current().id;
        self.close_choice = 2;
        if (!self.current().doc.modified()) self.finishClose() else self.dirty = true;
    }
    fn finishClose(self: *App) void {
        const id = self.close_tab orelse return;
        self.close_tab = null;
        const idx = self.findTab(id) orelse return;
        self.tabs.orderedRemove(idx).deinit();
        if (self.tabs.items.len == 0) {
            self.closed = true;
            return;
        }
        self.selected = @min(idx, self.tabs.items.len - 1);
        self.changed();
        if (self.close_all) self.closeSelected();
    }
    fn act(self: *App, action: Action) void {
        switch (action) {
            .new => self.newTab() catch |err| self.failure(err),
            .open => self.choose(false),
            .save => self.save(false),
            .save_as => self.save(true),
            .find => {
                self.find_open = !self.find_open;
                self.query.select_all = true;
            },
            .wrap => {
                self.wrap = !self.wrap;
                self.current().scroll_x = 0;
            },
        }
        self.dirty = true;
    }
    pub fn resize(self: *App, w: i32, h: i32) void {
        self.w = w;
        self.h = h;
        self.menu_open = false;
        self.changed();
    }
    fn viewTop(self: *App) f64 {
        return top + if (self.find_open) @as(f64, 40) else 0;
    }
    fn viewHeight(self: *App) f64 {
        return @max(1, @as(f64, @floatFromInt(self.h)) - self.viewTop() - status_h - 8);
    }
    pub fn cancelDrag(self: *App) void {
        self.dragging = false;
        self.scroll_drag.end();
    }
    pub fn cursorName(self: *App) [*:0]const u8 {
        return if (!self.menu_open and self.py >= self.viewTop() and self.py < @as(f64, @floatFromInt(self.h)) - status_h and self.px < @as(f64, @floatFromInt(self.w)) - 16) "text" else "default";
    }
    /// The current tab's bar, along the right edge of the text view; null
    /// while the document fits.
    fn scrollbarGeometry(self: *App) ?scrollbar.Geometry {
        if (self.tabs.items.len == 0) return null;
        const tab = self.current();
        const strip = scrollbar.gutter(theme.global.scrollbar_width);
        const track: scrollbar.Rect = .{ .x = @as(f32, @floatFromInt(self.w)) - strip, .y = @floatCast(self.viewTop()), .w = strip, .h = @floatCast(self.viewHeight()) };
        return scrollbar.Geometry.compute(.vertical, track, track.h, @floatFromInt(tab.height), @floatCast(tab.scroll));
    }

    /// Advances the scrollbar's hover and scroll feedback.
    pub fn stepBar(self: *App, now: i64) void {
        if (self.tabs.items.len == 0) return;
        const tab = self.current();
        const bar = self.scrollbarGeometry();
        if (self.bar_tab != tab) {
            self.bar_tab = tab;
            self.bar_observed = tab.scroll;
        }
        const hovered = !self.menu_open and self.close_tab == null and if (bar) |b| b.overThumb(@floatCast(self.px), @floatCast(self.py)) else false;
        if (self.bar_appearance.step(now, tab.scroll != self.bar_observed, hovered, self.scroll_drag.active, bar != null)) self.dirty = true;
        self.bar_observed = tab.scroll;
    }

    /// How long the event loop may sleep before the scrollbar needs a frame.
    pub fn barTimeout(self: *const App, now: i64) ?u32 {
        if (self.bar_appearance.active) return 16;
        if (self.bar_appearance.deadline) |deadline| return @intCast(std.math.clamp(deadline - now, 0, 60_000));
        return null;
    }

    fn clampScroll(self: *App) void {
        const t = self.current();
        t.scroll = std.math.clamp(t.scroll, 0, @max(0, @as(f64, @floatFromInt(t.height)) - self.viewHeight()));
    }
    pub fn handleScroll(self: *App, amount: f64) void {
        if (self.close_tab != null or self.menu_open) return;
        if (self.py >= 0 and self.py < top) {
            if (amount > 0) self.first_tab = @min(self.tabs.items.len - 1, self.first_tab + 1) else self.first_tab -|= 1;
        } else if (self.shift and !self.wrap) {
            self.current().scroll_x = @max(0, self.current().scroll_x + amount * 3);
        } else {
            self.current().scroll += amount * 3;
            self.clampScroll();
        }
        self.dirty = true;
    }
    fn layout(self: *App, cr: *c.cairo_t) void {
        const t = self.current();
        if (t.layout == null) t.layout = p.pango_cairo_create_layout(cr) orelse return;
        const width: i32 = if (self.wrap) @max(1, self.w - 40) * 1024 else -1;
        if (t.layout_revision != t.doc.revision or t.layout_width != width or t.layout_scale != self.scale) {
            const family = a.dupeZ(u8, theme.global.mono_font) catch return;
            defer a.free(family);
            const font = p.pango_font_description_from_string(family) orelse return;
            defer p.pango_font_description_free(font);
            p.pango_font_description_set_absolute_size(font, ui.textSize() * 1024);
            p.pango_layout_set_font_description(t.layout.?, font);
            p.pango_layout_set_text(t.layout.?, t.doc.text.items.ptr, @intCast(t.doc.text.items.len));
            p.pango_layout_set_width(t.layout.?, width);
            p.pango_layout_set_wrap(t.layout.?, 2);
            p.pango_cairo_update_layout(cr, t.layout.?);
            p.pango_layout_get_pixel_size(t.layout.?, &t.width, &t.height);
            t.layout_revision = t.doc.revision;
            t.layout_width = width;
            t.layout_scale = self.scale;
            self.clampScroll();
        }
    }
    fn ensureLayout(self: *App) void {
        const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 1, 1);
        defer c.cairo_surface_destroy(surface);
        const cr = c.cairo_create(surface);
        defer c.cairo_destroy(cr);
        c.cairo_scale(cr, @floatFromInt(self.scale), @floatFromInt(self.scale));
        self.layout(cr.?);
    }
    pub fn caretRect(self: *App) p.Rectangle {
        self.ensureLayout();
        var r: p.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 18 * 1024 };
        if (self.current().layout) |l| p.pango_layout_get_cursor_pos(l, @intCast(self.document().cursor), &r, null);
        return r;
    }
    pub fn inputRectangle(self: *App) p.Rectangle {
        const r = self.caretRect();
        return .{ .x = @intFromFloat(@as(f64, @floatFromInt(r.x)) / 1024 + 16 - self.current().scroll_x), .y = @intFromFloat(@as(f64, @floatFromInt(r.y)) / 1024 + self.viewTop() - self.current().scroll), .width = 2, .height = @max(1, @divTrunc(r.height, 1024)) };
    }
    fn reveal(self: *App) void {
        const r = self.caretRect();
        const t = self.current();
        const y = @as(f64, @floatFromInt(r.y)) / 1024;
        const h = @as(f64, @floatFromInt(r.height)) / 1024;
        t.scroll = @max(0, @min(t.scroll, y));
        t.scroll = @max(t.scroll, y + h - self.viewHeight());
        self.clampScroll();
        if (!self.wrap) {
            const x = @as(f64, @floatFromInt(r.x)) / 1024;
            t.scroll_x = @max(0, @max(x - @as(f64, @floatFromInt(self.w)) + 48, @min(t.scroll_x, x)));
        }
        self.changed();
    }
    fn indexAt(self: *App, x: f64, y: f64) usize {
        self.ensureLayout();
        const t = self.current();
        const l = t.layout orelse return 0;
        var idx: c_int = 0;
        var trailing: c_int = 0;
        _ = p.pango_layout_xy_to_index(l, @intFromFloat(std.math.clamp(x * 1024, -1e9, 1e9)), @intFromFloat(std.math.clamp(y * 1024, -1e9, 1e9)), &idx, &trailing);
        var offset: usize = @intCast(@max(0, idx));
        while (trailing > 0 and offset < t.doc.text.items.len) : (trailing -= 1) offset += std.unicode.utf8ByteSequenceLength(t.doc.text.items[offset]) catch 1;
        return @min(offset, t.doc.text.items.len);
    }
    pub fn handleMotion(self: *App, x: f64, y: f64) void {
        const changed_hover = ((self.py < top or y < top) and @divFloor(self.px, 76) != @divFloor(x, 76)) or (self.py < top) != (y < top);
        self.px = x;
        self.py = y;
        if (self.menu_open) {
            const hovered = self.menuHit(x, y);
            if (hovered != self.menu_selected) {
                self.menu_selected = hovered;
                self.dirty = true;
            }
            return;
        }
        if (self.dragging) {
            const t = self.current();
            if (y < self.viewTop()) t.scroll -= 18 else if (y > self.viewTop() + self.viewHeight()) t.scroll += 18;
            self.clampScroll();
            t.doc.move(self.indexAt(x - 16 + t.scroll_x, y - self.viewTop() + t.scroll), true);
            self.changed();
        }
        if (self.scroll_drag.active) {
            if (self.scrollbarGeometry()) |bar| {
                self.current().scroll = self.scroll_drag.offsetAt(bar, @floatCast(x), @floatCast(y));
                self.clampScroll();
            }
            self.dirty = true;
        }
        if (changed_hover) self.dirty = true;
    }
    pub fn handleButton(self: *App, code: u32, pressed: bool) void {
        if (code != 0x110) return;
        if (pressed) self.caret_activity +%= 1;
        if (!pressed) {
            self.cancelDrag();
            return;
        }
        if (self.close_tab != null) {
            const x = (@as(f64, @floatFromInt(self.w)) - 420) / 2;
            const y = (@as(f64, @floatFromInt(self.h)) - 170) / 2;
            if (self.py >= y + 112 and self.py <= y + 150 and self.operation == null) {
                if (self.px >= x + 20 and self.px < x + 135) {
                    self.close_tab = null;
                    self.close_all = false;
                } else if (self.px >= x + 145 and self.px < x + 270) self.finishClose() else if (self.px >= x + 280 and self.px < x + 400) self.save(false);
                self.dirty = true;
            }
            return;
        }
        if (self.menu_open) {
            const row = self.menuHit(self.px, self.py);
            self.dismissMenu();
            if (row) |i| self.act(@enumFromInt(i));
            return;
        }
        if (self.py < 0) return;
        if (self.py < top) {
            if (!self.has_titlebar and self.px >= @as(f64, @floatFromInt(self.w)) - 34) {
                self.toggleMenu(@as(f64, @floatFromInt(self.w)) - 8);
                return;
            }
            if (self.px >= self.tabRight()) {
                self.act(.new);
                return;
            }
            const i = self.first_tab + @as(usize, @intFromFloat(@max(0, self.px) / tab_w));
            if (i < self.tabs.items.len) {
                self.selected = i;
                self.changed();
                if (@mod(self.px, tab_w) > tab_w - 28) self.closeSelected();
            }
        } else if (self.find_open and self.py < self.viewTop()) {
            if (self.px > @as(f64, @floatFromInt(self.w)) - 90) self.findNext(self.shift);
        } else if (self.py < @as(f64, @floatFromInt(self.h)) - status_h) {
            if (self.px > @as(f64, @floatFromInt(self.w)) - scrollbar.gutter(theme.global.scrollbar_width)) {
                if (self.scrollbarGeometry()) |bar| {
                    const scroll: f32 = @floatCast(self.current().scroll);
                    if (scrollbar.press(bar, @floatCast(self.px), @floatCast(self.py), scroll)) |action| {
                        switch (action) {
                            .grab => self.scroll_drag.begin(bar, @floatCast(self.px), @floatCast(self.py), scroll),
                            .page => |offset| {
                                self.current().scroll = offset;
                                self.clampScroll();
                            },
                        }
                        self.dirty = true;
                    }
                }
                return;
            }
            self.find_open = false;
            const t = self.current();
            t.doc.move(self.indexAt(self.px - 16 + t.scroll_x, self.py - self.viewTop() + t.scroll), self.shift);
            self.dragging = true;
            self.changed();
        }
    }
    pub fn pasteText(self: *App, bytes: []const u8) void {
        self.caret_activity +%= 1;
        if (self.close_tab != null or self.menu_open) return;
        if (self.find_open) {
            self.query.insert(a, bytes) catch |err| self.failure(err);
            self.dirty = true;
            return;
        }
        self.document().insert(bytes) catch |err| {
            self.failure(err);
            return;
        };
        self.notice_len = 0;
        self.reveal();
    }
    fn findNext(self: *App, backwards: bool) void {
        const q = self.query.text.items;
        if (q.len == 0) return;
        const d = self.document();
        const sel = d.selection();
        const found = if (backwards) std.mem.lastIndexOf(u8, d.text.items[0..sel[0]], q) orelse std.mem.lastIndexOf(u8, d.text.items, q) else std.mem.indexOfPos(u8, d.text.items, sel[1], q) orelse std.mem.indexOf(u8, d.text.items, q);
        if (found) |pos| {
            d.anchor = pos;
            d.cursor = pos + q.len;
            self.reveal();
        } else self.message("Text not found");
    }
    pub fn keyRepeats(self: *App, sym: u32, utf8: []const u8) bool {
        if (self.close_tab != null or self.menu_open or self.ctrl or self.alt) return false;
        return @import("ui").key_repeat.editingKey(switch (sym) {
            c.XKB_KEY_Left, c.XKB_KEY_Right, c.XKB_KEY_Up, c.XKB_KEY_Down, c.XKB_KEY_BackSpace, c.XKB_KEY_Delete => true,
            else => false,
        }, utf8);
    }
    pub fn handleKey(self: *App, sym: u32, utf8: []const u8) void {
        self.caret_activity +%= 1;
        if (self.close_tab != null) {
            if (sym == c.XKB_KEY_Escape and self.operation == null) {
                self.close_tab = null;
                self.close_all = false;
                self.dirty = true;
            }
            if (self.operation == null) {
                if (sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab or sym == c.XKB_KEY_Left or sym == c.XKB_KEY_Right) {
                    self.close_choice = (self.close_choice + @as(usize, if (self.shift or sym == c.XKB_KEY_Left) 2 else 1)) % 3;
                    self.dirty = true;
                }
                if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_space) switch (self.close_choice) {
                    0 => {
                        self.close_tab = null;
                        self.close_all = false;
                        self.dirty = true;
                    },
                    1 => self.finishClose(),
                    else => self.save(false),
                };
            }
            return;
        }
        if (sym == c.XKB_KEY_F10 and !self.ctrl and !self.alt) {
            self.toggleMenu(self.menu_anchor);
            return;
        }
        if (self.menu_open) {
            switch (sym) {
                c.XKB_KEY_Escape => self.dismissMenu(),
                c.XKB_KEY_Down => self.menu_selected = if (self.menu_selected) |i| (i + 1) % labels.len else 0,
                c.XKB_KEY_Up => self.menu_selected = if (self.menu_selected) |i| (i + labels.len - 1) % labels.len else labels.len - 1,
                c.XKB_KEY_Home => self.menu_selected = 0,
                c.XKB_KEY_End => self.menu_selected = labels.len - 1,
                c.XKB_KEY_Return, c.XKB_KEY_KP_Enter, c.XKB_KEY_space => if (self.menu_selected) |i| {
                    self.dismissMenu();
                    self.act(@enumFromInt(i));
                },
                else => {},
            }
            self.dirty = true;
            if (!self.ctrl) return;
            self.dismissMenu();
        }
        if (self.ctrl) switch (sym) {
            c.XKB_KEY_n, c.XKB_KEY_N, c.XKB_KEY_t, c.XKB_KEY_T => {
                self.act(.new);
                return;
            },
            c.XKB_KEY_o, c.XKB_KEY_O => {
                self.act(.open);
                return;
            },
            c.XKB_KEY_s, c.XKB_KEY_S => {
                self.save(self.shift);
                return;
            },
            c.XKB_KEY_w, c.XKB_KEY_W => {
                self.closeSelected();
                return;
            },
            c.XKB_KEY_q, c.XKB_KEY_Q => {
                self.requestClose();
                return;
            },
            c.XKB_KEY_f, c.XKB_KEY_F => {
                self.find_open = true;
                self.query.select_all = true;
                self.dirty = true;
                return;
            },
            c.XKB_KEY_Tab, c.XKB_KEY_ISO_Left_Tab, c.XKB_KEY_Page_Up, c.XKB_KEY_Page_Down => {
                self.selected = if (self.shift or sym == c.XKB_KEY_Page_Up) (self.selected + self.tabs.items.len - 1) % self.tabs.items.len else (self.selected + 1) % self.tabs.items.len;
                self.changed();
                return;
            },
            else => {},
        };
        if (sym == c.XKB_KEY_Escape) {
            self.find_open = false;
            self.notice_len = 0;
            self.dirty = true;
            return;
        }
        if (self.find_open) {
            if (sym == c.XKB_KEY_Return) self.findNext(self.shift) else if (self.ctrl and (sym == c.XKB_KEY_v or sym == c.XKB_KEY_V)) self.paste_requested = true else self.query.key(a, sym, utf8, self.ctrl, self.shift, self.alt);
            self.dirty = true;
            return;
        }
        const d = self.document();
        const sel = d.selection();
        if (self.ctrl) switch (sym) {
            c.XKB_KEY_a, c.XKB_KEY_A => {
                d.anchor = 0;
                d.cursor = d.text.items.len;
                self.reveal();
                return;
            },
            c.XKB_KEY_c, c.XKB_KEY_C, c.XKB_KEY_x, c.XKB_KEY_X => {
                if (sel[0] == sel[1]) return;
                if (sel[1] - sel[0] > @import("../files/transfer.zig").limit) {
                    self.message("Clipboard selections are limited to 1 MiB.");
                    return;
                }
                self.clipboard.clearRetainingCapacity();
                self.clipboard.appendSlice(a, d.text.items[sel[0]..sel[1]]) catch return;
                self.clipboard_revision += 1;
                if (sym == c.XKB_KEY_x or sym == c.XKB_KEY_X) {
                    d.insert("") catch |err| self.failure(err);
                    self.reveal();
                }
                return;
            },
            c.XKB_KEY_v, c.XKB_KEY_V => {
                self.paste_requested = true;
                return;
            },
            c.XKB_KEY_z, c.XKB_KEY_Z, c.XKB_KEY_y, c.XKB_KEY_Y => {
                d.undo(self.shift or sym == c.XKB_KEY_y or sym == c.XKB_KEY_Y) catch |err| self.failure(err);
                self.reveal();
                return;
            },
            else => {},
        };
        switch (sym) {
            c.XKB_KEY_Left, c.XKB_KEY_Right => {
                const right = sym == c.XKB_KEY_Right;
                d.move(if (!self.shift and !self.ctrl and sel[0] != sel[1]) (if (right) sel[1] else sel[0]) else d.boundary(right, self.ctrl), self.shift);
            },
            c.XKB_KEY_Home => d.move(if (self.ctrl) 0 else d.lineStart(d.cursor), self.shift),
            c.XKB_KEY_End => d.move(if (self.ctrl) d.text.items.len else d.lineEnd(d.cursor), self.shift),
            c.XKB_KEY_Up, c.XKB_KEY_Down, c.XKB_KEY_Page_Up, c.XKB_KEY_Page_Down => {
                const r = self.caretRect();
                const down = sym == c.XKB_KEY_Down or sym == c.XKB_KEY_Page_Down;
                const distance = if (sym == c.XKB_KEY_Page_Up or sym == c.XKB_KEY_Page_Down) self.viewHeight() else @as(f64, @floatFromInt(r.height)) / 1024;
                d.move(self.indexAt(@as(f64, @floatFromInt(r.x)) / 1024, @as(f64, @floatFromInt(r.y)) / 1024 + @as(f64, @floatFromInt(r.height)) / 2048 + (if (down) distance else -distance)), self.shift);
            },
            c.XKB_KEY_BackSpace, c.XKB_KEY_Delete => {
                if (sel[0] == sel[1]) d.anchor = d.boundary(sym == c.XKB_KEY_Delete, self.ctrl);
                d.insert("") catch |err| self.failure(err);
            },
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => {
                if (!self.ctrl and !self.alt) d.insert(if (d.crlf) "\r\n" else "\n") catch |err| self.failure(err);
            },
            c.XKB_KEY_Tab => {
                if (!self.ctrl and !self.alt) d.insert("\t") catch |err| self.failure(err);
            },
            c.XKB_KEY_F3 => self.findNext(self.shift),
            else => {
                if (!self.ctrl and !self.alt and utf8.len > 0 and utf8[0] >= 32) d.insert(utf8) catch |err| self.failure(err);
            },
        }
        self.reveal();
    }
    fn tabRight(self: *const App) f64 {
        return @as(f64, @floatFromInt(self.w)) - @as(f64, if (self.has_titlebar) 34 else 70);
    }
    pub fn dismissMenu(self: *App) void {
        if (!self.menu_open) return;
        self.menu_open = false;
        self.dirty = true;
    }
    pub fn toggleMenu(self: *App, anchor: f64) void {
        if (self.close_tab != null) return;
        self.cancelDrag();
        self.menu_anchor = anchor;
        self.menu_open = !self.menu_open;
        self.menu_selected = null;
        self.dirty = true;
    }
    fn menuBox(self: *const App) menu.Rect {
        const height = labels.len * menu.row_height + 2 * menu.padding + 2 * menu.separator_space;
        return .{
            .x = std.math.clamp(self.menu_anchor - menu.width, 6, @max(6, @as(f64, @floatFromInt(self.w)) - menu.width - 6)),
            .y = @min(if (self.has_titlebar) @as(f64, 6) else top + 4, @max(6, @as(f64, @floatFromInt(self.h)) - height - 6)),
            .w = menu.width,
            .h = height,
        };
    }
    fn menuRow(self: *const App, i: usize) menu.Rect {
        const box = self.menuBox();
        const separators: usize = @as(usize, if (i >= 2) 1 else 0) + @as(usize, if (i >= 4) 1 else 0);
        return .{ .x = box.x + menu.padding, .y = box.y + @as(f64, @floatFromInt(menu.padding + i * menu.row_height + separators * menu.separator_space)), .w = box.w - 2 * menu.padding, .h = menu.row_height };
    }
    fn menuHit(self: *const App, x: f64, y: f64) ?usize {
        for (0..labels.len) |i| if (self.menuRow(i).contains(x, y)) return i;
        return null;
    }
    fn paintMenu(self: *App, cr: *c.cairo_t) void {
        menu.frame(cr, self.menuBox(), true);
        const IconId = @import("ui").layout.IconId;
        const icons = [_]?IconId{ .plus, .open, .save, .save, .search, if (self.wrap) .checkmark else null };
        const hints = [_]?[]const u8{ "CTRL+N", "CTRL+O", "CTRL+S", "CTRL+SHIFT+S", "CTRL+F", null };
        for (labels, 0..) |label, i| menu.row(cr, self.menuRow(i), .{
            .label = label,
            .hint = hints[i],
            .icon = icons[i],
            .selected = self.menu_selected == i,
            .separator = i == 2 or i == 4,
        }, true);
    }
    fn paintButton(self: *App, cr: *c.cairo_t, r: field.Rect, label: []const u8, selected: bool) void {
        var layer = ui.Layer.begin(cr, r) orelse return;
        defer layer.finish();
        layer.renderer.palette = theme.shellPalette();
        button.paint(&layer.renderer, layer.local(), .{ .label = label, .variant = .ghost, .size = .sm }, .{ .selected = selected, .pointer = if (self.px >= r.x and self.px < r.x + r.w and self.py >= r.y and self.py < r.y + r.h) .hover else .idle });
    }
    pub fn render(self: *App, cr: *c.cairo_t) void {
        const t = theme.global;
        fill(cr, 0, 0, @floatFromInt(self.w), @floatFromInt(self.h), t.app_bg);
        fill(cr, 0, 0, @floatFromInt(self.w), 38, t.app_bar);
        var i = self.first_tab;
        while (i < self.tabs.items.len) : (i += 1) {
            const x = @as(f64, @floatFromInt(i - self.first_tab)) * tab_w;
            if (x + tab_w > self.tabRight()) break;
            const tab = self.tabs.items[i];
            if (i == self.selected) {
                fill(cr, x, 0, tab_w, 38, t.app_bg);
                fill(cr, x + 8, 35, tab_w - 16, 2, theme.shellPalette().accent);
            }
            var buf: [512]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, "{s}{s}", .{ tab.name(), if (tab.doc.modified()) " •" else "" }) catch "Text file";
            c.cairo_save(cr);
            c.cairo_rectangle(cr, x + 12, 2, tab_w - 42, 32);
            c.cairo_clip(cr);
            ui.setSource(cr, t.window_fg);
            ui.drawText(cr, label, x + 12, 24, ui.textSize(), false);
            c.cairo_restore(cr);
            self.paintButton(cr, .{ .x = @floatCast(x + tab_w - 28), .y = 5, .w = 24, .h = 26 }, "×", false);
        }
        self.paintButton(cr, .{ .x = @floatCast(self.tabRight() + 2), .y = 5, .w = 28, .h = 26 }, "+", false);
        if (!self.has_titlebar) self.paintButton(cr, .{ .x = @floatFromInt(self.w - 32), .y = 5, .w = 28, .h = 26 }, "…", self.menu_open);
        if (self.find_open) {
            const box: field.Rect = .{ .x = 12, .y = 43, .w = @floatFromInt(self.w - 110), .h = 30 };
            if (ui.Layer.begin(cr, box)) |l| {
                var layer = l;
                _ = field.paintFrame(&layer.renderer, layer.local(), .{}, .{ .focused = true });
                layer.finish();
            }
            c.cairo_save(cr);
            c.cairo_rectangle(cr, 22, 43, @floatFromInt(self.w - 130), 30);
            c.cairo_clip(cr);
            const bytes = self.query.text.items;
            const selected = self.query.selection();
            if (selected[0] != selected[1]) {
                const x = 22 + ui.measureText(cr, bytes[0..selected[0]], ui.textSize(), false);
                const width = ui.measureText(cr, bytes[selected[0]..selected[1]], ui.textSize(), false);
                fill(cr, x, 46, width, 24, t.app_item_selected);
            }
            var ink = t.window_fg;
            if (bytes.len == 0) ink[3] *= 0.5;
            ui.setSource(cr, ink);
            ui.drawText(cr, if (bytes.len == 0) "Find…" else bytes, 22, 64, ui.textSize(), false);
            if (self.focused and self.caret_visible) fill(cr, 22 + ui.measureText(cr, bytes[0..@min(self.query.cursor, bytes.len)], ui.textSize(), false), 48, 1, 18, t.window_fg);
            c.cairo_restore(cr);
            self.paintButton(cr, .{ .x = @floatFromInt(self.w - 90), .y = 43, .w = 78, .h = 30 }, "Next", false);
        }
        self.layout(cr);
        const tab = self.current();
        const sel = tab.doc.selection();
        c.cairo_save(cr);
        c.cairo_rectangle(cr, 12, self.viewTop(), @floatFromInt(self.w - 30), self.viewHeight());
        c.cairo_clip(cr);
        c.cairo_translate(cr, 16 - tab.scroll_x, self.viewTop() - tab.scroll);
        if (tab.layout) |layout_ptr| {
            if (p.pango_layout_get_iter(layout_ptr)) |iter| {
                defer p.pango_layout_iter_free(iter);
                var line_index: c_int = 0;
                while (true) : (line_index += 1) {
                    var rect: p.Rectangle = undefined;
                    p.pango_layout_iter_get_line_extents(iter, null, &rect);
                    const y = @as(f64, @floatFromInt(rect.y)) / 1024;
                    const h = @as(f64, @floatFromInt(rect.height)) / 1024;
                    if (y > tab.scroll + self.viewHeight()) break;
                    if (y + h >= tab.scroll) {
                        const line = p.pango_layout_iter_get_line_readonly(iter);
                        const line_start: usize = @intCast(p.pango_layout_line_get_start_index(line));
                        const line_end: usize = if (p.pango_layout_get_line_readonly(layout_ptr, line_index + 1)) |next|
                            @intCast(p.pango_layout_line_get_start_index(next))
                        else
                            tab.doc.text.items.len;
                        // Pango extends ranges to the right margin even for
                        // lines entirely before the selection. Only ask for
                        // intersecting lines, including a selected line break.
                        if (sel[0] != sel[1] and sel[0] < line_end and sel[1] > line_start) {
                            var ranges: ?[*]c_int = null;
                            var count: c_int = 0;
                            p.pango_layout_line_get_x_ranges(line, @intCast(sel[0]), @intCast(sel[1]), &ranges, &count);
                            if (ranges) |r| {
                                defer p.g_free(r);
                                var n: usize = 0;
                                while (n < @as(usize, @intCast(count))) : (n += 1) {
                                    var accent = theme.shellPalette().accent;
                                    accent[3] = 0.35;
                                    fill(cr, @as(f64, @floatFromInt(r[n * 2])) / 1024, y, @as(f64, @floatFromInt(r[n * 2 + 1] - r[n * 2])) / 1024, h, accent);
                                }
                            }
                        }
                        ui.setSource(cr, t.window_fg);
                        c.cairo_move_to(cr, @as(f64, @floatFromInt(rect.x)) / 1024, @as(f64, @floatFromInt(p.pango_layout_iter_get_baseline(iter))) / 1024);
                        p.pango_cairo_show_layout_line(cr, line);
                    }
                    if (p.pango_layout_iter_next_line(iter) == 0) break;
                }
            }
            if (self.focused and !self.find_open and self.close_tab == null) {
                var r: p.Rectangle = undefined;
                p.pango_layout_get_cursor_pos(layout_ptr, @intCast(tab.doc.cursor), &r, null);
                if (self.caret_visible) fill(cr, @as(f64, @floatFromInt(r.x)) / 1024, @as(f64, @floatFromInt(r.y)) / 1024, 1.5, @as(f64, @floatFromInt(r.height)) / 1024, t.window_fg);
                if (self.preedit.items.len > 0) {
                    const x = @as(f64, @floatFromInt(r.x)) / 1024;
                    const y = @as(f64, @floatFromInt(r.y + r.height)) / 1024;
                    ui.setSource(cr, t.window_fg);
                    ui.drawText(cr, self.preedit.items, x, y, ui.textSize(), false);
                    fill(cr, x, y + 2, ui.measureText(cr, self.preedit.items, ui.textSize(), false), 1, theme.shellPalette().accent);
                }
            }
        }
        c.cairo_restore(cr);
        if (self.scrollbarGeometry()) |bar| ui.drawScrollbar(cr, scrollbar.look(bar, self.bar_appearance, theme.global.scrollbar_width, theme.shellPalette()));
        fill(cr, 0, @as(f64, @floatFromInt(self.h)) - status_h, @floatFromInt(self.w), status_h, t.app_bar);
        var info: [256]u8 = undefined;
        const line = std.mem.count(u8, tab.doc.text.items[0..tab.doc.cursor], "\n") + 1;
        const column = (std.unicode.utf8CountCodepoints(tab.doc.text.items[tab.doc.lineStart(tab.doc.cursor)..tab.doc.cursor]) catch 0) + 1;
        const text = if (self.notice_len > 0) self.notice[0..self.notice_len] else std.fmt.bufPrint(&info, "Line {d}, Column {d}    ·    UTF-8{s}    ·    {s}", .{ line, column, if (tab.doc.bom) " BOM" else "", if (tab.doc.crlf) "CRLF" else "LF" }) catch "";
        ui.setSource(cr, t.window_fg);
        ui.drawText(cr, text, 12, @floatFromInt(self.h - 8), ui.statusSize(), false);
        if (self.menu_open) self.paintMenu(cr);
        if (self.close_tab != null) self.paintClose(cr);
    }
    fn paintClose(self: *App, cr: *c.cairo_t) void {
        fill(cr, 0, 0, @floatFromInt(self.w), @floatFromInt(self.h), .{ 0, 0, 0, 0.45 });
        const x: f32 = @as(f32, @floatFromInt(self.w - 420)) / 2;
        const y: f32 = @as(f32, @floatFromInt(self.h - 170)) / 2;
        if (ui.Layer.begin(cr, .{ .x = x, .y = y, .w = 420, .h = 170 })) |l| {
            var layer = l;
            dialog.paintFrame(&layer.renderer, layer.local());
            layer.finish();
        }
        ui.setSource(cr, theme.global.window_fg);
        ui.drawText(cr, "Save changes before closing?", x + 20, y + 36, ui.textSize(), true);
        ui.drawText(cr, "Your unsaved changes will be lost if you discard them.", x + 20, y + 72, ui.textSize(), false);
        self.paintButton(cr, .{ .x = x + 20, .y = y + 112, .w = 115, .h = 38 }, "Cancel", self.close_choice == 0);
        self.paintButton(cr, .{ .x = x + 145, .y = y + 112, .w = 125, .h = 38 }, "Discard", self.close_choice == 1);
        self.paintButton(cr, .{ .x = x + 280, .y = y + 112, .w = 120, .h = 38 }, "Save", self.close_choice == 2);
    }
};
fn fill(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64, color: [4]f32) void {
    ui.setSource(cr, color);
    c.cairo_rectangle(cr, x, y, w, h);
    c.cairo_fill(cr);
}
