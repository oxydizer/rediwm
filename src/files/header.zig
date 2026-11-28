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
const row_pad = 12;
const row_pad_y = 6;
const cluster_gap = 8;
const button_side = 28;
const button_pitch = button_side + 2;
const field_height = 30;
pub const field_pad_x = 10;
pub const field_pad_y = 4;
pub const field_font = 13;
pub const nav_height = 2 * row_pad_y + field_height;
pub const action_height = 2 * row_pad_y + button_side;
const field_left = row_pad + 2 * button_pitch + button_side + cluster_gap;
const field_right = row_pad + button_pitch + button_side + cluster_gap;
/// The Git View checkbox needs room between the clipboard buttons and the
/// view buttons, so inside a repository the one-row layout starts later.
pub fn isNarrow(width: i32, git: bool) bool {
    return width < if (git) @as(i32, 700) else 600;
}
pub fn height(width: i32, git: bool) i32 {
    return nav_height + action_height * @as(i32, if (isNarrow(width, git)) 2 else 1);
}
pub fn rect(width: i32, git: bool, action: Action) Rect {
    const w: f64 = @floatFromInt(width);
    const narrow = isNarrow(width, git);
    const nav_y = (nav_height - button_side) / 2;
    const action_y = nav_height + row_pad_y;
    const controls_y: f64 = action_y + @as(f64, if (narrow) action_height else 0);
    const filter_w = 78;
    const sort_w = 104;
    const filter_x = w - row_pad - filter_w;
    const sort_x = filter_x - cluster_gap - sort_w;
    const list_x = sort_x - cluster_gap - button_side;
    const grid_x = list_x - button_pitch;
    const new_w = 92;
    return switch (action) {
        .back, .forward, .up => .{ .x = row_pad + @as(f64, @floatFromInt(@backingInt(action))) * button_pitch, .y = nav_y, .w = button_side, .h = button_side },
        .refresh => .{ .x = w - row_pad - button_pitch - button_side, .y = nav_y, .w = button_side, .h = button_side },
        .search => .{ .x = w - row_pad - button_side, .y = nav_y, .w = button_side, .h = button_side },
        .new => .{ .x = row_pad, .y = action_y, .w = new_w, .h = button_side },
        .cut, .copy, .paste, .trash => .{ .x = row_pad + new_w + cluster_gap + @as(f64, @floatFromInt(@backingInt(action) - @backingInt(Action.cut))) * button_pitch, .y = action_y, .w = button_side, .h = button_side },
        .grid => .{ .x = grid_x, .y = controls_y, .w = button_side, .h = button_side },
        .list => .{ .x = list_x, .y = controls_y, .w = button_side, .h = button_side },
        .sort => .{ .x = sort_x, .y = controls_y, .w = sort_w, .h = button_side },
        .filter => .{ .x = filter_x, .y = controls_y, .w = filter_w, .h = button_side },
        .git_view => .{ .x = w - 406, .y = controls_y, .w = 92, .h = button_side },
    };
}
/// The checkbox exists only inside a repository, and not at widths too small
/// to hold it left of the view buttons.
pub fn visible(width: i32, git: bool, action: Action) bool {
    return action != .git_view or (git and rect(width, git, action).x >= row_pad);
}
/// Thin rule between the checkbox and the view buttons.
pub fn gitSeparator(width: i32) Rect {
    const r = rect(width, true, .grid);
    return .{ .x = r.x - 12, .y = r.y + 8, .w = 1, .h = r.h - 16 };
}
pub fn field(width: i32) Rect {
    return .{ .x = field_left, .y = row_pad_y, .w = @floatFromInt(width - field_left - field_right), .h = field_height };
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
                try std.testing.expectEqual(@as(f64, 28), r.h);
                switch (action) {
                    .new, .sort, .filter, .git_view => {},
                    else => try std.testing.expectEqual(@as(f64, 28), r.w),
                }
                try std.testing.expectEqual(@as(?Action, action), hit(width, git, r.x, r.y));
                try std.testing.expectEqual(@as(?Action, null), hit(width, git, r.x + r.w, r.y));
                try std.testing.expectEqual(@as(?Action, null), hit(width, git, r.x, r.y + r.h));
                const f = field(width);
                try std.testing.expect(r.x + r.w <= f.x or f.x + f.w <= r.x or r.y + r.h <= f.y or f.y + f.h <= r.y);
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
            try std.testing.expectEqual(git and width < 700 or width < 600, height(width, git) == 122);
            const f = field(width);
            try std.testing.expectEqual(@as(f64, 30), f.h);
            const back = rect(width, git, .back);
            try std.testing.expectEqual(back.y + back.h / 2, f.y + f.h / 2);
            if (visible(width, git, .git_view)) {
                const box = rect(width, git, .git_view);
                try std.testing.expectEqual(@as(?Action, .git_view), hit(width, git, box.x + 4, box.y + 4));
                const rule = gitSeparator(width);
                try std.testing.expect(box.x + box.w <= rule.x and rule.x + rule.w <= rect(width, git, .grid).x);
            }
        }
    }
}
