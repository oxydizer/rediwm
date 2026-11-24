#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "surface_feedback.h"
#include <stdlib.h>
#include <string.h>
#include <wlr/types/wlr_color_management_v1.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_output.h>

struct preference {
    struct wlr_addon addon;
    struct wl_list link;
    struct wlr_surface *surface;
    struct rediwm_color_feedback *feedback;
    struct wlr_image_description_v1_data description;
};
static void forget(struct wlr_addon *addon) {
    struct preference *p = wl_container_of(addon, p, addon);
    struct rediwm_color_feedback *f = p->feedback;
    wl_list_remove(&p->link);
    wlr_addon_finish(addon);
    free(p);
    if (wl_list_empty(&f->hdr_surfaces)) {
        if (f->requests) wl_protocol_logger_destroy(f->requests);
        if (f->idle) wl_event_source_remove(f->idle);
        f->requests = NULL;
        f->idle = NULL;
    }
}
static const struct wlr_addon_interface preference_impl = {"rediwm-color-preference", forget};
static void refresh(void *data) {
    struct rediwm_color_feedback *f = data;
    f->idle = NULL;
    struct preference *p;
    wl_list_for_each(p, &f->hdr_surfaces, link)
        wlr_color_manager_v1_set_surface_preferred_image_description(f->manager, p->surface, &p->description);
}
static void request(void *data, enum wl_protocol_logger_type direction, const struct wl_protocol_logger_message *msg) {
    if (direction != WL_PROTOCOL_LOGGER_REQUEST || msg->message->name[0] != 'g') return;
    struct rediwm_color_feedback *f = data;
    // The logger runs before wlroots handles a request. Refresh after the new
    // object exists, including when the client queues get_preferred immediately.
    if (!strcmp(msg->message->name, "get_surface_feedback") &&
            !strcmp(wl_resource_get_class(msg->resource), "wp_color_manager_v1")) {
        if (!f->idle) f->idle = wl_event_loop_add_idle(wl_display_get_event_loop(f->display), refresh, f);
    } else if (f->idle && !strcmp(wl_resource_get_class(msg->resource), "wp_color_management_surface_feedback_v1")) {
        wl_event_source_remove(f->idle);
        refresh(f);
    }
}
void rediwm_color_feedback_set(struct rediwm_color_feedback *f, struct wlr_surface *surface,
        const struct wlr_output_image_description *d) {
    struct wlr_image_description_v1_data desc = {
        .tf_named = WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_GAMMA22,
        .primaries_named = WP_COLOR_MANAGER_V1_PRIMARIES_SRGB,
    };
    struct wlr_addon *addon = wlr_addon_find(&surface->addons, f, &preference_impl);
    if (d) {
        desc.tf_named = wlr_color_manager_v1_transfer_function_from_wlr(d->transfer_function);
        desc.primaries_named = wlr_color_manager_v1_primaries_from_wlr(d->primaries);
        desc.has_mastering_display_primaries = true;
        desc.mastering_display_primaries = d->mastering_display_primaries;
        desc.has_mastering_luminance = d->mastering_luminance.max > 0;
        desc.mastering_luminance.min = d->mastering_luminance.min;
        desc.mastering_luminance.max = d->mastering_luminance.max;
        desc.max_cll = d->max_cll;
        desc.max_fall = d->max_fall;
        struct preference *p = addon ? wl_container_of(addon, p, addon) : calloc(1, sizeof(*p));
        if (p) {
            if (!addon) {
                p->surface = surface;
                p->feedback = f;
                wlr_addon_init(&p->addon, &surface->addons, f, &preference_impl);
                wl_list_insert(&f->hdr_surfaces, &p->link);
            }
            p->description = desc;
            if (!f->requests) f->requests = wl_display_add_protocol_logger(f->display, request, f);
        }
    } else if (addon) forget(addon);
    wlr_color_manager_v1_set_surface_preferred_image_description(f->manager, surface, &desc);
}
void rediwm_color_feedback_finish(struct rediwm_color_feedback *f) {
    struct preference *p, *next;
    wl_list_for_each_safe(p, next, &f->hdr_surfaces, link) forget(&p->addon);
}
