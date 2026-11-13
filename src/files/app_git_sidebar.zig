//! Files Git sidebar: branch card, status list and their geometry.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const App = @import("app.zig").App;
const c = @import("c.zig").api;
const git = @import("git.zig");
const header = @import("header.zig");
const shell_ui = @import("ui").cairo;
const ui_theme = @import("ui").theme;
const git_header_h = App.git_header_h;
const git_row_h = App.git_row_h;
const GitBranchRow = App.GitBranchRow;
const ViewItem = @import("app_model.zig").ViewItem;
const setSource = @import("app_draw.zig").setSource;
const withAlpha = @import("app_draw.zig").withAlpha;
const roundedRect = @import("app_draw.zig").roundedRect;
const drawEllipsis = @import("app_draw.zig").drawEllipsis;
const drawText = @import("app_draw.zig").drawText;
const measureText = @import("app_draw.zig").measureText;

pub fn gitSidebarHeight(self: *App) i32 {
    return if (self.repository() != null) 44 + @as(i32, @intFromFloat(self.gitCardHeight())) else 0;
}

// HEAD is listed first when it is not a branch (detached or unborn).
pub fn gitHeadExtra(repo: git.Repository) usize {
    for (repo.branches) |name| {
        if (std.mem.eql(u8, name, repo.branch)) return 0;
    }
    return 1;
}

pub fn gitBranchRowCount(repo: git.Repository) usize {
    return repo.branches.len + gitHeadExtra(repo);
}

pub fn gitBranchRow(repo: git.Repository, i: usize) GitBranchRow {
    const extra = gitHeadExtra(repo);
    if (i < extra) return .{ .name = repo.branch, .current = true };
    const name = repo.branches[i - extra];
    return .{ .name = name, .current = std.mem.eql(u8, name, repo.branch) };
}

// Branch rows followed by the "New branch" row.
pub fn gitCardHeight(self: *App) f64 {
    const repo = self.repository() orelse return git_header_h;
    if (!self.git_expanded) return git_header_h;
    return git_header_h + @as(f64, @floatFromInt(gitBranchRowCount(repo) + 1)) * git_row_h + 4;
}

pub fn gitCard(self: *App) header.Rect {
    return .{ .x = 10, .y = @floatFromInt(self.pinRowY(self.pins.items.items.len) + 44 + self.deviceBlock() + self.torrentSidebarHeight() + self.fileOpsSidebarHeight()), .w = @floatFromInt(self.sidebarWidth() - 20 - self.scrollbarGutter()), .h = self.gitCardHeight() };
}

