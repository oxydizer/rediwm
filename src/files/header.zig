// Header geometry is shared by painting and pointer hit testing.
const std = @import("std");
const IconId = @import("ui").layout.IconId;
pub const Action = enum { back, forward, up, refresh, new, cut, copy, paste, trash, grid, list, sort, filter, search, git_view };
pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    pub fn contains(r: Rect, x: f64, y: f64) bool {
        return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
    }
};
pub const Button = struct { action: Action, rect: Rect };
/// The Git View checkbox needs room between the clipboard buttons and the
/// view buttons, so inside a repository the one-row layout starts later.
fn isNarrow(width: i32, git: bool) bool {
    return width < if (git) @as(i32, 700) else 600;
}
pub fn height(width: i32, git: bool) i32 {
    return if (isNarrow(width, git)) 152 else 112;
}
pub fn rect(width: i32, git: bool, action: Action) Rect {
    const w: f64 = @floatFromInt(width);
    const narrow = isNarrow(width, git);
    const controls_y: f64 = if (narrow) 110 else 64;
    return switch (action) {
        .back => .{ .x = 12, .y = 12, .w = 30, .h = 32 },
        .forward => .{ .x = 44, .y = 12, .w = 30, .h = 32 },
        .up => .{ .x = 76, .y = 12, .w = 30, .h = 32 },
        .refresh => .{ .x = w - 78, .y = 12, .w = 30, .h = 32 },
        .search => .{ .x = w - 44, .y = 12, .w = 30, .h = 32 },
        .new => .{ .x = 16, .y = 64, .w = 92, .h = 36 },
        .cut, .copy, .paste, .trash => .{ .x = 126 + @as(f64, @floatFromInt(@intFromEnum(action) - @intFromEnum(Action.cut))) * 38, .y = 64, .w = 32, .h = 36 },
        .grid => .{ .x = w - 286, .y = controls_y, .w = 34, .h = 36 },
        .list => .{ .x = w - 250, .y = controls_y, .w = 34, .h = 36 },
        .sort => .{ .x = w - 204, .y = controls_y, .w = 104, .h = 36 },
        .filter => .{ .x = w - 90, .y = controls_y, .w = 74, .h = 36 },
        .git_view => .{ .x = w - 402, .y = controls_y, .w = 92, .h = 36 },
    };
}
/// The checkbox exists only inside a repository, and not at widths too small
/// to hold it left of the view buttons.
pub fn visible(width: i32, git: bool, action: Action) bool {
    return action != .git_view or (git and rect(width, git, action).x >= 16);
}
/// Thin rule between the checkbox and the view buttons.
pub fn gitSeparator(width: i32) Rect {
    const r = rect(width, true, .grid);
    return .{ .x = r.x - 12, .y = r.y + 8, .w = 1, .h = r.h - 16 };
}
pub fn field(width: i32) Rect {
    return .{ .x = 116, .y = 10, .w = @floatFromInt(width - 204), .h = 36 };
}
pub fn hit(width: i32, git: bool, x: f64, y: f64) ?Action {
    inline for (std.meta.tags(Action)) |action| {
        if (visible(width, git, action) and rect(width, git, action).contains(x, y)) return action;
    }
    return null;
}

/// Each action's glyph in the shell's icon set (ui/layout.zig's IconId).
pub fn glyph(action: Action) IconId {
    return switch (action) {
        .back => .chevron_left,
        .forward => .chevron_right,
        .up => .chevron_up,
        .refresh => .refresh,
        .new => .plus,
        .cut => .cut,
        .copy => .copy,
        .paste => .paste,
        .trash => .trash,
        .grid => .view_grid,
        .list => .view_list,
        .sort => .sort,
        .filter => .filter,
        .search => .search,
        .git_view => .git_branch,
    };
}

test "header controls do not overlap at narrow and wide widths" {
    for ([_]bool{ false, true }) |git| {
        for ([_]i32{ 360, 417, 418, 500, 599, 600, 699, 700, 960 }) |width| {
            for (std.meta.tags(Action), 0..) |action, i| {
                if (!visible(width, git, action)) continue;
                const r = rect(width, git, action);
                try std.testing.expect(r.x >= 0 and r.x + r.w <= @as(f64, @floatFromInt(width)));
                try std.testing.expect(r.y + r.h <= @as(f64, @floatFromInt(height(width, git))));
                for (std.meta.tags(Action)[i + 1 ..]) |other| {
                    if (!visible(width, git, other)) continue;
                    const b = rect(width, git, other);
                    try std.testing.expect(r.x + r.w <= b.x or b.x + b.w <= r.x or r.y + r.h <= b.y or b.y + b.h <= r.y);
                }
            }
            // The checkbox exists only in repositories wide enough for it, and
            // other layouts do not change for non-repositories.
            try std.testing.expect(visible(width, git, .git_view) == (git and width >= 418));
            try std.testing.expectEqual(git and width < 700 or width < 600, height(width, git) == 152);
            if (visible(width, git, .git_view)) {
                const box = rect(width, git, .git_view);
                try std.testing.expectEqual(@as(?Action, .git_view), hit(width, git, box.x + 4, box.y + 4));
                const rule = gitSeparator(width);
                try std.testing.expect(box.x + box.w <= rule.x and rule.x + rule.w <= rect(width, git, .grid).x);
            }
        }
    }
}
