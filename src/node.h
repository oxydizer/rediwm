// The compositor's own scene nodes (stage 7 of the scene-graph work).
//
// What wlr_scene gave the compositor as a data model (and the compositor no longer links
// it): a tree of nodes with a
// position, an enabled flag and an owner pointer, whose leaves are buffers or
// rectangles. It does no drawing, damage or picking here; the projection resolves
// the tree into items and the output pass draws them. Every mutator that can change
// what the tree shows reports it through the scene's `changed` hook, which asks for
// a frame; the projection then finds what moved by comparing items, as it does for
// the world today.
//
// Field names follow wlr_scene on purpose: the projection and the pass read the
// same members under the same names, and the Zig wrapper keeps wlr_scene's method
// names, so a call site changes by type, not by shape.
//
// Single-threaded, like the rest of the compositor.
#pragma once
#include <pixman.h>
#include <stdbool.h>
#include <stdint.h>
#include <wayland-server-core.h>
#include <wayland-server-protocol.h>
#include <wlr/render/color.h>
#include <wlr/render/pass.h>
#include <wlr/util/addon.h>
#include <wlr/util/box.h>

struct wlr_buffer;
struct wlr_output;
struct wlr_texture;
struct wlr_drm_syncobj_timeline;
struct rediwm_scene;
struct rediwm_scene_outputs;
struct rediwm_tree;

enum rediwm_node_type {
  REDIWM_NODE_TREE,
  REDIWM_NODE_RECT,
  REDIWM_NODE_BUFFER,
};

struct rediwm_node {
  enum rediwm_node_type type;
  struct rediwm_tree *parent; // NULL for a scene's root
  struct wl_list link;        // in parent->children, bottom to top
  bool enabled;
  int x, y; // relative to the parent
  void *data;
  struct {
    struct wl_signal destroy;
  } events;
  struct wlr_addon_set addons;
  // The projection's per-node state, found without a walk of `addons` on every sync:
  // a tree's presentation properties, the group a top-level node is, and the leaf a
  // buffer or rect is.
  void *props, *group, *leaf;
  struct rediwm_scene *scene;
};

struct rediwm_tree {
  struct rediwm_node node;
  struct wl_list children; // rediwm_node.link, bottom to top
};

struct rediwm_rect {
  struct rediwm_node node;
  int width, height;
  float color[4]; // premultiplied
};

struct rediwm_buffer;
struct rediwm_surface;
typedef bool (*rediwm_buffer_point_accepts_input)(struct rediwm_buffer *, double *x, double *y);

// A buffer node shows a wlr_buffer, or a colour, or nothing: the content is held here
// (the lock, the texture the output pass uploads, wait points, a single-pixel colour),
// as wlr_scene_buffer keeps it, and the setters keep it in step with the geometry.
struct rediwm_buffer {
  struct rediwm_node node;
  rediwm_buffer_point_accepts_input point_accepts_input; // may be NULL
  float opacity;
  enum wlr_scale_filter_mode filter_mode;
  struct wlr_fbox src_box;
  int dst_width, dst_height;
  enum wl_output_transform transform;
  // Under a tree clip that maps its texture radially (`sector_texture_height`): the
  // part of the mapped image this node fills, as fractions of it (x, y, width,
  // height). A zero width is all of it. Elsewhere it is not used.
  float sector_rect[4];
  pixman_region32_t opaque_region;
  // The size of the buffer as last set, kept for when the renderer releases it.
  int buffer_width, buffer_height;
  // The client surface this node shows, or NULL (node_surface.h).
  struct rediwm_surface *surface;

  // Content. `buffer` is NULL once the renderer has uploaded it and let it go (the
  // texture then stands for it). `own_buffer`: this node holds a lock on `buffer`.
  struct wlr_buffer *buffer;
  bool own_buffer;
  struct wl_listener buffer_release;
  struct wlr_texture *texture;
  struct wl_listener renderer_destroy;
  struct wlr_drm_syncobj_timeline *wait_timeline;
  uint64_t wait_point;
  bool buffer_is_opaque;
  bool is_single_pixel_buffer;
  uint32_t single_pixel_buffer_color[4];
  enum wlr_color_transfer_function transfer_function;
  enum wlr_color_named_primaries primaries;
  enum wlr_color_encoding color_encoding;
  enum wlr_color_range color_range;
  // What the output pass reports of a surface node (scene_outputs.h).
  struct {
    struct wl_signal outputs_update; // struct rediwm_outputs_update_event
    struct wl_signal output_sample;  // struct rediwm_output_sample_event
    struct wl_signal frame_done;     // struct rediwm_frame_done_event
  } events;
};

struct rediwm_scene {
  struct rediwm_tree tree;
  // Something the tree shows may have changed: the owner schedules a frame.
  // `node` is the one that changed (NULL when it is gone); `structural` when nodes
  // were made, moved, stacked or destroyed, or a layer changed.
  void (*changed)(void *data, struct rediwm_node *node, bool structural);
  // A buffer node was given a buffer (set_buffer, set_buffer_with_damage): the
  // buffer-local `damage` of what differs, or NULL for all of it. The projection turns
  // this into screen damage, as wlroots did for the nodes it tracked.
  void (*buffer_damaged)(void *data, struct rediwm_buffer *, const pixman_region32_t *damage);
  void *changed_data;
  // The outputs this scene is shown on (what surfaces are told about).
  struct rediwm_scene_outputs *outputs;
  // A client surface shown on `output` committed with frame callbacks waiting. NULL
  // schedules a frame, which delivers them; the owner may deliver them without one.
  void (*frame_callbacks)(struct wlr_output *output);
};