pub fn renderGitSidebar(self: *App, cr: *c.cairo_t, content_width: f64) void {
    const repo = self.repository() orelse return;
    const card = self.gitCard();
    setSource(cr, ui_theme.global.sidebarForeground());
    drawText(cr, "GIT", 24, card.y - 10, shell_ui.headingSize(), true);
    if (shell_ui.Layer.begin(cr, .{ .x = 23, .y = @floatCast(card.y + 6), .w = 20, .h = 20 })) |icon_layer| {
        var layer = icon_layer;
        layer.renderer.drawIcon(0, 0, 20, 20, .{ .id = .git_branch, .color = ui_theme.global.sidebarForeground() });
        layer.finish();
    }
    setSource(cr, ui_theme.global.sidebarForeground());
    drawEllipsis(cr, std.fs.path.basename(repo.root), 50, card.y + 22, content_width - 80, shell_ui.textSize(), false);
    if (shell_ui.Layer.begin(cr, .{ .x = @floatCast(content_width - 28), .y = @floatCast(card.y + 9), .w = 14, .h = 14 })) |icon_layer| {
        var layer = icon_layer;
        layer.renderer.drawIcon(0, 0, 14, 14, .{ .id = if (self.git_expanded) .chevron_down else .chevron_right, .color = ui_theme.global.sidebarForeground() });
        layer.finish();
    }
    if (!self.git_expanded) return;
    const right = content_width - 18;
    const rows = gitBranchRowCount(repo);
    for (0..rows + 1) |i| {
        const row_y = card.y + git_header_h + @as(f64, @floatFromInt(i)) * git_row_h;
        const baseline = row_y + 19;
        setSource(cr, ui_theme.global.sidebarForeground());
        if (i == rows) {
            if (shell_ui.Layer.begin(cr, .{ .x = 24, .y = @floatCast(row_y + 7), .w = 14, .h = 14 })) |icon_layer| {
                var layer = icon_layer;
                layer.renderer.drawIcon(0, 0, 14, 14, .{ .id = .plus, .color = ui_theme.global.sidebarForeground() });
                layer.finish();
            }
            drawText(cr, tr("New branch"), 44, baseline, shell_ui.textSize(), false);
            break;
        }
        const row = gitBranchRow(repo, i);
        var counts_width: f64 = 0;
        if (row.current) {
            if (shell_ui.Layer.begin(cr, .{ .x = 24, .y = @floatCast(row_y + 7), .w = 14, .h = 14 })) |icon_layer| {
                var layer = icon_layer;
                layer.renderer.drawIcon(0, 0, 14, 14, .{ .id = .checkmark, .color = ui_theme.global.sidebarForeground() });
                layer.finish();
            }
            if (repo.upstream) {
                var counts_buf: [80]u8 = undefined;
                const counts = std.fmt.bufPrint(&counts_buf, "↑{d}  ↓{d}", .{ repo.ahead, repo.behind }) catch "";
                counts_width = measureText(cr, counts, shell_ui.statusSize(), false);
                drawText(cr, counts, right - counts_width, baseline, shell_ui.statusSize(), false);
            }
        }
        var detached_buf: [40]u8 = undefined;
        const label = if (row.current and std.mem.eql(u8, row.name, "(detached)")) i18n.fmt(&detached_buf, tr("Detached {count}"), .{ .count = repo.oid[0..@min(7, repo.oid.len)] }) catch "Detached" else row.name;
        drawEllipsis(cr, label, 44, baseline, @max(0, right - counts_width - 50), shell_ui.textSize(), row.current);
    }
}

pub fn renderGitStatus(self: *App, cr: *c.cairo_t, item: ViewItem, y: f64) void {
    const column = self.listColumn(1);
    const x = column.x + 4;
    const status = item.git_status;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, column.x, y, column.w, @floatFromInt(self.cardHeight()));
    c.cairo_clip(cr);
    if (status != .clean) {
        roundedRect(cr, x, y + 5, 26, @as(f64, @floatFromInt(self.cardHeight())) - 10, 5);
        const tint = if (status == .deleted or status == .conflict) ui_theme.global.danger else ui_theme.global.accent;
        setSource(cr, withAlpha(tint, 0.25));
        c.cairo_fill(cr);
    }
    setSource(cr, ui_theme.global.window_fg);
    drawText(cr, status.label(), x + (26 - measureText(cr, status.label(), shell_ui.textSize(), true)) / 2, y + self.listBaseline(), shell_ui.textSize(), true);
    if (item.git_lines) |lines| {
        if (lines.added == 0 and lines.removed == 0) return;
        var buf: [32]u8 = undefined;
        var pen = x + 36;
        if (lines.added > 0) {
            const label = std.fmt.bufPrint(&buf, "+{d}", .{lines.added}) catch "";
            setSource(cr, ui_theme.global.app_git_added);
            drawText(cr, label, pen, y + self.listBaseline(), shell_ui.textSize(), false);
            pen += measureText(cr, label, shell_ui.textSize(), false) + 8;
        }
        if (lines.removed > 0) {
            const label = std.fmt.bufPrint(&buf, "−{d}", .{lines.removed}) catch "";
            setSource(cr, ui_theme.global.danger);
            drawText(cr, label, pen, y + self.listBaseline(), shell_ui.textSize(), false);
        }
    }
}
