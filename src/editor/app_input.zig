//! Pointer and keyboard input, pasting and find.

const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const c = @import("../files/c.zig").api;
const theme = @import("ui").theme;
const scrollbar = @import("ui").widgets.scrollbar;
const input = @import("ui").input;
const a = std.heap.c_allocator;
const app_mod = @import("app.zig");
const App = app_mod.App;
const top = app_mod.top;
const status_h = app_mod.status_h;
const labels = app_mod.labels;

/// The byte offset nearest a point given relative to the text origin.
pub fn indexAt(self: *App, x: f64, y: f64) usize {
    return self.port().indexAt(x, y);
}

pub fn handleMotion(self: *App, x: f64, y: f64) void {
    const previous_hover = self.hoverTarget();
    self.px = x;
    self.py = y;
    if (self.menu_open) {
        const hovered = self.menuHit(x, y);
        if (hovered != self.menu_selected) {
            self.menu_selected = hovered;
            self.dirty = true;
        }
        return;
    }
    if (self.dragging) {
        const t = self.current();
        if (y < self.viewTop()) self.port().scrollBy(-18) else if (y > self.viewTop() + self.viewHeight()) self.port().scrollBy(18);
        const pos = self.indexAt(x - 16 + t.scroll_x, y - self.viewTop());
        if (self.drag_word) |initial| {
            const range = t.doc.wordRange(self.port().characterAt(x - 16 + t.scroll_x, y - self.viewTop()));
            const backwards = pos < initial[0];
            t.doc.anchor = if (backwards) initial[1] else initial[0];
            t.doc.cursor = if (backwards) range[0] else @max(initial[1], range[1]);
        } else t.doc.move(pos, true);
        self.changed();
    }
    if (self.scroll_drag.active) {
        if (self.scrollbarGeometry()) |bar| self.seekScroll(self.scroll_drag.offsetAt(bar, @floatCast(x), @floatCast(y)));
        self.dirty = true;
    }
    if (!std.meta.eql(previous_hover, self.hoverTarget())) self.dirty = true;
}

pub fn handleButton(self: *App, code: u32, pressed: bool) void {
    if (code != 0x110) return;
    if (pressed) self.caret_activity +%= 1;
    if (!pressed) {
        self.cancelDrag();
        return;
    }
    const last_click = self.last_text_click;
    self.last_text_click = null;
    self.caret_snap = true;
    if (self.close_tab != null) {
        const x = (@as(f64, @floatFromInt(self.w)) - 420) / 2;
        const y = (@as(f64, @floatFromInt(self.h)) - 170) / 2;
        if (self.py >= y + 112 and self.py <= y + 150 and self.operation == null) {
            if (self.px >= x + 20 and self.px < x + 135) {
                self.close_tab = null;
                self.close_all = false;
            } else if (self.px >= x + 145 and self.px < x + 270) self.finishClose() else if (self.px >= x + 280 and self.px < x + 400) self.save(false);
            self.dirty = true;
        }
        return;
    }
    if (self.menu_open) {
        const row = self.menuHit(self.px, self.py);
        self.dismissMenu();
        if (row) |i| self.act(@enumFromInt(i));
        return;
    }
    if (self.py < 0) return;
    if (self.py < top) {
        if (!self.has_titlebar and self.menuButtonBox().contains(self.px, self.py)) {
            self.toggleMenu(@as(f64, @floatFromInt(self.w)) - 8);
            return;
        }
        if (self.newButtonBox().contains(self.px, self.py)) {
            self.act(.new);
            return;
        }
        if (self.tabAt(self.px)) |i| {
            self.selected = i;
            self.changed();
            if (self.tabCloseBox(i).contains(self.px, self.py)) self.closeSelected();
        }
    } else if (self.find_open and self.py < self.viewTop()) {
        if (self.searchHit(self.px, self.py)) |control| self.searchActivate(control);
    } else if (self.py < @as(f64, @floatFromInt(self.h)) - status_h) {
        if (self.px > @as(f64, @floatFromInt(self.w)) - scrollbar.gutter(theme.global.scrollbar_width)) {
            if (self.scrollbarGeometry()) |bar| {
                const scroll = self.scrollOffset();
                if (scrollbar.press(bar, @floatCast(self.px), @floatCast(self.py), scroll)) |action| {
                    switch (action) {
                        .grab => self.scroll_drag.begin(bar, @floatCast(self.px), @floatCast(self.py), scroll),
                        .page => |offset| self.seekScroll(offset),
                    }
                    self.dirty = true;
                }
            }
            return;
        }
        const text_y = self.py - self.viewTop();
        self.find_open = false;
        const t = self.current();
        const pos = self.indexAt(self.px - 16 + t.scroll_x, text_y);
        const now = @import("ui").key_repeat.nowMs();
        const double = if (last_click) |last| last.tab == t.id and now - last.time <= input.multi_click_ms and
            @abs(self.px - last.x) <= input.multi_click_slop and @abs(self.py - last.y) <= input.multi_click_slop else false;
        if (double and !self.shift) {
            const range = t.doc.wordRange(self.port().characterAt(self.px - 16 + t.scroll_x, text_y));
            t.doc.anchor = range[0];
            t.doc.cursor = range[1];
            self.drag_word = range;
        } else {
            t.doc.move(pos, self.shift);
            self.last_text_click = .{ .time = now, .x = self.px, .y = self.py, .tab = t.id };
        }
        self.dragging = true;
        self.changed();
    }
}

