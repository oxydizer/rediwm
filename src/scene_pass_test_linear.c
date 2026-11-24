// Linear pass gates: opaque content round-trips,
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

// SMPTE ST 2084 of `nits`, as an 8-bit level.
static int pq_level(double nits) {
    const double m1 = 2610. / 16384, m2 = 2523. / 4096 * 128, c1 = 3424. / 4096, c2 = 2413. / 4096 * 32,
        c3 = 2392. / 4096 * 32;
    const double p = pow(fmin(fmax(nits / 10000, 0), 1), m1);
    return (int)lround(pow((c1 + c2 * p) / (1 + c3 * p), m2) * 255);
}
// HDR10 encodes (phase 3): PQ on BT.2020 with 1.0 at the SDR white level, the
// adjustment matrix applied first, into 8 and 10 bits.
static void pq_gates(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator,
        struct rediwm_linear_target *t, const pixman_region32_t *whole) {
    struct wlr_buffer *a = target(allocator);
    struct rediwm_pass_encode pq = {.pq = true, .sdr_white = 203};
    struct wlr_render_pass *pass = linear_pass(r, a, t);
    solid(pass, (struct wlr_box){0, 0, WIDTH, HEIGHT}, 1, 1, 1, 1);
    solid(pass, (struct wlr_box){0, 0, 20, 20}, .5f, .5f, .5f, 1);
    solid(pass, (struct wlr_box){30, 0, 20, 20}, 1, 0, 0, 1);
    rediwm_scene_pass_encode(pass, whole, &pq);
    assert(wlr_render_pass_submit(pass));
    uint8_t px[4];
    // SDR white at 203 cd/m², grey at its gamma 2.2 share, all three channels.
    pixel_at(r, a, 60, 60, px);
    assert(abs(px[0] - pq_level(203)) <= 1 && px[0] == px[1] && px[1] == px[2] && px[3] == 255);
    pixel_at(r, a, 10, 10, px);
    assert(abs(px[0] - pq_level(203 * pow(.5, 2.2))) <= 1 && px[0] == px[2]);
    // sRGB red inside the BT.2020 container: the BT.709-to-BT.2020 row sums.
    pixel_at(r, a, 40, 10, px);
    assert(abs(px[0] - pq_level(203 * .627404)) <= 1 && abs(px[1] - pq_level(203 * .069097)) <= 1 &&
        abs(px[2] - pq_level(203 * .016391)) <= 1);
    // The matrix comes first: half the red of white, as night light would take.
    pq.adjust[0] = .5f;
    pq.adjust[4] = pq.adjust[8] = 1;
    pass = linear_pass(r, a, t);
    rediwm_scene_pass_encode(pass, whole, &pq);
    assert(wlr_render_pass_submit(pass));
    pixel_at(r, a, 60, 60, px);
    assert(abs(px[0] - pq_level(101.5)) <= 1 && abs(px[1] - pq_level(203)) <= 1);
    // A white level outside 1 to 10000 cd/m² fails the pass.
    pass = linear_pass(r, a, t);
    rediwm_scene_pass_encode(pass, whole, &(struct rediwm_pass_encode){.pq = true, .sdr_white = 0});
    assert(!wlr_render_pass_submit(pass));
    // Into a 10-bit buffer, the format an HDR output renders to, where it exists.
    uint64_t modifier = DRM_FORMAT_MOD_INVALID;
    struct wlr_drm_format format = {.format = DRM_FORMAT_XRGB2101010, .len = 1, .capacity = 1, .modifiers = &modifier};
    struct wlr_buffer *deep = wlr_allocator_create_buffer(allocator, WIDTH, HEIGHT, &format);
    if (deep) {
        pq = (struct rediwm_pass_encode){.pq = true, .sdr_white = 203};
        pass = linear_pass(r, deep, t);
        rediwm_scene_pass_encode(pass, whole, &pq);
        assert(wlr_render_pass_submit(pass));
        pixel_at(r, deep, 60, 60, px);
        assert(abs(px[0] - pq_level(203)) <= 1 && px[0] == px[1] && px[1] == px[2]);
        wlr_buffer_drop(deep);
    }
    // PQ submitted by a client is absolute. Changing desktop white must leave
    // these 1000-nit samples unchanged after composition and PQ encoding.
    struct rediwm_buffer node = {.transfer_function = WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ,
        .primaries = WLR_COLOR_NAMED_PRIMARIES_BT2020};
    for (int white = 100; white <= 400; white *= 2) {
        pq = (struct rediwm_pass_encode){.pq = true, .sdr_white = white};
        pass = linear_pass(r, a, t);
        rediwm_scene_pass_set_destination(pass, &pq);
        rediwm_scene_pass_set_source(pass, &node);
        float encoded = pq_level(1000) / 255.f;
        solid(pass, (struct wlr_box){0, 0, WIDTH, HEIGHT}, encoded, encoded, encoded, 1);
        rediwm_scene_pass_encode(pass, whole, &pq);
        assert(wlr_render_pass_submit(pass));
        pixel_at(r, a, 10, 10, px);
        assert(abs(px[0] - pq_level(1000)) <= 1 && px[0] == px[1] && px[0] == px[2]);
    }
    // Half-transparent electrically premultiplied PQ over black yields half
    // the light, before encoding or the SDR capture's shoulder.
    pq.sdr_white = 203;
    pass = linear_pass(r, a, t);
    rediwm_scene_pass_set_destination(pass, &pq);
    solid(pass, (struct wlr_box){0, 0, WIDTH, HEIGHT}, 0, 0, 0, 1);
    rediwm_scene_pass_set_source(pass, &node);
    float half = .5f * pq_level(1000) / 255.f;
    solid(pass, (struct wlr_box){0, 0, WIDTH, HEIGHT}, half, half, half, .5f);
    rediwm_scene_pass_encode(pass, whole, &pq);
    assert(wlr_render_pass_submit(pass));
    pixel_at(r, a, 10, 10, px);
    assert(abs(px[0] - pq_level(500)) <= 1);
    pass = linear_pass(r, a, t);
    rediwm_scene_pass_encode(pass, whole, &(struct rediwm_pass_encode){.tone_map = true});
    assert(wlr_render_pass_submit(pass));
    pixel_at(r, a, 10, 10, px);
    assert(abs(px[0] - 251) <= 1 && px[0] == px[1] && px[0] == px[2]);
    // Extended-linear samples above reference white use the same shoulder.
    node.transfer_function = WLR_COLOR_TRANSFER_FUNCTION_EXT_LINEAR;
    pass = linear_pass(r, a, t);
    rediwm_scene_pass_set_source(pass, &node);
    solid(pass, (struct wlr_box){0, 0, WIDTH, HEIGHT}, 2, 2, 2, 1);
    rediwm_scene_pass_encode(pass, whole, NULL);
    assert(wlr_render_pass_submit(pass));
    pixel_at(r, a, 10, 10, px);
    assert(abs(px[0] - 250) <= 1 && px[0] == px[1] && px[0] == px[2]);
    wlr_buffer_drop(a);
    printf("PASS: PQ encodes: white level, BT.2020 container, adjustment first, %s\n",
        deep ? "8 and 10 bits" : "8 bits (no 10-bit buffers here)");
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
        rediwm_scene_pass_encode(pass, &whole, NULL);
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
    rediwm_scene_pass_encode(pass, &whole, NULL);
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
    rediwm_scene_pass_encode(pass, &whole, NULL);
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
    rediwm_scene_pass_encode(pass, &part, NULL);
    assert(wlr_render_pass_submit(pass));
    pixel_at(r, a, 70, 50, px);
    assert(px[0] <= 3 && px[1] == 255 && px[2] <= 3); // green's zeros by cancellation, as above
    pixel_at(r, a, 10, 10, px);
    assert(px[0] == 255 && px[1] == 0 && px[2] == 0);
    pixman_region32_fini(&part);

    // Nothing may be drawn after the encode, and only a linear pass encodes.
    pass = linear_pass(r, a, t);
    rediwm_scene_pass_encode(pass, &whole, NULL);
    solid(pass, (struct wlr_box){0, 0, 10, 10}, 1, 1, 1, 1);
    assert(!wlr_render_pass_submit(pass));
    pass = rediwm_scene_pass_begin(r, a, NULL);
    rediwm_scene_pass_encode(pass, &whole, NULL);
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
    rediwm_scene_pass_encode(pass, &whole, NULL);
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
    rediwm_scene_pass_encode(pass, &whole, NULL);
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
    rediwm_scene_pass_encode(pass, &whole, NULL);
    assert(!wlr_render_pass_submit(pass));
    rediwm_scene_renderer_destroy_backdrop(r, lin_blur);
    rediwm_scene_renderer_destroy_backdrop(r, plain_blur);

    pq_gates(r, allocator, t, &whole);
    pixman_region32_fini(&whole);
    rediwm_scene_renderer_destroy_linear_target(r, t);
    wlr_buffer_drop(a);
    wlr_buffer_drop(b);
    puts("PASS: linear passes: round trip, linear blends, kept image, partial encode, dim, glass");
}
