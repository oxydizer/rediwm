//! Properties window of the Trash itself, shown by Files (sidebar Trash) and
//! by the desktop's Trash icon. It is the file Properties window
//! (`properties.zig`) with the Trash's own facts in place of an inode's: its
//! icon, how many items it holds and how much they weigh, and no permissions.
//! The items and size come from `trash_totals.zig` on a thread that lives as
//! long as the window; until it answers the rows read "Calculating…".
const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const c = @import("c.zig").api;
const icons = @import("../icon_cache.zig");
const icon_theme = @import("../icon_theme.zig");
const ui = @import("ui");
const shell_ui = ui.cairo;
const theme = ui.theme;
const chrome = ui.window_chrome;
const dialog = ui.widgets.dialog;
const button = ui.widgets.button;
const card = @import("properties_card.zig");
const totals = @import("trash_totals.zig");
const formatSize = @import("app_draw.zig").formatSize;
const Rect = shell_ui.Rect;
const a = std.heap.c_allocator;

pub const Action = enum { none, close, open };
pub const Target = enum { none, close, open };

const field_count = 3;

fn contentShift() f32 {
    return @max(0, @as(f32, @floatFromInt((chrome.Metrics{}).titlebarHeight())) - 49);
}

fn cardHeight() f32 {
    return card.fieldsBottom(field_count) + 22 + contentShift();
}

pub const Geometry = struct {
    box: Rect,
    close: Rect,
    open: Rect,

    pub fn init(w: i32, h: i32) Geometry {
        const width: f32 = @min(440, @as(f32, @floatFromInt(w)) - 24);
        const height: f32 = @min(cardHeight(), @as(f32, @floatFromInt(h)) - 16);
        return .{
            .box = .{ .x = (@as(f32, @floatFromInt(w)) - width) / 2, .y = (@as(f32, @floatFromInt(h)) - height) / 2, .w = width, .h = height },
            .close = dialog.closeBox(width),
            .open = card.openBox(width, -contentShift()),
        };
    }
};

fn contains(rect: Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h;
}

