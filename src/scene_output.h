#pragma once
#include <stdbool.h>
#include <wlr/util/box.h>
struct rediwm_node;
struct rediwm_buffer;
struct rediwm_read_fence;
struct wlr_renderer;
struct rediwm_scene_output;
struct wlr_output_state;
struct rediwm_projection;
struct rediwm_output_renderer;
struct wlr_render_pass;
struct wlr_buffer;
struct wlr_buffer_pass_options;
struct rediwm_output_renderer *rediwm_output_renderer_create(struct wlr_renderer *);
// Builds the programs that draw rounded shapes (see scene_pass.h); false if they
// did not build, in which case no window may be given a shape.
bool rediwm_output_renderer_enable_shapes(struct rediwm_output_renderer *);
// The program for imported client buffers (see scene_pass.h).
bool rediwm_output_renderer_enable_external(struct rediwm_output_renderer *);
// The programs for polygon outlines (see scene_pass.h), built on first request.
bool rediwm_output_renderer_enable_polygons(struct rediwm_output_renderer *);
// Glass in the pass (stage 5c); requires shapes. False: glass is the surface's own tint.
bool rediwm_output_renderer_enable_backdrops(struct rediwm_output_renderer *);
void rediwm_output_renderer_destroy(struct rediwm_output_renderer *);
// Node-subset capture uses the same drawing backend with its own swapchain
// and ReadFence; it must not inherit output culling or screen geometry.
struct wlr_render_pass *rediwm_output_begin_pass(struct rediwm_output_renderer *,
    struct wlr_buffer *, const struct wlr_buffer_pass_options *);
// Builds but never commits. The scene adapter continues to own surface
// enter/leave, pacing and the damage notifications during stages 3–5.
bool rediwm_scene_output_build_state(struct rediwm_output_renderer *,
    struct rediwm_projection *, struct rediwm_scene_output *, struct wlr_output_state *);
// Black over everything the output pass draws except the software cursor, at this
// alpha (0 = none, 1 = black), for the session's fade in and the greeter's fade
// out. A change repaints the whole output but re-blurs no glass: the veil lies
// above every effect. Direct scan-out waits until it is 0. False only when the
// state for a nonzero veil could not be allocated.
bool rediwm_scene_output_set_veil(struct rediwm_output_renderer *, struct rediwm_scene_output *, float alpha);
// Blend this output in linear light (docs/plans/hdr.md, phase 2), encoded back to
// sRGB for now. A change repaints the whole output and re-takes its glass. If the
// renderer cannot, frames are built as before and a warning is logged once.
// False only when the state for `on` could not be allocated.
bool rediwm_scene_output_set_linear(struct rediwm_output_renderer *, struct rediwm_scene_output *, bool on);
// The last frame built for this output blended in linear light.
bool rediwm_scene_output_linear(struct rediwm_output_renderer *, struct rediwm_scene_output *);
struct rediwm_pass_encode;
// How a linear output's frames are encoded (scene_pass.h): sRGB, or PQ while its
// commits carry an HDR10 image description. A change repaints the output.
// False only when the state could not be allocated.
bool rediwm_scene_output_set_encode(struct rediwm_output_renderer *, struct rediwm_scene_output *,
    const struct rediwm_pass_encode *);
bool rediwm_output_snapshot(struct rediwm_output_renderer *, struct rediwm_projection *,
    struct rediwm_scene_output *, struct rediwm_node *, struct wlr_box, float,
    struct wlr_buffer *, struct rediwm_read_fence *, struct rediwm_buffer *);
