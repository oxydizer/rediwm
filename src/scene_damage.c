// Damage for changes that move no view node. Needs only wlroots' scene, so the
// projection's tests can link it without the GL pass.
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "scene_damage.h"
#include "scene_view.h"
#include <wlr/types/wlr_damage_ring.h>
#include <wlr/types/wlr_output.h>
#include "scene_outputs.h"

// Damage a layout-space region on every output it touches, as a node update
// would: the ring and the commit damage, in device pixels, and a frame request.
// For changes the graph shows only as a different clip (a border colour), which
// move no view node.
void rediwm_scene_damage_layout(struct rediwm_scene_outputs *outputs, const pixman_region32_t *region) {
    struct rediwm_scene_output *out;
    wl_list_for_each(out, &outputs->outputs, link) {
        struct wlr_output *output = out->output;
        struct output_view v = {.width = output->width, .height = output->height,
            .scale = output->scale, .transform = output->transform,
            .logical = {.x = out->x, .y = out->y}};
        v.trans_width = v.width;
        v.trans_height = v.height;
        wlr_output_transform_coords(v.transform, &v.trans_width, &v.trans_height);
        v.logical.width = v.trans_width / v.scale;
        v.logical.height = v.trans_height / v.scale;
        pixman_region32_t device;
        pixman_region32_init(&device);
        pixman_region32_intersect_rect(&device, (pixman_region32_t *)region, v.logical.x, v.logical.y,
            v.logical.width, v.logical.height);
        if (pixman_region32_not_empty(&device)) {
            output_view_region(&device, &v, true);
            pixman_region32_intersect_rect(&device, &device, 0, 0, v.width, v.height);
            wlr_damage_ring_add(&out->damage_ring, &device);
            pixman_region32_union(&out->pending_commit_damage,
                &out->pending_commit_damage, &device);
            rediwm_trace_damage(output);
            wlr_output_schedule_frame(output);
        }
        pixman_region32_fini(&device);
    }
}
