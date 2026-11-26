// Tree properties: zoom, scale, clip, shadow, dim, unclipped and inert, kept in
// one addon per source tree (see struct tree_props). Part of projection.c.
#include "projection_internal.h"

static void destroy_tree_props(struct wlr_addon *addon) {
  struct tree_props *props = wl_container_of(addon, props, addon);
  if (props->slot) *props->slot = NULL;
  wlr_addon_finish(addon);
  free(props);
}
const struct wlr_addon_interface projection_tree_props_impl = {
    .name = "rediwm tree presentation", .destroy = destroy_tree_props};
static struct tree_props *tree_props_get(struct wlr_addon_set *set, void **slot) {
  struct tree_props *props = tree_props_find(set, slot);
  if (props) return props;
  props = calloc(1, sizeof(*props));
  if (!props) return NULL;
  props->slot = slot;
  if (slot) *slot = props;
  wlr_addon_init(&props->addon, set, NULL, &projection_tree_props_impl);
  return props;
}
// Set by a setter that changed something, so the wrappers below ask for a frame only
// then: a window's zoom and clip are applied every frame and mostly unchanged.
static bool props_changed;
static bool set_tree_zoom(struct wlr_addon_set *set, void **slot, double scale) {
  struct tree_props *props = tree_props_get(set, slot);
  if (!props) return false;
  if (!props->has_zoom || props->zoom != scale) props_changed = true;
  props->zoom = scale;
  props->has_zoom = true;
  return true;
}
static bool set_tree_scale(struct wlr_addon_set *set, void **slot, double factor) {
  if (factor <= 0) return false;
  struct tree_props *props = tree_props_get(set, slot);
  if (!props) return false;
  if (!props->has_scale || props->scale != factor) props_changed = true;
  props->scale = factor;
  props->has_scale = true;
  return true;
}
static bool finite_at_least_zero(double value) { return isfinite(value) && value >= 0; }
// Field by field, not memcmp: zig cc lowers memcmp() != 0 to compiler-rt's bytewise
// bcmp, and a window's clip and shadow (about 430 bytes each, mostly unused polygon
// vertices) are applied on every client commit.
static bool doubles_equal(const double *a, const double *b, int n) {
  for (int i = 0; i < n; i++)
    if (a[i] != b[i]) return false;
  return true;
}
static bool floats_equal(const float *a, const float *b, int n) {
  for (int i = 0; i < n; i++)
    if (a[i] != b[i]) return false;
  return true;
}
static bool polygons_equal(const double a[][2], const double b[][2], int count) {
  return doubles_equal(&a[0][0], &b[0][0], 2 * count);
}
static bool clip_spec_equal(const struct rediwm_clip_spec *a, const struct rediwm_clip_spec *b) {
  return a->width == b->width && a->height == b->height && a->poly_count == b->poly_count &&
      doubles_equal(a->radii, b->radii, 4) && a->border == b->border &&
      floats_equal(a->border_color, b->border_color, 4) && a->glow_x == b->glow_x &&
      a->glow_y == b->glow_y && a->glow_radius == b->glow_radius && a->glow_depth == b->glow_depth &&
      floats_equal(a->glow_color, b->glow_color, 4) && polygons_equal(a->poly, b->poly, a->poly_count) &&
      doubles_equal(a->sector.center, b->sector.center, 2) && doubles_equal(a->sector.radii, b->sector.radii, 2) &&
      doubles_equal(a->sector.axis, b->sector.axis, 2) &&
      doubles_equal(a->sector.half_angle, b->sector.half_angle, 2) &&
      a->sector_texture_height == b->sector_texture_height;
}
static bool shadow_spec_equal(const struct rediwm_shadow_spec *a, const struct rediwm_shadow_spec *b) {
  return a->width == b->width && a->height == b->height && a->poly_count == b->poly_count &&
      doubles_equal(a->radii, b->radii, 4) && a->offset_x == b->offset_x && a->offset_y == b->offset_y &&
      a->softness == b->softness && floats_equal(a->color, b->color, 4) &&
      polygons_equal(a->poly, b->poly, a->poly_count);
}
// 0 is no polygon. Otherwise 3 to REDIWM_POLY_MAX finite vertices inside the box,
// none the same as the next (a zero-length edge has no direction).
static bool valid_polygon(const double v[][2], int count, int width, int height) {
  if (count == 0) return true;
  if (count < 3 || count > REDIWM_POLY_MAX) return false;
  for (int i = 0; i < count; i++) {
    const double *a = v[i], *b = v[i + 1 < count ? i + 1 : 0];
    if (!isfinite(a[0]) || !isfinite(a[1]) || a[0] < 0 || a[1] < 0 || a[0] > width || a[1] > height) return false;
    if (a[0] == b[0] && a[1] == b[1]) return false;
  }
  return true;
}
static bool set_tree_clip(struct wlr_addon_set *set, void **slot,
                                     const struct rediwm_clip_spec *spec) {
  if (!spec) {
    struct tree_props *props = tree_props_find(set, slot);
    if (props && props->has_clip) props_changed = true;
    if (props) props->has_clip = false;
    return true;
  }
  if (spec->width <= 0 || spec->height <= 0 || !finite_at_least_zero(spec->border)) return false;
  if (!valid_polygon(spec->poly, spec->poly_count, spec->width, spec->height)) return false;
  if (!rediwm_sector_valid(&spec->sector) || (spec->sector.radii[1] > 0 && spec->poly_count != 0)) return false;
  if (!finite_at_least_zero(spec->sector_texture_height) ||
      (spec->sector_texture_height > 0 && spec->sector.radii[1] <= 0)) return false;
  for (int i = 0; i < 4; i++)
    if (!finite_at_least_zero(spec->radii[i]) || !isfinite(spec->border_color[i]) ||
        !isfinite(spec->glow_color[i]))
      return false;
  if (!isfinite(spec->glow_x) || !isfinite(spec->glow_y) || !finite_at_least_zero(spec->glow_radius) ||
      !finite_at_least_zero(spec->glow_depth))
    return false;
  struct tree_props *props = tree_props_get(set, slot);
  if (!props) return false;
  if (!props->has_clip || !clip_spec_equal(&props->clip, spec)) props_changed = true;
  props->clip = *spec;
  props->has_clip = true;
  return true;
}
static bool set_tree_shadow(struct wlr_addon_set *set, void **slot,
                                       const struct rediwm_shadow_spec *spec) {
  if (!spec) {
    struct tree_props *props = tree_props_find(set, slot);
    if (props && props->has_shadow) props_changed = true;
    if (props) props->has_shadow = false;
    return true;
  }
  if (spec->width <= 0 || spec->height <= 0 || !finite_at_least_zero(spec->softness) ||
      !isfinite(spec->offset_x) || !isfinite(spec->offset_y))
    return false;
  if (!valid_polygon(spec->poly, spec->poly_count, spec->width, spec->height)) return false;
  for (int i = 0; i < 4; i++)
    if (!finite_at_least_zero(spec->radii[i]) || !isfinite(spec->color[i])) return false;
  struct tree_props *props = tree_props_get(set, slot);
  if (!props) return false;
  if (!props->has_shadow || !shadow_spec_equal(&props->shadow, spec)) props_changed = true;
  props->shadow = *spec;
  props->has_shadow = true;
  return true;
}
static bool set_tree_dim(struct wlr_addon_set *set, void **slot, float brightness, float saturation) {
  if (!isfinite(brightness) || !isfinite(saturation) || brightness < 0 || brightness > 1 ||
      saturation < 0 || saturation > 1)
    return false;
  if (brightness == 0 && saturation == 0) {
    // Nothing taken away is no dim; a tree that has none gets no addon for it.
    struct tree_props *props = tree_props_find(set, slot);
    if (props && props->has_dim) props_changed = true;
    if (props) props->has_dim = false;
    return true;
  }
  struct tree_props *props = tree_props_get(set, slot);
  if (!props) return false;
  if (!props->has_dim || props->dim.brightness != brightness || props->dim.saturation != saturation) props_changed = true;
  props->dim = (struct dim){brightness, saturation};
  props->has_dim = true;
  return true;
}
static bool set_tree_unclipped(struct wlr_addon_set *set, void **slot, bool unclipped) {
  struct tree_props *props = unclipped ? tree_props_get(set, slot) : tree_props_find(set, slot);
  if (unclipped && !props) return false;
  if (props && props->unclipped != unclipped) props_changed = true;
  if (props) props->unclipped = unclipped;
  return true;
}
static bool set_tree_inert(struct wlr_addon_set *set, void **slot, bool inert) {
  struct tree_props *props = inert ? tree_props_get(set, slot) : tree_props_find(set, slot);
  if (inert && !props) return false;
  if (props && props->inert != inert) props_changed = true;
  if (props) props->inert = inert;
  return true;
}

