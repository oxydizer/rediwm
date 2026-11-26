// A surface and its subsurfaces in the own scene: see node_surface.h. wlroots'
// types/scene/subsurface_tree.c (wlroots 0.20, MIT licensed) on own nodes.
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "node_surface.h"
#include "glass.h"
#include <assert.h>
#include <stdlib.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_subcompositor.h>

// A tree for a surface and all of its child sub-surfaces. `tree` contains `scene_surface`
// and one node per sub-surface.
struct rediwm_subsurface_tree {
  struct rediwm_tree *tree;
  struct wlr_surface *surface;
  struct rediwm_surface *scene_surface;

  struct wl_listener surface_destroy;
  struct wl_listener surface_commit;
  struct wl_listener surface_map;
  struct wl_listener surface_unmap;
  struct wl_listener surface_new_subsurface;

  struct rediwm_subsurface_tree *parent; // NULL for the top-level surface

  struct wlr_addon scene_addon;

  struct wlr_box clip;

  // Only valid if the surface is a sub-surface

  struct wlr_addon surface_addon;

  struct wl_listener subsurface_destroy;
};

static void subsurface_tree_addon_destroy(struct wlr_addon *addon) {
  struct rediwm_subsurface_tree *subsurface_tree = wl_container_of(addon, subsurface_tree, scene_addon);
  // tree and scene_surface are cleaned up with the node
  if (subsurface_tree->parent) {
    wlr_addon_finish(&subsurface_tree->surface_addon);
    wl_list_remove(&subsurface_tree->subsurface_destroy.link);
  }
  wlr_addon_finish(&subsurface_tree->scene_addon);
  wl_list_remove(&subsurface_tree->surface_destroy.link);
  wl_list_remove(&subsurface_tree->surface_commit.link);
  wl_list_remove(&subsurface_tree->surface_map.link);
  wl_list_remove(&subsurface_tree->surface_unmap.link);
  wl_list_remove(&subsurface_tree->surface_new_subsurface.link);
  free(subsurface_tree);
}

static const struct wlr_addon_interface subsurface_tree_surface_addon_impl;

static struct rediwm_subsurface_tree *subsurface_tree_from_subsurface(
    struct rediwm_subsurface_tree *parent, struct wlr_subsurface *subsurface) {
  struct wlr_addon *addon =
      wlr_addon_find(&subsurface->surface->addons, parent, &subsurface_tree_surface_addon_impl);
  assert(addon != NULL);
  struct rediwm_subsurface_tree *subsurface_tree = wl_container_of(addon, subsurface_tree, surface_addon);
  return subsurface_tree;
}

static bool subsurface_tree_reconfigure_clip(struct rediwm_subsurface_tree *subsurface_tree) {
  struct rediwm_node *surface_node = &subsurface_tree->scene_surface->buffer->node;
  if (subsurface_tree->parent) {
    subsurface_tree->clip = (struct wlr_box){
        .x = subsurface_tree->parent->clip.x - subsurface_tree->tree->node.x,
        .y = subsurface_tree->parent->clip.y - subsurface_tree->tree->node.y,
        .width = subsurface_tree->parent->clip.width,
        .height = subsurface_tree->parent->clip.height,
    };
  }

  if (wlr_box_empty(&subsurface_tree->clip)) {
    rediwm_surface_set_clip(subsurface_tree->scene_surface, NULL);
    rediwm_node_set_enabled(surface_node, true);
    rediwm_node_set_position(surface_node, 0, 0);

    return false;
  } else {
    struct wlr_box clip = subsurface_tree->clip;
    struct wlr_box surface_box = {
        .width = subsurface_tree->surface->current.width,
        .height = subsurface_tree->surface->current.height,
    };

    bool intersects = wlr_box_intersection(&clip, &clip, &surface_box);
    rediwm_node_set_enabled(surface_node, intersects);

    if (intersects) {
      rediwm_node_set_position(surface_node, clip.x, clip.y);
      rediwm_surface_set_clip(subsurface_tree->scene_surface, &clip);
    }

    return true;
  }
}

