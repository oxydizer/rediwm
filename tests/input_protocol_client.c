// Real protocol peers driven by input_protocols.py in a private compositor.
#define main zoom_fixture_main
#include "zoom_client.c"
#undef main
#include "xdg-activation-v1-client-protocol.h"
#include "text-input-unstable-v3-client-protocol.h"
#include "input-method-unstable-v2-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include <poll.h>
#include <xkbcommon/xkbcommon.h>

static struct xdg_activation_v1 *activation;
static struct zwp_text_input_manager_v3 *text_manager;
static struct zwp_input_method_manager_v2 *method_manager;
static struct zwp_virtual_keyboard_manager_v1 *virtual_manager;
static struct zwp_text_input_v3 *text_input;
static struct zwp_input_method_v2 *method;
static struct zwp_input_method_keyboard_grab_v2 *grab;
static struct zwp_virtual_keyboard_v1 *virtual_keyboard;
static struct zwp_input_popup_surface_v2 *input_popup;
static struct wl_surface *ime_surface;
static uint32_t input_serial, done_serial;
static int forward_keys;
static struct xkb_state *app_xkb;

static void enable_input(void) {
  zwp_text_input_v3_enable(text_input);
  zwp_text_input_v3_set_surrounding_text(text_input, "hello", 3, 1);
  zwp_text_input_v3_set_content_type(text_input, 1, 0);
  zwp_text_input_v3_set_cursor_rectangle(text_input, 40, 30, 2, 20);
  zwp_text_input_v3_commit(text_input);
}
static void text_enter(void *d, struct zwp_text_input_v3 *t, struct wl_surface *s) {
  (void)d; (void)t; (void)s;
  puts("text-enter");
  enable_input();
}
static void text_leave(void *d, struct zwp_text_input_v3 *t, struct wl_surface *s) {
  (void)d; (void)s;
  puts("text-leave");
  zwp_text_input_v3_disable(t);
  zwp_text_input_v3_commit(t);
}
static void text_preedit(void *d, struct zwp_text_input_v3 *t, const char *s, int32_t a, int32_t b) {
  (void)d; (void)t; printf("preedit %s %d %d\n", s ? s : "", a, b);
}
static void text_commit(void *d, struct zwp_text_input_v3 *t, const char *s) {
  (void)d; (void)t; printf("commit %s\n", s ? s : "");
}
static void text_delete(void *d, struct zwp_text_input_v3 *t, uint32_t a, uint32_t b) {
  (void)d; (void)t; printf("delete %u %u\n", a, b);
}
static void text_done(void *d, struct zwp_text_input_v3 *t, uint32_t serial) {
  (void)d; (void)t; printf("text-done %u\n", serial);
}
static const struct zwp_text_input_v3_listener text_listener = {
  .enter=text_enter, .leave=text_leave, .preedit_string=text_preedit,
  .commit_string=text_commit, .delete_surrounding_text=text_delete, .done=text_done
};
static void im_activate(void *d, struct zwp_input_method_v2 *m) { (void)d; (void)m; puts("activate"); }
static void im_deactivate(void *d, struct zwp_input_method_v2 *m) { (void)d; (void)m; puts("deactivate"); }
static void im_surround(void *d, struct zwp_input_method_v2 *m, const char *s, uint32_t a, uint32_t b) {
  (void)d; (void)m; printf("surround %s %u %u\n", s, a, b);
}
static void im_cause(void *d, struct zwp_input_method_v2 *m, uint32_t cause) { (void)d; (void)m; printf("cause %u\n", cause); }
static void im_content(void *d, struct zwp_input_method_v2 *m, uint32_t hint, uint32_t purpose) {
  (void)d; (void)m; printf("content %u %u\n", hint, purpose);
}
static void im_done(void *d, struct zwp_input_method_v2 *m) {
  (void)d; (void)m; printf("im-done %u\n", ++done_serial);
}
static void im_unavailable(void *d, struct zwp_input_method_v2 *m) { (void)d; (void)m; puts("unavailable"); }
static const struct zwp_input_method_v2_listener im_listener = {
  im_activate, im_deactivate, im_surround, im_cause, im_content, im_done, im_unavailable
};
static void grab_keymap(void *d, struct zwp_input_method_keyboard_grab_v2 *g, uint32_t format, int32_t fd, uint32_t size) {
  (void)d; (void)g;
  zwp_virtual_keyboard_v1_keymap(virtual_keyboard, format, fd, size);
  close(fd); puts("grab-keymap");
}
static void grab_key(void *d, struct zwp_input_method_keyboard_grab_v2 *g, uint32_t serial, uint32_t time, uint32_t code, uint32_t state) {
  (void)d; (void)g; (void)serial;
  printf("grab-key %u %u\n", code, state);
  if (forward_keys) zwp_virtual_keyboard_v1_key(virtual_keyboard, time, code, state);
}
static void grab_mods(void *d, struct zwp_input_method_keyboard_grab_v2 *g, uint32_t serial, uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group) {
  (void)d; (void)g; (void)serial;
  puts("grab-mods");
  if (forward_keys) zwp_virtual_keyboard_v1_modifiers(virtual_keyboard, depressed, latched, locked, group);
}
static void grab_repeat(void *d, struct zwp_input_method_keyboard_grab_v2 *g, int32_t rate, int32_t delay) {
  (void)d; (void)g; printf("grab-repeat %d %d\n", rate, delay);
}
static const struct zwp_input_method_keyboard_grab_v2_listener grab_listener = {
  grab_keymap, grab_key, grab_mods, grab_repeat
};
static void rectangle(void *d, struct zwp_input_popup_surface_v2 *p, int32_t x, int32_t y, int32_t w, int32_t h) {
  (void)d; (void)p; printf("rectangle %d %d %d %d\n", x, y, w, h);
}
static const struct zwp_input_popup_surface_v2_listener rectangle_listener = {rectangle};

