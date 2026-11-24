// Linear pass gates (docs/plans/hdr.md, phase 2): opaque content round-trips,
// translucency blends in linear light, the FP16 image is kept between passes,
// the encode writes only its region and ends the pass, and glass blurs keep the
// encoding they were taken in.
// Included by scene_pass_test.c, in its one unit with scene_pass.c.

static void pixel_at(struct rediwm_scene_renderer *r, struct wlr_buffer *b, int x, int y, uint8_t out[4]) {
    static uint8_t pixels[WIDTH * HEIGHT * 4];
    read_pixels(r, b, pixels);
    memcpy(out, &pixels[(y * WIDTH + x) * 4], 4);
}
static struct wlr_render_pass *linear_pass(struct rediwm_scene_renderer *r, struct wlr_buffer *b,
        struct rediwm_linear_target *t) {
    struct wlr_render_pass *pass = rediwm_scene_pass_begin_linear(r, b, NULL, t);
    assert(pass);
    return pass;
}
static void solid(struct wlr_render_pass *pass, struct wlr_box box, float r, float g, float b, float a) {
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
        .box = box, .color = {r, g, b, a}, .blend_mode = WLR_RENDER_BLEND_MODE_PREMULTIPLIED});
}
// The sRGB level a straight colour `c` at `alpha` over black comes out at when the
// blend is done in linear light: decode, blend, encode (gamma 2.2 both ways).
static int linear_over_black(float c, float alpha) {
    return (int)lround(pow(pow(c, 2.2) * alpha, 1 / 2.2) * 255);
}

