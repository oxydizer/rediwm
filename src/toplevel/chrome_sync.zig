//! Toplevel chrome sync: titlebar, shadow, resize grab, shape and borders.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const glass = @import("../glass.zig");
const sn = @import("../node.zig");
const col = @import("../color.zig");
const chrome = @import("../chrome.zig");
const geometry = @import("../geometry.zig");
const icon_service = @import("../icon_service.zig");
const resize = @import("../resize.zig");
const projection = @import("../projection.zig");
const theme = @import("ui").theme;
const stats = @import("../ipc/stats.zig");
const xdg = @import("../xdg.zig");
const border_glow = @import("ui").border_glow;
const gpa = @import("../main.zig").gpa;
const log = std.log.scoped(.toplevel);
const titlebar_stretch = Toplevel.titlebar_stretch;
const applySizeClip = Toplevel.applySizeClip;
const nowMs = Toplevel.nowMs;

/// Repaint theme-dependent chrome. `rebuild_shadow` is true here: a theme edit can change the shadow's
/// color/size, so already-open windows must pick it up immediately, same as
/// border/titlebar colors already do.
pub fn refreshTheme(toplevel: *Toplevel) void {
    defer @import("../auto_tiling.zig").observe(toplevel);
    const height_changed = if (toplevel.last_titlebar) |memo| memo.chrome_height != theme.global.chrome_height else false;
    switch (toplevel.backend) {
        .placeholder => |*ph| col.setRect(ph.body_rect, col.Straight.fromRgba(theme.global.window_bg).premultiply()),
        .shell => |*sw| if (sw.control_center) |cc| cc.requestRepaint(),
        else => {},
    }
    syncChrome(toplevel, true, nowMs()) catch |err| {
        log.warn("refreshTheme: could not rebuild chrome: {}", .{err});
    };
    // A changed titlebar height must keep tiled frames inside their tile.
    if (height_changed and toplevel.in_world) {
        if (toplevel.tile) |tile| {
            if (toplevel.currentOutput()) |out| toplevel.setTiledOn(out, tile);
        }
    }
}

/// Keeps `IconService`'s refcount in sync with whatever icon this titlebar
/// last displayed (`toplevel.last_titlebar.?.icon`), so a future eviction
/// pass can tell a live titlebar's icon apart from an unreferenced one.
/// No-op when the icon didn't change (the common case: most `syncChrome`
/// calls are unrelated commits/hover changes on an already-resolved icon).
pub fn updateHeldIcon(toplevel: *Toplevel, new_icon: ?icon_service.Entry) void {
    const old_id: ?u64 = if (toplevel.last_titlebar) |prev| (if (prev.icon) |e| e.id else null) else null;
    const new_id: ?u64 = if (new_icon) |e| e.id else null;
    if (old_id == new_id) return;
    if (old_id) |id| toplevel.server.iconRelease(id);
    if (new_id) |id| toplevel.server.iconAcquire(id);
}

/// Releases whatever icon handle this titlebar currently holds, if any.
/// Called before dropping `last_titlebar` outside of the normal
/// `updateHeldIcon` path (window destroyed, decorations turned off).
pub fn releaseIcon(toplevel: *Toplevel) void {
    if (toplevel.last_titlebar) |prev| {
        if (prev.icon) |e| toplevel.server.iconRelease(e.id);
    }
}

/// Density of the sharpest output touched by the displayed frame. Keep the
/// previous density while offscreen to avoid repainting invisible windows.
pub fn syncOutputScale(toplevel: *Toplevel) void {
    const origin = toplevel.server.world.toLayout(@floatFromInt(toplevel.x), @floatFromInt(toplevel.y));
    const width = @as(f64, @floatFromInt(toplevel.chrome_width)) * toplevel.zoom();
    const height = @as(f64, @floatFromInt(toplevel.chrome_height)) * toplevel.zoom();
    var scale: f32 = 0;
    var it = toplevel.server.outputs.iterator(.forward);
    while (it.next()) |out| {
        if (!out.isLogicallyEnabled()) continue;
        const b = out.cached_box;
        if (origin.x < @as(f64, @floatFromInt(b.x)) + @as(f64, @floatFromInt(b.width)) and
            origin.y < @as(f64, @floatFromInt(b.y)) + @as(f64, @floatFromInt(b.height)) and
            origin.x + width > @as(f64, @floatFromInt(b.x)) and
            origin.y + height > @as(f64, @floatFromInt(b.y)))
        {
            scale = @max(scale, out.wlr_output.scale);
        }
    }
    if (scale == 0 or scale == toplevel.render_scale) return;
    toplevel.render_scale = scale;
    toplevel.syncChrome(true, nowMs()) catch |err| {
        log.warn("output scale: could not rebuild chrome: {}", .{err});
    };
}

