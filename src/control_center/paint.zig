//! The frame tick, the sidebar's animated highlight and painting content.

const std = @import("std");
const pixman = @import("pixman");
const gpa = @import("../main.zig").gpa;
const anim = @import("ui").anim;
const panel_buffer = @import("../panel_buffer.zig");
const panel_present = @import("../panel_present.zig");
const PanelBuffer = panel_buffer.PanelBuffer;
const ui = @import("ui");
const layout = ui.layout;
const Widget = layout.Widget;
const log = std.log.scoped(.control_center);
const settings_search = @import("search.zig");
const panel = @import("panel.zig");
const palette = panel.palette;
const pageClicked = panel.pageClicked;
const ControlCenter = @import("ControlCenter.zig");

/// Runs once per frame of `wlr_output` while anything is pending.
/// Returns whether another frame should be scheduled.
pub fn tick(cc: *ControlCenter, now_ms: i64) bool {
    cc.search.syncAvailability(cc);
    if (cc.search.pending_result != null) settings_search.apply(cc);
    // A live update must not wait for an open dropdown: that leaves the
    // page permanently unsettled. rebuildTree preserves compatible menus.
    const rebuild = cc.refresh_pending and !cc.pointer_down;
    if ((cc.layout_pending or rebuild) and cc.panel_box.width > 0 and cc.panel_box.height > 0) {
        cc.layout_pending = false;
        const body = if (!cc.search.reset_scroll and cc.search.empty() == cc.search.built_empty and cc.body_children[1].kind == .scroll_container) cc.body_children[1].kind.scroll_container else null;
        if (rebuild or cc.resizeNeedsTree()) cc.rebuildTree();
        cc.resizeLayout();
        // Keep a wheel glide going across the rebuild.
        if (cc.body_children[1].kind == .scroll_container) {
            if (body) |state| cc.body_children[1].kind.scroll_container = state;
        }
        cc.layoutContent();
    }
    if (cc.scroll_gliding) {
        const revision = ui.layout.paint_revision;
        cc.scroll_gliding = ui.widgets.scroll_container.stepGlides(&cc.root, now_ms, anim.rasterPixelQuantum(cc.toplevel.render_scale));
        if (revision != ui.layout.paint_revision) cc.dirty = true;
    }
    {
        const revision = ui.layout.paint_revision;
        cc.bars = ui.widgets.scroll_container.stepBars(&cc.root, now_ms);
        if (revision != ui.layout.paint_revision) cc.dirty = true;
    }
    if (cc.painted_scale != cc.toplevel.render_scale) {
        cc.background.invalidate();
        cc.dirty = true;
    }
    if (cc.stepNavHighlights(now_ms)) cc.dirty = true;
    if (cc.dirty) cc.paintContent();
    const selection_moving = anim.observeUnsettled(cc.nav_selection, now_ms);
    const hover_moving = anim.observeUnsettled(cc.nav_hover.row, now_ms);
    const hover_fading = anim.observeUnsettled(cc.nav_hover.alpha, now_ms);
    const nav_moving = selection_moving or hover_moving or hover_fading;
    return cc.dirty or cc.layout_pending or ((cc.scroll_gliding or cc.bars.pending() or nav_moving) and !anim.clockOverridden());
}

pub fn syncNavHover(cc: *ControlCenter) void {
    const cell: ?ui.hover_glide.Cell = if (ui.input.current.hovered) |widget| switch (widget.kind) {
        .row => |data| if (data.owner == @as(?*anyopaque, cc) and data.on_click == pageClicked)
            .{ .col = 0, .row = @intCast(cc.navIndex(@fromBackingInt(@intCast(data.id))) orelse return) }
        else
            null,
        else => null,
    } else null;
    if (std.meta.eql(cc.nav_hover.target, cell)) return;
    cc.nav_hover.setTarget(anim.nowMs(), cell);
    cc.scheduleFrame();
}

pub fn stepNavHighlights(cc: *ControlCenter, now_ms: i64) bool {
    if (cc.is_welcome) return false;
    const list = &cc.sidebar_children[1];
    if (list.children.len == 0) return false;
    const pitch = @max(1, list.children[0].computed_height + list.gap);
    const q = anim.rasterPixelQuantum(cc.toplevel.render_scale) / pitch;
    const pos = cc.nav_selection.value(now_ms);
    const selected = if (cc.nav_selection.settled(now_ms)) pos else @round(pos / q) * q;
    const before = cc.nav_hover.frame;
    const hover_changed = cc.nav_hover.step(now_ms, 1, q);
    const selection_changed = selected != cc.nav_selected_row;
    if (!selection_changed and !hover_changed) return false;
    // Repaint the rows the highlights left and reached, not the whole
    // list: the hover's opacity also depends on the selection.
    if (selection_changed) {
        markNavRows(list, cc.nav_selected_row);
        markNavRows(list, selected);
    }
    if (hover_changed or (selection_changed and before.alpha > 0)) {
        markNavRows(list, before.row);
        markNavRows(list, cc.nav_hover.frame.row);
    }
    cc.nav_selected_row = selected;
    anim.observeNoteChanged();
    return true;
}

