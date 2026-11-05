//! Files drawing helpers: sizes, text, rounded shapes and damage clips.

const std = @import("std");
const c = @import("c.zig").api;
const header = @import("header.zig");
const shell_ui = @import("ui").cairo;
const ui_theme = @import("ui").theme;
const Editor = @import("editor.zig").Editor;

pub fn formatSize(bytes: i64, buf: []u8) []const u8 {
    if (bytes < 0) return "—";
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "—";
    }
    const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
    if (kb < 1024.0) {
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{kb}) catch "—";
    }
    const mb = kb / 1024.0;
    if (mb < 1024.0) {
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{mb}) catch "—";
    }
    const gb = mb / 1024.0;
    if (gb < 1024.0) {
        return std.fmt.bufPrint(buf, "{d:.1} GB", .{gb}) catch "—";
    }
    const tb = gb / 1024.0;
    return std.fmt.bufPrint(buf, "{d:.1} TB", .{tb}) catch "—";
}

pub fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1000000);
}

pub fn setSource(cr: *c.cairo_t, color: [4]f32) void {
    c.cairo_set_source_rgba(cr, color[0], color[1], color[2], color[3]);
}

/// A straight-alpha theme colour at `alpha` of its own opacity.
pub fn withAlpha(color: [4]f32, alpha: f32) [4]f32 {
    return .{ color[0], color[1], color[2], color[3] * alpha };
}

pub fn roundedRect(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64, r: f64) void {
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + w - r, y + r, r, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, x + w - r, y + h - r, r, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, x + r, y + h - r, r, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, x + r, y + r, r, std.math.pi, 3 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
}

pub fn drawSpinner(cr: *c.cairo_t, cx: f64, cy: f64, r: f64) void {
    const angle = @as(f64, @floatFromInt(@mod(nowMs(), 1000))) / 1000.0 * 2.0 * std.math.pi;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    setSource(cr, ui_theme.global.file_spinner);
    c.cairo_set_line_width(cr, 1.5);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_arc(cr, cx, cy, r, angle, angle + 1.5 * std.math.pi);
    c.cairo_stroke(cr);
}

/// A damage scissor must cover whole device pixels. Fractional clip edges
/// blend a second copy of the background over retained pixels and leave seams.
pub fn clipDamage(cr: *c.cairo_t, rect: header.Rect) void {
    var x1 = rect.x;
    var y1 = rect.y;
    var x2 = rect.x + rect.w;
    var y2 = rect.y + rect.h;
    c.cairo_user_to_device(cr, &x1, &y1);
    c.cairo_user_to_device(cr, &x2, &y2);
    var matrix: c.cairo_matrix_t = undefined;
    c.cairo_get_matrix(cr, &matrix);
    c.cairo_identity_matrix(cr);
    c.cairo_rectangle(cr, @floor(x1), @floor(y1), @ceil(x2) - @floor(x1), @ceil(y2) - @floor(y1));
    c.cairo_clip(cr);
    c.cairo_set_matrix(cr, &matrix);
}

/// Like `drawEllipsis`, but keeps the end of `text`: "…/dir/file.zig".
pub fn drawHeadEllipsis(cr: *c.cairo_t, text: []const u8, x: f64, y: f64, width: f64, size: f64, bold: bool) void {
    if (width <= 0) return;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, x, y - size * 1.5, width, size * 2);
    c.cairo_clip(cr);
    if (measureText(cr, text, size, bold) <= width) return drawText(cr, text, x, y, size, bold);
    const dots = measureText(cr, "…", size, bold);
    var start: usize = 0;
    while (start < text.len and measureText(cr, text[start..], size, bold) + dots > width) start = Editor.next(text, start);
    drawText(cr, "…", x, y, size, bold);
    drawText(cr, text[start..], x + dots, y, size, bold);
}

pub fn drawEllipsis(cr: *c.cairo_t, text: []const u8, x: f64, y: f64, width: f64, size: f64, bold: bool) void {
    if (width <= 0) return;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, x, y - size * 1.5, width, size * 2);
    c.cairo_clip(cr);
    if (measureText(cr, text, size, bold) <= width) return drawText(cr, text, x, y, size, bold);
    const dots = measureText(cr, "…", size, bold);
    var end = text.len;
    while (end > 0 and measureText(cr, text[0..end], size, bold) + dots > width) end = Editor.prev(text, end);
    drawText(cr, text[0..end], x, y, size, bold);
    drawText(cr, "…", x + measureText(cr, text[0..end], size, bold), y, size, bold);
}

// Text goes through the shell's renderer (text.zig, Manrope), not Cairo's
// toy font API, so Files reads like the rest of the desktop.
pub fn drawText(cr: *c.cairo_t, str: []const u8, x: f64, y: f64, size: f64, bold: bool) void {
    shell_ui.drawText(cr, str, x, y, size, bold);
}

/// The face's own vertical extent at a size, both positive and measured from
/// the baseline. Anything that has to align with drawn text — a caret, a
/// selection highlight — has to come from these; a hand-tuned pixel offset
/// only happens to be right for one font at one size.
pub const FontMetrics = shell_ui.FontMetrics;

pub fn fontMetrics(cr: *c.cairo_t, size: f64) FontMetrics {
    return shell_ui.fontMetrics(cr, size);
}

pub fn measureText(cr: *c.cairo_t, str: []const u8, size: f64, bold: bool) f64 {
    return shell_ui.measureText(cr, str, size, bold);
}

pub fn formatPermissions(mode: c.mode_t) [10]u8 {
    var result = "----------".*;
    result[0] = switch (mode & c.S_IFMT) {
        c.S_IFDIR => 'd',
        c.S_IFLNK => 'l',
        c.S_IFCHR => 'c',
        c.S_IFBLK => 'b',
        c.S_IFIFO => 'p',
        c.S_IFSOCK => 's',
        c.S_IFREG => '-',
        else => '?',
    };
    for (0..9) |i| {
        const bit = @as(c.mode_t, 0o400) >> @as(std.math.Log2Int(c.mode_t), @intCast(i));
        if (mode & bit != 0) result[i + 1] = "rwx"[i % 3];
    }
    if (mode & c.S_ISUID != 0) result[3] = if (mode & c.S_IXUSR != 0) 's' else 'S';
    if (mode & c.S_ISGID != 0) result[6] = if (mode & c.S_IXGRP != 0) 's' else 'S';
    if (mode & c.S_ISVTX != 0) result[9] = if (mode & c.S_IXOTH != 0) 't' else 'T';
    return result;
}
