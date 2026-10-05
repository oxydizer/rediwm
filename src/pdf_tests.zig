const std = @import("std");
const c = @import("pdf/c.zig");
const layout = @import("pdf/layout.zig");
const document = @import("pdf/document.zig");
const cache = @import("pdf/cache.zig");
const worker = @import("pdf/worker.zig");

const testing = std.testing;
const a = testing.allocator;

test "layout: rotation dimensions and logical scaling" {
    const size = layout.PageSize{ .width = 612.0, .height = 792.0 }; // Standard US Letter in pts

    const sz0 = layout.rotatedPageSize(size, .deg0);
    try testing.expectEqual(612.0, sz0.width);
    try testing.expectEqual(792.0, sz0.height);

    const sz90 = layout.rotatedPageSize(size, .deg90);
    try testing.expectEqual(792.0, sz90.width);
    try testing.expectEqual(612.0, sz90.height);

    const sz180 = layout.rotatedPageSize(size, .deg180);
    try testing.expectEqual(612.0, sz180.width);
    try testing.expectEqual(792.0, sz180.height);

    const sz270 = layout.rotatedPageSize(size, .deg270);
    try testing.expectEqual(792.0, sz270.width);
    try testing.expectEqual(612.0, sz270.height);

    // 100% zoom: 1 pt = 96/72 logical px
    const lsz100 = layout.logicalPageSize(size, .deg0, 1.0);
    try testing.expectApproxEqAbs(612.0 * (96.0 / 72.0), lsz100.width, 0.001);
    try testing.expectApproxEqAbs(792.0 * (96.0 / 72.0), lsz100.height, 0.001);

    // 150% zoom
    const lsz150 = layout.logicalPageSize(size, .deg0, 1.5);
    try testing.expectApproxEqAbs(612.0 * (96.0 / 72.0) * 1.5, lsz150.width, 0.001);
    try testing.expectApproxEqAbs(792.0 * (96.0 / 72.0) * 1.5, lsz150.height, 0.001);
}

test "layout: continuous document layout, visible range, and anchor tracking" {
    const page_sizes = [_]layout.PageSize{
        .{ .width = 200.0, .height = 300.0 },
        .{ .width = 250.0, .height = 400.0 },
        .{ .width = 200.0, .height = 300.0 },
    };

    const doc_layout = try layout.computeDocumentLayout(a, &page_sizes, 1.0, .deg0, 10.0);
    defer doc_layout.deinit();

    try testing.expectEqual(@as(usize, 3), doc_layout.pages.len);
    // Page 0: y_offset = gap = 10
    try testing.expectEqual(10.0, doc_layout.pages[0].y_offset);
    const p0_h = 300.0 * (96.0 / 72.0);
    try testing.expectApproxEqAbs(p0_h, doc_layout.pages[0].logical_height, 0.001);

    // Page 1: y_offset = 10 + p0_h + 10
    const p1_expected_y = 10.0 + p0_h + 10.0;
    try testing.expectApproxEqAbs(p1_expected_y, doc_layout.pages[1].y_offset, 0.001);

    // Visible range test:
    // Viewport at y=0, height=200 should see only page 0
    const vis0 = layout.findVisiblePages(doc_layout.pages, 0.0, 200.0);
    try testing.expect(vis0 != null);
    try testing.expectEqual(@as(usize, 0), vis0.?.start_index);
    try testing.expectEqual(@as(usize, 0), vis0.?.end_index);

    // Viewport spanning boundary of page 0 and page 1
    const vis_span = layout.findVisiblePages(doc_layout.pages, p0_h - 50.0, 200.0);
    try testing.expect(vis_span != null);
    try testing.expectEqual(@as(usize, 0), vis_span.?.start_index);
    try testing.expectEqual(@as(usize, 1), vis_span.?.end_index);

    // Anchor tracking test:
    // Anchor in the middle of page 1
    const anchor1 = layout.Anchor{ .page_index = 1, .rel_y = 0.5 };
    const scroll_pos = layout.scrollToAnchor(doc_layout.pages, anchor1, 500.0);
    // Re-deriving anchor from that scroll position should match page 1
    const recovered_anchor = layout.anchorFromScroll(doc_layout.pages, scroll_pos, 500.0);
    try testing.expectEqual(@as(usize, 1), recovered_anchor.page_index);
    try testing.expectApproxEqAbs(0.5, recovered_anchor.rel_y, 0.05);
}

