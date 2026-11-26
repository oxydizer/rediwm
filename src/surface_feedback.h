#pragma once
#include <wayland-server-core.h>
struct wlr_color_manager_v1;
struct wlr_surface;
struct wlr_output_image_description;

// wlroots initialises each newly requested feedback object to SDR. Keep the
// current preferences for HDR surfaces so a late subscriber also gets them.
struct rediwm_color_feedback {
    struct wl_display *display;
    struct wlr_color_manager_v1 *manager;
    struct wl_list hdr_surfaces;
    struct wl_protocol_logger *requests;
    struct wl_event_source *idle;
};
void rediwm_color_feedback_set(struct rediwm_color_feedback *, struct wlr_surface *,
    const struct wlr_output_image_description *);
void rediwm_color_feedback_finish(struct rediwm_color_feedback *);
