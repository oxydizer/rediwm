// Presentation-only geometry. Source xdg/subsurface nodes are never rewritten.
// wlroots 0.20 ABI, pinned by build.zig.zon (as in glass.c).
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "projection.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/util/addon.h>
#include <wlr/util/log.h>

struct rediwm_projection {
  struct wlr_scene_tree *source, *view;
  struct wlr_scene *scene;
  struct wl_list leaves, groups;
  struct wlr_scene_node *last;
  struct wl_listener new_surface;
  struct wl_list surfaces;
};
// Source top-level subtrees are contiguous in paint order. Moving their
// presentation tree updates wlroots visibility once for the whole window,
// instead of once for every titlebar, border, client and shadow leaf.
struct group {
  struct wl_list link;
  struct rediwm_projection *projection;
  struct wlr_scene_node *source, *last;
  struct wlr_scene_tree *view;
  struct wl_listener destroy;
  struct wlr_addon source_lookup, view_lookup;
  bool seen;
};
// Everything project() last applied to a view node. Nothing else writes to
// non-glass views, so an unchanged state skips a dozen setter calls and an
// opaque-region rebuild per leaf on every sync (every frame after a commit).
struct view_state {
  int x, y, width, height;
  bool enabled, opaque;
  struct wlr_fbox src_box;
  enum wl_output_transform transform;
  float opacity;
  float color[4];
  enum wlr_scale_filter_mode filter_mode;
  enum wlr_color_transfer_function transfer_function;
  enum wlr_color_named_primaries primaries;
  enum wlr_color_encoding color_encoding;
  enum wlr_color_range color_range;
};
// Field by field: this file is built by zig cc, where memcmp() == 0 lowers to
// compiler-rt's bytewise bcmp, which cost more than the setters it skipped.
static bool view_state_equal(const struct view_state *a,
                             const struct view_state *b) {
  return a->x == b->x && a->y == b->y && a->width == b->width &&
         a->height == b->height && a->enabled == b->enabled &&
         a->opaque == b->opaque && a->src_box.x == b->src_box.x &&
         a->src_box.y == b->src_box.y &&
         a->src_box.width == b->src_box.width &&
         a->src_box.height == b->src_box.height &&
         a->transform == b->transform && a->opacity == b->opacity &&
         a->color[0] == b->color[0] && a->color[1] == b->color[1] &&
         a->color[2] == b->color[2] && a->color[3] == b->color[3] &&
         a->filter_mode == b->filter_mode &&
         a->transfer_function == b->transfer_function &&
         a->primaries == b->primaries &&
         a->color_encoding == b->color_encoding &&
         a->color_range == b->color_range;
}
struct leaf {
  struct wl_list link;
  struct rediwm_projection *projection;
  struct wlr_scene_node *source, *view;
  struct wl_listener destroy, commit;
  struct wlr_addon lookup, source_lookup;
  struct wlr_scene_surface *surface;
  bool dirty, seen;
  // Commits can outpace presentation. Keep their union, including empty damage
  // on a rotated buffer; buffer identity is not evidence of changed pixels.
  pixman_region32_t damage;
  bool full_damage;
  // A compositor-owned buffer reported its own damage since the last sync;
  // without a report a replaced buffer damages its whole view.
  bool owned_damage;
  int damage_width, damage_height;
  int width, height;
  struct wlr_buffer *last_buffer;
  // The client buffer whose view lock we told wlroots to ignore, if any.
  struct wlr_client_buffer *marked;
  double zoom;
  struct view_state applied;
  bool has_applied;
};
struct tree_zoom {
  struct wlr_addon addon;
  double scale;
};
static void destroy_tree_zoom(struct wlr_addon *addon) {
  struct tree_zoom *zoom = wl_container_of(addon, zoom, addon);
  wlr_addon_finish(addon);
  free(zoom);
}
static const struct wlr_addon_interface tree_zoom_impl = {
    .name = "rediwm window zoom", .destroy = destroy_tree_zoom};
