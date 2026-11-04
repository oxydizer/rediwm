//! PDF Viewer UI application state, toolbar, reading canvas, and sidebar.
//! Integrates background worker thread, LRU page/tile/thumb caches,
//! continuous layout virtualization, search, selection, and outline.
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const c = @import("c.zig");
const document = @import("document.zig");
const layout = @import("layout.zig");
const selection = @import("selection.zig");
const cache = @import("cache.zig");
const worker = @import("worker.zig");
const shell_ui = @import("ui").cairo;
const scrollbar = @import("ui").widgets.scrollbar;
const secret_input = @import("ui").widgets.secret_input;
const Editor = @import("../files/editor.zig").Editor;

const app_document = @import("app_document.zig");
const app_layout = @import("app_layout.zig");
const app_scroll = @import("app_scroll.zig");
const app_pointer = @import("app_pointer.zig");
const app_keyboard = @import("app_keyboard.zig");
const app_paint = @import("app_paint.zig");
pub const a = std.heap.c_allocator;

pub const Rect = struct {
    x: f64,
    y: f64,

    w: f64,
    h: f64,

    pub fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px <= self.x + self.w and py >= self.y and py <= self.y + self.h;
    }
};

pub fn shellRect(r: Rect) shell_ui.Rect {
    return .{
        .x = @floatCast(r.x),
        .y = @floatCast(r.y),
        .w = @floatCast(r.w),
        .h = @floatCast(r.h),
    };
}

pub const ZoomMode = enum { fit_width, fit_page, manual };
pub const SidebarTab = enum { pages, outline };

pub const Action = enum {
    toggle_sidebar,
    prev_page,
    next_page,
    zoom_out,
    zoom_in,
    fit_width,
    fit_page,
    rotate,
    open_dialog,
    find_toggle,
    find_prev,
    find_next,
    find_close,
    print,
};

/// Toolbar buttons left to right, shared by painting and hit testing.
pub const ToolbarButton = struct { x: f64, w: f64, act: Action };
pub const toolbar_buttons = [_]ToolbarButton{
    .{ .x = 10.0, .w = 32.0, .act = .toggle_sidebar },
    .{ .x = 52.0, .w = 32.0, .act = .prev_page },
    .{ .x = 88.0, .w = 32.0, .act = .next_page },
    .{ .x = 210.0, .w = 32.0, .act = .zoom_out },
    .{ .x = 286.0, .w = 32.0, .act = .zoom_in },
    .{ .x = 326.0, .w = 76.0, .act = .fit_width },
    .{ .x = 406.0, .w = 70.0, .act = .fit_page },
    .{ .x = 484.0, .w = 32.0, .act = .rotate },
    .{ .x = 524.0, .w = 64.0, .act = .find_toggle },
    .{ .x = 596.0, .w = 32.0, .act = .print },
};
pub const toolbar_button_y: f64 = 6.0;
pub const toolbar_button_h: f64 = 32.0;

/// Pages whose raster exceeds this render as square tiles of `tile_px`
/// device pixels, of which only those in view are rendered.
pub fn rasterTiled(px_w: f64, px_h: f64) bool {
    return px_w > 2048 or px_h > 2048 or px_w * px_h > 4 * 1024 * 1024;
}
pub const tile_px: f64 = 1024.0;

/// The tiles of a page raster that intersect the canvas: half-open index
/// ranges over a grid in the raster's device pixels, the unit of
/// `cache.TileKey` and of the worker's clip.
pub const TileSpan = struct {
    raster_w: f64,
    raster_h: f64,
    x0: usize = 0,
    x1: usize = 0,
    y0: usize = 0,
    y1: usize = 0,

    pub fn key(self: TileSpan, tx: usize, ty: usize) cache.TileKey {
        const x = @as(f64, @floatFromInt(tx)) * tile_px;
        const y = @as(f64, @floatFromInt(ty)) * tile_px;
        return .{
            .x = @intFromFloat(x),
            .y = @intFromFloat(y),
            .w = @intFromFloat(@min(tile_px, self.raster_w - x)),
            .h = @intFromFloat(@min(tile_px, self.raster_h - y)),
        };
    }
};

pub fn tileClip(tk: cache.TileKey) layout.Rect {
    return .{ .x = @floatFromInt(tk.x), .y = @floatFromInt(tk.y), .w = @floatFromInt(tk.w), .h = @floatFromInt(tk.h) };
}

pub const Dialog = enum { none, information, password };
pub const Focus = enum { none, page_number, password, search };

pub const SearchMatch = struct {
    page_index: usize,
    rect: layout.Rect,
};

pub const PageContent = struct {
    page_index: usize,
    text: ?[:0]u8 = null,
    text_rects: []const layout.Rect = &[_]layout.Rect{},
    links: []document.Link = &[_]document.Link{},

    pub fn deinit(self: *PageContent) void {
        if (self.text) |t| a.free(t);
        a.free(self.text_rects);
        for (self.links) |l| l.deinit(a);
        if (self.links.len > 0) a.free(self.links);
        self.* = undefined;
    }
};

