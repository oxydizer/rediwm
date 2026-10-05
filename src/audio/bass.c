/* Client-owned filter-chain. WirePlumber's smart-filter policy follows the
 * default output without rewriting the user's default device or stream targets.
 * All graph changes and debounced state writes run on the PipeWire loop. The
 * DSP is bass_dsp.c, a LADSPA plugin installed in lib/rediwm/ladspa next to
 * the binaries. */
#define _POSIX_C_SOURCE 200809L
#include "bass.h"
#include <pipewire/pipewire.h>
#include <pipewire/impl-module.h>
#include <pipewire/extensions/metadata.h>
#include <spa/param/props.h>
#include <spa/pod/builder.h>
#include <errno.h>
#include <stdatomic.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

struct rediwm_bass {
    struct pw_thread_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_registry *registry;
    struct pw_impl_module *module;
    struct pw_node *node;
    struct pw_metadata *filters;
    struct spa_hook registry_listener, core_listener, module_listener, node_listener;
    struct spa_source *save_timer, *mute_event;
    uint32_t node_id, metadata_id;
    enum pw_node_state node_state;
    char name[80], state_path[4096], plugin[4096];
    float gain, treble;
    bool started, failed, dirty, save_failed;
    /* Written from any thread by rediwm_bass_set_mute; `live` mirrors
     * node && filters && !failed for it. */
    atomic_bool muted, live;
    void (*notify)(void *);
    void *data;
};

static void changed(struct rediwm_bass *b) {
    atomic_store(&b->live, b->node && b->filters && !b->failed);
    if (b->notify) b->notify(b->data);
}

static void save_state(struct rediwm_bass *b) {
    if (!b->dirty) return;
    char path[sizeof(b->state_path)], tmp[sizeof(b->state_path) + 40];
    bool ok = b->state_path[0] != '\0';
    snprintf(path, sizeof(path), "%s", b->state_path);
    for (char *p = path + 1; ok && *p; ++p) {
        if (*p != '/') continue;
        *p = '\0';
        if (mkdir(path, 0700) < 0 && errno != EEXIST) ok = false;
        *p = '/';
    }
    snprintf(tmp, sizeof(tmp), "%s.tmp.%ld", path, (long)getpid());
    FILE *f = ok ? fopen(tmp, "w") : NULL;
    if (f) {
        ok = fprintf(f, "%.1f\n%.1f\n", (double)b->gain, (double)b->treble) > 0;
        if (fclose(f) != 0) ok = false;
        if (ok) ok = rename(tmp, path) == 0;
        if (!ok) unlink(tmp);
    } else ok = false;
    b->dirty = !ok;
    if (b->save_failed != !ok) {
        b->save_failed = !ok;
        changed(b);
    }
}

static void save_timer(void *data, uint64_t expirations) {
    (void)expirations;
    save_state(data);
}


static int apply(struct rediwm_bass *b) {
    if (!b->node || !b->filters || b->failed) return -ENOTCONN;
    uint8_t buffer[512];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    struct spa_pod_frame object, params;
    spa_pod_builder_push_object(&builder, &object, SPA_TYPE_OBJECT_Props, SPA_PARAM_Props);
    spa_pod_builder_prop(&builder, SPA_PROP_params, 0);
    spa_pod_builder_push_struct(&builder, &params);
    spa_pod_builder_string(&builder, "bass:Amount");
    spa_pod_builder_float(&builder, b->gain);
    spa_pod_builder_string(&builder, "bass:Treble");
    spa_pod_builder_float(&builder, b->treble);
    spa_pod_builder_string(&builder, "bass:Mute");
    spa_pod_builder_float(&builder, atomic_load(&b->muted) ? 1.0f : 0.0f);
    spa_pod_builder_pop(&builder, &params);
    const struct spa_pod *pod = spa_pod_builder_pop(&builder, &object);
    return pw_node_set_param(b->node, SPA_PARAM_Props, 0, pod);
}

