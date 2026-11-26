#pragma once
#include <stdbool.h>
struct wl_display;
struct glass_engine;
struct rediwm_surface;

bool rediwm_background_effect_create(struct wl_display *display, struct glass_engine *engine);
void rediwm_background_effect_update(struct rediwm_surface *surface, int width, int height);