pub fn clearChromeCache(toplevel: *Toplevel) void {
    if (toplevel.cached_titlebar) |buffer| buffer.base.drop();
    toplevel.cached_titlebar = null;
}

/// `rebuild_shadow` is false on a pure hover repaint, which cannot change the
/// shadow; geometry and theme changes pass true.
/// Every change goes through node and projection setters, which ask for a
/// frame themselves: a client commit that changes nothing schedules none.
pub fn syncChrome(toplevel: *Toplevel, rebuild_shadow: bool, now_ms: i64) !void {
    defer if (toplevel.server.input.grabbed_toplevel == toplevel) toplevel.server.input.updateGrabBorderGlow();
    const geometry_box = toplevel.clientGeometry();
    if (geometry_box.width <= 0 or geometry_box.height <= 0) return;
    defer toplevel.syncSidebarGlass(geometry_box.width, geometry_box.height);

    const decorated = toplevel.hasServerDecorations();
    toplevel.titlebar_buffer.node.setEnabled(decorated);
    for (toplevel.frame_fills) |rect| rect.node.setEnabled(decorated);
    // A decorated window's border is the shape's ring; the rects only outline
    // windows that draw their own decorations.
    for (toplevel.border_rects) |rect| rect.node.setEnabled(!decorated and toplevel.hasWorkspaceFocusBorder());
    if (!decorated) {
        toplevel.releaseIcon();
        toplevel.clearChromeCache();
        toplevel.last_titlebar = null;
        toplevel.shadow_tree.node.setEnabled(false);
        toplevel.resize_grab.node.setEnabled(false);
        toplevel.content_tree.node.setPosition(0, 0);
        const animated = visualChromeSize(toplevel, now_ms, geometry_box.width, geometry_box.height);
        toplevel.chrome_width = animated.w;
        toplevel.chrome_height = animated.h;
        applySizeClip(toplevel);
        toplevel.hovered = false;
        toplevel.hovered_control = null;
        toplevel.hover_anim.cancel(0);
        toplevel.resetChip();
        toplevel.last_painted_hover = 0;
        toplevel.syncBorders(animated.w, animated.h);
        toplevel.applyShape();
        return;
    }

    const radius: f32 = toplevel.cornerRadius();
    const natural_w = geometry_box.width + 2 * chrome.frame_border;
    const natural_h = geometry_box.height + toplevel.titlebarHeight() + chrome.frame_border;
    const animated = visualChromeSize(toplevel, now_ms, natural_w, natural_h);
    const width = animated.w;
    const height = animated.h;
    const window_title = toplevel.title();
    const app_id = toplevel.appId();
    const icon_lookup = toplevel.server.iconLookup(app_id, geometry.devicePixels((chrome.Metrics{ .density = toplevel.chromeDensity() }).iconSize(), toplevel.render_scale));
    const icon: ?icon_service.Entry = switch (icon_lookup) {
        .ready => |e| e,
        .pending, .missing => null,
    };
    toplevel.updateHeldIcon(icon);
    const hover = toplevel.hover_anim.value(now_ms);
    const chip_alpha = toplevel.chip_alpha.value(now_ms);
    // Only a grouped window has tabs. Others skip the 4 KiB scratch, which
    // ReleaseSafe would fill on every client commit.
    const tab_storage = if (toplevel.tab_group != 0) try gpa.create([@import("../window_tabs.zig").max_tabs]@import("../chrome_tabs.zig").Tab) else null;
    defer if (tab_storage) |storage| gpa.destroy(storage);
    var state: chrome.ChromeState = .{
        .tabs = toplevel.tabStrip(tab_storage),
        .active = toplevel.activated,
        .workspace_focus = toplevel.hasWorkspaceFocusBorder(),
        .maximized = toplevel.isMaximized(),
        .density = toplevel.chromeDensity(),
        .title = window_title,
        .scale = toplevel.render_scale,
        .hover = hover,
        // An invisible chip has no position: keeps the raster memo stable.
        .chip_pos = if (chip_alpha > 0) toplevel.chip_pos.value(now_ms) else 0,
        .chip_alpha = chip_alpha,
        .icon = icon,
    };
    toplevel.last_painted_hover = hover;
    toplevel.chrome_width = width;
    toplevel.chrome_height = height;
    const insets = toplevel.controlInsets();
    state.inset_left = insets.left;
    state.inset_right = insets.right;

    const title_memo = chrome.TitlebarMemo.capture(width, height, toplevel.titlePtr(), state);
    const skip_titlebar = if (toplevel.last_titlebar) |prev| prev.eql(title_memo) or toplevel.stretchesTitlebar(prev, title_memo, now_ms) else false;
    if (!skip_titlebar) {
        const titlebar = if (toplevel.cached_titlebar != null and toplevel.last_titlebar != null and toplevel.last_titlebar.?.reusableFor(title_memo))
            try chrome.ChromeBuffer.createUpdated(toplevel.cached_titlebar.?, state, toplevel.last_titlebar.?.title_ptr != title_memo.title_ptr)
        else
            try chrome.ChromeBuffer.create(width, state);
        toplevel.titlebar_buffer.setBuffer(&titlebar.base);
        if (toplevel.cached_titlebar) |previous| previous.base.drop();
        toplevel.cached_titlebar = titlebar;
        stats.recordTitlebarPaint();
        toplevel.last_titlebar = title_memo;
    }

    toplevel.titlebar_buffer.setDestSize(width, toplevel.titlebarHeight());
    glass.Effect.configure(toplevel.glass_effect, radius, 1);

    toplevel.syncBorders(width, height);
    toplevel.applyShape();
    toplevel.syncResizeGrab(width, height);
    if (rebuild_shadow) try toplevel.syncShadow(width, height, radius);

    // wlr_scene_xdg_surface_create origin is the geometry top-left.
    toplevel.content_tree.node.setPosition(chrome.frame_border, toplevel.titlebarHeight());
    switch (toplevel.backend) {
        .placeholder => |*ph| ph.body_rect.setSize(geometry_box.width, geometry_box.height),
        else => {},
    }
    applySizeClip(toplevel);
}

