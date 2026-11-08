//! Files hover glide: which toolbar button, item or place is under the pointer, and the damage it causes.

const std = @import("std");
const App = @import("app.zig").App;
const anim = @import("ui").anim;
const header = @import("header.zig");
const interaction_surface = @import("ui").interaction_surface;
const hover_glide = @import("ui").hover_glide;
const button_widget = @import("ui").widgets.button;
const ui_theme = @import("ui").theme;
const pins_mod = @import("pins.zig");
const HoverLayout = App.HoverLayout;
const column_labels = App.column_labels;
const places = App.places;
const pin_base = App.pin_base;

pub fn hoverBounds(self: *App, key: usize) ?header.Rect {
    if (key >= 920 and key < 924) return @import("app_audio_bar.zig").rect(self);
    if (key >= std.math.maxInt(usize) - 4096) return null;
    if (key >= 900 and key < 904) return .{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = @floatFromInt(self.h) };
    if (key == 0) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    if (key >= 2_000_000) {
        const index = key - 2_000_000;
        return self.sizeButtonRect(index);
    }
    if (key >= 1000) {
        const index = key - 1000;
        if (index >= self.items.items.len or self.items.items[index].text().len > 8) return null; // May show a full-name tooltip.
        const i: i32 = @intCast(index);
        return .{ .x = @floatFromInt(self.sidebarWidth() + self.itemLeftInset() - 1 + @mod(i, self.columns()) * self.cellWidth()), .y = @floatFromInt(self.viewTop() + self.itemInset() - 1 + @divTrunc(i, self.columns()) * self.rowHeight() - self.scroll_y), .w = @floatFromInt(self.cellWidth() - 18), .h = @floatFromInt(self.cardHeight() + 2) };
    }
    if (self.chooser != null and key >= 500 and key < 513) {
        if (key > 500) return self.chooserRect(key - 501);
        return .{ .x = 0, .y = @floatFromInt(self.h - self.footerHeight()), .w = @floatFromInt(self.w), .h = @floatFromInt(self.footerHeight()) };
    }
    if (key >= 300 and key < 300 + places.len) {
        const row = self.placeRect(key - 300);
        return .{ .x = row.x - 1, .y = row.y - 1, .w = row.w + 2, .h = row.h + 2 };
    }
    if (key >= 800 and key < 800 + pins_mod.max) {
        if (key - 800 >= self.pins.items.items.len) return null;
        const row = self.placeRect(pin_base + key - 800);
        return .{ .x = row.x - 1, .y = row.y - 1, .w = row.w + 2, .h = row.h + 2 };
    }
    if (key >= 600 and key < 800) {
        const index = self.deviceBase() + key % 100;
        if (!self.placeVisible(index)) return null;
        const row = if (key < 700) self.placeRect(index) else self.ejectRect(index);
        return .{ .x = row.x - 1, .y = row.y - 1, .w = row.w + 2, .h = row.h + 2 };
    }
    if (key >= 400 and key < 400 + column_labels.len) return self.listColumn(key - 400);
    if (key >= 200 and key < 200 + std.meta.tags(header.Action).len) {
        var rect = header.rect(self.w, self.inRepository(), @enumFromInt(key - 200));
        rect.x -= 1;
        rect.y -= 1;
        rect.w += 2;
        rect.h += 2;
        return rect;
    }
    return null;
}

/// Queues `rect` for the next partial repaint. A queued full repaint
/// absorbs it; damage left over from the last paint is not pending, or
/// every hover would grow the next repaint by all the ones before it.
pub fn addDamage(self: *App, rect: header.Rect) void {
    if (self.dirty and self.paint_damage == null) return;
    self.paint_damage = if (self.dirty) unionRect(self.paint_damage.?, rect) else rect;
    self.dirty = true;
}

pub fn invalidateHover(self: *App, old: usize, new: usize) void {
    if (self.dirty and self.paint_damage == null) return;
    const before = self.hoverBounds(old) orelse {
        self.invalidate();
        return;
    };
    const after = self.hoverBounds(new) orelse {
        self.invalidate();
        return;
    };
    var rect = unionRect(before, after);
    // Out-of-viewport rows must not repaint over the pinned header or status.
    if ((old == 0 or old >= 1000) and (new == 0 or new >= 1000)) rect = self.clipToViewport(rect);
    self.addDamage(rect);
}