pub const State = struct {
    placement: dialog.Placement = .{},
    /// The Trash's `files` directory, shown as its location.
    path: []const u8 = "",
    task: ?*totals.Task = null,
    totals: ?totals.Summary = null,
    focus: Target = .close,
    keyboard_focus: bool = false,

    /// Starts counting at once. `wake_fd` is the host's event fd: it is
    /// written when the totals arrive, after which the host calls `poll`.
    pub fn init(path: []const u8, wake_fd: c_int) !State {
        const owned = try a.dupe(u8, path);
        errdefer a.free(owned);
        return .{ .path = owned, .task = try totals.Task.start(path, wake_fd) };
    }

    pub fn deinit(self: *State) void {
        if (self.task) |task| task.destroy();
        a.free(self.path);
        self.* = .{};
    }

    /// Takes the totals if they have arrived; true means repaint.
    pub fn poll(self: *State) bool {
        const task = self.task orelse return false;
        const done = task.poll() orelse return false;
        self.totals = done;
        task.destroy();
        self.task = null;
        return true;
    }

    pub fn geometry(self: *const State, w: i32, h: i32) Geometry {
        var g = Geometry.init(w, h);
        g.box = self.placement.box(g.box, w, h);
        return g;
    }

    pub fn pointerButton(self: *State, w: i32, h: i32, x: f64, y: f64, pressed: bool) bool {
        return self.placement.button(Geometry.init(w, h).box, w, h, x, y, pressed);
    }

    pub fn motion(self: *State, w: i32, h: i32, x: f64, y: f64) bool {
        return self.placement.motion(Geometry.init(w, h).box, w, h, x, y);
    }

    pub fn hit(self: *const State, w: i32, h: i32, x: f64, y: f64) Target {
        const g = self.geometry(w, h);
        const px: f32 = @floatCast(x - g.box.x);
        const py: f32 = @floatCast(y - g.box.y);
        if (contains(g.close, px, py)) return .close;
        if (py < 49 + contentShift() or py >= g.box.h - 8) return .none;
        if (contains(g.open, px, py)) return .open;
        return .none;
    }

    pub fn click(self: *State, w: i32, h: i32, x: f64, y: f64) Action {
        const target = self.hit(w, h, x, y);
        if (target == .none) return .none;
        self.keyboard_focus = false;
        self.focus = target;
        return self.activate();
    }

    fn activate(self: *const State) Action {
        return if (self.focus == .open) .open else .close;
    }

    pub fn key(self: *State, sym: u32) Action {
        if (sym == c.XKB_KEY_Escape) return .close;
        if (sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab) {
            self.keyboard_focus = true;
            self.focus = if (self.focus == .close) .open else .close;
        } else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_KP_Enter or sym == c.XKB_KEY_space) return self.activate();
        return .none;
    }

    /// Dims the host window behind the card, then draws it.
    pub fn draw(self: *const State, ctx: anytype, w: i32, h: i32, mx: f64, my: f64, background: ?[4]f32, cfg: icon_theme.Config, io: std.Io) void {
        const cr: *c.cairo_t = @ptrCast(ctx);
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        shell_ui.setSource(cr, dialog.backdropColor());
        c.cairo_paint(cr);
        self.drawWindow(ctx, w, h, mx, my, background, cfg, io);
    }

    /// Floating compositor prompts have no app-sized backdrop to dim.
    pub fn drawWindow(self: *const State, ctx: anytype, w: i32, h: i32, mx: f64, my: f64, background: ?[4]f32, cfg: icon_theme.Config, io: std.Io) void {
        const cr: *c.cairo_t = @ptrCast(ctx);
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        const g = self.geometry(w, h);
        var layer = shell_ui.Layer.begin(cr, g.box) orelse return;
        defer layer.finish();
        const r = &layer.renderer;
        var palette = theme.shellPalette();
        palette.font_size = shell_ui.textSize();
        palette.button_font_size = shell_ui.textSize();
        r.palette = palette;
        dialog.paintWindowFrame(r, layer.local(), background);
        dialog.paintWindowTitle(r, layer.local(), tr("Properties"), .trash_can, null);
        const hover = self.hit(w, h, mx, my);
        button.paint(r, g.close, .{ .icon = .close, .variant = .chrome, .label = tr("Close") }, .{ .focused = self.keyboard_focus and self.focus == .close, .pointer = if (hover == .close) .hover else .idle });
        // The body is the app surface: it takes the app's foreground, not the dark chrome's.
        palette.fg = theme.global.forApp().window_fg;
        r.palette = palette;
        r.clip = .{ .x = 12, .y = 49 + contentShift(), .w = g.box.w - 24, .h = g.box.h - 59 - contentShift() };
        const s = -contentShift();
        // The same artwork the desktop and sidebar show: a pack's, else the glyph.
        const art = icons.getPack(cfg, io, "user-trash", @intFromFloat(44 * shell_ui.scaleOf(cr)));
        card.paintIdentity(r, g.box.w, s, .{
            .image = if (art) |im| .{ .pixels = im.pixels, .width = @intCast(im.size), .height = @intCast(im.size) } else null,
            .glyph = .trash_can,
            .name = tr("Trash"),
            .kind = tr("Deleted files and folders"),
        });
        card.paintOpen(r, g.box.w, s, tr("Open"), self.keyboard_focus and self.focus == .open, hover == .open);
        var items_buf: [64]u8 = undefined;
        var size_buf: [128]u8 = undefined;
        var short_buf: [32]u8 = undefined;
        var items: []const u8 = tr("Calculating…");
        var size: []const u8 = items;
        if (self.totals) |t| {
            items = i18n.fmt(&items_buf, i18n.trn("{count} item", "{count} items", t.items), .{ .count = t.items }) catch "—";
            const short = formatSize(t.bytes, &short_buf);
            const bytes: u64 = @intCast(@max(0, t.bytes));
            size = (if (t.partial)
                i18n.fmt(&size_buf, tr("At least {size}"), .{ .size = short })
            else
                i18n.fmt(&size_buf, i18n.trn("{size} ({bytes} byte)", "{size} ({bytes} bytes)", bytes), .{ .size = short, .bytes = bytes })) catch "—";
        }
        const labels = [field_count][]const u8{ tr("Items"), tr("Size"), tr("Location") };
        const values = [field_count][]const u8{ items, size, self.path };
        card.paintFields(r, g.box.w, s, &labels, &values);
    }
};

test {
    _ = @import("trash_properties_tests.zig");
}
