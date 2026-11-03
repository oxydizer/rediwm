#include "scene_output_internal.h"
#include "ribbon.h"

void scene_output_render_ribbon(struct entry *e, struct wlr_render_pass *pass,
        const struct output_view *v, struct wlr_box dst, const pixman_region32_t *clip) {
    struct rediwm_ribbon mesh = *e->item.ribbon;
    // The same affine corner transform as shapes, preserving subpixel vertices.
    enum { W = 3, H = 5 };
    struct wlr_box px[3], at[3] = {{0, 0, 1, 1}, {1, 0, 1, 1}, {0, 1, 1, 1}};
    for (int i = 0; i < 3; i++) wlr_box_transform(&px[i], &at[i], wlr_output_transform_invert(v->transform), W, H);
    const int ex[2] = {px[1].x - px[0].x, px[1].y - px[0].y};
    const int ey[2] = {px[2].x - px[0].x, px[2].y - px[0].y};
    const float w = (v->transform & 1) ? dst.height : dst.width;
    const float h = (v->transform & 1) ? dst.width : dst.height;
    for (uint32_t j = 0; j < mesh.count; j++) {
        const float x = mesh.vertices[j][0] * w, y = mesh.vertices[j][1] * h;
        for (int i = 0; i < 2; i++)
            mesh.vertices[j][i] = ex[i] * x + ey[i] * y + (ex[i] < 0 ? w : 0) + (ey[i] < 0 ? h : 0);
    }
    struct rediwm_buffer *buffer = rediwm_buffer_from_node(e->transport);
    rediwm_scene_pass_add_ribbon(pass, dst, &mesh, clip, e->item.content.opacity,
        mesh.edge == 2 ? buffer->texture : NULL);
}
