const wlr = @import("wlroots");
pub const Projection = opaque {
    extern fn rediwm_projection_create(source: *wlr.SceneTree, view: *wlr.SceneTree, scene: *wlr.Scene) ?*Projection;
    pub const create = rediwm_projection_create;
    extern fn rediwm_projection_watch(projection: *Projection, compositor: *wlr.Compositor) void;
    pub const watch = rediwm_projection_watch;
    extern fn rediwm_projection_destroy(projection: ?*Projection) void;
    pub const destroy = rediwm_projection_destroy;
    extern fn rediwm_projection_sync(projection: ?*Projection, zoom: f64, cx: f64, cy: f64, ox: f64, oy: f64) void;
    pub const sync = rediwm_projection_sync;
    extern fn rediwm_projection_sync_fixed(projection: ?*Projection, zoom: f64, cx: f64, cy: f64, ox: f64, oy: f64, fixed: ?*wlr.SceneTree) void;
    pub const syncFixed = rediwm_projection_sync_fixed;
    extern fn rediwm_projection_damage_buffer(projection: *Projection, source: *wlr.SceneNode, damage: ?*const @import("pixman").Region32) void;
    /// Buffer-local damage for the buffer just set on a compositor-owned
    /// source node; null damages all of it.
    pub const damageBuffer = rediwm_projection_damage_buffer;
    extern fn rediwm_projection_present_owned(projection: *Projection, source: *wlr.SceneBuffer, renderer: *wlr.Renderer, buffer: *wlr.Buffer, damage: ?*const @import("pixman").Region32) bool;
    /// Sets `buffer` on a compositor-owned source node, updating the texture
    /// in place with `damage` when the renderer allows; null replaces all.
    /// The caller may drop `buffer` afterwards. True when updated in place.
    pub const presentOwned = rediwm_projection_present_owned;
};
extern fn rediwm_projection_source(node: *wlr.SceneNode) *wlr.SceneNode;
pub const source = rediwm_projection_source;
extern fn rediwm_projection_set_tree_zoom(node: *wlr.SceneNode, scale: f64) bool;
pub const setTreeZoom = rediwm_projection_set_tree_zoom;
extern fn rediwm_projection_set_tree_scale(node: *wlr.SceneNode, factor: f64) bool;
pub const setTreeScale = rediwm_projection_set_tree_scale;
