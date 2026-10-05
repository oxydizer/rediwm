#pragma once
#include <stdbool.h>
struct wlr_scene_node;
struct wlr_scene_tree;
struct wlr_scene;
struct wlr_surface_state;
struct rediwm_projection;
// Whether a commit changed how buffer pixels map onto the surface, so damage
// from before it cannot be combined with damage after it.
bool rediwm_surface_state_remapped(const struct wlr_surface_state *);
struct rediwm_projection *rediwm_projection_create(struct wlr_scene_tree *,
                                                   struct wlr_scene_tree *,
                                                   struct wlr_scene *);
void rediwm_projection_destroy(struct rediwm_projection *);
void rediwm_projection_sync(struct rediwm_projection *, double, double, double,
                            double, double);
// Optional root subtree presented in layout coordinates, independent of the camera.
void rediwm_projection_sync_fixed(struct rediwm_projection *, double, double, double,
                                  double, double, struct wlr_scene_tree *);
struct wlr_scene_node *rediwm_projection_source(struct wlr_scene_node *);
// Window scale relative to its parent camera, around the frame origin.
bool rediwm_projection_set_tree_zoom(struct wlr_scene_node *, double);
// Relative presentation scale. Composes with parent camera and window zoom.
bool rediwm_projection_set_tree_scale(struct wlr_scene_node *, double);
double rediwm_projection_node_zoom(struct wlr_scene_node *);
// Buffer-local damage for the next buffer set on a compositor-owned source
// buffer node; NULL damages all of it. Surface leaves track their own.
struct pixman_region32;
void rediwm_projection_damage_buffer(struct rediwm_projection *,
                                     struct wlr_scene_node *,
                                     const struct pixman_region32 *);
// Presents `buffer` on a compositor-owned source buffer node, updating its
// texture in place with `damage` (buffer-local) when the renderer can. The
// caller may release `buffer` afterwards. NULL damage replaces everything.
// Returns whether the texture was updated in place.
struct wlr_scene_buffer;
struct wlr_renderer;
struct wlr_buffer;
bool rediwm_projection_present_owned(struct rediwm_projection *,
                                     struct wlr_scene_buffer *,
                                     struct wlr_renderer *,
                                     struct wlr_buffer *,
                                     const struct pixman_region32 *);
struct wlr_scene_node *rediwm_projection_node(struct rediwm_projection *,
                                              struct wlr_scene_node *);
