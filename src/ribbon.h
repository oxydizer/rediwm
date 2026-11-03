// A reusable, input-transparent ribbon mesh. Positions are normalized to the
// node's box; z is signed distance across the ribbon, w its time coordinate
// (tail 0, head 1, end of soft cap 2), or the opacity of a border halo.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#define REDIWM_RIBBON_VERTICES 128
struct rediwm_node;
struct rediwm_tree;
struct rediwm_ribbon {
    uint32_t count;
    float vertices[REDIWM_RIBBON_VERTICES][4];
    float color[4], core_color[4]; // straight RGBA, premultiplied by the shader
    uint32_t edge; // 0: folded trail, 1: border halo, 2: textured minimize, 3: resize sheet, 4: drag sheet
    float fade[2]; // opacity at the oldest/newest sample, separate from geometry
};
struct rediwm_buffer *rediwm_ribbon_create(struct rediwm_tree *parent);
const struct rediwm_ribbon *rediwm_ribbon_get(struct rediwm_node *node);
void rediwm_ribbon_update(struct rediwm_buffer *node, const struct rediwm_ribbon *mesh,
    int x, int y, int width, int height);
