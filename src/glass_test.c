// GPU integration checks; run with `zig build test-glass` on a GLES2 host.
#include <stdbool.h>
#include <stdlib.h>
static bool fail_next_glass_allocation;
static void *glass_test_calloc(size_t count, size_t size)
{
	if (fail_next_glass_allocation) {
		fail_next_glass_allocation = false;
		return NULL;
	}
	return calloc(count, size);
}
#define calloc glass_test_calloc
#include "glass.c"
#undef calloc
#include <stdio.h>
#include <wlr/backend/headless.h>
#include <wlr/interfaces/wlr_buffer.h>

struct test_buffer {
	struct wlr_buffer base;
	uint32_t *pixels;
};
static void buffer_destroy(struct wlr_buffer *base)
{
	struct test_buffer *buffer = wl_container_of(base, buffer, base);
	free(buffer->pixels);
	free(buffer);
}
static bool buffer_access(struct wlr_buffer *base, uint32_t flags, void **data, uint32_t *format,
			  size_t *stride)
{
	(void)flags;
	struct test_buffer *buffer = wl_container_of(base, buffer, base);
	*data = buffer->pixels;
	*format = DRM_FORMAT_ARGB8888;
	*stride = base->width * 4;
	return true;
}
static void buffer_end(struct wlr_buffer *base) { (void)base; }
static const struct wlr_buffer_impl buffer_impl = {
    .destroy = buffer_destroy,
    .begin_data_ptr_access = buffer_access,
    .end_data_ptr_access = buffer_end,
};
static struct test_buffer *buffer_create(int width, int height, uint32_t top, uint32_t bottom)
{
	struct test_buffer *buffer = calloc(1, sizeof(*buffer));
	assert(buffer);
	buffer->pixels = calloc(width * height, 4);
	assert(buffer->pixels);
	wlr_buffer_init(&buffer->base, &buffer_impl, width, height);
	for (int y = 0; y < height; y++)
		for (int x = 0; x < width; x++)
			buffer->pixels[y * width + x] = y < height / 2 ? top : bottom;
	return buffer;
}

static uint32_t pixel(struct glass_effect *effect, int x, int y)
{
	struct wlr_texture *texture =
	    wlr_texture_from_buffer(effect->engine->renderer, effect->node->buffer);
	assert(texture);
	uint32_t result = 0;
	assert(wlr_texture_read_pixels(texture, &(struct wlr_texture_read_pixels_options){
						    .data = &result,
						    .format = DRM_FORMAT_ARGB8888,
						    .stride = 4,
						    .src_box = {x, y, 1, 1},
						}));
	wlr_texture_destroy(texture);
	return result;
}
static void near_channel(uint32_t pixel_value, int shift, int expected, int tolerance)
{
	int actual = (pixel_value >> shift) & 255;
	if (abs(actual - expected) > tolerance) {
		fprintf(stderr, "channel %d: got %d expected %d (+/-%d), pixel %08x\n", shift,
			actual, expected, tolerance, pixel_value);
		abort();
	}
}