pub fn pasteText(self: *App, bytes: []const u8) void {
    self.caret_activity +%= 1;
    if (self.close_tab != null or self.menu_open) return;
    if (self.find_open) {
        if (self.searchEditor()) |editor| editor.insert(a, bytes) catch |err| self.failure(err);
        self.dirty = true;
        return;
    }
    self.document().insert(bytes) catch |err| {
        self.failure(err);
        return;
    };
    self.notice_len = 0;
    self.reveal();
}

pub fn keyRepeats(self: *App, sym: u32, utf8: []const u8) bool {
    if (self.close_tab != null or self.menu_open or self.alt) return false;
    if (self.ctrl) return switch (sym) {
        c.XKB_KEY_Left, c.XKB_KEY_Right, c.XKB_KEY_BackSpace, c.XKB_KEY_Delete => !self.find_open,
        else => false,
    };
    if (!self.find_open) switch (sym) {
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter, c.XKB_KEY_Tab, c.XKB_KEY_Home, c.XKB_KEY_End, c.XKB_KEY_Page_Up, c.XKB_KEY_Page_Down => return true,
        else => {},
    };
    return @import("ui").key_repeat.editingKey(switch (sym) {
        c.XKB_KEY_Left, c.XKB_KEY_Right, c.XKB_KEY_Up, c.XKB_KEY_Down, c.XKB_KEY_BackSpace, c.XKB_KEY_Delete => true,
        else => false,
    }, utf8);
}

pub fn handleKey(self: *App, sym: u32, utf8: []const u8) void {
    self.caret_activity +%= 1;
    self.last_text_click = null;
    if (self.close_tab != null) {
        if (sym == c.XKB_KEY_Escape and self.operation == null) {
            self.close_tab = null;
            self.close_all = false;
            self.dirty = true;
        }
        if (self.operation == null) {
            if (sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab or sym == c.XKB_KEY_Left or sym == c.XKB_KEY_Right) {
                self.close_choice = (self.close_choice + @as(usize, if (self.shift or sym == c.XKB_KEY_Left) 2 else 1)) % 3;
                self.dirty = true;
            }
            if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_space) switch (self.close_choice) {
                0 => {
                    self.close_tab = null;
                    self.close_all = false;
                    self.dirty = true;
                },
                1 => self.finishClose(),
                else => self.save(false),
            };
        }
        return;
    }
    if (sym == c.XKB_KEY_F10 and !self.ctrl and !self.alt) {
        self.toggleMenu(self.menu_anchor);
        return;
    }
    if (self.menu_open) {
        switch (sym) {
            c.XKB_KEY_Escape => self.dismissMenu(),
            c.XKB_KEY_Down => self.menu_selected = if (self.menu_selected) |i| (i + 1) % labels.len else 0,
            c.XKB_KEY_Up => self.menu_selected = if (self.menu_selected) |i| (i + labels.len - 1) % labels.len else labels.len - 1,
            c.XKB_KEY_Home => self.menu_selected = 0,
            c.XKB_KEY_End => self.menu_selected = labels.len - 1,
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter, c.XKB_KEY_space => if (self.menu_selected) |i| {
                self.dismissMenu();
                self.act(@enumFromInt(i));
            },
            else => {},
        }
        self.dirty = true;
        if (!self.ctrl) return;
        self.dismissMenu();
    }
    if (self.ctrl) switch (sym) {
        c.XKB_KEY_n, c.XKB_KEY_N, c.XKB_KEY_t, c.XKB_KEY_T => {
            self.act(.new);
            return;
        },
        c.XKB_KEY_o, c.XKB_KEY_O => {
            self.act(.open);
            return;
        },
        c.XKB_KEY_s, c.XKB_KEY_S => {
            self.save(self.shift);
            return;
        },
        c.XKB_KEY_w, c.XKB_KEY_W => {
            self.closeSelected();
            return;
        },
        c.XKB_KEY_q, c.XKB_KEY_Q => {
            self.requestClose();
            return;
        },
        c.XKB_KEY_f, c.XKB_KEY_F => {
            self.openSearch(false);
            return;
        },
        c.XKB_KEY_h, c.XKB_KEY_H => {
            self.openSearch(true);
            return;
        },
        c.XKB_KEY_Tab, c.XKB_KEY_ISO_Left_Tab, c.XKB_KEY_Page_Up, c.XKB_KEY_Page_Down => {
            self.selected = if (self.shift or sym == c.XKB_KEY_Page_Up) (self.selected + self.tabs.items.len - 1) % self.tabs.items.len else (self.selected + 1) % self.tabs.items.len;
            self.changed();
            return;
        },
        else => {},
    };
    if (sym == c.XKB_KEY_Escape) {
        self.find_open = false;
        self.notice_len = 0;
        self.dirty = true;
        return;
    }
    if (self.find_open) {
        self.searchKey(sym, utf8);
        return;
    }
    self.editKey(sym, utf8);
}
