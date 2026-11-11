// resolve(): source tree -> graph (projection.c has the overview).
#include "projection_internal.h"

// A glass effect covers its target exactly: the box is the target's (same
// parent), and it is shown only with it. The pass draws the blur (stage 5c).
static void effect_geometry(const struct rediwm_node *own, const struct rediwm_glass_info *info,
                            int *x, int *y, int *width, int *height, bool *enabled) {
  const struct rediwm_buffer *t = info->target;
  *x += t->node.x - own->x;
  *y += t->node.y - own->y;
  *enabled = *enabled && t->node.enabled;
  *width = t->dst_width ? t->dst_width : t->buffer_width;
  *height = t->dst_height ? t->dst_height : t->buffer_height;
}

// A clip's size, radii, border or colour changed: its views did not move, so
// nothing else tells wlroots that the corner arcs and the ring need repainting.
// The zone is the frame's rim, as wide as the largest radius plus the border and
// a margin; where the frame is thinner than twice that it is the whole box.
static bool clip_same_shape(const struct rediwm_clip *a, const struct rediwm_clip *b) {
  if (a->edges.x2 - a->edges.x1 != b->edges.x2 - b->edges.x1 ||
      a->edges.y2 - a->edges.y1 != b->edges.y2 - b->edges.y1 || a->border != b->border)
    return false;
  for (int i = 0; i < 4; i++)
    if (a->border_color[i] != b->border_color[i]) return false;
  return rediwm_clip_outline_equal(a, b);
}
// Where the highlight is, as far as it can be seen: a square around its point.
static bool clip_glow_box(const struct rediwm_clip *c, pixman_box32_t *out) {
  if (c->glow_radius <= 0 || c->glow_color[3] <= 0) return false;
  const double reach = c->glow_radius + 1;
  *out = (pixman_box32_t){(int)floor(c->glow_x - reach), (int)floor(c->glow_y - reach),
                          (int)ceil(c->glow_x + reach), (int)ceil(c->glow_y + reach)};
  return true;
}
static bool clip_same_glow(const struct rediwm_clip *a, const struct rediwm_clip *b) {
  if (a->glow_radius != b->glow_radius || a->glow_depth != b->glow_depth) return false;
  if (a->glow_radius <= 0) return true;
  if (a->glow_x != b->glow_x || a->glow_y != b->glow_y) return false;
  for (int i = 0; i < 4; i++)
    if (a->glow_color[i] != b->glow_color[i]) return false;
  return true;
}
// `only` limits the rim to a box (a moved highlight changes nothing else).
static void clip_rim(pixman_region32_t *out, const struct rediwm_clip *c, const pixman_box32_t *only) {
  const struct rediwm_snap f = rediwm_edges_snap(c->edges);
  if (f.width <= 0 || f.height <= 0) return;
  const int inset = (int)ceil(c->inset) + (int)ceil(c->border) + (int)ceil(c->glow_depth) + 2;
  pixman_region32_t rim;
  pixman_region32_init_rect(&rim, f.x, f.y, f.width, f.height);
  if (f.width > 2 * inset && f.height > 2 * inset) {
    pixman_region32_t inner;
    pixman_region32_init_rect(&inner, f.x + inset, f.y + inset, f.width - 2 * inset,
                              f.height - 2 * inset);
    pixman_region32_subtract(&rim, &rim, &inner);
    pixman_region32_fini(&inner);
  }
  if (only) pixman_region32_intersect_rect(&rim, &rim, only->x1, only->y1, only->x2 - only->x1, only->y2 - only->y1);
  pixman_region32_union(out, out, &rim);
  pixman_region32_fini(&rim);
}
static void damage_clip_change(struct rediwm_projection *p, const struct rediwm_clip *before,
                               const struct rediwm_clip *after) {
  pixman_region32_t region;
  pixman_region32_init(&region);
  if (before && after && clip_same_shape(before, after)) {
    // Only the highlight changed: its old and new places.
    pixman_box32_t box;
    if (clip_glow_box(before, &box)) clip_rim(&region, before, &box);
    if (clip_glow_box(after, &box)) clip_rim(&region, after, &box);
  } else {
    if (before) clip_rim(&region, before, NULL);
    if (after) clip_rim(&region, after, NULL);
  }
  pixman_region32_union(&p->pending, &p->pending, &region);
  pixman_region32_fini(&region);
}
// resolve(): source tree -> graph. Writes items, group origins, `seen` flags and
// the paint-order lists; creates adapters for nodes it meets the first time, but
// moves and shows nothing.
// What the walk carries down the tree: where the subtree is, whether it shows and
// takes input, and how it is presented. A tree's own properties are folded in as it
// is entered.
struct walk {
  double x, y;
  bool enabled, inert;
  struct rediwm_xform t;
  const struct rediwm_clip *clip;
  const struct dim *dim;
  const struct rediwm_shadow *shadow;
};
// `here` and `cast` hold the tree's clip and shadow for as long as the walk is below
// it.
static void apply_tree(struct rediwm_projection *p, struct tree_props *props, struct walk *w,
                       struct rediwm_clip *here, struct rediwm_shadow *cast) {
  if (!props) return;
  // Window zoom composes with the camera, around the frame origin.
  if (props->has_zoom) w->t = rediwm_xform_scale_about(w->t, props->zoom, w->x, w->y);
  if (props->has_scale) w->t = rediwm_xform_scale_about(w->t, props->scale, w->x, w->y);
  if (props->unclipped) {
    w->clip = NULL;
    w->dim = NULL;
  }
  if (props->inert) w->inert = true;
  if (props->has_dim) w->dim = &props->dim;
  if (props->has_clip) {
    *here = rediwm_clip_resolve(w->t, w->x, w->y, &props->clip);
    w->clip = here;
    // A hidden window damages nothing; showing it will.
    if (w->enabled && (!props->has_applied || !clip_same_shape(&props->applied, here) ||
                       !clip_same_glow(&props->applied, here)))
      damage_clip_change(p, props->has_applied ? &props->applied : NULL, here);
    props->applied = *here;
    props->has_applied = true;
  } else if (props->has_applied) {
    if (w->enabled) damage_clip_change(p, &props->applied, NULL);
    props->has_applied = false;
  }
  if (props->has_shadow) {
    *cast = rediwm_shadow_resolve(w->t, w->x, w->y, &props->shadow);
    w->shadow = cast;
  }
}
// One leaf into the graph. `node` is the node the pass reads pixels from;
// (x, y) and `enabled` are the leaf's own, from whichever tree placed it.
static void resolve_leaf(struct rediwm_projection *p, struct group *g, struct rediwm_node *node,
                         struct rediwm_node *own, const struct walk *w, double x, double y,
                         bool enabled) {
  // A node keeps its leaf; only a new one leaves this file (projection.c).
  struct leaf *l = node->leaf ? node->leaf : projection_get_leaf(p, node, own);
  if (!l) {
    wlr_log(WLR_ERROR, "zoom: cannot allocate presentation node");
    return;
  }
  l->seen = true;
  if (l->inert != w->inert) l->inert = w->inert;
  if (l->own != own) l->own = own;
  l->group = g;
  // Flattened leaves within each group retain the source's paint order.
  wl_list_insert(g->items.prev, &l->paint);
  struct rediwm_item *item = &l->item;
  item->enabled = enabled;
  item->scale = w->t.scale;
  item->content = (struct rediwm_content){0};
  // Only write what changes: rewriting a NULL over a NULL on every leaf of every
  // window dirties the line for nothing (measured at about 1 ns per leaf).
  if (w->clip) {
    l->clip = *w->clip;
    item->clip = &l->clip;
  } else if (item->clip) {
    item->clip = NULL;
  }
  if (node->type == REDIWM_NODE_RECT) {
    struct rediwm_rect *r = rediwm_rect_from_node(node);
    item->kind = REDIWM_ITEM_RECT;
    item->width = r->width;
    item->height = r->height;
    memcpy(item->content.color, r->color, sizeof(item->content.color));
  } else {
    struct rediwm_buffer *b = rediwm_buffer_from_node(node);
    if (l->intrinsic_kind == REDIWM_ITEM_EFFECT) g->has_effect = true;
    item->kind = l->intrinsic_kind != REDIWM_ITEM_BUFFER ? l->intrinsic_kind
                 : l->surface ? REDIWM_ITEM_SURFACE : REDIWM_ITEM_BUFFER;
    item->width = b->dst_width;
    item->height = b->dst_height;
    if (item->kind == REDIWM_ITEM_EFFECT) {
      struct rediwm_glass_info info;
      int ex = 0, ey = 0;
      if (own && rediwm_glass_effect_info(node, &info))
        effect_geometry(own, &info, &ex, &ey, &item->width, &item->height, &item->enabled);
      x += ex;
      y += ey;
    } else if (!item->width || !item->height) {
      item->width = b->buffer_width;
      item->height = b->buffer_height;
      if (b->transform & 1) {
        int tmp = item->width;
        item->width = item->height;
        item->height = tmp;
      }
    }
    struct rediwm_content *content = &item->content;
    content->src_box = b->src_box;
    memcpy(content->sector_rect, b->sector_rect, sizeof(content->sector_rect));
    content->transform = b->transform;
    content->opacity = b->opacity;
    content->filter_mode = rediwm_filter_at_scale(w->t.scale, b->filter_mode);
    content->transfer_function = b->transfer_function;
    content->primaries = b->primaries;
    content->color_encoding = b->color_encoding;
    content->color_range = b->color_range;
  }
  if (w->dim) {
    item->content.dim_brightness = w->dim->brightness;
    item->content.dim_saturation = w->dim->saturation;
  }
  if (w->shadow && node->type == REDIWM_NODE_BUFFER && item->kind != REDIWM_ITEM_RIBBON) {
    item->kind = REDIWM_ITEM_SHADOW;
    l->shadow = *w->shadow;
    item->shadow = &l->shadow;
  } else if (item->kind != REDIWM_ITEM_RIBBON && item->shadow) {
    item->shadow = NULL;
  }
  item->edges = rediwm_xform_rect(w->t, x, y, item->width, item->height);
}
static void resolve_own(struct rediwm_projection *p, struct group *g, struct rediwm_node *node,
                        const struct walk *parent) {
  const double x = parent->x + node->x, y = parent->y + node->y;
  const bool enabled = parent->enabled && node->enabled;
  switch (node->type) {
  case REDIWM_NODE_RECT:
    resolve_leaf(p, g, node, node, parent, x, y, enabled);
    return;
  case REDIWM_NODE_BUFFER:
    resolve_leaf(p, g, node, node, parent, x, y, enabled);
    return;
  case REDIWM_NODE_TREE: {
    struct walk w = *parent;
    w.x = x;
    w.y = y;
    w.enabled = enabled;
    struct rediwm_clip here;
    struct rediwm_shadow cast;
    apply_tree(p, tree_props_find(&node->addons, &node->props), &w, &here, &cast);
    struct rediwm_node *child;
    wl_list_for_each(child, &((struct rediwm_tree *)node)->children, link)
        resolve_own(p, g, child, &w);
    return;
  }
  }
}
// Source tree -> graph. Every adapter is detached from the paint lists first, so
// the lists hold exactly what this pass reaches, in source paint order.
void projection_resolve(struct rediwm_projection *p, double z, double cx, double cy,
                    double ox, double oy, struct rediwm_tree *fixed, bool full) {
  struct leaf *l;
  struct group *g;
  // A full pass walks every group; otherwise only the marked ones are, and the rest
  // keep the leaves and items they had.
  if (full) {
    wl_list_for_each(l, &p->leaves, link) {
      l->seen = false;
      detach(&l->paint);
    }
  }
  wl_list_for_each(g, &p->groups, link) {
    g->seen = false;
    g->touched = false;
    detach(&g->paint);
  }
  const struct rediwm_xform camera = rediwm_xform_camera(z, cx, cy, ox, oy);
  const struct rediwm_xform identity = {1, 0, 0};
  struct rediwm_node *layer;
  wl_list_for_each(layer, &p->own->tree.children, link) {
    if (layer->type != REDIWM_NODE_TREE) continue;
    const bool world = layer == &p->world->node;
    // The world is resolved from its children, ignoring its own place and state; any
    // other layer is a tree like the rest and hides what it holds when disabled.
    const struct walk base = {.x = world ? 0 : layer->x, .y = world ? 0 : layer->y,
                              .enabled = world || layer->enabled, .t = world ? camera : identity};
    struct rediwm_node *node;
    wl_list_for_each(node, &((struct rediwm_tree *)layer)->children, link) {
      g = projection_get_group(p, node);
      if (!g) {
        wlr_log(WLR_ERROR, "zoom: cannot allocate presentation group");
        continue;
      }
      g->seen = true;
      g->enabled = base.enabled && node->enabled;
      wl_list_insert(p->paint.prev, &g->paint);
      if (!full && g->resolved && !g->dirty && !g->has_effect) continue;
      if (!full) {
        struct leaf *next;
        wl_list_for_each_safe(l, next, &g->items, paint) {
          l->seen = false;
          detach(&l->paint);
        }
      }
      struct walk w = base;
      // The fixed subtree is laid out as is; everything else follows the camera.
      if (world && fixed && node == &fixed->node) w.t = identity;
      g->resolved = true;
      g->dirty = false;
      g->touched = true;
      g->has_effect = false;
      resolve_own(p, g, node, &w);
    }
  }
}
