//! RediTerm's titlebar-tab protocol, in-content fallback, and New tab menu.
const std = @import("std");
const c = @import("c_gfx");
const ui = @import("ui");
const App = @import("app.zig").App;
const sessions = @import("sessions.zig");
const drawEllipsis = @import("../files/app_draw.zig").drawEllipsis;
const tr = @import("i18n").tr;
const shell = ui.cairo;
const menu = ui.context_menu;
const Rect = menu.Rect;
const button = ui.widgets.button;

const strip_height = 38;
const button_width = 36;

fn app(ctx: *anyopaque) *App {
    return @ptrCast(@alignCast(ctx));
}

pub fn titlebarTabHandler(self: *App) ui.client_tabs.Handler {
    return .{
        .ctx = self,
        .select = select,
        .close = close,
        .new_tab = new,
        .move = move,
        .leading = leading,
    };
}

fn select(ctx: *anyopaque, id: u32) void {
    const self = app(ctx);
    dismissMenu(self);
    self.selectTab(id);
}

fn close(ctx: *anyopaque, id: u32) void {
    const self = app(ctx);
    dismissMenu(self);
    self.closeTab(id);
}

fn new(ctx: *anyopaque) void {
    app(ctx).newTab();
}

fn move(ctx: *anyopaque, id: u32, index: u32) void {
    sessions.moveTab(app(ctx), id, index);
}

fn leading(ctx: *anyopaque, x: i32, _: i32, _: i32, _: i32) void {
    toggleMenu(app(ctx), @floatFromInt(x));
}

pub fn publishTitlebarTabs(self: *App, tabs: *ui.client_tabs) void {
    if (!self.strip_in_titlebar) return tabs.publish(&.{}, 0, false);
    const active = self.current() orelse return;
    var list: [sessions.max_tabs]ui.client_tabs.Tab = undefined;
    for (self.tabs.items, 0..) |*tab, i| list[i] = .{ .id = tab.id, .title = tab.name() };
    tabs.publish(list[0..self.tabs.items.len], active.id, true);
}

pub fn inset(self: *const App) f64 {
    return if (self.strip_in_titlebar) 0 else strip_height;
}

const Strip = struct {
    left: f64,
    width: f64,
    first: usize,
    count: usize,
    previous: ?Rect,
    next: ?Rect,
    new_tab: Rect,

    fn tabBox(s: Strip, i: usize) Rect {
        return .{ .x = s.left + @as(f64, @floatFromInt(i)) * s.width, .y = 0, .w = s.width, .h = strip_height };
    }

    fn closeBox(s: Strip, i: usize) Rect {
        const box = s.tabBox(i);
        return control(box.x + box.w - 32, 30);
    }
};

fn control(x: f64, width: f64) Rect {
    return .{ .x = x, .y = 2, .w = width, .h = strip_height - 4 };
}

fn menuButton() Rect {
    return control(2, button_width);
}

fn strip(self: *const App) Strip {
    const right: f64 = @floatFromInt(@max(0, self.w - button_width - 2));
    var left = menuButton().x + button_width + 2;
    var room = @max(1, right - left);
    const total = self.tabs.items.len;
    const overflow = @as(f64, @floatFromInt(total)) * 100 > room;
    const arrow = 26;
    if (overflow) {
        left += arrow;
        room = @max(1, room - 2 * arrow);
    }
    const count = @min(total, @max(1, @as(usize, @intFromFloat(@floor(room / 100)))));
    const first = @min(self.first_visible, total - count);
    const width = @min(176, room / @as(f64, @floatFromInt(@max(1, count))));
    return .{
        .left = left,
        .width = width,
        .first = first,
        .count = count,
        .previous = if (overflow) control(left - arrow, arrow) else null,
        .next = if (overflow) control(left + @as(f64, @floatFromInt(count)) * width, arrow) else null,
        .new_tab = control(right, button_width),
    };
}

pub fn revealTab(self: *App) void {
    if (self.strip_in_titlebar) return;
    const s = strip(self);
    if (s.count == 0) return;
    self.first_visible = std.math.clamp(s.first, self.selected + 1 -| s.count, self.selected);
}

fn browse(self: *App, next: bool) void {
    const s = strip(self);
    self.first_visible = if (next) @min(s.first + 1, self.tabs.items.len - s.count) else s.first -| 1;
    if (self.first_visible != s.first) self.damageStrip();
}

pub fn damageStrip(self: *App) void {
    if (self.strip_in_titlebar) return;
    self.damage.add(.{ .x = 0, .y = 0, .w = self.w, .h = strip_height });
    self.dirty = true;
}

fn menuBox(self: *const App) Rect {
    const width = @min(menu.width, @max(1, self.w - 12));
    return .{
        .x = std.math.clamp(self.menu_x, 6, @max(6, @as(f64, @floatFromInt(self.w - width - 6)))),
        .y = inset(self) + 6,
        .w = @floatFromInt(width),
        .h = menu.row_height + 2 * menu.padding,
    };
}

fn menuRow(self: *const App) Rect {
    const box = menuBox(self);
    return .{ .x = box.x + menu.padding, .y = box.y + menu.padding, .w = box.w - 2 * menu.padding, .h = menu.row_height };
}

fn damageMenu(self: *App) void {
    const box = menuBox(self);
    // Include the shared menu frame's shadow.
    self.damage.add(.around(box.x - 6, box.y - 6, box.w + 12, box.h + 15));
    self.dirty = true;
}