bool rediwm_projection_set_tree_zoom(struct rediwm_node *node, double scale) { props_changed = false; bool ok = set_tree_zoom(&node->addons, &node->props, scale); if (props_changed) rediwm_node_touch(node); return ok; }
bool rediwm_projection_set_tree_scale(struct rediwm_node *node, double factor) { props_changed = false; bool ok = set_tree_scale(&node->addons, &node->props, factor); if (props_changed) rediwm_node_touch(node); return ok; }
bool rediwm_projection_set_tree_clip(struct rediwm_node *node, const struct rediwm_clip_spec *spec) { props_changed = false; bool ok = set_tree_clip(&node->addons, &node->props, spec); if (props_changed) rediwm_node_touch(node); return ok; }
bool rediwm_projection_set_tree_shadow(struct rediwm_node *node, const struct rediwm_shadow_spec *spec) { props_changed = false; bool ok = set_tree_shadow(&node->addons, &node->props, spec); if (props_changed) rediwm_node_touch(node); return ok; }
bool rediwm_projection_set_tree_dim(struct rediwm_node *node, float brightness, float saturation) { props_changed = false; bool ok = set_tree_dim(&node->addons, &node->props, brightness, saturation); if (props_changed) rediwm_node_touch(node); return ok; }
bool rediwm_projection_set_tree_unclipped(struct rediwm_node *node, bool unclipped) { props_changed = false; bool ok = set_tree_unclipped(&node->addons, &node->props, unclipped); if (props_changed) rediwm_node_touch(node); return ok; }
bool rediwm_projection_set_tree_inert(struct rediwm_node *node, bool inert) { props_changed = false; bool ok = set_tree_inert(&node->addons, &node->props, inert); if (props_changed) rediwm_node_touch(node); return ok; }

bool rediwm_projection_set_tree_output(struct rediwm_node *node, struct rediwm_scene_output *out) {
  struct tree_props *props = out ? tree_props_get(&node->addons, &node->props) : node->props;
  if (!props) return out == NULL;
  const uint64_t home = out ? out->serial : 0;
  if (props->home_output != home) {
    props->home_output = home;
    rediwm_node_touch(node);
  }
  return true;
}
