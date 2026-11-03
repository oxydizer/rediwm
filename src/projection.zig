const std = @import("std");
const wlr = @import("wlroots");
const node = @import("node.zig");
pub const Projection = opaque {
    extern fn rediwm_projection_create(own: *node.Scene, world: *node.Tree, outputs: *@import("scene_outputs.zig").SceneOutputs) ?*Projection;
    /// `own` is the compositor's scene (its root's children are layers, bottom to
    /// top) and `world` the layer that follows the camera. The projection asks for a
    /// frame whenever the scene changes.
    pub const create = rediwm_projection_create;
    extern fn rediwm_projection_watch(projection: *Projection, compositor: *wlr.Compositor) void;
    pub const watch = rediwm_projection_watch;
    extern fn rediwm_projection_destroy(projection: ?*Projection) void;
    pub const destroy = rediwm_projection_destroy;
    extern fn rediwm_projection_sync(projection: ?*Projection, zoom: f64, cx: f64, cy: f64, ox: f64, oy: f64) void;
    pub const sync = rediwm_projection_sync;
    extern fn rediwm_projection_sync_fixed(projection: ?*Projection, zoom: f64, cx: f64, cy: f64, ox: f64, oy: f64, fixed: ?*node.Tree) void;
    pub const syncFixed = rediwm_projection_sync_fixed;
    extern fn rediwm_projection_damage_buffer(projection: *Projection, source: *node.Node, damage: ?*const @import("pixman").Region32) void;
    /// Buffer-local damage for the buffer just set on a compositor-owned
    /// buffer node; null damages all of it.
    pub fn damageBuffer(projection: *Projection, buffer: *node.Buffer, damage: ?*const @import("pixman").Region32) void {
        rediwm_projection_damage_buffer(projection, &buffer.node, damage);
    }
    extern fn rediwm_projection_present_owned(projection: *Projection, source: *node.Buffer, renderer: *wlr.Renderer, buffer: *wlr.Buffer, damage: ?*const @import("pixman").Region32) bool;
    /// Sets `buffer` on a compositor-owned buffer node, updating the texture
    /// in place with `damage` when the renderer allows; null replaces all.
    /// The caller may drop `buffer` afterwards. True when updated in place.
    pub fn presentOwned(projection: *Projection, target: *node.Buffer, renderer: *wlr.Renderer, buffer: *wlr.Buffer, damage: ?*const @import("pixman").Region32) bool {
        return rediwm_projection_present_owned(projection, target, renderer, buffer, damage);
    }
    pub const Hit = extern struct {
        /// The leaf that was hit: a client surface's node, or a shell node.
        own: *node.Node,
        x: f64,
        y: f64,
    };
    extern fn rediwm_projection_node_at(projection: *Projection, lx: f64, ly: f64, hit: *Hit) bool;
    extern fn rediwm_projection_node_at_in(projection: *Projection, subtree: *node.Node, lx: f64, ly: f64, hit: *Hit) bool;
    /// The topmost leaf of one top-level subtree of a layer at a point, whatever lies
    /// above it.
    pub fn nodeAtIn(projection: *Projection, subtree: *node.Node, lx: f64, ly: f64) ?Hit {
        var hit: Hit = undefined;
        return if (rediwm_projection_node_at_in(projection, subtree, lx, ly, &hit)) hit else null;
    }
    /// What is topmost at a layout point, and the point in its own coordinates.
    pub fn nodeAt(projection: *Projection, lx: f64, ly: f64) ?Hit {
        var hit: Hit = undefined;
        return if (rediwm_projection_node_at(projection, lx, ly, &hit)) hit else null;
    }
    extern fn rediwm_projection_send_frame_done(projection: *Projection, output: *@import("scene_outputs.zig").SceneOutput, now: *std.posix.timespec) void;
    /// Frame callbacks of the world's client surfaces for one output.
    pub const sendFrameDone = rediwm_projection_send_frame_done;
};
extern fn rediwm_projection_set_tree_zoom(target: *node.Node, scale: f64) bool;
pub const setTreeZoom = rediwm_projection_set_tree_zoom;
extern fn rediwm_projection_set_tree_scale(target: *node.Node, factor: f64) bool;
pub const setTreeScale = rediwm_projection_set_tree_scale;

