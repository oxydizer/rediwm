// The output pass's real collection and the projection's picks, damage and
// surface feedback at a shared display edge. Included by projection_test.c.
#include "scene_output_internal.h"

static void expect_collected(struct rediwm_projection *p, struct rediwm_scene_output *out,
                             struct rediwm_node *shown) {
  struct rediwm_output_renderer renderer = {.projection = p};
  wl_array_init(&renderer.entries);
  struct output_view view = {.logical = {.x = out->x, .y = out->y}, .scale = out->output->scale};
  wlr_output_effective_resolution(out->output, &view.logical.width, &view.logical.height);
  pixman_region32_t covered;
  pixman_region32_init(&covered);
  assert(scene_output_collect_frame(&renderer, out, &view, &covered));
  assert(renderer.entries.size == sizeof(struct entry));
  const struct entry *entry = renderer.entries.data;
  assert(entry->transport == shown);
  pixman_region32_fini(&covered);
  scene_output_clear_entries(&renderer);
  wl_array_release(&renderer.entries);
}

static void test_home_output(struct rediwm_scene_outputs *scene, struct wlr_backend *backend,
                             struct rediwm_scene_output *east) {
  // The seam at zero covers fractional pointer coordinates on a negative-origin output.
  assert(wlr_output_layout_add(scene->layout, east->output, 0, 0));
  struct wlr_output *peer = wlr_headless_add_output(backend, 320, 240);
  assert(peer);
  struct wlr_output_state state;
  wlr_output_state_init(&state);
  wlr_output_state_set_enabled(&state, true);
  assert(wlr_output_commit_state(peer, &state));
  wlr_output_state_finish(&state);
  struct wlr_output_layout_output *lo = wlr_output_layout_add(scene->layout, peer, -320, 0);
  assert(lo);
  struct rediwm_scene_output *west = rediwm_scene_output_create(scene, peer, lo);
  assert(west);

  struct rig rig = rig_create(scene);
  struct rediwm_projection *p = rediwm_projection_create(rig.own, rig.world, scene);
  struct wlr_buffer *pixels = buffer_create();
  struct rediwm_buffer *under = rediwm_buffer_create(rig.world, pixels);
  struct wlr_surface under_surface = {0}, popup_surface = {.current = {.buffer_width = 200, .buffer_height = 120}};
  struct rediwm_surface under_binding = {.surface = &under_surface};
  struct rediwm_surface popup_binding = {.surface = &popup_surface};
  wl_signal_init(&under_surface.events.commit);
  wl_signal_init(&popup_surface.events.commit);
  pixman_region32_init(&popup_surface.buffer_damage);
  under->surface = &under_binding;
  rediwm_node_set_position(&under->node, -50, 40);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  clear_damage(west);
  clear_damage(east);

  struct rediwm_tree *frame = rediwm_tree_create(rig.world);
  struct rediwm_tree *popup = rediwm_tree_create(frame);
  assert(rediwm_projection_set_tree_output(&frame->node, west));
  assert(rediwm_projection_set_tree_unclipped(&popup->node, true));
  struct rediwm_buffer *node = rediwm_buffer_create(popup, pixels);
  node->surface = &popup_binding;
  node->buffer_is_opaque = true;
  rediwm_node_set_position(&frame->node, -50, 40);
  struct wl_listener updated = {.notify = on_outputs_update};
  wl_signal_add(&node->events.outputs_update, &updated);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct leaf *l = leaf_of(p, &node->node);
  assert(l && l->feedback);
  assert(damaged(west, 300, 50));
  assert(!pixman_region32_not_empty(&east->pending_commit_damage));

  struct rediwm_hit hit;
  assert(pick(p, -.25, 50, NULL, NULL) == &node->node);
  assert(pick(p, 0, 50, NULL, NULL) == &under->node);
  assert(!rediwm_projection_node_at_in(p, &frame->node, .25, 50, &hit));
  expect_collected(p, west, &node->node);
  expect_collected(p, east, &under->node);
  assert(update_size == 1 && update_active[0] == west && update_primary == west);
  assert(leaf_of(p, &under->node)->feedback->primary == east);

  clear_damage(west);
  clear_damage(east);
  uint64_t cursor = rediwm_projection_damage_cursor(p);
  commit_damage(l, 0, 0, 200, 120);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(west, 300, 50) && !pixman_region32_not_empty(&east->pending_commit_damage));
  struct events_seen events = events_since(p, &cursor, NULL);
  assert(events.count == 1 && events.last[0].home_output == west->serial);
  // Even when the whole popup fits on the adjacent output it receives no
  // samples, feedback or hits there.
  rediwm_node_set_position(&frame->node, 30, 40);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  expect_collected(p, west, &under->node);
  expect_collected(p, east, &under->node);
  assert(!pixman_region32_not_empty(&east->pending_commit_damage));
  assert(update_size == 0 && !update_primary && pick(p, 45, 50, NULL, NULL) == &under->node);
  rediwm_node_set_position(&frame->node, -50, 40);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  expect_collected(p, west, &node->node);
  clear_damage(west);
  // Moving only the home, with identical geometry, exposes the old and draws the new half.
  assert(rediwm_projection_set_tree_output(&frame->node, east));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(west, 300, 50) && damaged(east, 25, 50));
  expect_collected(p, west, &under->node);
  expect_collected(p, east, &node->node);
  assert(update_size == 1 && update_primary == east && leaf_of(p, &under->node)->feedback->primary == west);
  assert(pick(p, -.25, 50, NULL, NULL) == &under->node);
  assert(rediwm_projection_node_at_in(p, &frame->node, 0, 50, &hit) && hit.own == &node->node);

  // Overlapping outputs can show different windows at the very same layout
  // coordinates. A home-output leaf occludes and damages only its own display.
  assert(wlr_output_layout_add(scene->layout, peer, 0, 0) && west->x == 0);
  expect_collected(p, west, &under->node);
  expect_collected(p, east, &node->node);
  assert(update_size == 1 && update_primary == east && leaf_of(p, &under->node)->feedback->primary == west);
  clear_damage(west);
  clear_damage(east);
  commit_damage(l, 70, 0, 25, 25);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(east, 25, 50) && !pixman_region32_not_empty(&west->pending_commit_damage));
  struct wlr_output *first = wlr_output_layout_output_at(scene->layout, 25, 50);
  assert(first == east->output || first == peer);
  assert(rediwm_projection_set_tree_output(&frame->node, first == peer ? east : west));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(pick(p, 25, 50, NULL, NULL) == &under->node);
  wlr_output_state_init(&state);
  wlr_output_state_set_enabled(&state, false);
  assert(wlr_output_commit_state(first, &state));
  assert(pick(p, 25, 50, NULL, NULL) == &node->node);
  wlr_output_state_set_enabled(&state, true);
  assert(wlr_output_commit_state(first, &state));
  wlr_output_state_finish(&state);
  assert(wlr_output_layout_add(scene->layout, peer, -320, 0) && west->x == -320);

  // Lifting the restriction restores normal cross-output content, input and feedback.
  assert(rediwm_projection_set_tree_output(&frame->node, NULL));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  expect_collected(p, west, &node->node);
  expect_collected(p, east, &node->node);
  assert(update_size == 2 && update_primary == east);
  assert(pick(p, -.25, 50, NULL, NULL) == &node->node);
  assert(pick(p, 0, 50, NULL, NULL) == &node->node);

  // Reusing an output index cannot transfer a window that still names its
  // disconnected home. Both rendering and input wait for reassignment.
  assert(rediwm_projection_set_tree_output(&frame->node, west));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  expect_collected(p, west, &node->node);
  const int index = west->index;
  const uint64_t serial = west->serial;
  rediwm_scene_output_destroy(west);
  west = rediwm_scene_output_create(scene, peer, lo);
  assert(west && west->index == index && west->serial != serial);
  expect_collected(p, west, &under->node);
  assert(update_size == 0 && !update_primary);
  assert(pick(p, -.25, 50, NULL, NULL) == &under->node);

  wl_list_remove(&updated.link);
  rediwm_projection_destroy(p);
  rig_destroy(&rig);
  pixman_region32_fini(&popup_surface.buffer_damage);
  wlr_buffer_drop(pixels);
  rediwm_scene_output_destroy(west);
  wlr_output_destroy(peer);
}
