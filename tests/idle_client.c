// Test fixture for ext-idle-notify-v1 and idle-inhibit-unstable-v1
#define _GNU_SOURCE
#include "ext-idle-notify-v1-client-protocol.h"
#include "idle-inhibit-unstable-v1-client-protocol.h"
#include "xdg-shell-client-protocol.h"
#include <assert.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct xdg_wm_base *wm;
static struct ext_idle_notifier_v1 *idle_notifier;
static struct zwp_idle_inhibit_manager_v1 *idle_inhibit_manager;

static struct wl_surface *surface;
static struct xdg_surface *xdg_surface;
static struct xdg_toplevel *toplevel;
static struct zwp_idle_inhibitor_v1 *inhibitor;
static struct ext_idle_notification_v1 *notification;

static bool configured;

static void buffer_release(void *data, struct wl_buffer *buffer) {
  (void)data;
  wl_buffer_destroy(buffer);
}
static const struct wl_buffer_listener buffer_listener = {buffer_release};

static void paint(void) {
  const int width = 320, height = 240, stride = width * 4;
  const size_t size = (size_t)stride * height;
  int fd = memfd_create("idle-fixture", MFD_CLOEXEC);
  assert(fd >= 0 && ftruncate(fd, (off_t)size) == 0);
  uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  assert(pixels != MAP_FAILED);
  for (size_t i = 0; i < size / 4; i++) pixels[i] = 0xff336699;
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int32_t)size);
  struct wl_buffer *buffer = wl_shm_pool_create_buffer(
      pool, 0, width, height, stride, WL_SHM_FORMAT_ARGB8888);
  wl_buffer_add_listener(buffer, &buffer_listener, NULL);
  wl_surface_attach(surface, buffer, 0, 0);
  wl_surface_damage_buffer(surface, 0, 0, width, height);
  wl_shm_pool_destroy(pool);
  munmap(pixels, size);
  close(fd);
}

static void xdg_surface_configure(void *data, struct xdg_surface *xs, uint32_t serial) {
  (void)data;
  xdg_surface_ack_configure(xs, serial);
  if (!configured) {
    paint();
    wl_surface_commit(surface);
    configured = true;
  }
}
static const struct xdg_surface_listener xdg_surface_listener = {xdg_surface_configure};

static void xdg_toplevel_configure(void *data, struct xdg_toplevel *tl,
                                   int32_t width, int32_t height, struct wl_array *states) {
  (void)data; (void)tl; (void)width; (void)height; (void)states;
}
static void xdg_toplevel_close(void *data, struct xdg_toplevel *tl) {
  (void)data; (void)tl;
}
static const struct xdg_toplevel_listener xdg_toplevel_listener = {
  .configure = xdg_toplevel_configure,
  .close = xdg_toplevel_close,
};

static void xdg_wm_base_ping(void *data, struct xdg_wm_base *b, uint32_t serial) {
  (void)data;
  xdg_wm_base_pong(b, serial);
}
static const struct xdg_wm_base_listener xdg_wm_base_listener = {
  .ping = xdg_wm_base_ping,
};

static void notification_idled(void *data, struct ext_idle_notification_v1 *n) {
  (void)data; (void)n;
  printf("idled\n");
  fflush(stdout);
}

static void notification_resumed(void *data, struct ext_idle_notification_v1 *n) {
  (void)data; (void)n;
  printf("resumed\n");
  fflush(stdout);
}

static const struct ext_idle_notification_v1_listener notification_listener = {
  .idled = notification_idled,
  .resumed = notification_resumed,
};

static void registry_global(void *data, struct wl_registry *registry,
                            uint32_t name, const char *interface, uint32_t version) {
  (void)data; (void)version;
  if (strcmp(interface, wl_compositor_interface.name) == 0) {
    compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
  } else if (strcmp(interface, wl_shm_interface.name) == 0) {
    shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
  } else if (strcmp(interface, wl_seat_interface.name) == 0) {
    seat = wl_registry_bind(registry, name, &wl_seat_interface, 7);
  } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
    wm = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
    xdg_wm_base_add_listener(wm, &xdg_wm_base_listener, NULL);
  } else if (strcmp(interface, ext_idle_notifier_v1_interface.name) == 0) {
    idle_notifier = wl_registry_bind(registry, name, &ext_idle_notifier_v1_interface, 1);
  } else if (strcmp(interface, zwp_idle_inhibit_manager_v1_interface.name) == 0) {
    idle_inhibit_manager = wl_registry_bind(registry, name, &zwp_idle_inhibit_manager_v1_interface, 1);
  }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
  (void)data; (void)registry; (void)name;
}

