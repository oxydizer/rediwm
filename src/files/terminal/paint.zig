//! Terminal grid painting, cell metrics, palette and selection text, shared
//! by the Files drawer and RediTerm. Cairo through the shared text
//! rasterizer and font fallback; no host state.
const std = @import("std");
const ui = @import("ui");
const theme = ui.theme;
const shell = ui.cairo;
const c = @import("c_gfx");
const model = @import("model.zig");
const tc = model.c;

pub const Metrics = struct {
    cell_w: f64 = 9,
    cell_h: f64 = 20,
    ascent: f64 = 15,

    /// The exact shared mono advance and line height at the UI text size.
    pub fn measure(scale: f32) Metrics {
        const size = shell.textSize();
        const vertical = ui.text.verticalMetrics(.mono, size, scale) catch null;
        return .{
            .cell_w = @max(1, ui.text.measureWidthF("M", .mono, size, scale) catch 9),
            .ascent = if (vertical) |m| m.ascent else size,
            .cell_h = @ceil(if (vertical) |m| m.ascent + m.descent + 2 else size + 5),
        };
    }
};

pub const View = struct {
    /// The grid's area; cells start at its origin and are clipped to it.
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    metrics: Metrics,
    selection: ?model.Selection = null,
    focused: bool,
    /// Draw an outlined cursor while unfocused instead of none.
    hollow_cursor: bool = false,
    /// Animated cursor position within the grid, in logical pixels.
    cursor_position: ?CursorPosition = null,
    preedit: []const u8 = "",
};

pub const CursorPosition = struct { x: f64, y: f64 };

pub const Cursor = struct {
    row: c_int,
    col: c_int,
    shape: c_int,

    pub fn get(session: *tc.FT) ?Cursor {
        var cursor: Cursor = undefined;
        return if (tc.ft_cursor(session, &cursor.row, &cursor.col, &cursor.shape)) cursor else null;
    }
};

pub fn applyPalette(session: *tc.FT) void {
    const t = theme.global;
    setColor(session, tc.FT_DEFAULT_FG, t.terminal_fg orelse t.window_fg);
    setColor(session, tc.FT_DEFAULT_BG, background());
    setColor(session, tc.FT_CURSOR_COLOR, cursorColor());
    const names = .{ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white", "bright_black", "bright_red", "bright_green", "bright_yellow", "bright_blue", "bright_magenta", "bright_cyan", "bright_white" };
    const defaults = [_][3]u8{
        .{ 24, 24, 24 },    .{ 205, 49, 49 },   .{ 13, 188, 121 }, .{ 229, 190, 11 },
        .{ 36, 114, 200 },  .{ 188, 63, 188 },  .{ 17, 168, 205 }, .{ 229, 229, 229 },
        .{ 102, 102, 102 }, .{ 241, 76, 76 },   .{ 35, 209, 139 }, .{ 245, 245, 67 },
        .{ 59, 142, 234 },  .{ 214, 112, 214 }, .{ 41, 184, 219 }, .{ 255, 255, 255 },
    };
    inline for (names, 0..) |name, i| {
        if (@field(t, "terminal_" ++ name)) |color| setColor(session, i, color) else {
            const color = defaults[i];
            tc.ft_palette(session, i, color[0], color[1], color[2]);
        }
    }
}

/// The theme's terminal background, as the palette's default background.
pub fn background() [4]f32 {
    return theme.global.terminal_bg orelse theme.global.app_bg;
}

fn cursorColor() [4]f32 {
    return theme.global.terminal_cursor orelse theme.shellPalette().caretColor();
}

fn setColor(session: *tc.FT, index: c_int, color: [4]f32) void {
    tc.ft_palette(session, index, @intFromFloat(std.math.clamp(color[0], 0, 1) * 255), @intFromFloat(std.math.clamp(color[1], 0, 1) * 255), @intFromFloat(std.math.clamp(color[2], 0, 1) * 255));
}
fn rgb(color: [3]u8) [4]f32 {
    return .{ @as(f32, @floatFromInt(color[0])) / 255, @as(f32, @floatFromInt(color[1])) / 255, @as(f32, @floatFromInt(color[2])) / 255, 1 };
}
fn cellBytes(cell: tc.FT_Cell, buffer: []u8) []const u8 {
    var len: usize = 0;
    for (cell.chars) |ch| {
        if (ch == 0 or ch > 0x10ffff) break;
        var bytes: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(ch), &bytes) catch continue;
        if (len + n > buffer.len) break;
        @memcpy(buffer[len..][0..n], bytes[0..n]);
        len += n;
    }
    if (len == 0 and buffer.len > 0) {
        buffer[0] = ' ';
        len = 1;
    }
    return buffer[0..len];
}