bool rediwm_projection_set_tree_zoom(struct wlr_scene_node *node, double scale) {
  struct wlr_addon *addon = wlr_addon_find(&node->addons, NULL, &tree_zoom_impl);
  struct tree_zoom *zoom;
  if (addon) {
    zoom = wl_container_of(addon, zoom, addon);
  } else {
    zoom = calloc(1, sizeof(*zoom));
    if (!zoom) return false;
    wlr_addon_init(&zoom->addon, &node->addons, NULL, &tree_zoom_impl);
  }
  zoom->scale = scale;
  return true;
}
struct tree_scale {
  struct wlr_addon addon;
  double factor;
};
static void destroy_tree_scale(struct wlr_addon *addon) {
  struct tree_scale *scale = wl_container_of(addon, scale, addon);
  wlr_addon_finish(addon);
  free(scale);
}
static const struct wlr_addon_interface tree_scale_impl = {
    .name = "rediwm tree scale", .destroy = destroy_tree_scale};
bool rediwm_projection_set_tree_scale(struct wlr_scene_node *node, double factor) {
  if (factor <= 0) return false;
  struct wlr_addon *addon = wlr_addon_find(&node->addons, NULL, &tree_scale_impl);
  struct tree_scale *scale;
  if (addon) {
    scale = wl_container_of(addon, scale, addon);
  } else {
    scale = calloc(1, sizeof(*scale));
    if (!scale) return false;
    wlr_addon_init(&scale->addon, &node->addons, NULL, &tree_scale_impl);
  }
  scale->factor = factor;
  return true;
}
static const struct wlr_addon_interface lookup_impl, source_lookup_impl;
static const struct wlr_addon_interface group_source_impl, group_view_impl;
struct watched_surface {
  struct rediwm_projection *projection;
  struct wl_list link;
  struct wl_listener commit, destroy;
};
static void schedule(struct rediwm_projection *p) {
  struct wlr_scene_output *out;
  wl_list_for_each(out, &p->scene->outputs, link)
      wlr_output_schedule_frame(out->output);
}
static void finish_group(struct group *g) {
  wl_list_remove(&g->destroy.link);
  wl_list_remove(&g->link);
  wlr_addon_finish(&g->source_lookup);
  wlr_addon_finish(&g->view_lookup);
}
static void destroy_group(struct group *g) {
  finish_group(g);
  // Destroying the view also releases any remaining leaf adapters. This is
  // safe if the source tree is destroyed before its children or vice versa.
  wlr_scene_node_destroy(&g->view->node);
  free(g);
}
static void group_source_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct group *g = wl_container_of(listener, g, destroy);
  schedule(g->projection);
  destroy_group(g);
}
static void group_source_addon_destroy(struct wlr_addon *addon) {
  struct group *g = wl_container_of(addon, g, source_lookup);
  destroy_group(g);
}
static void group_view_destroy(struct wlr_addon *addon) {
  struct group *g = wl_container_of(addon, g, view_lookup);
  finish_group(g);
  free(g);
}
static const struct wlr_addon_interface group_source_impl = {
    .name = "rediwm projection group source", .destroy = group_source_addon_destroy};
static const struct wlr_addon_interface group_view_impl = {
    .name = "rediwm projection group", .destroy = group_view_destroy};
