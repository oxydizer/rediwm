#pragma once
struct rediwm_scene_output;
struct pixman_region32;
// Damages a layout-space region on one output, for changes that
// move no view node (a clip's border colour).
void rediwm_scene_damage_layout(struct rediwm_scene_output *, const struct pixman_region32 *);