pub fn clipToViewport(self: *App, rect: header.Rect) header.Rect {
    const top: f64 = @floatFromInt(self.viewTop());
    const bottom = @min(rect.y + rect.h, @as(f64, @floatFromInt(self.contentBottom())));
    const y = @max(rect.y, top);
    return .{ .x = rect.x, .y = y, .w = rect.w, .h = @max(0, bottom - y) };
}

/// The pointer's list header column, using Files' existing header geometry.
pub fn updateColumnSurface(self: *App) void {
    if (!self.list_view or self.transfer_view.active or self.dialog != null or self.menu != null) {
        _ = self.column_surface.pointerMotion(null);
        return;
    }

    if (self.mouse_x < @as(f64, @floatFromInt(self.sidebarWidth())) or
        self.mouse_x >= @as(f64, @floatFromInt(self.w - self.scrollbarGutter())))
    {
        _ = self.column_surface.pointerMotion(null);
        return;
    }

    for (0..@min(4, column_labels.len)) |i| {
        const rect = self.listColumn(i);
        if (!rect.contains(self.mouse_x, self.mouse_y)) continue;

        _ = self.column_surface.pointerMotion(.{
            .id = @intCast(400 + i),
            .rect = .{
                .x = @floatCast(rect.x),
                .y = @floatCast(rect.y),
                .w = @floatCast(rect.w),
                .h = @floatCast(rect.h),
            },
            .clip = .{
                .x = @floatFromInt(self.sidebarWidth()),
                .y = @floatFromInt(self.contentTop()),
                .w = @floatFromInt(self.w - self.sidebarWidth() - self.scrollbarGutter()),
                .h = 30,
            },
            .role = .interactive,
        });
        return;
    }

    _ = self.column_surface.pointerMotion(null);
}

fn dialogSurfaceHit(id: usize, rect: header.Rect) interaction_surface.Hit {
    return .{
        .id = @intCast(id),
        .rect = .{
            .x = @floatCast(rect.x),
            .y = @floatCast(rect.y),
            .w = @floatCast(rect.w),
            .h = @floatCast(rect.h),
        },
        .clip = .{
            .x = @floatCast(rect.x),
            .y = @floatCast(rect.y),
            .w = @floatCast(rect.w),
            .h = @floatCast(rect.h),
        },
        .role = .button,
    };
}

/// The pointer's generic modal or inline rename button.
pub fn updateDialogSurface(self: *App) void {
    const dlg = self.dialog orelse {
        _ = self.dialog_surface.pointerMotion(null);
        return;
    };

    // These dialogs retain their own interaction and hit-testing paths.
    if (dlg.kind == .transfers or dlg.kind == .properties or
        dlg.kind == .open_with or dlg.kind == .trash_confirm)
    {
        _ = self.dialog_surface.pointerMotion(null);
        return;
    }

    var hit: ?interaction_surface.Hit = null;

    if (self.renameCard()) |card| {
        if (card.confirm.contains(self.mouse_x, self.mouse_y)) {
            hit = dialogSurfaceHit(1, card.confirm);
        } else if (card.cancel.contains(self.mouse_x, self.mouse_y)) {
            hit = dialogSurfaceHit(2, card.cancel);
        }
    } else {
        const dw: f64 = @min(440, @as(f64, @floatFromInt(self.w)) - 24);
        const dx = (@as(f64, @floatFromInt(self.w)) - dw) / 2;
        const dy = (@as(f64, @floatFromInt(self.h)) - 130) / 2;

        if (dlg.kind == .conflict) {
            const button_w = (dw - 48) / 3;
            for (0..3) |i| {
                const rect: header.Rect = .{
                    .x = dx + 16 + @as(f64, @floatFromInt(i)) * (button_w + 8),
                    .y = dy + 84,
                    .w = button_w,
                    .h = 28,
                };
                if (self.mouse_x >= rect.x and self.mouse_x <= rect.x + rect.w and
                    self.mouse_y >= rect.y and self.mouse_y <= rect.y + rect.h)
                {
                    hit = dialogSurfaceHit(i + 1, rect);
                    break;
                }
            }
        } else {
            const rects = [_]header.Rect{
                .{ .x = dx + dw - 184, .y = dy + 84, .w = 80, .h = 28 },
                .{ .x = dx + dw - 96, .y = dy + 84, .w = 80, .h = 28 },
            };
            for (rects, 0..) |rect, i| {
                if (self.mouse_x >= rect.x and self.mouse_x <= rect.x + rect.w and
                    self.mouse_y >= rect.y and self.mouse_y <= rect.y + rect.h)
                {
                    hit = dialogSurfaceHit(i + 1, rect);
                    break;
                }
            }
        }
    }

    _ = self.dialog_surface.pointerMotion(hit);
}

