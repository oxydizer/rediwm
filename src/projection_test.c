// Synthetic surface commits into the real projection and wlroots scene damage
// path. No renderer, GPU, socket or host desktop is needed.
// The whole projection in one unit, for its static helpers.
#include "projection.c"
#include "projection_props.c"
#include "projection_resolve.c"
#include "projection_present.c"
#include "projection_pass.c"
#include "projection_pick.c"
#include "node.h"
#include <assert.h>
#include <stdio.h>
#include <wlr/backend.h>
#include <wlr/backend/headless.h>
#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/types/wlr_output_layout.h>


// One own scene and a world layer, per test.
struct rig {
  struct rediwm_scene *own, *parking; // `parking` holds what the pass no longer reaches
  struct rediwm_tree *world;
};
static struct rig rig_create(struct rediwm_scene_outputs *scene) {
  (void)scene;
  struct rig rig = {0};
  rig.own = rediwm_scene_create(NULL, NULL);
  rig.parking = rediwm_scene_create(NULL, NULL);
  assert(rig.own && rig.parking);
  rig.world = rediwm_tree_create(&rig.own->tree);
  assert(rig.world);
  return rig;
}
static void rig_destroy(struct rig *rig) {
  rediwm_scene_destroy(rig->own);
  rediwm_scene_destroy(rig->parking);
}
static struct leaf *leaf_of(struct rediwm_projection *p, struct rediwm_node *node) {
  struct leaf *l = node->leaf;
  return l && l->projection == p ? l : NULL;
}

static struct rediwm_node *pick(struct rediwm_projection *p, double x, double y, double *nx, double *ny) {
  struct rediwm_hit hit;
  if (!rediwm_projection_node_at(p, x, y, &hit)) return NULL;
  if (nx) *nx = hit.x;
  if (ny) *ny = hit.y;
  return hit.own;
}

static struct rediwm_node *effect_node;
bool rediwm_glass_is_effect_node(struct rediwm_node *node) {
  return node == effect_node;
}
// glass.c is not linked here: the stub effect keeps its own box.
bool rediwm_glass_effect_info(struct rediwm_node *node, struct rediwm_glass_info *out) {
  (void)node;
  (void)out;
  return false;
}
static void buffer_destroy(struct wlr_buffer *buffer) { free(buffer); }
static const struct wlr_buffer_impl buffer_impl = {.destroy = buffer_destroy};
static struct wlr_buffer *buffer_create(void) {
  struct wlr_buffer *buffer = calloc(1, sizeof(*buffer));
  assert(buffer);
  wlr_buffer_init(buffer, &buffer_impl, 200, 120);
  return buffer;
}
static void commit_damage(struct leaf *l, int x, int y, int width, int height) {
  struct wlr_surface *surface = l->surface->surface;
  pixman_region32_clear(&surface->buffer_damage);
  assert(pixman_region32_union_rect(&surface->buffer_damage,
      &surface->buffer_damage, x, y, width, height));
  surface->current.committed |= WLR_SURFACE_STATE_BUFFER; // an attach
  committed(&l->commit, NULL);
}
static bool damaged(struct rediwm_scene_output *out, int x, int y) {
  return pixman_region32_contains_point(&out->damage_ring.current, x, y, NULL);
}
static void clear_damage(struct rediwm_scene_output *out) {
  pixman_region32_clear(&out->damage_ring.current);
  pixman_region32_clear(&out->pending_commit_damage);
}
// Where the graph puts a leaf once rounded in layout space.
static void assert_position(struct rediwm_projection *p,
                            struct rediwm_node *source, int x, int y) {
  struct leaf *l = leaf_of(p, source);
  assert(l);
  const struct rediwm_snap s = rediwm_edges_snap(l->item.edges);
  assert(s.x == x && s.y == y);
}
// Runs when a window's source tree is destroyed, after the projection dropped its
// group and before the leaves are destroyed with their nodes. A leaf that still
// listed itself in that group would point into freed memory here; no allocator
// reliably shows that (glibc does not poison small chunks on free), so check
// the links themselves.
struct probe {
  struct wl_listener listener;
  struct leaf *leaves[8];
  size_t count;
  int *checks;
};
static void probe_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct probe *probe = wl_container_of(listener, probe, listener);
  for (size_t i = 0; i < probe->count; i++) {
    assert(probe->leaves[i]->paint.next == &probe->leaves[i]->paint &&
           probe->leaves[i]->paint.prev == &probe->leaves[i]->paint);
    ++*probe->checks;
  }
  wl_list_remove(&listener->link);
  free(probe);
}
static void probe_group(struct group *g, int *checks) {
  struct probe *probe = calloc(1, sizeof(*probe));
  assert(probe);
  struct leaf *l;
  wl_list_for_each(l, &g->items, paint) {
    assert(probe->count < 8);
    probe->leaves[probe->count++] = l;
  }
  probe->checks = checks;
  probe->listener.notify = probe_destroy;
  wl_signal_add(&g->source->events.destroy, &probe->listener);
}
static bool near(double a, double b) { return fabs(a - b) < 1e-9; }
static size_t items_of(struct group *g, struct leaf **out, size_t max) {
  size_t n = 0;
  struct leaf *l;
  wl_list_for_each(l, &g->items, paint) {
    assert(n < max);
    out[n++] = l;
  }
  return n;
}
// What a sync leaves: every group and leaf in the lists was reached by this pass,
// and nothing else is listed.
static void assert_presented(struct rediwm_projection *p) {
  struct group *g;
  wl_list_for_each(g, &p->paint, paint) {
    assert(g->seen);
    struct leaf *l;
    wl_list_for_each(l, &g->items, paint) assert(l->seen);
  }
}
// The typed graph: complete and in paint order before anything is presented,
// unrounded, and the only source of geometry.
struct graph_probe {
  struct rediwm_node *transport;
  struct rediwm_item expected;
  int count;
};
static bool probe_item(const struct rediwm_item *item, struct rediwm_node *transport, void *data) {
  struct graph_probe *probe = data;
  if (transport != probe->transport) return true;
  probe->count++;
  assert(item->edges.x1 == probe->expected.edges.x1 && item->edges.y1 == probe->expected.edges.y1);
  assert(item->edges.x2 == probe->expected.edges.x2 && item->edges.y2 == probe->expected.edges.y2);
  assert(item->kind == probe->expected.kind && rediwm_content_equal(&item->content, &probe->expected.content));
  return true;
}

