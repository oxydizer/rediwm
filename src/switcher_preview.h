#pragma once
#include <stdbool.h>

struct rediwm_buffer;
struct wlr_surface;

// Follow the surface's current buffer without changing its output/scale feedback
// or frame pacing. Call on every surface commit; NULL clears the binding. Once
// bound, replace/clear content only through this helper. Geometry stays caller-owned.
// The node owns the binding and a destroyed surface clears its content.
bool rediwm_switcher_preview_set_surface(struct rediwm_buffer *, struct wlr_surface *);

// Show what a compositor-owned buffer node (`rediwm_projection_present_owned`)
// presents, keeping its in-place texture updates possible. Call after each
// present; false (and no content) when the source holds no buffer.
bool rediwm_switcher_preview_set_owned(struct rediwm_buffer *, struct rediwm_buffer *source);