static void mute_event(void *data, uint64_t count) {
    (void)count;
    struct rediwm_bass *b = data;
    /* A node that appears later picks the state up in global(). */
    if (b->node && b->filters && !b->failed) apply(b);
}

static void node_info(void *data, const struct pw_node_info *info) {
    struct rediwm_bass *b = data;
    if (!(info->change_mask & PW_NODE_CHANGE_MASK_STATE) || b->node_state == info->state) return;
    b->node_state = info->state;
    /* Suspended adapters can silently discard Props before configuring their
     * follower. Restore the desired controls once the graph is configured. */
    if (info->state == PW_NODE_STATE_IDLE || info->state == PW_NODE_STATE_RUNNING) {
        if (apply(b) < 0) { b->failed = true; changed(b); }
    }
}
static const struct pw_node_events node_events = { PW_VERSION_NODE_EVENTS, .info = node_info };

static void module_destroy(void *data) {
    struct rediwm_bass *b = data;
    spa_hook_remove(&b->module_listener);
    b->module = NULL;
    b->failed = true;
    changed(b);
}
static const struct pw_impl_module_events module_events = {
    PW_VERSION_IMPL_MODULE_EVENTS, .destroy = module_destroy,
};

static void load_filter(struct rediwm_bass *b) {
    if (b->module || b->failed) return;
    char args[sizeof(b->plugin) + 1024];
    int n = snprintf(args, sizeof(args),
        "node.description = \"Bass and Treble\" "
        "audio.channels = 2 audio.position = [ FL FR ] "
        "filter.graph = { nodes = [ "
        "{ type = ladspa name = bass plugin = \"%s\" label = rediwm_bass "
        "control = { Amount = %.1f Treble = %.1f Mute = %.1f } } ] "
        "inputs = [ \"bass:InL\" \"bass:InR\" ] outputs = [ \"bass:OutL\" \"bass:OutR\" ] } "
        "capture.props = { node.name = %s media.class = Audio/Sink "
        "filter.smart = true filter.smart.name = %s filter.smart.disabled = false "
        "priority.session = 0 node.virtual = true } "
        "playback.props = { node.name = %s.output node.passive = true application.id = rediwm.bass }",
        b->plugin, (double)b->gain, (double)b->treble, atomic_load(&b->muted) ? 1.0 : 0.0, b->name, b->name, b->name);
    if (!b->plugin[0] || n < 0 || n >= (int)sizeof(args)) {
        b->failed = true;
        changed(b);
        return;
    }
    b->module = pw_context_load_module(b->context, "libpipewire-module-filter-chain", args, NULL);
    if (b->module) pw_impl_module_add_listener(b->module, &b->module_listener, &module_events, b);
    else { b->failed = true; changed(b); }
}

static void global(void *data, uint32_t id, uint32_t permissions,
                   const char *type, uint32_t version, const struct spa_dict *props) {
    (void)permissions; (void)version;
    struct rediwm_bass *b = data;
    if (!props) return;
    const char *name;
    if (strcmp(type, PW_TYPE_INTERFACE_Metadata) == 0 && !b->filters &&
        (name = spa_dict_lookup(props, PW_KEY_METADATA_NAME)) && strcmp(name, "filters") == 0) {
        b->filters = pw_registry_bind(b->registry, id, type, PW_VERSION_METADATA, 0);
        b->metadata_id = id;
        if (b->filters) load_filter(b);
    } else if (strcmp(type, PW_TYPE_INTERFACE_Node) == 0 && !b->node &&
               (name = spa_dict_lookup(props, PW_KEY_NODE_NAME)) && strcmp(name, b->name) == 0) {
        b->node = pw_registry_bind(b->registry, id, type, PW_VERSION_NODE, 0);
        b->node_id = id;
        b->node_state = PW_NODE_STATE_CREATING;
        if (b->node) pw_node_add_listener(b->node, &b->node_listener, &node_events, b);
        if (apply(b) < 0) b->failed = true;
        changed(b);
    }
}

