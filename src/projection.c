// Presentation-only geometry. Source xdg/subsurface nodes are never rewritten.
// wlroots 0.20 ABI, pinned by build.zig.zon (as in glass.c).
#include "projection_internal.h"

// Two halves, joined by the typed graph of scene_graph.h. resolve() walks the
// source tree and writes `item`s and group origins, in paint order, into the
// projection's lists (projection_internal.h). present() reads only that graph
// (and the content the source still owns: buffers and their damage), rounds, and
// turns what changed into damage events and screen damage. The graph is the one
// place geometry is computed; present() may not derive any of its own. The output
// pass, hit testing and the surface feedback all read the graph too: there is no
// second tree of the world.
// The parts: this file holds the adapters' lifecycle, damage events and the
// sync; projection_props.c the tree properties, projection_resolve.c resolve(),
// projection_present.c present(), projection_pass.c what the output pass reads
// and reports, projection_pick.c hit testing. Shared types and helpers are in
// projection_internal.h.
// The compositor has one projection; setters on nodes inside a client's subtree, which
// cannot reach it through a scene, tell it directly.
static struct rediwm_projection *current;
static const struct wlr_addon_interface source_lookup_impl;
static void apply_damage(struct rediwm_projection *p);
static void destroy_group(struct group *g) {
  // What the window's leaves showed is damaged at once, as a node going away was
  // for wlroots: a frame built before the next sync (a capture) must see it. The
  // leaves are destroyed with their nodes, after this group, and only ever touch
  // the projection.
  struct leaf *l, *next;
  wl_list_for_each_safe(l, next, &g->items, paint) {
    forget_shown(l);
    projection_damage_shadow(l, false, (struct rediwm_snap){0});
    detach(&l->paint);
  }
  apply_damage(g->projection);
  wl_list_remove(&g->paint);
  wl_list_remove(&g->destroy.link);
  wl_list_remove(&g->link);
  if (g->source->group == g) g->source->group = NULL;
  wlr_addon_finish(&g->source_lookup);
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
const struct wlr_addon_interface projection_group_source_impl = {
    .name = "rediwm projection group source", .destroy = group_source_addon_destroy};
struct group *projection_get_group(struct rediwm_projection *p,
                               struct rediwm_node *source) {
  struct group *g = source->group;
  if (g)
    return g;
  g = calloc(1, sizeof(*g));
  if (!g)
    return NULL;
  g->source = source;
  g->projection = p;
  wl_list_init(&g->paint);
  wl_list_init(&g->items);
  wl_list_insert(&p->groups, &g->link);
  wlr_addon_init(&g->source_lookup, &source->addons, p, &projection_group_source_impl);
  source->group = g;
  g->destroy.notify = group_source_destroy;
  wl_signal_add(&source->events.destroy, &g->destroy);
  return g;
}
bool rediwm_projection_damage_events(struct rediwm_projection *p, uint64_t *cursor,
                                     rediwm_damage_event_iterator fn, void *data) {
  const uint64_t end = p->next_event ? p->next_event : 1;
  const uint64_t oldest = end > DAMAGE_EVENTS ? end - DAMAGE_EVENTS : 1;
  bool complete = *cursor >= oldest;
  for (uint64_t seq = complete ? *cursor : oldest; seq < end; seq++)
    fn(&p->events[seq % DAMAGE_EVENTS], data);
  *cursor = end;
  return complete;
}
uint64_t rediwm_projection_damage_cursor(struct rediwm_projection *p) {
  return p->next_event ? p->next_event : 1;
}
static void destroy_leaf(struct leaf *l) {
  forget_shown(l);
  projection_damage_shadow(l, false, (struct rediwm_snap){0});
  // A node going away damaged the screen at once, and a frame built before the
  // next sync (a capture) must see it.
  apply_damage(l->projection);
  projection_free_feedback(l);
  wl_list_remove(&l->commit.link);
  wl_list_remove(&l->destroy.link);
  wl_list_remove(&l->link);
  wl_list_remove(&l->paint);
  if (l->source->leaf == l) l->source->leaf = NULL;
  wlr_addon_finish(&l->source_lookup);
  pixman_region32_fini(&l->damage);
  pixman_region32_fini(&l->visible);
  free(l);
}
static void source_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct leaf *l = wl_container_of(listener, l, destroy);
  schedule(l->projection);
  destroy_leaf(l);
}
static void source_addon_destroy(struct wlr_addon *addon) {
  struct leaf *l = wl_container_of(addon, l, source_lookup);
  destroy_leaf(l);
}
static const struct wlr_addon_interface source_lookup_impl = {
    .name = "rediwm projection source", .destroy = source_addon_destroy};
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
  // A commit with no new content (a client only asking for a frame callback) leaves
  // the leaf as it is; geometry and regions reach it through the node setters.
  if (!(state->committed & WLR_SURFACE_STATE_BUFFER) &&
      !pixman_region32_not_empty(&surface->buffer_damage) && !rediwm_surface_state_remapped(state))
    return;
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
  mark_group(l->projection, l->group);
  schedule(l->projection);
}
struct leaf *projection_get_leaf(struct rediwm_projection *p, struct rediwm_node *source,
                             struct rediwm_node *own) {
  // A node's leaf is kept on the node.
  if (source->leaf)
    return source->leaf;
  struct leaf *l = calloc(1, sizeof(*l));
  if (!l)
    return NULL;
  l->source = source;
  l->own = own;
  l->projection = p;
  l->item.id = ++p->next_leaf_id;
  l->dirty = true;
  l->full_damage = true;
  pixman_region32_init(&l->damage);
  pixman_region32_init(&l->visible);
  wl_list_init(&l->commit.link);
  wl_list_init(&l->paint);
  wl_list_insert(&p->leaves, &l->link);
  wlr_addon_init(&l->source_lookup, &source->addons, p, &source_lookup_impl);
  source->leaf = l;
  if (source->type == REDIWM_NODE_BUFFER) {
    l->item.ribbon = rediwm_ribbon_get(source);
    l->intrinsic_kind = l->item.ribbon ? REDIWM_ITEM_RIBBON :
        rediwm_glass_is_effect_node(source) ? REDIWM_ITEM_EFFECT : REDIWM_ITEM_BUFFER;
  }
  l->destroy.notify = source_destroy;
  wl_signal_add(&source->events.destroy, &l->destroy);
  if (source->type == REDIWM_NODE_BUFFER) {
    l->surface = rediwm_buffer_from_node(own)->surface;
    if (l->surface) {
      l->damage_width = l->surface->surface->current.buffer_width;
      l->damage_height = l->surface->surface->current.buffer_height;
      l->feedback = calloc(1, sizeof(*l->feedback));
      if (l->feedback) {
        l->feedback->leaf = l;
        wl_list_insert(&p->feedback, &l->feedback->link);
      }
      l->commit.notify = committed;
      wl_signal_add(&l->surface->surface->events.commit, &l->commit);
    }
  }
  return l;
}
// The group a node belongs to: the child of a layer it hangs under (root 0, layer 1,
// group 2), or NULL for the root and the layers, and for a node not yet grouped.
static struct group *group_of(struct rediwm_node *node) {
  int depth = 0;
  for (struct rediwm_node *n = node; n->parent; n = &n->parent->node) depth++;
  if (depth < 2) return NULL;
  for (; depth > 2; depth--) node = &node->parent->node;
  return node->group;
}
static void scene_changed(void *data, struct rediwm_node *node, bool structural) {
  struct rediwm_projection *p = data;
  if (structural || !node) mark_all(p);
  else mark_group(p, group_of(node));
  schedule(p);
}
static void buffer_given(void *data, struct rediwm_buffer *b, const pixman_region32_t *damage) {
  rediwm_projection_damage_buffer(data, &b->node, damage);
}
struct rediwm_projection *rediwm_projection_create(struct rediwm_scene *own, struct rediwm_tree *world,
                                                   struct rediwm_scene_outputs *outputs) {
  struct rediwm_projection *p = calloc(1, sizeof(*p));
  if (!p)
    return NULL;
  p->own = own;
  p->world = world;
  p->outputs = outputs;
  wl_list_init(&p->leaves);
  wl_list_init(&p->groups);
  wl_list_init(&p->paint);
  wl_list_init(&p->surfaces);
  wl_list_init(&p->feedback);
  wl_list_init(&p->new_surface.link);
  pixman_region32_init(&p->pending);
  // Every change to the tree asks for a frame; the next sync finds what moved.
  current = p;
  own->changed = scene_changed;
  own->buffer_damaged = buffer_given;
  own->changed_data = p;
  return p;
}
static void apply_damage(struct rediwm_projection *p) {
  if (pixman_region32_not_empty(&p->pending)) rediwm_scene_damage_layout(p->outputs, &p->pending);
  pixman_region32_clear(&p->pending);
}
#ifdef REDIWM_DAMAGE_AUDIT
static void audit_gate(struct rediwm_projection *p, double z, double cx, double cy, double ox,
                       double oy, struct rediwm_tree *fixed) {
  size_t n = 0;
  struct leaf *l;
  wl_list_for_each(l, &p->leaves, link) n++;
  struct rediwm_item *before = calloc(n ? n : 1, sizeof(*before));
  struct leaf **who = calloc(n ? n : 1, sizeof(*who));
  if (!before || !who) {
    free(before);
    free(who);
    return;
  }
  size_t i = 0;
  wl_list_for_each(l, &p->leaves, link) {
    before[i] = l->item;
    who[i++] = l;
  }
  projection_resolve(p, z, cx, cy, ox, oy, fixed, true);
  for (i = 0; i < n; i++) {
    const struct rediwm_item *a = &before[i], *b = &who[i]->item;
    if (a->enabled != b->enabled || a->kind != b->kind || memcmp(&a->edges, &b->edges, sizeof(a->edges)) ||
        !rediwm_content_equal(&a->content, &b->content))
      wlr_log(WLR_ERROR, "gate audit: leaf %llu (kind %d) was stale: enabled %d->%d edges %.1f,%.1f %.1f,%.1f -> %.1f,%.1f %.1f,%.1f",
              (unsigned long long)who[i]->item.id, b->kind, a->enabled, b->enabled, a->edges.x1, a->edges.y1,
              a->edges.x2, a->edges.y2, b->edges.x1, b->edges.y1, b->edges.x2, b->edges.y2);
  }
  free(before);
  free(who);
}
#endif
void rediwm_projection_sync_fixed(struct rediwm_projection *p, double z, double cx,
                            double cy, double ox, double oy,
                            struct rediwm_tree *fixed) {
  if (!p)
    return;
  const double camera[5] = {z, cx, cy, ox, oy};
  const bool moved = !p->have_camera || p->fixed != fixed || memcmp(p->camera, camera, sizeof(camera));
  if (!moved && !p->any_dirty)
    return;
  const bool full = moved || p->all_dirty;
  p->any_dirty = p->all_dirty = false;
  p->have_camera = true;
  p->fixed = fixed;
  memcpy(p->camera, camera, sizeof(camera));
  projection_resolve(p, z, cx, cy, ox, oy, fixed, full);
#ifdef REDIWM_DAMAGE_AUDIT
  // Self-check of the gate: what a full walk would put in the graph must be what the
  // gated one did. Reports every leaf that differs, then goes on with the full result.
  if (!full) audit_gate(p, z, cx, cy, ox, oy, fixed);
#endif
  projection_present(p, full);
  apply_damage(p);
}
void rediwm_projection_sync(struct rediwm_projection *p, double z, double cx,
                            double cy, double ox, double oy) {
  rediwm_projection_sync_fixed(p, z, cx, cy, ox, oy, NULL);
}
static void watched_commit(struct wl_listener *listener, void *data) {
  (void)data;
  struct watched_surface *watch = wl_container_of(listener, watch, commit);
  // Covers the first commit of new/desynchronized subsurfaces and popups,
  // before they have presentation leaves of their own: a surface with a leaf is
  // told by its leaf; any other may be about to appear anywhere.
  struct rediwm_projection *p = watch->projection;
  struct feedback *f;
  bool known = false;
  wl_list_for_each(f, &p->feedback, link)
      if (f->leaf->surface && f->leaf->surface->surface == watch->surface) known = true;
  // A known surface's leaf reports its own changes; frame callbacks alone are the
  // surface node's to deliver.
  if (known) return;
  mark_all(p);
  schedule(p);
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
  watch->surface = surface;
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
  if (current == p) current = NULL;
  if (p->own->changed_data == p) {
    p->own->changed = NULL;
    p->own->buffer_damaged = NULL;
    p->own->changed_data = NULL;
  }
  pixman_region32_fini(&p->pending);
  struct watched_surface *watch, *next;
  wl_list_for_each_safe(watch, next, &p->surfaces, link)
      watched_destroy(&watch->destroy, NULL);
  free(p);
}
