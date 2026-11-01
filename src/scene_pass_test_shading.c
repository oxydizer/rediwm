// Dimming, the opaque cover, the analytic shadow and partial repaints across a
// clip edge; shaped_gates() runs every shape gate.
// Included by scene_pass_test.c, in its one unit with scene_pass.c.

// ---- Dimming: a window that is not the focus is graded in the pass ----------------
// What rediwm_scene_pass_set_dim documents, worked out here on its own: the colour is
// pulled toward its luminance by the saturation taken away, then everything is scaled
// by the brightness left. On premultiplied values, as the pass has them.
static void graded(const double in[3], double brightness, double saturation, double out[3]) {
    const double l = .213 * in[0] + .715 * in[1] + .072 * in[2];
    for (int i = 0; i < 3; i++) out[i] = (l + (in[i] - l) * (1 - saturation)) * (1 - brightness);
}
static void check_pixel(const struct image *img, int x, int y, const double want[3], const char *what) {
    for (int ch = 0; ch < 3; ch++)
        check(diff(at(img, x, y)[ch], (int)lround(255 * want[ch])) <= 2, "%s: (%d,%d) channel %d is %d, not %ld",
            what, x, y, ch, at(img, x, y)[ch], lround(255 * want[ch]));
}
static void gate_dim(struct rediwm_scene_renderer *r, struct wlr_buffer *buf, struct image *img) {
    const float db = .10f, ds = .20f;
    const float c[4] = {200 / 255.f, 100 / 255.f, 50 / 255.f, 1};
    const double cd[3] = {c[0], c[1], c[2]}, bg[3] = {BG[0], BG[1], BG[2]};
    double want[3];
    // A plain rect, then one after the dim is taken off: the first is graded, the
    // second and what was drawn before are not.
    struct wlr_render_pass *pass = begin_fill(r, buf, BG, NULL);
    rediwm_scene_pass_set_dim(pass, db, ds);
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){.box = {20, 20, 40, 40}, .color = {c[0], c[1], c[2], 1}});
    rediwm_scene_pass_set_dim(pass, 0, 0);
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){.box = {80, 20, 40, 40}, .color = {c[0], c[1], c[2], 1}});
    finish(pass);
    read_image(r, buf, img);
    graded(cd, db, ds, want);
    check_pixel(img, 40, 40, want, "a dimmed plain rect");
    check_pixel(img, 100, 40, cd, "a rect after the dim is taken off");
    check_pixel(img, 300, 300, bg, "the background before the dim");
    // A dimmed rect through a shape: the interior and the ring are graded, the
    // corner the shape cuts away is the backdrop, whole.
    const struct rediwm_pass_shape ring = {.box = {140, 100, 80, 80}, .radii = {20, 20, 20, 20}, .border = 4,
        .border_color = {.5f, 0, 0, .5f}};
    pass = begin_fill(r, buf, BG, NULL);
    rediwm_scene_pass_set_dim(pass, db, ds);
    piece(pass, &ring, ring.box, c, NULL);
    rediwm_scene_pass_set_dim(pass, 0, 0);
    finish(pass);
    read_image(r, buf, img);
    graded(cd, db, ds, want);
    check_pixel(img, 180, 140, want, "a dimmed shaped interior");
    const double under_ring[3] = {cd[0] * .5 + .5, cd[1] * .5, cd[2] * .5};
    graded(under_ring, db, ds, want);
    check_pixel(img, 141, 140, want, "a dimmed ring");
    check_pixel(img, 141, 101, bg, "the corner a dimmed shape cuts away");
    // A half-transparent texel: graded as premultiplied, then over the backdrop,
    // so it keeps its alpha.
    uint32_t half[16];
    for (int i = 0; i < 16; i++) half[i] = 0x80800000;
    struct wlr_texture *t_half = wlr_texture_from_pixels(r->renderer, DRM_FORMAT_ARGB8888, 16, 4, 4, half);
    check(t_half != NULL, "cannot create the test texture");
    const struct rediwm_pass_shape card = {.box = {240, 100, 80, 80}, .radii = {20, 20, 20, 20}};
    pass = begin_fill(r, buf, BG, NULL);
    rediwm_scene_pass_set_dim(pass, db, ds);
    rediwm_scene_pass_add_texture_shaped(pass, &(struct wlr_render_texture_options){
        .texture = t_half, .dst_box = card.box}, &card);
    rediwm_scene_pass_set_dim(pass, 0, 0);
    finish(pass);
    read_image(r, buf, img);
    const double alpha = 128 / 255., src[3] = {128 / 255., 0, 0};
    graded(src, db, ds, want);
    for (int i = 0; i < 3; i++) want[i] += bg[i] * (1 - alpha);
    check_pixel(img, 280, 140, want, "a dimmed half-transparent texel");
    wlr_texture_destroy(t_half);
    // A shadow is not graded, whatever the pass holds.
    const struct rediwm_pass_shape cast = {.box = {340, 100, 80, 80}, .radii = {20, 20, 20, 20}};
    const struct rediwm_pass_shadow shadow = {.softness = 12, .color = {.6f, 0, 0, .6f}};
    uint8_t plain[3];
    for (int dimmed = 0; dimmed < 2; dimmed++) {
        pass = begin_fill(r, buf, BG, NULL);
        if (dimmed) rediwm_scene_pass_set_dim(pass, db, ds);
        rediwm_scene_pass_add_shadow(pass, &cast, &shadow);
        finish(pass);
        read_image(r, buf, img);
        if (!dimmed) memcpy(plain, at(img, 380, 140), 3);
        else for (int ch = 0; ch < 3; ch++)
            check(diff(at(img, 380, 140)[ch], plain[ch]) <= 1, "a dimmed pass graded a shadow (channel %d)", ch);
    }
    // A pass that ends with the dim still set leaves none for the next one.
    pass = begin_fill(r, buf, BG, NULL);
    rediwm_scene_pass_set_dim(pass, .5f, .5f);
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){.box = {20, 20, 40, 40}, .color = {c[0], c[1], c[2], 1}});
    finish(pass);
    pass = begin_fill(r, buf, BG, NULL);
    wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){.box = {20, 20, 40, 40}, .color = {c[0], c[1], c[2], 1}});
    finish(pass);
    read_image(r, buf, img);
    check_pixel(img, 40, 40, cd, "the first rect of a pass after one that kept its dim");
    // A fraction outside 0 to 1 fails the pass, and the next one works.
    const float bad[][2] = {{-.1f, 0}, {0, 1.5f}, {NAN, 0}, {0, INFINITY}};
    for (size_t i = 0; i < COUNT(bad); i++) {
        pass = begin_fill(r, buf, BG, NULL);
        rediwm_scene_pass_set_dim(pass, bad[i][0], bad[i][1]);
        check(!wlr_render_pass_submit(pass), "a dim of (%g, %g) did not fail the pass", bad[i][0], bad[i][1]);
    }
    pass = begin_fill(r, buf, BG, NULL);
    finish(pass);
    puts("PASS: a dimmed pass grades rects, shapes, rings and translucent texels, not shadows, and fails closed");
}