static void global_remove(void *data, uint32_t id) {
    struct rediwm_bass *b = data;
    if (b->node && id == b->node_id) {
        spa_hook_remove(&b->node_listener);
        pw_proxy_destroy((struct pw_proxy *)b->node);
        b->node = NULL;
        changed(b);
    }
    if (b->filters && id == b->metadata_id) {
        pw_proxy_destroy((struct pw_proxy *)b->filters);
        b->filters = NULL;
        if (b->module) pw_impl_module_destroy(b->module);
        /* Allow the policy manager to reappear after a restart. */
        b->failed = false;
        changed(b);
    }
}
static const struct pw_registry_events registry_events = {
    PW_VERSION_REGISTRY_EVENTS, .global = global, .global_remove = global_remove,
};

static void core_error(void *data, uint32_t id, int seq, int res, const char *message) {
    (void)seq;
    struct rediwm_bass *b = data;
    fprintf(stderr, "bass boost: PipeWire error: %s (%d)\n", message, res);
    if (id == PW_ID_CORE || (b->node && id == pw_proxy_get_id((struct pw_proxy *)b->node))) {
        b->failed = true;
        if (b->module) pw_impl_module_destroy(b->module);
        changed(b);
    }
}
static const struct pw_core_events core_events = { PW_VERSION_CORE_EVENTS, .error = core_error };

/* The DSP plugin is installed in lib/rediwm/ladspa beside bin/. */
static void find_plugin(struct rediwm_bass *b) {
    char exe[sizeof(b->plugin)];
    ssize_t len = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    char *slash = NULL;
    if (len > 0) {
        exe[len] = '\0';
        slash = strrchr(exe, '/');
    }
    int n = slash ? snprintf(b->plugin, sizeof(b->plugin), "%.*s/../lib/rediwm/ladspa/rediwm-bass.so",
        (int)(slash - exe), exe) : -1;
    /* A quote or backslash would need escaping in the filter-chain arguments. */
    if (n < 0 || n >= (int)sizeof(b->plugin) || strpbrk(b->plugin, "\"\\") || access(b->plugin, R_OK) != 0) {
        fprintf(stderr, "bass boost: DSP plugin missing (%s)\n", n > 0 ? b->plugin : "no executable path");
        b->plugin[0] = '\0';
    }
}

struct rediwm_bass *rediwm_bass_create(void (*notify)(void *), void *data) {
    struct rediwm_bass *b = calloc(1, sizeof(*b));
    if (!b) return NULL;
    b->notify = notify;
    b->data = data;
    snprintf(b->name, sizeof(b->name), "rediwm.bass.%ld", (long)getpid());
    const char *state = getenv("XDG_STATE_HOME"), *home = getenv("HOME");
    int n = 0;
    if (state && state[0] == '/') n = snprintf(b->state_path, sizeof(b->state_path), "%s/rediwm/bass-boost", state);
    else if (home && home[0] == '/') n = snprintf(b->state_path, sizeof(b->state_path), "%s/.local/state/rediwm/bass-boost", home);
    if (n < 0 || n >= (int)sizeof(b->state_path)) b->state_path[0] = '\0';
    FILE *f = fopen(b->state_path, "r");
    if (f) {
        /* Bass, then treble (absent in files saved before treble existed). */
        float gain, treble;
        if (fscanf(f, "%f", &gain) == 1 && isfinite(gain) && gain >= 0 && gain <= 12) b->gain = gain;
        if (fscanf(f, "%f", &treble) == 1 && isfinite(treble) && treble >= -6 && treble <= 6) b->treble = treble;
        fclose(f);
    }
    find_plugin(b);
    pw_init(NULL, NULL);
    b->loop = pw_thread_loop_new("rediwm-bass", NULL);
    if (!b->loop) goto fail;
    b->context = pw_context_new(pw_thread_loop_get_loop(b->loop), NULL, 0);
    if (!b->context) goto fail;
    b->core = pw_context_connect(b->context, NULL, 0);
    if (!b->core) goto fail;
    /* Let filter-chain open its own core connection. Controlling an exported
     * node through its owning connection deadlocks the server's set-param
     * busy/ping handshake (the acknowledgement queues behind the command). */
    pw_core_add_listener(b->core, &b->core_listener, &core_events, b);
    b->registry = pw_core_get_registry(b->core, PW_VERSION_REGISTRY, 0);
    if (!b->registry) goto fail;
    pw_registry_add_listener(b->registry, &b->registry_listener, &registry_events, b);
    b->save_timer = pw_loop_add_timer(pw_thread_loop_get_loop(b->loop), save_timer, b);
    b->mute_event = pw_loop_add_event(pw_thread_loop_get_loop(b->loop), mute_event, b);
    if (!b->save_timer || !b->mute_event || pw_thread_loop_start(b->loop) < 0) goto fail;
    b->started = true;
    return b;
fail:
    rediwm_bass_destroy(b);
    return NULL;
}