/// One rounded-rectangle shape for every leaf under a tree (see scene_graph.h):
/// source units, anchored at the tree's origin. `border_color` is premultiplied,
/// with the window's opacity applied.
pub const poly_max = 16;

pub const ClipSpec = extern struct {
    width: c_int,
    height: c_int,
    /// 0 for the rounded rectangle; otherwise the first `poly_count` of `poly`
    /// are the shape, from the tree's origin, inside the box (`radii` is then
    /// unused). Three to `poly_max`, none the same as the next.
    poly_count: c_int = 0,
    reserved: c_int = 0,
    /// Top-left, top-right, bottom-right, bottom-left.
    radii: [4]f64,
    border: f64,
    border_color: [4]f32,
    /// A highlight on the edge near a point of the tree (see scene_graph.h);
    /// `glow_color` is premultiplied, opacity applied. No radius, no highlight.
    glow_x: f64 = 0,
    glow_y: f64 = 0,
    glow_radius: f64 = 0,
    glow_depth: f64 = 0,
    glow_color: [4]f32 = .{ 0, 0, 0, 0 },
    poly: [poly_max][2]f64 = @splat(.{ 0, 0 }),
    /// An analytic annular sector instead of a polygon or rounded rectangle.
    sector: @import("scene_sector.zig").Spec = .{},
    /// Positive: map texture width around the outer arc, with this full source
    /// height extending inward. Zero keeps ordinary rectangular sampling.
    sector_texture_height: f64 = 0,
};
extern fn rediwm_projection_set_tree_clip(target: *node.Node, spec: ?*const ClipSpec) bool;
/// A null spec removes the clip. False for a size that is not positive or a
/// radius, border or colour that is negative or not finite.
pub fn setTreeClip(target: *node.Node, spec: ?ClipSpec) bool {
    if (spec) |value| return rediwm_projection_set_tree_clip(target, &value);
    return rediwm_projection_set_tree_clip(target, null);
}
/// The analytic drop shadow of a window's shape (see scene_graph.h): every leaf
/// under the tree draws it in the owned pass. `width`, `height` and `radii` are
/// the shape it is kept out of, in source units at the tree's origin; `color` is
/// premultiplied.
pub const ShadowSpec = extern struct {
    width: c_int,
    height: c_int,
    poly_count: c_int = 0,
    reserved: c_int = 0,
    radii: [4]f64,
    offset_x: f64,
    offset_y: f64,
    softness: f64,
    color: [4]f32,
    poly: [poly_max][2]f64 = @splat(.{ 0, 0 }),
};
extern fn rediwm_projection_set_tree_shadow(target: *node.Node, spec: ?*const ShadowSpec) bool;
/// A null spec removes the shadow. False for a size that is not positive or a
/// radius or softness that is negative or not finite.
pub fn setTreeShadow(target: *node.Node, spec: ?ShadowSpec) bool {
    if (spec) |value| return rediwm_projection_set_tree_shadow(target, &value);
    return rediwm_projection_set_tree_shadow(target, null);
}
/// Every leaf under the tree loses this fraction of its brightness and of its
/// colour in the output pass (see `rediwm_projection_set_tree_dim`); both zero
/// removes it. False for a fraction outside 0 to 1.
extern fn rediwm_projection_set_tree_dim(target: *node.Node, brightness: f32, saturation: f32) bool;
pub const setTreeDim = rediwm_projection_set_tree_dim;
/// Ends the clip and the dim inherited from an ancestor for this subtree: an xdg
/// popup or a window's shadow hangs under the window's tree but is no part of its
/// frame.
extern fn rediwm_projection_set_tree_unclipped(target: *node.Node, unclipped: bool) bool;
pub const setTreeUnclipped = rediwm_projection_set_tree_unclipped;
/// Shows the subtree but lets the pick pass through it to what is below: a
/// window sliding off the workspace it has left.
extern fn rediwm_projection_set_tree_inert(target: *node.Node, inert: bool) bool;
pub const setTreeInert = rediwm_projection_set_tree_inert;
