//! Narrow library adapter and explicit ownership for Poppler and Cairo.
//! All Poppler / GLib / Cairo objects are managed and released explicitly.
const std = @import("std");
const c = @import("c.zig");
const layout = @import("layout.zig");

pub const Error = error{
    FileNotFound,
    InvalidPdf,
    Encrypted,
    PasswordRequired,
    PageNotFound,
    RenderFailed,
    OutOfMemory,
};

pub const RenderOptions = struct {
    /// Zoom times the output's buffer scale.
    scale: f64 = 1.0,
    rotation: layout.Rotation = .deg0,
    /// Part of the raster to render, in its pixels (not logical units).
    clip: ?layout.Rect = null,
};

pub const RenderedPage = struct {
    pixels: []u32,
    width: i32,
    height: i32,
    stride: i32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: RenderedPage) void {
        self.allocator.free(self.pixels);
    }
};

pub const LinkTarget = union(enum) {
    uri: [:0]u8,
    goto_page: usize,
};

pub const Link = struct {
    area: layout.Rect,
    target: LinkTarget,

    pub fn deinit(self: Link, allocator: std.mem.Allocator) void {
        switch (self.target) {
            .uri => |u| allocator.free(u),
            .goto_page => {},
        }
    }
};

pub const OutlineItem = struct {
    title: [:0]u8,
    target_page: ?usize,
    level: usize,

    pub fn deinit(self: OutlineItem, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
    }
};

