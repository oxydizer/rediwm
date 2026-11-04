//! Neumorphic relief: the pair of soft shadows, one dark and one light, that
//! makes a rounded control look pressed out of (raised) or into (inset) the
//! surface it sits on. Pure geometry on the same signed-distance field as the
//! rest of the rasterizer, so `Renderer.fillRect` and any hand-rolled control
//! shade identically. Everything is in device pixels; `Spec.from` is where the
//! theme's logical values are scaled.
//!
//! The light sits `light_x, light_y` away from the shape (y down). A raised
//! shape casts its dark shadow away from the light and its light one toward
//! it. An inset shape is the same pair seen from inside: the edge facing the
//! light is in shadow and the opposite edge catches the light.
const std = @import("std");
const sdf = @import("sdf.zig");
const theme = @import("theme.zig");

/// The look of one theme, resolved to device pixels.
pub const Spec = struct {
    /// How far each shadow is shifted from the shape. 0 turns relief off.
    depth: f32,
    /// How far a shadow takes to fade out past its own edge (at least 1).
    softness: f32,
    /// Unit vector from the shape toward the light, y down.
    light_x: f32,
    light_y: f32,
    /// Straight RGBA; the alpha is the strength at the shadow's edge.
    dark: [4]f32,
    light: [4]f32,

    pub fn from(t: theme.Theme, scale: f32) Spec {
        // The angle reads like a protractor (counter-clockwise from +x, y up):
        // 135 is the upper left, the usual neumorphic light.
        const radians = t.relief_light_angle * (std.math.pi / 180.0);
        const soft = if (t.relief_softness > 0) t.relief_softness else t.relief_depth * 1.5;
        return .{
            .depth = @max(t.relief_depth, 0) * scale,
            .softness = @max(soft * scale, 1),
            .light_x = @cos(radians),
            .light_y = -@sin(radians),
            .dark = t.relief_dark,
            .light = t.relief_light,
        };
    }

    pub fn enabled(spec: Spec) bool {
        return spec.depth > 0 and (spec.dark[3] > 0 or spec.light[3] > 0);
    }

    /// How far outside its box a raised shape's shadows can reach. Damage for a
    /// control whose relief changes must cover this much more than its box.
    pub fn reach(spec: Spec) f32 {
        return spec.depth + spec.softness;
    }
};

/// A rounded box in device pixels.
pub const Shape = struct { x: f32, y: f32, w: f32, h: f32, radius: f32 };

/// Strength of the two shadows at one pixel, 0 to 1 each.
pub const Pair = struct { dark: f32, light: f32 };

const none: Pair = .{ .dark = 0, .light = 0 };

/// Signed distance from (`px`, `py`) to `shape` moved by (`dx`, `dy`).
inline fn shifted(shape: Shape, px: f32, py: f32, dx: f32, dy: f32) f32 {
    return sdf.sdRoundedBox(px - dx, py - dy, shape.x, shape.y, shape.w, shape.h, shape.radius);
}

/// Full strength on and inside an edge, none `softness` outside it, a
/// smoothstep between: the ramp of the compositor's window shadow, so a
/// control and a window frame fall off the same way.
pub inline fn falloff(distance: f32, softness: f32) f32 {
    const s = std.math.clamp(1 - distance / softness, 0, 1);
    return s * s * (3 - 2 * s);
}

/// The shadows a raised `shape` casts on the surface around it. They are kept
/// out of the shape itself, so a translucent fill does not show them.
pub fn raised(spec: Spec, shape: Shape, px: f32, py: f32) Pair {
    const d = shifted(shape, px, py, 0, 0);
    if (d >= spec.reach()) return none;
    const outside = 1 - sdf.coverage(d);
    if (outside <= 0) return none;
    const ox = spec.light_x * spec.depth;
    const oy = spec.light_y * spec.depth;
    return .{
        .dark = falloff(shifted(shape, px, py, -ox, -oy), spec.softness) * outside,
        .light = falloff(shifted(shape, px, py, ox, oy), spec.softness) * outside,
    };
}

/// The shadows inside an inset `shape`: what the shape, moved by the offset,
/// no longer covers, softened inward.
pub fn inset(spec: Spec, shape: Shape, px: f32, py: f32) Pair {
    const d = shifted(shape, px, py, 0, 0);
    if (d < -spec.reach()) return none;
    const inside = sdf.coverage(d);
    if (inside <= 0) return none;
    const ox = spec.light_x * spec.depth;
    const oy = spec.light_y * spec.depth;
    return .{
        .dark = falloff(-shifted(shape, px, py, -ox, -oy), spec.softness) * inside,
        .light = falloff(-shifted(shape, px, py, ox, oy), spec.softness) * inside,
    };
}
