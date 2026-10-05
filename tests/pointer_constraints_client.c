// Relative-pointer and pointer-constraints peer driven by pointer_constraints.py.
#define main zoom_fixture_main
#include "zoom_client.c"
#undef main
#include "pointer-constraints-unstable-v1-client-protocol.h"
#include "relative-pointer-unstable-v1-client-protocol.h"
#include <poll.h>

static struct zwp_pointer_constraints_v1 *constraints;
static struct zwp_relative_pointer_manager_v1 *relative_manager;
static struct zwp_relative_pointer_v1 *relative;
static struct zwp_locked_pointer_v1 *locked;
static struct zwp_confined_pointer_v1 *confined;
static struct wl_pointer *pointer;

static void relative_motion(void *d, struct zwp_relative_pointer_v1 *r, uint32_t hi, uint32_t lo,
                            wl_fixed_t dx, wl_fixed_t dy, wl_fixed_t udx, wl_fixed_t udy) {
  (void)d; (void)r; (void)hi; (void)lo;
  printf("relative %.3f %.3f %.3f %.3f\n", wl_fixed_to_double(dx), wl_fixed_to_double(dy),
         wl_fixed_to_double(udx), wl_fixed_to_double(udy));
}
static const struct zwp_relative_pointer_v1_listener relative_listener = {relative_motion};
static void on_locked(void *d, struct zwp_locked_pointer_v1 *l) { (void)d; (void)l; puts("locked"); }
static void on_unlocked(void *d, struct zwp_locked_pointer_v1 *l) { (void)d; (void)l; puts("unlocked"); }
static const struct zwp_locked_pointer_v1_listener locked_listener = {on_locked, on_unlocked};
static void on_confined(void *d, struct zwp_confined_pointer_v1 *c) { (void)d; (void)c; puts("confined"); }
static void on_unconfined(void *d, struct zwp_confined_pointer_v1 *c) { (void)d; (void)c; puts("unconfined"); }
static const struct zwp_confined_pointer_v1_listener confined_listener = {on_confined, on_unconfined};

static void constraint_caps(void *d, struct wl_seat *s, uint32_t c) {
  (void)d;
  if ((c & WL_SEAT_CAPABILITY_POINTER) && !pointer) {
    pointer = wl_seat_get_pointer(s);
    wl_pointer_add_listener(pointer, &pointer_listener, NULL);
  }
}
static const struct wl_seat_listener constraint_seat_listener = {constraint_caps, seat_name};
static void constraint_global(void *d, struct wl_registry *r, uint32_t id, const char *iface, uint32_t version) {
  printf("global %s %u\n", iface, version);
  if (!strcmp(iface, "zwp_pointer_constraints_v1"))
    constraints = wl_registry_bind(r, id, &zwp_pointer_constraints_v1_interface, 1);
  else if (!strcmp(iface, "zwp_relative_pointer_manager_v1"))
    relative_manager = wl_registry_bind(r, id, &zwp_relative_pointer_manager_v1_interface, 1);
  else if (!strcmp(iface, "wl_seat")) {
    seat = wl_registry_bind(r, id, &wl_seat_interface, 5);
    wl_seat_add_listener(seat, &constraint_seat_listener, NULL);
  } else global(d, r, id, iface, version);
}
static const struct wl_registry_listener constraint_registry = {constraint_global, removed};

static uint32_t lifetime(const char *mode) {
  return !strcmp(mode, "oneshot") ? ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_ONESHOT
                                  : ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT;
}

static void command(char *line) {
  char mode[32];
  int x, y, w, h;
  double hx, hy;
  if (!strcmp(line, "relative")) {
    relative = zwp_relative_pointer_manager_v1_get_relative_pointer(relative_manager, pointer);
    zwp_relative_pointer_v1_add_listener(relative, &relative_listener, NULL);
  } else if (sscanf(line, "lock %31s", mode) == 1) {
    locked = zwp_pointer_constraints_v1_lock_pointer(constraints, surface, pointer, NULL, lifetime(mode));
    zwp_locked_pointer_v1_add_listener(locked, &locked_listener, NULL);
    wl_surface_commit(surface);
  } else if (sscanf(line, "hint %lf %lf", &hx, &hy) == 2) {
    zwp_locked_pointer_v1_set_cursor_position_hint(locked, wl_fixed_from_double(hx), wl_fixed_from_double(hy));
    wl_surface_commit(surface);
  } else if (!strcmp(line, "unlock")) {
    zwp_locked_pointer_v1_destroy(locked);
    locked = NULL;
  } else if (sscanf(line, "confine %31s %d %d %d %d", mode, &x, &y, &w, &h) == 5) {
    struct wl_region *region = wl_compositor_create_region(compositor);
    wl_region_add(region, x, y, w, h);
    confined = zwp_pointer_constraints_v1_confine_pointer(constraints, surface, pointer, region, lifetime(mode));
    zwp_confined_pointer_v1_add_listener(confined, &confined_listener, NULL);
    wl_region_destroy(region);
    wl_surface_commit(surface);
  } else if (!strcmp(line, "unconfine")) {
    zwp_confined_pointer_v1_destroy(confined);
    confined = NULL;
  } else if (strcmp(line, "sync")) {
    fprintf(stderr, "Unknown command: %s\n", line);
    abort();
  }
  assert(wl_display_roundtrip(display) >= 0);
  printf("ack %s\n", line);
}

int main(int argc, char **argv) {
  setbuf(stdout, NULL);
  display = wl_display_connect(NULL); assert(display);
  wl_registry_add_listener(wl_display_get_registry(display), &constraint_registry, NULL);
  assert(wl_display_roundtrip(display) >= 0);
  assert(wl_display_roundtrip(display) >= 0);
  assert(constraints && relative_manager && pointer);
  app_id = argc > 1 ? argv[1] : "rediwm.pointer-constraints";
  surface = wl_compositor_create_surface(compositor);
  xdg = xdg_wm_base_get_xdg_surface(wm, surface); xdg_surface_add_listener(xdg, &xdg_listener, NULL);
  toplevel = xdg_surface_get_toplevel(xdg); xdg_toplevel_add_listener(toplevel, &top_listener, NULL);
  xdg_toplevel_set_title(toplevel, app_id); xdg_toplevel_set_app_id(toplevel, app_id);
  wl_surface_commit(surface);
  puts("ready");
  struct pollfd fds[2] = {{.fd = wl_display_get_fd(display), .events = POLLIN}, {.fd = STDIN_FILENO, .events = POLLIN}};
  char line[1024]; size_t used = 0;
  while (1) {
    assert(wl_display_dispatch_pending(display) >= 0);
    wl_display_flush(display);
    if (poll(fds, 2, -1) < 0) break;
    if (fds[0].revents & POLLIN) { if (wl_display_dispatch(display) < 0) break; }
    if (fds[1].revents & POLLIN) {
      char ch; if (read(STDIN_FILENO, &ch, 1) != 1) break;
      if (ch == '\n') { line[used] = 0; command(line); used = 0; }
      else { assert(used + 1 < sizeof(line)); line[used++] = ch; }
    }
    if (fds[1].revents & POLLHUP) break;
  }
  wl_display_disconnect(display);
  return 0;
}