static inline struct rediwm_tree *rediwm_tree_from_node(struct rediwm_node *node) {
  return node->type == REDIWM_NODE_TREE ? (struct rediwm_tree *)node : NULL;
}
static inline struct rediwm_rect *rediwm_rect_from_node(struct rediwm_node *node) {
  return node->type == REDIWM_NODE_RECT ? (struct rediwm_rect *)node : NULL;
}
static inline struct rediwm_buffer *rediwm_buffer_from_node(struct rediwm_node *node) {
  return node->type == REDIWM_NODE_BUFFER ? (struct rediwm_buffer *)node : NULL;
}

// A scene is its root tree; `changed` may be NULL.
struct rediwm_scene *rediwm_scene_create(void (*changed)(void *, struct rediwm_node *, bool),
                                         void *data);
void rediwm_scene_destroy(struct rediwm_scene *);

// Children are created enabled, at (0, 0), on top of their siblings. NULL on
// allocation failure.
struct rediwm_tree *rediwm_tree_create(struct rediwm_tree *parent);
struct rediwm_rect *rediwm_rect_create(struct rediwm_tree *parent, int width, int height,
                                       const float color[4]);
struct rediwm_buffer *rediwm_buffer_create(struct rediwm_tree *parent, struct wlr_buffer *);

// Destroys the node and everything under it; each node emits events.destroy first.
void rediwm_node_destroy(struct rediwm_node *);
// Reports a change the node's setters cannot see: asks for a frame.
void rediwm_node_touch(struct rediwm_node *);
void rediwm_node_set_enabled(struct rediwm_node *, bool enabled);
void rediwm_node_set_position(struct rediwm_node *, int x, int y);
// Restacking: all of these are no-ops where the node already sits.
void rediwm_node_raise_to_top(struct rediwm_node *);
void rediwm_node_lower_to_bottom(struct rediwm_node *);
void rediwm_node_place_above(struct rediwm_node *, struct rediwm_node *sibling);
void rediwm_node_place_below(struct rediwm_node *, struct rediwm_node *sibling);
// Moves the node to the top of `parent`, which must not be inside the node.
void rediwm_node_reparent(struct rediwm_node *, struct rediwm_tree *parent);
// The node's origin in the scene's root, and whether it and every ancestor are
// enabled, as wlr_scene_node_coords.
bool rediwm_node_coords(struct rediwm_node *, int *lx, int *ly);
// Whether the node and every ancestor are enabled.
bool rediwm_node_visible(const struct rediwm_node *);

void rediwm_rect_set_size(struct rediwm_rect *, int width, int height);
void rediwm_rect_set_color(struct rediwm_rect *, const float color[4]);

// Takes a lock on `buffer` (NULL clears), as wlr_scene_buffer_set_buffer. Nothing is
// damaged here: the caller of a compositor-owned buffer reports its damage to the
// projection.
void rediwm_buffer_set_buffer(struct rediwm_buffer *, struct wlr_buffer *);
// As wlr_scene_buffer_set_buffer_with_damage: `damage` is buffer-local.
void rediwm_buffer_set_buffer_with_damage(struct rediwm_buffer *, struct wlr_buffer *,
                                          const pixman_region32_t *damage);
// Damage (buffer-local, NULL for all of it) plus an acquire point to wait for before
// the buffer is read.
struct rediwm_buffer_options {
  const pixman_region32_t *damage;
  struct wlr_drm_syncobj_timeline *wait_timeline;
  uint64_t wait_point;
};
void rediwm_buffer_set_buffer_with_options(struct rediwm_buffer *, struct wlr_buffer *,
                                           const struct rediwm_buffer_options *);
// Replaces the content without telling the scene or the projection: for a caller that
// reports the damage itself (rediwm_projection_present_owned).
void rediwm_buffer_set_content(struct rediwm_buffer *, struct wlr_buffer *);
// The renderer's texture of the content, kept until the next buffer is set (the pass
// uploads it); NULL drops it.
void rediwm_buffer_set_texture(struct rediwm_buffer *, struct wlr_texture *);
// The buffer the node holds; NULL once the renderer released it after upload.
struct wlr_buffer *rediwm_buffer_get_buffer(const struct rediwm_buffer *);
void rediwm_buffer_set_dest_size(struct rediwm_buffer *, int width, int height);
void rediwm_buffer_set_source_box(struct rediwm_buffer *, const struct wlr_fbox *);
void rediwm_buffer_set_opacity(struct rediwm_buffer *, float opacity);
void rediwm_buffer_set_filter_mode(struct rediwm_buffer *, enum wlr_scale_filter_mode);
void rediwm_buffer_set_transform(struct rediwm_buffer *, enum wl_output_transform);
// See `sector_rect`; NULL is the whole image.
void rediwm_buffer_set_sector_rect(struct rediwm_buffer *, const float rect[4]);
// A copy of the region, in buffer-local units; NULL clears it.
void rediwm_buffer_set_opaque_region(struct rediwm_buffer *, const pixman_region32_t *);
// The size the buffer node is shown at when nothing sets one: the destination, else
// the buffer's own size with the transform applied.
void rediwm_buffer_size(const struct rediwm_buffer *, int *width, int *height);

// The topmost enabled node of the subtree at (x, y) in the subtree's own
// coordinates, with the point in the node's, as wlr_scene_node_at. Buffers answer
// through `point_accepts_input`.
struct rediwm_node *rediwm_node_at(struct rediwm_node *, double x, double y, double *nx, double *ny);
typedef void (*rediwm_buffer_iterator)(struct rediwm_buffer *, int sx, int sy, void *data);
// Every buffer of the subtree, bottom to top, with its position relative to the
// node passed in (as wlr_scene_node_for_each_buffer; disabled nodes are skipped).
void rediwm_node_for_each_buffer(struct rediwm_node *, rediwm_buffer_iterator, void *data);