void rediwm_bass_destroy(struct rediwm_bass *b) {
    if (!b) return;
    if (b->started) pw_thread_loop_stop(b->loop);
    b->notify = NULL;
    save_state(b);
    if (b->save_timer) pw_loop_destroy_source(pw_thread_loop_get_loop(b->loop), b->save_timer);
    if (b->mute_event) pw_loop_destroy_source(pw_thread_loop_get_loop(b->loop), b->mute_event);
    if (b->module) pw_impl_module_destroy(b->module);
    if (b->node) pw_proxy_destroy((struct pw_proxy *)b->node);
    if (b->filters) pw_proxy_destroy((struct pw_proxy *)b->filters);
    if (b->registry) pw_proxy_destroy((struct pw_proxy *)b->registry);
    if (b->core) pw_core_disconnect(b->core);
    if (b->context) pw_context_destroy(b->context);
    if (b->loop) pw_thread_loop_destroy(b->loop);
    free(b);
}

int rediwm_bass_get(struct rediwm_bass *b, float *gain, float *treble) {
    *gain = *treble = 0;
    if (!b) return 0;
    pw_thread_loop_lock(b->loop);
    *gain = b->gain;
    *treble = b->treble;
    int status = b->node && b->filters && !b->failed ? (b->save_failed ? 2 : 1) : 0;
    pw_thread_loop_unlock(b->loop);
    return status;
}

/* Rounds to 0.5 dB steps and saves the value once it applies. */
static bool set_control(struct rediwm_bass *b, float *control, float value, float lo, float hi) {
    if (!isfinite(value)) return false;
    pw_thread_loop_lock(b->loop);
    bool ok = b->node && b->filters && !b->failed;
    if (ok) {
        float old = *control;
        /* + 0 turns a rounded -0 into 0. */
        *control = roundf(fminf(hi, fmaxf(lo, value)) * 2) / 2 + 0.0f;
        ok = apply(b) >= 0;
        if (!ok) *control = old;
        else {
            b->dirty = true;
            struct timespec delay = { .tv_nsec = 300000000 };
            pw_loop_update_timer(pw_thread_loop_get_loop(b->loop), b->save_timer, &delay, NULL, false);
        }
    }
    pw_thread_loop_unlock(b->loop);
    return ok;
}

bool rediwm_bass_set(struct rediwm_bass *b, float gain) {
    return b && set_control(b, &b->gain, gain, 0, 12);
}

bool rediwm_bass_set_treble(struct rediwm_bass *b, float treble) {
    return b && set_control(b, &b->treble, treble, -6, 6);
}

/* Never takes the loop lock: pipewire.zig calls this under the PulseAudio
 * lock, which loop callbacks take through `notify`. */
bool rediwm_bass_set_mute(struct rediwm_bass *b, bool muted) {
    if (!b) return false;
    if (atomic_exchange(&b->muted, muted) != muted) pw_loop_signal_event(pw_thread_loop_get_loop(b->loop), b->mute_event);
    return atomic_load(&b->live);
}
