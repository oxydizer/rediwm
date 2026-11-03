const wlr = @import("wlroots");
const SceneOutput = @import("scene_outputs.zig").SceneOutput;
const Projection = @import("projection.zig").Projection;

extern var rediwm_scene_output_reblurs: u64;
/// Glass blurs the output pass re-took (stage 5c), for the performance stats.
pub const reblurs: *u64 = &rediwm_scene_output_reblurs;

pub const Renderer = opaque {
    extern fn rediwm_output_renderer_set_ribbons(renderer: *Renderer, enabled: bool) bool;
    pub const setRibbons = rediwm_output_renderer_set_ribbons;
    extern fn rediwm_output_renderer_create(renderer: *wlr.Renderer) ?*Renderer;
    pub const create = rediwm_output_renderer_create;
    extern fn rediwm_output_renderer_enable_shapes(renderer: *Renderer) bool;
    pub const enableShapes = rediwm_output_renderer_enable_shapes;
    extern fn rediwm_output_renderer_enable_external(renderer: *Renderer) bool;
    pub const enableExternal = rediwm_output_renderer_enable_external;
    extern fn rediwm_output_renderer_enable_polygons(renderer: *Renderer) bool;
    pub const enablePolygons = rediwm_output_renderer_enable_polygons;
    extern fn rediwm_output_renderer_enable_backdrops(renderer: *Renderer) bool;
    pub const enableBackdrops = rediwm_output_renderer_enable_backdrops;
    extern fn rediwm_output_renderer_destroy(renderer: ?*Renderer) void;
    pub const destroy = rediwm_output_renderer_destroy;
    extern fn rediwm_scene_output_build_state(renderer: *Renderer, projection: *Projection, output: *SceneOutput, state: *wlr.Output.State) bool;
    pub const buildState = rediwm_scene_output_build_state;
    extern fn rediwm_output_begin_pass(renderer: *Renderer, buffer: *wlr.Buffer, options: ?*const wlr.Renderer.BufferPassOptions) ?*wlr.RenderPass;
    pub const beginPass = rediwm_output_begin_pass;
    extern fn rediwm_scene_output_set_veil(renderer: *Renderer, output: *SceneOutput, alpha: f32) bool;
    pub const setVeil = rediwm_scene_output_set_veil;
};