static void subsurface_tree_reconfigure(struct rediwm_subsurface_tree *subsurface_tree) {
  bool has_clip = subsurface_tree_reconfigure_clip(subsurface_tree);

  struct wlr_surface *surface = subsurface_tree->surface;

  struct rediwm_node *prev = NULL;
  struct wlr_subsurface *subsurface;
  wl_list_for_each(subsurface, &surface->current.subsurfaces_below, current.link) {
    struct rediwm_subsurface_tree *child = subsurface_tree_from_subsurface(subsurface_tree, subsurface);
    if (prev != NULL) rediwm_node_place_above(&child->tree->node, prev);
    prev = &child->tree->node;

    rediwm_node_set_position(&child->tree->node, subsurface->current.x, subsurface->current.y);

    if (has_clip) subsurface_tree_reconfigure_clip(child);
  }

  if (subsurface_tree->scene_surface->glass) {
    struct rediwm_node *glass = rediwm_glass_node(subsurface_tree->scene_surface->glass);
    if (prev) rediwm_node_place_above(glass, prev);
    prev = glass;
  }
  if (prev != NULL) rediwm_node_place_above(&subsurface_tree->scene_surface->buffer->node, prev);
  prev = &subsurface_tree->scene_surface->buffer->node;

  wl_list_for_each(subsurface, &surface->current.subsurfaces_above, current.link) {
    struct rediwm_subsurface_tree *child = subsurface_tree_from_subsurface(subsurface_tree, subsurface);
    rediwm_node_place_above(&child->tree->node, prev);
    prev = &child->tree->node;

    rediwm_node_set_position(&child->tree->node, subsurface->current.x, subsurface->current.y);

    if (has_clip) subsurface_tree_reconfigure_clip(child);
  }
}

static void subsurface_tree_handle_surface_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_subsurface_tree *subsurface_tree =
      wl_container_of(listener, subsurface_tree, surface_destroy);
  rediwm_node_destroy(&subsurface_tree->tree->node);
}

static void subsurface_tree_handle_surface_commit(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_subsurface_tree *subsurface_tree =
      wl_container_of(listener, subsurface_tree, surface_commit);

  // TODO: only do this on subsurface order or position change
  subsurface_tree_reconfigure(subsurface_tree);
}

static void subsurface_tree_handle_subsurface_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_subsurface_tree *subsurface_tree =
      wl_container_of(listener, subsurface_tree, subsurface_destroy);
  rediwm_node_destroy(&subsurface_tree->tree->node);
}

static void subsurface_tree_handle_surface_map(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_subsurface_tree *subsurface_tree =
      wl_container_of(listener, subsurface_tree, surface_map);

  rediwm_node_set_enabled(&subsurface_tree->tree->node, true);
}

static void subsurface_tree_handle_surface_unmap(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_subsurface_tree *subsurface_tree =
      wl_container_of(listener, subsurface_tree, surface_unmap);

  rediwm_node_set_enabled(&subsurface_tree->tree->node, false);
}

static void subsurface_tree_surface_addon_destroy(struct wlr_addon *addon) {
  struct rediwm_subsurface_tree *subsurface_tree = wl_container_of(addon, subsurface_tree, surface_addon);
  rediwm_node_destroy(&subsurface_tree->tree->node);
}

static const struct wlr_addon_interface subsurface_tree_surface_addon_impl = {
    .name = "rediwm_subsurface_tree",
    .destroy = subsurface_tree_surface_addon_destroy,
};

static struct rediwm_subsurface_tree *scene_surface_tree_create(struct rediwm_tree *parent,
                                                                 struct wlr_surface *surface);

static bool subsurface_tree_create_subsurface(struct rediwm_subsurface_tree *parent,
                                              struct wlr_subsurface *subsurface) {
  struct rediwm_subsurface_tree *child = scene_surface_tree_create(parent->tree, subsurface->surface);
  if (child == NULL) return false;

  child->parent = parent;

  wlr_addon_init(&child->surface_addon, &subsurface->surface->addons, parent,
                 &subsurface_tree_surface_addon_impl);

  child->subsurface_destroy.notify = subsurface_tree_handle_subsurface_destroy;
  wl_signal_add(&subsurface->events.destroy, &child->subsurface_destroy);

  return true;
}

static void subsurface_tree_handle_surface_new_subsurface(struct wl_listener *listener, void *data) {
  struct rediwm_subsurface_tree *subsurface_tree =
      wl_container_of(listener, subsurface_tree, surface_new_subsurface);
  struct wlr_subsurface *subsurface = data;
  if (!subsurface_tree_create_subsurface(subsurface_tree, subsurface))
    wl_resource_post_no_memory(subsurface->resource);
}

static const struct wlr_addon_interface subsurface_tree_addon_impl = {
    .name = "rediwm_subsurface_tree",
    .destroy = subsurface_tree_addon_destroy,
};

