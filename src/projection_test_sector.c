// Analytic circular clips: geometry remains smooth between old polygon vertices,
// while picks, conservative covers and damage follow the same outline as GLES.
static struct rediwm_clip_spec sector_spec(void) {
  return (struct rediwm_clip_spec){
      .width = 110, .height = 110, .border = 1,
      .sector = {.center = {55, 55}, .radii = {20, 50}, .axis = {0, -1},
                 .half_angle = {sqrt(.5), sqrt(.5)}}};
}

static void test_sector_geometry(void) {
  const double pi = acos(-1);
  const struct rediwm_xform id = {1, 0, 0};
  struct rediwm_clip_spec spec = sector_spec();
  assert(rediwm_sector_valid(&spec.sector));
  const struct rediwm_clip clip = rediwm_clip_resolve(id, 0, 0, &spec);
  assert(near(rediwm_clip_distance(&clip, 55, 10), -5));
  assert(near(rediwm_clip_distance(&clip, 55, 55), 20));
  assert(near(rediwm_clip_distance(&clip, 55, 2), 3));
  const double edge = 40 * sqrt(.5), normal = 2 * sqrt(.5);
  assert(near(rediwm_clip_distance(&clip, 55 + edge + normal, 55 - edge + normal), 2));
  assert(near(rediwm_clip_distance(&clip, 55 + edge - normal, 55 - edge - normal), -2));
  // Past a corner, distance is to the finite side's endpoint, not its infinite line.
  assert(near(rediwm_clip_distance(&clip, 55 + 55 * sqrt(.5), 55 - 49 * sqrt(.5)), sqrt(13)));
  struct rediwm_snap cover[3];
  assert(rediwm_clip_opaque(&clip, cover) == 0);
  assert(near(clip.inset, 55));
  // Every radial sample, including between the old eight arc vertices, has the
  // exact circular distance. Rotation does not alter that distance.
  for (int rotation = 0; rotation < 32; rotation++) {
    const double angle = 2 * pi * rotation / 32;
    spec.sector.axis[0] = sin(angle);
    spec.sector.axis[1] = -cos(angle);
    const struct rediwm_clip rotated = rediwm_clip_resolve(id, 0, 0, &spec);
    for (int i = -9; i <= 9; i++) {
      const double a = angle + pi / 4 * i / 10;
      for (int radial = 0; radial < 2; radial++) {
        const double radius = radial ? 49.9 : 20.1;
        assert(near(rediwm_clip_distance(&rotated, 55 + sin(a) * radius, 55 - cos(a) * radius), -.1));
      }
    }
  }
  spec = sector_spec();
  const struct rediwm_clip moved = rediwm_clip_resolve(id, 20, -10, &spec);
  assert(rediwm_clip_outline_equal(&clip, &moved));
  const struct rediwm_clip scaled = rediwm_clip_resolve((struct rediwm_xform){1.5, -3, 2}, 10, 20, &spec);
  assert(near(scaled.sector.center[0], 94.5) && near(scaled.sector.center[1], 114.5));
  assert(near(scaled.sector.radii[0], 30) && near(scaled.sector.radii[1], 75));
  assert(near(rediwm_clip_distance(&scaled, 94.5, 47), -7.5));
  assert(!rediwm_clip_outline_equal(&clip, &scaled));
  spec.sector_texture_height = 120;
  const struct rediwm_clip mapped = rediwm_clip_resolve(id, 0, 0, &spec);
  const struct rediwm_clip mapped_scaled = rediwm_clip_resolve((struct rediwm_xform){1.5, -3, 2}, 10, 20, &spec);
  assert(near(mapped.sector_texture_height, 120));
  assert(near(mapped_scaled.sector_texture_height, 180));
  assert(near(rediwm_clip_distance(&mapped, 55, 10), rediwm_clip_distance(&clip, 55, 10)));
  assert(!rediwm_clip_outline_equal(&clip, &mapped));
  const struct rediwm_clip mapped_moved = rediwm_clip_resolve(id, 20, -10, &spec);
  assert(rediwm_clip_outline_equal(&mapped, &mapped_moved));
  spec.sector.axis[0] = 1;
  spec.sector.axis[1] = 0;
  const struct rediwm_clip turned = rediwm_clip_resolve(id, 0, 0, &spec);
  assert(!rediwm_clip_outline_equal(&clip, &turned));
}

static void test_sector_buffer_damage(struct rediwm_projection *p, struct rediwm_scene_output *out,
                                     struct rediwm_buffer *body) {
  const struct leaf *leaf = leaf_of(p, &body->node);
  uint64_t cursor = rediwm_projection_damage_cursor(p);
  pixman_region32_t damage, visible;
  pixman_region32_init_rect(&damage, 20, 80, 1, 1);
  pixman_region32_init_rect(&visible, 0, 0, 110, 110);
  rediwm_projection_note_visible(p, &body->node, &visible);
  // This tiny source patch would map near (11,73) with rectangular sampling.
  // Polar mapping must conservatively repaint every visible preview pixel and
  // attribute the full box to this leaf, so retained effects see the update too.
  rediwm_projection_damage_buffer(p, &body->node, &damage);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 55, 10) && layout_damaged(out, 55, 25));
  struct events_seen seen = events_since(p, &cursor, NULL);
  assert(seen.count == 1 && event_is(&seen.last[0], leaf->item.id, 0, 0, 110, 110));
  clear_damage(out);
  pixman_region32_clear(&damage);
  rediwm_projection_damage_buffer(p, &body->node, &damage);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));
  assert(events_since(p, &cursor, NULL).count == 0); // Empty updates remain idle.

  // Output damage is still cut to what was visible; the attribution event stays
  // whole because its consumers apply their own region/order tests.
  pixman_region32_clear(&visible);
  pixman_region32_union_rect(&visible, &visible, 50, 5, 10, 25);
  rediwm_projection_note_visible(p, &body->node, &visible);
  pixman_region32_union_rect(&damage, &damage, 20, 80, 1, 1);
  rediwm_projection_damage_buffer(p, &body->node, &damage);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(layout_damaged(out, 55, 25) && !layout_damaged(out, 10, 10));
  seen = events_since(p, &cursor, NULL);
  assert(seen.count == 1 && event_is(&seen.last[0], leaf->item.id, 0, 0, 110, 110));
  clear_damage(out);
  pixman_region32_union_rect(&visible, &visible, 0, 0, 110, 110);
  rediwm_projection_note_visible(p, &body->node, &visible);
  pixman_region32_fini(&visible);
  pixman_region32_fini(&damage);
}