static void damage_commit(struct wlr_surface *surface, int x, int y, int width, int height)
{
	pixman_region32_clear(&surface->buffer_damage);
	assert(pixman_region32_union_rect(&surface->buffer_damage, &surface->buffer_damage,
					x, y, width, height));
	surface->current.seq++;
	wl_signal_emit_mutable(&surface->events.commit, surface);
}
static uint64_t damage_hash(struct glass_effect *effect, struct wlr_scene_buffer *node,
		struct wlr_surface *surface, const struct wlr_box *bounds,
		const struct wlr_box *sample)
{
	struct capture capture = {
		.effect = effect, .box = *sample, .width = sample->width / 4,
		.height = sample->height / 4, .hash = UINT64_C(14695981039346656037),
	};
	struct wlr_scene_node *leaf = &node->node;
	HASH(&capture.hash, leaf);
	HASH(&capture.hash, *bounds);
	capture_buffer_hash(&capture, node, surface, bounds, sample);
	return capture.hash;
}
static void damage_checks(void)
{
	struct wlr_scene *scene = wlr_scene_create();
	assert(scene);
	struct glass_engine engine = {.scene = scene};
	wl_list_init(&engine.effects);
	struct glass_effect first = {.engine = &engine}, second = {.engine = &engine};
	wl_list_init(&first.dependencies);
	wl_list_init(&second.dependencies);
	struct wlr_scene_buffer *node = wlr_scene_buffer_create(&scene->tree, NULL);
	assert(node);
	wlr_scene_buffer_set_source_box(node, &(struct wlr_fbox){20, 10, 600, 400});
	struct wlr_surface surface = {.current = {.buffer_width = 1200, .buffer_height = 800}};
	wl_signal_init(&surface.events.commit);
	wl_signal_init(&surface.events.destroy);
	pixman_region32_init(&surface.buffer_damage);
	struct glass_dependency *a = dependency_get(&first, node, &surface);
	struct glass_dependency *b = dependency_get(&second, node, &surface);
	assert(a && b && a != b && dependency_get(&first, node, &surface) == a);
	struct wlr_box bounds = {100, 50, 300, 200}, sample = {200, 100, 50, 40};
	uint64_t revision = dependency_revision(a, &bounds, &sample, 4, 4);

	// A surface covering the whole output must not repaint a distant blur.
	damage_commit(&surface, 40, 20, 10, 10);
	assert(engine.resync);
	assert(dependency_revision(a, &bounds, &sample, 4, 4) == revision);
	// Empty commits/buffer rotation are not new pixels and cannot discard
	// relevant damage from earlier commits while a blur is held.
	engine.resync = false;
	damage_commit(&surface, 230, 120, 4, 4);
	damage_commit(&surface, 40, 20, 4, 4);
	damage_commit(&surface, 0, 0, 0, 0);
	assert(dependency_revision(a, &bounds, &sample, 4, 4) == ++revision);
	assert(dependency_revision(a, &bounds, &sample, 4, 4) == revision);
	// Another effect (or another output's effect) owns its accumulated damage.
	assert(pixman_region32_contains_point(&b->damage, 231, 121, NULL));
	assert(dependency_revision(b, &bounds, &sample, 4, 4) == 2);
	engine.resync = false;
	damage_commit(&surface, 0, 0, 0, 0);
	assert(!engine.resync);
	assert(dependency_revision(a, &bounds, &sample, 4, 4) == revision);

	// Fractional source/destination ratios include bilinear and quarter-size
	// capture rounding footprints. Buffer scale and viewporter use this path.
	damage_commit(&surface, 211, 120, 1, 1);
	assert(dependency_revision(a, &bounds, &sample, 4, 4) == ++revision);
	wlr_scene_buffer_set_source_box(node, &(struct wlr_fbox){20.5, 10.5, 601, 401});
	damage_commit(&surface, 230, 120, 1, 1);
	assert(dependency_revision(a, &bounds, &sample, 4, 4) == ++revision);
	wlr_scene_buffer_set_source_box(node, NULL);
	damage_commit(&surface, 500, 250, 1, 1);
	assert(dependency_revision(a, &bounds, &sample, 4, 4) == ++revision);

	// Changed-and-restored mappings cannot cancel a required repaint.
	const uint32_t mappings[] = {WLR_SURFACE_STATE_TRANSFORM, WLR_SURFACE_STATE_SCALE,
		WLR_SURFACE_STATE_VIEWPORT, WLR_SURFACE_STATE_OFFSET};
	for (size_t i = 0; i < sizeof(mappings) / sizeof(mappings[0]); i++) {
		surface.current.committed = mappings[i];
		surface.current.dx = mappings[i] == WLR_SURFACE_STATE_OFFSET;
		damage_commit(&surface, 0, 0, 0, 0);
		surface.current.committed = 0;
		surface.current.dx = 0;
		damage_commit(&surface, 0, 0, 0, 0);
		assert(dependency_revision(a, &bounds, &sample, 4, 4) == ++revision);
	}
	// wl_surface before v5 sets OFFSET on every attach(buffer, 0, 0). A zero
	// delta maps nothing differently and must not re-blur on every frame.
	surface.current.committed = WLR_SURFACE_STATE_OFFSET;
	damage_commit(&surface, 0, 0, 0, 0);
	surface.current.committed = 0;
	assert(dependency_revision(a, &bounds, &sample, 4, 4) == revision);
	surface.current.buffer_width = 1300;
	damage_commit(&surface, 0, 0, 0, 0);
	surface.current.buffer_width = 1200;
	damage_commit(&surface, 0, 0, 0, 0);
	assert(dependency_revision(a, &bounds, &sample, 4, 4) == ++revision);
	wlr_scene_buffer_set_transform(node, WL_OUTPUT_TRANSFORM_90);
	damage_commit(&surface, 5, 5, 1, 1);
	assert(dependency_revision(a, &bounds, &sample, 4, 4) == ++revision);

	// Exercise the actual capture hashing path, not only its damage helper.
	// Buffer pointer/sequence changes with empty damage leave the hash stable;
	// sampled pixels and all texture-mapping metadata still invalidate it.
	wlr_scene_buffer_set_transform(node, WL_OUTPUT_TRANSFORM_NORMAL);
	wlr_scene_buffer_set_source_box(node, &(struct wlr_fbox){20, 10, 600, 400});
	struct test_buffer *one = buffer_create(2, 2, 0xff000000, 0xff000000);
	struct test_buffer *two = buffer_create(2, 2, 0xff000000, 0xff000000);
	wlr_scene_buffer_set_buffer(node, &one->base);
	uint64_t hash = damage_hash(&first, node, &surface, &bounds, &sample);
	wlr_scene_buffer_set_buffer(node, &two->base);
	damage_commit(&surface, 0, 0, 0, 0);
	assert(damage_hash(&first, node, &surface, &bounds, &sample) == hash);
	damage_commit(&surface, 40, 20, 4, 4);
	assert(damage_hash(&first, node, &surface, &bounds, &sample) == hash);
	damage_commit(&surface, 230, 120, 4, 4);
	uint64_t changed = damage_hash(&first, node, &surface, &bounds, &sample);
	assert(changed != hash);
	hash = changed;
	struct wlr_box moved = bounds;
	moved.x++;
	assert(damage_hash(&first, node, &surface, &moved, &sample) != hash);
	wlr_scene_buffer_set_source_box(node, &(struct wlr_fbox){30, 10, 600, 400});
	assert(damage_hash(&first, node, &surface, &bounds, &sample) != hash);
	wlr_scene_buffer_set_source_box(node, &(struct wlr_fbox){20, 10, 600, 400});
	wlr_scene_buffer_set_opacity(node, .5f);
	assert(damage_hash(&first, node, &surface, &bounds, &sample) != hash);
	wlr_scene_buffer_set_opacity(node, 1);
	enum wlr_scale_filter_mode filter = node->filter_mode;
	wlr_scene_buffer_set_filter_mode(node, filter == WLR_SCALE_FILTER_BILINEAR ?
		WLR_SCALE_FILTER_NEAREST : WLR_SCALE_FILTER_BILINEAR);
	assert(damage_hash(&first, node, &surface, &bounds, &sample) != hash);
	wlr_scene_buffer_set_filter_mode(node, filter);
	// A client buffer whose texture was unavailable must not retain fallback
	// pixels once the drawable texture appears. No GL access is needed here.
	struct wlr_texture texture = {0};
	node->private.texture = &texture;
	assert(damage_hash(&first, node, &surface, &bounds, &sample) != hash);
	node->private.texture = NULL;
	// If dependency allocation fails, each source commit conservatively
	// changes the capture hash instead of silently keeping stale pixels.
	struct glass_effect fallback = {.engine = &engine};
	wl_list_init(&fallback.dependencies);
	fail_next_glass_allocation = true;
	hash = damage_hash(&fallback, node, &surface, &bounds, &sample);
	assert(wl_list_empty(&fallback.dependencies));
	damage_commit(&surface, 0, 0, 0, 0);
	fail_next_glass_allocation = true;
	assert(damage_hash(&fallback, node, &surface, &bounds, &sample) != hash);
	assert(wl_list_empty(&fallback.dependencies));
	wlr_buffer_drop(&one->base);
	wlr_buffer_drop(&two->base);

	// A source no longer in an effect's capture stops waking that effect.
	dependencies_begin(&second);
	dependencies_prune(&second);
	assert(wl_list_empty(&second.dependencies));
	dependencies_begin(&first);
	assert(dependency_get(&first, node, &surface) == a);
	dependencies_prune(&first);
	assert(!wl_list_empty(&first.dependencies));

	// Source destruction must refresh the blur even when opaque foreground
	// windows hide all of the source's ordinary scene damage.
	engine.resync = false;
	wlr_scene_node_destroy(&node->node);
	assert(engine.resync);
	assert(wl_list_empty(&first.dependencies) && wl_list_empty(&second.dependencies));
	assert(wl_list_empty(&surface.events.commit.listener_list));
	node = wlr_scene_buffer_create(&scene->tree, NULL);
	assert(node && dependency_get(&first, node, &surface));
	engine.resync = false;
	wl_signal_emit_mutable(&surface.events.destroy, &surface);
	assert(engine.resync);
	assert(wl_list_empty(&first.dependencies));
	wlr_scene_node_destroy(&scene->tree.node);
	pixman_region32_fini(&surface.buffer_damage);
	fputs("PASS: glass source damage accumulation, mapping, independent effects and lifetime\n", stderr);
}
static bool projection_input(struct wlr_scene_buffer *buffer, double *x, double *y) {
    (void)buffer;
    // Model a cropped surface's input callback, including a source-local offset.
    if (*x < 10) return false;
    *x += 7; *y += 9;
    return true;
}
static void projection_checks(struct wlr_scene *scene, struct glass_engine *engine) {
    struct wlr_scene_tree *source = wlr_scene_tree_create(&scene->tree);
    struct wlr_scene_tree *view = wlr_scene_tree_create(&scene->tree);
    struct rediwm_projection *p = rediwm_projection_create(source, view, scene);
    assert(p);
    struct wlr_scene_tree *frame = wlr_scene_tree_create(source);
    wlr_scene_node_set_position(&frame->node, 101, 51);
    struct test_buffer *image = buffer_create(400, 260, 0xffff0000, 0xff0000ff);
    struct wlr_scene_buffer *client = wlr_scene_buffer_create(frame, &image->base);
    wlr_buffer_drop(&image->base);
    wlr_scene_buffer_set_source_box(client, &(struct wlr_fbox){10, 10, 380, 240});
    wlr_scene_buffer_set_dest_size(client, 400, 260);
    client->point_accepts_input = projection_input;
    const double levels[] = {1, .85, .70, .55, 1};
    for (size_t j = 0; j < sizeof(levels)/sizeof(levels[0]); j++) {
        double wz = levels[j];
        assert(rediwm_projection_set_tree_zoom(&frame->node, wz));
        for (size_t i = 0; i < sizeof(levels)/sizeof(levels[0]); i++) {
            double z = levels[i];
            rediwm_projection_sync(p, z, -20, -30, 0, 0);
            struct wlr_scene_node *displayed = rediwm_projection_node(p, &client->node);
            assert(displayed && rediwm_projection_source(displayed) == &client->node);
            struct wlr_scene_buffer *buffer = wlr_scene_buffer_from_node(displayed);
            int displayed_x, displayed_y;
            assert(wlr_scene_node_coords(displayed, &displayed_x, &displayed_y));
            assert(displayed_x == lround(121*z) && displayed_y == lround(81*z));
            assert(buffer->dst_width == lround(121*z+400*wz*z) - lround(121*z));
            assert(fabs(rediwm_projection_node_zoom(displayed) - wz*z) < .0001);
            assert(buffer->src_box.x == 10 && buffer->src_box.width == 380);
            assert(frame->node.x == 101 && frame->node.y == 51);
            assert(client->dst_width == 400 && client->dst_height == 260);
            double x, y;
            struct wlr_scene_node *hit = wlr_scene_node_at(&view->node,
                displayed_x + buffer->dst_width * .5, displayed_y + buffer->dst_height * .5, &x, &y);
            assert(hit == displayed);
            assert(fabs(x - 207) < .0001 && fabs(y - 139) < .0001);
            assert(!wlr_scene_node_at(&view->node, displayed_x + 1, displayed_y + 1, &x, &y));
        }
    }
    assert(rediwm_projection_set_tree_zoom(&frame->node, .70));
    struct wlr_scene_buffer *target = wlr_scene_buffer_create(frame, NULL);
    wlr_scene_buffer_set_dest_size(target, 200, 60);
    struct glass_effect *effect = rediwm_glass_attach(engine, target, &target->node, GLASS_TITLEBAR);
    rediwm_glass_configure(effect, 10, 1);
    rediwm_projection_sync(p, .55, 0, 0, 0, 0);
    rediwm_glass_project(engine, p, .55);
    engine->bounds = (struct wlr_box){0, 0, 1280, 720};
    update_effect(effect, 1);
    assert(effect->valid && effect->projected_node->dst_width == 77);
    assert(fabs(effect->zoom - .70*.55) < .0001);
    uint64_t revision = effect->revision;
    rediwm_projection_sync(p, .55, 0, 0, 0, 0);
    rediwm_glass_project(engine, p, .55);
    update_effect(effect, 1);
    assert(effect->revision == revision);
    wlr_scene_node_set_enabled(&frame->node, false);
    rediwm_projection_sync(p, .55, 0, 0, 0, 0);
    update_effect(effect, 1);
    assert(!effect->projected_node->node.enabled);
    // Source destruction tears down all mirrors, including effect targets.
    wlr_scene_node_destroy(&frame->node);
    assert(wl_list_empty(&view->children));
    rediwm_projection_destroy(p);
    wlr_scene_node_destroy(&source->node);
    wlr_scene_node_destroy(&view->node);
    fputs("projection geometry, input, glass and destruction checks passed\n", stderr);
}

