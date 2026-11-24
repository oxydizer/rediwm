// What the owned output pass needs to know about a glass effect (stage 5 of
// docs/plans/scene-graph.md). glass.c only registers effects; the pass blurs.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <pixman.h>
struct rediwm_node;
struct rediwm_buffer;
struct rediwm_glass_region {
  pixman_region32_t local; // clipped surface-local mask
  int count;
  struct rediwm_edges *layout; // the same rectangles after projection
  double x, y, scale; // transform used for layout, scale is zero until resolved
};
struct rediwm_glass_info {
  // The surface the effect backs: drawn over it, same parent, same box.
  struct rediwm_buffer *target;
  struct rediwm_glass_region *region; // NULL for shell effects
  float sigma;      // Gaussian sigma, logical px, before any zoom
  float saturation; // 1 leaves colours unchanged
  float opacity;
  float radius;     // logical px; a window's effect takes the window's shape instead
  // Unique for the effect's life (a node address can be reused).
  uint64_t serial;
  // Keep the last blur while the effect moves (a dragged opaque titlebar, camera motion).
  bool held;
};
// False when `node`  is not a glass effect.
bool rediwm_glass_effect_info(struct rediwm_node *node, struct rediwm_glass_info *out);
bool rediwm_glass_is_effect_node(struct rediwm_node *node);
struct glass_engine;
struct glass_effect;
struct rediwm_surface;
struct rediwm_node *rediwm_glass_node(struct glass_effect *effect);
bool rediwm_glass_set_surface_region(struct glass_engine *engine, struct rediwm_surface *surface,
                                     const pixman_region32_t *region);
