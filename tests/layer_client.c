// Minimal wlr-layer-shell client: one full-output background surface with a
// solid shm buffer, kept mapped until the process is killed.
#define _GNU_SOURCE
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "wlr-layer-shell-unstable-v1-client-protocol.h"

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct zwlr_layer_shell_v1 *layer_shell;
static struct wl_surface *surface;
static struct wl_output *first_output;
static int panel_version;

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data;
    if (!strcmp(interface, wl_compositor_interface.name))
        compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
    else if (!strcmp(interface, wl_shm_interface.name))
        shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    else if (!strcmp(interface, wl_output_interface.name) && !first_output)
        first_output = wl_registry_bind(registry, name, &wl_output_interface, 1);
    else if (!strcmp(interface, zwlr_layer_shell_v1_interface.name)) {
        uint32_t wanted = panel_version ? (uint32_t)panel_version : 4;
        if (version >= wanted)
            layer_shell = wl_registry_bind(registry, name, &zwlr_layer_shell_v1_interface, wanted);
    }
}
static void global_remove(void *data, struct wl_registry *registry, uint32_t name) { (void)data; (void)registry; (void)name; }
static const struct wl_registry_listener registry_listener = {global, global_remove};

static struct wl_buffer *solid_buffer(int width, int height) {
    int stride = width * 4, size = stride * height;
    int fd = memfd_create("layer-client", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, size) != 0) exit(1);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) exit(1);
    for (int i = 0; i < width * height; i++) pixels[i] = 0xff203040;
    munmap(pixels, size);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return buffer;
}

static void configure(void *data, struct zwlr_layer_surface_v1 *layer, uint32_t serial, uint32_t width, uint32_t height) {
    (void)data;
    zwlr_layer_surface_v1_ack_configure(layer, serial);
    struct wl_buffer *buffer = solid_buffer(width ? (int)width : 64, height ? (int)height : 64);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_commit(surface);
    wl_buffer_destroy(buffer);
}
static void closed(void *data, struct zwlr_layer_surface_v1 *layer) { (void)data; (void)layer; exit(0); }
static const struct zwlr_layer_surface_v1_listener layer_listener = {configure, closed};

static void set_panel(struct zwlr_layer_surface_v1 *layer, uint32_t edge) {
    uint32_t anchors = ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT;
    if (panel_version == 4) anchors |= ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
    zwlr_layer_surface_v1_set_anchor(layer, anchors);
    zwlr_layer_surface_v1_set_size(layer, 60, 40);
    zwlr_layer_surface_v1_set_exclusive_zone(layer, 40);
    zwlr_layer_surface_v1_set_margin(layer, 3, 0, 0, 5);
    if (panel_version == 5) zwlr_layer_surface_v1_set_exclusive_edge(layer, edge);
    wl_surface_commit(surface);
}

static void run_panel(struct wl_display *display, struct zwlr_layer_surface_v1 *layer) {
    set_panel(layer, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP);
    struct pollfd fds[] = {{wl_display_get_fd(display), POLLIN, 0}, {STDIN_FILENO, POLLIN, 0}};
    while (wl_display_dispatch_pending(display) >= 0 && wl_display_flush(display) >= 0 && poll(fds, 2, -1) >= 0) {
        if (fds[0].revents && wl_display_dispatch(display) < 0) break;
        if (fds[1].revents) {
            char line[32];
            if (!fgets(line, sizeof(line), stdin)) break;
            if (!strcmp(line, "unmap\n")) {
                wl_surface_attach(surface, NULL, 0, 0);
                wl_surface_commit(surface);
            } else if (!strcmp(line, "top\n")) set_panel(layer, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP);
            else if (!strcmp(line, "left\n")) set_panel(layer, ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
            else exit(1);
        }
    }
}

int main(int argc, char **argv) {
    if (argc > 1) panel_version = atoi(argv[1]);
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return 1;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);
    if (!compositor || !shm || !layer_shell) return 1;
    surface = wl_compositor_create_surface(compositor);
    struct zwlr_layer_surface_v1 *layer = zwlr_layer_shell_v1_get_layer_surface(
        layer_shell, surface, panel_version ? first_output : NULL,
        panel_version ? ZWLR_LAYER_SHELL_V1_LAYER_TOP : ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
        "rediwm-test-layer");
    zwlr_layer_surface_v1_add_listener(layer, &layer_listener, NULL);
    if (panel_version) {
        run_panel(display, layer);
        wl_display_disconnect(display);
        return 0;
    }
    zwlr_layer_surface_v1_set_anchor(layer, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
        ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    zwlr_layer_surface_v1_set_exclusive_zone(layer, -1);
    wl_surface_commit(surface);
    while (wl_display_dispatch(display) != -1) {}
    return 0;
}
