// Synthetic surface commits into the real projection and wlroots scene damage
// path. No renderer, GPU, socket or host desktop is needed.
#include "projection.c"
#include <assert.h>
#include <stdio.h>
#include <wlr/backend.h>
#include <wlr/backend/headless.h>
#include <wlr/interfaces/wlr_buffer.h>

bool rediwm_glass_is_effect_node(struct wlr_scene_node *node) {
  (void)node;
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
  committed(&l->commit, NULL);
}
static bool damaged(struct wlr_scene_output *out, int x, int y) {
  return pixman_region32_contains_point(&out->damage_ring.current, x, y, NULL);
}
static void clear_damage(struct wlr_scene_output *out) {
  pixman_region32_clear(&out->damage_ring.current);
  pixman_region32_clear(&out->private.pending_commit_damage);
}
static void assert_position(struct rediwm_projection *p,
                            struct wlr_scene_node *source, int x, int y) {
  struct wlr_scene_node *view = rediwm_projection_node(p, source);
  assert(view && rediwm_projection_source(view) == source);
  int actual_x = 0, actual_y = 0;
  assert(wlr_scene_node_coords(view, &actual_x, &actual_y));
  assert(actual_x == x && actual_y == y);
}
static void test_groups(struct wlr_scene *scene, struct wlr_scene_output *out) {
  struct wlr_scene_tree *source = wlr_scene_tree_create(&scene->tree);
  struct wlr_scene_tree *view = wlr_scene_tree_create(&scene->tree);
  struct rediwm_projection *p = rediwm_projection_create(source, view, scene);
  assert(p);
  struct wlr_scene_tree *frame = wlr_scene_tree_create(source);
  struct wlr_scene_tree *nested = wlr_scene_tree_create(frame);
  struct wlr_scene_tree *other = wlr_scene_tree_create(source);
  float color[4] = {.2, .3, .1, 1};
  struct wlr_scene_rect *border = wlr_scene_rect_create(frame, 17, 9, color);
  struct wlr_buffer *buffer = buffer_create();
  struct wlr_scene_buffer *client = wlr_scene_buffer_create(nested, buffer);
  struct wlr_scene_rect *overlay = wlr_scene_rect_create(other, 20, 20, color);
  assert(frame && nested && other && border && client && overlay);
  wlr_scene_node_set_position(&frame->node, 37, 29);
  wlr_scene_node_set_position(&nested->node, -12, 5);
  wlr_scene_node_set_position(&client->node, 4, 3);
  wlr_scene_node_set_position(&border->node, -2, -3);
  wlr_scene_node_set_position(&other->node, 90, 60);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct group *g = get_group(p, &frame->node);
  struct group *h = get_group(p, &other->node);
  struct leaf *l = get_leaf(p, &client->node);
  assert(l->view->parent == g->view);
  assert(get_leaf(p, &border->node)->view->parent == g->view);
  assert(wl_list_length(&view->children) == 2);
  assert_position(p, &client->node, 29, 37);
  assert_position(p, &border->node, 35, 26);
  int local_x = l->view->x, local_y = l->view->y;
  clear_damage(out);
  wlr_scene_node_set_position(&frame->node, 83, 71);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  // Ordinary movement changes one group origin; child setters are no-ops.
  assert(l->view->x == local_x && l->view->y == local_y);
  assert_position(p, &client->node, 75, 79);
  assert_position(p, &border->node, 81, 68);
  assert(damaged(out, 50, 60) && damaged(out, 200, 150));
  clear_damage(out);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));

  // A fixed desktop ignores the camera while neighboring windows still pan.
  rediwm_projection_sync_fixed(p, .5, 10, 20, 0, 0, frame);
  assert_position(p, &client->node, 75, 79);
  assert_position(p, &overlay->node, 40, 20);
  assert(wlr_scene_buffer_from_node(l->view)->dst_width == 200);
  rediwm_projection_sync(p, .5, 10, 20, 0, 0);
  assert_position(p, &client->node, 33, 30);

  // Endpoint rounding must remain global, including half-pixels crossing
  // zero. Integer rounding of a local offset is not equivalent here.
  const double zooms[] = {.5, .85, 1, 1.25};
  for (size_t i = 0; i < sizeof(zooms) / sizeof(zooms[0]); ++i) {
    double z = zooms[i], cx = 6.5, cy = -2.5, ox = -17, oy = 31;
    double tx = ox * (1 - z) - z * cx, ty = oy * (1 - z) - z * cy;
    for (int x = -13; x <= 13; ++x) {
      wlr_scene_node_set_position(&frame->node, x, -x);
      rediwm_projection_sync(p, z, cx, cy, ox, oy);
      assert_position(p, &client->node, lround(z * (x - 8) + tx),
                       lround(z * (-x + 8) + ty));
      assert_position(p, &border->node, lround(z * (x - 2) + tx),
                       lround(z * (-x - 3) + ty));
      struct wlr_scene_buffer *v = wlr_scene_buffer_from_node(l->view);
      assert(v->dst_width == lround(z * (x - 8 + 200) + tx) -
                             lround(z * (x - 8) + tx));
    }
  }
  // Window zoom multiplies the camera scale while preserving its world origin.
  // Nested geometry keeps the same per-leaf projected scale.
  assert(rediwm_projection_set_tree_zoom(&frame->node, .85));
  wlr_scene_node_set_position(&frame->node, -17, 23);
  rediwm_projection_sync(p, .5, 3, -7, 0, 0);
  assert_position(p, &client->node, lround(.5 * -17 - 1.5 + (.85 * .5) * -8),
                   lround(.5 * 23 + 3.5 + (.85 * .5) * 8));
  assert(rediwm_projection_node_zoom(l->view) == (.85 * .5));

  // A relative tree scale composes with camera and window zoom, preserving origin.
  assert(rediwm_projection_set_tree_scale(&nested->node, .5));
  rediwm_projection_sync(p, .5, 3, -7, 0, 0);
  assert(fabs(rediwm_projection_node_zoom(l->view) - ((.85 * .5) * .5)) < .0001);
  assert_position(p, &client->node, lround(.5 * -17 - 1.5 + (.85 * .5) * -12 + (.85 * .5) * .5 * 4),
                   lround(.5 * 23 + 3.5 + (.85 * .5) * 5 + (.85 * .5) * .5 * 3));
  assert(rediwm_projection_set_tree_scale(&nested->node, 1.0));
  rediwm_projection_sync(p, .5, 3, -7, 0, 0);
  assert(fabs(rediwm_projection_node_zoom(l->view) - (.85 * .5)) < .0001);
  assert(rediwm_projection_set_tree_zoom(&frame->node, 1.0));

  // Reorder a whole window and a leaf within it, retaining source paint order.
  wlr_scene_node_raise_to_top(&frame->node);
  wlr_scene_node_raise_to_top(&nested->node);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(g->view->node.link.prev == &h->view->node.link);
  assert(l->view->link.prev == &get_leaf(p, &border->node)->view->link);
  // Input lookup and surface routing remain attached to the leaf when a
  // subsurface changes source root, rather than retaining a stale group.
  wlr_scene_node_reparent(&client->node, other);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(l->view->parent == h->view);
  assert_position(p, &client->node, 94, 63);
  double input_x = 40, input_y = 24;
  assert(accepts(wlr_scene_buffer_from_node(l->view), &input_x, &input_y));
  assert(input_x == 40 && input_y == 24);
  wlr_scene_node_set_enabled(&other->node, false);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  int x = 0, y = 0;
  assert(!wlr_scene_node_coords(l->view, &x, &y));
  wlr_scene_node_set_enabled(&other->node, true);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert_position(p, &client->node, 94, 63);

  // A former source root can become nested, leave the projected tree, and
  // return. Its unused group must hide while its leaves change group, and
  // neither its former position nor window zoom may leak into other leaves.
  wlr_scene_node_reparent(&frame->node, other);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!g->view->node.enabled);
  assert(get_leaf(p, &border->node)->view->parent == h->view);
  assert_position(p, &border->node, 71, 80);
  assert_position(p, &client->node, 94, 63);
  wlr_scene_node_reparent(&frame->node, &scene->tree);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!wlr_scene_node_coords(get_leaf(p, &border->node)->view, &x, &y));
  wlr_scene_node_reparent(&frame->node, source);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(g->view->node.enabled);
  assert(get_leaf(p, &border->node)->view->parent == g->view);
  assert_position(p, &border->node, -19, 20);

  // Destruction can precede synchronization after reparenting. The old view
  // group still owns this leaf, but the surviving source must be recreatable.
  struct wlr_scene_tree *temporary = wlr_scene_tree_create(source);
  struct wlr_scene_rect *survivor = wlr_scene_rect_create(temporary, 12, 12, color);
  assert(temporary && survivor);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  wlr_scene_node_reparent(&survivor->node, other);
  wlr_scene_node_destroy(&temporary->node);
  assert(!rediwm_projection_node(p, &survivor->node));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert_position(p, &survivor->node, 90, 60);
  wlr_scene_node_destroy(&survivor->node);

  // A direct leaf can itself be a former group root. After it becomes nested,
  // destroying the source runs both leaf and group cleanup on the same node.
  struct wlr_scene_rect *direct = wlr_scene_rect_create(source, 12, 12, color);
  assert(direct);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  wlr_scene_node_reparent(&direct->node, other);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(get_leaf(p, &direct->node)->view->parent == h->view);
  wlr_scene_node_destroy(&direct->node);
  assert(wl_list_length(&p->groups) == 2 && wl_list_length(&p->leaves) == 3);

  // Source-first teardown destroys its group without dangling leaf listeners;
  // view-first teardown removes every adapter before the source is destroyed.
  wlr_scene_node_destroy(&frame->node);
  assert(wl_list_length(&p->groups) == 1 && wl_list_length(&p->leaves) == 2);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  wlr_scene_node_destroy(&view->node);
  assert(wl_list_empty(&p->groups) && wl_list_empty(&p->leaves));
  rediwm_projection_destroy(p);
  wlr_scene_node_destroy(&source->node);
  wlr_buffer_drop(buffer);
}
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
  struct wlr_scene *scene = wlr_scene_create();
  assert(scene);
  struct wlr_scene_output *out = wlr_scene_output_create(scene, output);
  assert(out);
  struct wlr_scene_tree *source = wlr_scene_tree_create(&scene->tree);
  struct wlr_scene_tree *view = wlr_scene_tree_create(&scene->tree);
  struct rediwm_projection *p = rediwm_projection_create(source, view, scene);
  assert(p);
  struct wlr_buffer *a = buffer_create(), *b = buffer_create();
  struct wlr_scene_buffer *node = wlr_scene_buffer_create(source, a);
  assert(node);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(out, 100, 60)); // First presentation is fully damaged.
  clear_damage(out);

  struct leaf *l = get_leaf(p, &node->node);
  struct wlr_surface surface = {.current = {.buffer_width = 200, .buffer_height = 120}};
  pixman_region32_init(&surface.buffer_damage);
  struct wlr_scene_surface scene_surface = {.surface = &surface};
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

  // Rotation with empty damage is not a repaint; rotation with partial damage
  // must retain only that region. The source tree itself is disabled.
  wlr_scene_buffer_set_buffer(node, b);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));
  wlr_scene_buffer_set_buffer(node, a);
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
  wlr_scene_buffer_set_source_box(node, &(struct wlr_fbox){20, 20, 100, 60});
  wlr_scene_buffer_set_dest_size(node, 100, 60);
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
  wlr_scene_node_set_position(&node->node, 200, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 20, 20) && damaged(out, 170, 20));
  clear_damage(out);
  wlr_scene_node_set_enabled(&node->node, false);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  clear_damage(out);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  wlr_scene_node_set_enabled(&node->node, true);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 170, 20));
  wlr_scene_node_set_position(&node->node, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  clear_damage(out);

  // Unmap/remap must repaint even when the remapping commit has empty damage.
  wlr_scene_buffer_set_buffer(node, NULL);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  clear_damage(out);
  wlr_scene_buffer_set_buffer(node, a);
  commit_damage(l, 0, 0, 0, 0);
  rediwm_projection_sync(p, .5, 0, 0, 0, 0);
  assert(damaged(out, 25, 15));

  l->surface = NULL; // Synthetic surface has no lifecycle listeners to route.
  pixman_region32_fini(&surface.buffer_damage);
  rediwm_projection_destroy(p);
  test_groups(scene, out);
  wlr_scene_node_destroy(&scene->tree.node);
  wlr_buffer_drop(a);
  wlr_buffer_drop(b);
  wlr_backend_destroy(backend);
  wl_display_destroy(display);
  puts("PASS: projection damage, grouping, geometry and lifecycle");
  return 0;
}
