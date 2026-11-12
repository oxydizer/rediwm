//! Sizing and relayout, loading and prefetching icons, painting and presentation.

const std = @import("std");
const glass = @import("../glass.zig");
const wlr = @import("wlroots");
const gpa = @import("../main.zig").gpa;
const anim = @import("ui").anim;
const geometry = @import("../geometry.zig");
const panel_buffer = @import("../panel_buffer.zig");
const panel_present = @import("../panel_present.zig");
const PanelBuffer = panel_buffer.PanelBuffer;
const Taskbar = @import("../Taskbar.zig");
const Output = @import("../Output.zig");
const icon_service = @import("../icon_service.zig");
const ui = @import("ui");
const theme = ui.theme;
const model_mod = @import("model.zig");
const size_mod = @import("size.zig");
const SearchResult = model_mod.SearchResult;
const log = std.log.scoped(.start_menu);
const panel = @import("panel.zig");
const slide_distance = panel.slide_distance;
const updateIcon = panel.updateIcon;
const menuPalette = panel.menuPalette;
const StartMenu = @import("StartMenu.zig");

/// The size the theme asks for on this menu's output, before the caps in
/// `relayout`: its own values, else the automatic ones (`size.zig`).
pub fn wantedSize(menu: *StartMenu) size_mod.Size {
    var box: wlr.Box = undefined;
    menu.server.output_layout.getBox(menu.wlr_output, &box);
    if (menu.mode == .launcher) return .{
        .width = if (theme.global.start_menu_width > 0) theme.global.start_menu_width else 760,
        .height = if (theme.global.start_menu_max_height > 0) theme.global.start_menu_max_height else 720,
    };
    return size_mod.wanted(theme.global, @floatFromInt(box.width), @floatFromInt(box.height));
}

pub fn relayout(menu: *StartMenu) void {
    menu.background.invalidate();
    var output_box: wlr.Box = undefined;
    menu.server.output_layout.getBox(menu.wlr_output, &output_box);
    if (output_box.width <= 0 or output_box.height <= 0) return;

    const wanted = menu.wantedSize();
    const max_allowed_h = @min(wanted.height, @as(f32, @floatFromInt(output_box.height)) * 0.85);
    const max_allowed_w = @min(wanted.width, @as(f32, @floatFromInt(output_box.width)) - 40);

    const target_height = if (menu.mode == .launcher) @max(1, max_allowed_h) else @max(240, max_allowed_h);
    const target_width = if (menu.mode == .launcher) @max(1, max_allowed_w) else @max(320, max_allowed_w);

    const scroll_offset = menu.currentScrollOffset();
    if (menu.mode == .launcher and menu.panel_box.width > 0 and
        (menu.panel_box.width != @as(i32, @intFromFloat(target_width)) or menu.panel_box.height != @as(i32, @intFromFloat(target_height)))) menu.buildTree();
    menu.root.width = .{ .fixed = target_width };
    menu.root.height = .{ .fixed = target_height };
    ui.measure.measure(&menu.root, target_width, target_height);
    ui.arrange.arrange(&menu.root, 0, 0, target_width, target_height);
    menu.restoreScrollOffset(scroll_offset);

    const bottom_offset: f32 = @as(f32, @floatFromInt(Taskbar.reservedHeight())) + theme.global.start_menu_bottom_pad;
    const start_offset: f32 = if (Output.fromWlr(menu.wlr_output)) |output| if (output.taskbar) |bar| @floatFromInt(bar.startButtonBox().x - output_box.x - Taskbar.startButtonLeft()) else 0 else 0;
    const panel_left = std.math.clamp(theme.global.start_menu_left_pad + start_offset, 0, @max(0, @as(f32, @floatFromInt(output_box.width)) - target_width));

    menu.panel_box = .{
        .x = output_box.x + @as(i32, @intFromFloat(panel_left)),
        .y = if (menu.server.config.compositor.taskbar_position == .top) output_box.y + @as(i32, @intFromFloat(bottom_offset)) else output_box.y + output_box.height - @as(i32, @intFromFloat(bottom_offset)) - @as(i32, @intFromFloat(target_height)),
        .width = @intFromFloat(target_width),
        .height = @intFromFloat(target_height),
    };
    if (menu.mode == .launcher) {
        menu.panel_box.x = output_box.x + @divTrunc(output_box.width - menu.panel_box.width, 2);
        menu.panel_box.y = output_box.y + @divTrunc(output_box.height - menu.panel_box.height, 2);
    }
    menu.dirty = true;
    menu.paintContent();
    menu.applyPresentation(anim.nowMs());
}

/// Worker completions also include speculative/offscreen icons. Only a
/// changed visible raster needs a panel repaint.
pub fn iconsReady(menu: *StartMenu) void {
    if (menu.loadVisibleIcons()) menu.requestWidgetRepaint();
}