/// The pointer's sidebar row, unless that is the current place, which
/// paints its own fill.
pub fn updateSidebarSurface(self: *App) void {
    if (self.dialog != null or self.menu != null or self.sidebar_resize != null or
        self.overSidebarDivider(self.mouse_x, self.mouse_y))
    {
        _ = self.sidebar_surface.pointerMotion(null);
        return;
    }

    const index = self.placeAt(self.mouse_x, self.mouse_y) orelse {
        _ = self.sidebar_surface.pointerMotion(null);
        return;
    };
    const eject = self.ejectAt(self.mouse_x, self.mouse_y);
    const key: usize = if (eject) |k| 700 + k else switch (self.rowKind(index)) {
        .builtin => |b| 300 + b,
        .pin => |j| 800 + j,
        .device => |k| 600 + k,
    };
    const bounds = if (eject != null) self.ejectRect(index) else self.placeRect(index);

    _ = self.sidebar_surface.pointerMotion(.{
        .id = @intCast(key),
        .rect = .{
            .x = @floatCast(bounds.x),
            .y = @floatCast(bounds.y),
            .w = @floatCast(bounds.w),
            .h = @floatCast(bounds.h),
        },
        .clip = .{
            .x = 0,
            .y = @floatFromInt(self.contentTop()),
            .w = @floatFromInt(self.sidebarWidth()),
            .h = @floatFromInt(self.h - self.contentTop() - self.sidebarFooter()),
        },
        .role = .interactive,
    });
}

/// The pointer's item card, using Files' existing itemAt geometry.
pub fn updateItemSurface(self: *App) void {
    if (self.dialog != null or self.menu != null or self.transfer_view.active) {
        _ = self.item_surface.pointerMotion(null);
        return;
    }

    const index = self.itemAt(self.mouse_x, self.mouse_y) orelse {
        _ = self.item_surface.pointerMotion(null);
        return;
    };

    const per_row: usize = @intCast(self.columns());
    const col: i32 = @intCast(index % per_row);
    const row: i32 = @intCast(index / per_row);
    const cell = self.cellWidth();
    const rect: header.Rect = .{
        .x = @floatFromInt(self.sidebarWidth() + 20 + col * cell),
        .y = @floatFromInt(self.viewTop() + self.itemInset() - self.scroll_y + row * self.rowHeight()),
        .w = @floatFromInt(cell - 20),
        .h = @floatFromInt(self.cardHeight()),
    };
    const clip: header.Rect = .{
        .x = @floatFromInt(self.sidebarWidth() + 20),
        .y = @floatFromInt(self.viewTop()),
        .w = @floatFromInt(@max(0, self.w - self.sidebarWidth() - 20 - self.scrollbarGutter())),
        .h = @floatFromInt(@max(0, self.contentBottom() - self.viewTop())),
    };

    _ = self.item_surface.pointerMotion(.{
        .id = @intCast(index),
        .rect = .{
            .x = @floatCast(rect.x),
            .y = @floatCast(rect.y),
            .w = @floatCast(rect.w),
            .h = @floatCast(rect.h),
        },
        .clip = .{
            .x = @floatCast(clip.x),
            .y = @floatCast(clip.y),
            .w = @floatCast(clip.w),
            .h = @floatCast(clip.h),
        },
        .role = .interactive,
    });
}

/// The pointer's sidebar row, unless that is the current place, which
/// paints its own fill. The Surface retains the host's existing row identity.
pub fn hoveredPlace(self: *App) ?usize {
    if (self.dialog != null or self.menu != null) return null;
    if (self.sidebar_resize != null or self.overSidebarDivider(self.mouse_x, self.mouse_y)) return null;
    if (self.sidebarScrollbar()) |bar| {
        if (self.mouse_x >= @as(f64, bar.track.x)) return null;
    }

    const target = self.sidebar_surface.hovered orelse return null;
    const key: usize = @intCast(target.id);
    const index = if (key >= 300 and key < 300 + places.len)
        key - 300
    else if (key >= 800 and key < 800 + pins_mod.max) blk: {
        const pin = key - 800;
        if (pin >= self.pins.items.items.len) return null;
        break :blk pin_base + pin;
    } else if (key >= 600 and key < 700)
        self.deviceBase() + key - 600
    else if (key >= 700 and key < 800)
        self.deviceBase() + key - 700
    else
        return null;

    if (index >= self.rowCount() or !self.placeVisible(index)) return null;
    return if (self.placeActive(index)) null else index;
}

