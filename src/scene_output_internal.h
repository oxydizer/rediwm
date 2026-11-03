// Private to scene_output*.c: what the output pass keeps per output and builds
// per frame, and the device-space helpers every part uses (`static inline`, so a
// file boundary costs them no inlining). Everyone else uses scene_output.h.
#ifndef REDIWM_SCENE_OUTPUT_INTERNAL_H
#define REDIWM_SCENE_OUTPUT_INTERNAL_H

#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "scene_output.h"
#include "scene_outputs.h"
#include "scene_view.h"
#include "scene_pass.h"
#include "scene_graph.h"
#include "projection.h"
#include "glass.h"
#include "ribbon.h"
#include "node.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#ifdef REDIWM_DAMAGE_AUDIT
#include <drm_fourcc.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#endif
#include <wlr/render/drm_syncobj.h>
#include <wlr/render/swapchain.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_damage_ring.h>
#include <wlr/types/wlr_output.h>
#include "node.h"
#include <wlr/util/log.h>
#include <wlr/util/region.h>
#include <wlr/util/transform.h>

// Stage 5c: a glass effect's blur, kept per effect and output between frames
// (D1, D3 of docs/plans/scene-graph-stage5.md) and re-taken only when something
// below the effect changed in the region it reads.
struct effect_cache {
    struct wl_list link;
    uint64_t serial;               // rediwm_glass_info.serial
    struct rediwm_backdrop *backdrop;
    struct wlr_box region;         // device pixels the blur covers
    float sigma;                   // device pixels
    bool valid, seen;
    // A hold moved the blur without re-taking it: re-take it once released.
    bool carried;
};
struct output_state {
    struct wl_list link;
    struct rediwm_output_renderer *renderer;
    struct wlr_output *output;
    struct wl_listener destroy;
    uint64_t cursor;               // into the projection's damage events
    bool started;
    // Software cursors drawn last frame (device pixels), whose damage now is old.
    struct wlr_box cursors[4];
    int ncursors;
    struct wl_list caches;
    // rediwm_scene_output_set_veil: black over the frame (0 to 1), and whether it
    // changed since the last frame was built, so that change re-blurs no glass.
    float veil;
    bool veil_changed;
};
struct entry {
    struct rediwm_item item;
    struct rediwm_node *transport;
    struct wlr_box box; // snap of item edges in layout space
    pixman_region32_t visible, opaque;
    bool sampled;
    // Effects only: what glass registered, the box the blur reads (layout, the
    // target's grown by three sigma), the surface drawn over it, and whether
    // this frame takes a new blur.
    struct rediwm_glass_info glass;
    struct wlr_box padded;
    float sigma; // layout pixels
    struct rediwm_node *front;
    struct effect_cache *cache;
    bool reblur;
};
struct rediwm_output_renderer {
    struct rediwm_scene_renderer *pass;
    struct wl_array entries; // reusable scratch; no retained resource references
    struct wl_list outputs;  // output_state
    struct rediwm_projection *projection; // of the frame being built
    bool has_backdrops;
};
// Stage 3 parity deliberately retains the legacy layout snap, then snaps
// output-scaled edges. Removing that first snap is a geometry change, not a
// renderer switch. No view node position/size is consulted here.
static inline struct wlr_box device_box(struct wlr_box box, const struct output_view *v) {
    box.x -= v->logical.x;
    box.y -= v->logical.y;
    int x2 = round((box.x + box.width) * v->scale);
    int y2 = round((box.y + box.height) * v->scale);
    box.x = round(box.x * v->scale);
    box.y = round(box.y * v->scale);
    box.width = x2 - box.x;
    box.height = y2 - box.y;
    wlr_box_transform(&box, &box, wlr_output_transform_invert(v->transform),
        v->trans_width, v->trans_height);
    return box;
}
static inline void device_region(pixman_region32_t *region, const struct output_view *v, bool expand) {
    output_view_region(region, v, expand);
}
struct collector {
    struct rediwm_output_renderer *renderer;
    const struct output_view *view;
    // The logical boxes of the other enabled outputs.
    struct wlr_box other[15];
    int others;
    pixman_region32_t covered;
    // A window's items are contiguous and share one clip, so its cover is built
    // once for the run rather than for each of its six or so items.
    struct rediwm_clip cover_of;
    pixman_region32_t cover;
    bool has_cover;
    // What the effects visited so far read (layout): items there are kept even
    // where surfaces above hide them, for the blurs only (stage 5f).
    pixman_region32_t reads;
};

// Shared between the parts (scene_output_*.c).
void scene_output_render_ribbon(struct entry *, struct wlr_render_pass *,
    const struct output_view *, struct wlr_box, const pixman_region32_t *);
extern uint64_t rediwm_scene_output_reblurs;
bool scene_output_collect(const struct rediwm_item *item, struct rediwm_node *transport, void *data);
void scene_output_clear_entries(struct rediwm_output_renderer *r);
bool scene_output_decide_effects(struct rediwm_output_renderer *r, struct output_state *os,
        struct rediwm_scene_output *out, const struct output_view *v, pixman_region32_t *changed);
bool scene_output_render_entry(struct rediwm_output_renderer *r, struct entry *e, struct rediwm_scene_output *out,
    struct wlr_render_pass *pass, const struct output_view *v, pixman_region32_t *damage, bool backdrop);

#endif