#include "projection_test_graph.c"
#include "projection_test_damage.c"
#include "projection_test_ribbon.c"
#include "projection_test_groups.c"
#include "projection_test_sector.c"

int main(void) {
  struct wl_display *display = wl_display_create();
  assert(display);
  struct wlr_backend *backend = wlr_headless_backend_create(wl_display_get_event_loop(display));
  assert(backend);
  struct wlr_output *output = wlr_headless_add_output(backend, 640, 480);
  assert(output);
  struct wlr_output_state state;
  wlr_output_state_init(&state);
  wlr_output_state_set_enabled(&state, true);
  assert(wlr_output_commit_state(output, &state));
  wlr_output_state_finish(&state);
  struct wlr_output_layout *layout = wlr_output_layout_create(display);
  assert(layout);
  struct rediwm_scene_outputs *scene = rediwm_scene_outputs_create(layout);
  assert(scene);
  struct rediwm_scene_output *out = rediwm_scene_output_create(scene, output, NULL);
  assert(out);
  struct rig rig = rig_create(scene);
  struct rediwm_tree *source = rig.world;
  struct rediwm_projection *p = rediwm_projection_create(rig.own, source, scene);
  assert(p);
  struct wlr_buffer *a = buffer_create(), *b = buffer_create();
  struct rediwm_buffer *node = rediwm_buffer_create(source, a);
  assert(node);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(out, 100, 60)); // First presentation is fully damaged.
  clear_damage(out);

  struct leaf *l = leaf_of(p, &node->node);
  struct wlr_surface surface = {.current = {.buffer_width = 200, .buffer_height = 120}};
  pixman_region32_init(&surface.buffer_damage);
  struct rediwm_surface scene_surface = {.surface = &surface};
  l->surface = &scene_surface;
  l->damage_width = 200;
  l->damage_height = 120;

  // Both commits must survive until presentation, despite the final empty
  // commit. No buffer pointer change is needed for pixels to change.
  commit_damage(l, 10, 10, 4, 4);
  commit_damage(l, 170, 90, 4, 4);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(out, 11, 11) && damaged(out, 171, 91));
  assert(!damaged(out, 100, 60));
  clear_damage(out);

  // A commit that attaches and damages nothing (a client only asking for a frame
  // callback) leaves the leaf and its group clean.
  surface.current.committed = 0;
  pixman_region32_clear(&surface.buffer_damage);
  committed(&l->commit, NULL);
  assert(!l->dirty && !p->any_dirty);

  // Rotation with empty damage is not a repaint; rotation with partial damage
  // must retain only that region. The source tree itself is disabled.
  rediwm_buffer_set_buffer(node, b);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));
  rediwm_buffer_set_buffer(node, a);
  commit_damage(l, 20, 20, 4, 4);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(out, 21, 21) && !damaged(out, 100, 60));
  clear_damage(out);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));

  // Mapping invalidations remain sticky through later commits, even if a
  // buffer resize or viewport change is reverted before presentation.
  const uint32_t mappings[] = {WLR_SURFACE_STATE_VIEWPORT,
      WLR_SURFACE_STATE_SCALE, WLR_SURFACE_STATE_TRANSFORM};
  for (size_t i = 0; i < sizeof(mappings) / sizeof(mappings[0]); ++i) {
    surface.current.committed = mappings[i];
    commit_damage(l, 0, 0, 0, 0);
    surface.current.committed = 0;
    commit_damage(l, 0, 0, 0, 0);
    rediwm_projection_sync(p, 1, 0, 0, 0, 0);
    assert(damaged(out, 100, 60));
    clear_damage(out);
  }
  surface.current.buffer_width = 240;
  commit_damage(l, 0, 0, 0, 0);
  surface.current.buffer_width = 200;
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(out, 100, 60));
  clear_damage(out);

  // Cropping and fractional zoom use wlroots' buffer-to-output damage mapping,
  // including filtering expansion, rather than treating buffer pixels as scene
  // coordinates.
  rediwm_buffer_set_source_box(node, &(struct wlr_fbox){20, 20, 100, 60});
  rediwm_buffer_set_dest_size(node, 100, 60);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  clear_damage(out);
  commit_damage(l, 40, 40, 4, 4);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 10, 10) && !damaged(out, 30, 20));
  clear_damage(out);
  commit_damage(l, 0, 0, 4, 4); // Fully outside the viewport.
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));

  wlr_output_state_init(&state);
  wlr_output_state_set_scale(&state, 1.5f);
  assert(wlr_output_commit_state(output, &state));
  wlr_output_state_finish(&state);
  clear_damage(out);
  commit_damage(l, 40, 40, 4, 4);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 15, 15) && !damaged(out, 45, 30));
  clear_damage(out);

  // Geometry changes still damage both the old and new location, independently
  // of client buffer damage. Re-enabling a hidden node must repaint it too.
  rediwm_node_set_position(&node->node, 200, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 20, 20) && damaged(out, 170, 20));
  clear_damage(out);
  rediwm_node_set_enabled(&node->node, false);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  clear_damage(out);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  rediwm_node_set_enabled(&node->node, true);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 170, 20));
  rediwm_node_set_position(&node->node, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  clear_damage(out);

  // Unmap/remap must repaint even when the remapping commit has empty damage.
  rediwm_buffer_set_buffer(node, NULL);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  clear_damage(out);
  rediwm_buffer_set_buffer(node, a);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 25, 15));

  l->surface = NULL; // Synthetic surface has no lifecycle listeners to route.
  pixman_region32_fini(&surface.buffer_damage);
  rediwm_projection_destroy(p);
  test_groups(scene, out);
  test_graph(scene);
  test_clean_sync(scene);
  test_clip_geometry();
  test_polygon_geometry();
  test_sector_geometry();
  test_sector_projection(scene, out);
  test_clip_opaque();
  test_clip_projection(scene);
  test_clip_output(scene, out);
  test_shadow_output(scene, out);
  test_ribbon_output(scene, out);
  test_damage_events(scene);
  test_dim(scene);
  test_graph_damage(scene, out);
  test_feedback(scene, backend, out, output);
  test_opaque();
  rediwm_scene_outputs_destroy(scene);
  wlr_output_layout_destroy(layout);
  wlr_buffer_drop(a);
  wlr_buffer_drop(b);
  wlr_backend_destroy(backend);
  wl_display_destroy(display);
  puts("PASS: projection damage, feedback, grouping, geometry, graph, opaque regions and lifecycle");
  return 0;
}