static struct group *get_group(struct rediwm_projection *p,
                               struct wlr_scene_node *source) {
  struct wlr_addon *addon = wlr_addon_find(&source->addons, p, &group_source_impl);
  struct group *g;
  if (addon)
    return wl_container_of(addon, g, source_lookup);
  g = calloc(1, sizeof(*g));
  if (!g)
    return NULL;
  g->view = wlr_scene_tree_create(p->view);
  if (!g->view) {
    free(g);
    return NULL;
  }
  g->source = source;
  g->projection = p;
  wl_list_insert(&p->groups, &g->link);
  wlr_addon_init(&g->source_lookup, &source->addons, p, &group_source_impl);
  wlr_addon_init(&g->view_lookup, &g->view->node.addons, NULL, &group_view_impl);
  g->destroy.notify = group_source_destroy;
  wl_signal_add(&source->events.destroy, &g->destroy);
  return g;
}
static struct leaf *lookup(struct wlr_scene_node *node) {
  struct wlr_addon *addon = wlr_addon_find(&node->addons, NULL, &lookup_impl);
  if (!addon)
    return NULL;
  struct leaf *l = wl_container_of(addon, l, lookup);
  return l;
}
struct wlr_scene_node *rediwm_projection_source(struct wlr_scene_node *node) {
  struct leaf *l = lookup(node);
  return l ? l->source : node;
}
double rediwm_projection_node_zoom(struct wlr_scene_node *node) {
  struct leaf *l = lookup(node);
  return l ? l->zoom : 1;
}
struct wlr_scene_node *rediwm_projection_node(struct rediwm_projection *p,
                                              struct wlr_scene_node *source) {
  if (!p)
    return source;
  struct wlr_addon *addon =
      wlr_addon_find(&source->addons, p, &source_lookup_impl);
  if (!addon)
    return NULL;
  struct leaf *l = wl_container_of(addon, l, source_lookup);
  return l->view;
}
static void move_listener(struct wl_listener *listener,
                          struct wl_signal *signal) {
  wl_list_remove(&listener->link);
  wl_signal_add(signal, listener);
}
// Keep wlroots' own surface lifecycle implementation, but drive it exclusively
// from displayed buffers. Source buffers stay under a disabled tree in the same
// scene, so the handlers retain the correct scene/output/color-manager context.
static void route_surface(struct leaf *l, struct wlr_scene_buffer *buffer) {
  if (!l->surface)
    return;
  move_listener(&l->surface->private.outputs_update,
                &buffer->events.outputs_update);
  move_listener(&l->surface->private.output_sample,
                &buffer->events.output_sample);
  move_listener(&l->surface->private.frame_done, &buffer->events.frame_done);
}
// wlr_client_buffer_apply_damage updates a shm client's texture in place only
// when no lock but the surface's is outstanding; otherwise every commit
// allocates a new texture and uploads the whole buffer. wlr_scene marks its
// own surface-node lock as ignorable for that reason. The view holds a second
// lock and needs the same mark, which is safe for the same reason: the view is
// synchronized from the source before every output frame. Single-pixel
// buffers are excluded because wlroots draws them from a cached colour.
static void unmark_view_buffer(struct leaf *l) {
  if (!l->marked)
    return;
  struct wlr_scene_buffer *v = wlr_scene_buffer_from_node(l->view);
  if (v->buffer == &l->marked->base && l->marked->private.n_ignore_locks > 0)
    l->marked->private.n_ignore_locks--;
  l->marked = NULL;
}
static void mark_view_buffer(struct leaf *l, struct wlr_buffer *backing) {
  struct wlr_client_buffer *client =
      backing ? wlr_client_buffer_get(backing) : NULL;
  if (!client || !l->surface || l->surface->surface->buffer != client)
    return;
  if (client->source &&
      wlr_single_pixel_buffer_v1_try_from_buffer(client->source))
    return;
  client->private.n_ignore_locks++;
  l->marked = client;
}
static void destroy_leaf(struct leaf *l) {
  unmark_view_buffer(l);
  route_surface(l, l->surface ? l->surface->buffer : NULL);
  wl_list_remove(&l->commit.link);
  wl_list_remove(&l->destroy.link);
  wl_list_remove(&l->link);
  wlr_addon_finish(&l->source_lookup);
  wlr_addon_finish(&l->lookup);
  wlr_scene_node_destroy(l->view);
  pixman_region32_fini(&l->damage);
  free(l);
}
static void source_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct leaf *l = wl_container_of(listener, l, destroy);
  schedule(l->projection);
  destroy_leaf(l);
}
static void view_destroy(struct wlr_addon *addon) {
  // The adapter is explicitly destroyed before its presentation tree.
  struct leaf *l = wl_container_of(addon, l, lookup);
  // Addons finish before wlroots unlocks the view's buffer.
  unmark_view_buffer(l);
  route_surface(l, l->surface ? l->surface->buffer : NULL);
  wl_list_remove(&l->commit.link);
  wl_list_remove(&l->destroy.link);
  wl_list_remove(&l->link);
  wlr_addon_finish(&l->source_lookup);
  wlr_addon_finish(addon);
  pixman_region32_fini(&l->damage);
  free(l);
}
static void source_addon_destroy(struct wlr_addon *addon) {
  struct leaf *l = wl_container_of(addon, l, source_lookup);
  destroy_leaf(l);
}
static const struct wlr_addon_interface source_lookup_impl = {
    .name = "rediwm projection source", .destroy = source_addon_destroy};
