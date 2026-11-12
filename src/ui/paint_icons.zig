//! UI icon rasterization: signed-distance shapes for the built-in icon set.

const std = @import("std");
const layout = @import("layout.zig");
const IconId = layout.IconId;
const sdf = @import("paint.zig").sdf;

pub fn iconDistance(id: IconId, px: f32, py: f32, cx: f32, cy: f32, half: f32, thickness: f32) f32 {
    const t = thickness / 2;
    return switch (id) {
        .more => @min(sdCircle(px, py, cx, cy - half, t), @min(sdCircle(px, py, cx, cy, t), sdCircle(px, py, cx, cy + half, t))),
        .checkmark => @min(
            sdSegment(px, py, cx - half, cy + half * 0.1, cx - half * 0.25, cy + half * 0.6, t),
            sdSegment(px, py, cx - half * 0.25, cy + half * 0.6, cx + half, cy - half * 0.6, t),
        ),
        .close => @min(
            sdSegment(px, py, cx - half, cy - half, cx + half, cy + half, t),
            sdSegment(px, py, cx - half, cy + half, cx + half, cy - half, t),
        ),
        .chevron_down => @min(
            sdSegment(px, py, cx - half, cy - half * 0.3, cx, cy + half * 0.5, t),
            sdSegment(px, py, cx, cy + half * 0.5, cx + half, cy - half * 0.3, t),
        ),
        .chevron_left => @min(
            sdSegment(px, py, cx + half * 0.3, cy - half, cx - half * 0.5, cy, t),
            sdSegment(px, py, cx - half * 0.5, cy, cx + half * 0.3, cy + half, t),
        ),
        .region => blk: {
            // Corner brackets a third of the side long.
            const arm = half * 0.66;
            var d: f32 = std.math.floatMax(f32);
            for ([_]f32{ -1, 1 }) |sx| for ([_]f32{ -1, 1 }) |sy| {
                const x0 = cx + sx * half;
                const y0 = cy + sy * half;
                d = @min(d, sdSegment(px, py, x0, y0, x0 - sx * arm, y0, t));
                d = @min(d, sdSegment(px, py, x0, y0, x0, y0 - sy * arm, t));
            };
            break :blk d;
        },
        .chevron_right => @min(
            sdSegment(px, py, cx - half * 0.3, cy - half, cx + half * 0.5, cy, t),
            sdSegment(px, py, cx + half * 0.5, cy, cx - half * 0.3, cy + half, t),
        ),
        .chevron_up => @min(
            sdSegment(px, py, cx - half, cy + half * 0.3, cx, cy - half * 0.5, t),
            sdSegment(px, py, cx, cy - half * 0.5, cx + half, cy + half * 0.3, t),
        ),
        .play => sdf.sdQuad(px, py, cx - half * 0.65, cy - half, cx + half, cy, cx - half * 0.65, cy + half, cx - half * 0.65, cy),
        // `.play` rotated a quarter turn: same degenerate quad, tip at the top.
        .caret_up => sdf.sdQuad(px, py, cx - half, cy + half * 0.65, cx, cy - half, cx + half, cy + half * 0.65, cx, cy + half * 0.65),
        .skip_next => @min(
            sdf.sdQuad(px, py, cx - half * 0.9, cy - half * 0.9, cx + half * 0.45, cy, cx - half * 0.9, cy + half * 0.9, cx - half * 0.9, cy),
            sdBox(px, py, cx + half * 0.72, cy, half * 0.18, half * 0.9),
        ),
        .skip_previous => @min(
            sdf.sdQuad(px, py, cx + half * 0.9, cy - half * 0.9, cx - half * 0.45, cy, cx + half * 0.9, cy + half * 0.9, cx + half * 0.9, cy),
            sdBox(px, py, cx - half * 0.72, cy, half * 0.18, half * 0.9),
        ),
        .stop => sdRoundedBoxCentered(px, py, cx, cy, half * 0.75, half * 0.75, half * 0.15),
        .pause => @min(sdBox(px, py, cx - half * 0.45, cy, half * 0.22, half), sdBox(px, py, cx + half * 0.45, cy, half * 0.22, half)),
        .minimize => sdSegment(px, py, cx - half, cy, cx + half, cy, t),
        .drag_handle => @min(
            sdSegment(px, py, cx - half, cy - half * 0.7, cx + half, cy - half * 0.7, t),
            @min(
                sdSegment(px, py, cx - half, cy, cx + half, cy, t),
                sdSegment(px, py, cx - half, cy + half * 0.7, cx + half, cy + half * 0.7, t),
            ),
        ),
        .plus => @min(
            sdSegment(px, py, cx - half, cy, cx + half, cy, t),
            sdSegment(px, py, cx, cy - half, cx, cy + half, t),
        ),
        .maximize => @max(sdBox(px, py, cx, cy, half, half), -sdBox(px, py, cx, cy, half - thickness, half - thickness)),
        // Speaker housing + cone + waves. Same silhouette as Taskbar.zig's
        // `volumeGlyphSd` (an independent SDF glyph set — this engine has
        // no shared primitives with the taskbar's own raster loop) but
        // through this function's px/py/cx/cy/half/thickness
        // parameterization rather than tile-local gx/gy.
        .volume_muted => blk: {
            const body = sdf.sdQuad(
                px,
                py,
                cx - half,
                cy - half * 0.4,
                cx + half * 0.3,
                cy - half * 0.95,
                cx + half * 0.3,
                cy + half * 0.95,
                cx - half,
                cy + half * 0.4,
            );
            const strike = sdSegment(px, py, cx - half, cy - half, cx + half, cy + half, t);
            break :blk @min(body, strike);
        },
        .volume_low => blk: {
            const body = sdf.sdQuad(
                px,
                py,
                cx - half,
                cy - half * 0.4,
                cx + half * 0.3,
                cy - half * 0.95,
                cx + half * 0.3,
                cy + half * 0.95,
                cx - half,
                cy + half * 0.4,
            );
            const far: f32 = 999;
            const mouth = cx + half * 0.32;
            const wave = if (px < mouth) far else @abs(sdCircle(px, py, cx + half * 0.14, cy, half * 0.54)) - t;
            break :blk @min(body, wave);
        },
        .volume => blk: {
            const body = sdf.sdQuad(
                px,
                py,
                cx - half,
                cy - half * 0.4,
                cx + half * 0.3,
                cy - half * 0.95,
                cx + half * 0.3,
                cy + half * 0.95,
                cx - half,
                cy + half * 0.4,
            );
            const far: f32 = 999;
            const mouth = cx + half * 0.32;
            const w1 = if (px < mouth) far else @abs(sdCircle(px, py, cx + half * 0.14, cy, half * 0.54)) - t;
            const w2 = if (px < mouth) far else @abs(sdCircle(px, py, cx + half * 0.14, cy, half * 0.88)) - t;
            break :blk @min(body, @min(w1, w2));
        },
        // Shared outline microphone and mute slash for Settings and the OSD.
        .mic_muted => @min(iconDistance(.mic_outline, px, py, cx, cy, half, thickness), sdSegment(px, py, cx - half, cy - half, cx + half, cy + half, t)),
        .mic_outline => blk: {
            const capsule = @abs(sdf.sdRoundedBox(px, py, cx - half * 0.3, cy - half * 0.9, half * 0.6, half * 1.2, half * 0.3)) - t;
            const ring = @abs(sdCircle(px, py, cx, cy + half * 0.05, half * 0.58)) - t;
            const arc = @max(ring, cy - half * 0.05 - py);
            const stand = sdSegment(px, py, cx, cy + half * 0.62, cx, cy + half, t);
            const base = sdSegment(px, py, cx - half * 0.35, cy + half, cx + half * 0.35, cy + half, t);
            break :blk @min(capsule, @min(arc, @min(stand, base)));
        },
        .caps_lock => blk: {
            const arrow = @min(sdSegment(px, py, cx - half * 0.7, cy, cx, cy - half * 0.7, t * 0.6), sdSegment(px, py, cx, cy - half * 0.7, cx + half * 0.7, cy, t * 0.6));
            const stem = sdSegment(px, py, cx, cy - half * 0.5, cx, cy + half * 0.35, t * 0.6);
            const base = sdSegment(px, py, cx - half * 0.55, cy + half * 0.75, cx + half * 0.55, cy + half * 0.75, t * 0.6);
            break :blk @min(arrow, @min(stem, base));
        },
        .brightness => blk: {
            var d = @abs(sdCircle(px, py, cx, cy, half * 0.4)) - t * 0.5;
            for (0..8) |i| {
                const angle = @as(f32, @floatFromInt(i)) * std.math.pi / 4;
                const dx = @cos(angle);
                const dy = @sin(angle);
                d = @min(d, sdSegment(px, py, cx + dx * half * 0.7, cy + dy * half * 0.7, cx + dx * half, cy + dy * half, t * 0.5));
            }
            break :blk d;
        },
        .mic => blk: {
            const capsule = sdf.sdRoundedBox(px, py, cx - half * 0.3, cy - half * 0.9, half * 0.6, half * 1.1, half * 0.3);
            const stand = sdSegment(px, py, cx, cy + half * 0.3, cx, cy + half * 0.9, t);
            const base = sdSegment(px, py, cx - half * 0.4, cy + half * 0.9, cx + half * 0.4, cy + half * 0.9, t);
            break :blk @min(capsule, @min(stand, base));
        },
        .grid => blk: {
            const step = half * 0.45;
            const dot_r = thickness * 0.85;
            const d1 = sdCircle(px, py, cx - step, cy - step, dot_r);
            const d2 = sdCircle(px, py, cx + step, cy - step, dot_r);
            const d3 = sdCircle(px, py, cx - step, cy + step, dot_r);
            const d4 = sdCircle(px, py, cx + step, cy + step, dot_r);
            break :blk @min(@min(d1, d2), @min(d3, d4));
        },
        .search => @min(
            @abs(sdCircle(px, py, cx - half * 0.2, cy - half * 0.2, half * 0.65)) - t,
            sdSegment(px, py, cx + half * 0.28, cy + half * 0.28, cx + half, cy + half, t),
        ),
        // Power-menu glyphs (start menu footer button + power_menu.zig's
        // action tiles). Each is built by carving a notch out of a ring or
        // box with `@max(shape, -cutter)` — the same boolean-subtract trick
        // used below for `.maximize` — since this glyph set has no analytic
        // arc primitive.
        .power => blk: {
            const ring = @abs(sdCircle(px, py, cx, cy + half * 0.08, half * 0.62)) - t;
            const gap = sdBox(px, py, cx, cy - half * 0.5, half * 0.24, half * 0.3);
            const bar = sdSegment(px, py, cx, cy - half * 0.95, cx, cy - half * 0.05, t);
            break :blk @min(@max(ring, -gap), bar);
        },
        .clock, .divide, .cpu, .ram => 1000, // Embedded SVG; no procedural fallback.
        .power_saver, .power_balanced, .power_performance => blk: {
            // Upper three quarters of a ring, open at the bottom, with a
            // needle from the hub.
            const hub_y = cy + half * 0.2;
            const radius = half * 1.15;
            const ring = @abs(sdCircle(px, py, cx, hub_y, radius)) - t;
            const dial = @max(ring, -sdBox(px, py, cx, hub_y + radius, radius * 0.72, radius));
            const angle: f32 = switch (id) {
                .power_saver => -0.75 * std.math.pi,
                .power_balanced => -0.5 * std.math.pi,
                else => -0.25 * std.math.pi,
            };
            const needle = sdSegment(px, py, cx, hub_y, cx + @cos(angle) * radius * 0.62, hub_y + @sin(angle) * radius * 0.62, t);
            break :blk @min(dial, @min(needle, sdCircle(px, py, cx, hub_y, t * 1.6)));
        },
        .@"suspend" => blk: {
            const r = half * 0.65;
            const outer = sdCircle(px, py, cx - r * 0.1, cy, r);
            const cutout = sdCircle(px, py, cx + r * 0.35, cy - r * 0.25, r * 0.85);
            break :blk @max(outer, -cutout);
        },
        .lock => blk: {
            const shackle_cy = cy - half * 0.26;
            const shackle = @abs(sdCircle(px, py, cx, shackle_cy, half * 0.38)) - t;
            const shackle_cut = sdBox(px, py, cx, shackle_cy + half * 0.55, half * 0.55, half * 0.45);
            const shackle_open = @max(shackle, -shackle_cut);
            const body = sdRoundedBoxCentered(px, py, cx, cy + half * 0.34, half * 1.05, half * 0.72, half * 0.16);
            const keyhole = sdCircle(px, py, cx, cy + half * 0.32, t * 0.9);
            break :blk @min(shackle_open, @max(body, -keyhole));
        },
        .logout => blk: {
            const frame_cx = cx - half * 0.32;
            const frame = @abs(sdRoundedBoxCentered(px, py, frame_cx, cy, half * 0.4, half * 0.6, half * 0.12)) - t;
            const gap = sdBox(px, py, frame_cx + half * 0.4, cy, half * 0.22, half * 0.34);
            const frame_open = @max(frame, -gap);
            const shaft = sdSegment(px, py, cx - half * 0.28, cy, cx + half * 0.5, cy, t);
            // A filled triangle reads as a crisp arrowhead at this stroke
            // weight; two thin segments (tried first) blurred into a blob.
            const arrow = sdf.sdQuad(
                px,
                py,
                cx + half * 0.95,
                cy,
                cx + half * 0.42,
                cy - half * 0.38,
                cx + half * 0.42,
                cy + half * 0.38,
                cx + half * 0.42,
                cy + half * 0.38,
            );
            break :blk @min(frame_open, @min(shaft, arrow));
        },
        // Restart glyph: an open ring read as a clockwise arrow — a small
        // notch (same proportions as `.power`'s gap; a bigger cutter reads
        // as "chunk missing" rather than "open ring") plugged by a filled
        // triangle tangent to the circle. Restarting the compositor itself
        // (see power_menu.zig) reuses the same ring with a small center dot
        // standing in for "the shell/window", rather than a second pictogram.
        .reboot, .restart_shell => blk: {
            const ring = @abs(sdCircle(px, py, cx, cy, half * 0.6)) - t;
            const diag: f32 = 0.7071;
            // Unit radial direction (center -> notch, at the upper-right)
            // and its perpendicular (tangent to the ring there).
            const radial_x = diag;
            const radial_y = -diag;
            const tangent_x = diag;
            const tangent_y = diag;
            const gap_cx = cx + half * 0.6 * radial_x;
            const gap_cy = cy + half * 0.6 * radial_y;
            const gap = sdBoxRot(px, py, gap_cx, gap_cy, half * 0.16, half * 0.16, diag, diag);
            const ring_open = @max(ring, -gap);
            // Triangle base spans the ring's radial thickness at the notch;
            // the tip points tangentially, so the open ring reads as one
            // continuous curved arrow rather than a ring plus a separate spike.
            const arrow_len = half * 0.5;
            const arrow_w = half * 0.3;
            const arrow = sdf.sdQuad(
                px,
                py,
                gap_cx + tangent_x * arrow_len,
                gap_cy + tangent_y * arrow_len,
                gap_cx + radial_x * arrow_w,
                gap_cy + radial_y * arrow_w,
                gap_cx - radial_x * arrow_w,
                gap_cy - radial_y * arrow_w,
                gap_cx - radial_x * arrow_w,
                gap_cy - radial_y * arrow_w,
            );
            const base = @min(ring_open, arrow);
            break :blk if (id == .restart_shell) @min(base, sdCircle(px, py, cx, cy, half * 0.24)) else base;
        },
        .git_branch, .home, .generic, .folder, .document, .terminal, .settings, .keyboard, .edit, .browser, .wifi, .ethernet, .globe, .mouse, .touchpad, .trackball, .display, .music, .headphones, .bluetooth, .battery, .notification, .eye, .eye_off, .refresh, .cut, .copy, .paste, .trash, .trash_can, .view_grid, .view_list, .sort, .filter, .zoom_in, .zoom_out, .rotate, .crop, .undo, .save, .fit, .print, .open, .usb_stick, .drive, .eject, .users, .squares => sdCircle(px, py, cx, cy, half * 0.6),
    };
}

