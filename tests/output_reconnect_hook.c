// Test-only hot-unplug and replug of headless outputs by connector name.
// The test writes lines "unplug NAME" or "replug NAME" to $REDIWM_TEST_HOTPLUG;
// the hook runs them in order and removes the file. A replugged output keeps
// its old name and size, as a monitor waking from sleep does.
#define _GNU_SOURCE
#define WLR_USE_UNSTABLE
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/backend/headless.h>
#include <wlr/types/wlr_output.h>

#define MAX_OUTPUTS 8

struct slot {
    char name[32];
    struct wlr_output *output;
    struct wl_listener destroy;
    int width, height;
};

static struct slot slots[MAX_OUTPUTS];
static struct wlr_backend *headless;
static struct wl_event_source *timer;
static const char *replug_name;

static void handle_destroy(struct wl_listener *listener, void *data) {
    (void)data;
    struct slot *slot = wl_container_of(listener, slot, destroy);
    slot->output = NULL;
    wl_list_remove(&slot->destroy.link);
}

static struct slot *find(const char *name) {
    for (int i = 0; i < MAX_OUTPUTS; i++) {
        if (slots[i].name[0] && strcmp(slots[i].name, name) == 0) return &slots[i];
    }
    return NULL;
}

static int poll_commands(void *data) {
    (void)data;
    const char *path = getenv("REDIWM_TEST_HOTPLUG");
    FILE *file = path ? fopen(path, "r") : NULL;
    if (file) {
        char line[128];
        while (fgets(line, sizeof line, file)) {
            char verb[16], name[32];
            if (sscanf(line, "%15s %31s", verb, name) != 2) continue;
            struct slot *slot = find(name);
            assert(slot);
            if (strcmp(verb, "unplug") == 0) {
                assert(slot->output);
                wlr_output_destroy(slot->output);
            } else if (strcmp(verb, "replug") == 0) {
                assert(!slot->output);
                replug_name = slot->name;
                struct wlr_output *output = wlr_headless_add_output(headless, slot->width, slot->height);
                replug_name = NULL;
                assert(output);
            }
        }
        fclose(file);
        unlink(path);
    }
    wl_event_source_timer_update(timer, 20);
    return 0;
}

// Runs when the backend names an output, before the compositor sees it.
void wlr_output_set_name(struct wlr_output *output, const char *name) {
    void (*set_name)(struct wlr_output *, const char *) = dlsym(RTLD_NEXT, "wlr_output_set_name");
    assert(set_name);
    const char *used = replug_name ? replug_name : name;
    set_name(output, used);
    if (!headless) {
        headless = output->backend;
        timer = wl_event_loop_add_timer(output->event_loop, poll_commands, NULL);
        assert(timer);
        wl_event_source_timer_update(timer, 20);
    }
    struct slot *slot = find(used);
    for (int i = 0; !slot && i < MAX_OUTPUTS; i++) {
        if (!slots[i].name[0]) slot = &slots[i];
    }
    assert(slot && !slot->output);
    if (used != slot->name) snprintf(slot->name, sizeof slot->name, "%s", used);
    slot->output = output;
    slot->width = output->width;
    slot->height = output->height;
    slot->destroy.notify = handle_destroy;
    wl_signal_add(&output->events.destroy, &slot->destroy);
}