static const struct wlr_addon_interface lookup_impl = {
    .name = "rediwm projection", .destroy = view_destroy};
bool rediwm_surface_state_remapped(const struct wlr_surface_state *state) {
  // wl_surface before v5 sets OFFSET on every attach, even attach(buffer, 0, 0),
  // so only a nonzero delta is a real change. GTK3, Xwayland and other v4
  // clients would otherwise fully damage the surface on every frame.
  return (state->committed & (WLR_SURFACE_STATE_TRANSFORM |
                              WLR_SURFACE_STATE_SCALE |
                              WLR_SURFACE_STATE_VIEWPORT)) ||
         ((state->committed & WLR_SURFACE_STATE_OFFSET) &&
          (state->dx || state->dy));
}
static void committed(struct wl_listener *listener, void *data) {
  (void)data;
  struct leaf *l = wl_container_of(listener, l, commit);
  struct wlr_surface *surface = l->surface->surface;
  const struct wlr_surface_state *state = &surface->current;
  // Regions from different buffer mappings cannot safely be combined. A full
  // repaint also covers a mapping changed and restored between presentations.
  if (state->buffer_width != l->damage_width ||
      state->buffer_height != l->damage_height ||
      rediwm_surface_state_remapped(state))
    l->full_damage = true;
  l->damage_width = state->buffer_width;
  l->damage_height = state->buffer_height;
  if (!l->full_damage &&
      !pixman_region32_union(&l->damage, &l->damage, &surface->buffer_damage))
    l->full_damage = true;
  l->dirty = true;
  schedule(l->projection);
}
static bool accepts(struct wlr_scene_buffer *buffer, double *x, double *y) {
  struct leaf *l = lookup(&buffer->node);
  if (!l || buffer->dst_width <= 0 || buffer->dst_height <= 0)
    return false;
  *x *= (double)l->width / buffer->dst_width;
  *y *= (double)l->height / buffer->dst_height;
  struct wlr_scene_buffer *source = wlr_scene_buffer_from_node(l->source);
  return !source->point_accepts_input ||
         source->point_accepts_input(source, x, y);
}
static struct leaf *get_leaf(struct rediwm_projection *p,
                             struct wlr_scene_node *source) {
  struct wlr_addon *addon =
      wlr_addon_find(&source->addons, p, &source_lookup_impl);
  struct leaf *l;
  if (addon)
    return wl_container_of(addon, l, source_lookup);
  l = calloc(1, sizeof(*l));
  if (!l)
    return NULL;
  l->source = source;
  l->projection = p;
  l->dirty = true;
  l->full_damage = true;
  pixman_region32_init(&l->damage);
  wl_list_init(&l->commit.link);
  if (source->type == WLR_SCENE_NODE_RECT) {
    struct wlr_scene_rect *rect = wlr_scene_rect_from_node(source);
    struct wlr_scene_rect *view =
        wlr_scene_rect_create(p->view, 0, 0, rect->color);
    if (view)
      l->view = &view->node;
  } else {
    struct wlr_scene_buffer *view = wlr_scene_buffer_create(p->view, NULL);
    if (view)
      l->view = &view->node;
  }
  if (!l->view) {
    pixman_region32_fini(&l->damage);
    free(l);
    return NULL;
  }
  wl_list_insert(&p->leaves, &l->link);
  wlr_addon_init(&l->source_lookup, &source->addons, p, &source_lookup_impl);
  wlr_addon_init(&l->lookup, &l->view->addons, NULL, &lookup_impl);
  l->destroy.notify = source_destroy;
  wl_signal_add(&source->events.destroy, &l->destroy);
  if (source->type == WLR_SCENE_NODE_BUFFER) {
    struct wlr_scene_buffer *buffer = wlr_scene_buffer_from_node(source);
    struct wlr_scene_buffer *view = wlr_scene_buffer_from_node(l->view);
    view->point_accepts_input = accepts;
    l->surface = wlr_scene_surface_try_from_buffer(buffer);
    if (l->surface) {
      l->damage_width = l->surface->surface->current.buffer_width;
      l->damage_height = l->surface->surface->current.buffer_height;
      route_surface(l, view);
      l->commit.notify = committed;
      wl_signal_add(&l->surface->surface->events.commit, &l->commit);
    }
  }
  return l;
}
// Glass writes its own projected buffers after this synchronization pass.
extern bool rediwm_glass_is_effect_node(struct wlr_scene_node *node);
static void project(struct rediwm_projection *p, struct group *g,
                    struct wlr_scene_node *node,
                    double x, double y, bool enabled, double z, double tx,
                    double ty) {
  x += node->x;
  y += node->y;
  enabled = enabled && node->enabled;
  if (node->type == WLR_SCENE_NODE_TREE) {
    struct wlr_addon *addon = wlr_addon_find(&node->addons, NULL, &tree_zoom_impl);
    if (addon) {
      struct tree_zoom *zoom = wl_container_of(addon, zoom, addon);
      // Window zoom composes with the camera, around the frame origin.
      double z_prime = z * zoom->scale;
      tx += (z - z_prime) * x;
      ty += (z - z_prime) * y;
      z = z_prime;
    }
    struct wlr_addon *scale_addon = wlr_addon_find(&node->addons, NULL, &tree_scale_impl);
    if (scale_addon) {
      struct tree_scale *scale = wl_container_of(scale_addon, scale, addon);
      double z_prime = z * scale->factor;
      tx += (z - z_prime) * x;
      ty += (z - z_prime) * y;
      z = z_prime;
    }
    struct wlr_scene_node *child;
    wl_list_for_each(child, &wlr_scene_tree_from_node(node)->children, link)
        project(p, g, child, x, y, enabled, z, tx, ty);
    return;
  }
  struct leaf *l = get_leaf(p, node);
  if (!l) {
    wlr_log(WLR_ERROR, "zoom: cannot allocate presentation node");
    return;
  }
  l->seen = true;
  if (l->view->parent != g->view)
    wlr_scene_node_reparent(l->view, g->view);
  l->zoom = z;
  bool glass = rediwm_glass_is_effect_node(node);
  if (node->type == WLR_SCENE_NODE_RECT) {
    struct wlr_scene_rect *r = wlr_scene_rect_from_node(node);
    l->width = r->width;
    l->height = r->height;
  } else {
    struct wlr_scene_buffer *b = wlr_scene_buffer_from_node(node);
    l->width = b->dst_width;
    l->height = b->dst_height;
    if (!l->width || !l->height) {
      l->width = b->private.buffer_width;
      l->height = b->private.buffer_height;
      if (b->transform & 1) {
        int tmp = l->width;
        l->width = l->height;
        l->height = tmp;
      }
    }
  }
  int px = lround(z * x + tx), py = lround(z * y + ty);
  int width = lround(z * (x + l->width) + tx) - px;
  int height = lround(z * (y + l->height) + ty) - py;
  struct view_state next = {0};
  // Round in global coordinates first. Rounding a scaled local offset would
  // change pixels at fractional zoom and when crossing negative origins.
  next.x = px - g->view->node.x;
  next.y = py - g->view->node.y;
  next.width = width;
  next.height = height;
  next.enabled = enabled && width > 0 && height > 0;
  // Flattened leaves within each group retain the source's paint order.
  // Reorder only when necessary, avoiding damage from no-op syncs.
  struct wlr_scene_node *previous = g->last;
  if (previous) {
    if (l->view->link.prev != &previous->link)
      wlr_scene_node_place_above(l->view, previous);
  } else if (l->view->link.prev != &g->view->children) {
    wlr_scene_node_lower_to_bottom(l->view);
  }
  g->last = l->view;
  if (node->type == WLR_SCENE_NODE_RECT) {
    struct wlr_scene_rect *r = wlr_scene_rect_from_node(node);
    memcpy(next.color, r->color, sizeof(next.color));
    if (!l->has_applied || !view_state_equal(&next, &l->applied)) {
      struct wlr_scene_rect *v = wlr_scene_rect_from_node(l->view);
      wlr_scene_node_set_position(l->view, next.x, next.y);
      wlr_scene_node_set_enabled(l->view, next.enabled);
      wlr_scene_rect_set_size(v, width > 0 ? width : 0, height > 0 ? height : 0);
      wlr_scene_rect_set_color(v, r->color);
      l->applied = next;
      l->has_applied = true;
    }
  } else if (!glass) {
    struct wlr_scene_buffer *b = wlr_scene_buffer_from_node(node);
    struct wlr_scene_buffer *v = wlr_scene_buffer_from_node(l->view);
    struct wlr_buffer *backing = b->buffer;
    // wlroots may cache a single-pixel buffer as a color and release the
    // source node's buffer reference. The mapped surface still owns it.
    if (!backing && l->surface && l->surface->surface->buffer)
      backing = &l->surface->surface->buffer->base;
    if (l->dirty || l->last_buffer != backing) {
      struct wlr_scene_buffer_set_buffer_options options = {
          .damage = backing && (l->surface || l->owned_damage) &&
                            l->dirty && !l->full_damage
                        ? &l->damage : NULL,
          .wait_timeline = b->private.wait_timeline,
          .wait_point = b->private.wait_point,
      };
      unmark_view_buffer(l);
      wlr_scene_buffer_set_buffer_with_options(v, backing, &options);
      mark_view_buffer(l, backing);
      l->last_buffer = backing;
    }
    next.src_box = b->src_box;
    next.transform = b->transform;
    next.opacity = b->opacity;
    next.filter_mode = z == 1 ? b->filter_mode : WLR_SCALE_FILTER_BILINEAR;
    next.transfer_function = b->transfer_function;
    next.primaries = b->primaries;
    next.color_encoding = b->color_encoding;
    next.color_range = b->color_range;
    // Read after the buffer update above, which can change it.
    next.opaque = v->private.buffer_is_opaque;
    if (!l->has_applied || !view_state_equal(&next, &l->applied)) {
      wlr_scene_node_set_position(l->view, next.x, next.y);
      wlr_scene_node_set_enabled(l->view, next.enabled);
      wlr_scene_buffer_set_source_box(v, &b->src_box);
      wlr_scene_buffer_set_dest_size(v, width > 0 ? width : 1,
                                     height > 0 ? height : 1);
      wlr_scene_buffer_set_transform(v, b->transform);
      wlr_scene_buffer_set_opacity(v, b->opacity);
      wlr_scene_buffer_set_filter_mode(v, next.filter_mode);
      wlr_scene_buffer_set_transfer_function(v, b->transfer_function);
      wlr_scene_buffer_set_primaries(v, b->primaries);
      wlr_scene_buffer_set_color_encoding(v, b->color_encoding);
      wlr_scene_buffer_set_color_range(v, b->color_range);
      // Mirror intrinsic opacity into the explicit region too. wlroots updates
      // buffer_is_opaque on buffer replacement without recomputing visibility
      // when the size is unchanged. Changing this region invalidates occlusion,
      // so an opaque -> translucent single-pixel buffer reveals the nodes below.
      // Keep partial client opaque regions conservatively empty under projection.
      pixman_region32_t opaque;
      pixman_region32_init(&opaque);
      if (next.opaque && width > 0 && height > 0)
        pixman_region32_union_rect(&opaque, &opaque, 0, 0, width, height);
      wlr_scene_buffer_set_opaque_region(v, &opaque);
      pixman_region32_fini(&opaque);
      l->applied = next;
      l->has_applied = true;
    }
  }
  l->dirty = false;
  l->full_damage = false;
  l->owned_damage = false;
  pixman_region32_clear(&l->damage);
}
// Not in 0.20's public headers, but exported; see
// rediwm_projection_present_owned.
struct wlr_client_buffer *wlr_client_buffer_create(struct wlr_buffer *buffer,
                                                   struct wlr_renderer *renderer);
