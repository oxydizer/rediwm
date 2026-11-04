//! The save, trash and discard dialogs and their background operations.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const c = @import("../files/c.zig").api;
const view = @import("view.zig");
const Rect = view.Rect;
const edit = @import("edit.zig");
const Editor = @import("../files/editor.zig").Editor;
const shell_ui = @import("ui").cairo;
const ui_button = @import("ui").widgets.button;
const ui_dialog = @import("ui").widgets.dialog;
const ui_field = @import("ui").widgets.field;
const deletion = @import("../delete_dialog.zig");
const ui_theme = @import("ui").theme;
const a = std.heap.c_allocator;
const app_mod = @import("app.zig");
const App = app_mod.App;
const clippedText = app_mod.clippedText;
const shellRect = app_mod.shellRect;
const setSource = app_mod.setSource;
const drawText = app_mod.drawText;
const measureText = app_mod.measureText;

pub fn openSave(self: *App) void {
    if (self.image == null) return;
    self.cancelDrag();
    if (self.crop_mode) {
        self.applyCrop();
        if (self.crop_mode) return;
    }
    const path = self.paths[self.selected];
    const raw_base = std.fs.path.stem(path);
    var base_len = @min(raw_base.len, 230);
    while (base_len > 0 and base_len < raw_base.len and raw_base[base_len] & 0xc0 == 0x80) base_len -= 1;
    const base = if (std.unicode.utf8ValidateSlice(raw_base[0..base_len]) and std.mem.indexOfAny(u8, raw_base[0..base_len], "\r\n") == null) raw_base[0..base_len] else "image";
    const dir = std.fs.path.dirname(path) orelse ".";
    var buf: [4096]u8 = undefined;
    var name_buf: [1024]u8 = undefined;
    var suggested = false;
    for (0..10000) |n| {
        const name = if (n == 0) std.fmt.bufPrint(&name_buf, "{s}-edited.png", .{base}) catch "edited.png" else std.fmt.bufPrint(&name_buf, "{s}-edited-{d}.png", .{ base, n }) catch "edited.png";
        const dest = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0) catch {
            self.message(tr("The filename is too long."));
            return;
        };
        var st: c.struct_stat = undefined;
        if (c.lstat(dest, &st) == 0) continue;
        self.filename.set(a, name) catch {
            self.message(tr("Not enough memory."));
            return;
        };
        self.filename.anchor = 0;
        self.filename.cursor = name.len - 4;
        suggested = true;
        break;
    }
    if (!suggested) {
        self.filename.set(a, "edited.png") catch {
            self.message(tr("Not enough memory."));
            return;
        };
        self.filename.select_all = true;
    }
    self.dialog = .save;
    self.notice_len = 0;
    self.dirty = true;
}

pub fn deleteAction(self: *App, action: deletion.Action) void {
    switch (action) {
        .none => {},
        .cancel => {
            self.dialog = .none;
            self.deletion.deinit();
            self.notice_len = 0;
        },
        .toggle => self.deletion.permanent = !self.deletion.permanent,
        .confirm => self.confirmDialog(),
    }
    self.dirty = true;
}

pub fn confirmDialog(self: *App) void {
    switch (self.dialog) {
        .none => {},
        .discard => self.openSave(),
        .save => {
            const name = self.filename.text.items;
            if (name.len == 0 or !std.unicode.utf8ValidateSlice(name) or std.mem.indexOfScalar(u8, name, 0) != null) {
                self.message(tr("Enter a filename."));
                return;
            }
            if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(name), ".png")) {
                self.message(tr("Use a .png filename to save a PNG copy."));
                return;
            }
            if (!std.fs.path.isAbsolute(name)) @import("../files/ops.zig").validateFilename(name) catch {
                self.message(tr("Enter a filename or an absolute path."));
                return;
            };
            const path = if (std.fs.path.isAbsolute(name)) a.dupeSentinel(u8, name, 0) catch return else std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ std.fs.path.dirname(self.paths[self.selected]) orelse ".", name }, 0) catch return;
            defer a.free(path);
            self.operation = edit.Operation.start(.save, self.io, path, self.image, null) catch {
                self.message(tr("Could not start saving."));
                return;
            };
            self.notice_len = 0;
            self.dirty = true;
        },
        .trash => {
            self.operation = edit.Operation.start(if (self.deletion.permanent) .delete else .trash, self.io, self.deletion.paths.items[0], null, self.trash_stamp) catch {
                self.message(tr("Could not start deleting this file."));
                return;
            };
            self.notice_len = 0;
            self.dirty = true;
        },
    }
}

