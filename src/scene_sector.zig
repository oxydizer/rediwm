//! ABI shared with scene_sector.h and scene_pass.h. A zero outer radius disables
//! the analytic annular sector; active sectors have a unit axis and half-angle.
fn Sector(comptime Float: type) type {
    return extern struct {
        center: [2]Float = @splat(0),
        radii: [2]Float = @splat(0), // inner, outer
        axis: [2]Float = @splat(0),
        half_angle: [2]Float = @splat(0), // cos, sin
    };
}

pub const Spec = Sector(f64);
pub const Device = Sector(f32);
