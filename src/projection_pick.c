#include "projection_internal.h"

// ---- Hit testing (stage 6 of docs/plans/scene-graph.md) --------------------------
// The topmost node at a layout point, from the graph: the items from the top of the
// paint order down, each tested at the pixels it covers once rounded, then against
// the window's shape and the node's own input rule.
// `only` restricts the pick to the leaves of one top-level subtree.
static bool pick_leaf(struct rediwm_projection *p, const struct group *only, double lx, double ly,
                 struct rediwm_hit *hit) {
  const double px = floor(lx), py = floor(ly);
  for (struct wl_list *gl = p->paint.prev; gl != &p->paint; gl = gl->prev) {
    struct group *g = wl_container_of(gl, g, paint);
    if (!g->enabled || (only && g != only)) continue;
    for (struct wl_list *ll = g->items.prev; ll != &g->items; ll = ll->prev) {
      struct leaf *l = wl_container_of(ll, l, paint);
      const struct rediwm_item *item = &l->item;
      // An effect takes no input, and a leaf with no pixels once rounded is not shown.
      if (!item->enabled || item->kind == REDIWM_ITEM_EFFECT || item->kind == REDIWM_ITEM_RIBBON || l->inert) continue;
      const struct rediwm_snap s = rediwm_edges_snap(item->edges);
      if (s.width <= 0 || s.height <= 0 || px < s.x || px >= s.x + s.width || py < s.y ||
          py >= s.y + s.height)
        continue;
      double x = lx - s.x, y = ly - s.y;
      if (l->source->type == REDIWM_NODE_BUFFER) {
        x *= (double)item->width / s.width;
        y *= (double)item->height / s.height;
        // A window's rounded corners are transparent: a point the shape cuts away
        // goes to what is below. The point is in source units; the shape is in
        // layout space.
        if (item->clip && item->width > 0 && item->height > 0) {
          const struct rediwm_edges *e = &item->edges;
          const double cx = e->x1 + x * (e->x2 - e->x1) / item->width;
          const double cy = e->y1 + y * (e->y2 - e->y1) / item->height;
          if (rediwm_clip_distance(item->clip, cx, cy) > 0) continue;
        }
        struct rediwm_buffer *own = rediwm_buffer_from_node(l->own);
        if (own->point_accepts_input && !own->point_accepts_input(own, &x, &y)) continue;
      }
      *hit = (struct rediwm_hit){.own = l->own, .x = x, .y = y};
      return true;
    }
  }
  return false;
}
bool rediwm_projection_node_at(struct rediwm_projection *p, double lx, double ly,
                               struct rediwm_hit *hit) {
  return pick_leaf(p, NULL, lx, ly, hit);
}
// The topmost leaf of one top-level subtree of a layer (a window's frame tree) at a
// point, whatever lies above it.
bool rediwm_projection_node_at_in(struct rediwm_projection *p, struct rediwm_node *subtree,
                                  double lx, double ly, struct rediwm_hit *hit) {
  struct wlr_addon *addon = wlr_addon_find(&subtree->addons, p, &projection_group_source_impl);
  struct group *g;
  if (!addon) return false;
  g = wl_container_of(addon, g, source_lookup);
  return pick_leaf(p, g, lx, ly, hit);
}