bool wlr_client_buffer_apply_damage(struct wlr_client_buffer *client_buffer,
                                    struct wlr_buffer *next,
                                    const pixman_region32_t *damage);
// A plain buffer replaced on a scene node gets a new texture and a full
// upload. Wrapping it in a client buffer instead lets the next frame's
// damage update that texture in place, as for shm clients. The source node's
// lock is marked ignorable (like wlr_scene's own surface lock): the view is
// synchronized from the source before every frame and told the damage.
bool rediwm_projection_present_owned(struct rediwm_projection *p,
                                     struct wlr_scene_buffer *source,
                                     struct wlr_renderer *renderer,
                                     struct wlr_buffer *buffer,
                                     const pixman_region32_t *damage) {
  struct wlr_client_buffer *current =
      source->buffer ? wlr_client_buffer_get(source->buffer) : NULL;
  bool same_size = current && current->base.width == buffer->width &&
                   current->base.height == buffer->height;
  if (same_size) {
    // A full repaint still fits the existing texture.
    pixman_region32_t whole;
    pixman_region32_init_rect(&whole, 0, 0, buffer->width, buffer->height);
    bool updated = wlr_client_buffer_apply_damage(current, buffer,
                                                  damage ? damage : &whole);
    pixman_region32_fini(&whole);
    if (updated) {
      rediwm_projection_damage_buffer(p, &source->node, damage);
      return true;
    }
  }
  struct wlr_client_buffer *next = wlr_client_buffer_create(buffer, renderer);
  if (!next) {
    // Without a texture wrapper, fall back to the plain buffer.
    if (current)
      current->private.n_ignore_locks--;
    wlr_scene_buffer_set_buffer(source, buffer);
    rediwm_projection_damage_buffer(p, &source->node, NULL);
    return false;
  }
  if (current)
    current->private.n_ignore_locks--;
  wlr_scene_buffer_set_buffer(source, &next->base);
  next->private.n_ignore_locks++;
  // The node's lock keeps it alive; drop the one creation handed us.
  wlr_buffer_unlock(&next->base);
  // Renderers without in-place updates (pixman) land here every frame. The
  // replacement differs from its predecessor only where `damage` says, so a
  // same-sized replacement keeps precise output damage.
  rediwm_projection_damage_buffer(p, &source->node, same_size ? damage : NULL);
  return false;
}
void rediwm_projection_damage_buffer(struct rediwm_projection *p,
                                     struct wlr_scene_node *source,
                                     const pixman_region32_t *damage) {
  struct wlr_addon *addon =
      wlr_addon_find(&source->addons, p, &source_lookup_impl);
  // A leaf's first projection applies its whole buffer anyway.
  if (!addon)
    return;
  struct leaf *l = wl_container_of(addon, l, source_lookup);
  if (l->surface)
    return;
  if (!damage ||
      !pixman_region32_union(&l->damage, &l->damage, damage))
    l->full_damage = true;
  l->owned_damage = true;
  l->dirty = true;
  schedule(p);
}
struct rediwm_projection *
rediwm_projection_create(struct wlr_scene_tree *source,
                         struct wlr_scene_tree *view, struct wlr_scene *scene) {
  struct rediwm_projection *p = calloc(1, sizeof(*p));
  if (!p)
    return NULL;
  p->source = source;
  p->view = view;
  p->scene = scene;
  wl_list_init(&p->leaves);
  wl_list_init(&p->groups);
  wl_list_init(&p->surfaces);
  wl_list_init(&p->new_surface.link);
  wlr_scene_node_set_enabled(&source->node, false);
  return p;
}
void rediwm_projection_sync_fixed(struct rediwm_projection *p, double z, double cx,
                            double cy, double ox, double oy,
                            struct wlr_scene_tree *fixed) {
  if (!p)
    return;
  p->last = NULL;
  struct leaf *l;
  wl_list_for_each(l, &p->leaves, link) l->seen = false;
  struct group *g;
  wl_list_for_each(g, &p->groups, link) g->seen = false;
  struct wlr_scene_node *node;
  double tx = ox * (1 - z) - z * cx, ty = oy * (1 - z) - z * cy;
  wl_list_for_each(node, &p->source->children, link) {
    g = get_group(p, node);
    if (!g) {
      wlr_log(WLR_ERROR, "zoom: cannot allocate presentation group");
      continue;
    }
    double gz = fixed && node == &fixed->node ? 1 : z;
    double gx = fixed && node == &fixed->node ? 0 : tx;
    double gy = fixed && node == &fixed->node ? 0 : ty;
    g->seen = true;
    g->last = NULL;
    wlr_scene_node_set_position(&g->view->node, lround(gz * node->x + gx),
                                lround(gz * node->y + gy));
    wlr_scene_node_set_enabled(&g->view->node, node->enabled);
    if (p->last) {
      if (g->view->node.link.prev != &p->last->link)
        wlr_scene_node_place_above(&g->view->node, p->last);
    } else if (g->view->node.link.prev != &p->view->children) {
      wlr_scene_node_lower_to_bottom(&g->view->node);
    }
    p->last = &g->view->node;
    project(p, g, node, 0, 0, true, gz, gx, gy);
  }
  wl_list_for_each(l, &p->leaves, link) if (!l->seen) {
    wlr_scene_node_set_enabled(l->view, false);
    // The cached state no longer describes the view; reapply on return.
    l->has_applied = false;
  }
  wl_list_for_each(g, &p->groups, link) if (!g->seen)
      wlr_scene_node_set_enabled(&g->view->node, false);
}
void rediwm_projection_sync(struct rediwm_projection *p, double z, double cx,
                            double cy, double ox, double oy) {
  rediwm_projection_sync_fixed(p, z, cx, cy, ox, oy, NULL);
}
static void watched_commit(struct wl_listener *listener, void *data) {
  (void)data;
  struct watched_surface *watch = wl_container_of(listener, watch, commit);
  // Covers the first commit of new/desynchronized subsurfaces and popups,
  // before they have presentation leaves of their own.
  schedule(watch->projection);
}
static void watched_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct watched_surface *watch = wl_container_of(listener, watch, destroy);
  wl_list_remove(&watch->commit.link);
  wl_list_remove(&watch->destroy.link);
  wl_list_remove(&watch->link);
  free(watch);
}
static void new_surface(struct wl_listener *listener, void *data) {
  struct rediwm_projection *p = wl_container_of(listener, p, new_surface);
  struct wlr_surface *surface = data;
  struct watched_surface *watch = calloc(1, sizeof(*watch));
  if (!watch) {
    wlr_log(WLR_ERROR, "zoom: cannot watch new surface");
    return;
  }
  watch->projection = p;
  watch->commit.notify = watched_commit;
  watch->destroy.notify = watched_destroy;
  wl_signal_add(&surface->events.commit, &watch->commit);
  wl_signal_add(&surface->events.destroy, &watch->destroy);
  wl_list_insert(&p->surfaces, &watch->link);
}
void rediwm_projection_watch(struct rediwm_projection *p,
                             struct wlr_compositor *compositor) {
  p->new_surface.notify = new_surface;
  wl_signal_add(&compositor->events.new_surface, &p->new_surface);
}
void rediwm_projection_destroy(struct rediwm_projection *p) {
  if (!p)
    return;
  struct leaf *l, *tmp;
  wl_list_for_each_safe(l, tmp, &p->leaves, link) destroy_leaf(l);
  struct group *g, *next_group;
  wl_list_for_each_safe(g, next_group, &p->groups, link) destroy_group(g);
  wl_list_remove(&p->new_surface.link);
  struct watched_surface *watch, *next;
  wl_list_for_each_safe(watch, next, &p->surfaces, link)
      watched_destroy(&watch->destroy, NULL);
  free(p);
}
