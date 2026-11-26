//! Resolved client-area geometry for the editor.
//!
//! This module owns arrangement, not widget measurement or painting.
//! Callers supply dimensions obtained from the shared widgets and consume
//! the same resolved rectangles for rendering and input.

const std = @import("std");

pub const SearchMode = enum {
    closed,
    find,
    replace,
};

pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,

    pub fn contains(self: Rect, x: f64, y: f64) bool {
        return x >= self.x and y >= self.y and
            x < self.x + self.w and y < self.y + self.h;
    }
};

pub const Size = struct {
    w: f64,
    h: f64,
};

/// Spacing tokens and dimensions measured from the shared widgets.
pub const Metrics = struct {
    tab_strip_height: f64 = 40,
    status_height: f64 = 26,
    viewport_bottom_gap: f64 = 8,
    viewport_leading_inset: f64 = 12,
    viewport_trailing_inset: f64 = 18,
    gutter_width: f64 = 0,

    search_leading_inset: f64 = 12,
    search_trailing_inset: f64 = 12,
    search_top_inset: f64 = 3,
    search_bottom_inset: f64 = 5,
    search_row_gap: f64 = 8,
    search_control_gap: f64 = 8,

    field: Size,
    next: Size,
    toggle: Size,
    close: Size,
    replace: Size,
    replace_all: Size,
};

pub const Input = struct {
    width: f64,
    height: f64,
    editor_owned_tabs: bool,
    search: SearchMode = .closed,
};

