// Test-only gamma hook for rediwm night light integration tests.
#define _GNU_SOURCE
#define WLR_USE_UNSTABLE
#include <assert.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wlr/types/wlr_output.h>
#include <wlr/render/color.h>

size_t wlr_output_get_gamma_size(struct wlr_output *output) {
    (void)output;
    return 256;
}

bool wlr_output_test_state(struct wlr_output *output, const struct wlr_output_state *state) {
    bool (*real_test)(struct wlr_output *, const struct wlr_output_state *) =
        dlsym(RTLD_NEXT, "wlr_output_test_state");
    assert(real_test);

    const char *mode = getenv("REDIWM_GAMMA_MODE");
    bool reject_mode = mode && strcmp(mode, "reject") == 0;

    bool has_transform = (state->committed & WLR_OUTPUT_STATE_COLOR_TRANSFORM) != 0;
    bool is_non_null = has_transform && state->color_transform != NULL;

    const char *samples_path = getenv("REDIWM_GAMMA_SAMPLES");
    if (samples_path && has_transform) {
        FILE *f = fopen(samples_path, "a");
        if (f) {
            fprintf(f, "{\"event\":\"test\",\"output\":\"%s\",\"has_transform\":%s}\n",
                    output->name ? output->name : "?",
                    is_non_null ? "true" : "false");
            fclose(f);
        }
    }

    if (reject_mode && is_non_null) {
        return false;
    }

    if (has_transform) {
        struct wlr_output_state copy = *state;
        copy.committed &= ~WLR_OUTPUT_STATE_COLOR_TRANSFORM;
        copy.color_transform = NULL;
        return real_test(output, &copy);
    }
    return real_test(output, state);
}

bool wlr_output_commit_state(struct wlr_output *output, const struct wlr_output_state *state) {
    bool (*real_commit)(struct wlr_output *, const struct wlr_output_state *) =
        dlsym(RTLD_NEXT, "wlr_output_commit_state");
    assert(real_commit);

    const char *mode = getenv("REDIWM_GAMMA_MODE");
    bool reject_mode = mode && strcmp(mode, "reject") == 0;

    bool has_transform = (state->committed & WLR_OUTPUT_STATE_COLOR_TRANSFORM) != 0;
    bool is_non_null = has_transform && state->color_transform != NULL;

    const char *samples_path = getenv("REDIWM_GAMMA_SAMPLES");
    if (samples_path && has_transform) {
        FILE *f = fopen(samples_path, "a");
        if (f) {
            if (is_non_null) {
                float in0[3] = {0.0f, 0.0f, 0.0f}, out0[3];
                float in_half[3] = {0.5f, 0.5f, 0.5f}, out_half[3];
                float in1[3] = {1.0f, 1.0f, 1.0f}, out1[3];
                wlr_color_transform_eval(state->color_transform, out0, in0);
                wlr_color_transform_eval(state->color_transform, out_half, in_half);
                wlr_color_transform_eval(state->color_transform, out1, in1);
                fprintf(f, "{\"event\":\"commit\",\"output\":\"%s\",\"has_transform\":true,\"sample_0\":[%.5f,%.5f,%.5f],\"sample_half\":[%.5f,%.5f,%.5f],\"sample_1\":[%.5f,%.5f,%.5f]}\n",
                        output->name ? output->name : "?",
                        out0[0], out0[1], out0[2],
                        out_half[0], out_half[1], out_half[2],
                        out1[0], out1[1], out1[2]);
            } else {
                fprintf(f, "{\"event\":\"commit\",\"output\":\"%s\",\"has_transform\":false}\n",
                        output->name ? output->name : "?");
            }
            fclose(f);
        }
    }

    if (reject_mode && is_non_null) {
        return false;
    }

    if (has_transform) {
        struct wlr_output_state copy = *state;
        copy.committed &= ~WLR_OUTPUT_STATE_COLOR_TRANSFORM;
        copy.color_transform = NULL;
        return real_commit(output, &copy);
    }
    return real_commit(output, state);
}
