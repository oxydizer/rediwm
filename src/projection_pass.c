// What the output pass reads from the graph and reports back: items in paint
// order, mirrored opaque regions, what of each leaf is visible, surface
// feedback and frame callbacks. Part of projection.c.
#include "projection_internal.h"

void projection_free_feedback(struct leaf *l) {
  if (!l->feedback) return;
  wl_list_remove(&l->feedback->link);
  free(l->feedback);
  l->feedback = NULL;
}
static uint32_t region_area(const pixman_region32_t *region) {
  int count = 0;
  const pixman_box32_t *box = pixman_region32_rectangles((pixman_region32_t *)region, &count);
  uint32_t area = 0;
  for (int i = 0; i < count; i++)
    area += (uint32_t)(box[i].x2 - box[i].x1) * (uint32_t)(box[i].y2 - box[i].y1);
  return area;
}
static struct leaf *transport_leaf(struct rediwm_projection *p, struct rediwm_node *node) {
  struct leaf *l = node->leaf;
  return l && l->projection == p ? l : NULL;
}
static struct leaf *feedback_leaf(struct rediwm_projection *p, struct rediwm_node *node) {
  struct leaf *l = transport_leaf(p, node);
  return l && l->feedback ? l : NULL;
}
// What of an item nothing above hides, as the output pass last saw it (layout space).
void rediwm_projection_note_visible(struct rediwm_projection *p, struct rediwm_node *node,
                                    const pixman_region32_t *visible) {
  struct leaf *l = transport_leaf(p, node);
  if (!l) return;
  pixman_region32_copy(&l->visible, visible);
  l->has_visible = true;
}
void rediwm_projection_feedback_begin(struct rediwm_projection *p) {
  // Whatever this build does not reach (off every output, hidden, gone) shows
  // nothing: damage that only changes what such a leaf shows is dropped.
  struct leaf *leaf;
  wl_list_for_each(leaf, &p->leaves, link) {
    pixman_region32_clear(&leaf->visible);
    leaf->has_visible = true;
  }
  struct feedback *f;
  wl_list_for_each(f, &p->feedback, link) memset(f->area, 0, sizeof(f->area));
  struct rediwm_scene_output *out;
  wl_list_for_each(out, &p->outputs->outputs, link) {
    const unsigned i = out->index % FEEDBACK_OUTPUTS;
    if (p->shown_output[i].known &&
        (p->shown_output[i].scale != out->output->scale ||
         p->shown_output[i].color_serial != out->color_serial ||
         p->shown_output[i].transform != out->output->transform ||
         p->shown_output[i].subpixel != out->output->subpixel))
      p->forced |= 1ull << i;
    p->shown_output[i].color_serial = out->color_serial;
    p->shown_output[i].scale = out->output->scale;
    p->shown_output[i].transform = out->output->transform;
    p->shown_output[i].subpixel = out->output->subpixel;
    p->shown_output[i].known = true;
  }
}
// `visible` is what of the surface nothing above it hides, over the whole layout.
void rediwm_projection_feedback_note(struct rediwm_projection *p, struct rediwm_node *node,
                                     const pixman_region32_t *visible) {
  struct leaf *l = feedback_leaf(p, node);
  if (!l || !pixman_region32_not_empty((pixman_region32_t *)visible)) return;
  struct rediwm_scene_output *out;
  wl_list_for_each(out, &p->outputs->outputs, link) {
    if (!out->output->enabled) continue;
    struct wlr_box box = {.x = out->x, .y = out->y};
    wlr_output_effective_resolution(out->output, &box.width, &box.height);
    pixman_region32_t shown;
    pixman_region32_init(&shown);
    pixman_region32_intersect_rect(&shown, (pixman_region32_t *)visible, box.x, box.y, box.width,
                                   box.height);
    l->feedback->area[out->index % FEEDBACK_OUTPUTS] = region_area(&shown);
    pixman_region32_fini(&shown);
  }
}
// The outputs and primary output of one surface from the last report of every
// output, and the signals of what changed.
static void update_feedback(struct leaf *l) {
  struct feedback *f = l->feedback;
  struct rediwm_scene_outputs *scene = l->projection->outputs;
  struct rediwm_scene_output *out;
  uint64_t total = 0;
  wl_list_for_each(out, &scene->outputs, link)
      if (out->output->enabled) total += f->area[out->index % FEEDBACK_OUTPUTS];
  uint32_t largest = 0;
  uint64_t active = 0;
  size_t count = 0;
  struct rediwm_scene_output *primary = NULL;
  wl_list_for_each(out, &scene->outputs, link) {
    if (!out->output->enabled) continue;
    const uint32_t overlap = f->area[out->index % FEEDBACK_OUTPUTS];
    // Ten percent of what is visible or less, and the output is ignored.
    if (overlap > 0.1 * total) {
      if (overlap >= largest) {
        largest = overlap;
        primary = out;
      }
      active |= 1ull << (out->index % FEEDBACK_OUTPUTS);
      count++;
    }
  }
  struct rediwm_buffer *b = rediwm_buffer_from_node(l->source);
  const uint64_t before = f->active;
  struct rediwm_scene_output *before_primary = f->primary;
  f->active = active;
  f->primary = primary;
  if (before == active && before_primary == primary && !(active & l->projection->forced)) return;
  struct rediwm_scene_output *outputs[FEEDBACK_OUTPUTS];
  struct rediwm_outputs_update_event event = {.active = outputs, .size = count, .primary = primary};
  size_t i = 0;
  wl_list_for_each(out, &scene->outputs, link)
      if (active & (1ull << (out->index % FEEDBACK_OUTPUTS))) outputs[i++] = out;
  wl_signal_emit_mutable(&b->events.outputs_update, &event);
}
void rediwm_projection_feedback_end(struct rediwm_projection *p) {
  struct feedback *f, *next;
  wl_list_for_each_safe(f, next, &p->feedback, link) update_feedback(f->leaf);
  p->forced = 0;
}
// Frame callbacks for the world: the surfaces shown on any
// output (the surface itself picks the output that paces it).
void rediwm_projection_send_frame_done(struct rediwm_projection *p, struct rediwm_scene_output *out,
                                       struct timespec *now) {
  struct feedback *f, *next;
  wl_list_for_each_safe(f, next, &p->feedback, link) {
    if (!f->active || !f->leaf->seen || !f->leaf->item.enabled) continue;
    struct rediwm_frame_done_event event = {.output = out, .when = *now};
    wl_signal_emit_mutable(&rediwm_buffer_from_node(f->leaf->source)->events.frame_done, &event);
  }
}
bool rediwm_projection_for_each_item(struct rediwm_projection *p, bool reverse, rediwm_item_iterator iterator, void *data) {
  for (struct wl_list *link = reverse ? p->paint.prev : p->paint.next;
       link != &p->paint; link = reverse ? link->prev : link->next) {
    struct group *g = wl_container_of(link, g, paint);
    if (!g->enabled) continue;
    for (struct wl_list *leaf_link = reverse ? g->items.prev : g->items.next;
         leaf_link != &g->items; leaf_link = reverse ? leaf_link->prev : leaf_link->next) {
      struct leaf *l = wl_container_of(leaf_link, l, paint);
      if (l->item.enabled && !iterator(&l->item, l->source, data)) return false;
    }
  }
  return true;
}
// A node's opaque region (in its own units) as it lands on screen, never larger
// than the real one.
//
// wlroots knows a client surface is opaque from its raw buffer's format (an XRGB
// buffer covers the whole surface) or from the client's own opaque region, and
// keeps that in the node's opaque region; the node's buffer is a wlr_client_buffer,
// which reveals no pixel format, so its own flag is false for every client. A node
// shown 1:1 uses the region as is. Otherwise each rectangle is scaled with the
// node and pulled one pixel inward, so rounding and the filter's reach beyond an
// opaque edge can never mark a translucent pixel opaque.
void rediwm_mirror_opaque(pixman_region32_t *out, const pixman_region32_t *source, int source_width,
        int source_height, int width, int height) {
    int count = 0;
    const pixman_box32_t *box = pixman_region32_rectangles((pixman_region32_t *)source, &count);
    const bool exact = width == source_width && height == source_height;
    for (int i = 0; i < count; i++) {
        if (exact) {
            pixman_region32_union_rect(out, out, box[i].x1, box[i].y1, box[i].x2 - box[i].x1, box[i].y2 - box[i].y1);
        } else if (source_width > 0 && source_height > 0) {
            const double sx = (double)width / source_width;
            const double sy = (double)height / source_height;
            const int x1 = (int)ceil(box[i].x1 * sx) + 1;
            const int y1 = (int)ceil(box[i].y1 * sy) + 1;
            const int x2 = (int)floor(box[i].x2 * sx) - 1;
            const int y2 = (int)floor(box[i].y2 * sy) - 1;
            if (x2 > x1 && y2 > y1) pixman_region32_union_rect(out, out, x1, y1, x2 - x1, y2 - y1);
        }
    }
    pixman_region32_intersect_rect(out, out, 0, 0, width, height);
}
