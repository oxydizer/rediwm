// Group and feedback tests: grouping, damage per group, surface feedback and
// frame callbacks.
// Included by projection_test.c, in its one unit with the projection.

static bool in_group(struct group *g, struct leaf *l) {
  struct leaf *listed;
  wl_list_for_each(listed, &g->items, paint) if (listed == l) return true;
  return false;
}
static int snap_width(struct leaf *l) { return rediwm_edges_snap(l->item.edges).width; }
static void test_groups(struct rediwm_scene_outputs *scene, struct rediwm_scene_output *out) {
  struct rig rig = rig_create(scene);
  struct rediwm_tree *source = rig.world;
  struct rediwm_projection *p = rediwm_projection_create(rig.own, source, scene);
  assert(p);
  struct rediwm_tree *frame = rediwm_tree_create(source);
  struct rediwm_tree *nested = rediwm_tree_create(frame);
  struct rediwm_tree *other = rediwm_tree_create(source);
  float color[4] = {.2, .3, .1, 1};
  struct rediwm_rect *border = rediwm_rect_create(frame, 17, 9, color);
  struct wlr_buffer *buffer = buffer_create();
  struct rediwm_buffer *client = rediwm_buffer_create(nested, buffer);
  struct rediwm_rect *overlay = rediwm_rect_create(other, 20, 20, color);
  assert(frame && nested && other && border && client && overlay);
  rediwm_node_set_position(&frame->node, 37, 29);
  rediwm_node_set_position(&nested->node, -12, 5);
  rediwm_node_set_position(&client->node, 4, 3);
  rediwm_node_set_position(&border->node, -2, -3);
  rediwm_node_set_position(&other->node, 90, 60);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct group *g = projection_get_group(p, &frame->node);
  struct group *h = projection_get_group(p, &other->node);
  struct leaf *l = leaf_of(p, &client->node);
  struct leaf *border_leaf = leaf_of(p, &border->node);
  assert(in_group(g, l) && in_group(g, border_leaf) && in_group(h, leaf_of(p, &overlay->node)));
  assert(wl_list_length(&p->paint) == 2);
  assert_position(p, &client->node, 29, 37);
  assert_position(p, &border->node, 35, 26);
  clear_damage(out);
  rediwm_node_set_position(&frame->node, 83, 71);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  // Ordinary movement moves every leaf of the group.
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
  assert(snap_width(l) == 200);
  rediwm_projection_sync(p, .5, 10, 20, 0, 0);
  assert_position(p, &client->node, 33, 30);

  // Endpoint rounding must remain global, including half-pixels crossing
  // zero. Integer rounding of a local offset is not equivalent here.
  const double zooms[] = {.5, .85, 1, 1.25};
  for (size_t i = 0; i < sizeof(zooms) / sizeof(zooms[0]); ++i) {
    double z = zooms[i], cx = 6.5, cy = -2.5, ox = -17, oy = 31;
    double tx = ox * (1 - z) - z * cx, ty = oy * (1 - z) - z * cy;
    for (int x = -13; x <= 13; ++x) {
      rediwm_node_set_position(&frame->node, x, -x);
      rediwm_projection_sync(p, z, cx, cy, ox, oy);
      assert_position(p, &client->node, lround(z * (x - 8) + tx),
                       lround(z * (-x + 8) + ty));
      assert_position(p, &border->node, lround(z * (x - 2) + tx),
                       lround(z * (-x - 3) + ty));
      assert(snap_width(l) == lround(z * (x - 8 + 200) + tx) -
                              lround(z * (x - 8) + tx));
    }
  }
  // Window zoom multiplies the camera scale while preserving its world origin.
  // Nested geometry keeps the same per-leaf projected scale.
  assert(rediwm_projection_set_tree_zoom(&frame->node, .85));
  rediwm_node_set_position(&frame->node, -17, 23);
  rediwm_projection_sync(p, .5, 3, -7, 0, 0);
  assert_position(p, &client->node, lround(.5 * -17 - 1.5 + (.85 * .5) * -8),
                   lround(.5 * 23 + 3.5 + (.85 * .5) * 8));
  assert(l->item.scale == (.85 * .5));

  // A relative tree scale composes with camera and window zoom, preserving origin.
  assert(rediwm_projection_set_tree_scale(&nested->node, .5));
  rediwm_projection_sync(p, .5, 3, -7, 0, 0);
  assert(fabs(l->item.scale - ((.85 * .5) * .5)) < .0001);
  assert_position(p, &client->node, lround(.5 * -17 - 1.5 + (.85 * .5) * -12 + (.85 * .5) * .5 * 4),
                   lround(.5 * 23 + 3.5 + (.85 * .5) * 5 + (.85 * .5) * .5 * 3));
  assert(rediwm_projection_set_tree_scale(&nested->node, 1.0));
  rediwm_projection_sync(p, .5, 3, -7, 0, 0);
  assert(fabs(l->item.scale - (.85 * .5)) < .0001);
  assert(rediwm_projection_set_tree_zoom(&frame->node, 1.0));

  // Reorder a whole window and a leaf within it, retaining source paint order.
  rediwm_node_raise_to_top(&frame->node);
  rediwm_node_raise_to_top(&nested->node);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct leaf *order[8];
  assert(p->paint.next == &h->paint && h->paint.next == &g->paint && g->paint.next == &p->paint);
  assert(items_of(g, order, 8) == 2 && order[0] == border_leaf && order[1] == l);
  // The source node and its input stay attached to the leaf when a subsurface
  // changes source root, rather than retaining a stale group.
  rediwm_node_reparent(&client->node, other);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(in_group(h, l) && !in_group(g, l));
  assert_position(p, &client->node, 94, 63);
  double input_x, input_y;
  assert(pick(p, 94 + 40, 63 + 24, &input_x, &input_y) == &client->node);
  assert(input_x == 40 && input_y == 24);
  rediwm_node_set_enabled(&other->node, false);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!l->item.enabled && !pick(p, 94 + 40, 63 + 24, &input_x, &input_y));
  rediwm_node_set_enabled(&other->node, true);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert_position(p, &client->node, 94, 63);

  // A former source root can become nested, leave the projected tree, and
  // return. Its unused group is not reached while its leaves change group, and
  // neither its former position nor window zoom may leak into other leaves.
  rediwm_node_reparent(&frame->node, other);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!g->seen);
  assert(in_group(h, border_leaf));
  assert_position(p, &border->node, 71, 80);
  assert_position(p, &client->node, 94, 63);
  rediwm_node_reparent(&frame->node, &rig.parking->tree);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!border_leaf->seen);
  rediwm_node_reparent(&frame->node, source);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(g->seen);
  assert(in_group(g, border_leaf));
  assert_position(p, &border->node, -19, 20);

  // A leaf moved out of a window's tree before the tree is destroyed keeps its
  // leaf: the surviving source node needs nothing recreated.
  struct rediwm_tree *temporary = rediwm_tree_create(source);
  struct rediwm_rect *survivor = rediwm_rect_create(temporary, 12, 12, color);
  assert(temporary && survivor);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  rediwm_node_reparent(&survivor->node, other);
  rediwm_node_destroy(&temporary->node);
  assert(leaf_of(p, &survivor->node));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert_position(p, &survivor->node, 90, 60);
  rediwm_node_destroy(&survivor->node);

  // A direct leaf can itself be a former group root. After it becomes nested,
  // destroying the source runs both leaf and group cleanup on the same node.
  struct rediwm_rect *direct = rediwm_rect_create(source, 12, 12, color);
  assert(direct);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  rediwm_node_reparent(&direct->node, other);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(in_group(h, leaf_of(p, &direct->node)));
  rediwm_node_destroy(&direct->node);
  assert(wl_list_length(&p->groups) == 2 && wl_list_length(&p->leaves) == 3);

  // Source-first teardown destroys its group without dangling leaf listeners.
  rediwm_node_destroy(&frame->node);
  assert(wl_list_length(&p->groups) == 1 && wl_list_length(&p->leaves) == 2);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  rediwm_node_destroy(&other->node);
  assert(wl_list_empty(&p->groups) && wl_list_empty(&p->leaves));
  rediwm_projection_destroy(p);
  rig_destroy(&rig);
  wlr_buffer_drop(buffer);
}
// Stage 6b: the screen's damage comes from the graph. A restack damages what
// changed order, a change of what a leaf itself shows is cut to what was visible
// of it at the last build, and a window going away is damaged at once.
static void test_graph_damage(struct rediwm_scene_outputs *scene, struct rediwm_scene_output *out) {
  struct rig rig = rig_create(scene);
  struct rediwm_tree *source = rig.world;
  struct rediwm_projection *p = rediwm_projection_create(rig.own, source, scene);
  assert(p);
  struct wlr_buffer *buffer = buffer_create(); // 200x120
  struct rediwm_tree *frame_a = rediwm_tree_create(source);
  struct rediwm_tree *frame_b = rediwm_tree_create(source);
  struct rediwm_buffer *a = rediwm_buffer_create(frame_a, buffer);
  struct rediwm_buffer *b = rediwm_buffer_create(frame_b, buffer);
  rediwm_node_set_position(&frame_a->node, 20, 20);
  rediwm_node_set_position(&frame_b->node, 60, 40);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  clear_damage(out);

  // Raising the window below changes the pixels where the two overlap, and says
  // nothing about the rest of the screen.
  rediwm_node_raise_to_top(&frame_a->node);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 100, 60) && layout_damaged(out, 210, 130));
  assert(!layout_damaged(out, 350, 300) && !layout_damaged(out, 5, 5));
  clear_damage(out);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0); // Same order: nothing.
  assert(!pixman_region32_not_empty(&out->damage_ring.current));

  // What changes only what a leaf shows is cut to what of it was visible at the
  // last build: the right part of `a` was hidden, so its change is not damaged.
  struct leaf *la = leaf_of(p, &a->node), *lb = leaf_of(p, &b->node);
  pixman_region32_t visible;
  pixman_region32_init_rect(&visible, 20, 20, 50, 120);
  rediwm_projection_note_visible(p, &a->node, &visible);
  rediwm_projection_damage_buffer(p, &a->node, NULL);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 30, 60) && !layout_damaged(out, 150, 60));
  clear_damage(out);
  // Nothing visible, nothing to damage; a leaf the pass never saw is damaged whole.
  pixman_region32_clear(&visible);
  rediwm_projection_note_visible(p, &a->node, &visible);
  rediwm_projection_damage_buffer(p, &a->node, NULL);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));
  assert(!lb->has_visible);
  rediwm_projection_damage_buffer(p, &b->node, NULL);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 70, 50) && layout_damaged(out, 250, 150));
  clear_damage(out);
  // A leaf that is moved damages where it was only where it was visible, and
  // where it is whatever the last build saw.
  pixman_region32_init_rect(&visible, 60, 40, 40, 120);
  rediwm_projection_note_visible(p, &b->node, &visible);
  rediwm_node_set_position(&frame_b->node, 200, 150);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 70, 60) && !layout_damaged(out, 150, 60)); // old box, cut
  assert(layout_damaged(out, 250, 200)); // new box, whole
  clear_damage(out);
  (void)la;

  // A window going away damages what it showed without waiting for a sync: a
  // capture can build a frame before the next one.
  rediwm_projection_note_visible(p, &a->node, &(pixman_region32_t){.extents = {20, 20, 220, 140}, .data = NULL});
  rediwm_node_destroy(&frame_a->node);
  assert(layout_damaged(out, 30, 30) && layout_damaged(out, 210, 130));
  pixman_region32_fini(&visible);
  rediwm_projection_destroy(p);
  rig_destroy(&rig);
  wlr_buffer_drop(buffer);
}
// Stage 6a: what the output pass reports of a surface becomes the signals wlroots
// would have sent. Two outputs side by side, a node over the seam.
static int outputs_updates, frame_dones, update_size;
static struct rediwm_scene_output *update_active[4], *update_primary;
static void on_outputs_update(struct wl_listener *listener, void *data) {
  (void)listener;
  const struct rediwm_outputs_update_event *event = data;
  outputs_updates++;
  update_primary = event->primary;
  update_size = (int)event->size;
  for (size_t i = 0; i < event->size && i < 4; i++) update_active[i] = event->active[i];
}
static void on_frame_done(struct wl_listener *listener, void *data) {
  (void)listener;
  (void)data;
  frame_dones++;
}
static void report(struct rediwm_projection *p, struct rediwm_node *node, int x, int y, int w, int h) {
  pixman_region32_t visible;
  pixman_region32_init(&visible);
  if (w > 0) pixman_region32_union_rect(&visible, &visible, x, y, w, h);
  rediwm_projection_feedback_begin(p);
  struct rediwm_scene_output *out;
  wl_list_for_each(out, &p->outputs->outputs, link) {
    int width, height;
    wlr_output_effective_resolution(out->output, &width, &height);
    pixman_region32_t part;
    pixman_region32_init(&part);
    pixman_region32_intersect_rect(&part, &visible, out->x, out->y, width, height);
    rediwm_projection_note_output(p, node, out, &part);
    pixman_region32_fini(&part);
  }
  rediwm_projection_feedback_end(p);
  pixman_region32_fini(&visible);
}
static void test_feedback(struct rediwm_scene_outputs *scene, struct wlr_backend *backend, struct rediwm_scene_output *left,
                          struct wlr_output *left_output) {
  struct wlr_output *right_output = wlr_headless_add_output(backend, 320, 240);
  assert(right_output);
  struct wlr_output_state state;
  wlr_output_state_init(&state);
  wlr_output_state_set_enabled(&state, true);
  assert(wlr_output_commit_state(right_output, &state));
  wlr_output_state_finish(&state);
  struct rediwm_scene_output *right = rediwm_scene_output_create(scene, right_output, NULL);
  assert(right);
  int seam = 0, unused = 0;
  wlr_output_effective_resolution(left_output, &seam, &unused);
  right->x = seam;

  struct rig rig = rig_create(scene);
  struct rediwm_tree *source = rig.world;
  struct rediwm_projection *p = rediwm_projection_create(rig.own, source, scene);
  assert(p);
  struct wlr_buffer *buffer = buffer_create();
  struct rediwm_buffer *node = rediwm_buffer_create(source, buffer);
  rediwm_node_set_position(&node->node, seam - 26, 50);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  struct leaf *l = leaf_of(p, &node->node);
  l->feedback = calloc(1, sizeof(*l->feedback));
  assert(l->feedback);
  l->feedback->leaf = l;
  wl_list_insert(&p->feedback, &l->feedback->link);
  struct wl_listener updated = {.notify = on_outputs_update}, done = {.notify = on_frame_done};
  wl_signal_add(&node->events.outputs_update, &updated);
  wl_signal_add(&node->events.frame_done, &done);
  struct timespec now = {0};

  // Over the seam: both outputs show more than a tenth, the one with most is primary.
  report(p, &node->node, seam - 26, 50, 200, 100); // 26 columns left, 174 right
  assert(outputs_updates == 1 && update_size == 2 && update_primary == right && l->feedback->primary == right);
  assert(l->feedback->active == (1ull << left->index | 1ull << right->index));
  report(p, &node->node, seam - 26, 50, 200, 100);
  assert(outputs_updates == 1); // Unchanged: no signal.
  // A sliver on the other side is ignored (10 % rule): 2 of 28 columns.
  report(p, &node->node, seam - 26, 50, 28, 100);
  assert(outputs_updates == 2 && update_size == 1 && update_active[0] == left && update_primary == left && l->feedback->primary == left);
  // Frames are sent for what is shown, and for no output it is not.
  rediwm_projection_send_frame_done(p, left, &now);
  assert(frame_dones == 1);
  // A hidden leaf hears none, whatever it was told last.
  rediwm_node_set_enabled(&node->node, false);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  rediwm_projection_send_frame_done(p, left, &now);
  assert(frame_dones == 1);
  rediwm_node_set_enabled(&node->node, true);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  report(p, &node->node, 0, 0, 0, 0); // hidden
  assert(outputs_updates == 3 && update_size == 0 && !l->feedback->active && !l->feedback->primary);
  rediwm_projection_send_frame_done(p, left, &now);
  assert(frame_dones == 1); // nothing shown, nothing sent
  // An active output whose scale changed hears again, whatever else is the same.
  report(p, &node->node, seam - 26, 50, 26, 100);
  assert(outputs_updates == 4 && update_size == 1);
  report(p, &node->node, seam - 26, 50, 26, 100);
  assert(outputs_updates == 4);
  wlr_output_state_init(&state);
  wlr_output_state_set_scale(&state, 1.25f);
  assert(wlr_output_commit_state(left_output, &state));
  wlr_output_state_finish(&state);
  report(p, &node->node, seam - 26, 50, 26, 100);
  assert(outputs_updates == 5);
  report(p, &node->node, seam - 26, 50, 26, 100);
  assert(outputs_updates == 5);
  // Switching the signal on a stationary output refreshes colour feedback once.
  left->color_serial++;
  report(p, &node->node, seam - 26, 50, 26, 100);
  assert(outputs_updates == 6 && update_primary == left);
  report(p, &node->node, seam - 26, 50, 26, 100);
  assert(outputs_updates == 6);
  wlr_output_state_init(&state);
  wlr_output_state_set_scale(&state, 1.f);
  assert(wlr_output_commit_state(left_output, &state));
  wlr_output_state_finish(&state);

  wl_list_remove(&updated.link);
  wl_list_remove(&done.link);
  rediwm_projection_destroy(p);
  rig_destroy(&rig);
  wlr_buffer_drop(buffer);
  rediwm_scene_output_destroy(right);
  wlr_output_destroy(right_output);
}