/// All rectangles are in client-local logical coordinates.
pub const Layout = struct {
    tab_strip: Rect = .{},
    search_panel: Rect = .{},
    query: Rect = .{},
    next: Rect = .{},
    toggle: Rect = .{},
    close: Rect = .{},
    replacement: Rect = .{},
    replace: Rect = .{},
    replace_all: Rect = .{},
    gutter: Rect = .{},
    viewport: Rect = .{},
    status: Rect = .{},

    fn placeButton(
        x: f64,
        row_y: f64,
        row_height: f64,
        measured: Size,
    ) Rect {
        const h = @min(@max(0, measured.h), row_height);
        return .{
            .x = x,
            .y = row_y + (row_height - h) / 2,
            .w = @max(0, measured.w),
            .h = h,
        };
    }

    pub fn resolve(input: Input, metrics: Metrics) Layout {
        const width = @max(0, input.width);
        const height = @max(0, input.height);
        const strip_height = if (input.editor_owned_tabs)
            @min(metrics.tab_strip_height, height)
        else
            0;
        const has_search = input.search != .closed;
        const has_replace = input.search == .replace;
        const field_height = @max(0, metrics.field.h);
        const search_height = if (!has_search)
            0
        else
            metrics.search_top_inset + field_height +
                (if (has_replace) metrics.search_row_gap + field_height else 0) +
                metrics.search_bottom_inset;

        const search_top = strip_height;
        const content_top = @min(height, strip_height + search_height);
        const status_top = @max(0, height - metrics.status_height);
        const viewport_bottom = @max(
            content_top,
            status_top - metrics.viewport_bottom_gap,
        );
        const gutter_width = @min(
            @max(0, metrics.gutter_width),
            @max(0, width - metrics.viewport_leading_inset - metrics.viewport_trailing_inset),
        );

        const left = @min(width, @max(0, metrics.search_leading_inset));
        const right = @max(left, width - @max(0, metrics.search_trailing_inset));
        const available = right - left;
        const gap = @max(0, metrics.search_control_gap);
        const row_y = search_top + metrics.search_top_inset;

        var out: Layout = .{
            .tab_strip = if (input.editor_owned_tabs)
                .{ .x = 0, .y = 0, .w = width, .h = strip_height }
            else
                .{},
            .search_panel = if (has_search)
                .{ .x = 0, .y = search_top, .w = width, .h = search_height }
            else
                .{},
            .gutter = if (gutter_width > 0)
                .{
                    .x = 0,
                    .y = content_top,
                    .w = metrics.viewport_leading_inset + gutter_width,
                    .h = @max(0, status_top - content_top),
                }
            else
                .{},
            .viewport = .{
                .x = metrics.viewport_leading_inset + gutter_width,
                .y = content_top,
                .w = @max(
                    0,
                    width - metrics.viewport_leading_inset -
                        metrics.viewport_trailing_inset - gutter_width,
                ),
                .h = @max(0, viewport_bottom - content_top),
            },
            .status = .{
                .x = 0,
                .y = status_top,
                .w = width,
                .h = height - status_top,
            },
        };

        if (!has_search) return out;

        // Allocate the trailing controls from right to left. If the window
        // is too narrow, controls shrink rather than extending off-screen.
        var cursor = right;
        const close_w = @min(available, @max(0, metrics.close.w));
        cursor -= close_w;
        out.close = placeButton(cursor, row_y, field_height, .{
            .w = close_w,
            .h = metrics.close.h,
        });

        const toggle_space = @max(0, cursor - left - gap);
        const toggle_w = @min(toggle_space, @max(0, metrics.toggle.w));
        cursor -= if (toggle_w > 0) gap + toggle_w else 0;
        out.toggle = placeButton(cursor, row_y, field_height, .{
            .w = toggle_w,
            .h = metrics.toggle.h,
        });

        const next_space = @max(0, cursor - left - gap);
        const next_w = @min(next_space, @max(0, metrics.next.w));
        cursor -= if (next_w > 0) gap + next_w else 0;
        out.next = placeButton(cursor, row_y, field_height, .{
            .w = next_w,
            .h = metrics.next.h,
        });

        out.query = .{
            .x = left,
            .y = row_y,
            .w = @max(0, cursor - left),
            .h = field_height,
        };

        if (has_replace) {
            cursor = right;
            const replace_all_w = @min(available, @max(0, metrics.replace_all.w));
            cursor -= replace_all_w;
            const replacement_y = row_y + field_height + metrics.search_row_gap;
            out.replace_all = placeButton(cursor, replacement_y, field_height, .{
                .w = replace_all_w,
                .h = metrics.replace_all.h,
            });

            const replace_space = @max(0, cursor - left - gap);
            const replace_w = @min(replace_space, @max(0, metrics.replace.w));
            cursor -= if (replace_w > 0) gap + replace_w else 0;
            out.replace = placeButton(cursor, replacement_y, field_height, .{
                .w = replace_w,
                .h = metrics.replace.h,
            });
            out.replacement = .{
                .x = left,
                .y = replacement_y,
                .w = @max(0, cursor - left),
                .h = field_height,
            };
        }

        return out;
    }
};

fn testMetrics() Metrics {
    return .{
        .field = .{ .w = 200, .h = 44 },
        .next = .{ .w = 54, .h = 28 },
        .toggle = .{ .w = 82, .h = 28 },
        .close = .{ .w = 28, .h = 28 },
        .replace = .{ .w = 72, .h = 28 },
        .replace_all = .{ .w = 96, .h = 28 },
    };
}

test "titlebar tabs do not consume client-area height" {
    const metrics = testMetrics();
    const titlebar = Layout.resolve(.{
        .width = 900,
        .height = 620,
        .editor_owned_tabs = false,
    }, metrics);
    const editor_tabs = Layout.resolve(.{
        .width = 900,
        .height = 620,
        .editor_owned_tabs = true,
    }, metrics);

    try std.testing.expectEqual(@as(f64, 0), titlebar.tab_strip.h);
    try std.testing.expectEqual(@as(f64, 0), titlebar.viewport.y);
    try std.testing.expectEqual(metrics.tab_strip_height, editor_tabs.tab_strip.h);
    try std.testing.expectEqual(metrics.tab_strip_height, editor_tabs.viewport.y);
}