static struct rediwm_subsurface_tree *scene_surface_tree_create(struct rediwm_tree *parent,
                                                                 struct wlr_surface *surface) {
  struct rediwm_subsurface_tree *subsurface_tree = calloc(1, sizeof(*subsurface_tree));
  if (subsurface_tree == NULL) return NULL;

  subsurface_tree->tree = rediwm_tree_create(parent);
  if (subsurface_tree->tree == NULL) goto error_surface_tree;

  subsurface_tree->scene_surface = rediwm_surface_create(subsurface_tree->tree, surface);
  if (subsurface_tree->scene_surface == NULL) goto error_scene_surface;

  subsurface_tree->surface = surface;

  struct wlr_subsurface *subsurface;
  wl_list_for_each(subsurface, &surface->current.subsurfaces_below, current.link) {
    if (!subsurface_tree_create_subsurface(subsurface_tree, subsurface)) goto error_scene_surface;
  }
  wl_list_for_each(subsurface, &surface->current.subsurfaces_above, current.link) {
    if (!subsurface_tree_create_subsurface(subsurface_tree, subsurface)) goto error_scene_surface;
  }

  subsurface_tree_reconfigure(subsurface_tree);

  wlr_addon_init(&subsurface_tree->scene_addon, &subsurface_tree->tree->node.addons, NULL,
                 &subsurface_tree_addon_impl);

  subsurface_tree->surface_destroy.notify = subsurface_tree_handle_surface_destroy;
  wl_signal_add(&surface->events.destroy, &subsurface_tree->surface_destroy);

  subsurface_tree->surface_commit.notify = subsurface_tree_handle_surface_commit;
  wl_signal_add(&surface->events.commit, &subsurface_tree->surface_commit);

  subsurface_tree->surface_map.notify = subsurface_tree_handle_surface_map;
  wl_signal_add(&surface->events.map, &subsurface_tree->surface_map);

  subsurface_tree->surface_unmap.notify = subsurface_tree_handle_surface_unmap;
  wl_signal_add(&surface->events.unmap, &subsurface_tree->surface_unmap);

  subsurface_tree->surface_new_subsurface.notify = subsurface_tree_handle_surface_new_subsurface;
  wl_signal_add(&surface->events.new_subsurface, &subsurface_tree->surface_new_subsurface);

  rediwm_node_set_enabled(&subsurface_tree->tree->node, surface->mapped);

  return subsurface_tree;

error_scene_surface:
  rediwm_node_destroy(&subsurface_tree->tree->node);
error_surface_tree:
  free(subsurface_tree);
  return NULL;
}

struct rediwm_tree *rediwm_subsurface_tree_create(struct rediwm_tree *parent, struct wlr_surface *surface) {
  struct rediwm_subsurface_tree *subsurface_tree = scene_surface_tree_create(parent, surface);
  if (subsurface_tree == NULL) return NULL;
  return subsurface_tree->tree;
}

static struct rediwm_subsurface_tree *get_subsurface_tree_from_node(struct rediwm_node *node) {
  struct wlr_addon *addon = wlr_addon_find(&node->addons, NULL, &subsurface_tree_addon_impl);
  if (!addon) return NULL;

  struct rediwm_subsurface_tree *tree = wl_container_of(addon, tree, scene_addon);
  return tree;
}

static bool subsurface_tree_set_clip(struct rediwm_node *node, const struct wlr_box *clip) {
  if (node->type != REDIWM_NODE_TREE) return false;

  bool discovered_subsurface_tree = false;
  struct rediwm_subsurface_tree *tree = get_subsurface_tree_from_node(node);
  if (tree) {
    if (tree->parent == NULL) {
      if (clip ? wlr_box_equal(&tree->clip, clip) : wlr_box_empty(&tree->clip)) return true;

      if (clip)
        tree->clip = *clip;
      else
        tree->clip = (struct wlr_box){0};
    }

    discovered_subsurface_tree = true;
    subsurface_tree_reconfigure_clip(tree);
  }

  struct rediwm_tree *scene_tree = (struct rediwm_tree *)node;
  struct rediwm_node *child;
  wl_list_for_each(child, &scene_tree->children, link) {
    discovered_subsurface_tree |= subsurface_tree_set_clip(child, clip);
  }

  return discovered_subsurface_tree;
}

bool rediwm_subsurface_tree_set_clip(struct rediwm_node *node, const struct wlr_box *clip) {
  return subsurface_tree_set_clip(node, clip);
}
