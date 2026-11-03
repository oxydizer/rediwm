//! Scene transport for ribbon.Geometry. The caller owns the returned node and
//! its parent/lifecycle. Put it in an unclipped subtree when it extends outside
//! a clipped host. The renderer's optional ribbon program must be enabled first.
const sn = @import("../node.zig");
const ribbon = @import("ribbon.zig");

extern fn rediwm_ribbon_create(parent: *sn.Tree) ?*sn.Buffer;
pub const create = rediwm_ribbon_create;
extern fn rediwm_ribbon_update(node: *sn.Buffer, mesh: *const ribbon.Mesh, x: c_int, y: c_int, width: c_int, height: c_int) void;

pub fn present(node: *sn.Buffer, geometry: *const ribbon.Geometry) void {
    rediwm_ribbon_update(node, &geometry.mesh, geometry.x, geometry.y, geometry.width, geometry.height);
}