static void token_done(void *d, struct xdg_activation_token_v1 *token, const char *name) {
  (void)d; printf("token %s\n", name); xdg_activation_token_v1_destroy(token);
}
static const struct xdg_activation_token_v1_listener token_listener = {token_done};
static void app_enter(void *d, struct wl_keyboard *k, uint32_t serial, struct wl_surface *s, struct wl_array *keys) {
  key_enter(d,k,serial,s,keys); input_serial=serial; puts("keyboard-enter");
}
static void app_keymap(void *d, struct wl_keyboard *k, uint32_t format, int32_t fd, uint32_t size) {
  (void)d; (void)k; assert(format == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1);
  char *data = mmap(NULL,size,PROT_READ,MAP_PRIVATE,fd,0); assert(data != MAP_FAILED);
  struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  struct xkb_keymap *map = xkb_keymap_new_from_string(ctx,data,XKB_KEYMAP_FORMAT_TEXT_V1,0); assert(map);
  if(app_xkb) xkb_state_unref(app_xkb);
  app_xkb = xkb_state_new(map);
  printf("app-layouts %u\n",xkb_keymap_num_layouts(map));
  xkb_keymap_unref(map); xkb_context_unref(ctx); munmap(data,size); close(fd);
}
static void app_modifiers(void *d, struct wl_keyboard *k, uint32_t serial, uint32_t depressed, uint32_t latched, uint32_t locked, uint32_t group) {
  (void)d;(void)k;(void)serial;
  if(app_xkb) xkb_state_update_mask(app_xkb,depressed,latched,locked,0,0,group);
}
static void layout_keyboard(void) {
  struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  struct xkb_rule_names names = {.layout="us,ru", .options="grp:caps_toggle"};
  struct xkb_keymap *map = xkb_keymap_new_from_names(ctx,&names,0); assert(map);
  char *data = xkb_keymap_get_as_string(map,XKB_KEYMAP_FORMAT_TEXT_V1);
  size_t size = strlen(data)+1;
  int fd = memfd_create("layout-test",0); assert(fd >= 0);
  assert(write(fd,data,size) == (ssize_t)size);
  virtual_keyboard=zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(virtual_manager,seat);
  zwp_virtual_keyboard_v1_keymap(virtual_keyboard,1,fd,size);
  close(fd); free(data); xkb_keymap_unref(map); xkb_context_unref(ctx);
}
static void app_key(void *d, struct wl_keyboard *k, uint32_t serial, uint32_t time, uint32_t code, uint32_t state) {
  (void)d;(void)k;(void)time; input_serial=serial; printf("app-key %u %u\n",code,state);
  if(app_xkb && state) { char name[128]; xkb_keysym_get_name(xkb_state_key_get_one_sym(app_xkb,code+8),name,sizeof(name)); printf("app-sym %s\n",name); }
}
static const struct wl_keyboard_listener app_keyboard_listener = {
  app_keymap, app_enter, key_leave, app_key, app_modifiers, repeat
};
static void app_caps(void *d, struct wl_seat *s, uint32_t c) {
  (void)d;
  if(c & WL_SEAT_CAPABILITY_POINTER) wl_pointer_add_listener(wl_seat_get_pointer(s), &pointer_listener, NULL);
  if(c & WL_SEAT_CAPABILITY_KEYBOARD) wl_keyboard_add_listener(wl_seat_get_keyboard(s), &app_keyboard_listener, NULL);
}
static const struct wl_seat_listener app_seat_listener = {app_caps, seat_name};
static void protocol_global(void *d, struct wl_registry *r, uint32_t id, const char *iface, uint32_t version) {
  printf("global %s %u\n",iface,version);
  if(!strcmp(iface,"xdg_activation_v1")) activation=wl_registry_bind(r,id,&xdg_activation_v1_interface,1);
  else if(!strcmp(iface,"zwp_text_input_manager_v3")) text_manager=wl_registry_bind(r,id,&zwp_text_input_manager_v3_interface,1);
  else if(!strcmp(iface,"zwp_input_method_manager_v2")) method_manager=wl_registry_bind(r,id,&zwp_input_method_manager_v2_interface,1);
  else if(!strcmp(iface,"zwp_virtual_keyboard_manager_v1")) virtual_manager=wl_registry_bind(r,id,&zwp_virtual_keyboard_manager_v1_interface,1);
  else if(!strcmp(iface,"wl_seat")) {
    seat=wl_registry_bind(r,id,&wl_seat_interface,5);
    wl_seat_add_listener(seat,&app_seat_listener,NULL);
  } else global(d,r,id,iface,version);
}
static const struct wl_registry_listener protocol_registry = {protocol_global,removed};