pub fn syncSidebarGlass(toplevel: *Toplevel, width: i32, height: i32) void {
    const themed = switch (toplevel.backend) {
        .shell => |shell| !shell.welcome,
        .xdg => std.mem.eql(u8, toplevel.appId(), "rediwm-files") or
            std.mem.eql(u8, toplevel.appId(), "rediwm-file-chooser"),
        else => false,
    };
    const enabled = themed and theme.global.app_sidebar_blur and theme.global.app_sidebar[3] < 1;
    if (enabled and toplevel.sidebar_glass_target == null) {
        const target = toplevel.content_tree.createSceneBuffer(null) catch return;
        target.point_accepts_input = struct {
            fn accepts(_: *sn.Buffer, _: *f64, _: *f64) callconv(.c) bool {
                return false;
            }
        }.accepts;
        target.node.placeBelow(toplevel.scene_tree);
        const effect = glass.Engine.attach(toplevel.server.glass_engine, target, &target.node, .sidebar) orelse {
            target.node.destroy();
            return;
        };
        // Both nodes belong to content_tree and are freed with the window.
        toplevel.sidebar_glass_target = target;
        toplevel.sidebar_glass_effect = effect;
    }
    if (toplevel.sidebar_glass_target) |target| {
        target.node.setEnabled(enabled);
        if (enabled) {
            target.setDestSize(width, height);
            glass.Effect.configure(toplevel.sidebar_glass_effect, 0, toplevel.shape_opacity);
        }
    }
}

