// Included by fifo_client.c to use its surfaces and actual presentation feedback.
static void set_target(struct wp_commit_timer_v1 *timer, uint64_t ns) {
  uint64_t sec = ns / 1000000000;
  wp_commit_timer_v1_set_timestamp(timer, sec >> 32, (uint32_t)sec, ns % 1000000000);
}

static void timed_buffer(struct wl_surface *surface, const char *label) {
  attach_shm(surface, 160, 120, true);
  request_feedback(surface, label);
  wl_surface_commit(surface);
}

static void timing_case(struct window *w) {
  assert(timing);
  uint64_t first = now_ns() + 100000000, second = first + 100000000;
  printf("targets %" PRIu64 " %" PRIu64 "\n", first, second);
  struct wp_commit_timer_v1 *timer = wp_commit_timing_manager_v1_get_timer(timing, w->surface);
  set_target(timer, first);
  wp_commit_timer_v1_destroy(timer); // Pending timestamp survives the timer.
  timed_buffer(w->surface, "first");
  timer = wp_commit_timing_manager_v1_get_timer(timing, w->surface);
  set_target(timer, second);
  wp_fifo_v1_set_barrier(w->fifo);
  timed_buffer(w->surface, "second");
  wp_commit_timer_v1_destroy(timer); // Committed constraint survives too.
  wp_fifo_v1_wait_barrier(w->fifo);
  timed_buffer(w->surface, "untimed");
  report();
}

static void timing_subsurface(struct window *parent) {
  struct wl_surface *surface = wl_compositor_create_surface(compositor);
  struct wl_subsurface *sub = wl_subcompositor_get_subsurface(subcompositor, surface, parent->surface);
  struct wp_commit_timer_v1 *timer = wp_commit_timing_manager_v1_get_timer(timing, surface);
  wl_subsurface_set_position(sub, 32, 32);
  uint64_t target = now_ns() + 100000000;
  printf("target %" PRIu64 "\n", target);
  set_target(timer, target);
  timed_buffer(surface, "child");
  timed_buffer(parent->surface, "parent");
  report();

  // A target beyond the timer's millisecond range must disappear with the surface.
  wp_commit_timer_v1_set_timestamp(timer, UINT32_MAX, UINT32_MAX, 999999999);
  wl_surface_commit(surface);
  wl_subsurface_destroy(sub);
  wl_surface_destroy(surface);
  wp_commit_timer_v1_destroy(timer);
  timed_buffer(parent->surface, "survivor");
  report();
}

static int timing_error(const char *mode) {
  struct wl_surface *surface = wl_compositor_create_surface(compositor);
  struct wp_commit_timer_v1 *timer = wp_commit_timing_manager_v1_get_timer(timing, surface);
  if (!strcmp(mode, "timing-duplicate")) {
    wp_commit_timing_manager_v1_get_timer(timing, surface);
    return expect_error(&wp_commit_timing_manager_v1_interface, WP_COMMIT_TIMING_MANAGER_V1_ERROR_COMMIT_TIMER_EXISTS);
  }
  if (!strcmp(mode, "timing-nsec")) {
    wp_commit_timer_v1_set_timestamp(timer, 0, 0, 1000000000);
    return expect_error(&wp_commit_timer_v1_interface, WP_COMMIT_TIMER_V1_ERROR_INVALID_TIMESTAMP);
  }
  if (!strcmp(mode, "timing-pending")) {
    set_target(timer, 0);
    wp_commit_timer_v1_destroy(timer);
    timer = wp_commit_timing_manager_v1_get_timer(timing, surface);
    set_target(timer, 0);
    return expect_error(&wp_commit_timer_v1_interface, WP_COMMIT_TIMER_V1_ERROR_TIMESTAMP_EXISTS);
  }
  assert(!strcmp(mode, "timing-orphan"));
  wl_surface_destroy(surface);
  set_target(timer, 0);
  return expect_error(&wp_commit_timer_v1_interface, WP_COMMIT_TIMER_V1_ERROR_SURFACE_DESTROYED);
}