static void linear_gates(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator) {
    assert(rediwm_scene_renderer_enable_backdrops(r)); // for the glass case
    assert(rediwm_scene_renderer_enable_linear(r));
    assert(rediwm_scene_renderer_enable_linear(r)); // idempotent
    struct wlr_buffer *a = target(allocator), *b = target(allocator);
    struct rediwm_linear_target *t = NULL;
    bool fresh = false;
    // The target must be the buffer's size.
    assert(rediwm_scene_renderer_ensure_linear_target(r, &t, WIDTH + 1, HEIGHT, &fresh) && fresh);
    assert(!rediwm_scene_pass_begin_linear(r, a, NULL, t));
    assert(!rediwm_scene_pass_begin_linear(r, a, NULL, NULL));
    assert(rediwm_scene_renderer_ensure_linear_target(r, &t, WIDTH, HEIGHT, &fresh) && fresh);
    assert(rediwm_scene_renderer_ensure_linear_target(r, &t, WIDTH, HEIGHT, &fresh) && !fresh);
    pixman_region32_t whole;
    pixman_region32_init_rect(&whole, 0, 0, WIDTH, HEIGHT);

    // Opaque content, plain and shaped, comes back as the plain pass draws it.
    // A saturated colour can lose up to three levels in a channel near zero: the
    // BT.2020-to-sRGB conversion reaches it by cancellation, FP16 leaves a few
    // 1e-5 of residue, and gamma 2.2 is steep near black.
    struct wlr_texture *opaque = texture_create(r->renderer, true);
    const struct rediwm_pass_shape shape = {.box = {0, 0, WIDTH, HEIGHT}};
    for (int shaped = 0; shaped < 2; shaped++) {
        float alpha = 1;
        const struct wlr_render_texture_options tex = {.texture = opaque, .dst_box = {-3, 11, 112, 77},
            .alpha = &alpha, .blend_mode = WLR_RENDER_BLEND_MODE_NONE};
        struct wlr_render_pass *pass = rediwm_scene_pass_begin(r, b, NULL);
        clear(pass);
        if (shaped) rediwm_scene_pass_add_texture_shaped(pass, &tex, &shape);
        else wlr_render_pass_add_texture(pass, &tex);
        assert(wlr_render_pass_submit(pass));
        pass = linear_pass(r, a, t);
        clear(pass);
        if (shaped) rediwm_scene_pass_add_texture_shaped(pass, &tex, &shape);
        else wlr_render_pass_add_texture(pass, &tex);
        rediwm_scene_pass_encode(pass, &whole);
        assert(wlr_render_pass_submit(pass));
        const int worst = compare(r, a, b);
        if (worst > 3) fprintf(stderr, "linear opaque round trip (shaped %d): worst %d\n", shaped, worst);
        assert(worst <= 3);
    }
    wlr_texture_destroy(opaque);

    // Translucency blends in linear light: half-transparent white and a
    // quarter-opaque grey over black, against the formula. (The plain pass gives
    // 128 for the first: it blends the encoded values.)
    struct wlr_render_pass *pass = linear_pass(r, a, t);
    solid(pass, (struct wlr_box){0, 0, WIDTH, HEIGHT}, 0, 0, 0, 1);
    solid(pass, (struct wlr_box){0, 0, 20, 20}, .5f, .5f, .5f, .5f);
    solid(pass, (struct wlr_box){30, 0, 20, 20}, .6f * .25f, .6f * .25f, .6f * .25f, .25f);
    rediwm_scene_pass_encode(pass, &whole);
    assert(wlr_render_pass_submit(pass));
    uint8_t px[4];
    pixel_at(r, a, 10, 10, px);
    assert(abs(px[0] - linear_over_black(1, .5f)) <= 1 && px[0] == px[1] && px[1] == px[2] && px[3] == 255);
    pixel_at(r, a, 40, 10, px);
    assert(abs(px[0] - linear_over_black(.6f, .25f)) <= 1);

    // The image is kept: a pass that draws nothing new encodes the same frame.
    uint8_t before[WIDTH * HEIGHT * 4], after[sizeof(before)];
    read_pixels(r, a, before);
    pass = rediwm_scene_pass_begin(r, a, NULL);
    clear(pass);
    assert(wlr_render_pass_submit(pass));
    pass = linear_pass(r, a, t);
    rediwm_scene_pass_encode(pass, &whole);
    assert(wlr_render_pass_submit(pass));
    read_pixels(r, a, after);
    assert(memcmp(before, after, sizeof(before)) == 0);

    // The encode writes only its region: the rest of the buffer keeps what it had.
    pass = rediwm_scene_pass_begin(r, a, NULL);
    solid(pass, (struct wlr_box){0, 0, WIDTH, HEIGHT}, 1, 0, 0, 1);
    assert(wlr_render_pass_submit(pass));
    pixman_region32_t part;
    pixman_region32_init_rect(&part, 60, 40, 30, 20);
    pass = linear_pass(r, a, t);
    solid(pass, (struct wlr_box){0, 0, WIDTH, HEIGHT}, 0, 1, 0, 1);
    rediwm_scene_pass_encode(pass, &part);
    assert(wlr_render_pass_submit(pass));
    pixel_at(r, a, 70, 50, px);
    assert(px[0] <= 3 && px[1] == 255 && px[2] <= 3); // green's zeros by cancellation, as above
    pixel_at(r, a, 10, 10, px);
    assert(px[0] == 255 && px[1] == 0 && px[2] == 0);
    pixman_region32_fini(&part);

    // Nothing may be drawn after the encode, and only a linear pass encodes.
    pass = linear_pass(r, a, t);
    rediwm_scene_pass_encode(pass, &whole);
    solid(pass, (struct wlr_box){0, 0, 10, 10}, 1, 1, 1, 1);
    assert(!wlr_render_pass_submit(pass));
    pass = rediwm_scene_pass_begin(r, a, NULL);
    rediwm_scene_pass_encode(pass, &whole);
    assert(!wlr_render_pass_submit(pass));

    // A dimmed opaque grey looks as the plain pass dims it: the brightness step
    // is taken in linear light by its gamma 2.2 equivalent.
    pass = rediwm_scene_pass_begin(r, b, NULL);
    rediwm_scene_pass_set_dim(pass, .5f, 0);
    solid(pass, (struct wlr_box){0, 0, WIDTH, HEIGHT}, .5f, .5f, .5f, 1);
    assert(wlr_render_pass_submit(pass));
    pass = linear_pass(r, a, t);
    rediwm_scene_pass_set_dim(pass, .5f, 0);
    solid(pass, (struct wlr_box){0, 0, WIDTH, HEIGHT}, .5f, .5f, .5f, 1);
    rediwm_scene_pass_encode(pass, &whole);
    assert(wlr_render_pass_submit(pass));
    assert(compare(r, a, b) <= 1);

    // Glass in a linear pass blurs in FP16; that blur cannot be composited by a
    // plain pass, nor a plain blur by a linear one.
    const struct wlr_box region = {8, 8, 80, 60}, box = {20, 20, 50, 30};
    struct rediwm_backdrop *lin_blur = NULL, *plain_blur = NULL;
    pass = linear_pass(r, a, t);
    solid(pass, (struct wlr_box){0, 0, WIDTH, HEIGHT}, .2f, .4f, .8f, 1);
    rediwm_scene_pass_begin_backdrop(pass, region, 4);
    solid(pass, (struct wlr_box){0, 0, WIDTH / 2, HEIGHT}, 1, 1, 1, 1);
    solid(pass, (struct wlr_box){WIDTH / 2, 0, WIDTH - WIDTH / 2, HEIGHT}, .2f, .4f, .8f, 1);
    rediwm_scene_pass_end_backdrop(pass, &lin_blur, 8);
    rediwm_scene_pass_add_backdrop(pass, &(struct rediwm_pass_shape){.box = box}, box,
        &(struct rediwm_pass_backdrop){.backdrop = lin_blur, .saturation = 1, .opacity = 1});
    rediwm_scene_pass_encode(pass, &whole);
    assert(wlr_render_pass_submit(pass));
    assert(lin_blur && lin_blur->linear);
    // Left of the effect's centre the blur is the white half, right of it the blue.
    pixel_at(r, a, 24, 35, px);
    assert(px[0] > 200 && px[1] > 200 && px[2] > 200);
    pixel_at(r, a, 69, 35, px);
    assert(px[2] > px[0]);
    pass = rediwm_scene_pass_begin(r, b, NULL);
    rediwm_scene_pass_add_backdrop(pass, &(struct rediwm_pass_shape){.box = box}, box,
        &(struct rediwm_pass_backdrop){.backdrop = lin_blur, .saturation = 1, .opacity = 1});
    assert(!wlr_render_pass_submit(pass));
    pass = rediwm_scene_pass_begin(r, b, NULL);
    rediwm_scene_pass_begin_backdrop(pass, region, 4);
    solid(pass, (struct wlr_box){0, 0, WIDTH, HEIGHT}, 1, 1, 1, 1);
    rediwm_scene_pass_end_backdrop(pass, &plain_blur, 8);
    assert(wlr_render_pass_submit(pass));
    assert(plain_blur && !plain_blur->linear);
    pass = linear_pass(r, a, t);
    rediwm_scene_pass_add_backdrop(pass, &(struct rediwm_pass_shape){.box = box}, box,
        &(struct rediwm_pass_backdrop){.backdrop = plain_blur, .saturation = 1, .opacity = 1});
    rediwm_scene_pass_encode(pass, &whole);
    assert(!wlr_render_pass_submit(pass));
    rediwm_scene_renderer_destroy_backdrop(r, lin_blur);
    rediwm_scene_renderer_destroy_backdrop(r, plain_blur);

    pixman_region32_fini(&whole);
    rediwm_scene_renderer_destroy_linear_target(r, t);
    wlr_buffer_drop(a);
    wlr_buffer_drop(b);
    puts("PASS: linear passes: round trip, linear blends, kept image, partial encode, dim, glass");
}