pub fn syncOperation(self: *App) void {
    const op = self.operation orelse return;
    if (!op.done.load(.acquire)) return;
    defer op.deinit();
    self.operation = null;
    self.dirty = true;
    if (op.err) |err| {
        if (err == error.FileChanged and op.kind != .save) {
            self.dialog = .none;
            self.deletion.deinit();
        }
        self.message(switch (err) {
            error.PathAlreadyExists => tr("That file already exists. Choose another name."),
            error.FileChanged => tr("The file changed. Please try again."),
            error.GioNotAvailable => tr("Trash is unavailable: install gio to use it."),
            else => if (op.kind == .save) tr("Could not save. Check the folder and permissions.") else if (op.kind == .delete) tr("Could not delete. The file was kept.") else tr("Could not move to Trash. The file was kept."),
        });
        return;
    }
    self.dialog = .none;
    if (op.kind != .save) self.deletion.deinit();
    if (op.kind == .save) {
        self.modified = false;
        self.setTitle();
        if (i18n.fmt(&self.notice, tr("Saved {name}"), .{ .name = std.fs.path.basename(op.path) })) |saved_message| {
            self.notice_len = saved_message.len;
        } else |_| self.message(tr("Saved PNG copy."));
        self.finishPending();
    } else {
        var pos = self.position();
        if (self.image) |im| im.deinit();
        self.image = null;
        if (self.original) |im| im.deinit();
        self.original = null;
        self.modified = false;
        // Command-line lists may contain the same pathname more than once.
        var i: usize = 0;
        while (i < self.order.items.len) {
            if (std.mem.eql(u8, self.paths[self.order.items[i]], op.path)) {
                _ = self.order.orderedRemove(i);
                if (i < pos) pos -= 1;
            } else i += 1;
        }
        if (self.count() == 0) {
            self.closed = true;
            return;
        }
        self.select(self.indexAt(@min(pos, self.count() - 1)));
        self.message(tr("Moved to Trash."));
    }
}

pub fn dialogRect(self: *const App) Rect {
    const w = @min(560, @as(f64, @floatFromInt(self.w - 32)));
    const h: f64 = 204;
    return .{ .x = (@as(f64, @floatFromInt(self.w)) - w) / 2, .y = (@as(f64, @floatFromInt(self.h)) - h) / 2, .w = w, .h = h };
}

pub fn dialogButton(self: *const App, index: usize) Rect {
    const r = self.dialogRect();
    const n: f64 = if (self.dialog == .discard) 3 else 2;
    const w = (r.w - 40 - (n - 1) * 8) / n;
    return .{ .x = r.x + 20 + @as(f64, @floatFromInt(index)) * (w + 8), .y = r.y + r.h - 52, .w = w, .h = 32 };
}

pub fn filenameRect(self: *const App) Rect {
    const r = self.dialogRect();
    return .{ .x = r.x + 20, .y = r.y + 76, .w = r.w - 40, .h = 34 };
}

pub fn placeCaret(self: *App, extend: bool) void {
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 1, 1);
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return;
    defer c.cairo_destroy(cr);
    const target = self.px - self.filenameText().x + self.filename.scroll;
    const bytes = self.filename.text.items;
    var pos: usize = 0;
    while (pos < bytes.len) {
        const next = Editor.next(bytes, pos);
        if (target < (measureText(cr, bytes[0..pos], shell_ui.textSize(), false) + measureText(cr, bytes[0..next], shell_ui.textSize(), false)) / 2) break;
        pos = next;
    }
    self.filename.move(pos, extend);
}

/// Where the filename's text runs inside its field.
pub fn filenameText(self: *const App) shell_ui.Rect {
    return ui_field.arrange(shellRect(self.filenameRect()), .{}, ui_theme.shellPalette()).text;
}

