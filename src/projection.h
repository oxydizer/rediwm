#pragma once
#include <stdbool.h>
#include <stdint.h>
struct rediwm_node;
struct rediwm_buffer;
struct rediwm_scene_outputs;
struct rediwm_scene_output;
struct rediwm_node;
struct rediwm_tree;
struct rediwm_scene;
struct wlr_surface_state;
struct rediwm_projection;
struct rediwm_item;
struct rediwm_clip_spec;
// Synchronous traversal of the whole displayed graph (bottom-to-top unless
// reverse is true). World geometry comes from resolved items; `transport` is the
// scene node that owns the item's buffer, texture and wait points: the source
// node for the world, the node itself for the layout trees. Callbacks must not
// mutate the scene; pointers are borrowed for this call.
typedef bool (*rediwm_item_iterator)(const struct rediwm_item *,
                                    struct rediwm_node *transport, void *);
bool rediwm_projection_for_each_item(struct rediwm_projection *, bool reverse, rediwm_item_iterator, void *);
// Whether a commit changed how buffer pixels map onto the surface, so damage
// from before it cannot be combined with damage after it.
bool rediwm_surface_state_remapped(const struct wlr_surface_state *);
// `own` is the compositor's scene: the children of its root are layers, bottom to
// top, and `world` (one of them) follows the camera while the others are laid out as
// they are. The projection resolves all of it into the graph the output pass draws,
// and asks for a frame whenever the scene changes. `scene` is wlroots' scene, kept
// for its outputs.
struct rediwm_projection *rediwm_projection_create(struct rediwm_scene *own,
                                                   struct rediwm_tree *world,
                                                   struct rediwm_scene_outputs *);
void rediwm_projection_destroy(struct rediwm_projection *);
void rediwm_projection_sync(struct rediwm_projection *, double, double, double,
                            double, double);
// A leaf's pixels changed in `box` (layout space) during a sync. `leaf` is the
// item's `id`; a leaf that is gone or hidden reports its last box.
struct rediwm_damage_event {
  uint64_t leaf;
  uint64_t home_output;
  struct { int x, y, width, height; } box;
};
typedef void (*rediwm_damage_event_iterator)(const struct rediwm_damage_event *, void *);
// Calls `fn` for every event since `*cursor` and moves the cursor past them. A
// consumer starts from rediwm_projection_damage_cursor(). Returns false when
// events were lost (the cursor fell behind the ring): treat everything as changed.
bool rediwm_projection_damage_events(struct rediwm_projection *, uint64_t *cursor,
                                     rediwm_damage_event_iterator, void *);
uint64_t rediwm_projection_damage_cursor(struct rediwm_projection *);
// Optional child of the world presented in layout coordinates, independent of the
// camera.
void rediwm_projection_sync_fixed(struct rediwm_projection *, double, double, double,
                                  double, double, struct rediwm_tree *);
// What a point lands on: the leaf node, and (x, y) the point in its own coordinates
// (source units for a client surface).
struct rediwm_hit {
  struct rediwm_node *own;
  double x, y;
};
bool rediwm_projection_node_at(struct rediwm_projection *, double lx, double ly,
                               struct rediwm_hit *);
// The same, among the leaves of one top-level subtree of a layer (a window's frame
// tree), whatever lies above it.
bool rediwm_projection_node_at_in(struct rediwm_projection *, struct rediwm_node *subtree,
                                  double lx, double ly, struct rediwm_hit *);
// Window scale relative to its parent camera, around the frame origin.
bool rediwm_projection_set_tree_zoom(struct rediwm_node *, double);
// Relative presentation scale. Composes with parent camera and window zoom.
bool rediwm_projection_set_tree_scale(struct rediwm_node *, double);
// One rounded-rectangle shape for every leaf under the tree, in the tree's own
// units and anchored at its origin; NULL removes it. Returns false for a size
// that is not positive or a radius or border that is negative or not finite.
bool rediwm_projection_set_tree_clip(struct rediwm_node *, const struct rediwm_clip_spec *);
// Every leaf under the tree draws the analytic shadow of this shape (see
// rediwm_shadow_spec in scene_graph.h); its node supplies only the footprint,
// opacity and input. NULL removes it. False for a size that is not positive, or a
// radius or softness that is negative or not finite.
struct rediwm_shadow_spec;
bool rediwm_projection_set_tree_shadow(struct rediwm_node *, const struct rediwm_shadow_spec *);
// Every leaf under the tree is drawn with this fraction of its brightness and of
// its colour taken away (both 0 to 1; 0 and 0 removes the dim): a window that is not
// the focus. It is part of what the leaf shows, so a change damages the leaves
// under the tree; a shadow is not drawn dimmed. False for a value outside 0 to 1.
bool rediwm_projection_set_tree_dim(struct rediwm_node *, float brightness, float saturation);
// Ends the clip and the dim inherited from an ancestor for this subtree (an xdg
// popup lives under its parent's tree but is no part of the window's frame).
bool rediwm_projection_set_tree_unclipped(struct rediwm_node *, bool);
// Shows the subtree but lets the pick pass through it to what is below.
bool rediwm_projection_set_tree_inert(struct rediwm_node *, bool);
// Confines a subtree (including unclipped descendants) to the given scene
// output. NULL restores normal placement across outputs.
bool rediwm_projection_set_tree_output(struct rediwm_node *, struct rediwm_scene_output *);
// The same for a node inside a wlroots subtree (a client's popup).
struct rediwm_shadow_spec;
// Buffer-local damage for the next buffer set on a compositor-owned source
// buffer node; NULL damages all of it. Surface leaves track their own.
struct pixman_region32;
void rediwm_projection_damage_buffer(struct rediwm_projection *,
                                     struct rediwm_node *,
                                     const struct pixman_region32 *);
// Presents `buffer` on a compositor-owned source buffer node, updating its
// texture in place with `damage` (buffer-local) when the renderer can. The
// caller may release `buffer` afterwards. NULL damage replaces everything.
// Returns whether the texture was updated in place.
struct wlr_renderer;
struct wlr_buffer;
bool rediwm_projection_present_owned(struct rediwm_projection *,
                                     struct rediwm_buffer *,
                                     struct wlr_renderer *,
                                     struct wlr_buffer *,
                                     const struct pixman_region32 *);
// A node's opaque region (in the node's own units, `source_width` by `source_height`)
// as it lands on a box of `width` by `height` device pixels: never larger than the
// real one, one pixel inward where the node is scaled.
void rediwm_mirror_opaque(struct pixman_region32 *out, const struct pixman_region32 *source,
                          int source_width, int source_height, int width, int height);
// Surface feedback (stage 6): each time the output pass builds, it reports how
// much of every client surface nothing above hides, over the whole layout.
// `begin` clears the last report, `note_output` records the layout-space
// region visible on one output, and `end` sends updated surface feedback.
void rediwm_projection_note_visible(struct rediwm_projection *, struct rediwm_node *,
                                    const struct pixman_region32 *visible);
void rediwm_projection_feedback_begin(struct rediwm_projection *);
void rediwm_projection_note_output(struct rediwm_projection *, struct rediwm_node *, struct rediwm_scene_output *,
                                     const struct pixman_region32 *visible);
void rediwm_projection_feedback_end(struct rediwm_projection *);
// Frame callbacks of the world's surfaces.
struct timespec;
void rediwm_projection_send_frame_done(struct rediwm_projection *, struct rediwm_scene_output *,
                                       struct timespec *now);