test "layout: coordinate transforms round-trip" {
    const page_pts = layout.PageSize{ .width = 300.0, .height = 400.0 };
    const rotations = [_]layout.Rotation{ .deg0, .deg90, .deg180, .deg270 };
    const scales = [_]f64{ 0.5, 1.0, 1.33, 2.0 };

    for (rotations) |rot| {
        for (scales) |scale| {
            const original_pt = layout.Point{ .x = 55.5, .y = 120.25 };
            const view_pt = layout.pagePointToView(original_pt, page_pts, rot, scale);
            const recovered_pt = layout.viewPointToPage(view_pt, page_pts, rot, scale);
            try testing.expectApproxEqAbs(original_pt.x, recovered_pt.x, 0.001);
            try testing.expectApproxEqAbs(original_pt.y, recovered_pt.y, 0.001);

            const original_rect = layout.Rect{ .x = 10.0, .y = 20.0, .w = 80.0, .h = 100.0 };
            const view_rect = layout.pageRectToView(original_rect, page_pts, rot, scale);
            const recovered_rect = layout.viewRectToPage(view_rect, page_pts, rot, scale);
            try testing.expectApproxEqAbs(original_rect.x, recovered_rect.x, 0.001);
            try testing.expectApproxEqAbs(original_rect.y, recovered_rect.y, 0.001);
            try testing.expectApproxEqAbs(original_rect.w, recovered_rect.w, 0.001);
            try testing.expectApproxEqAbs(original_rect.h, recovered_rect.h, 0.001);
        }
    }
}

test "layout: fit width and fit page calculations" {
    const max_w: f64 = 200.0;
    const padding: f64 = 20.0;
    // Available width = 500, padding on each side = 20 => usable width = 460
    // max_w logical = 200 * (96/72) = 266.6666
    // fitWidth = 460 / 266.6666 = 1.725
    const fw = layout.fitWidth(max_w, 500.0, padding);
    try testing.expectApproxEqAbs(460.0 / (200.0 * (96.0 / 72.0)), fw, 0.001);

    const fp = layout.fitPage(200.0, 300.0, 500.0, 600.0, padding);
    // Usable w = 460, usable h = 560
    // w scale = 460 / (200 * 4/3) = 1.725
    // h scale = 560 / (300 * 4/3) = 1.4
    // fitPage picks the min = 1.4
    try testing.expectApproxEqAbs(560.0 / (300.0 * (96.0 / 72.0)), fp, 0.001);
}

fn createTestPdf(path: [*:0]const u8) !void {
    const surface = c.api.cairo_pdf_surface_create(path, 200.0, 300.0);
    if (c.api.cairo_surface_status(surface) != c.api.CAIRO_STATUS_SUCCESS) return error.CairoFailed;
    defer c.api.cairo_surface_destroy(surface);

    const cr = c.api.cairo_create(surface);
    if (c.api.cairo_status(cr) != c.api.CAIRO_STATUS_SUCCESS) return error.CairoFailed;
    defer c.api.cairo_destroy(cr);

    // Page 1: Blue rectangle at (10, 20) with w=50, h=60, and text "Page 1 Test"
    c.api.cairo_set_source_rgb(cr, 0.0, 0.0, 1.0);
    c.api.cairo_rectangle(cr, 10.0, 20.0, 50.0, 60.0);
    c.api.cairo_fill(cr);

    c.api.cairo_select_font_face(cr, "Sans", c.api.CAIRO_FONT_SLANT_NORMAL, c.api.CAIRO_FONT_WEIGHT_NORMAL);
    c.api.cairo_set_font_size(cr, 14.0);
    c.api.cairo_move_to(cr, 20.0, 120.0);
    c.api.cairo_show_text(cr, "Page 1 Test");
    c.api.cairo_surface_show_page(surface);

    // Page 2: Red rectangle and text "Page 2 Content"
    c.api.cairo_set_source_rgb(cr, 1.0, 0.0, 0.0);
    c.api.cairo_rectangle(cr, 30.0, 40.0, 60.0, 50.0);
    c.api.cairo_fill(cr);

    c.api.cairo_move_to(cr, 30.0, 150.0);
    c.api.cairo_show_text(cr, "Page 2 Content");
    c.api.cairo_surface_show_page(surface);

    c.api.cairo_surface_finish(surface);
}