pub fn sdSegment(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32, half_thickness: f32) f32 {
    const pax = px - ax;
    const pay = py - ay;
    const bax = bx - ax;
    const bay = by - ay;
    const denom = bax * bax + bay * bay;
    const h = if (denom > 0) std.math.clamp((pax * bax + pay * bay) / denom, 0, 1) else 0;
    const dx = pax - bax * h;
    const dy = pay - bay * h;
    return @sqrt(dx * dx + dy * dy) - half_thickness;
}

pub fn sdCircle(px: f32, py: f32, cx: f32, cy: f32, radius: f32) f32 {
    const dx = px - cx;
    const dy = py - cy;
    return @sqrt(dx * dx + dy * dy) - radius;
}

pub fn sdBox(px: f32, py: f32, cx: f32, cy: f32, half_w: f32, half_h: f32) f32 {
    const qx = @abs(px - cx) - half_w;
    const qy = @abs(py - cy) - half_h;
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @min(@max(qx, qy), 0) + @sqrt(ox * ox + oy * oy);
}

// `sdf.sdRoundedBox` takes a top-left corner; the icon glyphs above all
// work in center + half-extent terms like `sdBox`, so this just re-centers.
pub fn sdRoundedBoxCentered(px: f32, py: f32, cx: f32, cy: f32, half_w: f32, half_h: f32, radius: f32) f32 {
    return sdf.sdRoundedBox(px, py, cx - half_w, cy - half_h, half_w * 2, half_h * 2, radius);
}

// `sdBox` rotated about its own center — used to carve an angled notch out
// of a ring (the `.reboot`/`.restart_shell` glyphs' gap), which an
// axis-aligned cutter can't reach.
pub fn sdBoxRot(px: f32, py: f32, cx: f32, cy: f32, half_w: f32, half_h: f32, cos_a: f32, sin_a: f32) f32 {
    const dx = px - cx;
    const dy = py - cy;
    const rx = cos_a * dx + sin_a * dy;
    const ry = -sin_a * dx + cos_a * dy;
    const qx = @abs(rx) - half_w;
    const qy = @abs(ry) - half_h;
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @min(@max(qx, qy), 0) + @sqrt(ox * ox + oy * oy);
}