static const struct wl_registry_listener registry_listener = {
  registry_global,
  registry_global_remove,
};

int main(void) {
  display = wl_display_connect(NULL);
  assert(display);

  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);

  assert(compositor && shm && wm && idle_notifier && idle_inhibit_manager);

  surface = wl_compositor_create_surface(compositor);
  xdg_surface = xdg_wm_base_get_xdg_surface(wm, surface);
  xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, NULL);
  toplevel = xdg_surface_get_toplevel(xdg_surface);
  xdg_toplevel_add_listener(toplevel, &xdg_toplevel_listener, NULL);
  xdg_toplevel_set_app_id(toplevel, "rediwm.idle-fixture");
  xdg_toplevel_set_title(toplevel, "Idle Fixture");
  wl_surface_commit(surface);

  while (!configured) {
    if (wl_display_dispatch(display) < 0) return 1;
  }
  wl_display_roundtrip(display);

  printf("ready\n");
  fflush(stdout);

  struct pollfd fds[2] = {
    { .fd = STDIN_FILENO, .events = POLLIN },
    { .fd = wl_display_get_fd(display), .events = POLLIN },
  };

  char line[256];
  while (1) {
    while (wl_display_prepare_read(display) != 0) {
      wl_display_dispatch_pending(display);
    }
    wl_display_flush(display);

    if (poll(fds, 2, -1) < 0) {
      wl_display_cancel_read(display);
      break;
    }

    if (fds[1].revents & POLLIN) {
      wl_display_read_events(display);
      wl_display_dispatch_pending(display);
    } else {
      wl_display_cancel_read(display);
    }

    if (fds[0].revents & POLLIN) {
      if (!fgets(line, sizeof(line), stdin)) break;
      line[strcspn(line, "\r\n")] = 0;

      if (strcmp(line, "inhibit") == 0) {
        if (!inhibitor) {
          inhibitor = zwp_idle_inhibit_manager_v1_create_inhibitor(idle_inhibit_manager, surface);
        }
        wl_display_flush(display);
        printf("inhibited\n");
        fflush(stdout);
      } else if (strcmp(line, "uninhibit") == 0) {
        if (inhibitor) {
          zwp_idle_inhibitor_v1_destroy(inhibitor);
          inhibitor = NULL;
        }
        wl_display_flush(display);
        printf("uninhibited\n");
        fflush(stdout);
      } else if (strncmp(line, "watch ", 6) == 0) {
        uint32_t timeout_ms = (uint32_t)strtoul(line + 6, NULL, 10);
        if (notification) {
          ext_idle_notification_v1_destroy(notification);
        }
        notification = ext_idle_notifier_v1_get_idle_notification(idle_notifier, timeout_ms, seat);
        ext_idle_notification_v1_add_listener(notification, &notification_listener, NULL);
        wl_display_flush(display);
        printf("watching\n");
        fflush(stdout);
      } else if (strcmp(line, "unwatch") == 0) {
        if (notification) {
          ext_idle_notification_v1_destroy(notification);
          notification = NULL;
        }
        wl_display_flush(display);
        printf("unwatched\n");
        fflush(stdout);
      } else if (strcmp(line, "ping") == 0) {
        printf("pong\n");
        fflush(stdout);
      } else if (strcmp(line, "quit") == 0) {
        break;
      }
    }
  }

  if (notification) ext_idle_notification_v1_destroy(notification);
  if (inhibitor) zwp_idle_inhibitor_v1_destroy(inhibitor);
  xdg_toplevel_destroy(toplevel);
  xdg_surface_destroy(xdg_surface);
  wl_surface_destroy(surface);
  wl_display_disconnect(display);
  return 0;
}
