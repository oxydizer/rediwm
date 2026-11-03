// Probe client for frame_latency.py: commits frames and records, for each, when it
// was committed and when the display showed it (wp_presentation feedback).
//
//   frame_probe_client paced|event SECONDS OUTPUT_FILE
//
// paced: animates, one commit per frame callback (a game or video player).
// event: commits on every pointer motion over its window (drawing, dragging, a
//        terminal echoing keys): content arriving at arbitrary points of the period.
//
// The output file has one line per commit: commit_ns presented_ns flags
// (presented_ns 0: the frame was replaced before it was shown).
#define _GNU_SOURCE
#include "presentation-time-client-protocol.h"
#include "xdg-shell-client-protocol.h"
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#define W 640
#define H 400
#define BUFFERS 8
#define MAX_RECORDS 65536

struct frame_buffer {
  struct wl_buffer *buffer;
  uint32_t *pixels;
  bool busy;
};
struct record {
  uint64_t commit_ns, presented_ns;
  uint32_t flags;
};

static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct xdg_wm_base *wm;
static struct wp_presentation *presentation;
static struct wl_surface *surface;
static struct frame_buffer buffers[BUFFERS];
static struct record records[MAX_RECORDS];
static int record_count, pending_feedback;
static clockid_t clock_id = CLOCK_MONOTONIC;
static bool paced, mapped, running = true;
static uint64_t stop_ns;
static int frame_number;

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(clock_id, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void draw(uint32_t *pixels, int x, int y) {
  for (int i = 0; i < W * H; i++) pixels[i] = 0xff202830;
  for (int row = y - 16; row < y + 16; row++) {
    if (row < 0 || row >= H) continue;
    for (int col = x - 16; col < x + 16; col++)
      if (col >= 0 && col < W) pixels[row * W + col] = 0xfff0f0f0;
  }
}

static void released(void *data, struct wl_buffer *buffer) {
  (void)buffer;
  ((struct frame_buffer *)data)->busy = false;
}
static const struct wl_buffer_listener buffer_listener = {released};

static void feedback_sync_output(void *d, struct wp_presentation_feedback *f, struct wl_output *o) {
  (void)d; (void)f; (void)o;
}
static void feedback_presented(void *data, struct wp_presentation_feedback *feedback, uint32_t sec_hi, uint32_t sec_lo,
                               uint32_t nsec, uint32_t refresh, uint32_t seq_hi, uint32_t seq_lo, uint32_t flags) {
  (void)refresh; (void)seq_hi; (void)seq_lo;
  struct record *r = &records[(intptr_t)data];
  r->presented_ns = (((uint64_t)sec_hi << 32 | sec_lo) * 1000000000ull) + nsec;
  r->flags = flags;
  pending_feedback--;
  wp_presentation_feedback_destroy(feedback);
}
static void feedback_discarded(void *data, struct wp_presentation_feedback *feedback) {
  (void)data;
  pending_feedback--;
  wp_presentation_feedback_destroy(feedback);
}
static const struct wp_presentation_feedback_listener feedback_listener = {feedback_sync_output, feedback_presented,
                                                                          feedback_discarded};

static void frame_done(void *data, struct wl_callback *callback, uint32_t time);
static const struct wl_callback_listener frame_listener = {frame_done};

static void commit_frame(int x, int y) {
  if (!mapped || !running || record_count >= MAX_RECORDS) return;
  struct frame_buffer *b = NULL;
  for (int i = 0; i < BUFFERS && !b; i++)
    if (!buffers[i].busy) b = &buffers[i];
  if (!b) return;
  draw(b->pixels, x, y);
  wl_surface_attach(surface, b->buffer, 0, 0);
  b->busy = true;
  wl_surface_damage_buffer(surface, 0, 0, W, H);
  struct wp_presentation_feedback *feedback = wp_presentation_feedback(presentation, surface);
  wp_presentation_feedback_add_listener(feedback, &feedback_listener, (void *)(intptr_t)record_count);
  pending_feedback++;
  if (paced) wl_callback_add_listener(wl_surface_frame(surface), &frame_listener, NULL);
  records[record_count].commit_ns = now_ns();
  record_count++;
  wl_surface_commit(surface);
  wl_display_flush(display);
}

static void frame_done(void *data, struct wl_callback *callback, uint32_t time) {
  (void)data; (void)time;
  wl_callback_destroy(callback);
  frame_number++;
  commit_frame(40 + (frame_number * 7) % (W - 80), H / 2);
}

static void pointer_enter(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf, wl_fixed_t x, wl_fixed_t y) {
  (void)d; (void)p; (void)s; (void)sf; (void)x; (void)y;
}
static void pointer_leave(void *d, struct wl_pointer *p, uint32_t s, struct wl_surface *sf) {
  (void)d; (void)p; (void)s; (void)sf;
}
static void pointer_motion(void *d, struct wl_pointer *p, uint32_t t, wl_fixed_t x, wl_fixed_t y) {
  (void)d; (void)p; (void)t;
  if (!paced) commit_frame(wl_fixed_to_int(x), wl_fixed_to_int(y));
}
static void pointer_button(void *d, struct wl_pointer *p, uint32_t s, uint32_t t, uint32_t b, uint32_t st) {
  (void)d; (void)p; (void)s; (void)t; (void)b; (void)st;
}
static void pointer_axis(void *d, struct wl_pointer *p, uint32_t t, uint32_t a, wl_fixed_t v) {
  (void)d; (void)p; (void)t; (void)a; (void)v;
}
static const struct wl_pointer_listener pointer_listener = {
    .enter = pointer_enter, .leave = pointer_leave, .motion = pointer_motion, .button = pointer_button, .axis = pointer_axis};

static void seat_capabilities(void *data, struct wl_seat *s, uint32_t caps) {
  (void)data;
  if (caps & WL_SEAT_CAPABILITY_POINTER) wl_pointer_add_listener(wl_seat_get_pointer(s), &pointer_listener, NULL);
}
static void seat_name(void *d, struct wl_seat *s, const char *n) { (void)d; (void)s; (void)n; }
static const struct wl_seat_listener seat_listener = {.capabilities = seat_capabilities, .name = seat_name};

static void wm_ping(void *d, struct xdg_wm_base *b, uint32_t serial) { (void)d; xdg_wm_base_pong(b, serial); }
static const struct xdg_wm_base_listener wm_listener = {wm_ping};

static void presentation_clock(void *d, struct wp_presentation *p, uint32_t id) { (void)d; (void)p; clock_id = id; }
static const struct wp_presentation_listener presentation_listener = {presentation_clock};

static void xdg_configure(void *d, struct xdg_surface *s, uint32_t serial) {
  (void)d;
  xdg_surface_ack_configure(s, serial);
  if (!mapped) {
    mapped = true;
    commit_frame(W / 2, H / 2);
  }
}
static const struct xdg_surface_listener xdg_listener = {xdg_configure};
static void top_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *s) {
  (void)d; (void)t; (void)w; (void)h; (void)s;
}
static void top_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; running = false; }
static const struct xdg_toplevel_listener top_listener = {.configure = top_configure, .close = top_close};