/// The one or two rows a highlight at fractional row `pos` covers.
pub fn markNavRows(list: *Widget, pos: f32) void {
    const clamped = std.math.clamp(pos, 0, @as(f32, @floatFromInt(list.children.len - 1)));
    list.children[@intFromFloat(@floor(clamped))].markPaintDirty();
    list.children[@intFromFloat(@ceil(clamped))].markPaintDirty();
}

/// Paint once beneath the rows so the fills can move through their gaps.
pub fn paintNavHighlights(owner: ?*anyopaque, list: *const Widget, renderer: *ui.paint.Renderer) void {
    const cc: *ControlCenter = @ptrCast(@alignCast(owner orelse return));
    if (list.children.len == 0) return;
    const t = renderer.palette orelse palette();
    const hover = cc.nav_hover.frame;
    const apart = std.math.clamp(@abs(hover.row - cc.nav_selected_row), 0, 1);
    const alpha = std.math.clamp(hover.alpha, 0, 1) * apart;
    if (alpha > 0) {
        const box = navRowBox(list, hover.row);
        ui.widgets.highlight.paint(renderer, box, .{
            .color = scaleAlpha(t.sidebarHover(), alpha),
            .radius = t.radius,
            .border_width = 1,
            .border_color = scaleAlpha(t.border_soft, alpha),
        });
    }
    const box = navRowBox(list, cc.nav_selected_row);
    ui.widgets.highlight.paint(renderer, box, .{
        .color = t.sidebarSelected(),
        .radius = t.radius,
        .border_width = 1,
        .border_color = t.start_menu_selected_border,
    });
    const marker_h = @max(10, box.h - 18);
    renderer.fillRect(box.x + 3, box.y + (box.h - marker_h) / 2, 3, marker_h, .{
        .color = t.start_menu_selected_marker,
        .radius = 1.5,
    });
}

pub fn navRowBox(list: *const Widget, pos: f32) ui.paint.ClipRect {
    const clamped = std.math.clamp(pos, 0, @as(f32, @floatFromInt(list.children.len - 1)));
    const lo: usize = @intFromFloat(@floor(clamped));
    const a = &list.children[lo];
    const b = &list.children[@min(lo + 1, list.children.len - 1)];
    const f = clamped - @as(f32, @floatFromInt(lo));
    return .{ .x = a.computed_x, .y = a.computed_y + (b.computed_y - a.computed_y) * f, .w = a.computed_width, .h = a.computed_height };
}

pub fn scaleAlpha(color: [4]f32, alpha: f32) [4]f32 {
    return .{ color[0], color[1], color[2], color[3] * alpha };
}

pub fn requestWidgetRepaint(cc: *ControlCenter) void {
    cc.dirty = true;
    cc.scheduleFrame();
}

pub fn requestRepaint(cc: *ControlCenter) void {
    cc.background.invalidate();
    cc.dirty = true;
    cc.scheduleFrame();
}

pub fn paintContent(cc: *ControlCenter) void {
    if (cc.panel_box.width <= 0 or cc.panel_box.height <= 0) return;
    // The window's chrome raster scale: the highest output scale it touches.
    const scale = cc.toplevel.render_scale;
    if (cc.painted_scale != scale) cc.background.invalidate();
    const buf = PanelBuffer.createRetained(cc.panel_box.width, cc.panel_box.height, scale, &cc.background) catch |err| {
        log.err("ControlCenter.paintContent: could not create panel buffer: {}", .{err});
        return;
    };

    const t0 = panel_present.nowNs();
    var renderer = ui.paint.Renderer.init(buf.pixels, buf.width, buf.height, scale);
    renderer.palette = palette();
    cc.background.paintIncremental(gpa, &cc.root, &renderer, &buf.stamp);
    const elapsed_ns = panel_present.nowNs() -| t0;

    // A world node reaches its projected view only with the damage we
    // report (AGENTS.md, "Damage and retained pixels"); buffer-local, at the real raster scale.
    var region: pixman.Region32 = undefined;
    region.init();
    defer region.deinit();
    const full = cc.painted_scale != scale or cc.background.damage == null;
    if (cc.background.damage) |box| {
        const x: i32 = @intFromFloat(@floor(box.x * scale));
        const y: i32 = @intFromFloat(@floor(box.y * scale));
        const right: i32 = @intFromFloat(@ceil((box.x + box.w) * scale));
        const bottom: i32 = @intFromFloat(@ceil((box.y + box.h) * scale));
        _ = region.unionRect(&region, x, y, @intCast(@max(0, right - x)), @intCast(@max(0, bottom - y)));
    }
    _ = cc.server.world.projection.presentOwned(cc.buffer_node, cc.server.renderer, &buf.base, if (full) null else &region);
    cc.buffer_node.setDestSize(cc.panel_box.width, cc.panel_box.height);
    buf.base.drop();
    cc.server.switcher.committed(cc.toplevel);
    panel_present.addPaint(elapsed_ns);
    cc.painted_scale = scale;
    cc.dirty = false;
}
