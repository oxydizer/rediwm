// Analytic circular switcher clips: pixel coverage and the border use exactly
// the same circular arcs, including fractional scales and rotated sectors.
static void gate_sector_texture(struct rediwm_scene_renderer *r, struct wlr_buffer *buf,
                                struct image *img);
static void gate_sector(struct rediwm_scene_renderer *r, struct wlr_buffer *buf,
                        struct image *img) {
    const float ring[4] = {0.f, .8f, .9f, 1.f};
    const double pi = acos(-1.);
    int worst = 0;
    for (size_t scale = 0; scale < COUNT(SCALES); scale++) {
        const float s = SCALES[scale];
        for (int direction = 0; direction < 8; direction++) {
            const double angle = direction * pi / 4 + .13;
            struct rediwm_pass_shape shape = {
                .box = {20, 20, (int)ceilf(196 * s), (int)ceilf(196 * s)},
                .sector = {
                    .center = {98 * s + .3f, 98 * s + .7f},
                    .radii = {34.25f * s, 95.75f * s},
                    .axis = {(float)sin(angle), (float)-cos(angle)},
                    .half_angle = {(float)cos(pi / 5), (float)sin(pi / 5)},
                },
                .border = 2 * s,
            };
            memcpy(shape.border_color, ring, sizeof(ring));
            struct rediwm_sector reference;
            for (int i = 0; i < 2; i++) {
                reference.center[i] = shape.sector.center[i];
                reference.radii[i] = shape.sector.radii[i];
                reference.axis[i] = shape.sector.axis[i];
                reference.half_angle[i] = shape.sector.half_angle[i];
            }
            struct wlr_render_pass *pass = begin_fill(r, buf, BG, NULL);
            piece(pass, &shape, shape.box, BODY, NULL);
            finish(pass);
            read_image(r, buf, img);
            for (int y = 0; y < shape.box.height; y++) for (int x = 0; x < shape.box.width; x++) {
                const double distance = rediwm_sd_sector(x + .5, y + .5, &reference);
                const double coverage = rediwm_coverage(distance);
                const double border = 1 - rediwm_coverage(distance + shape.border);
                const uint8_t *pixel = at(img, shape.box.x + x, shape.box.y + y);
                for (int ch = 0; ch < 3; ch++) {
                    const double color = (BODY[ch] * (1 - border) + ring[ch] * border) * coverage + BG[ch] * (1 - coverage);
                    const int error = diff(pixel[ch], (int)lround(color * 255));
                    if (error > worst) worst = error;
                }
            }
        }
    }
    check(worst <= 2, "sector: GPU circular coverage/ring differs from analytic distance by %d levels", worst);

    // Invalid shape data fails the pass without leaving GL state poisoned.
    struct rediwm_pass_shape invalid = {.box = {20, 20, 100, 100},
        .sector = {.center = {50, 50}, .radii = {40, 20}, .axis = {0, -1}, .half_angle = {.8, .6}}};
    struct wlr_render_pass *pass = begin_fill(r, buf, BG, NULL);
    piece(pass, &invalid, invalid.box, BODY, NULL);
    check(!wlr_render_pass_submit(pass), "sector: inverted radii did not fail the pass");
    pass = begin_fill(r, buf, BG, NULL);
    finish(pass);
    printf("PASS: circular sectors and borders match analytic coverage within %d levels at fractional scales and eight orientations\n", worst);
    gate_sector_texture(r, buf, img);
}

