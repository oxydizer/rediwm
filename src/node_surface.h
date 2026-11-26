// Client surfaces in the own scene (stage 7b of the scene-graph work).
//
// A port of wlroots' wlr_scene_surface, wlr_scene_subsurface_tree, wlr_scene_xdg_surface,
// and wlr_scene_drag_icon onto own nodes (MIT licensed, as
// wlroots; the logic follows types/scene/*.c of wlroots 0.20). A surface is an own buffer
// node whose content follows the wl_surface; a surface with subsurfaces is a tree of
// them, stacked as the protocol orders them. The binding listens to the buffer node's
// signals, which the projection and the output pass raise: outputs_update,
// output_sample and frame_done.
#pragma once
#include "node.h"
#include <wlr/types/wlr_alpha_modifier_v1.h>
#include <wlr/types/wlr_color_management_v1.h>
#include <wlr/types/wlr_color_representation_v1.h>
#include <wlr/util/box.h>

struct wlr_surface;
struct wlr_xdg_surface;
struct wlr_drag_icon;

// The surface a buffer node shows. Only `buffer` and `surface` are read outside.
struct rediwm_surface {
  struct rediwm_buffer *buffer;
  struct wlr_surface *surface;
  struct wlr_box clip;
  struct glass_effect *glass;
  struct wl_listener node_destroy, outputs_update, output_sample, frame_done, surface_destroy,
      surface_commit;
};

// A metadata-only commit changes every displayed pixel, including in live previews.
static inline void rediwm_buffer_sync_surface_color(struct rediwm_buffer *scene_buffer, struct wlr_surface *surface) {
  enum wlr_color_transfer_function tf = WLR_COLOR_TRANSFER_FUNCTION_GAMMA22;
  enum wlr_color_named_primaries primaries = WLR_COLOR_NAMED_PRIMARIES_SRGB;
  const struct wlr_image_description_v1_data *img_desc =
      surface ? wlr_surface_get_image_description_v1_data(surface) : NULL;
  if (img_desc != NULL) {
    tf = wlr_color_manager_v1_transfer_function_to_wlr(img_desc->tf_named);
    primaries = wlr_color_manager_v1_primaries_to_wlr(img_desc->primaries_named);
  }

  enum wlr_color_encoding color_encoding = WLR_COLOR_ENCODING_NONE;
  enum wlr_color_range color_range = WLR_COLOR_RANGE_NONE;
  const struct wlr_color_representation_v1_surface_state *color_repr =
      surface ? wlr_color_representation_v1_get_surface_state(surface) : NULL;
  if (color_repr != NULL) {
    if (color_repr->coefficients != 0)
      color_encoding = wlr_color_representation_v1_color_encoding_to_wlr(color_repr->coefficients);
    if (color_repr->range != 0)
      color_range = wlr_color_representation_v1_color_range_to_wlr(color_repr->range);
  }

  const bool color_changed = scene_buffer->transfer_function != tf || scene_buffer->primaries != primaries ||
      scene_buffer->color_encoding != color_encoding || scene_buffer->color_range != color_range;
  scene_buffer->transfer_function = tf;
  scene_buffer->primaries = primaries;
  scene_buffer->color_encoding = color_encoding;
  scene_buffer->color_range = color_range;
  if (color_changed) rediwm_node_touch(&scene_buffer->node);
}

// Sample committed alpha only when binding to a surface or following a commit.
// Reconfiguring a scene clip can also happen between Wayland commits.
static inline void rediwm_buffer_sync_surface_alpha(struct rediwm_buffer *buffer, struct wlr_surface *surface) {
  const struct wlr_alpha_modifier_surface_v1_state *state =
      surface ? wlr_alpha_modifier_v1_get_surface_state(surface) : NULL;
  rediwm_buffer_set_alpha_multiplier(buffer, state ? (float)state->multiplier : 1);
}

// A node showing `surface` alone, no subsurfaces. NULL on allocation failure.
struct rediwm_surface *rediwm_surface_create(struct rediwm_tree *parent, struct wlr_surface *);
// Clips what the node shows of the surface to `clip` (surface coordinates), or lifts the
// clip when NULL. The subsurface tree sets it; others use rediwm_subsurface_tree_set_clip.
void rediwm_surface_set_clip(struct rediwm_surface *surface, const struct wlr_box *clip);

// The output that paces `surface` (frame callbacks, presentation feedback, fifo-v1
// barriers): the highest-refresh output it is shown on. NULL while it is hidden on every
// output (covered, minimized, another workspace, unmapped, outputs off).
struct wlr_output *rediwm_surface_frame_pacing_output(struct wlr_surface *surface);

// The surface and its subsurfaces, in a tree that follows them, enabled while mapped.
struct rediwm_tree *rediwm_subsurface_tree_create(struct rediwm_tree *parent, struct wlr_surface *);
// Clips every surface of the subsurface trees at or under `node` to `clip` (in the
// tree's coordinates), or lifts the clip when NULL. Returns false if none was found.
bool rediwm_subsurface_tree_set_clip(struct rediwm_node *node, const struct wlr_box *clip);

// An xdg surface's tree: the surface at the origin of its window geometry, and a popup
// at its position. Popups are made by the compositor as children of this tree.
struct rediwm_tree *rediwm_xdg_surface_create(struct rediwm_tree *parent, struct wlr_xdg_surface *);

// A drag icon's tree, moved by the icon's own offset on every commit.
struct rediwm_tree *rediwm_drag_icon_create(struct rediwm_tree *parent, struct wlr_drag_icon *);