pub fn drawDialog(self: *App, cr: *c.cairo_t) void {
    if (self.dialog == .trash) {
        self.deletion.draw(cr, self.w, self.h, self.px, self.py, null);
        const note = if (self.operation != null) tr("Working…") else self.notice[0..self.notice_len];
        if (note.len > 0) {
            setSource(cr, ui_theme.global.window_fg);
            drawText(cr, note, 16, @floatFromInt(self.h - 8), shell_ui.statusSize(), false);
        }
        return;
    }
    setSource(cr, ui_theme.global.image_dialog_backdrop);
    c.cairo_paint(cr);
    const r = self.dialogRect();
    const t = ui_theme.shellPalette();
    // Frame, field and buttons are shell UI; the text goes on top.
    if (shell_ui.Layer.begin(cr, shellRect(r))) |begun| {
        var layer = begun;
        const lr = &layer.renderer;
        ui_dialog.paintFrame(lr, layer.local());
        if (self.dialog == .save) {
            const f = self.filenameRect();
            _ = ui_field.paintFrame(lr, .{ .x = @floatCast(f.x - r.x), .y = @floatCast(f.y - r.y), .w = @floatCast(f.w), .h = @floatCast(f.h) }, .{}, .{ .focused = true });
        }
        const n: usize = if (self.dialog == .discard) 3 else 2;
        for (0..n) |i| {
            const b = self.dialogButton(i);
            const label = if (i == 0) tr("Cancel") else if (self.dialog == .save or i == 2) tr("Save as…") else if (self.dialog == .trash) tr("Move to Trash") else tr("Discard");
            const proximity = ui_button.sampleProximity(
                .{ .x = @floatCast(b.x), .y = @floatCast(b.y), .w = @floatCast(b.w), .h = @floatCast(b.h) },
                @floatCast(self.px), @floatCast(self.py),
                .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) },
            );
            ui_button.paint(lr, .{ .x = @floatCast(b.x - r.x), .y = @floatCast(b.y - r.y), .w = @floatCast(b.w), .h = @floatCast(b.h) }, .{
                .variant = if (i == 0) .secondary else .primary,
                .label = label,
            }, .{
                .pointer = if (b.contains(self.px, self.py)) .hover else .idle,
                .proximity_distance = proximity.distance,
                .proximity_x = proximity.x,
                .proximity_y = proximity.y,
            });
        }
        layer.finish();
    }
    if (self.dialog == .save) {
        const f = self.filenameRect();
        shell_ui.drawProximityGlow(
            cr,
            shellRect(f),
            7,
            .{ .x = self.px, .y = self.py },
            shellRect(r),
        );
    }
    setSource(cr, t.fg);
    const title = switch (self.dialog) {
        .save => tr("Save a PNG copy"),
        .trash => tr("Move this image to Trash?"),
        .discard => tr("Save your edits?"),
        .none => "",
    };
    drawText(cr, title, r.x + 20, r.y + 30, shell_ui.textSize(), true);
    setSource(cr, t.fg);
    const description = switch (self.dialog) {
        .save => tr("Same folder, or enter an absolute path."),
        .trash => if (self.modified or self.hasCropSelection()) tr("Unsaved edits will be discarded.") else tr("You can restore the file from Trash."),
        .discard => tr("This image has unsaved changes."),
        .none => "",
    };
    clippedText(cr, description, .{ .x = r.x + 20, .y = r.y + 42, .w = r.w - 40, .h = 25 }, shell_ui.textSize(), false);
    if (self.dialog == .save) {
        const area = self.filenameText();
        const field = self.filenameRect();
        c.cairo_save(cr);
        c.cairo_rectangle(cr, area.x, field.y, area.w, field.h);
        c.cairo_clip(cr);
        const bytes = self.filename.text.items;
        const caret = measureText(cr, bytes[0..self.filename.cursor], shell_ui.textSize(), false);
        self.filename.scroll = @max(0, @max(caret - area.w + 16, @min(self.filename.scroll, caret)));
        const x = area.x - self.filename.scroll;
        const m = shell_ui.fontMetrics(cr, shell_ui.textSize());
        const ink = m.ascent + m.descent;
        const top = field.y + (field.h - ink) / 2;
        const sel = self.filename.selection();
        if (sel[0] != sel[1]) {
            const start = measureText(cr, bytes[0..sel[0]], shell_ui.textSize(), false);
            const end = measureText(cr, bytes[0..sel[1]], shell_ui.textSize(), false);
            setSource(cr, t.selectionColor());
            c.cairo_rectangle(cr, x + start, top, end - start, ink);
            c.cairo_fill(cr);
        }
        setSource(cr, t.fg);
        drawText(cr, bytes, x, top + m.ascent, shell_ui.textSize(), false);
        setSource(cr, t.caretColor());
        c.cairo_rectangle(cr, x + caret, top, t.caret_width, ink);
        c.cairo_fill(cr);
        c.cairo_restore(cr);
    } else {
        setSource(cr, t.fg);
        clippedText(cr, std.fs.path.basename(self.paths[self.selected]), .{ .x = r.x + 20, .y = r.y + 76, .w = r.w - 40, .h = 30 }, shell_ui.textSize(), true);
    }
    const note = if (self.operation != null) tr("Working…") else self.notice[0..self.notice_len];
    setSource(cr, t.danger);
    clippedText(cr, note, .{ .x = r.x + 20, .y = r.y + 118, .w = r.w - 40, .h = 26 }, shell_ui.textSize(), false);
}