static void command(char *line) {
  if(!strcmp(line,"layout-keyboard")) layout_keyboard();
  else if(!strcmp(line,"layout-shortcut") || !strcmp(line,"layout-text")) {
    zwp_virtual_keyboard_v1_modifiers(virtual_keyboard, !strcmp(line,"layout-shortcut") ? 64 : 0,0,0,1);
    zwp_virtual_keyboard_v1_key(virtual_keyboard,100,20,1);
    zwp_virtual_keyboard_v1_key(virtual_keyboard,101,20,0);
  }
  else if(!strcmp(line,"layout-key")) {
    zwp_virtual_keyboard_v1_key(virtual_keyboard,100,20,1);
    zwp_virtual_keyboard_v1_key(virtual_keyboard,101,20,0);
  }
  else if(!strcmp(line,"layout-destroy")) {
    zwp_virtual_keyboard_v1_destroy(virtual_keyboard); virtual_keyboard=NULL;
  }
  else if(!strcmp(line,"layout-us")) zwp_virtual_keyboard_v1_modifiers(virtual_keyboard,0,0,0,0);
  else if(!strcmp(line,"enable")) enable_input();
  else if(!strcmp(line,"disable")) { zwp_text_input_v3_disable(text_input); zwp_text_input_v3_commit(text_input); }
  else if(!strcmp(line,"update")) {
    zwp_text_input_v3_set_surrounding_text(text_input,"updated",7,7);
    zwp_text_input_v3_set_text_change_cause(text_input,1);
    zwp_text_input_v3_set_cursor_rectangle(text_input,100,70,3,25);
    zwp_text_input_v3_commit(text_input);
  } else if(!strcmp(line,"extreme-rectangle")) {
    zwp_text_input_v3_set_cursor_rectangle(text_input,INT32_MAX,INT32_MIN,INT32_MAX,INT32_MAX);
    zwp_text_input_v3_commit(text_input);
  } else if(!strcmp(line,"compose") || !strcmp(line,"stale")) {
    zwp_input_method_v2_set_preedit_string(method,"pré",0,4);
    zwp_input_method_v2_commit_string(method,"composed");
    zwp_input_method_v2_delete_surrounding_text(method,2,1);
    zwp_input_method_v2_commit(method,done_serial - (!strcmp(line,"stale") ? 1 : 0));
  } else if(!strcmp(line,"commit-only")) {
    zwp_input_method_v2_commit_string(method,"final");
    zwp_input_method_v2_commit(method,done_serial);
  } else if(!strcmp(line,"grab")) {
    virtual_keyboard=zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(virtual_manager,seat);
    grab=zwp_input_method_v2_grab_keyboard(method);
    zwp_input_method_keyboard_grab_v2_add_listener(grab,&grab_listener,NULL);
  } else if(!strcmp(line,"forward")) forward_keys=1;
  else if(!strcmp(line,"ungrab")) { zwp_input_method_keyboard_grab_v2_release(grab); grab=NULL; }
  else if(!strcmp(line,"virtual-key")) {
    zwp_virtual_keyboard_v1_key(virtual_keyboard,100,30,1);
    zwp_virtual_keyboard_v1_key(virtual_keyboard,101,30,0);
  } else if(!strcmp(line,"popup")) {
    ime_surface=wl_compositor_create_surface(compositor);
    input_popup=zwp_input_method_v2_get_input_popup_surface(method,ime_surface);
    zwp_input_popup_surface_v2_add_listener(input_popup,&rectangle_listener,NULL);
    paint(ime_surface,120,50,0xff00ffff); wl_surface_commit(ime_surface);
  } else if(!strcmp(line,"method")) {
    method=zwp_input_method_manager_v2_get_input_method(method_manager,seat);
    zwp_input_method_v2_add_listener(method,&im_listener,NULL);
    done_serial=0;
  } else if(!strcmp(line,"destroy-input")) { zwp_text_input_v3_destroy(text_input); text_input=NULL; }
  else if(!strcmp(line,"create-input")) {
    text_input=zwp_text_input_manager_v3_get_text_input(text_manager,seat);
    zwp_text_input_v3_add_listener(text_input,&text_listener,NULL);
  } else if(!strcmp(line,"unmap")) { wl_surface_attach(surface,NULL,0,0); wl_surface_commit(surface); }
  else if(!strncmp(line,"token",5)) {
    struct xdg_activation_token_v1 *token=xdg_activation_v1_get_activation_token(activation);
    xdg_activation_token_v1_add_listener(token,&token_listener,NULL);
    if(strcmp(line,"token-empty")) {
      xdg_activation_token_v1_set_surface(token,surface);
      xdg_activation_token_v1_set_serial(token,!strcmp(line,"token-bad") ? 0 : input_serial,seat);
    }
    xdg_activation_token_v1_commit(token);
  } else if(!strncmp(line,"activate ",9)) xdg_activation_v1_activate(activation,line+9,surface);
  else if(strcmp(line,"sync")) { fprintf(stderr,"Unknown command: %s\n",line); abort(); }
  assert(wl_display_roundtrip(display)>=0);
  printf("ack %s\n",line);
}