/// Whether a frame easing to a new size keeps its titlebar raster, stretched,
/// instead of rastering it for every frame (`ChromeBuffer.create` costs
/// milliseconds, and a reflow eases several frames at once): only the size
/// changed, the width by at most `titlebar_stretch`. The band does not depend
/// on the height, and the settled size always rasters exactly.
pub fn stretchesTitlebar(toplevel: *const Toplevel, raster: chrome.TitlebarMemo, next: chrome.TitlebarMemo, now_ms: i64) bool {
    if (toplevel.size_w.settle_ms == 0 and toplevel.size_h.settle_ms == 0) return false;
    if (toplevel.size_w.settled(now_ms) and toplevel.size_h.settled(now_ms)) return false;
    var resized = raster;
    resized.width = next.width;
    resized.height = next.height;
    if (!resized.eql(next)) return false;
    const ratio = @as(f32, @floatFromInt(next.width)) / @as(f32, @floatFromInt(@max(raster.width, 1)));
    return @abs(ratio - 1) <= titlebar_stretch;
}

pub fn visualChromeSize(toplevel: *Toplevel, now_ms: i64, natural_w: i32, natural_h: i32) struct { w: i32, h: i32 } {
    if (toplevel.size_w.settle_ms == 0 and toplevel.size_h.settle_ms == 0) {
        return .{ .w = natural_w, .h = natural_h };
    }
    const w: i32 = @intFromFloat(@round(toplevel.size_w.value(now_ms)));
    const h: i32 = @intFromFloat(@round(toplevel.size_h.value(now_ms)));
    if (toplevel.size_w.settled(now_ms) and toplevel.size_h.settled(now_ms) and
        ((w == natural_w and h == natural_h) or toplevel.size_wait == .none))
    {
        toplevel.size_w.cancel(@floatFromInt(natural_w));
        toplevel.size_h.cancel(@floatFromInt(natural_h));
        return .{ .w = natural_w, .h = natural_h };
    }
    return .{ .w = @max(w, 1), .h = @max(h, 1) };
}

// The output pass draws the shadow from the window's shape; the node, without a
// buffer, carries only its footprint, the window's opacity and input. Called
// where geometry or theme may have changed, never on a hover repaint.
pub fn syncShadow(toplevel: *Toplevel, width: i32, height: i32, radius: f32) !void {
    const t = theme.global;
    if (t.window_shape.len > 0) _ = chrome.polygonsReady();
    const disabled = !chrome.shapes or toplevel.isMaximized() or t.shadow[3] <= 0 or t.shadow_size <= 0;
    const memo = chrome.ShadowMemo.capture(width, height, radius, toplevel.render_scale, disabled, toplevel.shapeKey());

    if (disabled) {
        toplevel.shadow_tree.node.setEnabled(false);
        toplevel.last_shadow = memo;
        return;
    }

    toplevel.shadow_tree.node.setEnabled(true);
    // Every client commit lands here; an unchanged memo means nothing to redo.
    if (toplevel.last_shadow) |prev| {
        if (prev.eql(memo)) return;
    }

    const margin: i32 = @intFromFloat(@ceil(t.shadow_size));
    const offset_y: i32 = @intFromFloat(t.shadow_offset_y);
    toplevel.shadow_node.node.setPosition(-margin, -margin + offset_y);
    toplevel.shadow_node.setDestSize(width + 2 * margin, height + 2 * margin);
    const r: f64 = radius;
    var spec: projection.ShadowSpec = .{
        .width = width,
        .height = height,
        .radii = .{ r, r, r, r },
        .offset_x = 0,
        .offset_y = @floatFromInt(offset_y),
        .softness = t.shadow_size,
        .color = col.Straight.fromRgba(t.shadow).premultiply().rgba,
    };
    if (toplevel.shapePolygon(width, height)) |polygon| {
        spec.poly_count = @intCast(polygon.count);
        spec.poly = polygon.points;
        spec.radii = @splat(0);
    }
    if (!projection.setTreeShadow(&toplevel.shadow_tree.node, spec)) log.warn("could not set the window shadow ({d}x{d})", .{ width, height });
    toplevel.last_shadow = memo;
}

// Unchanged position and size are no-ops in wlroots, so this runs on every
// sync. Off while maximized, like the shadow: `startResize` refuses then.
pub fn syncResizeGrab(toplevel: *Toplevel, width: i32, height: i32) void {
    const reach: i32 = @intFromFloat(@ceil(resize.reach_outside));
    toplevel.resize_grab.node.setEnabled(!toplevel.isMaximized());
    toplevel.resize_grab.node.setPosition(-reach, -reach);
    toplevel.resize_grab.setDestSize(width + 2 * reach, height + 2 * reach);
}