static void test_sector_projection(struct rediwm_scene_outputs *scene, struct rediwm_scene_output *out) {
  struct rig rig = rig_create(scene);
  struct rediwm_projection *p = rediwm_projection_create(rig.own, rig.world, scene);
  assert(p);
  struct rediwm_tree *frame = rediwm_tree_create(rig.world);
  struct wlr_buffer *buffer = buffer_create();
  struct rediwm_buffer *body = rediwm_buffer_create(frame, buffer);
  assert(frame && body);
  rediwm_buffer_set_dest_size(body, 110, 110);
  struct rediwm_clip_spec spec = sector_spec();
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(pick(p, 55, 10, NULL, NULL) == &body->node);
  assert(!pick(p, 55, 55, NULL, NULL)); // The hub is a hole.
  assert(!pick(p, 5, 5, NULL, NULL)); // Cut-away bounding-box corner.
  clear_damage(out);
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  assert(!props_changed);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));

  const struct rediwm_sector bad[] = {
      {.radii = {-1, 50}, .axis = {0, -1}, .half_angle = {sqrt(.5), sqrt(.5)}},
      {.radii = {50, 50}, .axis = {0, -1}, .half_angle = {sqrt(.5), sqrt(.5)}},
      {.radii = {20, 50}, .axis = {0, -2}, .half_angle = {sqrt(.5), sqrt(.5)}},
      {.radii = {20, 50}, .axis = {0, -1}, .half_angle = {1, 0}},
      {.radii = {20, 50}, .axis = {0, -1}, .half_angle = {-sqrt(.5), sqrt(.5)}},
      {.radii = {20, INFINITY}, .axis = {0, -1}, .half_angle = {sqrt(.5), sqrt(.5)}},
      {.center = {NAN, 0}}, {.radii = {0, -1}}, {.axis = {0, -1}},
  };
  for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
    struct rediwm_clip_spec invalid = spec;
    invalid.sector = bad[i];
    assert(!rediwm_projection_set_tree_clip(&frame->node, &invalid));
    assert(!props_changed);
  }
  struct rediwm_clip_spec mixed = spec;
  mixed.poly_count = 3;
  memcpy(mixed.poly, (double[3][2]){{0, 0}, {110, 0}, {0, 110}}, 3 * sizeof(mixed.poly[0]));
  assert(!rediwm_projection_set_tree_clip(&frame->node, &mixed));
  assert(pick(p, 55, 10, NULL, NULL) == &body->node); // Invalid inputs preserved the old shape.

  const double bad_heights[] = {-1, INFINITY, NAN};
  for (size_t i = 0; i < sizeof(bad_heights) / sizeof(bad_heights[0]); i++) {
    struct rediwm_clip_spec invalid = spec;
    invalid.sector_texture_height = bad_heights[i];
    assert(!rediwm_projection_set_tree_clip(&frame->node, &invalid));
    assert(!props_changed);
  }
  struct rediwm_clip_spec without_sector = {.width = 110, .height = 110, .sector_texture_height = 70};
  assert(!rediwm_projection_set_tree_clip(&frame->node, &without_sector));
  assert(!props_changed);

  // Radial framing changes the content without changing the outline or source
  // buffer. Damage must include its interior, and repeating it must stay idle.
  spec.sector_texture_height = 70;
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(out, 55, 10) && damaged(out, 55, 25));
  clear_damage(out);
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  assert(!props_changed);
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(!pixman_region32_not_empty(&out->damage_ring.current));
  test_sector_buffer_damage(p, out, body);
  spec.sector_texture_height = 120;
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(out, 55, 25));
  clear_damage(out);
  spec.sector_texture_height = 0;
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(out, 55, 25));
  clear_damage(out);

  // A change of angle alters the outline without moving its box. The whole
  // sector, including its old middle, must be damaged and picks must follow.
  spec.sector.axis[0] = 1;
  spec.sector.axis[1] = 0;
  assert(rediwm_projection_set_tree_clip(&frame->node, &spec));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(damaged(out, 55, 10) && damaged(out, 100, 55));
  assert(!pick(p, 55, 10, NULL, NULL));
  assert(pick(p, 100, 55, NULL, NULL) == &body->node);
  assert(rediwm_projection_set_tree_clip(&frame->node, NULL));
  rediwm_projection_sync(p, 1, 0, 0, 0, 0);
  assert(pick(p, 55, 55, NULL, NULL) == &body->node);
  rediwm_projection_destroy(p);
  rig_destroy(&rig);
  wlr_buffer_drop(buffer);
}
