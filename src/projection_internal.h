// Private to projection*.c and projection_test.c: the adapters the graph is
// built from and the small helpers its parts share. Everyone else uses
// projection.h. Helpers called per leaf are `static inline` here, as no file
// boundary may cost them their inlining.
#ifndef REDIWM_PROJECTION_INTERNAL_H
#define REDIWM_PROJECTION_INTERNAL_H

#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "projection.h"
#include "glass.h"
#include "node.h"
#include "scene_graph.h"
#include "scene_damage.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_output.h>
#include "node_surface.h"
#include "scene_outputs.h"
#include <wlr/util/addon.h>
#include <wlr/util/log.h>

// Damage events: which leaf changed which layout-space box, for consumers that
// must tell what lies below a point in paint order from what lies above it
// (backdrop effects, stage 5 of docs/plans/scene-graph.md). A ring: each consumer
// keeps its own cursor, and one that falls behind by more than the ring holds is
// told so and must treat everything as changed.
enum { DAMAGE_EVENTS = 4096 };
struct rediwm_projection {
  // The compositor's scene. The children of its root are layers, bottom to top:
  // `world` follows the camera, every other layer is laid out as is. The wlroots
  // scene is kept for its outputs.
  struct rediwm_scene *own;
  struct rediwm_tree *world;
  struct rediwm_scene_outputs *outputs;
  // What changed since the last sync. A change to one top-level subtree (a group) marks
  // that group; a change to the shape of the tree, a layer or anything not tied to
  // one group marks them all (`all_dirty`). A sync resolves and presents only the
  // marked groups, or none when nothing changed and the camera did not move.
  bool any_dirty, all_dirty, have_camera;
  double camera[5];
  struct rediwm_tree *fixed;
  // Every adapter, in creation order; `paint` holds the groups resolve() last
  // reached, bottom to top.
  struct wl_list leaves, groups, paint;
  // The surface leaves whose outputs the output pass reports (stage 6), and what
  // each output (by scene output index) looked like at the last report.
  struct wl_list feedback;
  struct {
    float scale;
    enum wl_output_transform transform;
    enum wl_output_subpixel subpixel;
    bool known;
  } shown_output[64];
  // The outputs whose scale, transform or subpixel order changed since: a surface
  // on them is told again even where nothing else changed, as wlroots does, for
  // its preferred scale.
  uint64_t forced;
  struct wl_listener new_surface;
  struct wl_list surfaces;
  uint64_t next_leaf_id;
  // Layout-space damage the sync in progress collects, applied to every output
  // when it ends (stage 6b).
  pixman_region32_t pending;
  struct rediwm_damage_event events[DAMAGE_EVENTS];
  uint64_t next_event; // sequence number of the next event; 0 is never used
};
// Source top-level subtrees are contiguous in paint order: each is a group, and
// a window going away damages everything its leaves showed at once.
struct group {
  struct wl_list link;
  // In projection->paint, or alone, when the last resolve() did not reach it.
  struct wl_list paint;
  // The leaves resolve() last reached under this group, bottom to top.
  struct wl_list items;
  bool enabled;
  // Changed since resolve() last walked it; walked at least once; walked by this sync.
  bool dirty, resolved, touched;
  // Holds a glass effect, whose box is its target's, which may be a node of another group:
  // such a group is walked whenever anything is.
  bool has_effect;
  struct rediwm_projection *projection;
  struct rediwm_node *source;
  struct wl_listener destroy;
  struct wlr_addon source_lookup;
  bool seen;
};
// A list link that is always valid to remove: alone, or in a live list.
static inline void detach(struct wl_list *link) {
  wl_list_remove(link);
  wl_list_init(link);
}
struct leaf {
  struct wl_list link;
  // In its group's `items` when the last resolve() reached it, else alone.
  struct wl_list paint;
  struct rediwm_projection *projection;
  // The node the pass reads the pixels from (`transport`): the buffer or rect itself.
  struct rediwm_node *source;
  // The own node it is.
  struct rediwm_node *own;
  // The group the last resolve() put it in.
  struct group *group;
  // A glass effect: decided when the leaf is made, as an effect is its own node.
  bool effect;
  struct wl_listener destroy, commit;
  struct wlr_addon source_lookup;
  struct rediwm_surface *surface;
  struct feedback *feedback;
  bool dirty, seen;
  // Under an inert tree at the last resolve(): drawn, never picked.
  bool inert;
  // Commits can outpace presentation. Keep their union, including empty damage
  // on a rotated buffer; buffer identity is not evidence of changed pixels.
  pixman_region32_t damage;
  bool full_damage;
  // A compositor-owned buffer reported its own damage since the last sync;
  // without a report a replaced buffer damages its whole box.
  bool owned_damage;
  int damage_width, damage_height;
  // The graph's view of this leaf, rewritten by every resolve(). `item.clip`
  // points at `clip` when the leaf is under a clipped tree.
  struct rediwm_item item;
  struct rediwm_clip clip;
  // `item.shadow` points at `shadow` when the leaf is under a shadow tree. A
  // shadow has no buffer to damage: present() damages the footprint it last drew
  // (`shadow_drawn`) and the new one.
  struct rediwm_shadow shadow;
  // The box present() last showed the leaf in, for its damage events.
  struct rediwm_snap shown;
  struct rediwm_content shown_content;
  bool has_shown;
  // What of the leaf nothing above hid when the output pass last built, over the
  // whole layout: damage that changes only what the leaf shows is cut to it, as
  // wlroots cut it to a node's visible region. Not known until the first build.
  pixman_region32_t visible;
  bool has_visible;
  // Position in paint order at the last sync, to tell a restack.
  uint32_t rank;
  bool ranked;
  struct rediwm_shadow shadow_drawn_as;
  struct rediwm_snap shadow_drawn;
  float shadow_drawn_opacity;
  bool has_shadow_drawn;
  struct wlr_buffer *last_buffer;
};
// Everything the compositor says about how a source tree is presented, in one
// addon. Resolve meets every tree of every window on every frame, and each
// property that had an addon of its own cost a lookup there. The properties:
//  * zoom: a window's scale about its origin, composing with the camera;
//  * scale: a relative presentation scale (Xwayland's 1/N), composing with both;
//  * clip: the rounded shape that clips everything under the tree. Resolve
//    evaluates it after this tree's own zoom and scale, so it follows its window
//    and an inner scale never changes it. A clipped tree inside another replaces
//    the outer shape for its own leaves; nothing intersects them;
//  * unclipped: ends the inherited clip and dim for the subtree. A popup's scene
//    tree is a child of its parent surface's, so it sits under the window's clipped
//    tree in the source graph while belonging to no window frame. The subtree's own
//    clip or dim, if it sets one, still applies;
//  * dim: every leaf under the tree loses this fraction of its brightness and of
//    its colour (`rediwm_content.dim_*`), inherited like the clip. It is a field of
//    the item, so a change of it damages what the leaves show with no rule of its
//    own, and the pass applies it per draw. A subtree's own dim replaces the outer
//    one, and `unclipped` ends it as it ends the clip;
//  * shadow: every leaf under the tree is the analytic shadow of this shape
//    (REDIWM_ITEM_SHADOW), resolved like the clip;
//  * inert: the subtree is shown but takes no input: the pick passes through it
//    to what is below (a window sliding off a workspace it has left).
struct dim {
  float brightness, saturation;
};
struct tree_props {
  struct wlr_addon addon;
  // Where an own node keeps its properties (`rediwm_node.props`), cleared with them.
  void **slot;
  bool has_zoom, has_scale, has_clip, unclipped, has_shadow, inert, has_dim;
  double zoom, scale;
  struct dim dim;
  struct rediwm_clip_spec clip;
  struct rediwm_shadow_spec shadow;
  // The clip as the last resolve() saw it in layout space, to tell a changed
  // shape (to be damaged) from a moved window (whose leaves damage themselves).
  struct rediwm_clip applied;
  bool has_applied;
};
extern const struct wlr_addon_interface projection_tree_props_impl;
static inline struct tree_props *tree_props_find(struct wlr_addon_set *set, void **slot) {
  if (slot) return *slot;
  struct wlr_addon *addon = wlr_addon_find(set, NULL, &projection_tree_props_impl);
  struct tree_props *props;
  return addon ? (props = wl_container_of(addon, props, addon)) : NULL;
}
struct watched_surface {
  struct rediwm_projection *projection;
  struct wlr_surface *surface;
  struct wl_list link;
  struct wl_listener commit, destroy;
};
static inline void mark_all(struct rediwm_projection *p) { p->any_dirty = p->all_dirty = true; }
static inline void mark_group(struct rediwm_projection *p, struct group *g) {
  if (!g) {
    mark_all(p);
    return;
  }
  g->dirty = true;
  p->any_dirty = true;
}
static inline void schedule(struct rediwm_projection *p) {
  struct rediwm_scene_output *out;
  wl_list_for_each(out, &p->outputs->outputs, link) {
      rediwm_trace_damage(out->output);
      wlr_output_schedule_frame(out->output);
  }
}
// ---- Surface feedback (stage 6 of docs/plans/scene-graph.md) ---------------------
// wlr_scene tells a surface where it is shown by emitting its scene buffer's own
// signals, from the node's visible region. The world's source tree is disabled, so
// wlroots sees nothing there; the output pass, which draws the graph, knows what
// is shown.
// For every client surface it reports, per output it builds, how many pixels are
// visible (not hidden by what is above), and this keeps the last report of each
// output. From the sums it applies wlroots' own rule (scene.c,
// update_node_update_outputs): an output is active when it shows more than a tenth
// of what is visible on all of them, and the primary one is the one showing most
// (the last, on a tie). It then emits the signals the surface binding listens to
// (node_surface.c) on the source buffer.
enum { FEEDBACK_OUTPUTS = 64 };
struct feedback {
  struct wl_list link;
  struct leaf *leaf;
  // Visible pixels as the last build of each output (scene output index) saw them.
  uint32_t area[FEEDBACK_OUTPUTS];
  uint64_t active;
  struct rediwm_scene_output *primary;
};
static inline void emit(struct rediwm_projection *p, uint64_t leaf, int x, int y, int width, int height) {
  if (width <= 0 || height <= 0) return;
  if (!p->next_event) p->next_event = 1;
  p->events[p->next_event % DAMAGE_EVENTS] =
      (struct rediwm_damage_event){.leaf = leaf, .box = {x, y, width, height}};
  p->next_event++;
}
static inline void emit_snap(struct leaf *l, struct rediwm_snap s) {
  emit(l->projection, l->item.id, s.x, s.y, s.width, s.height);
}
// Layout-space damage for the screen, applied when the sync ends. `visible_only`
// cuts it to what the leaf showed at the last build: a change of what the leaf
// itself shows is invisible where something opaque lay over it, and anything that
// stops covering it damages that region itself.
static inline void damage_box(struct leaf *l, struct rediwm_snap s, bool visible_only) {
  if (s.width <= 0 || s.height <= 0) return;
  pixman_region32_t *pending = &l->projection->pending;
  if (visible_only && l->has_visible) {
    pixman_region32_t region;
    pixman_region32_init_rect(&region, s.x, s.y, s.width, s.height);
    pixman_region32_intersect(&region, &region, &l->visible);
    pixman_region32_union(pending, pending, &region);
    pixman_region32_fini(&region);
  } else {
    pixman_region32_union_rect(pending, pending, s.x, s.y, s.width, s.height);
  }
}
static inline void forget_shown(struct leaf *l) {
  if (l->has_shown) {
    emit_snap(l, l->shown);
    damage_box(l, l->shown, true);
  }
  l->has_shown = false;
}

// Shared between the parts (projection_*.c).
extern const struct wlr_addon_interface projection_group_source_impl;
struct group *projection_get_group(struct rediwm_projection *p, struct rediwm_node *source);
struct leaf *projection_get_leaf(struct rediwm_projection *p, struct rediwm_node *source,
                                 struct rediwm_node *own);
void projection_free_feedback(struct leaf *l);
void projection_resolve(struct rediwm_projection *p, double z, double cx, double cy,
                        double ox, double oy, struct rediwm_tree *fixed, bool full);
void projection_present(struct rediwm_projection *p, bool full);
void projection_damage_shadow(struct leaf *l, bool show, struct rediwm_snap at);

#endif