fn toggleMenu(self: *App, x: f64) void {
    if (self.closing) return;
    if (self.menu_open) return dismissMenu(self);
    self.cancelDrag();
    self.repeat_tab = null;
    self.menu_x = x;
    self.menu_open = true;
    self.menu_selected = false;
    damageMenu(self);
    self.damageStrip();
}

pub fn dismissMenu(self: *App) void {
    if (!self.menu_open) return;
    self.menu_open = false;
    damageMenu(self);
    self.damageStrip();
}

pub fn activateMenu(self: *App) void {
    dismissMenu(self);
    self.newTab();
}

pub fn selectMenuRow(self: *App, selected: bool) void {
    if (self.menu_selected == selected) return;
    self.menu_selected = selected;
    damageMenu(self);
}

fn overStrip(self: *const App, y: f64) bool {
    return y >= 0 and y < inset(self);
}

pub fn motion(self: *App, old_y: f64) void {
    if (overStrip(self, old_y) or overStrip(self, self.mouse_y)) self.damageStrip();
    if (self.menu_open) selectMenuRow(self, self.pointer_hover and menuRow(self).contains(self.mouse_x, self.mouse_y));
}

pub fn press(self: *App, primary: bool) bool {
    const x = self.mouse_x;
    const y = self.mouse_y;
    if (self.menu_open) {
        if (primary and menuRow(self).contains(x, y)) activateMenu(self) else dismissMenu(self);
        return true;
    }
    if (!overStrip(self, y)) return y < 0;
    if (!primary) return true;
    const s = strip(self);
    if (menuButton().contains(x, y)) {
        toggleMenu(self, menuButton().x);
    } else if (s.new_tab.contains(x, y)) {
        self.newTab();
    } else if (s.previous != null and s.previous.?.contains(x, y)) {
        browse(self, false);
    } else if (s.next != null and s.next.?.contains(x, y)) {
        browse(self, true);
    } else {
        for (self.tabs.items[s.first..][0..s.count], 0..) |*tab, i| {
            if (s.closeBox(i).contains(x, y)) {
                self.closeTab(tab.id);
                break;
            }
            if (s.tabBox(i).contains(x, y)) {
                self.selectTab(tab.id);
                break;
            }
        }
    }
    return true;
}

pub fn axis(self: *App, dy: f64) bool {
    if (self.menu_open) return true;
    if (!overStrip(self, self.mouse_y)) return self.mouse_y < 0;
    if (dy != 0) browse(self, dy > 0);
    return true;
}

fn fill(cr: *c.cairo_t, r: Rect, color: [4]f32) void {
    shell.setSource(cr, color);
    c.cairo_rectangle(cr, r.x, r.y, r.w, r.h);
    c.cairo_fill(cr);
}

fn icon(self: *const App, cr: *c.cairo_t, r: Rect, id: ui.layout.IconId, label: []const u8, selected: bool, disabled: bool) void {
    var layer = shell.Layer.beginVisible(cr, .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) }) orelse return;
    defer layer.finish();
    layer.renderer.palette = ui.theme.shellPalette();
    button.paint(&layer.renderer, layer.local(), .{ .label = label, .icon = id, .variant = .ghost, .size = .sm }, .{
        .selected = selected,
        .pointer = if (disabled) .disabled else if (self.pointer_hover and !self.menu_open and r.contains(self.mouse_x, self.mouse_y)) .hover else .idle,
    });
}

fn paintStrip(self: *const App, cr: *c.cairo_t) void {
    const theme = ui.theme.global;
    const s = strip(self);
    fill(cr, .{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = strip_height }, theme.app_bar);
    icon(self, cr, menuButton(), .more, tr("Menu"), self.menu_open, false);
    if (s.previous) |r| icon(self, cr, r, .chevron_left, "", false, s.first == 0);
    if (s.next) |r| icon(self, cr, r, .chevron_right, "", false, s.first + s.count == self.tabs.items.len);
    for (self.tabs.items[s.first..][0..s.count], 0..) |*tab, i| {
        const r = s.tabBox(i);
        if (self.selected == s.first + i) {
            fill(cr, r, theme.app_bg);
            fill(cr, .{ .x = r.x + 8, .y = strip_height - 3, .w = r.w - 16, .h = 2 }, ui.theme.shellPalette().accent);
        }
        shell.setSource(cr, theme.window_fg);
        const size = shell.textSize();
        const fm = shell.fontMetrics(cr, size);
        drawEllipsis(cr, tab.name(), r.x + 10, (r.h + fm.ascent - fm.descent) / 2, r.w - 44, size, false);
        icon(self, cr, s.closeBox(i), .close, tr("Close tab"), false, tab.hangup_at != null);
    }
    icon(self, cr, s.new_tab, .plus, tr("New tab"), false, self.tabs.items.len == sessions.max_tabs);
}

pub fn render(self: *const App, cr: *c.cairo_t) void {
    if (!self.strip_in_titlebar and shell.clipTouches(cr, .{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = strip_height })) paintStrip(self, cr);
    if (self.menu_open) {
        const box = menuBox(self);
        if (!shell.clipTouches(cr, .{ .x = @floatCast(box.x - 6), .y = @floatCast(box.y - 6), .w = @floatCast(box.w + 12), .h = @floatCast(box.h + 15) })) return;
        menu.frame(cr, box, true);
        menu.row(cr, menuRow(self), .{
            .label = tr("New tab"),
            .hint = "CTRL+SHIFT+T",
            .icon = .plus,
            .selected = self.menu_selected,
            .disabled = self.tabs.items.len == sessions.max_tabs,
        }, true);
    }
}
