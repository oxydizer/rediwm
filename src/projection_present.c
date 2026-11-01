// present(): graph -> damage (projection.c has the overview), and the
// buffers the compositor itself replaces.
#include "projection_internal.h"

// What a shadow draws changed, or it appeared or went: damage the footprint it
// last drew and the one it draws now, in layout space.
void projection_damage_shadow(struct leaf *l, bool show, struct rediwm_snap at) {
  const float opacity = l->item.content.opacity;
  if (show == l->has_shadow_drawn &&
      (!show || (at.x == l->shadow_drawn.x && at.y == l->shadow_drawn.y &&
                 at.width == l->shadow_drawn.width && at.height == l->shadow_drawn.height &&
                 opacity == l->shadow_drawn_opacity &&
                 rediwm_shadow_equal(&l->shadow, &l->shadow_drawn_as))))
    return;
  pixman_region32_t region;
  pixman_region32_init(&region);
  if (l->has_shadow_drawn)
    pixman_region32_union_rect(&region, &region, l->shadow_drawn.x, l->shadow_drawn.y,
                               l->shadow_drawn.width, l->shadow_drawn.height);
  if (show) pixman_region32_union_rect(&region, &region, at.x, at.y, at.width, at.height);
  if (pixman_region32_not_empty(&region)) {
    pixman_region32_union(&l->projection->pending, &l->projection->pending, &region);
    const pixman_box32_t *b = pixman_region32_extents(&region);
    emit(l->projection, l->item.id, b->x1, b->y1, b->x2 - b->x1, b->y2 - b->y1);
  }
  pixman_region32_fini(&region);
  l->has_shadow_drawn = show;
  l->shadow_drawn = at;
  l->shadow_drawn_as = l->shadow;
  l->shadow_drawn_opacity = opacity;
}