pub const Document = struct {
    doc: *c.PopplerDocument,
    n_pages: usize,

    /// Borrow the original read-only descriptor; Poppler owns a duplicate.
    /// Password retries never resolve the pathname again.
    pub fn openFd(fd: c_int, password: ?[:0]const u8) Error!Document {
        const owned = c.api.fcntl(fd, c.api.F_DUPFD_CLOEXEC, @as(c_int, 3));
        if (owned < 0) return error.FileNotFound;
        var err: ?*c.GError = null;
        defer if (err) |e| c.g_error_free(e);
        const doc = c.poppler_document_new_from_fd(owned, if (password) |p| p.ptr else null, &err) orelse {
            if (err) |e| if (e.code == c.POPPLER_ERROR_ENCRYPTED) return error.Encrypted;
            return error.InvalidPdf;
        };
        errdefer c.g_object_unref(doc);
        const pages = c.poppler_document_get_n_pages(doc);
        if (pages <= 0 or pages > 100_000) return error.InvalidPdf;
        return .{ .doc = doc, .n_pages = @intCast(pages) };
    }

    pub fn openPath(path: [:0]const u8, password: ?[:0]const u8) Error!Document {
        var err: ?*c.GError = null;
        defer if (err) |e| c.g_error_free(e);

        var uri: ?[*:0]u8 = null;
        defer if (uri) |u| c.g_free(u);

        if (!std.mem.startsWith(u8, path, "file://")) {
            var st: c.api.struct_stat = undefined;
            if (c.api.stat(path.ptr, &st) != 0) return error.FileNotFound;
        }

        const uri_str: [*:0]const u8 = if (std.mem.startsWith(u8, path, "file://"))
            path.ptr
        else blk: {
            uri = c.g_filename_to_uri(path.ptr, null, &err);
            if (uri == null) {
                if (err) |e| {
                    if (e.code == c.POPPLER_ERROR_OPEN_FILE or e.code == 4) return error.FileNotFound;
                }
                return error.FileNotFound;
            }
            break :blk uri.?;
        };

        const pass_ptr = if (password) |p| p.ptr else null;
        const doc = c.poppler_document_new_from_file(uri_str, pass_ptr, &err) orelse {
            if (err) |e| {
                if (e.code == c.POPPLER_ERROR_ENCRYPTED) return error.Encrypted;
                if (e.code == c.POPPLER_ERROR_OPEN_FILE or e.code == 4) return error.FileNotFound;
            }
            return error.InvalidPdf;
        };
        errdefer c.g_object_unref(doc);

        const pages = c.poppler_document_get_n_pages(doc);
        return .{
            .doc = doc,
            .n_pages = @intCast(@max(0, pages)),
        };
    }

    pub fn openBytes(bytes: []const u8, password: ?[:0]const u8) Error!Document {
        if (bytes.len == 0) return error.InvalidPdf;
        const gbytes = c.g_bytes_new_static(bytes.ptr, bytes.len) orelse return error.OutOfMemory;
        defer c.g_bytes_unref(gbytes);

        var err: ?*c.GError = null;
        defer if (err) |e| c.g_error_free(e);

        const pass_ptr = if (password) |p| p.ptr else null;
        const doc = c.poppler_document_new_from_bytes(gbytes, pass_ptr, &err) orelse {
            if (err) |e| {
                if (e.code == c.POPPLER_ERROR_ENCRYPTED) return error.Encrypted;
            }
            return error.InvalidPdf;
        };
        errdefer c.g_object_unref(doc);

        const pages = c.poppler_document_get_n_pages(doc);
        return .{
            .doc = doc,
            .n_pages = @intCast(@max(0, pages)),
        };
    }

    pub fn deinit(self: *Document) void {
        c.g_object_unref(self.doc);
    }

    pub fn pageCount(self: Document) usize {
        return self.n_pages;
    }

    pub fn getPageSize(self: Document, page_index: usize) Error!layout.PageSize {
        if (page_index >= self.n_pages) return error.PageNotFound;
        const page = c.poppler_document_get_page(self.doc, @intCast(page_index)) orelse return error.PageNotFound;
        defer c.g_object_unref(page);

        var w: f64 = 0;
        var h: f64 = 0;
        c.poppler_page_get_size(page, &w, &h);
        if (!validPageSize(w, h)) return error.RenderFailed;
        return .{ .width = w, .height = h };
    }

    pub fn renderPage(
        self: Document,
        page_index: usize,
        options: RenderOptions,
        allocator: std.mem.Allocator,
    ) Error!RenderedPage {
        if (page_index >= self.n_pages) return error.PageNotFound;
        const page = c.poppler_document_get_page(self.doc, @intCast(page_index)) orelse return error.PageNotFound;
        defer c.g_object_unref(page);

        var w_pts: f64 = 0;
        var h_pts: f64 = 0;
        c.poppler_page_get_size(page, &w_pts, &h_pts);
        if (!validPageSize(w_pts, h_pts) or !std.math.isFinite(options.scale) or options.scale <= 0) return error.RenderFailed;

        const s = layout.PTS_TO_LOGICAL * options.scale;
        const w_log = w_pts * s;
        const h_log = h_pts * s;

        const dest_w_log = switch (options.rotation) {
            .deg0, .deg180 => w_log,
            .deg90, .deg270 => h_log,
        };
        const dest_h_log = switch (options.rotation) {
            .deg0, .deg180 => h_log,
            .deg90, .deg270 => w_log,
        };

        if (!std.math.isFinite(dest_w_log) or !std.math.isFinite(dest_h_log)) return error.RenderFailed;
        if (options.clip) |clip| {
            if (!std.math.isFinite(clip.x) or !std.math.isFinite(clip.y)) return error.RenderFailed;
        }
        const width = if (options.clip) |clip| clip.w else dest_w_log;
        const height = if (options.clip) |clip| clip.h else dest_h_log;
        // Validate before float-to-int conversion, which traps on NaN/overflow.
        if (!std.math.isFinite(width) or !std.math.isFinite(height) or
            width <= 0 or height <= 0 or width > 32768 or height > 32768) return error.RenderFailed;
        const px_w: i32 = @intFromFloat(@ceil(width));
        const px_h: i32 = @intFromFloat(@ceil(height));
        if (px_w > 32768 or px_h > 32768 or @as(i64, px_w) * px_h > 64 * 1024 * 1024) return error.RenderFailed;

        const pixels = allocator.alloc(u32, @intCast(px_w * px_h)) catch return error.OutOfMemory;
        errdefer allocator.free(pixels);

        const stride = px_w * 4;
        const surface = c.api.cairo_image_surface_create_for_data(
            @ptrCast(pixels.ptr),
            c.api.CAIRO_FORMAT_ARGB32,
            px_w,
            px_h,
            stride,
        );
        if (c.api.cairo_surface_status(surface) != c.api.CAIRO_STATUS_SUCCESS) return error.RenderFailed;
        defer c.api.cairo_surface_destroy(surface);

        const cr = c.api.cairo_create(surface);
        if (c.api.cairo_status(cr) != c.api.CAIRO_STATUS_SUCCESS) return error.RenderFailed;
        defer c.api.cairo_destroy(cr);

        // Explicit white paper background
        c.api.cairo_set_source_rgb(cr, 1.0, 1.0, 1.0);
        c.api.cairo_paint(cr);

        if (options.clip) |clip| {
            c.api.cairo_translate(cr, -clip.x, -clip.y);
        }

        switch (options.rotation) {
            .deg0 => {},
            .deg90 => {
                c.api.cairo_translate(cr, dest_w_log, 0);
                c.api.cairo_rotate(cr, std.math.pi / 2.0);
            },
            .deg180 => {
                c.api.cairo_translate(cr, dest_w_log, dest_h_log);
                c.api.cairo_rotate(cr, std.math.pi);
            },
            .deg270 => {
                c.api.cairo_translate(cr, 0, dest_h_log);
                c.api.cairo_rotate(cr, 3.0 * std.math.pi / 2.0);
            },
        }

        c.api.cairo_scale(cr, s, s);
        c.poppler_page_render(page, cr);
        c.api.cairo_surface_flush(surface);

        return .{
            .pixels = pixels,
            .width = px_w,
            .height = px_h,
            .stride = stride,
            .allocator = allocator,
        };
    }

    pub fn getPageText(self: Document, page_index: usize, allocator: std.mem.Allocator) Error!?[:0]u8 {
        if (page_index >= self.n_pages) return error.PageNotFound;
        const page = c.poppler_document_get_page(self.doc, @intCast(page_index)) orelse return error.PageNotFound;
        defer c.g_object_unref(page);

        const text_ptr = c.poppler_page_get_text(page);
        if (text_ptr == null) return null;
        defer c.g_free(text_ptr);

        return try allocator.dupeZ(u8, std.mem.span(text_ptr.?));
    }

    pub fn findText(self: Document, page_index: usize, query: [:0]const u8, allocator: std.mem.Allocator) Error![]layout.Rect {
        if (page_index >= self.n_pages) return error.PageNotFound;
        const page = c.poppler_document_get_page(self.doc, @intCast(page_index)) orelse return error.PageNotFound;
        defer c.g_object_unref(page);

        var w_pts: f64 = 0;
        var h_pts: f64 = 0;
        c.poppler_page_get_size(page, &w_pts, &h_pts);

        const list = c.poppler_page_find_text(page, query.ptr);
        if (list == null) return try allocator.alloc(layout.Rect, 0);
        defer c.g_list_free_full(list, @ptrCast(&c.poppler_rectangle_free));

        var count: usize = 0;
        var it: ?*c.GList = list;
        while (it) |node| : (it = node.next) {
            if (node.data != null) count += 1;
        }

        const rects = try allocator.alloc(layout.Rect, count);
        errdefer allocator.free(rects);

        var i: usize = 0;
        it = list;
        while (it) |node| : (it = node.next) {
            if (node.data) |data| {
                const r: *c.PopplerRectangle = @ptrCast(@alignCast(data));
                const top = h_pts - r.y2;
                const bottom = h_pts - r.y1;
                rects[i] = .{
                    .x = r.x1,
                    .y = @min(top, bottom),
                    .w = @abs(r.x2 - r.x1),
                    .h = @abs(bottom - top),
                };
                i += 1;
            }
        }
        return rects;
    }

    pub fn getPageLinks(self: Document, page_index: usize, allocator: std.mem.Allocator) Error![]Link {
        if (page_index >= self.n_pages) return error.PageNotFound;
        const page = c.poppler_document_get_page(self.doc, @intCast(page_index)) orelse return error.PageNotFound;
        defer c.g_object_unref(page);

        var w_pts: f64 = 0;
        var h_pts: f64 = 0;
        c.poppler_page_get_size(page, &w_pts, &h_pts);

        const list = c.poppler_page_get_link_mapping(page);
        if (list == null) return try allocator.alloc(Link, 0);
        defer c.poppler_page_free_link_mapping(list);

        var results: std.ArrayList(Link) = .empty;
        defer results.deinit(allocator);

        var it: ?*c.GList = list;
        while (it) |node| : (it = node.next) {
            if (node.data) |data| {
                const mapping: *c.PopplerLinkMapping = @ptrCast(@alignCast(data));
                if (mapping.action) |action_raw| {
                    const any_action: *c.PopplerActionAny = @ptrCast(@alignCast(action_raw));
                    const top = h_pts - mapping.area.y2;
                    const bottom = h_pts - mapping.area.y1;
                    const area = layout.Rect{
                        .x = mapping.area.x1,
                        .y = @min(top, bottom),
                        .w = @abs(mapping.area.x2 - mapping.area.x1),
                        .h = @abs(bottom - top),
                    };

                    if (any_action.type == c.POPPLER_ACTION_URI) {
                        const uri_action: *c.PopplerActionUri = @ptrCast(@alignCast(action_raw));
                        if (uri_action.uri) |uri_ptr| {
                            const uri_str = try allocator.dupeZ(u8, std.mem.span(uri_ptr));
                            try results.append(allocator, .{ .area = area, .target = .{ .uri = uri_str } });
                        }
                    } else if (any_action.type == c.POPPLER_ACTION_GOTO_DEST) {
                        const dest_action: *c.PopplerActionGotoDest = @ptrCast(@alignCast(action_raw));
                        if (dest_action.dest) |dest| {
                            if (dest.page_num >= 1) {
                                try results.append(allocator, .{
                                    .area = area,
                                    .target = .{ .goto_page = @intCast(dest.page_num - 1) },
                                });
                            }
                        }
                    }
                }
            }
        }
        return try results.toOwnedSlice(allocator);
    }

    pub fn getOutline(self: Document, allocator: std.mem.Allocator) Error![]OutlineItem {
        var results: std.ArrayList(OutlineItem) = .empty;
        defer results.deinit(allocator);
        errdefer for (results.items) |item| item.deinit(allocator);

        const iter = c.poppler_index_iter_new(self.doc) orelse return try results.toOwnedSlice(allocator);
        defer c.poppler_index_iter_free(iter);

        var remaining: usize = 10_000;
        try self.collectOutline(iter, 0, &results, allocator, &remaining);
        return try results.toOwnedSlice(allocator);
    }

    fn collectOutline(
        self: Document,
        iter: *c.PopplerIndexIter,
        level: usize,
        results: *std.ArrayList(OutlineItem),
        allocator: std.mem.Allocator,
        remaining: *usize,
    ) Error!void {
        while (true) {
            if (level >= 64 or remaining.* == 0) return;
            remaining.* -= 1;
            const action_raw = c.poppler_index_iter_get_action(iter);
            if (action_raw) |act| {
                defer c.poppler_action_free(act);
                const any_act: *c.PopplerActionAny = @ptrCast(@alignCast(act));
                const title = if (any_act.title) |t| try allocator.dupeZ(u8, std.mem.span(t)) else try allocator.dupeZ(u8, "");

                var page_target: ?usize = null;
                if (any_act.type == c.POPPLER_ACTION_GOTO_DEST) {
                    const goto_act: *c.PopplerActionGotoDest = @ptrCast(@alignCast(act));
                    if (goto_act.dest) |dest| {
                        if (dest.page_num >= 1) {
                            page_target = @intCast(dest.page_num - 1);
                        } else if (dest.named_dest) |named| {
                            if (c.poppler_document_find_dest(self.doc, named)) |resolved| {
                                defer c.poppler_dest_free(resolved);
                                if (resolved.page_num >= 1) {
                                    page_target = @intCast(resolved.page_num - 1);
                                }
                            }
                        }
                    }
                }
                results.append(allocator, .{
                    .title = title,
                    .target_page = page_target,
                    .level = level,
                }) catch |err| {
                    allocator.free(title);
                    return err;
                };
            }

            if (c.poppler_index_iter_get_child(iter)) |child| {
                defer c.poppler_index_iter_free(child);
                try self.collectOutline(child, level + 1, results, allocator, remaining);
            }

            if (c.poppler_index_iter_next(iter) == 0) break;
        }
    }
};

fn validPageSize(width: f64, height: f64) bool {
    return std.math.isFinite(width) and std.math.isFinite(height) and
        width > 0 and height > 0 and width <= 1_000_000 and height <= 1_000_000;
}