static void global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t version) {
  (void)d;
  if (!strcmp(iface, "wl_compositor")) compositor = wl_registry_bind(r, name, &wl_compositor_interface, 4);
  else if (!strcmp(iface, "wl_shm")) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
  else if (!strcmp(iface, "wl_seat")) seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
  else if (!strcmp(iface, "xdg_wm_base")) wm = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
  else if (!strcmp(iface, "wp_presentation"))
    presentation = wl_registry_bind(r, name, &wp_presentation_interface, version < 1 ? version : 1);
}
static void global_remove(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener registry_listener = {global, global_remove};

int main(int argc, char **argv) {
  if (argc != 4 || (strcmp(argv[1], "paced") && strcmp(argv[1], "event"))) {
    fprintf(stderr, "usage: %s paced|event SECONDS OUTPUT_FILE\n", argv[0]);
    return 2;
  }
  paced = !strcmp(argv[1], "paced");
  double seconds = atof(argv[2]);
  display = wl_display_connect(NULL);
  if (!display) { fprintf(stderr, "no display\n"); return 1; }
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, NULL);
  wl_display_roundtrip(display);
  if (!compositor || !shm || !wm || !presentation) { fprintf(stderr, "missing globals\n"); return 1; }
  wp_presentation_add_listener(presentation, &presentation_listener, NULL);
  xdg_wm_base_add_listener(wm, &wm_listener, NULL);
  if (seat) wl_seat_add_listener(seat, &seat_listener, NULL);
  wl_display_roundtrip(display);

  int fd = memfd_create("frame-probe", 0);
  size_t size = (size_t)W * H * 4;
  if (fd < 0 || ftruncate(fd, size * BUFFERS) < 0) return 1;
  uint32_t *map = mmap(NULL, size * BUFFERS, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (map == MAP_FAILED) return 1;
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size * BUFFERS);
  for (int i = 0; i < BUFFERS; i++) {
    buffers[i].pixels = map + (size / 4) * i;
    buffers[i].buffer = wl_shm_pool_create_buffer(pool, size * i, W, H, W * 4, WL_SHM_FORMAT_XRGB8888);
    wl_buffer_add_listener(buffers[i].buffer, &buffer_listener, &buffers[i]);
  }

  surface = wl_compositor_create_surface(compositor);
  struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm, surface);
  xdg_surface_add_listener(xdg, &xdg_listener, NULL);
  struct xdg_toplevel *toplevel = xdg_surface_get_toplevel(xdg);
  xdg_toplevel_add_listener(toplevel, &top_listener, NULL);
  xdg_toplevel_set_app_id(toplevel, "frame-probe");
  xdg_toplevel_set_title(toplevel, "frame probe");
  wl_surface_commit(surface);

  uint64_t end_ns = 0;
  while (true) {
    while (wl_display_prepare_read(display) != 0) wl_display_dispatch_pending(display);
    wl_display_flush(display);
    struct pollfd pfd = {wl_display_get_fd(display), POLLIN, 0};
    poll(&pfd, 1, 20);
    if (pfd.revents & POLLIN) wl_display_read_events(display);
    else wl_display_cancel_read(display);
    wl_display_dispatch_pending(display);
    uint64_t now = now_ns();
    if (mapped && !stop_ns) stop_ns = now + (uint64_t)(seconds * 1e9);
    if (running && stop_ns && now >= stop_ns) {
      running = false;
      end_ns = now + 500000000ull;
    }
    if (!running && !end_ns) end_ns = now + 500000000ull;
    if (!running && (pending_feedback <= 0 || now >= end_ns)) break;
  }

  FILE *out = fopen(argv[3], "w");
  if (!out) return 1;
  for (int i = 0; i < record_count; i++)
    fprintf(out, "%llu %llu %u\n", (unsigned long long)records[i].commit_ns, (unsigned long long)records[i].presented_ns,
            records[i].flags);
  fclose(out);
  return 0;
}