// ---- Gate 5: the opaque cover of the model is fully covered in real pixels -------------
// rediwm_clip_opaque promises its rectangles are inside full coverage; the output
// pass will draw them without blending and trust that. Painting them first with
// blending off, then the whole window over them, must change nothing.
static void gate_opaque_cover(struct rediwm_scene_renderer *r, struct wlr_buffer *buf,
        struct image *img, struct image *ref) {
    for (size_t si = 0; si < COUNT(SCALES); si++) for (size_t zi = 0; zi < COUNT(ZOOMS); zi++) {
        struct window w = make_window(SCALES[si], ZOOMS[zi], 10, 1);
        struct rediwm_pass_shape s = w.shape;
        memcpy(s.border_color, BODY, sizeof(BODY));
        struct wlr_render_pass *pass = begin_fill(r, buf, BG, NULL);
        piece(pass, &s, s.box, BODY, NULL);
        finish(pass);
        read_image(r, buf, ref);
        // Border colour equals the body's here, so the cover may include the ring.
        struct rediwm_snap cover[3];
        int n = rediwm_clip_opaque(&w.clip, cover);
        check(n > 0, "no opaque cover at scale %.2f zoom %.2f", SCALES[si], ZOOMS[zi]);
        pass = begin_fill(r, buf, BG, NULL);
        for (int i = 0; i < n; i++)
            wlr_render_pass_add_rect(pass, &(struct wlr_render_rect_options){
                .box = box_of(cover[i]), .color = {BODY[0], BODY[1], BODY[2], 1},
                .blend_mode = WLR_RENDER_BLEND_MODE_NONE});
        piece(pass, &s, s.box, BODY, NULL);
        finish(pass);
        read_image(r, buf, img);
        for (int i = 0; i < img->w * img->h * 4; i++)
            check(diff(img->p[i], ref->p[i]) <= 1, "cover pixel differs at scale %.2f zoom %.2f (%d vs %d)",
                SCALES[si], ZOOMS[zi], img->p[i], ref->p[i]);
    }
    puts("PASS: the opaque cover draws without blending and changes nothing, at every scale and zoom");
}

