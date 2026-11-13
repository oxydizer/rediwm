const std = @import("std");
const i18n = @import("i18n");
const tr = i18n.tr;
const ui = @import("ui");
const cairo = ui.cairo;
const theme = ui.theme;
const W = ui.layout.Widget;
const Rect = cairo.Rect;
const c = @import("../files/c.zig").api;
const collector = @import("collector.zig");
const model = @import("model.zig");
const proc = @import("proc.zig");
const actions = @import("actions.zig");
const scrollbar = ui.widgets.scrollbar;
const a = std.heap.c_allocator;
pub const row_h: f64 = 32;
const table = @import("app_table.zig");
const footer_view = @import("app_footer.zig");
const summary = @import("app_summary.zig");
const titles = [_]i18n.Message{ i18n.msg("Name"), i18n.msg("PID"), i18n.msg("User"), i18n.msg("CPU %"), i18n.msg("Memory (resident)"), i18n.msg("State") };
const proportions = [_]f32{ 0.25, 0.10, 0.11, 0.18, 0.20, 0.16 };
const Pending = enum { none, end, confirm, cancel, force };
const Confirmation = struct { identity: proc.Identity, name: [256]u8 = undefined, len: usize };
const Selection = struct { identity: proc.Identity, fade: ui.hover_glide.Fade = .{} };

