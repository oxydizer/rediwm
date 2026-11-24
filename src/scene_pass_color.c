// Source colour state is scoped to a single surface, including its uniform
// single-pixel representation. Borders, shadows and shell colours stay SDR.
#include "scene_pass_internal.h"
#include "node.h"
#include <stdio.h>

void rediwm_scene_pass_set_source(struct wlr_render_pass *base, const struct rediwm_buffer *b) {
    struct pass *p = owned_pass(base);
    p->convert = b && ((b->transfer_function && b->transfer_function != WLR_COLOR_TRANSFER_FUNCTION_GAMMA22) ||
        b->primaries == WLR_COLOR_NAMED_PRIMARIES_BT2020);
    p->source = p->convert || (b && b->color_encoding > WLR_COLOR_ENCODING_IDENTITY) ? b : NULL;
}

void rediwm_scene_pass_set_destination(struct wlr_render_pass *base, const struct rediwm_pass_encode *encode) {
    struct pass *p = owned_pass(base);
    p->hdr = encode && encode->pq && p->linear;
    p->sdr_white = encode && encode->sdr_white > 0 ? encode->sdr_white : 203.f;
}

struct program *scene_pass_color_program(struct pass *p, const struct rediwm_pass_shape *shape, bool external) {
    struct program *base = shaped_for(p->renderer, shape, external, p->linear != NULL);
    if (!p->convert || !base->id) return base;
    const bool poly = shape && (shape->poly_count || shape->sector.radii[1] > 0);
    const unsigned i = (p->linear ? 4 : 0) + (poly ? 2 : 0) + external;
    struct program *g = &p->renderer->client[i];
    if (!g->bit) {
        char prefix[256];
        snprintf(prefix, sizeof(prefix), "%s#define CLIENT_COLOR 1\n%s%suniform highp %s tex;\n",
            external ? "#extension GL_OES_EGL_image_external : require\n" : "",
            poly ? "#define POLY 1\n" : "", p->linear ? "#define LINEAR 1\n" : "",
            external ? "samplerExternalOES" : "sampler2D");
        scene_pass_program_init(g, 1u << (15 + i), scene_pass_shaped_vertex, prefix, scene_pass_shaped_fragment);
    }
    return g;
}

void scene_pass_color_uniform(const struct pass *p, const struct program *g) {
    if (!p->convert) return;
    glUniform4f(g->source_color, p->source->transfer_function,
        p->source->primaries == WLR_COLOR_NAMED_PRIMARIES_BT2020, 10000.f / p->sdr_white, !p->hdr);
}