test "document: opening, page sizes, rendering and text extraction" {
    var path_buf = "/tmp/rediwm-test-doc-XXXXXX".*;
    const fd = c.api.mkstemp(&path_buf);
    try testing.expect(fd >= 0);
    _ = c.api.close(fd);
    defer _ = c.api.unlink(&path_buf);

    try createTestPdf(&path_buf);

    const path_span = std.mem.sliceTo(&path_buf, 0);
    var doc = try document.Document.openPath(path_span, null);
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 2), doc.pageCount());

    const sz0 = try doc.getPageSize(0);
    try testing.expectEqual(200.0, sz0.width);
    try testing.expectEqual(300.0, sz0.height);

    const sz1 = try doc.getPageSize(1);
    try testing.expectEqual(200.0, sz1.width);
    try testing.expectEqual(300.0, sz1.height);

    try testing.expectError(error.PageNotFound, doc.getPageSize(99));

    // Render Page 0 at 100% zoom
    const rendered = try doc.renderPage(0, .{}, a);
    defer rendered.deinit();

    // 200 pt * 4/3 = 267 px, 300 pt * 4/3 = 400 px
    try testing.expectEqual(@as(i32, 267), rendered.width);
    try testing.expectEqual(@as(i32, 400), rendered.height);

    // Verify paper background is opaque white (0xFFFFFFFF) in top-left corner outside blue box
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), rendered.pixels[0]);

    // Verify blue pixel exists in the blue box region (x=10..60, y=20..80 in pts -> x=13..80, y=27..106 in px)
    const px_sample = rendered.pixels[@intCast(40 * rendered.width + 30)];
    // Blue pixel in Cairo ARGB32 (little-endian 0xAARRGGBB): A=0xFF, R=0x00, G=0x00, B=0xFF -> 0xFF0000FF
    try testing.expectEqual(@as(u32, 0xFF0000FF), px_sample);

    // Test rotated render (deg90): width and height are swapped
    const rendered90 = try doc.renderPage(0, .{ .rotation = .deg90 }, a);
    defer rendered90.deinit();
    try testing.expectEqual(@as(i32, 400), rendered90.width);
    try testing.expectEqual(@as(i32, 267), rendered90.height);

    // Text extraction
    const text0 = try doc.getPageText(0, a);
    defer if (text0) |t| a.free(t);
    try testing.expect(text0 != null);
    try testing.expect(std.mem.indexOf(u8, text0.?, "Page 1 Test") != null);

    // Text search
    const matches = try doc.findText(0, "Test", a);
    defer a.free(matches);
    try testing.expectEqual(@as(usize, 1), matches.len);
    // Normalized top-left coordinates:
    try testing.expect(matches[0].x >= 10.0 and matches[0].x <= 150.0);
    try testing.expect(matches[0].y >= 80.0 and matches[0].y <= 140.0);
    try testing.expect(matches[0].w > 0.0 and matches[0].h > 0.0);
}

test "document: rejection of corrupt and nonexistent files" {
    try testing.expectError(error.FileNotFound, document.Document.openPath("/nonexistent-rediwm-pdf-file.pdf", null));
    try testing.expectError(error.InvalidPdf, document.Document.openBytes("not a valid pdf header", null));
    try testing.expectError(error.InvalidPdf, document.Document.openBytes("", null));
}