// ---- Gate 6: analytic shadow ------------------------------------------------------------
// The CPU chrome's shadow (chrome.zig: ShadowBuffer.rasterize, shadowCoverage,
// edgeCoverage) at one pixel: smoothstep falloff from the moved shape, cut out of
// the unmoved one with a one-pixel ramp. Every pixel is compared, corners too.
static double cpu_shadow(double px, double py, const struct rediwm_pass_shape *s, double oy, double softness) {
    const double radii[4] = {s->radii[0], s->radii[1], s->radii[2], s->radii[3]};
    const double d = rediwm_sd_rounded_box(px, py, s->box.x, s->box.y + oy, s->box.width, s->box.height, radii);
    const double frame_d = rediwm_sd_rounded_box(px, py, s->box.x, s->box.y, s->box.width, s->box.height, radii);
    double t = 1 - d / softness;
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    double inside = .5 - frame_d;
    inside = inside < 0 ? 0 : inside > 1 ? 1 : inside;
    return t * t * (3 - 2 * t) * (1 - inside);
}
static void gate_shadow(struct rediwm_scene_renderer *r, struct wlr_buffer *buf, struct image *img) {
    const float white[4] = {1, 1, 1, 1};
    // The default theme: radius 10, softness 24, offset 8, at scale 1 and 1.5.
    const float scales[] = {1, 1.5f};
    int worst = 0;
    for (int si = 0; si < 2; si++) {
        const float k = scales[si];
        const float softness = 24 * k, oy = roundf(8 * k), radius = 10 * k;
        const struct rediwm_pass_shape s = {.box = {80, 60, 200, 120}, .radii = {radius, radius, radius, radius}};
        struct wlr_render_pass *pass = begin_fill(r, buf, white, NULL);
        rediwm_scene_pass_add_shadow(pass, &s, &(struct rediwm_pass_shadow){
            .offset_y = oy, .softness = softness, .color = {0, 0, 0, .5f}, .hide_inside = true});
        finish(pass);
        read_image(r, buf, img);
        for (int y = 0; y < img->h; y++)
            for (int x = 0; x < img->w; x++) {
                const int want = (int)lround(255 * (1 - .5 * cpu_shadow(x + .5, y + .5, &s, oy, softness)));
                const int got = at(img, x, y)[0];
                if (diff(got, want) > worst) worst = diff(got, want);
            }
        const int cx = s.box.x + s.box.width / 2, bottom = s.box.y + s.box.height;
        int last = 255;
        for (int dy = (int)oy; dy < 60; dy++) {
            const int got = at(img, cx, bottom + dy)[0];
            check(got >= last || dy == (int)oy, "shadow is not monotonic at %d px (%d after %d)", dy, got, last);
            last = got;
        }
        check(at(img, 10, 10)[0] == 255 && at(img, cx, s.box.y + s.box.height / 2)[0] == 255,
            "shadow reaches outside its footprint or inside the window");
    }
    check(worst <= 1, "shadow differs from the CPU chrome's by %d levels", worst);
    // Not hidden inside: the same draw shows through the window.
    const struct rediwm_pass_shape s = {.box = {80, 60, 200, 120}};
    struct wlr_render_pass *pass = begin_fill(r, buf, white, NULL);
    rediwm_scene_pass_add_shadow(pass, &s, &(struct rediwm_pass_shadow){
        .offset_y = 6, .softness = 24, .color = {0, 0, 0, .5f}});
    finish(pass);
    read_image(r, buf, img);
    check(at(img, s.box.x + s.box.width / 2, s.box.y + s.box.height / 2)[0] < 200,
        "an unhidden shadow does not show under the shape");
    printf("PASS: analytic shadow equals the CPU chrome's at every pixel, corners included (max diff %d), "
        "and stays out of the window\n", worst);
}