pub const App = struct {
    worker: *collector.Worker,
    model: model.Model,
    history: model.History = .{},
    w: i32 = 960,
    h: i32 = 640,
    scale: i32 = 1,
    density: f64 = 1,
    dirty: bool = true,
    closed: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    focused: bool = false,
    caret_visible: bool = true,
    caret_moving: bool = false,
    paused: bool = false,
    suspended: bool = false,
    px: f32 = -1,
    py: f32 = -1,
    root: W = .{ .kind = .container },
    sections: [6]W = undefined,
    /// CPU card, RAM card, collapse button (`app_summary.zig` places them).
    cards: [3]W = undefined,
    /// The card that is expanded, or was last; `card_t` eases 0 → 1 open.
    card: usize = 0,
    card_open: bool = false,
    card_anim: ui.anim.Anim = .{},
    card_t: f32 = 0,
    card_request: ?usize = null,
    toolbar: [3]W = undefined,
    headers: [6]W = undefined,
    header_labels: [6][64]u8 = undefined,
    footer: [3]W = undefined,
    modal: W = .{ .kind = .container },
    modal_buttons: [2]W = undefined,
    initialized: bool = false,
    dispatcher: ui.input.Dispatcher = .{},
    pending: Pending = .none,
    confirmation: ?Confirmation = null,
    notice: []const u8 = "",
    bar: scrollbar.Appearance = .{},
    bar_drag: scrollbar.Drag = .{},
    last_scroll: f64 = 0,
    row_hover: ui.hover_glide.Glide = .{},
    selections: std.ArrayList(Selection) = .empty,

    pub fn init(io: std.Io) !App {
        return .{ .worker = try collector.Worker.init(io), .model = .{ .allocator = a, .uid = c.getuid() } };
    }
    pub fn deinit(self: *App) void {
        self.worker.deinit();
        self.dispatcher.reset();
        if (self.initialized) a.free(self.toolbar[0].kind.text_input.value);
        self.model.deinit();
        self.selections.deinit(a);
    }
    pub fn getTitle(_: *App) [*:0]const u8 {
        return i18n.trZ("System Monitor");
    }
    pub fn requestClose(self: *App) void {
        self.closed = true;
        self.worker.setActive(false);
    }
    pub fn setSuspended(self: *App, suspended: bool) void {
        if (self.suspended == suspended) return;
        self.suspended = suspended;
        self.worker.setActive(!self.paused and !suspended and !self.closed);
        if (suspended) self.cancelDrag();
        self.dirty = true;
    }
    pub fn start(self: *App) void {
        self.worker.setActive(!self.paused and !self.suspended and !self.closed);
    }
    pub fn sync(self: *App) void {
        self.applyPending();
        if (self.worker.take()) |snap| {
            if (self.paused or self.suspended or self.closed) {
                snap.deinit();
                return;
            }
            self.history.append(snap);
            self.model.update(snap) catch {
                self.notice = tr("Not enough memory to display every process");
            };
            self.clampScroll();
            self.dirty = true;
        }
    }
    fn button(self: *App, label: []const u8, id: usize, width: f32) W {
        return .{ .kind = .{ .button = .{ .label = label, .owner = self, .id = id, .on_click = clicked } }, .width = .{ .fixed = width }, .height = .{ .fixed = 34 } };
    }
    fn ensureWidgets(self: *App) void {
        if (self.initialized) return;
        self.initialized = true;
        self.toolbar = .{
            .{ .kind = .{ .text_input = .{ .owner = self, .placeholder = tr("Search name, PID or user"), .value = a.dupe(u8, "") catch unreachable, .on_change = searchChanged, .field = .{ .leading_icon = .search } } }, .width = .{ .flex = 1 }, .height = .{ .fixed = 34 } },
            self.button(tr("My processes"), 0, 148),
            self.button(tr("Pause updates"), 1, 130),
        };
        for (&self.headers, titles, proportions, 0..) |*header, title, width, i| {
            header.* = self.button(title.get(), 10 + i, 0);
            header.width = .{ .percent = width };
            header.kind.button.variant = .ghost;
            header.kind.button.alignment = .left;
        }
        self.footer = .{
            .{ .kind = .container, .width = .{ .flex = 1 } },
            self.button(tr("End process"), 2, 124),
            self.button(tr("Force quit…"), 3, 124),
        };
        self.footer[1].kind.button.destructive = true;
        for (self.cards[0..2], 0..) |*card, i| card.* = .{
            .name = if (i == 0) "monitor_cpu_card" else "monitor_ram_card",
            .kind = .{ .row = .{ .owner = self, .id = 30 + i, .on_click = clicked, .underlay = true } },
        };
        self.cards[2] = self.button(tr("Collapse"), 32, 28);
        self.cards[2].height = .{ .fixed = 28 };
        self.cards[2].kind.button.icon = .minimize;
        self.cards[2].kind.button.variant = .ghost;
        for (self.footer[1..]) |*control| control.height = .{ .fixed = 38 };
        self.sections = .{
            .{ .kind = .container, .height = .{ .fixed = 150 }, .children = &self.cards },
            .{ .kind = .container, .height = .{ .fixed = 50 }, .padding = .{ .left = 16, .right = 16, .top = 4 }, .gap = 8, .children = &self.toolbar },
            .{ .kind = .container, .height = .{ .fixed = 36 }, .padding = .{ .left = 16, .right = scrollbar.gutter(theme.global.scrollbar_width) + 16 }, .children = &self.headers },
            .{ .kind = .container, .height = .{ .flex = 1 } },
            .{ .kind = .container, .height = .{ .fixed = 46 }, .padding = .{ .left = 16, .right = 16, .top = 6 }, .gap = 8, .children = &self.footer },
            .{ .kind = .container, .height = .{ .fixed = 28 } },
        };
        self.root = .{ .kind = .container, .direction = .column, .children = &self.sections, .@"align" = .stretch };
        self.modal_buttons = .{ self.button(tr("Cancel"), 20, 120), self.button(tr("Force quit"), 21, 120) };
        self.modal_buttons[1].kind.button.variant = .primary;
        self.modal = .{ .kind = .container, .gap = 12, .children = &self.modal_buttons };
        self.root.linkParents();
        self.modal.linkParents();
        self.layout();
    }
    fn layout(self: *App) void {
        if (!self.initialized) return;
        self.sections[2].padding.right = scrollbar.gutter(theme.global.scrollbar_width) + 16;
        self.sections[4].height = .{ .fixed = footer_view.height(self) };
        ui.measure.measure(&self.root, @floatFromInt(self.w), @floatFromInt(self.h));
        ui.arrange.arrange(&self.root, 0, 0, @floatFromInt(self.w), @floatFromInt(self.h));
        self.layoutFooter();
        summary.layout(self);
        const box = self.dialogBox();
        ui.measure.measure(&self.modal, 252, 34);
        ui.arrange.arrange(&self.modal, box.x + box.w - 276, box.y + box.h - 50, 252, 34);
        self.clampScroll();
    }
    pub fn resize(self: *App, width: i32, height: i32) void {
        self.w = @max(640, width);
        self.h = @max(480, height);
        self.layout();
        self.dirty = true;
    }
    fn tree(self: *App) *W {
        return if (self.confirmation != null) &self.modal else &self.root;
    }
    fn clicked(owner: ?*anyopaque, id: usize) void {
        const self: *App = @ptrCast(@alignCast(owner.?));
        switch (id) {
            0 => {
                self.model.mine = !self.model.mine;
                self.model.filter() catch {};
                self.clampScroll();
            },
            1 => {
                self.paused = !self.paused;
                self.worker.setActive(!self.paused and !self.suspended and !self.closed);
            },
            2 => self.pending = .end,
            3 => self.pending = .confirm,
            10...15 => self.model.setSort(@fromBackingInt(@intCast(id - 10))),
            20 => self.pending = .cancel,
            21 => self.pending = .force,
            30...32 => self.card_request = id - 30,
            else => {},
        }
        self.dirty = true;
    }
    fn searchChanged(owner: ?*anyopaque, _: usize, value: []const u8) void {
        const self: *App = @ptrCast(@alignCast(owner.?));
        self.model.query = value;
        self.model.filter() catch {};
        self.clampScroll();
        self.dirty = true;
    }
    fn manageable(self: *const App) bool {
        const row = self.model.selectedProcess() orelse return false;
        return row.uids != null and proc.owned(row.uids.?, self.model.uid) and !row.protected and row.state != 'Z' and row.state != 'X';
    }
    /// Toggles card 0/1 or collapses (2) once dispatch has returned, then
    /// re-targets the pointer: the widget under it just moved or vanished.
    fn applyCardRequest(self: *App) void {
        const request = self.card_request orelse return;
        self.card_request = null;
        if (request < 2) {
            // A card still sliding back can't take over mid-way.
            if ((self.card_open or self.card_t > 0) and request != self.card) return;
            self.card = request;
            self.card_open = !self.card_open;
        } else self.card_open = false;
        const now = ui.key_repeat.nowMs();
        self.card_anim.retargetTo(now, if (self.card_open) 1 else 0, ui.anim.curveFor(.panel_slide));
        self.layout();
        // The card stays focusable while open; only the collapse button vanishes.
        if (!self.card_open and self.dispatcher.focused == &self.cards[2]) self.dispatcher.focus(&self.root, &self.cards[self.card]);
        self.dispatcher.pointerMotion(self.tree(), self.px, self.py);
        self.dirty = true;
    }
    fn applyPending(self: *App) void {
        self.applyCardRequest();
        const pending = self.pending;
        self.pending = .none;
        if (pending == .none) return;
        if (pending == .cancel) {
            self.dismiss();
            return;
        }
        if (pending == .force) {
            const confirmation = self.confirmation orelse return;
            self.dismiss();
            self.send(confirmation.identity, .force);
        } else {
            const row = self.model.selectedProcess() orelse {
                self.notice = tr("Select a process first");
                return;
            };
            if (!self.manageable()) {
                self.notice = if (row.protected) actions.message(error.ProtectedProcess) else actions.message(error.PermissionDenied);
                return;
            }
            if (pending == .end) self.send(row.identity, .end) else {
                var confirmation: Confirmation = .{ .identity = row.identity, .len = @min(row.name.len, 255) };
                while (confirmation.len > 0 and !std.unicode.utf8ValidateSlice(row.name[0..confirmation.len])) confirmation.len -= 1;
                @memcpy(confirmation.name[0..confirmation.len], row.name[0..confirmation.len]);
                self.confirmation = confirmation;
                self.cancelDrag();
                self.dispatcher.reset();
                self.dispatcher.focus(&self.modal, &self.modal_buttons[0]);
            }
        }
        self.dirty = true;
    }
    fn dismiss(self: *App) void {
        self.confirmation = null;
        self.dispatcher.reset();
        self.dirty = true;
    }
    fn send(self: *App, identity: proc.Identity, kind: actions.Kind) void {
        actions.execute(identity, kind) catch |err| {
            self.notice = actions.message(err);
            self.dirty = true;
            return;
        };
        self.notice = if (kind == .end) tr("Termination requested") else tr("Force quit requested");
        self.dirty = true;
    }
    pub fn cancelDrag(self: *App) void {
        self.px = -1;
        self.py = -1;
        self.bar_drag.end();
        self.dispatcher.pressed = null;
        self.dispatcher.text_drag = null;
        if (self.initialized) self.dispatcher.pointerLeave(self.tree());
    }
    pub fn cursorName(self: *App) [*:0]const u8 {
        return if (self.dispatcher.overText()) "text" else if (self.dispatcher.hovered != null) "pointer" else "default";
    }
    pub fn handleMotion(self: *App, x: f64, y: f64) void {
        self.ensureWidgets();
        self.px = @floatCast(x);
        self.py = @floatCast(y);
        if (self.confirmation == null and self.bar_drag.active) if (self.barGeometry()) |g| {
            self.model.scroll = self.bar_drag.offsetAt(g, self.px, self.py);
        };
        self.dispatcher.pointerMotion(self.tree(), self.px, self.py);
        self.dirty = true;
    }
    pub fn handleButton(self: *App, code: u32, pressed: bool) void {
        self.ensureWidgets();
        if (code != 0x110) return;
        if (!pressed) {
            self.bar_drag.end();
            self.dispatcher.pointerButtonUp(self.tree(), self.px, self.py);
            self.applyPending();
        } else {
            if (self.confirmation == null) {
                if (self.barGeometry()) |g| if (scrollbar.press(g, self.px, self.py, @floatCast(self.model.scroll))) |decision| {
                    switch (decision) {
                        .grab => self.bar_drag.begin(g, self.px, self.py, @floatCast(self.model.scroll)),
                        .page => |offset| self.model.scroll = offset,
                    }
                    self.dirty = true;
                    return;
                };
                if (self.processAt()) |index| {
                    self.model.selected = self.model.snapshot.?.processes[self.model.rows.items[index]].identity;
                    self.notice = "";
                    self.dispatcher.focus(&self.root, null);
                }
            }
            self.dispatcher.pointerButtonDown(self.tree(), self.px, self.py);
        }
        self.dirty = true;
    }
    pub fn handleScroll(self: *App, value: f64) void {
        if (self.confirmation != null) return;
        self.model.scroll += value * 3;
        self.clampScroll();
        self.dirty = true;
    }
    pub fn handleKey(self: *App, sym: u32, text: []const u8) void {
        self.ensureWidgets();
        self.dirty = true;
        if (self.ctrl and (sym == c.XKB_KEY_q or sym == c.XKB_KEY_w)) {
            self.requestClose();
            return;
        }
        if (sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab) {
            _ = self.dispatcher.focusNext(self.tree(), self.shift or sym == c.XKB_KEY_ISO_Left_Tab);
            return;
        }
        if (self.confirmation != null) {
            if (sym == c.XKB_KEY_Escape) self.dismiss() else if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_space) self.activateFocused();
            return;
        }
        if (self.ctrl and sym == c.XKB_KEY_f) {
            self.dispatcher.focus(&self.root, &self.toolbar[0]);
            ui.widgets.text_input.selectAll(&self.toolbar[0]);
            return;
        }
        if (sym == c.XKB_KEY_Escape and self.card_open and self.dispatcher.focused != &self.toolbar[0]) {
            self.card_request = 2;
            self.applyPending();
            return;
        }
        if (sym == c.XKB_KEY_Escape) {
            if (self.toolbar[0].kind.text_input.value.len > 0) {
                ui.widgets.text_input.selectAll(&self.toolbar[0]);
                ui.widgets.text_input.insertText(a, &self.toolbar[0], "") catch {};
            }
            self.dispatcher.focus(&self.root, null);
            return;
        }
        const field_focused = self.dispatcher.focused == &self.toolbar[0];
        if (field_focused and sym != c.XKB_KEY_Down and sym != c.XKB_KEY_Up and sym != c.XKB_KEY_Return) {
            const key: ?ui.input.Key = switch (sym) {
                c.XKB_KEY_BackSpace => .backspace,
                c.XKB_KEY_Delete => .delete,
                c.XKB_KEY_Left => .left,
                c.XKB_KEY_Right => .right,
                c.XKB_KEY_Home => .home,
                c.XKB_KEY_End => .end,
                else => if (self.ctrl and sym == c.XKB_KEY_a) .select_all else if (!self.ctrl and !self.alt and text.len > 0) .{ .char = text } else null,
            };
            if (key) |k| {
                const outcome = self.dispatcher.keyEvent(a, k, .{ .shift = self.shift }) catch return;
                if (outcome.copy) |copy| a.free(copy);
            }
            return;
        }
        if (sym == c.XKB_KEY_Return or sym == c.XKB_KEY_space) {
            self.activateFocused();
        } else if (sym == c.XKB_KEY_Delete and !self.ctrl and !self.alt) {
            self.pending = if (self.shift) .confirm else .end;
            self.applyPending();
        } else if (sym == c.XKB_KEY_Up or sym == c.XKB_KEY_Down or sym == c.XKB_KEY_Page_Up or sym == c.XKB_KEY_Page_Down or sym == c.XKB_KEY_Home or sym == c.XKB_KEY_End) {
            if (self.model.rows.items.len == 0) return;
            self.dispatcher.focus(&self.root, null);
            const last = self.model.rows.items.len - 1;
            const current = self.model.selectedIndex() orelse if (sym == c.XKB_KEY_Up) last else 0;
            const page: usize = @intFromFloat(@max(1, @floor(self.listBox().h / row_h)));
            const index = switch (sym) {
                c.XKB_KEY_Up => current -| 1,
                c.XKB_KEY_Down => @min(last, current + 1),
                c.XKB_KEY_Page_Up => current -| page,
                c.XKB_KEY_Page_Down => @min(last, current + page),
                c.XKB_KEY_Home => 0,
                else => last,
            };
            self.model.selected = self.model.snapshot.?.processes[self.model.rows.items[index]].identity;
            const y = @as(f64, @floatFromInt(index)) * row_h;
            if (y < self.model.scroll) self.model.scroll = y;
            if (y + row_h > self.model.scroll + self.listBox().h) self.model.scroll = y + row_h - self.listBox().h;
            self.clampScroll();
        } else if (!self.ctrl and !self.alt and text.len > 0) {
            self.dispatcher.focus(&self.root, &self.toolbar[0]);
            ui.widgets.text_input.insertText(a, &self.toolbar[0], text) catch {};
        }
    }
    fn activateFocused(self: *App) void {
        const focused = self.dispatcher.focused orelse return;
        if (focused.kind == .button) ui.widgets.button.press(focused);
        if (focused.kind == .row) if (focused.kind.row.on_click) |click| click(focused.kind.row.owner, focused.kind.row.id);
        self.applyPending();
    }
    pub fn keyRepeats(self: *App, sym: u32, text: []const u8) bool {
        if (self.confirmation != null or self.ctrl or self.alt) return false;
        return sym == c.XKB_KEY_Up or sym == c.XKB_KEY_Down or sym == c.XKB_KEY_Page_Up or sym == c.XKB_KEY_Page_Down or sym == c.XKB_KEY_BackSpace or (self.dispatcher.focused == &self.toolbar[0] and text.len > 0);
    }
    pub fn listBox(self: *const App) Rect {
        return .{ .x = 16, .y = 236, .w = @floatFromInt(self.w - 32), .h = @max(0, @as(f32, @floatFromInt(self.h)) - 264 - footer_view.height(self)) };
    }
    fn processAt(self: *const App) ?usize {
        if (self.confirmation != null or self.suspended or self.bar_drag.active) return null;
        const list = self.listBox();
        const right = list.x + list.w - scrollbar.gutter(theme.global.scrollbar_width);
        if (self.px < list.x or self.px >= right or self.py < list.y or self.py >= list.y + list.h) return null;
        const index: usize = @intFromFloat(@floor((self.py - list.y + self.model.scroll) / row_h));
        return if (index < self.model.rows.items.len) index else null;
    }
    pub fn rowBox(self: *const App, row: f32) cairo.ItemBox {
        const list = self.listBox();
        return .{ .x = list.x + 1, .y = list.y + @as(f64, row) * row_h - self.model.scroll + 1, .w = list.w - scrollbar.gutter(theme.global.scrollbar_width) - 2, .h = row_h - 2 };
    }
    fn clampScroll(self: *App) void {
        self.model.scroll = std.math.clamp(self.model.scroll, 0, @max(0, @as(f64, @floatFromInt(self.model.rows.items.len)) * row_h - self.listBox().h));
    }
    pub fn barGeometry(self: *const App) ?scrollbar.Geometry {
        const list = self.listBox();
        const gutter = scrollbar.gutter(theme.global.scrollbar_width);
        return scrollbar.Geometry.compute(.vertical, .{ .x = list.x + list.w - gutter, .y = list.y, .w = gutter, .h = list.h }, list.h, @as(f32, @floatFromInt(self.model.rows.items.len)) * @as(f32, @floatCast(row_h)), @floatCast(self.model.scroll));
    }
    pub fn stepAnimations(self: *App, now: i64) void {
        const t = if (self.card_anim.settled(now)) self.card_anim.to else self.card_anim.value(now);
        if (t != self.card_t) {
            self.card_t = t;
            self.layout();
            self.dirty = true;
        }
        const index = self.processAt();
        const hovered = if (index) |i| blk: {
            const identity = self.model.snapshot.?.processes[self.model.rows.items[i]].identity;
            if (self.model.selected) |selected| if (identity.eql(selected)) break :blk null;
            break :blk @as(?ui.hover_glide.Cell, .{ .col = 0, .row = @intCast(i) });
        } else null;
        self.row_hover.setTarget(now, hovered);
        const pixel = ui.anim.rasterPixelQuantum(@floatCast(self.density));
        if (self.row_hover.step(now, pixel, pixel / @as(f32, row_h))) self.dirty = true;
        if (self.model.selected) |identity| {
            const found = for (self.selections.items) |selection| {
                if (selection.identity.eql(identity)) break true;
            } else false;
            if (!found) self.selections.append(a, .{ .identity = identity }) catch {};
        }
        var i: usize = 0;
        while (i < self.selections.items.len) {
            const selection = &self.selections.items[i];
            const selected = if (self.model.selected) |identity| identity.eql(selection.identity) else false;
            if (selection.fade.step(now, selected)) self.dirty = true;
            if (!selected and selection.fade.alpha == 0 and selection.fade.animation.settled(now)) {
                _ = self.selections.swapRemove(i);
            } else i += 1;
        }
        const geom = self.barGeometry();
        const thumb_hovered = if (geom) |g| g.overThumb(self.px, self.py) else false;
        if (self.bar.step(now, self.model.scroll != self.last_scroll, thumb_hovered, self.bar_drag.active, geom != null)) self.dirty = true;
        self.last_scroll = self.model.scroll;
        if (self.focused and self.dispatcher.focused == &self.toolbar[0]) {
            const visible = self.dispatcher.caret.visible(now);
            const moving = self.dispatcher.caret.moving(now);
            if (visible != self.caret_visible or moving or moving != self.caret_moving) self.dirty = true;
            self.caret_visible = visible;
            self.caret_moving = moving;
        }
    }
    pub fn animationTimeout(self: *App, now: i64) ?u32 {
        if (self.suspended) return null;
        var timeout: ?u32 = if (self.bar.active) 16 else if (self.bar.deadline) |deadline| @intCast(@min(60000, @max(0, deadline - now))) else null;
        if (self.row_hover.animating(now) or !self.card_anim.settled(now)) timeout = 16;
        for (self.selections.items) |selection| if (!selection.fade.animation.settled(now)) {
            timeout = if (timeout) |existing| @min(existing, 16) else 16;
            break;
        };
        if (self.focused and self.dispatcher.focused == &self.toolbar[0] and self.dispatcher.caret.animating(now)) {
            const caret = self.dispatcher.caret;
            const half: i64 = @max(1, ui.input.caret_config.blink_ms / 2);
            var wait: u32 = if (caret.moving(now)) 16 else @intCast(half - @mod(now - caret.last_edit_ms, half));
            if (ui.input.caret_config.blink_timeout_s > 0) {
                const expiry = caret.last_edit_ms + @as(i64, ui.input.caret_config.blink_timeout_s) * 1000;
                wait = @min(wait, @as(u32, @intCast(@max(1, expiry - now))));
            }
            timeout = if (timeout) |existing| @min(existing, wait) else wait;
        }
        return timeout;
    }
    pub fn render(self: *App, cr: *c.cairo_t) void {
        self.ensureWidgets();
        self.layout();
        cairo.setSource(cr, theme.global.app_bg);
        c.cairo_paint(cr);
        self.paintSummary(cr);
        self.paintTable(cr);
        self.paintFooter(cr);
        self.toolbar[1].kind.button.label = if (self.model.mine) tr("My processes") else tr("All processes");
        self.toolbar[2].kind.button.label = if (self.paused) tr("Resume updates") else tr("Pause updates");
        for (&self.headers, titles, 0..) |*header, title, i| {
            header.kind.button.label = std.fmt.bufPrint(&self.header_labels[i], "{s}{s}", .{ title.get(), if (@backingInt(self.model.sort) == i) if (self.model.descending) " ↓" else " ↑" else "" }) catch title.get();
        }
        for (self.footer[1..]) |*control| {
            if (!self.manageable()) control.kind.button.state = .disabled else if (control.kind.button.state == .disabled) control.kind.button.state = .idle;
        }
        ui.input.active_dispatcher = &self.dispatcher;
        defer ui.input.active_dispatcher = null;
        if (cairo.Layer.begin(cr, .{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = @floatFromInt(self.h) })) |value| {
            var layer = value;
            ui.paint.paint(&self.root, &layer.renderer);
            layer.finish();
        }
        self.paintFooterStatus(cr);
        if (self.confirmation) |confirmation| self.paintConfirmation(cr, confirmation);
    }
    pub const paintSummary = summary.paint;
    pub const paintTable = table.paint;
    pub const paintFooter = footer_view.paint;
    pub const layoutFooter = footer_view.layout;
    pub const paintFooterStatus = footer_view.paintStatus;
    fn dialogBox(self: *const App) Rect {
        return .{ .x = (@as(f32, @floatFromInt(self.w)) - 520) / 2, .y = (@as(f32, @floatFromInt(self.h)) - 232) / 2, .w = 520, .h = 232 };
    }
    fn paintConfirmation(self: *App, cr: *c.cairo_t, confirmation: Confirmation) void {
        cairo.setSource(cr, ui.widgets.dialog.backdropColor());
        c.cairo_paint(cr);
        const box = self.dialogBox();
        if (cairo.Layer.begin(cr, box)) |value| {
            var layer = value;
            ui.widgets.dialog.paintFrame(&layer.renderer, layer.local());
            ui.widgets.dialog.paintHeader(&layer.renderer, 24, 24, box.w - 48, .{ .icon = .close, .title = tr("Force quit this process?"), .subtitle = tr("Unsaved work will be lost.") });
            layer.finish();
        }
        var buf: [512]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s} (PID {d})", .{ confirmation.name[0..confirmation.len], confirmation.identity.pid }) catch tr("Selected process");
        textBox(cr, label, .{ .x = box.x + 24, .y = box.y + 112, .w = box.w - 48, .h = 32 }, cairo.textSize(), true, theme.global.window_fg);
        if (cairo.Layer.begin(cr, .{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = @floatFromInt(self.h) })) |value| {
            var layer = value;
            ui.paint.paint(&self.modal, &layer.renderer);
            layer.finish();
        }
    }
};

pub fn textBox(cr: *c.cairo_t, text: []const u8, box: Rect, size: f32, bold: bool, color: [4]f32) void {
    if (box.w <= 0 or box.h <= 0) return;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, box.x, box.y, box.w, box.h);
    c.cairo_clip(cr);
    cairo.setSource(cr, color);
    const metrics = cairo.fontMetrics(cr, size);
    cairo.drawText(cr, text, box.x, box.y + (box.h - metrics.ascent - metrics.descent) / 2 + metrics.ascent, size, bold);
}
pub fn bytesLabel(buf: []u8, value: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var n: f64 = @floatFromInt(value);
    var unit: usize = 0;
    while (n >= 1024 and unit + 1 < units.len) : (unit += 1) n /= 1024;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ n, units[unit] }) catch "—";
}
pub fn bytesPair(buf: []u8, used: u64, total: u64) []const u8 {
    var left: [32]u8 = undefined;
    var right: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} / {s}", .{ bytesLabel(&left, used), bytesLabel(&right, total) }) catch "—";
}
