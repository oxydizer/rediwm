// What a frame draws: the graph's items, top to bottom, culled against what is
// above them, with their visible and opaque regions. Part of scene_output.c.
#include "scene_output_internal.h"

// What of a clipped item may be drawn without the shape and without blending: the
// model's opaque cover, minus a margin around the edge where the ring is drawn.
// Layout space, like the item's own opaque region.
static void clip_cover(pixman_region32_t *out, const struct rediwm_clip *c, double scale) {
    pixman_region32_init(out);
    struct rediwm_snap parts[3];
    const int n = rediwm_clip_opaque(c, parts);
    for (int i = 0; i < n; i++)
        pixman_region32_union_rect(out, out, parts[i].x, parts[i].y, parts[i].width, parts[i].height);
    if (c->border > 0) {
        const struct rediwm_snap f = rediwm_edges_snap(c->edges);
        const int ring = (int)ceil(fmax(c->border, 1.0 / scale)) + 1;
        if (f.width > 2 * ring && f.height > 2 * ring)
            pixman_region32_intersect_rect(out, out, f.x + ring, f.y + ring, f.width - 2 * ring, f.height - 2 * ring);
        else
            pixman_region32_clear(out);
    }
}
static bool same_clip(const struct rediwm_clip *a, const struct rediwm_clip *b) {
    if (a->edges.x1 != b->edges.x1 || a->edges.y1 != b->edges.y1 || a->edges.x2 != b->edges.x2 ||
        a->edges.y2 != b->edges.y2 || a->border != b->border) return false;
    return rediwm_clip_outline_equal(a, b);
}
bool scene_output_collect(const struct rediwm_item *item, struct rediwm_node *transport, void *data) {
    struct collector *collector = data;
    struct rediwm_output_renderer *r = collector->renderer;
    if (!item->enabled) { return true; }
    struct rediwm_snap s = rediwm_edges_snap(item->edges);
    if (s.width <= 0 || s.height <= 0) { return true; }
    struct wlr_box box = {s.x, s.y, s.width, s.height}, intersection;
    const bool here = wlr_box_intersection(&intersection, &box, &collector->view->logical);
    // An item on another output only is not drawn for this one, but it still hides
    // what is below it there, which the surface feedback below counts (stage 6).
    bool elsewhere = false;
    for (int i = 0; i < collector->others && !elsewhere; i++) {
        struct wlr_box other;
        elsewhere = wlr_box_intersection(&other, &box, &collector->other[i]);
    }
    if (!here && !elsewhere) { return true; }
    // Visit top-to-bottom so fully occluded items never enter the render list
    // and never allocate/copy content. The graph, not the view's visible region,
    // supplies the bounds and paint order.
    pixman_region32_t visible;
    pixman_region32_init_rect(&visible, box.x, box.y, box.width, box.height);
    pixman_region32_subtract(&visible, &visible, &collector->covered);
    // What a client surface shows of itself on every output is what it is told:
    // this counts for an item that draws nothing as well (opacity 0), as it does
    // for wlroots.
    if (item->kind == REDIWM_ITEM_SURFACE)
        rediwm_projection_feedback_note(r->projection, transport, &visible);
    if (item->kind != REDIWM_ITEM_EFFECT)
        rediwm_projection_note_visible(r->projection, transport, &visible);
    if (here)
        pixman_region32_intersect_rect(&visible, &visible, intersection.x, intersection.y,
            intersection.width, intersection.height);
    struct rediwm_glass_info glass = {0};
    bool skip = false;
    if (item->kind == REDIWM_ITEM_RECT) {
        skip = item->content.color[3] == 0;
    } else if (item->kind == REDIWM_ITEM_EFFECT) {
        // Glass is drawn here (stage 5c); without the blur program there is none,
        // and the surface's own tint shows, as glass.c's fallback did.
        skip = !here || !r->has_backdrops || item->content.opacity == 0 ||
            !rediwm_glass_effect_info(transport, &glass) || glass.opacity <= 0;
    } else if (item->kind == REDIWM_ITEM_RIBBON) {
        skip = item->content.opacity == 0 || item->ribbon->count < 4;
    } else if (item->kind == REDIWM_ITEM_SHADOW) {
        // No buffer: the pixels are the shadow's, and never opaque.
        skip = item->content.opacity == 0 || item->shadow->color[3] == 0;
    } else {
        struct rediwm_buffer *b = rediwm_buffer_from_node(transport);
        skip = item->content.opacity == 0 ||
            (!b->buffer && !b->texture && !b->is_single_pixel_buffer);
    }
    if (skip) { pixman_region32_fini(&visible); return true; }
    if (here && !pixman_region32_not_empty(&visible) &&
        pixman_region32_contains_rectangle(&collector->reads, &(pixman_box32_t){intersection.x, intersection.y,
            intersection.x + intersection.width, intersection.y + intersection.height}) == PIXMAN_REGION_OUT) {
        pixman_region32_fini(&visible);
        return true;
    }
    struct entry *e = wl_array_add(&r->entries, sizeof(*e));
    if (!e) { pixman_region32_fini(&visible); return false; }
    *e = (struct entry){.item = *item, .transport = transport,
        .box = box, .visible = visible};
    pixman_region32_init(&e->opaque);
    if (item->kind == REDIWM_ITEM_EFFECT) {
        // The blur reads three sigma around the surface, below the effect in
        // paint order, including what opaque surfaces above hide on screen: items
        // there stay in the list for it (`reads`), not for the screen.
        e->glass = glass;
        e->sigma = glass.sigma * item->scale;
        const int pad = (int)ceil(3 * e->sigma);
        e->padded = (struct wlr_box){box.x - pad, box.y - pad, box.width + 2 * pad, box.height + 2 * pad};
        pixman_region32_union_rect(&collector->reads, &collector->reads,
            e->padded.x, e->padded.y, e->padded.width, e->padded.height);
        e->front = &glass.target->node;
        return true;
    }
    bool full = item->kind == REDIWM_ITEM_RECT && item->content.color[3] == 1;
    if (item->kind != REDIWM_ITEM_RECT && item->kind != REDIWM_ITEM_SHADOW && item->kind != REDIWM_ITEM_RIBBON) {
        struct rediwm_buffer *b = rediwm_buffer_from_node(transport);
        // Match the surface adapter's opacity policy. A cached raster whose
        // buffer was released must not suddenly hide previously visible peers.
        if (b->buffer && item->content.opacity == 1) {
            full = b->buffer_is_opaque;
            if (!full) {
                rediwm_mirror_opaque(&e->opaque, &b->opaque_region, item->width, item->height, s.width, s.height);
                pixman_region32_translate(&e->opaque, s.x, s.y);
            }
        }
    }
    if (full) pixman_region32_union_rect(&e->opaque, &e->opaque, s.x, s.y, s.width, s.height);
    if (item->clip) {
        // The corners are transparent and the ring is drawn by the shape: only
        // the interior may hide what is below or skip blending.
        if (!collector->has_cover || !same_clip(&collector->cover_of, item->clip)) {
            if (collector->has_cover) pixman_region32_fini(&collector->cover);
            clip_cover(&collector->cover, item->clip, collector->view->scale);
            collector->cover_of = *item->clip;
            collector->has_cover = true;
        }
        pixman_region32_intersect(&e->opaque, &e->opaque, &collector->cover);
    }
    pixman_region32_union(&collector->covered, &collector->covered, &e->opaque);
    if (!here) {
        // Only what it hides, for the feedback of what is below.
        pixman_region32_fini(&e->visible);
        pixman_region32_fini(&e->opaque);
        r->entries.size -= sizeof(*e);
    }
    return true;
}
void scene_output_clear_entries(struct rediwm_output_renderer *r) {
    struct entry *e;
    wl_array_for_each(e, &r->entries) {
        pixman_region32_fini(&e->visible);
        pixman_region32_fini(&e->opaque);
    }
    r->entries.size = 0;
}