int main(int argc, char **argv)
{
	wlr_log_init(WLR_ERROR, NULL);
	damage_checks();
	if (argc == 2 && strcmp(argv[1], "--damage-only") == 0)
		return 0;
	struct wl_display *display = wl_display_create();
	assert(display);
	struct wlr_backend *backend =
	    wlr_headless_backend_create(wl_display_get_event_loop(display));
	assert(backend);
	struct wlr_renderer *renderer = wlr_renderer_autocreate(backend);
	assert(renderer);
	struct wlr_allocator *allocator = wlr_allocator_autocreate(backend, renderer);
	assert(allocator);
	struct wlr_scene *scene = wlr_scene_create();
	assert(scene);
	struct glass_engine *engine = rediwm_glass_create(renderer, allocator, scene, NULL);
	assert(engine && !engine->failed);
	float color[] = {.2, .4, .6, 1};
	struct wlr_scene_rect *background = wlr_scene_rect_create(&scene->tree, 2000, 2000, color);
	wlr_scene_node_set_position(&background->node, -500, -500);
	struct wlr_scene_buffer *target = wlr_scene_buffer_create(&scene->tree, NULL);
	wlr_scene_buffer_set_dest_size(target, 200, 200);
	struct glass_effect *effect =
	    rediwm_glass_attach(engine, target, &target->node, GLASS_TITLEBAR);
	rediwm_glass_configure(effect, 10, 1);
	// A foreground window must never feed back into this window's filter.
	float green[] = {0, 1, 0, 1};
	struct wlr_scene_rect *foreground = wlr_scene_rect_create(&scene->tree, 200, 200, green);
	update_effect(effect, 1);
	assert(effect->valid && !engine->failed);
	uint32_t center = pixel(effect, 100, 100);
	// CSS saturate(150%) of RGB(51,102,153).
	near_channel(center, 24, 255, 0);
	near_channel(center, 16, 29, 2);
	near_channel(center, 8, 106, 2);
	near_channel(center, 0, 182, 2);
	assert(pixel(effect, 0, 0) == 0);
	assert(pixel(effect, 0, 199) >> 24 == 255); // only the top corners are round
	uint64_t revision = effect->revision;
	update_effect(effect, 1);
	assert(effect->revision == revision);
	wlr_scene_rect_set_color(foreground, color);
	update_effect(effect, 1);
	assert(effect->revision == revision);

	// Vertical asymmetry detects an upside-down FBO or source transform.
	float red[] = {1, 0, 0, 1}, blue[] = {0, 0, 1, 1};
	wlr_scene_rect_set_color(background, blue);
	struct wlr_scene_rect *upper = wlr_scene_rect_create(&scene->tree, 2000, 600, red);
	wlr_scene_node_set_position(&upper->node, -500, -500);
	wlr_scene_node_place_below(&upper->node, &effect->node->node);
	update_effect(effect, 1);
	assert(effect->revision > revision);
	near_channel(pixel(effect, 100, 20), 16, 255, 2);
	near_channel(pixel(effect, 100, 180), 0, 255, 2);
	uint32_t boundary = pixel(effect, 100, 100);
	assert(((boundary >> 16) & 255) > 90 && (boundary & 255) > 90);
	// Fractional scale keeps the same logical blur radius and clipped arcs.
	update_effect(effect, 1.5);
	near_channel(pixel(effect, 150, 30), 16, 255, 2);
	near_channel(pixel(effect, 150, 270), 0, 255, 2);
	assert(pixel(effect, 0, 0) == 0);

	// A real texture, cropped and scaled like a viewporter/buffer-scale
	// client, must agree with the same scene geometry made from rectangles.
	wlr_scene_node_set_enabled(&upper->node, false);
	struct test_buffer *image = buffer_create(160, 160, 0xffff0000, 0xff0000ff);
	struct wlr_scene_buffer *client = wlr_scene_buffer_create(&scene->tree, &image->base);
	wlr_buffer_drop(&image->base);
	wlr_scene_buffer_set_source_box(client, &(struct wlr_fbox){40, 40, 80, 80});
	wlr_scene_buffer_set_dest_size(client, 200, 200);
	wlr_scene_node_place_below(&client->node, &effect->node->node);
	update_effect(effect, 1);
	near_channel(pixel(effect, 100, 40), 16, 255, 5);
	near_channel(pixel(effect, 100, 160), 0, 255, 5);
	wlr_scene_buffer_set_transform(client, WL_OUTPUT_TRANSFORM_180);
	update_effect(effect, 1);
	near_channel(pixel(effect, 100, 40), 0, 255, 5);
	near_channel(pixel(effect, 100, 160), 16, 255, 5);

	// Screen-edge clamping: glass at the bottom must not blur in black
	// from beyond the wallpaper/output. All samples remain the same blue.
	wlr_scene_node_set_enabled(&client->node, false);
	wlr_scene_node_set_position(&background->node, 0, 0);
	wlr_scene_rect_set_size(background, 200, 200);
	engine->bounds = (struct wlr_box){0, 0, 200, 200};
	update_effect(effect, 1);
	near_channel(pixel(effect, 100, 199), 0, 255, 2);
	near_channel(pixel(effect, 199, 100), 0, 255, 2);

	// Fade the panel and its backing as one group: if the front has alpha
	// .37 at t=.5, the backing must be (.5-.37)/(1-.37), not another .5.
	struct test_buffer *panel = buffer_create(200, 200, 0x5e05060b, 0x5e05060b);
	wlr_scene_buffer_set_buffer(target, &panel->base);
	wlr_buffer_drop(&panel->base);
	effect->kind = GLASS_PANEL;
	rediwm_glass_configure(effect, 10, .5);
	update_effect(effect, 1);
	uint32_t faded = pixel(effect, 100, 100);
	near_channel(faded, 24, 53, 2);
	near_channel(faded, 0, 53, 2);
	assert(pixel(effect, 199, 199) == 0);

	// Scene-buffer opacity with full-opacity pixels (the panel-reuse path)
	// must match the CPU-faded buffer above: front = 0.737 * 0.5 = 0.37.
	wlr_scene_buffer_set_opacity(target, .5);
	struct test_buffer *full = buffer_create(200, 200, 0xbc0a0c16, 0xbc0a0c16);
	wlr_scene_buffer_set_buffer(target, &full->base);
	wlr_buffer_drop(&full->base);
	rediwm_glass_configure(effect, 10, .5);
	update_effect(effect, 1);
	uint32_t scene_faded = pixel(effect, 100, 100);
	near_channel(scene_faded, 24, 53, 2);
	near_channel(scene_faded, 0, 53, 2);

	// Power menu: glass stays at opacity 1 while the panel fades.
	rediwm_glass_configure(effect, 10, 1);
	update_effect(effect, 1);
	near_channel(pixel(effect, 100, 100), 24, 255, 2);
	wlr_scene_buffer_set_opacity(target, 1);

	// Removing the target owns and removes its effect, including GPU buffers.
	wlr_scene_node_destroy(&target->node);
	assert(wl_list_empty(&engine->effects));
    projection_checks(scene, engine);
	rediwm_glass_destroy(engine);
	wlr_scene_node_destroy(&scene->tree.node);
	wlr_allocator_destroy(allocator);
	wlr_renderer_destroy(renderer);
	wlr_backend_destroy(backend);
	wl_display_destroy(display);
	fputs("glass GPU checks passed\n", stderr);
	return 0;
}
