//! The Transfers card's rows for I/O service jobs (stage S3b): one per
//! running job of any window, with its name, progress, pause or resume, and
//! cancel. Drawn below the row of a job the window still runs itself
//! (archive extraction, until S4).
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const shell_ui = @import("ui").cairo;
const ui_theme = @import("ui").theme;
const c = @import("c.zig").api;
const app_mod = @import("app.zig");
const App = app_mod.App;
const io_service = @import("io_service.zig");
const app_jobs = @import("app_jobs.zig");
const sidebar_controls = @import("app_sidebar_controls.zig");

/// Rows shown at most; more jobs than that show the oldest.
pub const max_rows = 4;
pub const row_height = 60;

/// Hover keys: three per row, below the legacy row's.
const key_base: usize = std.math.maxInt(usize) - 3000;

pub fn rows(self: *App, out: *[max_rows]io_service.JobRecord) []io_service.JobRecord {
    return self.service.jobs.active(out);
}

/// After the job table changed: a new or finished job reflows the sidebar;
/// progress only repaints the rows.
pub fn changed(self: *App, rows_before: usize) void {
    var out: [max_rows]io_service.JobRecord = undefined;
    const now = rows(self, &out).len;
    if (now != rows_before) {
        self.clampSidebarScroll();
        self.invalidate();
        return;
    }
    if (now == 0 or self.sidebarWidth() == 0) return;
    const card = self.sidebarLayout().cards[@intFromEnum(@import("app_model.zig").SidebarSection.transfers)];
    if (!card.visible or !card.expanded) return;
    self.addDamageRegion(.{ .x = 0, .y = @floatFromInt(card.y), .w = @floatFromInt(self.sidebarWidth()), .h = @floatFromInt(card.height()) });
}

pub fn count(self: *App) usize {
    var out: [max_rows]io_service.JobRecord = undefined;
    return rows(self, &out).len;
}

pub fn height(self: *App) i32 {
    var out: [max_rows]io_service.JobRecord = undefined;
    return @intCast(rows(self, &out).len * row_height);
}

/// Row `index`'s box, below `top` (the first service row's top).
fn rowBox(self: *App, top: f64, index: usize) shell_ui.Rect {
    return .{
        .x = 12,
        .y = @floatCast(top + @as(f64, @floatFromInt(index * row_height))),
        .w = @floatCast(@max(0, self.sidebarContentWidth() - 24)),
        .h = 52,
    };
}

fn pauseRect(area: shell_ui.Rect) shell_ui.Rect {
    return sidebar_controls.buttonRect(area, 54, 2);
}

fn cancelRect(area: shell_ui.Rect) shell_ui.Rect {
    return sidebar_controls.buttonRect(area, 26, 2);
}

const Hit = struct { record: io_service.JobRecord, part: enum { body, pause, cancel } };

fn hit(self: *App, top: f64, x: f64, y: f64) ?Hit {
    var out: [max_rows]io_service.JobRecord = undefined;
    for (rows(self, &out), 0..) |record, i| {
        const area = rowBox(self, top, i);
        if (!sidebar_controls.contains(area, x, y)) continue;
        if (sidebar_controls.contains(cancelRect(area), x, y)) return .{ .record = record, .part = .cancel };
        if (app_jobs.canPause(record) and sidebar_controls.contains(pauseRect(area), x, y)) return .{ .record = record, .part = .pause };
        return .{ .record = record, .part = .body };
    }
    return null;
}

pub fn hover(self: *App, top: f64, x: f64, y: f64) usize {
    var out: [max_rows]io_service.JobRecord = undefined;
    const found = hit(self, top, x, y) orelse return 0;
    const index = for (rows(self, &out), 0..) |record, i| {
        if (record.id == found.record.id) break i;
    } else 0;
    return key_base - 3 * index - @as(usize, @intFromEnum(found.part));
}

/// Pause, resume or cancel through the service; the body opens the folder
/// a transfer of this window goes to.
pub fn click(self: *App, top: f64, x: f64, y: f64) bool {
    const found = hit(self, top, x, y) orelse return false;
    switch (found.part) {
        .cancel => send(self, .cancel_job, found.record.id),
        .pause => send(self, if (found.record.state == .paused) .resume_job else .pause_job, found.record.id),
        // A job waiting for an answer: ask here.
        .body => if (found.record.pending_conflict != 0) {
            @import("app_transfers.zig").askConflict(self, found.record.pending_conflict);
        } else if (@import("app_transfers.zig").destinationOf(self, found.record.id)) |destination| {
            self.navigate(destination);
            self.focus = .file_view;
        },
    }
    self.invalidate();
    return true;
}

fn send(self: *App, kind: io_service.CommandKind, job_id: io_service.JobId) void {
    const link = &self.service;
    const handle = link.handle orelse return;
    var command: io_service.Command = .{ .kind = kind, .job_id = job_id };
    link.outbox.send(handle, &command) catch {
        self.setStatusNotice(switch (kind) {
            .cancel_job => tr("Could not cancel file transfer"),
            .pause_job => tr("Could not pause file transfer"),
            else => tr("Could not resume file transfer"),
        }, true);
    };
}

/// "photo.jpg", or "photo.jpg and 3 more".
fn title(buf: []u8, record: *const io_service.JobRecord) []const u8 {
    const name = if (record.kind == .empty_trash) tr("Emptying Trash") else record.label();
    if (record.pending_conflict != 0) return i18n.fmt(buf, tr("{name}: needs an answer"), .{ .name = name }) catch name;
    if (record.source_count <= 1 or record.kind == .empty_trash) return name;
    return i18n.fmt(buf, tr("{name} and {count} more"), .{ .name = name, .count = record.source_count - 1 }) catch name;
}

pub fn render(self: *App, cr: *c.cairo_t, top: f64) void {
    var out: [max_rows]io_service.JobRecord = undefined;
    const palette = ui_theme.shellPalette();
    for (rows(self, &out), 0..) |*record, i| {
        const area = rowBox(self, top, i);
        if (area.w < 120) return;
        @import("app_draw.zig").drawSidebarTransferSurface(cr, area);
        var buf: [256]u8 = undefined;
        @import("app_draw.zig").drawTransferProgressRow(
            cr,
            area,
            title(&buf, record),
            app_jobs.fraction(record.*),
            ui_theme.global.sidebarForeground(),
            palette.accent,
            shell_ui.statusSize(),
        );
        if (app_jobs.canPause(record.*)) {
            const rect = pauseRect(area);
            sidebar_controls.render(cr, rect, if (record.state == .paused) .play else .pause, sidebar_controls.contains(rect, self.mouse_x, self.mouse_y));
        }
        const rect = cancelRect(area);
        sidebar_controls.render(cr, rect, .close, sidebar_controls.contains(rect, self.mouse_x, self.mouse_y));
    }
}