// ---- Gate 7: a partial repaint across a clip edge equals a full repaint -----------------
static void draw_scene(struct rediwm_scene_renderer *r, struct wlr_buffer *buf, const struct window *w,
        int variant, const pixman_region32_t *clip) {
    const float bodies[2][3][4] = {
        {{.2f, .3f, .5f, 1}, {.9f, .9f, .9f, 1}, {.3f, .3f, .3f, 1}},
        {{.8f, .2f, .2f, 1}, {.1f, .6f, .2f, 1}, {.6f, .6f, .1f, 1}},
    };
    struct rediwm_pass_shape s = w->shape;
    const float rings[2][4] = {{1, 1, 1, 1}, {1, 0, 0, 1}};
    memcpy(s.border_color, rings[variant], sizeof(rings[variant]));
    struct wlr_render_pass *pass = begin_fill(r, buf, BG, clip);
    rediwm_scene_pass_add_shadow(pass, &s, &(struct rediwm_pass_shadow){
        .offset_y = 12, .softness = 24,
        .color = {0, 0, 0, .4f}, .hide_inside = true, .clip = clip});
    piece(pass, &s, w->title, bodies[variant][0], clip);
    piece(pass, &s, w->client, bodies[variant][1], clip);
    piece(pass, &s, w->footer, bodies[variant][2], clip);
    finish(pass);
}
static void gate_damage_at_clip_edge(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator,
        struct image *img) {
    struct wlr_buffer *a = target_sized(allocator, GW, GH), *b = target_sized(allocator, GW, GH),
        *c = target_sized(allocator, GW, GH);
    struct image one = {0}, two = {0};
    int differing_inside = 0, differing_outside = 0;
    const float zooms[] = {1.f, .55f};
    for (size_t si = 0; si < COUNT(SCALES); si++) for (size_t zi = 0; zi < COUNT(zooms); zi++) {
        struct window w = make_window(SCALES[si], zooms[zi], 10, 1);
        const struct wlr_box *bx = &w.shape.box;
        // Damage whose edges cut through the corner arcs, the ring and the shadow:
        // a square over the top-left arc, one over the bottom-right, and a band.
        pixman_region32_t damage;
        pixman_region32_init_rect(&damage, bx->x - 5, bx->y - 5, 13, 13);
        pixman_region32_union_rect(&damage, &damage, bx->x + bx->width - 9, bx->y + bx->height - 11, 30, 29);
        pixman_region32_union_rect(&damage, &damage, bx->x + bx->width / 3, bx->y + 3, 7, bx->height + 20);
        draw_scene(r, a, &w, 0, NULL);
        draw_scene(r, b, &w, 1, NULL);
        draw_scene(r, c, &w, 0, NULL);
        draw_scene(r, c, &w, 1, &damage);
        read_image(r, a, &one);
        read_image(r, b, &two);
        read_image(r, c, img);
        for (int y = 0; y < GH; y++) for (int x = 0; x < GW; x++) {
            bool in = pixman_region32_contains_point(&damage, x, y, NULL);
            const uint8_t *want = at(in ? &two : &one, x, y);
            for (int ch = 0; ch < 4; ch++)
                check(at(img, x, y)[ch] == want[ch],
                    "partial repaint differs at (%d,%d) channel %d (%s damage): %d, wanted %d (scale %.2f)",
                    x, y, ch, in ? "inside" : "outside", at(img, x, y)[ch], want[ch], SCALES[si]);
            if (memcmp(at(&one, x, y), at(&two, x, y), 4)) in ? differing_inside++ : differing_outside++;
        }
        pixman_region32_fini(&damage);
    }
    // The control: the two frames really differ both where the damage is and where it is not.
    check(differing_inside > 0 && differing_outside > 0, "the test frames do not differ across the damage edge");
    free(one.p);
    free(two.p);
    wlr_buffer_drop(a);
    wlr_buffer_drop(b);
    wlr_buffer_drop(c);
    puts("PASS: repainting only damage that cuts through arcs, ring and shadow equals a full repaint");
}

static void shaped_gates(struct rediwm_scene_renderer *r, struct wlr_allocator *allocator) {
    struct wlr_buffer *buf = target_sized(allocator, GW, GH);
    struct image img = {0}, ref = {0};
    gate_clip_accuracy(r, buf, &img);
    gate_no_seams(r, buf, &img);
    gate_border_partition(r, buf, &img, &ref);
    gate_premultiplied(r, buf, &img);
    gate_polygon(r, buf, &img, &ref);
    gate_sector(r, buf, &img);
    gate_dim(r, buf, &img);
    gate_opaque_cover(r, buf, &img, &ref);
    gate_shadow(r, buf, &img);
    gate_damage_at_clip_edge(r, allocator, &img);
    free(img.p);
    free(ref.p);
    wlr_buffer_drop(buf);
}