test "document: descriptor retries survive unlink and reject invalid raster dimensions" {
    var path = "/tmp/rediwm-test-fd-XXXXXX".*;
    const temp = c.api.mkstemp(&path);
    try testing.expect(temp >= 0);
    _ = c.api.close(temp);
    defer _ = c.api.unlink(&path);
    try createTestPdf(&path);
    const fd = c.api.open(&path, c.api.O_RDONLY | c.api.O_CLOEXEC);
    try testing.expect(fd >= 0);
    defer _ = c.api.close(fd);
    try testing.expectEqual(@as(c_int, 0), c.api.unlink(&path));
    for (0..2) |_| {
        var doc = try document.Document.openFd(fd, null);
        defer doc.deinit();
        try testing.expectEqual(@as(usize, 2), doc.pageCount());
        for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -1, 0, 1e100 }) |scale| {
            try testing.expectError(error.RenderFailed, doc.renderPage(0, .{ .scale = scale }, a));
        }
        try testing.expectError(error.RenderFailed, doc.renderPage(0, .{
            .clip = .{ .x = 0, .y = 0, .w = std.math.inf(f64), .h = 100 },
        }, a));
        try testing.expectError(error.RenderFailed, doc.renderPage(0, .{
            .clip = .{ .x = std.math.nan(f64), .y = 0, .w = 100, .h = 100 },
        }, a));
    }
}

test "document: password-protected document detection" {
    var path_buf = "/tmp/rediwm-plain-XXXXXX".*;
    const fd = c.api.mkstemp(&path_buf);
    try testing.expect(fd >= 0);
    _ = c.api.close(fd);
    defer _ = c.api.unlink(&path_buf);

    try createTestPdf(&path_buf);

    var enc_buf = "/tmp/rediwm-enc-XXXXXX".*;
    const enc_fd = c.api.mkstemp(&enc_buf);
    try testing.expect(enc_fd >= 0);
    _ = c.api.close(enc_fd);
    defer _ = c.api.unlink(&enc_buf);

    const path_span = std.mem.sliceTo(&path_buf, 0);
    const enc_span = std.mem.sliceTo(&enc_buf, 0);

    // Encrypt with qpdf: password "secretpass"
    const cmd = try std.fmt.allocPrintSentinel(a, "qpdf --encrypt secretpass ownerpass 256 -- '{s}' '{s}' 2>/dev/null", .{ path_span, enc_span }, 0);
    defer a.free(cmd);
    const rc = c.api.system(cmd);
    if (rc != 0) return; // If qpdf is not available or failed, skip

    const encrypted_input_fd = c.api.open(enc_span.ptr, c.api.O_RDONLY | c.api.O_CLOEXEC);
    try testing.expect(encrypted_input_fd >= 0);
    defer _ = c.api.close(encrypted_input_fd);
    // All attempts must use the retained inode, even after unlink.
    try testing.expectEqual(@as(c_int, 0), c.api.unlink(enc_span.ptr));
    try testing.expectError(error.Encrypted, document.Document.openFd(encrypted_input_fd, null));
    // Opening with wrong password must return error.Encrypted or error.InvalidPdf
    const wrong_res = document.Document.openFd(encrypted_input_fd, "wrongpassword");
    try testing.expect(wrong_res == error.Encrypted or wrong_res == error.InvalidPdf);

    // Opening with correct password must succeed
    var enc_doc = try document.Document.openFd(encrypted_input_fd, "secretpass");
    defer enc_doc.deinit();
    try testing.expectEqual(@as(usize, 2), enc_doc.pageCount());
}

