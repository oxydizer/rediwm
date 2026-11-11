//! Toplevel size clip and the open and close animations.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const xscale = @import("../xwayland_scale.zig");
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const chrome = @import("../chrome.zig");
const anim = @import("ui").anim;
const LaunchOrigin = Toplevel.LaunchOrigin;
const CloseSnapshot = Toplevel.CloseSnapshot;
const ignoreCloseInput = Toplevel.ignoreCloseInput;
const nowMs = Toplevel.nowMs;

/// Idempotent: re-applying the clip a window already has is a no-op, so the
/// per-commit call from `syncChrome` costs nothing once the size settles.
pub fn setSizeClip(toplevel: *Toplevel, clip: ?wlr.Box) void {
    if (toplevel.backend == .placeholder or toplevel.backend == .shell) return;
    if (toplevel.last_clip_valid) {
        const same = if (clip) |box|
            if (toplevel.last_clip) |prev| std.meta.eql(prev, box) else false
        else
            toplevel.last_clip == null;
        if (same) return;
    }
    toplevel.last_clip = clip;
    toplevel.last_clip_valid = true;
    if (clip) |box| {
        var copy = box;
        toplevel.scene_tree.subsurfaceTreeSetClip(&copy);
    } else {
        toplevel.scene_tree.subsurfaceTreeSetClip(null);
    }
}

pub fn applySizeClip(toplevel: *Toplevel) void {
    if (toplevel.backend_gone or toplevel.closing) return;
    if (toplevel.backend == .placeholder or toplevel.backend == .shell) return;
    // An Xwayland surface can fire property changes (e.g. WM_CLASS, routed
    // here through handleIdentityChanged -> syncChrome) before its X11
    // window is associated with a wl_surface and attachXwaylandScene has run.
    // scene_tree is then still the bare placeholder tree from createXwayland,
    // with no subsurface tree to clip.
    if (!toplevel.isInitialized()) return;
    if (toplevel.size_w.settle_ms == 0 and toplevel.size_h.settle_ms == 0) {
        toplevel.setSizeClip(null);
        return;
    }
    const decorated = toplevel.hasServerDecorations();
    const cw = if (decorated) @max(toplevel.chrome_width - 2 * chrome.frameBorder(), 0) else toplevel.chrome_width;
    const ch = if (decorated)
        @max(toplevel.chrome_height - toplevel.titlebarHeight() - chrome.frameBorder(), 0)
    else
        toplevel.chrome_height;
    const n = toplevel.surfaceScale();
    toplevel.setSizeClip(.{ .x = 0, .y = 0, .width = xscale.surfaceLength(cw, n), .height = xscale.surfaceLength(ch, n) });
}

pub fn beginOpenAnimation(toplevel: *Toplevel, launch_origin: ?LaunchOrigin) void {
    const now_ms = nowMs();
    toplevel.launch_origin = null;
    if (launch_origin) |origin| if (!toplevel.isFullscreen() and anim.enabled() and !anim.reducedMotion()) {
        toplevel.launch_origin = origin;
        toplevel.map_motion.cancel(0);
        toplevel.map_opacity.cancel(0);
        toplevel.map_motion.retargetTo(now_ms, 1, anim.curveFor(.window_launch));
        // Opaque early: the growing window, not a fade, is the effect.
        toplevel.map_opacity.retargetTo(now_ms, 1, anim.Curve{ .duration = .{ .ms = 120, .ease = .out_cubic } });
        if (toplevel.map_motion.settled(now_ms)) {
            toplevel.map_motion.cancel(1);
            toplevel.launch_origin = null;
        }
        toplevel.applyVisualTransform(now_ms);
        toplevel.applyOpacity(now_ms);
        toplevel.server.scheduleFrames();
        return;
    };
    if (toplevel.isMaximized() or toplevel.isFullscreen()) {
        toplevel.map_motion.cancel(1);
        toplevel.map_opacity.cancel(1);
        toplevel.applyVisualTransform(now_ms);
        toplevel.applyOpacity(now_ms);
        return;
    }
    toplevel.map_motion.cancel(0);
    toplevel.map_opacity.cancel(0);
    toplevel.map_motion.retargetTo(now_ms, 1, anim.curveFor(.window_open));
    toplevel.map_opacity.retargetTo(now_ms, 1, anim.curveFor(.window_open));
    toplevel.applyVisualTransform(now_ms);
    toplevel.applyOpacity(now_ms);
    if (!toplevel.map_motion.settled(now_ms) or !toplevel.map_opacity.settled(now_ms)) {
        toplevel.server.scheduleFrames();
    }
}

pub fn beginCloseAnimation(toplevel: *Toplevel) bool {
    toplevel.launch_origin = null;
    if (!anim.enabled() or anim.speed() <= 0) return false;
    if (!snapshotClient(toplevel)) return false;
    const now_ms = nowMs();
    toplevel.map_motion.retargetTo(now_ms, 0, anim.curveFor(.window_close));
    toplevel.map_opacity.retargetTo(now_ms, 0, anim.curveFor(.window_close));
    if (toplevel.map_motion.settled(now_ms) and toplevel.map_opacity.settled(now_ms)) {
        if (toplevel.close_snapshot) |snap| {
            snap.node.destroy();
            toplevel.close_snapshot = null;
        }
        toplevel.scene_tree.setEnabled(true);
        return false;
    }
    toplevel.closing = true;
    toplevel.server.world.closing.append(toplevel);
    toplevel.in_closing_list = true;
    toplevel.applyVisualTransform(now_ms);
    toplevel.applyOpacity(now_ms);
    toplevel.server.scheduleFrames();
    return true;
}

pub fn copyCloseBuffer(buffer: *sn.Buffer, sx: c_int, sy: c_int, ctx: *CloseSnapshot) void {
    const src = buffer.getBuffer() orelse return;
    const dest = ctx.tree.createSceneBuffer(src) catch {
        ctx.ok = false;
        return;
    };
    dest.node.setPosition(sx, sy);
    dest.point_accepts_input = ignoreCloseInput;
    if (buffer.dst_width > 0 and buffer.dst_height > 0) {
        dest.setDestSize(buffer.dst_width, buffer.dst_height);
    }
    if (buffer.src_box.width > 0 and buffer.src_box.height > 0) {
        dest.setSourceBox(&buffer.src_box);
    }
    dest.setTransform(buffer.transform);
    dest.setOpacity(buffer.opacity);
    dest.setFilterMode(buffer.filter_mode);
    ctx.count += 1;
}

pub fn snapshotClient(toplevel: *Toplevel) bool {
    const snap = toplevel.content_tree.createSceneTree() catch return false;
    var ctx: CloseSnapshot = .{ .tree = snap };
    toplevel.scene_tree.forEachSurfaceBuffer(*CloseSnapshot, copyCloseBuffer, &ctx);
    if (!ctx.ok or ctx.count == 0) {
        snap.node.destroy();
        return false;
    }
    toplevel.scene_tree.setEnabled(false);
    toplevel.close_snapshot = snap;
    return true;
}

pub fn cancelClose(toplevel: *Toplevel) void {
    if (toplevel.close_snapshot) |snap| {
        snap.node.destroy();
        toplevel.close_snapshot = null;
    }
    if (toplevel.in_closing_list) {
        toplevel.closing_link.remove();
        toplevel.in_closing_list = false;
    }
    toplevel.closing = false;
    toplevel.map_motion.cancel(1);
    toplevel.map_opacity.cancel(1);
    toplevel.scene_tree.setEnabled(true);
}
