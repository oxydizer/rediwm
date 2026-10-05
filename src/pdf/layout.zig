//! Continuous vertical layout geometry, anchor tracking and coordinate transforms.
const std = @import("std");

/// 100% zoom is 96 logical pixels per inch; PDF points use 72 per inch.
pub const PTS_TO_LOGICAL: f64 = 96.0 / 72.0;

pub const Rotation = enum(u2) {
    deg0 = 0,
    deg90 = 1,
    deg180 = 2,
    deg270 = 3,

    pub fn rotateClockwise(self: Rotation) Rotation {
        return switch (self) {
            .deg0 => .deg90,
            .deg90 => .deg180,
            .deg180 => .deg270,
            .deg270 => .deg0,
        };
    }

    pub fn rotateCounterClockwise(self: Rotation) Rotation {
        return switch (self) {
            .deg0 => .deg270,
            .deg90 => .deg0,
            .deg180 => .deg90,
            .deg270 => .deg180,
        };
    }
};

pub const Point = struct {
    x: f64,
    y: f64,
};

pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    pub fn contains(self: Rect, pt: Point) bool {
        return pt.x >= self.x and pt.x <= self.x + self.w and pt.y >= self.y and pt.y <= self.y + self.h;
    }
};

pub const PageSize = struct {
    width: f64,
    height: f64,
};

pub fn rotatedPageSize(size: PageSize, rotation: Rotation) PageSize {
    return switch (rotation) {
        .deg0, .deg180 => size,
        .deg90, .deg270 => .{ .width = size.height, .height = size.width },
    };
}

pub fn logicalPageSize(size: PageSize, rotation: Rotation, zoom: f64) PageSize {
    const rot = rotatedPageSize(size, rotation);
    return .{
        .width = rot.width * PTS_TO_LOGICAL * zoom,
        .height = rot.height * PTS_TO_LOGICAL * zoom,
    };
}

pub const PageLayout = struct {
    page_index: usize,
    pts_size: PageSize,
    logical_width: f64,
    logical_height: f64,
    y_offset: f64,
};

pub const DocumentLayout = struct {
    pages: []PageLayout,
    total_height: f64,
    max_width: f64,
    gap: f64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: DocumentLayout) void {
        self.allocator.free(self.pages);
    }
};

pub fn computeDocumentLayout(
    allocator: std.mem.Allocator,
    page_sizes: []const PageSize,
    zoom: f64,
    rotation: Rotation,
    gap: f64,
) !DocumentLayout {
    const pages = try allocator.alloc(PageLayout, page_sizes.len);
    errdefer allocator.free(pages);

    var cur_y: f64 = gap;
    var max_w: f64 = 0;

    for (page_sizes, 0..) |sz, i| {
        const lsz = logicalPageSize(sz, rotation, zoom);
        pages[i] = .{
            .page_index = i,
            .pts_size = sz,
            .logical_width = lsz.width,
            .logical_height = lsz.height,
            .y_offset = cur_y,
        };
        if (lsz.width > max_w) max_w = lsz.width;
        cur_y += lsz.height + gap;
    }

    return .{
        .pages = pages,
        .total_height = cur_y,
        .max_width = max_w,
        .gap = gap,
        .allocator = allocator,
    };
}

pub const VisibleRange = struct {
    start_index: usize,
    end_index: usize,
};

pub fn findVisiblePages(pages: []const PageLayout, scroll_y: f64, viewport_h: f64) ?VisibleRange {
    if (pages.len == 0) return null;
    const view_top = scroll_y;
    const view_bottom = scroll_y + viewport_h;

    // Binary search for first page where y_offset + logical_height >= view_top
    var low: usize = 0;
    var high: usize = pages.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (pages[mid].y_offset + pages[mid].logical_height < view_top) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }

    if (low >= pages.len or pages[low].y_offset > view_bottom) return null;
    const start = low;

    var end = start;
    while (end + 1 < pages.len and pages[end + 1].y_offset <= view_bottom) {
        end += 1;
    }

    return .{ .start_index = start, .end_index = end };
}

pub const SidebarCard = struct {
    page_index: usize,
    card_h: f64,
    y_offset: f64,
};

pub const SidebarLayout = struct {
    cards: []SidebarCard,
    total_height: f64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: SidebarLayout) void {
        self.allocator.free(self.cards);
    }
};

pub fn computeSidebarLayout(
    allocator: std.mem.Allocator,
    page_sizes: []const PageSize,
    rotation: Rotation,
    card_w: f64,
) !SidebarLayout {
    const cards = try allocator.alloc(SidebarCard, page_sizes.len);
    errdefer allocator.free(cards);

    var cur_y: f64 = 12.0;
    for (page_sizes, 0..) |sz, i| {
        const rsz = rotatedPageSize(sz, rotation);
        const card_h = @min(180.0, @max(60.0, card_w * (rsz.height / rsz.width)));
        cards[i] = .{
            .page_index = i,
            .card_h = card_h,
            .y_offset = cur_y,
        };
        cur_y += card_h + 24.0;
    }

    return .{
        .cards = cards,
        .total_height = cur_y,
        .allocator = allocator,
    };
}