test "cache: page cache bounds, LRU eviction, and best-fit scale fallback" {
    // 64 KB limit
    var pc = cache.PageCache.init(a, 64 * 1024);
    defer pc.deinit();

    // Create 3 dummy pages, each 32 KB (width=128, height=64, stride=512 => 32,768 bytes)
    for (0..3) |i| {
        const px = try a.alloc(u32, 128 * 64);
        @memset(px, @intCast(i));
        const key = cache.PageKey.init(1, i, 1.0, .deg0, null);
        try pc.put(.{
            .key = key,
            .pixels = px,
            .width = 128,
            .height = 64,
            .stride = 128 * 4,
            .bytes = 128 * 64 * 4,
            .last_used = 0,
            .allocator = a,
        });
    }

    // Cache limit is 64KB (2 pages max). Page 0 should have been evicted when Page 2 was put!
    try testing.expect(pc.get(cache.PageKey.init(1, 0, 1.0, .deg0, null)) == null);
    try testing.expect(pc.get(cache.PageKey.init(1, 1, 1.0, .deg0, null)) != null);
    try testing.expect(pc.get(cache.PageKey.init(1, 2, 1.0, .deg0, null)) != null);

    // Test findBest: even if we request scale 2.0 (which is not rendered yet),
    // findBest should find the cached 1.0 render for page 2!
    const best = pc.findBest(1, 2, .deg0);
    try testing.expect(best != null);
    try testing.expectEqual(@as(usize, 2), best.?.key.page_index);

    // Old generation should not match findBest
    try testing.expect(pc.findBest(2, 2, .deg0) == null);

    // clearGeneration
    pc.clearGeneration(2); // Keep only generation 2 => removes generation 1
    try testing.expectEqual(@as(usize, 0), pc.bytes);
    try testing.expect(pc.get(cache.PageKey.init(1, 1, 1.0, .deg0, null)) == null);
}

test "layout: sidebar card layout and binary search virtualization" {
    const page_sizes = [_]layout.PageSize{
        .{ .width = 200.0, .height = 300.0 },
        .{ .width = 200.0, .height = 300.0 },
        .{ .width = 200.0, .height = 300.0 },
        .{ .width = 200.0, .height = 300.0 },
    };

    const sb = try layout.computeSidebarLayout(a, &page_sizes, .deg0, 140.0);
    defer sb.deinit();

    try testing.expectEqual(@as(usize, 4), sb.cards.len);
    try testing.expect(sb.total_height > 100.0);

    // Binary search visible range
    const vis = layout.findVisibleSidebarCards(sb.cards, 0.0, 300.0);
    try testing.expect(vis != null);
    try testing.expectEqual(@as(usize, 0), vis.?.start_index);
    try testing.expect(vis.?.end_index >= 0);
}

test "worker: background open, render, and result delivery" {
    var path_buf = "/tmp/rediwm-test-worker-XXXXXX".*;
    const fd = c.api.mkstemp(&path_buf);
    try testing.expect(fd >= 0);
    _ = c.api.close(fd);
    defer _ = c.api.unlink(&path_buf);

    try createTestPdf(&path_buf);

    const document_fd = c.api.open(&path_buf, c.api.O_RDONLY | c.api.O_CLOEXEC);
    try testing.expect(document_fd >= 0);
    defer _ = c.api.close(document_fd);
    const w = try worker.Worker.init(document_fd);
    defer w.deinit();

    try w.requestOpen(null, 1);

    var got_open = false;
    for (0..100) |_| {
        if (w.takeResult()) |res| {
            var mut_res = res;
            defer mut_res.deinit();
            if (mut_res.payload == .open_done) {
                got_open = true;
                try testing.expectEqual(@as(usize, 2), mut_res.payload.open_done.page_count);
                break;
            }
        }
        _ = c.api.usleep(10_000);
    }
    try testing.expect(got_open);

    w.setRenderJobs(&[_]worker.Job{.{
        .kind = .render_page,
        .priority = 0,
        .generation = 1,
        .page_index = 0,
        .scale = 1.0,
        .rotation = .deg0,
    }}, 1);

    var got_render = false;
    for (0..100) |_| {
        if (w.takeResult()) |res| {
            var mut_res = res;
            defer mut_res.deinit();
            if (mut_res.payload == .page_rendered) {
                got_render = true;
                try testing.expectEqual(@as(usize, 0), mut_res.payload.page_rendered.page_index);
                try testing.expect(mut_res.payload.page_rendered.rendered.width > 0);
                break;
            }
        }
        _ = c.api.usleep(10_000);
    }
    try testing.expect(got_render);
}
