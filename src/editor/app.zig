const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const c = @import("../files/c.zig").api;
const ui = @import("ui").cairo;
const theme = @import("ui").theme;
const scrollbar = @import("ui").widgets.scrollbar;
const button = @import("ui").widgets.button;
const field = @import("ui").widgets.field;
const dialog = @import("ui").widgets.dialog;
const menu = @import("ui").context_menu;
const p = @import("pango.zig");
const caret_mod = @import("caret.zig");
const input = @import("ui").input;
const Document = @import("document.zig").Document;
const view = @import("view.zig");
const lines = @import("lines.zig");
const op = @import("operation.zig");
const app_files = @import("app_files.zig");
const app_view = @import("app_view.zig");
const app_input = @import("app_input.zig");
const app_paint = @import("app_paint.zig");
const app_search = @import("app_search.zig");
const app_edit = @import("app_edit.zig");
const app_controls = @import("app_controls.zig");
const app_drafts = @import("app_drafts.zig");
const drafts = @import("drafts.zig");
const a = std.heap.c_allocator;
pub const top: f64 = 40;
pub const status_h: f64 = 26;
/// A tab is this wide while there is room; tabs share the strip down to
/// `tab_min`, and beyond that the strip scrolls.
pub const tab_max: f64 = 176;
pub const tab_min: f64 = 112;
const Status = struct {
    revision: usize = std.math.maxInt(usize),
    cursor: usize = 0,
    line: usize = 0,
    column: usize = 0,
};
/// Stand-in for the position of a cursor too far from the view to measure.
pub const far: c_int = 1_000_000 * 1024;
pub const Action = enum { new, open, save, save_as, find, replace, wrap };
pub const labels = [_]i18n.Message{ i18n.msg("New"), i18n.msg("Open"), i18n.msg("Save"), i18n.msg("Save As"), i18n.msg("Find"), i18n.msg("Replace"), i18n.msg("Word Wrap") };
pub const Tab = struct {
    id: usize,
    doc: Document = .{},
    path: ?[:0]u8 = null,
    stamp: ?op.Stamp = null,
    /// Pixels of the first visible line (`doc.top`) scrolled out of view.
    dy: f64 = 0,
    scroll_x: f64 = 0,
    measure: view.Measure = .{},
    /// The status bar's line and column, recomputed only when the cursor or text moves.
    status: Status = .{},
    /// The draft file this tab's unsaved text lives in, and the revision of the
    /// text it holds; null while the tab has none (see `drafts.zig`).
    draft_name: ?u64 = null,
    draft_rev: ?usize = null,
    pub fn deinit(t: *Tab) void {
        t.doc.deinit();
        if (t.path) |path| a.free(path);
        a.destroy(t);
    }
    pub fn name(t: *Tab) []const u8 {
        return if (t.path) |path| std.fs.path.basename(path) else tr("Untitled");
    }
};
pub const App = struct {
    tabs: std.ArrayList(*Tab) = .empty,
    selected: usize = 0,
    next_id: usize = 1,
    /// How far the tab strip is scrolled, in pixels.
    tab_scroll: f64 = 0,
    strip_seen: app_controls.Strip = .{},
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
    caret: caret_mod.Caret = .{},
    caret_painted: caret_mod.Rect = .{},
    caret_snap: bool = true,
    caret_dirty: bool = false,
    caret_activity: usize = 0,
    menu_open: bool = false,
    menu_selected: ?usize = null,
    menu_anchor: f64 = 0,
    has_titlebar: bool = true,
    dragging: bool = false,
    drag_word: ?[2]usize = null,
    last_text_click: ?struct { time: i64, x: f64, y: f64, tab: usize } = null,
    scroll_drag: scrollbar.Drag = .{},
    bar_appearance: scrollbar.Appearance = .{},
    /// The scroll position and tab the scrollbar last saw: only a scroll within
    /// the same tab shows feedback, not switching to a tab scrolled elsewhere.
    bar_observed: f64 = 0,
    bar_tab: ?*Tab = null,
    px: f64 = -1,
    py: f64 = -1,
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
    replace_open: bool = false,
    search_focus: app_search.Control = .query,
    query: @import("../files/editor.zig").Editor = .{},
    replacement: @import("../files/editor.zig").Editor = .{},
    clipboard: std.ArrayList(u8) = .empty,
    clipboard_revision: usize = 0,
    paste_requested: bool = false,
    preedit: std.ArrayList(u8) = .empty,
    layouts: view.Layouts = .{},
    rows: std.ArrayList(view.Row) = .empty,
    /// Where unsaved text is kept between sessions; null when it cannot be.
    keeper: ?*drafts.Keeper = null,

    pub fn init(io: std.Io) !App {
        var self: App = .{ .io = io };
        try self.newTab();
        return self;
    }
    pub fn deinit(self: *App) void {
        self.deinitDrafts();
        if (self.operation) |job| job.deinit();
        for (self.tabs.items) |t| t.deinit();
        self.tabs.deinit(a);
        for (self.queue.items) |path| a.free(path);
        self.queue.deinit(a);
        self.query.deinit(a);
        self.replacement.deinit(a);
        self.clipboard.deinit(a);
        self.preedit.deinit(a);
        self.rows.deinit(a);
        self.layouts.deinit();
    }
    pub fn current(self: *App) *Tab {
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
    pub fn findTab(self: *App, id: usize) ?usize {
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
    pub fn changed(self: *App) void {
        self.dirty = true;
        if (self.tabs.items.len == 0) return;
        const t = self.current();
        const name = if (std.unicode.utf8ValidateSlice(t.name())) t.name() else tr("Text file");
        var title: [1024:0]u8 = undefined;
        const value = i18n.fmtZ(&title, tr("{modified}{name} — Text Editor ({tab}/{tabs})"), .{ .modified = if (t.doc.modified()) "* " else "", .name = name, .tab = self.selected + 1, .tabs = self.tabs.items.len }) catch "";
        // Resizing and moving the caret do not change the window title. Avoid
        // sending a redundant set_title alongside every resize buffer commit.
        if (!std.mem.eql(u8, std.mem.span(self.getTitle()), value)) {
            @memcpy(self.title[0..value.len], value);
            self.title[value.len] = 0;
            self.title_changed = true;
        }
        self.revealTab();
    }

    pub const CaretState = app_paint.CaretState;
    pub const caretState = app_paint.caretState;
    pub const stepCaret = app_paint.stepCaret;
    pub const caretDamage = app_paint.caretDamage;
    pub const paintCaret = app_paint.paintCaret;
    pub const tabRight = app_paint.tabRight;
    pub const dismissMenu = app_paint.dismissMenu;
    pub const toggleMenu = app_paint.toggleMenu;
    pub const menuBox = app_paint.menuBox;
    pub const menuRow = app_paint.menuRow;
    pub const menuHit = app_paint.menuHit;
    pub const paintMenu = app_paint.paintMenu;
    pub const paintButton = app_paint.paintButton;
    pub const paintIcon = app_controls.paintIcon;
    pub const tabWidth = app_controls.tabWidth;
    pub const tabX = app_controls.tabX;
    pub const tabAt = app_controls.tabAt;
    pub const tabScrollMax = app_controls.tabScrollMax;
    pub const scrollTabs = app_controls.scrollTabs;
    pub const revealTab = app_controls.revealTab;
    pub const tabCloseBox = app_controls.tabCloseBox;
    pub const newButtonBox = app_controls.newButtonBox;
    pub const menuButtonBox = app_controls.menuButtonBox;
    pub const hoverTarget = app_controls.hoverTarget;
    pub const render = app_paint.render;
    pub const paintLine = app_paint.paintLine;
    pub const paintClose = app_paint.paintClose;
    pub fn getTitle(self: *App) [*:0]const u8 {
        return &self.title;
    }

    pub const message = app_files.message;
    pub const failure = app_files.failure;
    pub const open = app_files.open;
    pub const sync = app_files.sync;
    pub const choose = app_files.choose;
    pub const startSave = app_files.startSave;
    pub const save = app_files.save;
    pub const requestClose = app_files.requestClose;
    pub const closeSelected = app_files.closeSelected;
    pub const finishClose = app_files.finishClose;
    pub const act = app_files.act;

    pub const openDrafts = app_drafts.openDrafts;
    pub const stepDrafts = app_drafts.stepDrafts;
    pub const draftTimeout = app_drafts.draftTimeout;
    pub const draftWake = app_drafts.draftWake;
    pub const drainDrafts = app_drafts.drainDrafts;
    pub const signaled = app_drafts.signaled;
    pub const deinitDrafts = app_drafts.deinitDrafts;

    pub const resize = app_view.resize;
    pub const viewTop = app_view.viewTop;
    pub const viewHeight = app_view.viewHeight;
    pub const cancelDrag = app_view.cancelDrag;
    pub const cursorName = app_view.cursorName;
    pub const scrollbarGeometry = app_view.scrollbarGeometry;
    pub const scrollOffset = app_view.scrollOffset;
    pub const seekScroll = app_view.seekScroll;
    pub const port = app_view.port;
    pub const stepBar = app_view.stepBar;
    pub const barTimeout = app_view.barTimeout;
    pub const handleScroll = app_view.handleScroll;
    pub const caretRect = app_view.caretRect;
    pub const caretRectNear = app_view.caretRectNear;
    pub const inputRectangle = app_view.inputRectangle;
    pub const reveal = app_view.reveal;

    pub const indexAt = app_input.indexAt;
    pub const handleMotion = app_input.handleMotion;
    pub const handleButton = app_input.handleButton;
    pub const pasteText = app_input.pasteText;
    pub const findNext = app_search.findNext;
    pub const openSearch = app_search.openSearch;
    pub const searchEditor = app_search.searchEditor;
    pub const searchBox = app_search.searchBox;
    pub const searchHit = app_search.searchHit;
    pub const searchKey = app_search.searchKey;
    pub const searchActivate = app_search.searchActivate;
    pub const paintSearch = app_search.paintSearch;
    pub const searchCaret = app_search.searchCaret;
    pub const keyRepeats = app_input.keyRepeats;
    pub const handleKey = app_input.handleKey;
    pub const editKey = app_edit.editKey;
};
pub fn fill(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64, color: [4]f32) void {
    ui.setSource(cr, color);
    c.cairo_rectangle(cr, x, y, w, h);
    c.cairo_fill(cr);
}
