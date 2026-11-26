// Noninstalled fixture: use a real 10-bit headless swapchain so wlroots
// negotiates recorder buffers exactly as it would on a 10-bit DRM output.
#define _GNU_SOURCE
#define WLR_USE_UNSTABLE
#include <assert.h>
#include <dlfcn.h>
#include <drm_fourcc.h>
#include <wlr/backend/headless.h>
#include <wlr/types/wlr_output.h>

bool wlr_output_commit_state(struct wlr_output *out, const struct wlr_output_state *state) {
    static bool (*commit)(struct wlr_output *, const struct wlr_output_state *);
    if (!commit) commit = dlsym(RTLD_NEXT, "wlr_output_commit_state");
    assert(commit);
    if (wlr_output_is_headless(out) && (state->committed & WLR_OUTPUT_STATE_ENABLED) && state->enabled) {
        struct wlr_output_state deep = *state;
        wlr_output_state_set_render_format(&deep, DRM_FORMAT_XRGB2101010);
        return commit(out, &deep);
    }
    return commit(out, state);
}