pub fn loadVisibleIcons(menu: *StartMenu) bool {
    var changed = false;
    var scroll_offset: f32 = 0;
    var have_viewport = false;
    var first_visible: ?usize = null;
    var last_visible: usize = 0;

    for (menu.root.children) |*viewport| {
        if (viewport.kind != .scroll_container) continue;
        have_viewport = true;
        scroll_offset = viewport.kind.scroll_container.scroll_offset;
        for (viewport.children, 0..) |*row, index| {
            const img = &row.children[0].kind.image;
            if (row.computed_y + row.computed_height <= viewport.computed_y or
                row.computed_y >= viewport.computed_y + viewport.computed_height)
            {
                _ = updateIcon(img, &menu.visible_icon_ids[index], .missing);
                continue;
            }
            if (first_visible == null) first_visible = index;
            last_visible = index;
            const lookup = if (menu.model.results[index].icon) |name|
                menu.server.iconLookup(name, geometry.devicePixels(38, menu.wlr_output.scale))
            else
                icon_service.Lookup.missing;
            if (updateIcon(img, &menu.visible_icon_ids[index], lookup)) {
                row.children[0].markPaintDirty();
                changed = true;
            }
        }
    }

    for (menu.root.children) |*strip| {
        if (!std.mem.eql(u8, strip.name orelse "", "recent_cards")) continue;
        for (strip.children, 0..) |*card, i| {
            const img = &card.children[1];
            const result = menu.model.results[menu.card_indices[i]];
            const lookup = if (result.icon) |name| menu.server.iconLookup(name, geometry.devicePixels(48, menu.wlr_output.scale)) else icon_service.Lookup.missing;
            if (updateIcon(&img.kind.image, &menu.card_icons[i], lookup)) {
                img.markPaintDirty();
                changed = true;
            }
        }
    }
    if (have_viewport) menu.prefetchAhead(scroll_offset, first_visible, last_visible);
    return changed;
}

// Step 5 (scroll-direction + initial-results prefetch) and step 6
// (stale-interest cancellation), folded into one pass since they're two
// halves of the same decision: once the visible viewport or result set
// has moved since the last paint, whatever was speculatively queued for
// the *old* one is no longer useful, so cancel it before queuing fresh
// prefetch for the new one. `results.ptr` changing is a cheap, reliable
// "new query/category" signal — `Model.update` always rebuilds
// `results` from a fresh arena allocation, even for identical content.
// Recent-card icons are visible lookups handled alongside the list above.
pub fn prefetchAhead(menu: *StartMenu, scroll_offset: f32, first_visible: ?usize, last_visible: usize) void {
    const results_ptr: [*]const SearchResult = menu.model.results.ptr;
    const results_changed = !menu.prefetch_initialized or results_ptr != menu.prefetch_results_ptr;
    const scroll_changed = menu.prefetch_initialized and scroll_offset != menu.prefetch_scroll_offset;
    const stale = results_changed or scroll_changed;

    defer {
        menu.prefetch_results_ptr = results_ptr;
        menu.prefetch_scroll_offset = scroll_offset;
        menu.prefetch_initialized = true;
    }
    if (!stale) return;
    menu.server.iconCancelSpeculative();

    const first = first_visible orelse return; // nothing on screen (empty results) to prefetch around
    const visible_count = last_visible - first + 1;
    const size_px = geometry.devicePixels(38, menu.wlr_output.scale);
    // A fresh query/category has no established scroll direction of its
    // own yet: prefetch forward from what's visible, matching "initial
    // menu results" in the plan.
    const forward = results_changed or scroll_offset >= menu.prefetch_scroll_offset;

    if (forward) {
        var idx = last_visible + 1;
        var n: usize = 0;
        while (n < visible_count and idx < menu.model.results.len) : ({
            idx += 1;
            n += 1;
        }) {
            if (menu.model.results[idx].icon) |name| menu.server.iconPrefetch(name, size_px);
        }
    } else {
        var idx = first;
        var n: usize = 0;
        while (n < visible_count and idx > 0) : (n += 1) {
            idx -= 1;
            if (menu.model.results[idx].icon) |name| menu.server.iconPrefetch(name, size_px);
        }
    }
}

pub fn paintContent(menu: *StartMenu) void {
    if (menu.panel_box.width <= 0 or menu.panel_box.height <= 0) return;
    const scale = menu.wlr_output.scale;
    const buf = PanelBuffer.createRetained(menu.panel_box.width, menu.panel_box.height, scale, &menu.background) catch |err| {
        log.err("StartMenu.paintContent: could not create buffer: {}", .{err});
        return;
    };

    const t0 = panel_present.nowNs();
    _ = menu.loadVisibleIcons();
    var renderer = ui.paint.Renderer.init(buf.pixels, buf.width, buf.height, scale);
    renderer.palette = menuPalette();
    ui.input.active_dispatcher = &menu.dispatcher;
    menu.background.paintIncremental(gpa, &menu.root, &renderer, &buf.stamp);
    ui.input.active_dispatcher = null;
    const elapsed_ns = panel_present.nowNs() -| t0;

    buf.publish(menu.buffer_node, scale, menu.background.damage);
    menu.buffer_node.setDestSize(menu.panel_box.width, menu.panel_box.height);
    buf.base.drop();
    panel_present.addPaint(elapsed_ns);
    menu.dirty = false;
}

pub fn applyPresentation(menu: *StartMenu, now_ms: i64) void {
    if (menu.panel_box.width <= 0 or menu.panel_box.height <= 0) return;
    const t = menu.slide.value(now_ms);
    panel_present.applySlide(menu.buffer_node, menu.panel_box, t, if (menu.server.config.compositor.taskbar_position == .top) -slide_distance else slide_distance);
    // Keep the rounded blur inside a straight corner cut, as on the dock.
    const radius = @max(theme.global.start_menu_radius, theme.global.start_menu_bevel * 1.71);
    glass.Effect.configure(menu.glass_effect, radius, t);
    if (menu.state == .opening and (menu.slide.settled(now_ms) or panel_present.slideOffset(t, slide_distance) == 0)) menu.state = .open;
}