int main(int argc,char **argv) {
  setbuf(stdout,NULL);
  display=wl_display_connect(NULL); assert(display);
  wl_registry_add_listener(wl_display_get_registry(display),&protocol_registry,NULL);
  assert(wl_display_roundtrip(display)>=0);
  assert(activation && text_manager && method_manager && virtual_manager && seat);
  if(argc>1 && strcmp(argv[1],"ime")) {
    app_id=argv[1];
    surface=wl_compositor_create_surface(compositor);
    xdg=xdg_wm_base_get_xdg_surface(wm,surface); xdg_surface_add_listener(xdg,&xdg_listener,NULL);
    toplevel=xdg_surface_get_toplevel(xdg); xdg_toplevel_add_listener(toplevel,&top_listener,NULL);
    xdg_toplevel_set_title(toplevel,app_id); xdg_toplevel_set_app_id(toplevel,app_id);
    text_input=zwp_text_input_manager_v3_get_text_input(text_manager,seat);
    zwp_text_input_v3_add_listener(text_input,&text_listener,NULL);
    wl_surface_commit(surface);
  }
  puts("ready");
  struct pollfd fds[2]={{.fd=wl_display_get_fd(display),.events=POLLIN},{.fd=STDIN_FILENO,.events=POLLIN}};
  char line[1024]; size_t used=0;
  while(1) {
    assert(wl_display_dispatch_pending(display)>=0);
    wl_display_flush(display);
    if(poll(fds,2,-1)<0) break;
    if(fds[0].revents & POLLIN) { if(wl_display_dispatch(display)<0) break; }
    if(fds[1].revents & POLLIN) {
      char ch; if(read(STDIN_FILENO,&ch,1)!=1) break;
      if(ch=='\n') { line[used]=0; command(line); used=0; }
      else { assert(used+1<sizeof(line)); line[used++]=ch; }
    }
    if(fds[1].revents & POLLHUP) break;
  }
  wl_display_disconnect(display);
  return 0;
}