test "find panel and viewport share one resolved boundary" {
    const metrics = testMetrics();
    const layout = Layout.resolve(.{
        .width = 900,
        .height = 620,
        .editor_owned_tabs = false,
        .search = .find,
    }, metrics);

    try std.testing.expectEqual(
        layout.search_panel.y + layout.search_panel.h,
        layout.viewport.y,
    );
    try std.testing.expectEqual(@as(f64, 44), layout.query.h);
    try std.testing.expect(layout.next.x > layout.query.x);
    try std.testing.expect(layout.close.x > layout.toggle.x);
    try std.testing.expectEqual(@as(f64, 28), layout.next.h);
    try std.testing.expectEqual(@as(f64, 8), layout.next.y - layout.query.y);
}

test "replace row participates in the panel's measured height" {
    const metrics = testMetrics();
    const find = Layout.resolve(.{
        .width = 900,
        .height = 620,
        .editor_owned_tabs = true,
        .search = .find,
    }, metrics);
    const replace = Layout.resolve(.{
        .width = 900,
        .height = 620,
        .editor_owned_tabs = true,
        .search = .replace,
    }, metrics);

    try std.testing.expectEqual(
        find.search_panel.h + metrics.search_row_gap + metrics.field.h,
        replace.search_panel.h,
    );
    try std.testing.expectEqual(
        replace.query.y + replace.query.h + metrics.search_row_gap,
        replace.replacement.y,
    );
    try std.testing.expectEqual(
        replace.search_panel.y + replace.search_panel.h,
        replace.viewport.y,
    );
    try std.testing.expect(replace.replace_all.x > replace.replace.x);
}

test "search controls stay within a narrow client area" {
    const layout = Layout.resolve(.{
        .width = 120,
        .height = 300,
        .editor_owned_tabs = false,
        .search = .replace,
    }, testMetrics());

    try std.testing.expect(layout.query.x >= 0);
    try std.testing.expect(layout.query.x + layout.query.w <= 120);
    try std.testing.expect(layout.close.x + layout.close.w <= 120);
    try std.testing.expect(layout.replacement.x >= 0);
    try std.testing.expect(layout.replace_all.x + layout.replace_all.w <= 120);
}

test "viewport and status stay inside short client areas" {
    const layout = Layout.resolve(.{
        .width = 320,
        .height = 40,
        .editor_owned_tabs = true,
        .search = .replace,
    }, testMetrics());

    try std.testing.expect(layout.viewport.h >= 0);
    try std.testing.expect(layout.status.y >= 0);
    try std.testing.expect(layout.status.y + layout.status.h <= 40);
    try std.testing.expect(layout.query.w >= 0);
    try std.testing.expect(layout.replacement.w >= 0);
}

test "line-number gutter reserves its width before shifting the text viewport" {
    const metrics = testMetrics();
    const plain = Layout.resolve(.{
        .width = 900,
        .height = 620,
        .editor_owned_tabs = false,
    }, metrics);
    const numbered = Layout.resolve(.{
        .width = 900,
        .height = 620,
        .editor_owned_tabs = false,
    }, .{
        .field = metrics.field,
        .next = metrics.next,
        .toggle = metrics.toggle,
        .close = metrics.close,
        .replace = metrics.replace,
        .replace_all = metrics.replace_all,
        .gutter_width = 52,
    });

    try std.testing.expectEqual(@as(f64, 12), numbered.gutter.x);
    try std.testing.expectEqual(@as(f64, 52), numbered.gutter.w);
    try std.testing.expectEqual(plain.viewport.x + 52, numbered.viewport.x);
    try std.testing.expectEqual(plain.viewport.w - 52, numbered.viewport.w);
    try std.testing.expectEqual(plain.viewport.y, numbered.gutter.y);
    try std.testing.expectEqual(plain.viewport.h, numbered.gutter.h);
}
