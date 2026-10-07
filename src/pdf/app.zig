//! PDF Viewer UI application state, toolbar, reading canvas, and sidebar.
//! Integrates background worker thread, LRU page/tile/thumb caches,
//! continuous layout virtualization, search, selection, and outline.
const std = @import("std");
const c = @import("c.zig");
const document = @import("document.zig");
const layout = @import("layout.zig");
const cache = @import("cache.zig");
const worker = @import("worker.zig");
const shell_ui = @import("ui").cairo;
const ui_button = @import("ui").widgets.button;
const ui_field = @import("ui").widgets.field;
const ui_dialog = @import("ui").widgets.dialog;
const ui_theme = @import("ui").theme;
const scrollbar = @import("ui").widgets.scrollbar;
const secret_input = @import("ui").widgets.secret_input;
const Editor = @import("../files/editor.zig").Editor;
const IconId = @import("ui").layout.IconId;

const a = std.heap.c_allocator;

pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    pub fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px <= self.x + self.w and py >= self.y and py <= self.y + self.h;
    }
};

fn shellRect(r: Rect) shell_ui.Rect {
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
const ToolbarButton = struct { x: f64, w: f64, act: Action };
const toolbar_buttons = [_]ToolbarButton{
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
const toolbar_button_y: f64 = 6.0;
const toolbar_button_h: f64 = 32.0;

/// Pages whose raster exceeds this render as square tiles of `tile_px`
/// device pixels, of which only those in view are rendered.
fn rasterTiled(px_w: f64, px_h: f64) bool {
    return px_w > 2048 or px_h > 2048 or px_w * px_h > 4 * 1024 * 1024;
}
const tile_px: f64 = 1024.0;

/// The tiles of a page raster that intersect the canvas: half-open index
/// ranges over a grid in the raster's device pixels, the unit of
/// `cache.TileKey` and of the worker's clip.
const TileSpan = struct {
    raster_w: f64,
    raster_h: f64,
    x0: usize = 0,
    x1: usize = 0,
    y0: usize = 0,
    y1: usize = 0,

    fn key(self: TileSpan, tx: usize, ty: usize) cache.TileKey {
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

fn tileClip(tk: cache.TileKey) layout.Rect {
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
    links: []document.Link = &[_]document.Link{},

    pub fn deinit(self: *PageContent) void {
        if (self.text) |t| a.free(t);
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
    hover_link: ?document.Link = null,

    // Text selection & Wayland clipboard
    selection_active: bool = false,
    selection_dragging: bool = false,
    selection_page: ?usize = null,
    selection_start: layout.Point = .{ .x = 0, .y = 0 },
    selection_end: layout.Point = .{ .x = 0, .y = 0 },
    selection_box: ?layout.Rect = null,
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
        const path = try a.dupeZ(u8, initial_path);
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

    fn clearOutline(self: *App) void {
        if (self.outline) |items| {
            for (items) |it| it.deinit(a);
            a.free(items);
            self.outline = null;
        }
    }

    fn clearPageContents(self: *App) void {
        var it = self.page_contents.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.page_contents.clearRetainingCapacity();
    }

    fn openDocument(self: *App, password: ?[:0]const u8) !void {
        self.error_message = null;
        self.generation += 1;
        self.loading = true;

        if (self.doc_layout) |l| {
            l.deinit();
            self.doc_layout = null;
        }
        if (self.sidebar_layout) |s| {
            s.deinit();
            self.sidebar_layout = null;
        }
        self.page_sizes.clearRetainingCapacity();
        self.page_cache.clearGeneration(self.generation);
        self.thumb_cache.clearGeneration(self.generation);
        self.clearOutline();
        self.clearPageContents();
        self.search_matches.clearRetainingCapacity();

        self.current_page = 0;
        self.scroll_y = 0.0;
        self.anchor = .{ .page_index = 0, .rel_y = 0.0 };
        self.dialog = .none;
        self.focus = .none;

        try self.worker.requestOpen(password, self.generation);
        self.updateTitle();
        self.dirty = true;
    }

    fn submitPassword(self: *App) void {
        const len = self.password_input.len;
        self.password_buf[len] = 0;
        // requestOpen makes its own locked copy before this storage is wiped.
        self.openDocument(self.password_buf[0..len :0]) catch {
            self.loading = false;
            self.dialog = .password;
            self.focus = .password;
            self.error_message = "Could not prepare password. Please try again.";
        };
        self.password_input.clear();
        self.dirty = true;
    }

    pub fn sync(self: *App) void {
        var received_any = false;
        while (self.worker.takeResult()) |res| {
            var mut_res = res;
            defer mut_res.deinit();

            if (mut_res.generation != self.generation) continue;
            received_any = true;

            switch (mut_res.payload) {
                .open_done => |od| {
                    self.loading = false;
                    self.n_pages = od.page_count;
                    self.dialog = .none;
                    self.focus = .none;

                    self.page_sizes.clearRetainingCapacity();
                    self.page_sizes.ensureTotalCapacity(a, self.n_pages) catch {
                        self.n_pages = 0;
                        self.error_message = "Not enough memory to open this document.";
                        self.dirty = true;
                        continue;
                    };

                    // Initial estimate from page 0
                    self.page_sizes.appendAssumeCapacity(od.first_page_size);
                    for (1..self.n_pages) |_| {
                        self.page_sizes.appendAssumeCapacity(od.first_page_size);
                    }

                    // Store outline
                    self.clearOutline();
                    self.outline = od.outline;
                    mut_res.payload.open_done.outline = null;

                    self.updateEffectiveZoom();
                    self.recomputeLayout() catch {};
                    self.updateTitle();
                    self.dirty = true;
                },

                .open_failed => |of| {
                    self.loading = false;
                    if (of.err == error.Encrypted) {
                        self.dialog = .password;
                        self.focus = .password;
                        self.password_input.clear();
                        self.error_message = "Document is encrypted. Enter password:";
                    } else if (of.err == error.FileNotFound) {
                        self.error_message = "File not found.";
                    } else if (of.err == error.InvalidPdf) {
                        self.error_message = "Invalid or corrupt PDF document.";
                    } else {
                        self.error_message = "Could not open document.";
                    }
                    self.dirty = true;
                },

                .page_sizes_batch => |b| {
                    for (b.sizes, 0..) |sz, idx| {
                        const p_idx = b.start + idx;
                        if (p_idx < self.page_sizes.items.len) {
                            self.page_sizes.items[p_idx] = sz;
                        }
                    }
                    // Open fitted to the first page's size; refit to the real ones.
                    if (self.zoom_mode != .manual) self.updateEffectiveZoom();
                    self.relayout();
                },

                .page_rendered => |*pr| {
                    const key = cache.PageKey.init(
                        self.generation,
                        pr.page_index,
                        pr.scale,
                        pr.rotation,
                        if (pr.clip) |c_val| .{
                            .x = @intFromFloat(c_val.x),
                            .y = @intFromFloat(c_val.y),
                            .w = @intFromFloat(c_val.w),
                            .h = @intFromFloat(c_val.h),
                        } else null,
                    );
                    self.page_cache.put(.{
                        .key = key,
                        .pixels = pr.rendered.pixels,
                        .width = pr.rendered.width,
                        .height = pr.rendered.height,
                        .stride = pr.rendered.stride,
                        .bytes = @intCast(pr.rendered.stride * pr.rendered.height),
                        .last_used = 0,
                        .allocator = pr.rendered.allocator,
                    }) catch {};
                    pr.rendered.pixels = &[_]u32{};
                    self.dirty = true;
                },

                .thumb_rendered => |*tr| {
                    const key = cache.ThumbKey{
                        .generation = self.generation,
                        .page_index = tr.page_index,
                        .rotation = tr.rotation,
                        .card_w = tr.card_w,
                        .card_h = tr.card_h,
                    };
                    self.thumb_cache.put(.{
                        .key = key,
                        .pixels = tr.rendered.pixels,
                        .width = tr.rendered.width,
                        .height = tr.rendered.height,
                        .stride = tr.rendered.stride,
                        .bytes = @intCast(tr.rendered.stride * tr.rendered.height),
                        .last_used = 0,
                        .allocator = tr.rendered.allocator,
                    }) catch {};
                    tr.rendered.pixels = &[_]u32{};
                    self.dirty = true;
                },

                .content_extracted => |*ce| {
                    var entry = self.page_contents.getOrPut(ce.page_index) catch continue;
                    if (entry.found_existing) entry.value_ptr.deinit();
                    entry.value_ptr.* = .{
                        .page_index = ce.page_index,
                        .text = ce.text,
                        .links = ce.links,
                    };
                    ce.text = null;
                    ce.links = &[_]document.Link{};
                    self.dirty = true;
                },

                .search_matches => |*sm| {
                    for (sm.rects) |r| {
                        self.search_matches.append(a, .{ .page_index = sm.page_index, .rect = r }) catch {};
                    }
                    if (self.search_matches.items.len > 0 and self.search_match_idx == 0) {
                        self.scrollToMatch(0);
                    }
                    self.dirty = true;
                },

                else => {},
            }
        }

        self.queueRenderJobs();
    }

    fn queueRenderJobs(self: *App) void {
        const dl = self.doc_layout orelse return;
        const cv = self.canvasRect();
        const vis = layout.findVisiblePages(dl.pages, self.scroll_y, cv.h);
        const vis_range = vis orelse return;

        var jobs: [64]worker.Job = undefined;
        var count: usize = 0;

        const effective_scale = self.zoom * @as(f64, @floatFromInt(self.scale));

        // 1. Visible page render jobs (priority 0)
        for (vis_range.start_index..vis_range.end_index + 1) |i| {
            if (count >= jobs.len) break;
            const p = dl.pages[i];

            // Large pages: only the tiles in view.
            if (self.tileSpan(cv, p)) |span| {
                for (span.y0..span.y1) |ty| for (span.x0..span.x1) |tx| {
                    if (count >= jobs.len) break;
                    const tk = span.key(tx, ty);
                    const pk = cache.PageKey.init(self.generation, i, effective_scale, self.rotation, tk);
                    if (self.page_cache.get(pk) == null) {
                        jobs[count] = .{
                            .kind = .render_page,
                            .priority = 0,
                            .generation = self.generation,
                            .page_index = i,
                            .scale = effective_scale,
                            .rotation = self.rotation,
                            .clip = tileClip(tk),
                        };
                        count += 1;
                    }
                };
            } else {
                const pk = cache.PageKey.init(self.generation, i, effective_scale, self.rotation, null);
                if (self.page_cache.get(pk) == null) {
                    jobs[count] = .{
                        .kind = .render_page,
                        .priority = 0,
                        .generation = self.generation,
                        .page_index = i,
                        .scale = effective_scale,
                        .rotation = self.rotation,
                        .clip = null,
                    };
                    count += 1;
                }
            }

            // Also request content for links / selection if not cached
            if (!self.page_contents.contains(i)) {
                self.worker.requestContent(i, self.generation);
            }
        }

        // 2. Visible thumbnail jobs (priority 1)
        if (self.sidebar_open and self.sidebar_tab == .pages and self.sidebar_layout != null) {
            const sb = self.sidebarRect();
            const sbl = self.sidebar_layout.?;
            const vis_sb = layout.findVisibleSidebarCards(sbl.cards, self.sidebar_scroll_y, sb.h);
            if (vis_sb) |vsb| {
                const card_w = self.sidebar_w - 32.0;
                for (vsb.start_index..vsb.end_index + 1) |i| {
                    if (count >= jobs.len) break;
                    const card = sbl.cards[i];
                    const tk = cache.ThumbKey{
                        .generation = self.generation,
                        .page_index = i,
                        .rotation = self.rotation,
                        .card_w = @intFromFloat(card_w),
                        .card_h = @intFromFloat(card.card_h),
                    };
                    if (self.thumb_cache.get(tk) == null) {
                        const rsz = layout.rotatedPageSize(self.page_sizes.items[i], self.rotation);
                        const base_w = rsz.width * layout.PTS_TO_LOGICAL;
                        const thumb_scale = (card_w / base_w) * @as(f64, @floatFromInt(self.scale));
                        jobs[count] = .{
                            .kind = .render_thumb,
                            .priority = 1,
                            .generation = self.generation,
                            .page_index = i,
                            .scale = thumb_scale,
                            .rotation = self.rotation,
                            .card_w = card_w,
                            .card_h = card.card_h,
                        };
                        count += 1;
                    }
                }
            }
        }

        // 3. Nearby prefetch page (priority 2), unless it would be tiled: a
        // whole raster of it would be large, and drawn tiles replace it.
        if (vis_range.start_index > 0 and count < jobs.len and !self.isTiled(dl.pages[vis_range.start_index - 1])) {
            const prev = vis_range.start_index - 1;
            const pk = cache.PageKey.init(self.generation, prev, effective_scale, self.rotation, null);
            if (self.page_cache.get(pk) == null) {
                jobs[count] = .{
                    .kind = .render_page,
                    .priority = 2,
                    .generation = self.generation,
                    .page_index = prev,
                    .scale = effective_scale,
                    .rotation = self.rotation,
                };
                count += 1;
            }
        }
        if (vis_range.end_index + 1 < dl.pages.len and count < jobs.len and !self.isTiled(dl.pages[vis_range.end_index + 1])) {
            const next = vis_range.end_index + 1;
            const pk = cache.PageKey.init(self.generation, next, effective_scale, self.rotation, null);
            if (self.page_cache.get(pk) == null) {
                jobs[count] = .{
                    .kind = .render_page,
                    .priority = 2,
                    .generation = self.generation,
                    .page_index = next,
                    .scale = effective_scale,
                    .rotation = self.rotation,
                };
                count += 1;
            }
        }

        if (count > 0) {
            self.worker.setRenderJobs(jobs[0..count], self.generation);
        }
    }

    fn recomputeLayout(self: *App) !void {
        if (self.page_sizes.items.len == 0) return;
        const cv_w = self.canvasRect().w;
        const old_content = self.contentWidth();
        // Fraction of the content sitting at the viewport centre, so zoom and
        // resize keep the same spot in view.
        const centre_frac: f64 = if (old_content > cv_w and old_content > 0)
            (self.scroll_x + cv_w / 2.0) / old_content
        else
            0.5;
        if (self.doc_layout) |l| l.deinit();
        self.doc_layout = try layout.computeDocumentLayout(
            a,
            self.page_sizes.items,
            self.zoom,
            self.rotation,
            16.0,
        );

        self.scroll_x = std.math.clamp(centre_frac * self.contentWidth() - cv_w / 2.0, 0.0, self.maxScrollX());

        if (self.sidebar_layout) |s| s.deinit();
        self.sidebar_layout = try layout.computeSidebarLayout(
            a,
            self.page_sizes.items,
            self.rotation,
            self.sidebar_w - 32.0,
        );
    }

    /// Lays the pages out again after a zoom, rotation or size change and
    /// returns to the same reading position.
    fn relayout(self: *App) void {
        self.recomputeLayout() catch {};
        if (self.doc_layout) |dl| {
            const cv_h = self.canvasRect().h;
            const anchored = layout.scrollToAnchor(dl.pages, self.anchor, cv_h);
            self.scroll_y = @min(anchored, @max(0.0, dl.total_height - cv_h));
        }
        self.dirty = true;
    }

    fn setZoomMode(self: *App, mode: ZoomMode) void {
        self.zoom_mode = mode;
        self.updateEffectiveZoom();
        self.relayout();
    }

    fn zoomBy(self: *App, factor: f64) void {
        if (self.doc_layout == null) return;
        self.zoom_mode = .manual;
        self.zoom = std.math.clamp(self.zoom * factor, 0.2, 5.0);
        self.relayout();
    }

    /// Ctrl+wheel: a 15-unit wheel notch zooms 1.2x, like the buttons;
    /// touchpads zoom smoothly in proportion.
    pub fn handleZoomScroll(self: *App, delta: f64) void {
        self.zoomBy(std.math.pow(f64, 1.2, -delta / 15.0));
    }

    fn isTiled(self: *const App, p: layout.PageLayout) bool {
        const s: f64 = @floatFromInt(self.scale);
        return rasterTiled(@ceil(p.logical_width * s), @ceil(p.logical_height * s));
    }

    /// The visible tiles of page `p`, or null when it renders whole.
    fn tileSpan(self: *const App, cv: Rect, p: layout.PageLayout) ?TileSpan {
        if (!self.isTiled(p)) return null;
        const s: f64 = @floatFromInt(self.scale);
        var span: TileSpan = .{ .raster_w = @ceil(p.logical_width * s), .raster_h = @ceil(p.logical_height * s) };
        // The canvas in page coordinates, clamped to the page.
        const page_x = self.pageX(cv, p);
        const page_y = cv.y + p.y_offset - self.scroll_y;
        const x0 = @max(0.0, cv.x - page_x) * s;
        const x1 = @min(p.logical_width, cv.x + cv.w - page_x) * s;
        const y0 = @max(0.0, cv.y - page_y) * s;
        const y1 = @min(p.logical_height, cv.y + cv.h - page_y) * s;
        if (x1 <= x0 or y1 <= y0) return span;
        const cols = @ceil(span.raster_w / tile_px);
        const rows = @ceil(span.raster_h / tile_px);
        span.x0 = @intFromFloat(@floor(x0 / tile_px));
        span.x1 = @intFromFloat(@min(cols, @ceil(x1 / tile_px)));
        span.y0 = @intFromFloat(@floor(y0 / tile_px));
        span.y1 = @intFromFloat(@min(rows, @ceil(y1 / tile_px)));
        return span;
    }

    fn updateEffectiveZoom(self: *App) void {
        // Nothing to fit before the document opens (first configure, password prompt).
        if (self.page_sizes.items.len == 0) return;
        const canvas = self.canvasRect();
        var max_w: f64 = 0;
        for (self.page_sizes.items) |sz| {
            const rsz = layout.rotatedPageSize(sz, self.rotation);
            if (rsz.width > max_w) max_w = rsz.width;
        }
        if (max_w <= 0) max_w = 612.0;

        switch (self.zoom_mode) {
            .fit_width => {
                self.zoom = layout.fitWidth(max_w, canvas.w, 24.0);
            },
            .fit_page => {
                const cur_sz = if (self.current_page < self.page_sizes.items.len)
                    self.page_sizes.items[self.current_page]
                else
                    self.page_sizes.items[0];
                const rsz = layout.rotatedPageSize(cur_sz, self.rotation);
                // Never enlarge past 100%: a small page keeps its real size.
                self.zoom = @min(1.0, layout.fitPage(rsz.width, rsz.height, canvas.w, canvas.h, 24.0));
            },
            .manual => {},
        }
        self.zoom = std.math.clamp(self.zoom, 0.2, 5.0);
    }

    fn updateTitle(self: *App) void {
        if (self.path) |p| {
            const raw = std.fs.path.basename(p);
            const base = if (std.unicode.utf8ValidateSlice(raw)) raw else "Document.pdf";
            _ = std.fmt.bufPrintZ(&self.title, "{s} — PDF Viewer ({d}/{d})", .{ base, self.current_page + 1, self.n_pages }) catch {
                _ = std.fmt.bufPrintZ(&self.title, "PDF Viewer", .{}) catch unreachable;
            };
        } else {
            _ = std.fmt.bufPrintZ(&self.title, "PDF Viewer", .{}) catch unreachable;
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

    // Geometry helpers
    pub fn toolbarRect(self: *const App) Rect {
        return .{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = 44.0 };
    }

    pub fn sidebarRect(self: *const App) Rect {
        if (!self.sidebar_open) return .{ .x = 0, .y = 44.0, .w = 0, .h = @max(0, @as(f64, @floatFromInt(self.h)) - 44.0) };
        return .{ .x = 0, .y = 44.0, .w = self.sidebar_w, .h = @max(0, @as(f64, @floatFromInt(self.h)) - 44.0) };
    }

    pub fn canvasRect(self: *const App) Rect {
        const sb_w = if (self.sidebar_open) self.sidebar_w else 0.0;
        return .{
            .x = sb_w,
            .y = 44.0,
            .w = @max(0, @as(f64, @floatFromInt(self.w)) - sb_w),
            .h = @max(0, @as(f64, @floatFromInt(self.h)) - 44.0),
        };
    }

    const page_margin: f64 = 20.0;

    fn contentWidth(self: *const App) f64 {
        const dl = self.doc_layout orelse return 0;
        return dl.max_width + page_margin * 2.0;
    }

    fn maxScrollX(self: *const App) f64 {
        return @max(0.0, self.contentWidth() - self.canvasRect().w);
    }

    /// Left edge of a page in window coordinates. Pages centre while they fit;
    /// once the widest page overflows the canvas they scroll horizontally.
    fn pageX(self: *const App, cv: Rect, p: layout.PageLayout) f64 {
        const dl = self.doc_layout.?;
        if (self.maxScrollX() <= 0) return cv.x + (cv.w - p.logical_width) / 2.0;
        return cv.x + page_margin + (dl.max_width - p.logical_width) / 2.0 - self.scroll_x;
    }

    /// Horizontal scrollbar along the canvas's bottom edge, or null when the
    /// pages fit.
    fn hbar(self: *const App) ?scrollbar.Geometry {
        if (self.doc_layout == null) return null;
        const cv = self.canvasRect();
        const strip = scrollbar.gutter(ui_theme.global.scrollbar_width);
        const track: scrollbar.Rect = .{ .x = @floatCast(cv.x), .y = @as(f32, @floatCast(cv.y + cv.h)) - strip, .w = @floatCast(cv.w), .h = strip };
        return scrollbar.Geometry.compute(.horizontal, track, @floatCast(cv.w), @floatCast(self.contentWidth()), @floatCast(self.scroll_x));
    }

    /// Advances the scrollbar's hover and scroll feedback.
    pub fn stepBar(self: *App, now: i64) void {
        const bar = self.hbar();
        const hovered = if (bar) |b| b.overThumb(@floatCast(self.px), @floatCast(self.py)) else false;
        if (self.hbar_appearance.step(now, self.scroll_x != self.hbar_observed, hovered, self.hbar_drag.active, bar != null)) self.dirty = true;
        self.hbar_observed = self.scroll_x;
    }

    /// How long the event loop may sleep before the scrollbar needs a frame.
    pub fn barTimeout(self: *const App, now: i64) ?u32 {
        if (self.hbar_appearance.active) return 16;
        if (self.hbar_appearance.deadline) |deadline| return @intCast(std.math.clamp(deadline - now, 0, 60_000));
        return null;
    }

    pub fn handleHorizontalScroll(self: *App, delta: f64) void {
        self.scroll_x = std.math.clamp(self.scroll_x + delta * 30.0, 0.0, self.maxScrollX());
        self.dirty = true;
    }

    pub fn searchBarRect(self: *const App) Rect {
        const cv = self.canvasRect();
        return .{
            .x = cv.x + @max(10.0, cv.w - 300.0),
            .y = cv.y + 10.0,
            .w = 290.0,
            .h = 36.0,
        };
    }

    pub fn goToPage(self: *App, page: usize) void {
        if (self.doc_layout == null or self.n_pages == 0) return;
        const p_idx = std.math.clamp(page, 0, self.n_pages - 1);
        self.current_page = p_idx;
        const dl = self.doc_layout.?;
        self.scroll_y = @max(0.0, dl.pages[p_idx].y_offset - 16.0);
        self.anchor = .{ .page_index = p_idx, .rel_y = 0.0 };
        self.updateTitle();
        self.dirty = true;
    }

    pub fn scrollToMatch(self: *App, match_idx: usize) void {
        if (self.search_matches.items.len == 0 or self.doc_layout == null) return;
        self.search_match_idx = match_idx % self.search_matches.items.len;
        const m = self.search_matches.items[self.search_match_idx];
        const dl = self.doc_layout.?;
        if (m.page_index < dl.pages.len) {
            const p = dl.pages[m.page_index];
            const match_y = p.y_offset + m.rect.y * layout.PTS_TO_LOGICAL * self.zoom;
            self.scroll_y = @max(0.0, match_y - 100.0);
            self.current_page = m.page_index;
            self.anchor = layout.anchorFromScroll(dl.pages, self.scroll_y, self.canvasRect().h);
            self.updateTitle();
            self.dirty = true;
        }
    }

    fn executeSearch(self: *App) void {
        const query = self.search_editor.text.items;
        self.search_matches.clearRetainingCapacity();
        self.search_match_idx = 0;
        if (query.len == 0 or self.n_pages == 0) {
            self.dirty = true;
            return;
        }

        const qz = a.dupeZ(u8, query) catch return;
        defer a.free(qz);

        for (0..self.n_pages) |p| {
            self.worker.requestSearch(qz, p, self.generation) catch {};
        }
    }

    pub fn handleScroll(self: *App, delta: f64) void {
        const sb = self.sidebarRect();
        if (self.sidebar_open and sb.contains(self.px, self.py)) {
            const max_sb = if (self.sidebar_layout) |s| @max(0.0, s.total_height - sb.h) else 0.0;
            self.sidebar_scroll_y = std.math.clamp(self.sidebar_scroll_y + delta * 25.0, 0.0, max_sb);
            self.dirty = true;
            return;
        }

        const dl = self.doc_layout orelse return;
        const cv = self.canvasRect();
        const max_scroll = @max(0.0, dl.total_height - cv.h);
        self.scroll_y = std.math.clamp(self.scroll_y + delta * 30.0, 0.0, max_scroll);
        self.anchor = layout.anchorFromScroll(dl.pages, self.scroll_y, cv.h);
        if (self.anchor.page_index != self.current_page) {
            self.current_page = self.anchor.page_index;
            self.updateTitle();
        }
        self.dirty = true;
    }

    pub fn scrollViewport(self: *App, direction: f64) void {
        const dl = self.doc_layout orelse return;
        const cv = self.canvasRect();
        const distance = @max(100.0, cv.h * 0.85) * direction;
        const max_scroll = @max(0.0, dl.total_height - cv.h);
        self.scroll_y = std.math.clamp(self.scroll_y + distance, 0.0, max_scroll);
        self.anchor = layout.anchorFromScroll(dl.pages, self.scroll_y, cv.h);
        if (self.anchor.page_index != self.current_page) {
            self.current_page = self.anchor.page_index;
            self.updateTitle();
        }
        self.dirty = true;
    }

    pub fn handleMotion(self: *App, px: f64, py: f64) void {
        self.px = px;
        self.py = py;

        if (self.hbar_drag.active) {
            if (self.hbar()) |bar| self.scroll_x = self.hbar_drag.offsetAt(bar, @floatCast(px), @floatCast(py));
            self.dirty = true;
            return;
        }

        if (self.dragging_canvas) {
            const dl = self.doc_layout orelse return;
            const cv = self.canvasRect();
            const dy = py - self.drag_start_y;
            const max_scroll = @max(0.0, dl.total_height - cv.h);
            self.scroll_y = std.math.clamp(self.drag_start_scroll_y - dy, 0.0, max_scroll);
            self.scroll_x = std.math.clamp(self.drag_start_scroll_x - (px - self.drag_start_x), 0.0, self.maxScrollX());
            self.anchor = layout.anchorFromScroll(dl.pages, self.scroll_y, cv.h);
            self.current_page = self.anchor.page_index;
            self.updateTitle();
            self.dirty = true;
            return;
        }

        if (self.selection_dragging and self.selection_page != null and self.doc_layout != null) {
            const dl = self.doc_layout.?;
            const cv = self.canvasRect();
            const p_idx = self.selection_page.?;
            if (p_idx < dl.pages.len) {
                const p = dl.pages[p_idx];
                const page_x = self.pageX(cv, p);
                const page_y = cv.y + p.y_offset - self.scroll_y;
                const view_pt = layout.Point{ .x = px - page_x, .y = py - page_y };
                self.selection_end = layout.viewPointToPage(view_pt, p.pts_size, self.rotation, self.zoom);
                const min_x = @min(self.selection_start.x, self.selection_end.x);
                const max_x = @max(self.selection_start.x, self.selection_end.x);
                const min_y = @min(self.selection_start.y, self.selection_end.y);
                const max_y = @max(self.selection_start.y, self.selection_end.y);
                self.selection_box = .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
                self.selection_active = true;
                self.dirty = true;
                return;
            }
        }

        // Link hover detection
        self.hover_link = null;
        if (self.doc_layout) |dl| {
            const cv = self.canvasRect();
            if (cv.contains(px, py)) {
                const vis = layout.findVisiblePages(dl.pages, self.scroll_y, cv.h);
                if (vis) |v| {
                    for (v.start_index..v.end_index + 1) |i| {
                        const p = dl.pages[i];
                        const page_x = self.pageX(cv, p);
                        const page_y = cv.y + p.y_offset - self.scroll_y;
                        if (px >= page_x and px <= page_x + p.logical_width and py >= page_y and py <= page_y + p.logical_height) {
                            if (self.page_contents.get(i)) |content| {
                                const pt = layout.viewPointToPage(.{ .x = px - page_x, .y = py - page_y }, p.pts_size, self.rotation, self.zoom);
                                for (content.links) |lnk| {
                                    if (lnk.area.contains(pt)) {
                                        self.hover_link = lnk;
                                        break;
                                    }
                                }
                            }
                            break;
                        }
                    }
                }
            }
        }

        // Sidebar hover detection
        const sb = self.sidebarRect();
        if (self.sidebar_open and sb.contains(px, py)) {
            if (self.sidebar_tab == .pages and self.sidebar_layout != null) {
                const sbl = self.sidebar_layout.?;
                const vis_sb = layout.findVisibleSidebarCards(sbl.cards, self.sidebar_scroll_y, sb.h);
                var found: ?usize = null;
                if (vis_sb) |vsb| {
                    for (vsb.start_index..vsb.end_index + 1) |i| {
                        const card = sbl.cards[i];
                        const card_y = sb.y + card.y_offset - self.sidebar_scroll_y;
                        if (py >= card_y and py <= card_y + card.card_h) {
                            found = i;
                            break;
                        }
                    }
                }
                if (self.hover_thumb != found) {
                    self.hover_thumb = found;
                    self.dirty = true;
                }
            } else if (self.sidebar_tab == .outline and self.outline != null) {
                const row_h = 28.0;
                const rel_y = py - (sb.y + 40.0) + self.sidebar_scroll_y;
                if (rel_y >= 0) {
                    const idx: usize = @intFromFloat(rel_y / row_h);
                    if (idx < self.outline.?.len and self.hover_outline != idx) {
                        self.hover_outline = idx;
                        self.dirty = true;
                    }
                }
            }
        } else {
            if (self.hover_thumb != null or self.hover_outline != null) {
                self.hover_thumb = null;
                self.hover_outline = null;
                self.dirty = true;
            }
        }
    }

    pub fn handleButton(self: *App, button: u32, pressed: bool) void {
        if (button == 0x110) { // Left click
            if (pressed) {
                if (self.dialog != .none) {
                    self.handleDialogClick();
                    return;
                }

                if (self.search_open and self.searchBarRect().contains(self.px, self.py)) {
                    self.handleSearchBarClick();
                    return;
                }

                if (self.toolbarRect().contains(self.px, self.py)) {
                    self.handleToolbarClick();
                    return;
                }

                if (self.sidebar_open and self.sidebarRect().contains(self.px, self.py)) {
                    self.handleSidebarClick();
                    return;
                }

                // Canvas click
                const cv = self.canvasRect();
                if (cv.contains(self.px, self.py) and self.doc_layout != null) {
                    if (self.hbar()) |bar| {
                        const scroll_x: f32 = @floatCast(self.scroll_x);
                        if (scrollbar.press(bar, @floatCast(self.px), @floatCast(self.py), scroll_x)) |action| {
                            switch (action) {
                                .grab => self.hbar_drag.begin(bar, @floatCast(self.px), @floatCast(self.py), scroll_x),
                                .page => |offset| self.scroll_x = offset,
                            }
                            self.dirty = true;
                            return;
                        }
                    }
                    // Check if clicked a hyperlink!
                    if (self.hover_link) |lnk| {
                        switch (lnk.target) {
                            .goto_page => |target| self.goToPage(target),
                            .uri => |u| {
                                if (!std.mem.startsWith(u8, u, "http://") and !std.mem.startsWith(u8, u, "https://")) return;
                                const copy = a.dupeZ(u8, u) catch return;
                                if (self.clipboard_text) |old| a.free(old);
                                self.clipboard_text = copy;
                                self.clipboard_request = true;
                                self.dialog = .information;
                                self.error_message = "Link copied. Paste it into your browser.";
                                self.dirty = true;
                            },
                        }
                        return;
                    }

                    // Start text selection or drag pan
                    const dl = self.doc_layout.?;
                    const vis = layout.findVisiblePages(dl.pages, self.scroll_y, cv.h);
                    if (vis) |v| {
                        for (v.start_index..v.end_index + 1) |i| {
                            const p = dl.pages[i];
                            const page_x = self.pageX(cv, p);
                            const page_y = cv.y + p.y_offset - self.scroll_y;
                            if (self.px >= page_x and self.px <= page_x + p.logical_width and self.py >= page_y and self.py <= page_y + p.logical_height) {
                                const pt = layout.viewPointToPage(.{ .x = self.px - page_x, .y = self.py - page_y }, p.pts_size, self.rotation, self.zoom);
                                self.selection_dragging = true;
                                self.selection_page = i;
                                self.selection_start = pt;
                                self.selection_end = pt;
                                self.selection_box = null;
                                self.selection_active = false;
                                return;
                            }
                        }
                    }

                    // Otherwise middle/left pan
                    self.dragging_canvas = true;
                    self.drag_start_y = self.py;
                    self.drag_start_scroll_y = self.scroll_y;
                    self.drag_start_x = self.px;
                    self.drag_start_scroll_x = self.scroll_x;
                }
            } else {
                // Button release
                self.dragging_canvas = false;
                if (self.hbar_drag.active) {
                    self.hbar_drag.end();
                    self.dirty = true;
                }
                if (self.selection_dragging) {
                    self.selection_dragging = false;
                    if (self.selection_box != null and self.selection_box.?.w > 2.0 and self.selection_box.?.h > 2.0) {
                        self.selection_active = true;
                        // Build text for clipboard
                        if (self.selection_page) |p_idx| {
                            if (self.page_contents.get(p_idx)) |content| {
                                if (content.text) |txt| {
                                    if (self.selected_text) |t| a.free(t);
                                    self.selected_text = a.dupeZ(u8, txt) catch null;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    fn handleToolbarClick(self: *App) void {
        // Page number editor field click: x=124..204
        if (self.px >= 124.0 and self.px <= 204.0 and self.py >= 6.0 and self.py <= 38.0) {
            self.focus = .page_number;
            self.editor.text.clearRetainingCapacity();
            var buf: [16]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{self.current_page + 1}) catch "";
            self.editor.insert(a, str) catch {};
            self.dirty = true;
            return;
        }

        for (toolbar_buttons) |item| {
            if (self.px >= item.x and self.px <= item.x + item.w and self.py >= toolbar_button_y and self.py <= toolbar_button_y + toolbar_button_h) {
                self.triggerAction(item.act);
                return;
            }
        }
    }

    fn handleSidebarClick(self: *App) void {
        const sb = self.sidebarRect();
        // Check top tabs
        if (self.py >= sb.y and self.py <= sb.y + 36.0) {
            const half = sb.w / 2.0;
            if (self.px < half) {
                self.sidebar_tab = .pages;
            } else {
                self.sidebar_tab = .outline;
            }
            self.dirty = true;
            return;
        }

        if (self.sidebar_tab == .pages) {
            if (self.hover_thumb) |idx| {
                self.goToPage(idx);
            }
        } else if (self.sidebar_tab == .outline and self.outline != null) {
            if (self.hover_outline) |idx| {
                if (idx < self.outline.?.len) {
                    if (self.outline.?[idx].target_page) |target| {
                        self.goToPage(target);
                    }
                }
            }
        }
    }

    fn handleSearchBarClick(self: *App) void {
        const sr = self.searchBarRect();
        const close_x = sr.x + sr.w - 28.0;
        const next_x = close_x - 28.0;
        const prev_x = next_x - 28.0;

        if (self.px >= close_x and self.px <= sr.x + sr.w) {
            self.search_open = false;
            self.focus = .none;
            self.dirty = true;
        } else if (self.px >= next_x and self.px < close_x) {
            if (self.search_matches.items.len > 0) {
                self.scrollToMatch(self.search_match_idx + 1);
            }
        } else if (self.px >= prev_x and self.px < next_x) {
            if (self.search_matches.items.len > 0) {
                self.scrollToMatch(if (self.search_match_idx == 0) self.search_matches.items.len - 1 else self.search_match_idx - 1);
            }
        } else {
            self.focus = .search;
            self.dirty = true;
        }
    }

    fn handleDialogClick(self: *App) void {
        const dw: f64 = 440;
        const dh: f64 = 190;
        const dx = (@as(f64, @floatFromInt(self.w)) - dw) / 2.0;
        const dy = (@as(f64, @floatFromInt(self.h)) - dh) / 2.0;

        // Cancel button: x = dx + dw - 180..dx + dw - 100
        if (self.px >= dx + dw - 180.0 and self.px <= dx + dw - 100.0 and self.py >= dy + dh - 46.0 and self.py <= dy + dh - 14.0) {
            self.dialog = .none;
            self.focus = .none;
            self.password_input.clear();
            self.dirty = true;
            return;
        }

        // Action button: x = dx + dw - 90..dx + dw - 20
        if (self.px >= dx + dw - 90.0 and self.px <= dx + dw - 20.0 and self.py >= dy + dh - 46.0 and self.py <= dy + dh - 14.0) {
            if (self.dialog == .password) self.submitPassword() else self.dialog = .none;
            self.dirty = true;
        }
    }

    pub fn triggerAction(self: *App, act: Action) void {
        switch (act) {
            .toggle_sidebar => {
                self.sidebar_open = !self.sidebar_open;
                if (self.zoom_mode != .manual) self.updateEffectiveZoom();
                self.relayout();
            },
            .prev_page => {
                if (self.current_page > 0) self.goToPage(self.current_page - 1);
            },
            .next_page => {
                if (self.current_page + 1 < self.n_pages) self.goToPage(self.current_page + 1);
            },
            .zoom_out => self.zoomBy(1.0 / 1.2),
            .zoom_in => self.zoomBy(1.2),
            .fit_width => self.setZoomMode(.fit_width),
            .fit_page => self.setZoomMode(.fit_page),
            .rotate => {
                self.rotation = self.rotation.rotateClockwise();
                if (self.zoom_mode != .manual) self.updateEffectiveZoom();
                self.relayout();
            },
            .open_dialog => {
                self.dialog = .information;
                self.focus = .none;
                self.error_message = "Open another PDF from Files in a new window.";
            },
            .find_toggle => {
                self.search_open = !self.search_open;
                if (self.search_open) {
                    self.focus = .search;
                } else {
                    self.focus = .none;
                }
            },
            .find_prev => {
                if (self.search_matches.items.len > 0) {
                    self.scrollToMatch(if (self.search_match_idx == 0) self.search_matches.items.len - 1 else self.search_match_idx - 1);
                }
            },
            .find_next => {
                if (self.search_matches.items.len > 0) {
                    self.scrollToMatch(self.search_match_idx + 1);
                }
            },
            .find_close => {
                self.search_open = false;
                self.focus = .none;
            },
            .print => if (self.n_pages > 0 and !self.loading) {
                self.print_request = true;
            },
        }
        self.dirty = true;
    }

    /// Reports a print helper problem in the information dialog.
    pub fn showMessage(self: *App, message: []const u8) void {
        self.dialog = .information;
        self.focus = .none;
        self.error_message = message;
        self.dirty = true;
    }

    pub fn handleKey(self: *App, sym: u32, utf8: []const u8) void {
        // Ctrl+W closes immediately regardless of focus
        if (self.ctrl and (sym == 'w' or sym == 'W')) {
            self.closed = true;
            return;
        }

        // Esc clears modal dialogs, search, or selection
        if (sym == 0xff1b) { // Escape
            if (self.dialog != .none) {
                self.dialog = .none;
                self.focus = .none;
                self.password_input.clear();
            } else if (self.search_open) {
                self.search_open = false;
                self.focus = .none;
            } else if (self.selection_active) {
                self.selection_active = false;
                self.selection_box = null;
            }
            self.dirty = true;
            return;
        }

        // Active text fields
        switch (self.focus) {
            .page_number => {
                if (sym == 0xff0d) { // Enter
                    const txt = self.editor.text.items;
                    if (std.fmt.parseInt(usize, txt, 10)) |num| {
                        if (num >= 1) self.goToPage(num - 1);
                    } else |_| {}
                    self.focus = .none;
                    self.dirty = true;
                    return;
                }
                self.editor.key(a, sym, utf8, self.ctrl, self.shift, self.alt);
                self.dirty = true;
                return;
            },
            .password => {
                if (sym == 0xff0d) { // Enter
                    self.submitPassword();
                    return;
                } else if (sym == 0xff08) { // Backspace
                    self.password_input.backspace();
                    self.dirty = true;
                    return;
                } else if (utf8.len > 0) {
                    _ = self.password_input.insert(utf8);
                    self.dirty = true;
                    return;
                }
                return;
            },
            .search => {
                if (sym == 0xff0d) { // Enter
                    if (self.shift) {
                        self.triggerAction(.find_prev);
                    } else {
                        self.triggerAction(.find_next);
                    }
                    return;
                }
                self.search_editor.key(a, sym, utf8, self.ctrl, self.shift, self.alt);
                self.executeSearch();
                self.dirty = true;
                return;
            },
            .none => {},
        }

        // Global / reader shortcuts
        if (self.ctrl) {
            switch (sym) {
                'w', 'W' => self.closed = true,
                'o', 'O' => self.triggerAction(.open_dialog),
                'f', 'F' => self.triggerAction(.find_toggle),
                'p', 'P' => self.triggerAction(.print),
                'l', 'L' => {
                    self.focus = .page_number;
                    self.editor.text.clearRetainingCapacity();
                    var buf: [16]u8 = undefined;
                    const str = std.fmt.bufPrint(&buf, "{d}", .{self.current_page + 1}) catch "";
                    self.editor.insert(a, str) catch {};
                    self.dirty = true;
                },
                'c', 'C' => {
                    if (self.selected_text) |txt| {
                        if (self.clipboard_text) |c_prev| a.free(c_prev);
                        self.clipboard_text = a.dupeZ(u8, txt) catch null;
                        self.clipboard_request = true;
                    }
                },
                0xff50 => self.goToPage(0), // Ctrl+Home
                0xff57 => if (self.n_pages > 0) self.goToPage(self.n_pages - 1), // Ctrl+End
                '+', '=' => self.triggerAction(.zoom_in),
                '-', '_' => self.triggerAction(.zoom_out),
                else => {},
            }
            return;
        }

        switch (sym) {
            'r', 'R' => self.triggerAction(.rotate),
            '+', '=' => self.triggerAction(.zoom_in),
            '-' => self.triggerAction(.zoom_out),
            '0' => self.triggerAction(.fit_width),
            '9' => self.triggerAction(.fit_page),
            0xffbe => { // F3
                if (self.shift) {
                    self.triggerAction(.find_prev);
                } else {
                    self.triggerAction(.find_next);
                }
            },
            0xff55 => self.triggerAction(.prev_page), // PageUp
            0xff56 => self.triggerAction(.next_page), // PageDown
            ' ' => {
                if (self.shift) {
                    self.scrollViewport(-1.0);
                } else {
                    self.scrollViewport(1.0);
                }
            },
            // Left/Right pan while the pages overflow horizontally, otherwise turn pages.
            0xff51 => if (self.maxScrollX() > 0) self.handleHorizontalScroll(-2.0) else self.triggerAction(.prev_page),
            0xff53 => if (self.maxScrollX() > 0) self.handleHorizontalScroll(2.0) else self.triggerAction(.next_page),
            'p', 'P' => self.triggerAction(.prev_page),
            'n', 'N' => self.triggerAction(.next_page),
            0xff52 => self.handleScroll(-2.0), // Up arrow
            0xff54 => self.handleScroll(2.0), // Down arrow
            0xff50 => self.goToPage(0), // Home
            0xff57 => if (self.n_pages > 0) self.goToPage(self.n_pages - 1), // End
            else => {},
        }
    }

    pub fn keyRepeats(self: *const App, sym: u32, _: []const u8) bool {
        if (self.focus != .none) return false;
        return switch (sym) {
            0xff51, 0xff52, 0xff53, 0xff54, 0xff55, 0xff56, ' ', '+', '-', '=', 0xffbe => true,
            else => false,
        };
    }

    pub fn cancelDrag(self: *App) void {
        self.dragging_canvas = false;
        self.hbar_drag.end();
        self.selection_dragging = false;
    }

    pub fn cursorName(self: *const App) [*:0]const u8 {
        if (self.hover_link != null) return "pointer";
        if (self.selection_active or self.selection_dragging) return "text";
        if (self.focus != .none) return "text";
        return "default";
    }

    pub fn render(self: *App, cr: *c.api.cairo_t) void {
        // Render reading canvas
        self.renderCanvas(cr);

        // Render sidebar
        if (self.sidebar_open) {
            self.renderSidebar(cr);
        }

        // Render top toolbar
        self.renderToolbar(cr);

        // Render in-page search bar
        if (self.search_open) {
            self.renderSearchBar(cr);
        }

        // Render modal dialog
        if (self.dialog != .none) {
            self.renderDialog(cr);
        }
    }

    fn renderCanvas(self: *App, cr: *c.api.cairo_t) void {
        const cv = self.canvasRect();
        if (cv.w <= 0 or cv.h <= 0) return;

        c.api.cairo_save(cr);
        defer c.api.cairo_restore(cr);

        c.api.cairo_rectangle(cr, cv.x, cv.y, cv.w, cv.h);
        c.api.cairo_clip(cr);

        // Canvas neutral background
        shell_ui.setSource(cr, ui_theme.global.app_bg);
        c.api.cairo_paint(cr);

        if (self.loading) {
            shell_ui.setSource(cr, ui_theme.global.window_fg);
            const msg = "Opening document...";
            shell_ui.drawText(cr, msg, cv.x + @max(20.0, (cv.w - shell_ui.measureText(cr, msg, shell_ui.textSize(), false)) / 2.0), cv.y + cv.h / 2.0, shell_ui.textSize(), false);
            return;
        }

        if (self.doc_layout == null or self.n_pages == 0) {
            shell_ui.setSource(cr, ui_theme.global.window_fg);
            const msg = if (self.error_message) |m| m else "No document open. Click 'Open' or press Ctrl+O.";
            shell_ui.drawText(cr, msg, cv.x + @max(20.0, (cv.w - shell_ui.measureText(cr, msg, shell_ui.textSize(), false)) / 2.0), cv.y + cv.h / 2.0, shell_ui.textSize(), false);
            return;
        }

        const dl = self.doc_layout.?;
        const vis = layout.findVisiblePages(dl.pages, self.scroll_y, cv.h);
        if (vis == null) return;

        const effective_scale = self.zoom * @as(f64, @floatFromInt(self.scale));

        for (vis.?.start_index..vis.?.end_index + 1) |i| {
            const p = dl.pages[i];
            const page_x = self.pageX(cv, p);
            const page_y = cv.y + p.y_offset - self.scroll_y;

            // Page drop shadow
            shell_ui.setSource(cr, ui_theme.global.pdf_page_shadow);
            c.api.cairo_rectangle(cr, page_x + 2.0, page_y + 3.0, p.logical_width, p.logical_height);
            c.api.cairo_fill(cr);

            // White paper background
            c.api.cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
            c.api.cairo_rectangle(cr, page_x, page_y, p.logical_width, p.logical_height);
            c.api.cairo_fill(cr);

            // Check page cache
            var painted_pixels = false;
            if (self.tileSpan(cv, p)) |span| {
                var tiles: [64]?*cache.CachedPage = undefined;
                var n: usize = 0;
                var complete = true;
                for (span.y0..span.y1) |ty| for (span.x0..span.x1) |tx| {
                    const pk = cache.PageKey.init(self.generation, i, effective_scale, self.rotation, span.key(tx, ty));
                    const cp = self.page_cache.get(pk);
                    complete = complete and cp != null;
                    if (n < tiles.len) {
                        tiles[n] = cp;
                        n += 1;
                    }
                };
                // An older whole-page raster stands in under missing tiles.
                if (!complete) {
                    if (self.page_cache.findBest(self.generation, i, self.rotation)) |best| {
                        self.drawCachedSurface(cr, best, page_x, page_y, p.logical_width, p.logical_height);
                        painted_pixels = true;
                    }
                }
                n = 0;
                for (span.y0..span.y1) |ty| for (span.x0..span.x1) |tx| {
                    if (n >= tiles.len) break;
                    defer n += 1;
                    const cp = tiles[n] orelse continue;
                    const tk = span.key(tx, ty);
                    self.drawRaster(cr, cp, page_x, page_y, @floatFromInt(tk.x), @floatFromInt(tk.y));
                    painted_pixels = true;
                };
            } else {
                const pk = cache.PageKey.init(self.generation, i, effective_scale, self.rotation, null);
                if (self.page_cache.get(pk)) |cp| {
                    self.drawRaster(cr, cp, page_x, page_y, 0, 0);
                    painted_pixels = true;
                }
            }

            // Fallback: draw best cached scale while sharp zoom renders!
            if (!painted_pixels) {
                if (self.page_cache.findBest(self.generation, i, self.rotation)) |best| {
                    self.drawCachedSurface(cr, best, page_x, page_y, p.logical_width, p.logical_height);
                } else {
                    // Placeholder while page is rendering
                    shell_ui.setSource(cr, ui_theme.global.pdf_loading);
                    var buf: [32]u8 = undefined;
                    const loading_msg = std.fmt.bufPrint(&buf, "Rendering page {d}...", .{i + 1}) catch "";
                    shell_ui.drawText(cr, loading_msg, page_x + @max(20.0, (p.logical_width - shell_ui.measureText(cr, loading_msg, shell_ui.textSize(), false)) / 2.0), page_y + p.logical_height / 2.0, shell_ui.textSize(), false);
                }
            }

            // Page border
            shell_ui.setSource(cr, ui_theme.global.pdf_page_border);
            c.api.cairo_set_line_width(cr, 1.0);
            c.api.cairo_rectangle(cr, page_x, page_y, p.logical_width, p.logical_height);
            c.api.cairo_stroke(cr);

            // Paint search matches on this page
            if (self.search_open) {
                for (self.search_matches.items, 0..) |m, m_idx| {
                    if (m.page_index == i) {
                        const vr = layout.pageRectToView(m.rect, p.pts_size, self.rotation, self.zoom);
                        const is_active = m_idx == self.search_match_idx;
                        if (is_active) {
                            shell_ui.setSource(cr, ui_theme.global.pdf_search_match_active);
                        } else {
                            shell_ui.setSource(cr, ui_theme.global.pdf_search_match);
                        }
                        c.api.cairo_rectangle(cr, page_x + vr.x, page_y + vr.y, vr.w, vr.h);
                        c.api.cairo_fill(cr);
                    }
                }
            }

            // Paint text selection highlight on this page
            if (self.selection_page == i and self.selection_box != null) {
                const sbox = self.selection_box.?;
                const vr = layout.pageRectToView(sbox, p.pts_size, self.rotation, self.zoom);
                shell_ui.setSource(cr, ui_theme.shellPalette().selectionColor());
                c.api.cairo_rectangle(cr, page_x + vr.x, page_y + vr.y, vr.w, vr.h);
                c.api.cairo_fill(cr);
            }
        }

        if (self.hbar()) |bar| shell_ui.drawScrollbar(cr, scrollbar.look(bar, self.hbar_appearance, ui_theme.global.scrollbar_width, ui_theme.shellPalette()));
    }

    /// Draws a raster at the current zoom one pixel per device pixel, with
    /// the page origin on the device grid: resampling would soften text and
    /// leave seams between tiles. `x`, `y` place it within the page raster.
    fn drawRaster(self: *App, cr: *c.api.cairo_t, cp: *cache.CachedPage, page_x: f64, page_y: f64, x: f64, y: f64) void {
        const s: f64 = @floatFromInt(self.scale);
        const origin_x = @round(page_x * s);
        const origin_y = @round(page_y * s);
        self.drawCachedSurface(cr, cp, (origin_x + x) / s, (origin_y + y) / s, @as(f64, @floatFromInt(cp.width)) / s, @as(f64, @floatFromInt(cp.height)) / s);
    }

    fn drawCachedSurface(self: *App, cr: *c.api.cairo_t, cp: *cache.CachedPage, x: f64, y: f64, target_w: f64, target_h: f64) void {
        _ = self;
        const surf = c.api.cairo_image_surface_create_for_data(
            @ptrCast(cp.pixels.ptr),
            c.api.CAIRO_FORMAT_ARGB32,
            cp.width,
            cp.height,
            cp.stride,
        );
        if (surf == null or c.api.cairo_surface_status(surf) != c.api.CAIRO_STATUS_SUCCESS) return;
        defer c.api.cairo_surface_destroy(surf);

        c.api.cairo_save(cr);
        defer c.api.cairo_restore(cr);

        c.api.cairo_translate(cr, x, y);
        const sx = target_w / @as(f64, @floatFromInt(cp.width));
        const sy = target_h / @as(f64, @floatFromInt(cp.height));
        c.api.cairo_scale(cr, sx, sy);
        c.api.cairo_set_source_surface(cr, surf, 0, 0);
        c.api.cairo_paint(cr);
    }

    fn renderSidebar(self: *App, cr: *c.api.cairo_t) void {
        const sb = self.sidebarRect();
        c.api.cairo_save(cr);
        defer c.api.cairo_restore(cr);

        c.api.cairo_rectangle(cr, sb.x, sb.y, sb.w, sb.h);
        c.api.cairo_clip(cr);

        // Sidebar background
        shell_ui.setSource(cr, ui_theme.global.app_sidebar);
        c.api.cairo_paint(cr);

        // Top tabs: [ Pages ] [ Outline ]
        const tab_w = sb.w / 2.0;
        const tab_h = 32.0;
        shell_ui.setSource(cr, if (self.sidebar_tab == .pages) ui_theme.global.app_nav_selected else ui_theme.global.app_item);
        c.api.cairo_rectangle(cr, sb.x + 4.0, sb.y + 4.0, tab_w - 6.0, tab_h - 8.0);
        c.api.cairo_fill(cr);

        shell_ui.setSource(cr, if (self.sidebar_tab == .outline) ui_theme.global.app_nav_selected else ui_theme.global.app_item);
        c.api.cairo_rectangle(cr, sb.x + tab_w + 2.0, sb.y + 4.0, tab_w - 6.0, tab_h - 8.0);
        c.api.cairo_fill(cr);

        // The selected tab is told apart by its fill, not by a dimmer label.
        shell_ui.setSource(cr, ui_theme.global.window_fg);
        shell_ui.drawText(cr, "Pages", sb.x + (tab_w - shell_ui.measureText(cr, "Pages", shell_ui.textSize(), true)) / 2.0, sb.y + 20.0, shell_ui.textSize(), true);
        shell_ui.drawText(cr, "Outline", sb.x + tab_w + (tab_w - shell_ui.measureText(cr, "Outline", shell_ui.textSize(), true)) / 2.0, sb.y + 20.0, shell_ui.textSize(), true);

        // Divider under tabs
        shell_ui.setSource(cr, ui_theme.global.app_divider);
        c.api.cairo_set_line_width(cr, 1.0);
        c.api.cairo_move_to(cr, sb.x, sb.y + tab_h);
        c.api.cairo_line_to(cr, sb.x + sb.w, sb.y + tab_h);
        c.api.cairo_stroke(cr);

        // Right vertical divider
        c.api.cairo_move_to(cr, sb.x + sb.w - 0.5, sb.y);
        c.api.cairo_line_to(cr, sb.x + sb.w - 0.5, sb.y + sb.h);
        c.api.cairo_stroke(cr);

        if (self.sidebar_tab == .pages) {
            self.renderThumbnailCards(cr);
        } else {
            self.renderOutlineList(cr);
        }
    }

    fn renderThumbnailCards(self: *App, cr: *c.api.cairo_t) void {
        const sb = self.sidebarRect();
        const sbl = self.sidebar_layout orelse return;
        const vis = layout.findVisibleSidebarCards(sbl.cards, self.sidebar_scroll_y, sb.h - 36.0);
        const vis_cards = vis orelse return;

        const card_w = self.sidebar_w - 32.0;

        for (vis_cards.start_index..vis_cards.end_index + 1) |i| {
            const card = sbl.cards[i];
            const card_x = sb.x + 16.0;
            const card_y = sb.y + 36.0 + card.y_offset - self.sidebar_scroll_y;

            // Card shadow
            shell_ui.setSource(cr, ui_theme.global.pdf_thumbnail_shadow);
            c.api.cairo_rectangle(cr, card_x + 1.0, card_y + 2.0, card_w, card.card_h);
            c.api.cairo_fill(cr);

            // White thumbnail paper
            shell_ui.setSource(cr, ui_theme.global.pdf_thumbnail_bg);
            c.api.cairo_rectangle(cr, card_x, card_y, card_w, card.card_h);
            c.api.cairo_fill(cr);

            // Render thumbnail from cache
            const tk = cache.ThumbKey{
                .generation = self.generation,
                .page_index = i,
                .rotation = self.rotation,
                .card_w = @intFromFloat(card_w),
                .card_h = @intFromFloat(card.card_h),
            };
            if (self.thumb_cache.get(tk)) |ct| {
                const surf = c.api.cairo_image_surface_create_for_data(
                    @ptrCast(ct.pixels.ptr),
                    c.api.CAIRO_FORMAT_ARGB32,
                    ct.width,
                    ct.height,
                    ct.stride,
                );
                if (surf != null and c.api.cairo_surface_status(surf) == c.api.CAIRO_STATUS_SUCCESS) {
                    defer c.api.cairo_surface_destroy(surf);
                    c.api.cairo_save(cr);
                    c.api.cairo_translate(cr, card_x, card_y);
                    const sx = card_w / @as(f64, @floatFromInt(ct.width));
                    const sy = card.card_h / @as(f64, @floatFromInt(ct.height));
                    c.api.cairo_scale(cr, sx, sy);
                    c.api.cairo_set_source_surface(cr, surf, 0, 0);
                    c.api.cairo_paint(cr);
                    c.api.cairo_restore(cr);
                }
            }

            // Highlight border if active or hover
            const is_current = i == self.current_page;
            const is_hover = self.hover_thumb == i;
            if (is_current) {
                shell_ui.setSource(cr, ui_theme.shellPalette().accent);
                c.api.cairo_set_line_width(cr, 2.5);
            } else if (is_hover) {
                shell_ui.setSource(cr, ui_theme.global.window_dim);
                c.api.cairo_set_line_width(cr, 1.5);
            } else {
                shell_ui.setSource(cr, ui_theme.global.pdf_page_border);
                c.api.cairo_set_line_width(cr, 1.0);
            }
            c.api.cairo_rectangle(cr, card_x, card_y, card_w, card.card_h);
            c.api.cairo_stroke(cr);

            // Page number badge
            var badge: [16]u8 = undefined;
            const badge_str = std.fmt.bufPrint(&badge, "{d}", .{i + 1}) catch "";
            const bw = shell_ui.measureText(cr, badge_str, shell_ui.textSize(), is_current);
            shell_ui.setSource(cr, ui_theme.global.window_fg);
            shell_ui.drawText(cr, badge_str, card_x + (card_w - bw) / 2.0, card_y + card.card_h + 15.0, shell_ui.textSize(), is_current);
        }
    }

    fn renderOutlineList(self: *App, cr: *c.api.cairo_t) void {
        const sb = self.sidebarRect();
        const items = self.outline orelse {
            shell_ui.setSource(cr, ui_theme.global.window_fg);
            shell_ui.drawText(cr, "No outline in document", sb.x + 16.0, sb.y + 60.0, shell_ui.textSize(), false);
            return;
        };

        const row_h = 28.0;
        for (items, 0..) |it, idx| {
            const row_y = sb.y + 40.0 + @as(f64, @floatFromInt(idx)) * row_h - self.sidebar_scroll_y;
            if (row_y + row_h < sb.y + 36.0 or row_y > sb.y + sb.h) continue;

            const is_hover = self.hover_outline == idx;
            if (is_hover) {
                shell_ui.setSource(cr, ui_theme.global.app_item_hover);
                c.api.cairo_rectangle(cr, sb.x + 4.0, row_y, sb.w - 8.0, row_h);
                c.api.cairo_fill(cr);
            }

            const indent = @as(f64, @floatFromInt(it.level)) * 12.0;
            shell_ui.setSource(cr, ui_theme.global.window_fg);
            c.api.cairo_save(cr);
            c.api.cairo_rectangle(cr, sb.x + 12.0 + indent, row_y, @max(0.0, sb.w - 24.0 - indent), row_h);
            c.api.cairo_clip(cr);
            shell_ui.drawText(cr, it.title, sb.x + 12.0 + indent, row_y + 18.0, shell_ui.textSize(), is_hover);
            c.api.cairo_restore(cr);
        }
    }

    fn renderToolbar(self: *App, cr: *c.api.cairo_t) void {
        const tb = self.toolbarRect();

        // Background & bottom border
        shell_ui.setSource(cr, ui_theme.global.app_toolbar);
        c.api.cairo_rectangle(cr, tb.x, tb.y, tb.w, tb.h);
        c.api.cairo_fill(cr);

        shell_ui.setSource(cr, ui_theme.global.app_divider);
        c.api.cairo_set_line_width(cr, 1.0);
        c.api.cairo_move_to(cr, tb.x, tb.h - 0.5);
        c.api.cairo_line_to(cr, tb.x + tb.w, tb.h - 0.5);
        c.api.cairo_stroke(cr);

        for (toolbar_buttons) |item| {
            const x = item.x;
            const y = toolbar_button_y;
            const w = item.w;
            const h = toolbar_button_h;
            switch (item.act) {
                .toggle_sidebar => self.renderButtonIcon(cr, x, y, w, h, .view_grid, "Toggle sidebar"),
                .prev_page => self.renderButtonText(cr, x, y, w, h, "◀"),
                .next_page => self.renderButtonText(cr, x, y, w, h, "▶"),
                .zoom_out => self.renderButtonText(cr, x, y, w, h, "−"),
                .zoom_in => self.renderButtonText(cr, x, y, w, h, "+"),
                .fit_width => self.renderToggle(cr, x, y, w, h, "Fit width", self.zoom_mode == .fit_width),
                .fit_page => self.renderToggle(cr, x, y, w, h, "Fit page", self.zoom_mode == .fit_page),
                .rotate => self.renderButtonIcon(cr, x, y, w, h, .rotate, "Rotate"),
                .find_toggle => self.renderButtonText(cr, x, y, w, h, if (self.search_open) "Find ▲" else "Find"),
                .print => self.renderButtonIcon(cr, x, y, w, h, .print, "Print"),
                else => {},
            }
        }

        // Page number field: [ 3 ] / 42
        var pbuf: [32]u8 = undefined;
        const cur_str = if (self.focus == .page_number)
            self.editor.text.items
        else
            std.fmt.bufPrint(&pbuf, "{d}", .{self.current_page + 1}) catch "1";

        shell_ui.setSource(cr, ui_theme.global.field_bg);
        c.api.cairo_rectangle(cr, 126.0, 8.0, 48.0, 28.0);
        c.api.cairo_fill(cr);

        shell_ui.setSource(cr, if (self.focus == .page_number) ui_theme.shellPalette().fieldFocusColor() else ui_theme.global.field_border);
        c.api.cairo_set_line_width(cr, 1.0);
        c.api.cairo_rectangle(cr, 126.0, 8.0, 48.0, 28.0);
        c.api.cairo_stroke(cr);

        shell_ui.setSource(cr, ui_theme.global.window_fg);
        const cw = shell_ui.measureText(cr, cur_str, shell_ui.textSize(), true);
        shell_ui.drawText(cr, cur_str, 126.0 + (48.0 - cw) / 2.0, 26.0, shell_ui.textSize(), true);

        var total_buf: [32]u8 = undefined;
        const total_str = std.fmt.bufPrint(&total_buf, "/ {d}", .{self.n_pages}) catch "";
        shell_ui.setSource(cr, ui_theme.global.window_fg);
        shell_ui.drawText(cr, total_str, 180.0, 26.0, shell_ui.textSize(), false);

        // Zoom level between − and +
        var zbuf: [16]u8 = undefined;
        const zstr = std.fmt.bufPrint(&zbuf, "{d}%", .{@as(i32, @intFromFloat(@round(self.zoom * 100.0)))}) catch "100%";
        const zw = shell_ui.measureText(cr, zstr, shell_ui.textSize(), true);
        shell_ui.drawText(cr, zstr, 246.0 + (36.0 - zw) / 2.0, 26.0, shell_ui.textSize(), true);
    }

    fn renderSearchBar(self: *App, cr: *c.api.cairo_t) void {
        const sr = self.searchBarRect();

        // Search bar card background & shadow
        shell_ui.setSource(cr, ui_theme.global.pdf_search_shadow);
        c.api.cairo_rectangle(cr, sr.x + 2.0, sr.y + 2.0, sr.w, sr.h);
        c.api.cairo_fill(cr);

        shell_ui.setSource(cr, ui_theme.global.window_bg);
        c.api.cairo_rectangle(cr, sr.x, sr.y, sr.w, sr.h);
        c.api.cairo_fill(cr);

        shell_ui.setSource(cr, ui_theme.global.field_border);
        c.api.cairo_set_line_width(cr, 1.0);
        c.api.cairo_rectangle(cr, sr.x, sr.y, sr.w, sr.h);
        c.api.cairo_stroke(cr);

        // Search input text
        const qtxt = self.search_editor.text.items;
        // Half-strength white, not the shell's blue-grey `faint`.
        const fg = ui_theme.global.window_fg;
        shell_ui.setSource(cr, if (qtxt.len > 0) fg else .{ fg[0], fg[1], fg[2], fg[3] * 0.5 });
        const display_txt = if (qtxt.len > 0) qtxt else "Find in document...";
        c.api.cairo_save(cr);
        c.api.cairo_rectangle(cr, sr.x + 10.0, sr.y, sr.w - 110.0, sr.h);
        c.api.cairo_clip(cr);
        shell_ui.drawText(cr, display_txt, sr.x + 10.0, sr.y + 22.0, shell_ui.textSize(), qtxt.len > 0);
        c.api.cairo_restore(cr);

        // Result count
        var cbuf: [32]u8 = undefined;
        const count_str = if (self.search_matches.items.len > 0)
            std.fmt.bufPrint(&cbuf, "{d}/{d}", .{ self.search_match_idx + 1, self.search_matches.items.len }) catch ""
        else if (qtxt.len > 0)
            "0"
        else
            "";
        shell_ui.setSource(cr, ui_theme.global.window_fg);
        shell_ui.drawText(cr, count_str, sr.x + sr.w - 95.0, sr.y + 22.0, shell_ui.statusSize(), false);

        // Prev, Next, Close glyphs
        shell_ui.setSource(cr, ui_theme.global.window_fg);
        shell_ui.drawText(cr, "▲", sr.x + sr.w - 55.0, sr.y + 22.0, 11, true);
        shell_ui.drawText(cr, "▼", sr.x + sr.w - 38.0, sr.y + 22.0, 11, true);
        shell_ui.drawText(cr, "✕", sr.x + sr.w - 18.0, sr.y + 22.0, 11, true);
    }

    fn renderDialog(self: *App, cr: *c.api.cairo_t) void {
        const dw: f64 = 440;
        const dh: f64 = 190;
        const dx = (@as(f64, @floatFromInt(self.w)) - dw) / 2.0;
        const dy = (@as(f64, @floatFromInt(self.h)) - dh) / 2.0;

        // Dim overlay
        shell_ui.setSource(cr, ui_theme.global.pdf_dialog_backdrop);
        c.api.cairo_rectangle(cr, 0, 0, @floatFromInt(self.w), @floatFromInt(self.h));
        c.api.cairo_fill(cr);

        // The shared card stays opaque when the window background is glass.
        if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(dx), .y = @floatCast(dy), .w = @floatCast(dw), .h = @floatCast(dh) })) |value| {
            var frame = value;
            ui_dialog.paintFrame(&frame.renderer, frame.local());
            frame.finish();
        }

        // Title
        const title = switch (self.dialog) {
            .information => "PDF Viewer",
            .password => "Password Required",
            .none => "",
        };
        shell_ui.setSource(cr, ui_theme.global.window_fg);
        shell_ui.drawText(cr, title, dx + 24.0, dy + 32.0, shell_ui.textSize(), true);

        // Prompt / error message
        if (self.error_message) |msg| {
            shell_ui.setSource(cr, ui_theme.global.danger);
            shell_ui.drawText(cr, msg, dx + 24.0, dy + 58.0, shell_ui.textSize(), false);
        } else {
            shell_ui.setSource(cr, ui_theme.global.window_fg);
            const prompt = switch (self.dialog) {
                .information => "Open another PDF from Files in a new window.",
                .password => "Document is encrypted. Enter password:",
                .none => "",
            };
            shell_ui.drawText(cr, prompt, dx + 24.0, dy + 58.0, shell_ui.textSize(), false);
        }

        if (self.dialog == .password) {
            if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(dx + 24), .y = @floatCast(dy + 80), .w = @floatCast(dw - 48), .h = 44 })) |value| {
                var field = value;
                _ = ui_field.paintSecret(&field.renderer, field.local(), .{}, .{ .focused = true, .external_caret = true }, &self.password_input, "Password");
                field.finish();
            }
        }

        self.renderButtonText(cr, dx + dw - 180, dy + dh - 46, 80, 32, "Cancel");
        const btn_label = if (self.dialog == .password) "Unlock" else "OK";
        self.renderButtonText(cr, dx + dw - 90, dy + dh - 46, 70, 32, btn_label);
    }

    fn renderButtonText(self: *App, cr: *c.api.cairo_t, x: f64, y: f64, w: f64, h: f64, label: []const u8) void {
        const is_hover = self.px >= x and self.px <= x + w and self.py >= y and self.py <= y + h;
        var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(x), .y = @floatCast(y), .w = @floatCast(w), .h = @floatCast(h) }) orelse return;
        defer layer.finish();
        ui_button.paint(&layer.renderer, layer.local(), .{
            .variant = .ghost,
            .label = label,
        }, .{ .pointer = if (is_hover) .hover else .idle });
    }

    /// A text button shown selected while its mode is active.
    fn renderToggle(self: *App, cr: *c.api.cairo_t, x: f64, y: f64, w: f64, h: f64, label: []const u8, selected: bool) void {
        const is_hover = self.px >= x and self.px <= x + w and self.py >= y and self.py <= y + h;
        var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(x), .y = @floatCast(y), .w = @floatCast(w), .h = @floatCast(h) }) orelse return;
        defer layer.finish();
        ui_button.paint(&layer.renderer, layer.local(), .{
            .variant = .ghost,
            .label = label,
        }, .{ .pointer = if (is_hover) .hover else .idle, .selected = selected });
    }

    fn renderButtonIcon(self: *App, cr: *c.api.cairo_t, x: f64, y: f64, w: f64, h: f64, icon: IconId, tooltip: []const u8) void {
        const is_hover = self.px >= x and self.px <= x + w and self.py >= y and self.py <= y + h;
        var layer = shell_ui.Layer.begin(cr, .{ .x = @floatCast(x), .y = @floatCast(y), .w = @floatCast(w), .h = @floatCast(h) }) orelse return;
        defer layer.finish();
        ui_button.paint(&layer.renderer, layer.local(), .{
            .variant = .ghost,
            .icon = icon,
            .label = tooltip,
        }, .{ .pointer = if (is_hover) .hover else .idle });
    }
};
