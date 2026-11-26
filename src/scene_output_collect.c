// What a frame draws: the graph's items, top to bottom, culled against what is
// above them, with their visible and opaque regions. Part of scene_output.c.
#include "scene_output_internal.h"

// The first output is being drawn. For every other output the same walk
// measures visibility and occlusion for client enter/leave and damage.
struct collect_output {
    struct rediwm_scene_output *out;
    struct wlr_box logical;
    pixman_region32_t covered;
};
struct collector {
    struct rediwm_output_renderer *renderer;
    const struct output_view *view;
    struct collect_output outputs[64];
    size_t count;
    struct rediwm_clip cover_of;
    pixman_region32_t cover;
    bool has_cover;
    pixman_region32_t reads;
};

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
static bool collect_item(const struct rediwm_item *item, struct rediwm_node *transport, void *data) {
    struct collector *collector = data;
    struct rediwm_output_renderer *r = collector->renderer;
    if (!item->enabled) { return true; }
    struct rediwm_snap s = rediwm_edges_snap(item->edges);
    if (s.width <= 0 || s.height <= 0) { return true; }
    struct wlr_box box = {s.x, s.y, s.width, s.height}, intersection;
    // An overhanging window may intersect a peer geometrically. Only its
    // home draws it or adds it to the opaque cover for that output.
    pixman_region32_t visible;
    pixman_region32_init(&visible);
    bool here = false, elsewhere = false;
    uint64_t overlaps = 0;
    for (size_t i = 0; i < collector->count; i++) {
        struct collect_output *co = &collector->outputs[i];
        struct wlr_box part;
        if ((item->home_output && co->out->serial != item->home_output) ||
                !wlr_box_intersection(&part, &box, &co->logical)) continue;
        overlaps |= 1ull << i;
        pixman_region32_t shown;
        pixman_region32_init_rect(&shown, part.x, part.y, part.width, part.height);
        pixman_region32_subtract(&shown, &shown, &co->covered);
        rediwm_projection_note_output(r->projection, transport, co->out, &shown);
        if (i == 0) {
            here = true;
            intersection = part;
            // Transfer the region to the entry without another allocation.
            visible = shown;
        } else {
            elsewhere |= pixman_region32_not_empty(&shown);
            pixman_region32_fini(&shown);
        }
    }
    const bool draw = here && (pixman_region32_not_empty(&visible) ||
        pixman_region32_contains_rectangle(&collector->reads, &(pixman_box32_t){intersection.x, intersection.y,
            intersection.x + intersection.width, intersection.y + intersection.height}) != PIXMAN_REGION_OUT);
    if (!draw && !elsewhere) { pixman_region32_fini(&visible); return true; }
    struct rediwm_glass_info glass = {0};
    bool skip = false;
    if (item->kind == REDIWM_ITEM_RECT) {
        skip = item->content.color[3] == 0;
    } else if (item->kind == REDIWM_ITEM_EFFECT) {
        // Glass is drawn here (stage 5c); without the blur program there is none,
        // and the surface's own tint shows, as glass.c's fallback did.
        skip = !draw || !r->has_backdrops || item->content.opacity == 0 ||
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
        // A client viewport can be much larger than the output. Allocate blur
        // storage only for the visible output and the samples around its edges.
        const struct wlr_box extent = item->blur_region ? intersection : box;
        e->padded = (struct wlr_box){extent.x - pad, extent.y - pad, extent.width + 2 * pad, extent.height + 2 * pad};
        pixman_region32_union_rect(&collector->reads, &collector->reads,
            e->padded.x, e->padded.y, e->padded.width, e->padded.height);
        // The shell uses its foreground texture for antialiased decoration edges.
        // A client region is a mask behind the surface and needs no client texture.
        e->front = item->blur_region ? NULL : &glass.target->node;
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
    for (size_t i = 0; i < collector->count; i++) if (overlaps & (1ull << i)) {
        pixman_region32_t *covered = &collector->outputs[i].covered;
        pixman_region32_union(covered, covered, &e->opaque);
    }
    if (!draw) {
        // Only what it hides, for the feedback of what is below.
        pixman_region32_fini(&e->visible);
        pixman_region32_fini(&e->opaque);
        r->entries.size -= sizeof(*e);
    }
    return true;
}
bool scene_output_collect_frame(struct rediwm_output_renderer *r, struct rediwm_scene_output *out,
        const struct output_view *v, pixman_region32_t *covered) {
    struct collector collector = {.renderer = r, .view = v, .count = 1,
        .outputs = {{.out = out, .logical = v->logical}}};
    struct rediwm_scene_output *peer;
    wl_list_for_each(peer, &out->outputs->outputs, link) {
        if (peer == out || !peer->output->enabled) continue;
        struct collect_output *co = &collector.outputs[collector.count++];
        co->out = peer;
        co->logical = (struct wlr_box){.x = peer->x, .y = peer->y};
        wlr_output_effective_resolution(peer->output, &co->logical.width, &co->logical.height);
    }
    for (size_t i = 0; i < collector.count; i++) pixman_region32_init(&collector.outputs[i].covered);
    pixman_region32_init(&collector.reads);
    rediwm_projection_feedback_begin(r->projection);
    bool ok = rediwm_projection_for_each_item(r->projection, true, collect_item, &collector);
    if (ok) {
        rediwm_projection_feedback_end(r->projection);
        pixman_region32_copy(covered, &collector.outputs[0].covered);
    }
    if (collector.has_cover) pixman_region32_fini(&collector.cover);
    pixman_region32_fini(&collector.reads);
    for (size_t i = 0; i < collector.count; i++) pixman_region32_fini(&collector.outputs[i].covered);
    return ok;
}
void scene_output_clear_entries(struct rediwm_output_renderer *r) {
    struct entry *e;
    wl_array_for_each(e, &r->entries) {
        pixman_region32_fini(&e->visible);
        pixman_region32_fini(&e->opaque);
    }
    r->entries.size = 0;
}