pub fn findVisibleSidebarCards(cards: []const SidebarCard, scroll_y: f64, viewport_h: f64) ?VisibleRange {
    if (cards.len == 0) return null;
    const view_top = scroll_y;
    const view_bottom = scroll_y + viewport_h;

    var low: usize = 0;
    var high: usize = cards.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (cards[mid].y_offset + cards[mid].card_h + 24.0 < view_top) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }

    if (low >= cards.len or cards[low].y_offset > view_bottom) return null;
    const start = low;

    var end = start;
    while (end + 1 < cards.len and cards[end + 1].y_offset <= view_bottom) {
        end += 1;
    }

    return .{ .start_index = start, .end_index = end };
}

pub const Anchor = struct {
    page_index: usize,
    rel_y: f64,
};

pub fn anchorFromScroll(pages: []const PageLayout, scroll_y: f64, viewport_h: f64) Anchor {
    if (pages.len == 0) return .{ .page_index = 0, .rel_y = 0 };
    const reading_y = scroll_y + @min(60.0, viewport_h * 0.2);

    var low: usize = 0;
    var high: usize = pages.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (pages[mid].y_offset + pages[mid].logical_height < reading_y) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    const idx = @min(low, pages.len - 1);
    const p = pages[idx];
    if (reading_y < p.y_offset) {
        return .{ .page_index = idx, .rel_y = 0.0 };
    }
    const rel = if (p.logical_height > 0) (reading_y - p.y_offset) / p.logical_height else 0.0;
    return .{ .page_index = idx, .rel_y = @max(0.0, @min(1.0, rel)) };
}

pub fn scrollToAnchor(pages: []const PageLayout, anchor: Anchor, viewport_h: f64) f64 {
    if (pages.len == 0) return 0;
    const idx = @min(anchor.page_index, pages.len - 1);
    const p = pages[idx];
    const target_doc_y = p.y_offset + p.logical_height * @max(0.0, @min(1.0, anchor.rel_y));
    const reading_offset = @min(60.0, viewport_h * 0.2);
    return @max(0.0, target_doc_y - reading_offset);
}

pub fn pagePointToView(pt: Point, page_pts: PageSize, rotation: Rotation, scale: f64) Point {
    const s = PTS_TO_LOGICAL * scale;
    return switch (rotation) {
        .deg0 => .{ .x = pt.x * s, .y = pt.y * s },
        .deg90 => .{ .x = (page_pts.height - pt.y) * s, .y = pt.x * s },
        .deg180 => .{ .x = (page_pts.width - pt.x) * s, .y = (page_pts.height - pt.y) * s },
        .deg270 => .{ .x = pt.y * s, .y = (page_pts.width - pt.x) * s },
    };
}

pub fn viewPointToPage(pt: Point, page_pts: PageSize, rotation: Rotation, scale: f64) Point {
    const s = PTS_TO_LOGICAL * scale;
    if (s <= 0) return .{ .x = 0, .y = 0 };
    return switch (rotation) {
        .deg0 => .{ .x = pt.x / s, .y = pt.y / s },
        .deg90 => .{ .x = pt.y / s, .y = page_pts.height - (pt.x / s) },
        .deg180 => .{ .x = page_pts.width - (pt.x / s), .y = page_pts.height - (pt.y / s) },
        .deg270 => .{ .x = page_pts.width - (pt.y / s), .y = pt.x / s },
    };
}

pub fn pageRectToView(r: Rect, page_pts: PageSize, rotation: Rotation, scale: f64) Rect {
    const p1 = pagePointToView(.{ .x = r.x, .y = r.y }, page_pts, rotation, scale);
    const p2 = pagePointToView(.{ .x = r.x + r.w, .y = r.y + r.h }, page_pts, rotation, scale);
    const min_x = @min(p1.x, p2.x);
    const max_x = @max(p1.x, p2.x);
    const min_y = @min(p1.y, p2.y);
    const max_y = @max(p1.y, p2.y);
    return .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
}

pub fn viewRectToPage(r: Rect, page_pts: PageSize, rotation: Rotation, scale: f64) Rect {
    const p1 = viewPointToPage(.{ .x = r.x, .y = r.y }, page_pts, rotation, scale);
    const p2 = viewPointToPage(.{ .x = r.x + r.w, .y = r.y + r.h }, page_pts, rotation, scale);
    const min_x = @min(p1.x, p2.x);
    const max_x = @max(p1.x, p2.x);
    const min_y = @min(p1.y, p2.y);
    const max_y = @max(p1.y, p2.y);
    return .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
}

pub fn fitWidth(max_pts_w: f64, available_w: f64, padding: f64) f64 {
    const target_w = @max(10.0, available_w - padding * 2.0);
    const base_w = max_pts_w * PTS_TO_LOGICAL;
    if (base_w <= 0) return 1.0;
    return target_w / base_w;
}

pub fn fitPage(pts_w: f64, pts_h: f64, available_w: f64, available_h: f64, padding: f64) f64 {
    const target_w = @max(10.0, available_w - padding * 2.0);
    const target_h = @max(10.0, available_h - padding * 2.0);
    const base_w = pts_w * PTS_TO_LOGICAL;
    const base_h = pts_h * PTS_TO_LOGICAL;
    if (base_w <= 0 or base_h <= 0) return 1.0;
    return @min(target_w / base_w, target_h / base_h);
}