// The source gradient makes both crop offsets and orientation observable:
// red is the column, green the row. A polar window must preserve its entire
// top row while consuming only the first part of a tall source's height.
static void gate_sector_texture(struct rediwm_scene_renderer *r, struct wlr_buffer *buf,
                                struct image *img) {
    enum { SIDE = 128 };
    uint32_t pixels[SIDE * SIDE];
    for (int y = 0; y < SIDE; y++) for (int x = 0; x < SIDE; x++)
        pixels[y * SIDE + x] = 0xff000020u | (uint32_t)(2 * x) << 16 | (uint32_t)(2 * y) << 8;
    struct wlr_texture *texture = wlr_texture_from_pixels(r->renderer,
        DRM_FORMAT_ARGB8888, SIDE * 4, SIDE, SIDE, pixels);
    check(texture != NULL, "sector texture creation failed");
    const enum wl_output_transform source_transforms[] = {
        WL_OUTPUT_TRANSFORM_NORMAL, WL_OUTPUT_TRANSFORM_90, WL_OUTPUT_TRANSFORM_FLIPPED,
    };
    const double half = .7;
    int worst = 0;
    for (int scale = 0; scale < 2; scale++) {
        const float s = scale ? 1.5f : 1.f;
        for (int output = 0; output < 8; output++) {
            struct wlr_box probe[3], positions[3] = {{0, 0, 1, 1}, {1, 0, 1, 1}, {0, 1, 1, 1}};
            for (int i = 0; i < 3; i++) wlr_box_transform(&probe[i], &positions[i],
                wlr_output_transform_invert(output), 3, 5);
            const double ex[2] = {probe[1].x - probe[0].x, probe[1].y - probe[0].y};
            const double ey[2] = {probe[2].x - probe[0].x, probe[2].y - probe[0].y};
            struct rediwm_pass_shape shape = {
                .box = {20, 20, (int)ceilf(240 * s), (int)ceilf(240 * s)},
                .sector = {
                    .center = {120 * s + .3f, 120 * s + .7f},
                    .radii = {30 * s, 110 * s},
                    .axis = {(float)(ex[0] * sin(.31) - ey[0] * cos(.31)),
                             (float)(ex[1] * sin(.31) - ey[1] * cos(.31))},
                    .half_angle = {(float)cos(half), (float)sin(half)},
                },
                .sector_texture_height = 160 * s,
                .sector_texture_flip = output >= WL_OUTPUT_TRANSFORM_FLIPPED ? -1 : 1,
                .sector_texture_transform = output,
            };
            for (size_t tr = 0; tr < COUNT(source_transforms); tr++) {
                const enum wl_output_transform source = source_transforms[tr];
                struct wlr_render_pass *pass = begin_fill(r, buf, BG, NULL);
                rediwm_scene_pass_add_texture_shaped(pass, &(struct wlr_render_texture_options){
                    .texture = texture, .dst_box = shape.box,
                    .src_box = {16, 24, 96, 80}, .filter_mode = WLR_SCALE_FILTER_BILINEAR,
                    .transform = wlr_output_transform_compose(source, output),
                }, &shape);
                finish(pass);
                read_image(r, buf, img);
                for (int across = -3; across <= 3; across++) for (int row = 0; row < 3; row++) {
                    const double theta = across * .18, radius = (106 - row * 30) * s;
                    const double ax = shape.sector.axis[0], ay = shape.sector.axis[1];
                    const double tx = -ay * shape.sector_texture_flip, ty = ax * shape.sector_texture_flip;
                    const int x = (int)floor(shape.box.x + shape.sector.center[0] + radius * (ax * cos(theta) + tx * sin(theta)));
                    const int y = (int)floor(shape.box.y + shape.sector.center[1] + radius * (ay * cos(theta) + ty * sin(theta)));
                    const double dx = x + .5 - shape.box.x - shape.sector.center[0];
                    const double dy = y + .5 - shape.box.y - shape.sector.center[1];
                    const double u = .5 + atan2(dx * tx + dy * ty, dx * ax + dy * ay) / (2 * half);
                    const double v = (shape.sector.radii[1] - hypot(dx, dy)) / shape.sector_texture_height;
                    // Known source orientation, independent of output rotation.
                    const double su = source == WL_OUTPUT_TRANSFORM_90 ? 1 - v :
                        source == WL_OUTPUT_TRANSFORM_FLIPPED ? 1 - u : u;
                    const double sv = source == WL_OUTPUT_TRANSFORM_90 ? u : v;
                    const uint8_t *pixel = at(img, x, y);
                    const int red = (int)lround(2 * (16 + 96 * su - .5));
                    const int green = (int)lround(2 * (24 + 80 * sv - .5));
                    const int error = diff(pixel[0], red) > diff(pixel[1], green) ? diff(pixel[0], red) : diff(pixel[1], green);
                    if (error > worst) worst = error;
                }
            }
        }
    }
    check(worst <= 2, "sector top framing/source crop/transform differs by %d levels", worst);

    // A short source ends naturally, with no stretched last row below it.
    const struct rediwm_pass_shape short_source = {
        .box = {20, 20, 240, 240},
        .sector = {.center = {120, 120}, .radii = {30, 110}, .axis = {0, -1},
                   .half_angle = {(float)cos(half), (float)sin(half)}},
        .sector_texture_height = 20, .sector_texture_flip = 1,
    };
    struct wlr_render_pass *pass = begin_fill(r, buf, BG, NULL);
    rediwm_scene_pass_add_texture_shaped(pass, &(struct wlr_render_texture_options){
        .texture = texture, .dst_box = short_source.box,
    }, &short_source);
    finish(pass);
    read_image(r, buf, img);
    const uint8_t *empty = at(img, 140, 90);
    for (int ch = 0; ch < 3; ch++)
        check(diff(empty[ch], (int)lround(BG[ch] * 255)) <= 1, "sector short source smeared its bottom row");
    wlr_texture_destroy(texture);
    printf("PASS: sector previews retain top rows, crop only the bottom and preserve source/output transforms (max diff %d)\n", worst);
}