/// The pointer's item, unless it is selected, which paints its own fill.
pub fn hoveredItem(self: *App) ?usize {
    if (self.dialog != null or self.menu != null or self.transfer_view.active) return null;
    const target = self.item_surface.hovered orelse return null;
    const idx: usize = @intCast(target.id);
    if (idx >= self.items.items.len) return null;
    return if (self.items.items[idx].selected) null else idx;
}

/// The sidebar highlight at fractional place `frame.row`, between the
/// rows' real positions (they are not evenly spaced).
pub fn navHighlight(self: *App, frame: hover_glide.Frame) header.Rect {
    const last = self.rowCount() - 1;
    const row = std.math.clamp(frame.row, 0, @as(f32, @floatFromInt(last)));
    const low: usize = @min(@as(usize, @intFromFloat(@floor(row))), last);
    const high = @min(low + 1, last);
    const t: f64 = row - @floor(row);
    var rect = self.placeRect(low);
    rect.y += (self.placeRect(high).y - rect.y) * t;
    return rect;
}

/// The item highlight at fractional cell (`frame.col`, `frame.row`).
pub fn itemHighlight(self: *App, frame: hover_glide.Frame) header.Rect {
    const cell: f64 = @floatFromInt(self.cellWidth());
    return .{
        .x = @as(f64, @floatFromInt(self.sidebarWidth() + self.itemLeftInset())) + frame.col * cell,
        .y = @as(f64, @floatFromInt(self.viewTop() + self.itemInset() - self.scroll_y)) + frame.row * @as(f64, @floatFromInt(self.rowHeight())),
        .w = cell - 20,
        .h = @floatFromInt(self.cardHeight()),
    };
}

pub fn toolbarButtonVisible(self: *App, action: header.Action) bool {
    return action != .git_view and !(self.chooser != null and
        (action == .cut or action == .copy or action == .paste or action == .trash));
}

pub fn toolbarButtonEnabled(self: *App, action: header.Action) bool {
    if (self.isRecent() and (action == .new or action == .paste)) return false;
    if (self.history.archive_len > 0) switch (action) {
        .new, .cut, .copy, .paste, .trash => return false,
        else => {},
    };
    switch (self.trashRelation()) {
        // Read-only: items are restored or deleted, not created, cut or pasted.
        .root => switch (action) {
            .new, .cut, .paste => return false,
            else => {},
        },
        // Inside a trashed folder there is nothing to restore or delete either.
        .inside => switch (action) {
            .new, .cut, .paste, .trash => return false,
            else => {},
        },
        .none => {},
    }
    return switch (action) {
        .back => self.history.canBack(),
        .forward => self.history.canForward(),
        .up => self.history.canUp(),
        .cut, .copy, .trash => self.hasSelection(),
        else => true,
    };
}

pub fn updateToolbarSurface(self: *App) void {
    const action = if (self.transfer_view.active or self.dialog != null or self.menu != null)
        null
    else
        header.hit(self.w, self.inRepository(), self.mouse_x, self.mouse_y);
    if (action) |value| {
        const r = header.rect(self.w, self.inRepository(), value);
        _ = self.toolbar_surface.pointerMotion(.{
            .id = @intCast(@intFromEnum(value)),
            .rect = .{ .x = @floatCast(r.x), .y = @floatCast(r.y), .w = @floatCast(r.w), .h = @floatCast(r.h) },
            .clip = .{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = @floatFromInt(self.contentTop()) },
            .role = .button,
            .enabled = self.toolbarButtonVisible(value) and self.toolbarButtonEnabled(value),
        });
    } else {
        _ = self.toolbar_surface.pointerMotion(null);
    }
}

pub fn hoveredToolbarButton(self: *App) ?header.Rect {
    const target = self.toolbar_surface.hovered orelse return null;
    return .{
        .x = @floatCast(target.rect.x),
        .y = @floatCast(target.rect.y),
        .w = @floatCast(target.rect.w),
        .h = @floatCast(target.rect.h),
    };
}

