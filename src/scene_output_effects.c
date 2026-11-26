// ---- Effects: which blurs this frame re-takes (D1) ---------------------------------
// Part of scene_output.c.
#include "scene_output_internal.h"

uint64_t rediwm_scene_output_reblurs; // read and reset by the performance stats
struct attribution {
    uint64_t output_serial;
    const struct output_view *view;
    struct entry *entries;
    size_t len;
    struct wl_array events;          // struct seen_event
    pixman_region32_t explained;     // device pixels events account for
};
struct seen_event { uint64_t leaf; struct wlr_box box; }; // device pixels
static void note_event(const struct rediwm_damage_event *ev, void *data) {
    struct attribution *a = data;
    if (ev->home_output && ev->home_output != a->output_serial) return;
    struct wlr_box box = device_box((struct wlr_box){ev->box.x, ev->box.y, ev->box.width, ev->box.height}, a->view);
    // wlroots widens a scaled buffer's damage for filtering; so does this.
    box = (struct wlr_box){box.x - 2, box.y - 2, box.width + 4, box.height + 4};
    struct seen_event *se = wl_array_add(&a->events, sizeof(*se));
    if (se) *se = (struct seen_event){ev->leaf, box};
    pixman_region32_union_rect(&a->explained, &a->explained, box.x, box.y, box.width, box.height);
}
// Paint position of a leaf in this frame (0 = top), or -1 when it is not drawn.
static long position_of(const struct attribution *a, uint64_t leaf) {
    if (!leaf) return -1;
    for (size_t i = 0; i < a->len; i++) if (a->entries[i].item.id == leaf) return (long)i;
    return -1;
}
static bool boxes_meet(const struct wlr_box *a, const struct wlr_box *b) {
    struct wlr_box out;
    return wlr_box_intersection(&out, a, b);
}
static struct effect_cache *cache_for(struct output_state *os, uint64_t serial) {
    struct effect_cache *c;
    wl_list_for_each(c, &os->caches, link) if (c->serial == serial) return c;
    c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->serial = serial;
    wl_list_insert(&os->caches, &c->link);
    return c;
}
// Decides, bottom to top, which effects re-blur: a blur is kept unless something
// painted below the effect, or something no event explains, changed in the region
// it reads, or the region or sigma changed (a held effect keeps it while moving).
// A re-blur changes the effect's own pixels (`changed`). Returns false on
// allocation failure.
bool scene_output_decide_effects(struct rediwm_output_renderer *r, struct output_state *os,
        struct rediwm_scene_output *out, const struct output_view *v, pixman_region32_t *changed) {
    struct entry *entries = r->entries.data;
    const size_t len = r->entries.size / sizeof(*entries);
    struct attribution a = {.output_serial = out->serial, .view = v, .entries = entries, .len = len};
    wl_array_init(&a.events);
    pixman_region32_init(&a.explained);
    bool complete = os->started && rediwm_projection_damage_events(r->projection, &os->cursor, note_event, &a);
    if (!os->started) {
        os->cursor = rediwm_projection_damage_cursor(r->projection);
        os->started = true;
    }
    // A software cursor is drawn over everything, so its damage (where it was and
    // where it is) never changes what a blur reads.
    struct wlr_output_cursor *cursor;
    int ncursors = 0;
    struct wlr_box cursors[4];
    wl_list_for_each(cursor, &out->output->cursors, link) {
        if (ncursors == 4 || !cursor->enabled || !cursor->visible || cursor == out->output->hardware_cursor) continue;
        cursors[ncursors++] = (struct wlr_box){(int)floor(cursor->x) - cursor->hotspot_x - 4,
            (int)floor(cursor->y) - cursor->hotspot_y - 4, (int)cursor->width + 8, (int)cursor->height + 8};
    }
    for (int i = 0; i < os->ncursors; i++)
        pixman_region32_union_rect(&a.explained, &a.explained, os->cursors[i].x, os->cursors[i].y,
            os->cursors[i].width, os->cursors[i].height);
    for (int i = 0; i < ncursors; i++) {
        pixman_region32_union_rect(&a.explained, &a.explained, cursors[i].x, cursors[i].y,
            cursors[i].width, cursors[i].height);
        os->cursors[i] = cursors[i];
    }
    os->ncursors = ncursors;
    // The veil is drawn over every effect, so repainting the output for it changes
    // nothing a blur reads. While it changes, damage no event explains goes
    // unnoticed too; a resize or failed frame still re-blurs on its own.
    if (os->veil_changed)
        pixman_region32_union_rect(&a.explained, &a.explained, 0, 0, v->width, v->height);
    pixman_region32_t unexplained;
    pixman_region32_init(&unexplained);
    pixman_region32_subtract(&unexplained, &out->pending_commit_damage, &a.explained);
    struct effect_cache *c;
    wl_list_for_each(c, &os->caches, link) c->seen = false;
    out->glass_deferred = false;
    bool ok = true;
    for (size_t i = len; i > 0; i--) {
        struct entry *e = &entries[i - 1];
        if (e->item.kind != REDIWM_ITEM_EFFECT) continue;
        e->cache = cache_for(os, e->glass.serial);
        if (!e->cache) { ok = false; continue; }
        c = e->cache;
        c->seen = true;
        const struct wlr_box region = device_box(e->padded, v);
        const float sigma = e->sigma * v->scale;
        const bool same_size = c->valid && c->sigma == sigma && c->region.width == region.width &&
            c->region.height == region.height;
        const bool held = e->glass.held || out->hold_glass;
        bool reblur = !same_size || !complete || (c->carried && !held);
        if (!reblur && (c->region.x != region.x || c->region.y != region.y)) {
            // A held effect carries its last blur along; otherwise a move re-blurs.
            if (held) {
                c->region = region;
                c->carried = true;
            } else {
                reblur = true;
            }
        }
        if (!reblur && !c->carried) {
            const long here = (long)(i - 1);
            struct seen_event *se;
            wl_array_for_each(se, &a.events) {
                if (!boxes_meet(&se->box, &region)) continue;
                const long at = position_of(&a, se->leaf);
                if (at < 0 || at > here) { reblur = true; break; }
            }
            if (!reblur && pixman_region32_contains_rectangle(&unexplained,
                    &(pixman_box32_t){region.x, region.y, region.x + region.width, region.y + region.height}) != PIXMAN_REGION_OUT)
                reblur = true;
            // An effect below that re-blurs changes what this one reads.
            for (size_t j = len; !reblur && j > i; j--) {
                const struct entry *below = &entries[j - 1];
                if (below->item.kind == REDIWM_ITEM_EFFECT && below->reblur) {
                    const struct wlr_box bb = device_box(below->box, v);
                    if (boxes_meet(&bb, &region)) reblur = true;
                }
            }
            // A stationary panel can see the strip moving below it. Keep the
            // old blur now, and refresh once when the hold ends.
            if (held && reblur) {
                c->carried = true;
                reblur = false;
            }
        }
        if (out->hold_glass && c->carried && !reblur) out->glass_deferred = true;
        e->reblur = reblur;
        if (reblur) {
            const struct wlr_box own = device_box(e->box, v);
            pixman_region32_union_rect(changed, changed, own.x, own.y, own.width, own.height);
        }
    }
    pixman_region32_fini(&unexplained);
    pixman_region32_fini(&a.explained);
    wl_array_release(&a.events);
    return ok;
}