/// The shape that clips the whole window, titlebar, client and subsurfaces, in
/// the output pass (see `chrome.shapes`). Windows that draw their own
/// decorations, and fullscreen ones, have none; a maximized one has a square one,
/// for its border. Nothing changes if the shape is the one already set.
pub fn applyShape(toplevel: *Toplevel) void {
    if (!chrome.shapes) return;
    const node = &toplevel.frame_tree.node;
    if (!toplevel.hasServerDecorations() or toplevel.chrome_width <= 0 or toplevel.chrome_height <= 0) {
        _ = projection.setTreeClip(node, null);
        return;
    }
    // The polygon programs are built the first time a theme asks for an outline.
    if (theme.global.window_shape.len > 0) _ = chrome.polygonsReady();
    const radius: f64 = toplevel.cornerRadius();
    const ring = toplevel.borderColor().scale(toplevel.shape_opacity);
    var spec: projection.ClipSpec = .{
        .width = toplevel.chrome_width,
        .height = toplevel.chrome_height,
        .radii = .{ radius, radius, radius, radius },
        .border = @floatFromInt(chrome.frame_border),
        .border_color = ring.rgba,
    };
    if (toplevel.shapePolygon(toplevel.chrome_width, toplevel.chrome_height)) |polygon| {
        spec.poly_count = @intCast(polygon.count);
        spec.poly = polygon.points;
        spec.radii = @splat(0);
    }
    const t = theme.global;
    const glow = toplevel.glow_anim.value(nowMs()) * toplevel.shape_opacity;
    if (t.border_glow_enabled and glow * t.border_glow[3] >= 0.004) {
        const density = toplevel.chromeDensity();
        spec.glow_x = toplevel.glow_x;
        spec.glow_y = toplevel.glow_y;
        spec.glow_radius = @max(0.5 * t.border_glow_length * density, 1);
        spec.glow_depth = @max(t.border_glow_depth * density, 0);
        spec.glow_color = col.Straight.fromRgba(t.border_glow).premultiply().scale(glow).rgba;
    }
    if (!projection.setTreeClip(node, spec)) {
        log.warn("could not set the window shape ({d}x{d})", .{ toplevel.chrome_width, toplevel.chrome_height });
    }
}

pub fn syncBorders(toplevel: *Toplevel, width: i32, height: i32) void {
    if (!toplevel.hasServerDecorations()) {
        // Outline CSD frames outside their content. Client geometry and input
        // coordinates stay unchanged, and the content remains above the stroke.
        const color = toplevel.borderColor();
        for (toplevel.border_rects) |rect| col.setRect(rect, color);
        const edge = chrome.frame_border;
        toplevel.border_rects[0].node.setPosition(-edge, -edge);
        toplevel.border_rects[0].setSize(width + 2 * edge, edge);
        toplevel.border_rects[1].node.setPosition(-edge, 0);
        toplevel.border_rects[1].setSize(edge, height);
        toplevel.border_rects[2].node.setPosition(width, 0);
        toplevel.border_rects[2].setSize(edge, height);
        toplevel.border_rects[3].node.setPosition(-edge, height);
        toplevel.border_rects[3].setSize(width + 2 * edge, edge);
        return;
    }
    // Only back the gap the titlebar leaves: overlapping it would apply the
    // translucent chrome twice at the joins. The ring over the fills, the
    // titlebar and the client's edge is the shape's.
    const body_top = toplevel.titlebarHeight();
    const edge = chrome.frame_border;
    const body_height = @max(0, height - body_top - edge);
    for (toplevel.frame_fills) |rect| col.setRect(rect, chrome.fillColor());
    toplevel.frame_fills[0].node.setPosition(0, body_top);
    toplevel.frame_fills[0].setSize(edge, body_height);
    toplevel.frame_fills[1].node.setPosition(width - edge, body_top);
    toplevel.frame_fills[1].setSize(edge, body_height);
    toplevel.frame_fills[2].node.setPosition(0, height - edge);
    toplevel.frame_fills[2].setSize(width, edge);
}