/// Shared button proximity using Files' existing pointer and header geometry.
pub fn toolbarButtonProximity(
    self: *App,
    action: header.Action,
    x: f64,
    y: f64,
) button_widget.ProximitySample {
    const absent = button_widget.ProximitySample{
        .distance = std.math.inf(f32),
        .x = 0,
        .y = 0,
    };
    if (self.transfer_view.active or self.dialog != null or self.menu != null or
        !self.toolbarButtonVisible(action) or !self.toolbarButtonEnabled(action))
        return absent;

    const r = header.rect(self.w, self.inRepository(), action);
    return button_widget.sampleProximity(
        .{
            .x = @floatCast(r.x),
            .y = @floatCast(r.y),
            .w = @floatCast(r.w),
            .h = @floatCast(r.h),
        },
        @floatCast(x),
        @floatCast(y),
        .{
            .x = 0,
            .y = 0,
            .w = @floatFromInt(self.w),
            .h = @floatFromInt(self.contentTop()),
        },
    );
}

/// Repaint only toolbar buttons whose proximity appearance may have changed.
pub fn damageToolbarProximity(self: *App, old_x: f64, old_y: f64, new_x: f64, new_y: f64) void {
    const reach = ui_theme.global.border_glow_reach;
    if (reach <= 0) return;
    if (!ui_theme.global.button_hover_glow_enabled and ui_theme.global.button_relief == .flat) return;

    var damage: ?header.Rect = null;
    for (std.meta.tags(header.Action)) |action| {
        if (!self.toolbarButtonVisible(action) or !self.toolbarButtonEnabled(action)) continue;

        const before = self.toolbarButtonProximity(action, old_x, old_y);
        const after = self.toolbarButtonProximity(action, new_x, new_y);
        if (@min(before.distance, after.distance) > reach) continue;

        const rect = header.rect(self.w, self.inRepository(), action);
        damage = if (damage) |current| unionRect(current, rect) else rect;
    }
    if (damage) |rect| self.addDamage(rect);
}

