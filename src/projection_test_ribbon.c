static void test_ribbon_output(struct rediwm_scene_outputs *scene, struct rediwm_scene_output *out) {
    struct rig rig = rig_create(scene);
    struct rediwm_projection *p = rediwm_projection_create(rig.own, rig.world, scene);
    assert(p);
    struct rediwm_tree *frame = rediwm_tree_create(rig.world);
    struct rediwm_buffer *node = rediwm_ribbon_create(frame);
    assert(node);
    struct rediwm_ribbon mesh = {.count = 4, .color = {1, 0, 0, 1}};
    rediwm_ribbon_update(node, &mesh, 100, 100, 80, 40);
    rediwm_projection_sync(p, 1, 0, 0, 0, 0);
    struct leaf *l = leaf_of(p, &node->node);
    assert(l->item.kind == REDIWM_ITEM_RIBBON);
    assert(layout_damaged(out, 110, 110));
    struct rediwm_hit hit;
    assert(!rediwm_projection_node_at(p, 110, 110, &hit));
    clear_damage(out);
    rediwm_projection_sync(p, 1, 0, 0, 0, 0);
    assert(!pixman_region32_not_empty(&out->damage_ring.current));
    // A fading ribbon has no backing buffer, but still changes its own pixels.
    uint64_t cursor = rediwm_projection_damage_cursor(p);
    mesh.color[3] = .5f;
    rediwm_ribbon_update(node, &mesh, 100, 100, 80, 40);
    rediwm_projection_sync(p, 1, 0, 0, 0, 0);
    assert(layout_damaged(out, 110, 110));
    struct events_seen events = events_since(p, &cursor, NULL);
    assert(events.count == 1 && events.last[0].leaf == l->item.id);
    clear_damage(out);
    rediwm_ribbon_update(node, &mesh, 200, 100, 80, 40);
    rediwm_projection_sync(p, 1.5, 0, 0, 0, 0);
    assert(layout_damaged(out, 110, 110) && layout_damaged(out, 310, 160));
    clear_damage(out);
    rediwm_node_destroy(&node->node);
    assert(layout_damaged(out, 310, 160));
    rediwm_projection_destroy(p);
    rig_destroy(&rig);
    puts("PASS: ribbon content, move, fractional damage, input transparency and destruction");
}