/// Paints the visible rows, then the cursor. ASCII runs of one style are
/// drawn together; other cells alone, so fallback shaping cannot move later
/// cells. The caller's clip (its damage) is kept, and rows and runs outside
/// it are skipped. Cell edges snap to device pixels, so a partial repaint
/// meets the untouched rows exactly and every clip stays a pixel region.
pub fn paintCells(cr: *c.cairo_t, session: *tc.FT, view: View) void {
    if (view.h <= 0 or view.w <= 0) return;
    c.cairo_save(cr);
    shell.pixelRect(cr, view.x, view.y, view.x + view.w, view.y + view.h);
    c.cairo_clip(cr);
    const clip = shell.ClipRects.read(cr);
    defer clip.deinit();
    const cw = view.metrics.cell_w;
    const ch = view.metrics.cell_h;
    const ascent = view.metrics.ascent;
    const rows = @min(tc.ft_rows(session), @as(i32, @intFromFloat(@ceil(view.h / ch))));
    var row: i32 = 0;
    while (row < rows) : (row += 1) {
        const top = view.y + @as(f64, @floatFromInt(row)) * ch;
        const bottom = view.y + @as(f64, @floatFromInt(row + 1)) * ch;
        if (!clip.touches(view.x, top, view.w, bottom - top)) continue;
        var col: i32 = 0;
        while (col < tc.ft_cols(session)) {
            var cell: tc.FT_Cell = undefined;
            if (!tc.ft_cell(session, row, col, &cell)) break;
            if (cell.width == 0) {
                col += 1;
                continue;
            }
            const selected = if (view.selection) |selection| selection.contains(tc.ft_line(session) - tc.ft_offset(session) + row, col) else false;
            const reverse = cell.attrs & tc.FT_REVERSE != 0;
            const fg = if (reverse) cell.bg else cell.fg;
            const bg = if (reverse) cell.fg else cell.bg;
            const first_col = col;
            var bytes: [16384]u8 = undefined;
            var len: usize = 0;
            const ascii_run = cell.width == 1 and cell.chars[0] >= 32 and cell.chars[0] < 127 and cell.chars[1] == 0;
            while (col < tc.ft_cols(session)) {
                var next: tc.FT_Cell = undefined;
                if (!tc.ft_cell(session, row, col, &next)) break;
                if (next.width == 0) {
                    col += 1;
                    continue;
                }
                const next_selected = if (view.selection) |selection| selection.contains(tc.ft_line(session) - tc.ft_offset(session) + row, col) else false;
                if (next.attrs != cell.attrs or !std.mem.eql(u8, &next.fg, &cell.fg) or !std.mem.eql(u8, &next.bg, &cell.bg) or selected != next_selected) break;
                if (col != first_col and (!ascii_run or next.width != 1 or next.chars[0] < 32 or next.chars[0] >= 127 or next.chars[1] != 0)) break;
                const chunk = cellBytes(next, bytes[len..]);
                len += chunk.len;
                col += @max(1, next.width);
                if (!ascii_run) break;
            }
            const x = view.x + @as(f64, @floatFromInt(first_col)) * cw;
            const right = view.x + @as(f64, @floatFromInt(col)) * cw;
            const y = top;
            const width = right - x;
            if (!clip.touches(x, y, width, bottom - top)) continue;
            shell.setSource(cr, rgb(bg));
            shell.pixelRect(cr, x, top, right, bottom);
            c.cairo_fill(cr);
            if (selected) {
                shell.setSource(cr, theme.shellPalette().selectionColor());
                shell.pixelRect(cr, x, top, right, bottom);
                c.cairo_fill(cr);
            }
            const blank = std.mem.indexOfNone(u8, bytes[0..len], " ") == null;
            if (cell.attrs & tc.FT_CONCEAL == 0) {
                shell.setSource(cr, rgb(fg));
                if (!blank) {
                    c.cairo_save(cr);
                    shell.pixelRect(cr, x, top, right, bottom);
                    c.cairo_clip(cr);
                    shell.drawStyledText(cr, bytes[0..len], x, y + ascent, shell.textSize(), if (cell.attrs & tc.FT_BOLD != 0) .mono_bold else .mono, cell.attrs & tc.FT_ITALIC != 0);
                    c.cairo_restore(cr);
                }
                if (cell.attrs & tc.FT_UNDERLINE != 0) {
                    c.cairo_rectangle(cr, x, y + ascent + 1, width, 1);
                    c.cairo_fill(cr);
                }
                if (cell.attrs & tc.FT_STRIKE != 0) {
                    c.cairo_rectangle(cr, x, y + ascent * 0.6, width, 1);
                    c.cairo_fill(cr);
                }
            }
        }
    }
    if (Cursor.get(session)) |cursor| paintCursor(cr, session, view, cursor);
    c.cairo_restore(cr);
}