/// Samples the hover highlights and queues damage for what moved or
/// faded. Once per loop, before painting: the painters draw the sampled
/// `frame`, so a partial repaint and a complete one agree.
pub fn stepHover(self: *App, now: i64) void {
    const pixel = anim.rasterPixelQuantum(@floatFromInt(self.scale));

    self.updateItemSurface();
    self.updateSidebarSurface();
    self.updateColumnSurface();
    self.updateDialogSurface();
    if (self.sidebarWidth() > 0) {
        const before = self.nav_hover.frame;
        self.nav_hover.setTarget(now, if (self.hoveredPlace()) |i| .{ .col = 0, .row = @intCast(i) } else null);
        // Rows are at least 32 px apart, so this is at most a pixel.
        if (self.nav_hover.step(now, pixel, pixel / 32)) {
            const side: header.Rect = .{ .x = 0, .y = @floatFromInt(self.contentTop()), .w = @floatFromInt(self.sidebarWidth()), .h = @floatFromInt(self.h - self.contentTop() - self.sidebarFooter()) };
            self.damageHighlight(side, if (before.alpha > 0) self.navHighlight(before) else null, if (self.nav_hover.frame.alpha > 0) self.navHighlight(self.nav_hover.frame) else null);
        }
    } else self.nav_hover.reset();

    // Cells mean something else once the grid reflows or becomes a list.
    const layout: HoverLayout = .{ .columns = self.columns(), .list = self.list_view };
    if (!std.meta.eql(layout, self.item_hover_layout)) {
        self.item_hover_layout = layout;
        if (self.item_hover.frame.alpha > 0) self.invalidate();
        self.item_hover.reset();
    }
    const before = self.item_hover.frame;
    const per_row: usize = @intCast(self.columns());
    self.item_hover.setTarget(now, if (self.hoveredItem()) |idx| .{ .col = @intCast(idx % per_row), .row = @intCast(idx / per_row) } else null);
    const cell: f32 = @floatFromInt(@max(1, self.cellWidth()));
    const row: f32 = @floatFromInt(@max(1, self.rowHeight()));
    if (self.item_hover.step(now, pixel / cell, pixel / row)) {
        const view: header.Rect = self.clipToViewport(.{ .x = @floatFromInt(self.sidebarWidth()), .y = 0, .w = @floatFromInt(self.w - self.sidebarWidth()), .h = @floatFromInt(self.h) });
        self.damageHighlight(view, if (before.alpha > 0) self.itemHighlight(before) else null, if (self.item_hover.frame.alpha > 0) self.itemHighlight(self.item_hover.frame) else null);
    }
    self.updateToolbarSurface();
    if (self.toolbar_hover.step(now, self.hoveredToolbarButton(), pixel)) {
        self.addDamage(.{ .x = 0, .y = 0, .w = @floatFromInt(self.w), .h = @floatFromInt(self.contentTop()) });
    }
    self.hover_active = self.nav_hover.animating(now) or self.item_hover.animating(now) or self.toolbar_hover.active(now);
    if (self.sort_feedback.step(now, false) and self.list_view) {
        // Full rows avoid cutting neighbouring rounded selection outlines.
        self.addDamage(.{ .x = @floatFromInt(self.sidebarWidth()), .y = @floatFromInt(self.contentTop()), .w = @floatFromInt(self.w - self.sidebarWidth()), .h = @floatFromInt(@max(0, self.h - self.contentTop() - self.footerHeight())) });
    }
    self.hover_active = self.hover_active or !self.sort_feedback.animation.settled(now);
    // Only visible cards need samples or a frame clock. Logical selection
    // changes immediately; painting and damage share these sampled fades.
    const viewport_h = @max(0, self.contentBottom() - self.viewTop());
    const first: usize = @min(self.items.items.len, @as(usize, @intCast(@divTrunc(self.scroll_y, self.rowHeight()))) * per_row);
    const last: usize = @min(self.items.items.len, @as(usize, @intCast(@divTrunc(self.scroll_y + viewport_h, self.rowHeight()) + 1)) * per_row);
    for (self.items.items[first..last], first..) |*item, idx| {
        const fill_changed = item.selection_fill.step(now, item.selected);
        const border_changed = item.selection_border.step(now, item.selected or self.focused_index == idx);
        if (fill_changed or border_changed) {
            var rect = self.itemHighlight(.{ .col = @floatFromInt(idx % per_row), .row = @floatFromInt(idx / per_row) });
            // Repair the whole row: a merged header/hover clip can otherwise
            // cut a neighbouring rounded card and change Cairo's antialiasing.
            rect.x = @floatFromInt(self.sidebarWidth());
            rect.w = @floatFromInt(self.w - self.sidebarWidth());
            rect.y -= 1;
            rect.h += 2;
            self.addDamage(self.clipToViewport(rect));
        }
        self.hover_active = self.hover_active or !item.selection_fill.animation.settled(now) or !item.selection_border.animation.settled(now);
    }
    const field = header.field(self.w);
    const hit = if (!self.transfer_view.active and !self.search_visible and self.focus != .location_bar and
        self.dialog == null and self.menu == null and field.contains(self.mouse_x, self.mouse_y))
        self.breadcrumbs(null, self.mouse_x)
    else
        null;
    for (&self.breadcrumb_hover, 0..) |*fade, i| {
        fade.setTarget(now, if (hit != null and hit.?.index == i) .{ .col = 0, .row = 0 } else null);
        if (fade.step(now, 1, 1)) self.addDamage(field);
        self.hover_active = self.hover_active or fade.animating(now);
    }
}

/// Damage for a highlight that moved from `old` to `new` (null when it
/// was not drawn), inside `area`; a pixel wider for the border's edge.
pub fn damageHighlight(self: *App, area: header.Rect, old: ?header.Rect, new: ?header.Rect) void {
    var rect: header.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    for ([_]?header.Rect{ old, new }) |candidate| {
        const r = candidate orelse continue;
        rect = unionRect(rect, .{ .x = r.x - 1, .y = r.y - 1, .w = r.w + 2, .h = r.h + 2 });
    }
    const x1 = @max(rect.x, area.x);
    const y1 = @max(rect.y, area.y);
    const x2 = @min(rect.x + rect.w, area.x + area.w);
    const y2 = @min(rect.y + rect.h, area.y + area.h);
    if (x2 <= x1 or y2 <= y1) return;
    self.addDamage(.{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 });
}

pub fn unionRect(a: header.Rect, b: header.Rect) header.Rect {
    if (a.w == 0 or a.h == 0) return b;
    if (b.w == 0 or b.h == 0) return a;
    const x = @min(a.x, b.x);
    const y = @min(a.y, b.y);
    return .{ .x = x, .y = y, .w = @max(a.x + a.w, b.x + b.w) - x, .h = @max(a.y + a.h, b.y + b.h) - y };
}
