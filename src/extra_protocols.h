#pragma once
#include <stdbool.h>
struct wl_display;
struct wlr_backend;
struct wlr_renderer;
struct wlr_scene;
struct wlr_output_layout;
struct wlr_output;
struct wlr_surface;
struct rediwm_protocols;
struct rediwm_protocols *rediwm_protocols_create(struct wl_display *, struct wlr_backend *, struct wlr_renderer *, struct wlr_scene *, struct wlr_output_layout *, void *, bool (*)(void *), void (*)(void *, struct wlr_surface *));
void rediwm_protocols_destroy(struct rediwm_protocols *);
void rediwm_protocols_offer(struct rediwm_protocols *, struct wlr_output *);
void rediwm_protocols_revoke(struct rediwm_protocols *);
bool rediwm_protocols_tearing(struct rediwm_protocols *, struct wlr_surface *);
const char *rediwm_protocols_content(struct rediwm_protocols *, struct wlr_surface *);
const char *rediwm_surface_tag(struct wlr_surface *, bool description);
bool rediwm_surface_edge_is_srgb(struct wlr_surface *);