// The layout box a buffer-local box covers: through the source box onto the item's
// edges, one pixel wider for filtering, never beyond the leaf (damage outside its
// source box shows nowhere).
static struct rediwm_snap map_damage(const struct rediwm_item *item, const pixman_box32_t *b,
                                     const struct wlr_fbox *src, struct rediwm_snap snap) {
  const struct rediwm_edges *e = &item->edges;
  const double sx = (e->x2 - e->x1) / src->width, sy = (e->y2 - e->y1) / src->height;
  const int x1 = (int)floor(e->x1 + (b->x1 - src->x) * sx) - 1;
  const int y1 = (int)floor(e->y1 + (b->y1 - src->y) * sy) - 1;
  const int x2 = (int)ceil(e->x1 + (b->x2 - src->x) * sx) + 1;
  const int y2 = (int)ceil(e->y1 + (b->y2 - src->y) * sy) + 1;
  const int cx1 = x1 > snap.x ? x1 : snap.x, cy1 = y1 > snap.y ? y1 : snap.y;
  const int cx2 = x2 < snap.x + snap.width ? x2 : snap.x + snap.width;
  const int cy2 = y2 < snap.y + snap.height ? y2 : snap.y + snap.height;
  return (struct rediwm_snap){cx1, cy1, cx2 - cx1, cy2 - cy1};
}
// What a commit's or a replaced buffer's damage changed: the event covers the
// bounding box of the buffer-local damage, the screen only the pieces of it (up to
// a few). The whole box without damage, under a transform, or for polar sampling
// whose source rectangles do not map to axis-aligned screen rectangles.
static void damage_event_for_buffer(struct leaf *l, const pixman_region32_t *damage,
                                    int buffer_width, int buffer_height,
                                    struct rediwm_snap snap) {
  const struct rediwm_item *item = &l->item;
  if (damage && !pixman_region32_not_empty((pixman_region32_t *)damage)) return;
  if (!damage || item->content.transform != WL_OUTPUT_TRANSFORM_NORMAL ||
      buffer_width <= 0 || buffer_height <= 0 ||
      (item->clip && item->clip->sector_texture_height > 0)) {
    emit_snap(l, snap);
    damage_box(l, snap, true);
    return;
  }
  struct wlr_fbox src = item->content.src_box;
  if (wlr_fbox_empty(&src)) src = (struct wlr_fbox){0, 0, buffer_width, buffer_height};
  const struct rediwm_snap whole =
      map_damage(item, pixman_region32_extents((pixman_region32_t *)damage), &src, snap);
  emit(l->projection, item->id, whole.x, whole.y, whole.width, whole.height);
  int count = 0;
  const pixman_box32_t *rects = pixman_region32_rectangles((pixman_region32_t *)damage, &count);
  if (count > 16) {
    damage_box(l, whole, true);
    return;
  }
  for (int i = 0; i < count; i++) {
    const struct rediwm_snap piece = map_damage(item, &rects[i], &src, snap);
    damage_box(l, piece, true);
  }
}
// present(): graph -> damage. Reads items, never the source's geometry; rounds
// and tells the screen and the damage events what changed.
static void present_leaf(struct leaf *l) {
  struct rediwm_item *item = &l->item;
  // Round in layout coordinates first. Rounding a scaled local offset would
  // change pixels at fractional zoom and when crossing negative origins.
  const struct rediwm_snap snap = rediwm_edges_snap(item->edges);
  const bool enabled = item->enabled && snap.width > 0 && snap.height > 0;
  // Damage events: a moved, resized, shown, hidden or restyled leaf changes its
  // old and its new box; otherwise only what a new buffer or commit damaged.
  // Only a leaf that puts pixels on screen has them: an input-only node (a
  // resize grab) moving with its window must not read as a change below glass,
  // and the pass draws effects itself (shadows report in damage_shadow).
  bool paints = enabled;
  if (item->kind == REDIWM_ITEM_RECT) {
    paints = paints && item->content.color[3] > 0;
  } else if (item->kind == REDIWM_ITEM_EFFECT || item->kind == REDIWM_ITEM_SHADOW) {
    paints = false;
  } else {
    // What the output pass draws from: the buffer, or the texture left when GLES2
    // uploaded it and let the buffer go, or a single-pixel colour.
    const struct rediwm_buffer *sb = rediwm_buffer_from_node(l->source);
    paints = paints && item->content.opacity > 0 &&
             (sb->buffer || sb->texture || sb->is_single_pixel_buffer ||
              (l->surface && l->surface->surface->buffer));
  }
  const bool restyled = !l->has_shown || !paints || snap.x != l->shown.x ||
                        snap.y != l->shown.y || snap.width != l->shown.width ||
                        snap.height != l->shown.height ||
                        !rediwm_content_equal(&item->content, &l->shown_content);
  if (restyled) {
    forget_shown(l);
    if (paints) {
      emit_snap(l, snap);
      damage_box(l, snap, false);
      l->shown = snap;
      l->shown_content = item->content;
      l->has_shown = true;
    }
  }
  if (item->kind != REDIWM_ITEM_RECT && item->kind != REDIWM_ITEM_EFFECT) {
    struct rediwm_buffer *b = rediwm_buffer_from_node(l->source);
    struct wlr_buffer *backing = b->buffer;
    // wlroots may cache a single-pixel buffer as a color and release the
    // source node's buffer reference. The mapped surface still owns it.
    if (!backing && l->surface && l->surface->surface->buffer)
      backing = &l->surface->surface->buffer->base;
    if (l->dirty || l->last_buffer != backing) {
      const pixman_region32_t *damage =
          backing && (l->surface || l->owned_damage) && l->dirty && !l->full_damage
              ? &l->damage : NULL;
      if (!restyled && l->has_shown)
        damage_event_for_buffer(l, damage,
                                l->surface ? l->damage_width : backing ? backing->width : 0,
                                l->surface ? l->damage_height : backing ? backing->height : 0, snap);
      l->last_buffer = backing;
    }
  }
  if (item->kind == REDIWM_ITEM_SHADOW || l->has_shadow_drawn)
    projection_damage_shadow(l, item->kind == REDIWM_ITEM_SHADOW && enabled &&
                         item->content.opacity > 0 && item->shadow->color[3] > 0,
                  snap);
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
// lock is marked ignorable (like wlr_scene's own surface lock): the output pass
// reads the buffer from the node and is told the damage at the next sync.
bool rediwm_projection_present_owned(struct rediwm_projection *p,
                                     struct rediwm_buffer *source,
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
    rediwm_buffer_set_content(source, buffer);
    rediwm_projection_damage_buffer(p, &source->node, NULL);
    return false;
  }
  if (current)
    current->private.n_ignore_locks--;
  rediwm_buffer_set_content(source, &next->base);
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
                                     struct rediwm_node *source,
                                     const pixman_region32_t *damage) {
  struct leaf *l = source->leaf;
  // A leaf's first projection applies its whole buffer anyway.
  if (!l || l->projection != p)
    return;
  if (l->surface)
    return;
  if (!damage ||
      !pixman_region32_union(&l->damage, &l->damage, damage))
    l->full_damage = true;
  l->owned_damage = true;
  l->dirty = true;
  mark_group(p, l->group);
  schedule(p);
}
static void damage_restacked(struct rediwm_projection *p);
// Graph -> damage, then forget what the graph no longer reaches.
void projection_present(struct rediwm_projection *p, bool full) {
  struct group *g;
  wl_list_for_each(g, &p->paint, paint) {
    if (!full && !g->touched) continue;
    struct leaf *l, *next;
    wl_list_for_each_safe(l, next, &g->items, paint) present_leaf(l);
  }
  struct leaf *l;
  wl_list_for_each(l, &p->leaves, link) if (!l->seen) {
    forget_shown(l);
    projection_damage_shadow(l, false, (struct rediwm_snap){0});
    l->ranked = false;
  }
  // Nothing was stacked differently unless the shape of the tree changed.
  if (full) damage_restacked(p);
}
// A leaf that is above what it was below, or the reverse, changes every pixel of
// the two where they overlap, and nothing else tells the screen: wlroots damaged a
// node it restacked. The leaves still there are checked in paint order against
// the order of the last sync; when it differs, the ones that must have moved (all
// but a longest run that kept its order) are damaged whole. Any pair that swapped
// has at least one of them outside that run, and the overlap lies in its box.
static void damage_restacked(struct rediwm_projection *p) {
  size_t n = 0;
  bool ordered = true, have = false;
  uint32_t last = 0;
  struct group *g;
  struct leaf *l;
  wl_list_for_each(g, &p->paint, paint) wl_list_for_each(l, &g->items, paint) {
    if (!l->ranked) continue;
    if (have && l->rank < last) ordered = false;
    last = l->rank;
    have = true;
    n++;
  }
  if (!ordered) {
    struct leaf **leaves = malloc(n * sizeof(*leaves));
    size_t *tails = malloc(n * sizeof(*tails));
    long *before = malloc(n * sizeof(*before));
    bool *kept = calloc(n, sizeof(*kept));
    if (leaves && tails && before && kept) {
      size_t count = 0, length = 0;
      wl_list_for_each(g, &p->paint, paint) wl_list_for_each(l, &g->items, paint)
          if (l->ranked) leaves[count++] = l;
      // Longest strictly increasing run of the old ranks.
      for (size_t i = 0; i < count; i++) {
        size_t lo = 0, hi = length;
        while (lo < hi) {
          const size_t mid = (lo + hi) / 2;
          if (leaves[tails[mid]]->rank < leaves[i]->rank) lo = mid + 1;
          else hi = mid;
        }
        before[i] = lo > 0 ? (long)tails[lo - 1] : -1;
        tails[lo] = i;
        if (lo == length) length++;
      }
      for (long i = length ? (long)tails[length - 1] : -1; i >= 0; i = before[i]) kept[i] = true;
      for (size_t i = 0; i < count; i++) {
        struct leaf *moved = leaves[i];
        if (kept[i]) continue;
        // A shadow shows no box of its own (`shown`), but it lies over or under
        // what was restacked all the same.
        if (moved->has_shown) damage_box(moved, moved->shown, false);
        if (moved->has_shadow_drawn) damage_box(moved, moved->shadow_drawn, false);
      }
    } else {
      // Out of memory: treat the whole layout as changed.
      pixman_region32_union_rect(&p->pending, &p->pending, INT32_MIN / 2, INT32_MIN / 2, INT32_MAX, INT32_MAX);
    }
    free(leaves);
    free(tails);
    free(before);
    free(kept);
  }
  uint32_t rank = 0;
  wl_list_for_each(g, &p->paint, paint) wl_list_for_each(l, &g->items, paint) {
    l->rank = rank++;
    l->ranked = true;
  }
}