fn paintCursor(cr: *c.cairo_t, session: *tc.FT, view: View, cursor: Cursor) void {
    if (!view.focused and !view.hollow_cursor) return;
    const cw = view.metrics.cell_w;
    const ch = view.metrics.cell_h;
    const rest: CursorPosition = .{
        .x = @as(f64, @floatFromInt(cursor.col)) * cw,
        .y = @as(f64, @floatFromInt(cursor.row)) * ch,
    };
    const position = if (view.focused) view.cursor_position orelse rest else rest;
    const x = view.x + position.x;
    const y = view.y + position.y;
    shell.setSource(cr, cursorColor());
    if (!view.focused) {
        c.cairo_set_line_width(cr, 1);
        c.cairo_rectangle(cr, x + 0.5, y + 0.5, cw - 1, ch - 1);
        c.cairo_stroke(cr);
        return;
    }

    const underline = cursor.shape == 2;
    c.cairo_rectangle(cr, x, y + if (underline) ch - 2 else 0, if (cursor.shape == 3) 2 else cw, if (underline) 2 else ch);
    c.cairo_fill(cr);
    if (cursor.shape == 1) paintBlockGlyphs(cr, session, view, position);
    if (view.preedit.len > 0) {
        shell.setSource(cr, theme.global.terminal_fg orelse theme.global.window_fg);
        shell.drawTextFont(cr, view.preedit, view.x + rest.x, view.y + rest.y + view.metrics.ascent, shell.textSize(), .mono);
    }
}

fn paintBlockGlyphs(cr: *c.cairo_t, session: *tc.FT, view: View, position: CursorPosition) void {
    const cw = view.metrics.cell_w;
    const ch = view.metrics.cell_h;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, view.x + position.x, view.y + position.y, cw, ch);
    c.cairo_clip(cr);

    // A moving block can cover parts of two rows and two columns. Redraw
    // their glyphs at the grid baseline, including an overlapping wide cell.
    const first_col: i32 = @max(0, @as(i32, @intFromFloat(@floor(position.x / cw))) - 1);
    const end_col: i32 = @min(tc.ft_cols(session), @as(i32, @intFromFloat(@ceil((position.x + cw) / cw))));
    const end_row: i32 = @min(tc.ft_rows(session), @as(i32, @intFromFloat(@ceil((position.y + ch) / ch))));
    var row: i32 = @intFromFloat(@floor(position.y / ch));
    shell.setSource(cr, background());
    while (row < end_row) : (row += 1) {
        const top = view.y + @as(f64, @floatFromInt(row)) * ch;
        c.cairo_save(cr);
        c.cairo_rectangle(cr, view.x + position.x, top, cw, ch);
        c.cairo_clip(cr);
        var col = first_col;
        while (col < end_col) : (col += 1) {
            var cell: tc.FT_Cell = undefined;
            if (!tc.ft_cell(session, row, col, &cell) or cell.width == 0 or cell.chars[0] == 0 or cell.attrs & tc.FT_CONCEAL != 0) continue;
            var text: [24]u8 = undefined;
            const pen = view.x + @as(f64, @floatFromInt(col)) * cw;
            shell.drawStyledText(cr, cellBytes(cell, &text), pen, top + view.metrics.ascent, shell.textSize(), if (cell.attrs & tc.FT_BOLD != 0) .mono_bold else .mono, cell.attrs & tc.FT_ITALIC != 0);
        }
        c.cairo_restore(cr);
    }
}

/// The selected text, rows joined by newlines unless they wrapped, trailing
/// blanks trimmed. Bounded to the 1 MiB clipboard limit.
pub fn selectionText(allocator: std.mem.Allocator, session: *tc.FT, selection: model.Selection) ![]u8 {
    const ends = selection.ordered();
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var line = @max(ends[0].line, tc.ft_line(session) - tc.ft_history(session));
    const last_line = @min(ends[1].line, tc.ft_line(session) + tc.ft_rows(session) - 1);
    while (line <= last_line) : (line += 1) {
        const start = if (line == ends[0].line) ends[0].col else 0;
        const end = if (line == ends[1].line) ends[1].col else tc.ft_cols(session);
        const begin = bytes.items.len;
        var col = start;
        while (col < end) : (col += 1) {
            var cell: tc.FT_Cell = undefined;
            if (!tc.ft_cell_at(session, line, col, &cell) or cell.width == 0) continue;
            if (cell.chars[0] == 0) try bytes.append(allocator, ' ') else for (cell.chars) |ch| {
                if (ch == 0 or ch == std.math.maxInt(u32)) break;
                var encoded: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(ch), &encoded) catch continue;
                try bytes.appendSlice(allocator, encoded[0..len]);
            }
            if (bytes.items.len > 1024 * 1024 - 32) return error.TooLarge;
        }
        if (!tc.ft_wrapped_at(session, line)) {
            while (bytes.items.len > begin and bytes.items[bytes.items.len - 1] == ' ') _ = bytes.pop();
            if (line < last_line) try bytes.append(allocator, '\n');
        }
    }
    return bytes.toOwnedSlice(allocator);
}