pub const App = struct {
    worker: *worker.Worker,
    page_cache: cache.PageCache,
    thumb_cache: cache.ThumbCache,

    path: ?[:0]const u8 = null,
    generation: u64 = 0,
    loading: bool = false,

    n_pages: usize = 0,
    page_sizes: std.ArrayList(layout.PageSize) = .empty,
    doc_layout: ?layout.DocumentLayout = null,
    sidebar_layout: ?layout.SidebarLayout = null,
    outline: ?[]document.OutlineItem = null,

    current_page: usize = 0,
    zoom_mode: ZoomMode = .fit_page,
    zoom: f64 = 1.0,
    rotation: layout.Rotation = .deg0,
    scroll_y: f64 = 0.0,
    scroll_x: f64 = 0.0,
    anchor: layout.Anchor = .{ .page_index = 0, .rel_y = 0.0 },

    sidebar_open: bool = true,
    sidebar_w: f64 = 180.0,
    sidebar_scroll_y: f64 = 0.0,
    sidebar_tab: SidebarTab = .pages,

    w: i32 = 1000,
    h: i32 = 700,
    scale: i32 = 1,
    dirty: bool = true,
    /// Only the toolbar strip changed (its buttons' proximity glow): the
    /// client may repaint and damage just that strip instead of the window.
    toolbar_dirty: bool = false,
    title_changed: bool = true,
    title: [1024:0]u8 = @splat(0),
    closed: bool = false,

    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    dragging_canvas: bool = false,
    drag_start_y: f64 = 0,
    drag_start_scroll_y: f64 = 0,
    drag_start_x: f64 = 0,
    drag_start_scroll_x: f64 = 0,
    hbar_drag: scrollbar.Drag = .{},
    hbar_appearance: scrollbar.Appearance = .{},
    hbar_observed: f64 = 0,
    px: f64 = 0,
    py: f64 = 0,
    hover: ?Action = null,
    hover_thumb: ?usize = null,
    hover_outline: ?usize = null,

    dialog: Dialog = .none,
    focus: Focus = .none,
    editor: Editor = .{},
    error_message: ?[]const u8 = null,

    // Secure password input over mlocked storage
    password_buf: *[257]u8,
    password_input: secret_input.Input = undefined,

    // In-page search
    search_open: bool = false,
    search_editor: Editor = .{},
    search_matches: std.ArrayList(SearchMatch) = .empty,
    search_match_idx: usize = 0,
    search_in_progress: bool = false,

    // Page content & links
    page_contents: std.AutoHashMap(usize, PageContent),
    hover_text: bool = false,
    hover_link: ?document.Link = null,

    // Text selection & Wayland clipboard
    selection_active: bool = false,
    selection_dragging: bool = false,
    selection_page: ?usize = null,
    selection_start: layout.Point = .{ .x = 0, .y = 0 },
    selection_end: layout.Point = .{ .x = 0, .y = 0 },
    selection_range: ?selection.Range = null,
    selected_text: ?[:0]u8 = null,
    clipboard_text: ?[:0]u8 = null,
    clipboard_request: bool = false,

    /// Set by the Print button; main.zig hands it to the print helper.
    print_request: bool = false,

    pub fn init(initial_path: [:0]const u8, document_fd: c_int) !App {
        const wkr = try worker.Worker.init(document_fd);
        errdefer wkr.deinit();

        // Stable dedicated storage: returning App by value must not leave
        // password_input pointing into the init() stack frame.
        const secret = try std.heap.page_allocator.create([257]u8);
        errdefer std.heap.page_allocator.destroy(secret);
        if (c.api.mlock(secret, secret.len) != 0) return error.PasswordMemoryFailed;
        errdefer _ = c.api.munlock(secret, secret.len);
        const path = try a.dupeSentinel(u8, initial_path, 0);
        errdefer a.free(path);

        var self = App{
            .worker = wkr,
            .path = path,
            .password_buf = secret,
            .password_input = .{ .storage = secret[0..256] },
            .page_cache = cache.PageCache.init(a, cache.PAGE_CACHE_LIMIT),
            .thumb_cache = cache.ThumbCache.init(a, cache.THUMB_CACHE_LIMIT),
            .page_contents = std.AutoHashMap(usize, PageContent).init(a),
        };

        try self.openDocument(null);
        return self;
    }

    pub fn deinit(self: *App) void {
        self.worker.deinit();
        self.page_cache.deinit();
        self.thumb_cache.deinit();

        if (self.doc_layout) |l| l.deinit();
        if (self.sidebar_layout) |s| s.deinit();
        if (self.path) |p| a.free(p);
        if (self.selected_text) |t| a.free(t);
        if (self.clipboard_text) |t| a.free(t);

        self.clearOutline();
        self.clearPageContents();
        self.page_contents.deinit();

        self.page_sizes.deinit(a);
        self.editor.deinit(a);
        self.search_editor.deinit(a);
        self.search_matches.deinit(a);

        self.password_input.clear();
        _ = c.api.munlock(self.password_buf, self.password_buf.len);
        std.heap.page_allocator.destroy(self.password_buf);
    }

    // app_document.zig
    pub const clearOutline = app_document.clearOutline;
    pub const clearPageContents = app_document.clearPageContents;
    pub const openDocument = app_document.openDocument;
    pub const submitPassword = app_document.submitPassword;
    pub const sync = app_document.sync;
    pub const queueRenderJobs = app_document.queueRenderJobs;

    // app_layout.zig
    pub const recomputeLayout = app_layout.recomputeLayout;
    pub const relayout = app_layout.relayout;
    pub const setZoomMode = app_layout.setZoomMode;
    pub const zoomBy = app_layout.zoomBy;
    pub const handleZoomScroll = app_layout.handleZoomScroll;
    pub const isTiled = app_layout.isTiled;
    pub const tileSpan = app_layout.tileSpan;
    pub const updateEffectiveZoom = app_layout.updateEffectiveZoom;

    pub fn updateTitle(self: *App) void {
        if (self.path) |p| {
            const raw = std.fs.path.basename(p);
            const base = if (std.unicode.utf8ValidateSlice(raw)) raw else "Document.pdf";
            _ = i18n.fmtZ(&self.title, tr("{name} — PDF Viewer ({page}/{pages})"), .{ .name = base, .page = self.current_page + 1, .pages = self.n_pages }) catch {
                _ = i18n.fmtZ(&self.title, tr("PDF Viewer"), .{}) catch unreachable;
            };
        } else {
            _ = i18n.fmtZ(&self.title, tr("PDF Viewer"), .{}) catch unreachable;
        }
        self.title_changed = true;
    }

    pub fn getTitle(self: *App) [*:0]const u8 {
        return &self.title;
    }

    pub fn resize(self: *App, w: i32, h: i32) void {
        if (self.w == w and self.h == h) return;
        self.w = w;
        self.h = h;
        if (self.zoom_mode != .manual) {
            self.updateEffectiveZoom();
        }
        self.relayout();
    }

    pub fn requestClose(self: *App) void {
        self.closed = true;
    }

    // app_layout.zig
    pub const toolbarRect = app_layout.toolbarRect;
    pub const sidebarRect = app_layout.sidebarRect;
    pub const canvasRect = app_layout.canvasRect;
    pub const contentWidth = app_layout.contentWidth;
    pub const maxScrollX = app_layout.maxScrollX;
    pub const pageX = app_layout.pageX;

    pub const page_margin: f64 = 20.0;

    // app_scroll.zig
    pub const hbar = app_scroll.hbar;
    pub const stepBar = app_scroll.stepBar;
    pub const barTimeout = app_scroll.barTimeout;
    pub const handleHorizontalScroll = app_scroll.handleHorizontalScroll;

    // app_layout.zig
    pub const searchBarRect = app_layout.searchBarRect;

    // app_scroll.zig
    pub const goToPage = app_scroll.goToPage;
    pub const scrollToMatch = app_scroll.scrollToMatch;
    pub const executeSearch = app_scroll.executeSearch;
    pub const handleScroll = app_scroll.handleScroll;
    pub const scrollViewport = app_scroll.scrollViewport;

    // app_pointer.zig
    pub const handleMotion = app_pointer.handleMotion;
    pub const buttonProximity = app_pointer.buttonProximity;
    pub const handleButton = app_pointer.handleButton;
    pub const clearSelectionText = app_pointer.clearSelectionText;
    pub const updateSelection = app_pointer.updateSelection;
    pub const handleToolbarClick = app_pointer.handleToolbarClick;
    pub const handleSidebarClick = app_pointer.handleSidebarClick;
    pub const handleSearchBarClick = app_pointer.handleSearchBarClick;
    pub const handleDialogClick = app_pointer.handleDialogClick;

    // app_keyboard.zig
    pub const triggerAction = app_keyboard.triggerAction;

    /// Reports a print helper problem in the information dialog.
    pub fn showMessage(self: *App, message: []const u8) void {
        self.dialog = .information;
        self.focus = .none;
        self.error_message = message;
        self.dirty = true;
    }

    // app_keyboard.zig
    pub const handleKey = app_keyboard.handleKey;
    pub const keyRepeats = app_keyboard.keyRepeats;

    // app_pointer.zig
    pub const cancelDrag = app_pointer.cancelDrag;
    pub const cursorName = app_pointer.cursorName;

    // app_paint.zig
    pub const render = app_paint.render;
    pub const renderCanvas = app_paint.renderCanvas;
    pub const drawRaster = app_paint.drawRaster;
    pub const drawCachedSurface = app_paint.drawCachedSurface;
    pub const renderSidebar = app_paint.renderSidebar;
    pub const renderThumbnailCards = app_paint.renderThumbnailCards;
    pub const renderOutlineList = app_paint.renderOutlineList;
    pub const renderToolbar = app_paint.renderToolbar;
    pub const renderSearchBar = app_paint.renderSearchBar;
    pub const renderDialog = app_paint.renderDialog;
    pub const renderButtonText = app_paint.renderButtonText;
    pub const renderToggle = app_paint.renderToggle;
    pub const renderButtonIcon = app_paint.renderButtonIcon;
};
