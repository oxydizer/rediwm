// Reuse the real xdg window fixture; add a genuine wl_data_device source.
#define main zoom_fixture_main
#include "zoom_client.c"
#undef main
static struct wl_data_device_manager *data_manager;
static struct wl_data_device *data_device;
static struct wl_seat *transfer_seat;
static const char *payload;
static void source_target(void *d, struct wl_data_source *s, const char *mime) { (void)d;(void)s;(void)mime; }
static void source_send(void *d, struct wl_data_source *s, const char *mime, int32_t fd) {
    (void)d;(void)s;(void)mime;
    assert(write(fd,payload,strlen(payload))==(ssize_t)strlen(payload));
    close(fd);puts("transfer-sent");
}
static void source_cancel(void *d, struct wl_data_source *s) {(void)d;wl_data_source_destroy(s);}
static void source_drop(void *d, struct wl_data_source *s) {(void)d;(void)s;}
static void source_finish(void *d, struct wl_data_source *s) {(void)d;puts("transfer-finished");wl_data_source_destroy(s);}
static void source_action(void *d, struct wl_data_source *s, uint32_t action) {(void)d;(void)s;(void)action;}
static const struct wl_data_source_listener source_listener={source_target,source_send,source_cancel,source_drop,source_finish,source_action};
static void transfer_button(void *d, struct wl_pointer *p, uint32_t serial, uint32_t time, uint32_t b, uint32_t state) {
    (void)d;(void)p;(void)time;
    if(!state)return;
    struct wl_data_source *source=wl_data_device_manager_create_data_source(data_manager);
    wl_data_source_add_listener(source,&source_listener,NULL);
    wl_data_source_offer(source,"text/uri-list");
    if(b==272){
        wl_data_source_set_actions(source,WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY|WL_DATA_DEVICE_MANAGER_DND_ACTION_MOVE);
        wl_data_device_start_drag(data_device,source,surface,NULL,serial);
    }else wl_data_device_set_selection(data_device,source,serial);
}
static const struct wl_pointer_listener transfer_pointer={.enter=pointer_enter,.leave=pointer_leave,.motion=pointer_motion,.button=transfer_button,.axis=pointer_axis,.frame=pointer_frame,.axis_source=pointer_source,.axis_stop=pointer_stop,.axis_discrete=pointer_discrete};
static void transfer_caps(void *d, struct wl_seat *s, uint32_t c) {
    (void)d;
    if(c&WL_SEAT_CAPABILITY_POINTER)wl_pointer_add_listener(wl_seat_get_pointer(s),&transfer_pointer,NULL);
    if(c&WL_SEAT_CAPABILITY_KEYBOARD)wl_keyboard_add_listener(wl_seat_get_keyboard(s),&keyboard_listener,NULL);
}
static const struct wl_seat_listener transfer_seat_listener={transfer_caps,seat_name};
static void transfer_global(void *d,struct wl_registry *r,uint32_t id,const char *interface,uint32_t version){
    if(!strcmp(interface,"wl_data_device_manager"))data_manager=wl_registry_bind(r,id,&wl_data_device_manager_interface,3);
    else if(!strcmp(interface,"wl_seat")){transfer_seat=wl_registry_bind(r,id,&wl_seat_interface,5);wl_seat_add_listener(transfer_seat,&transfer_seat_listener,NULL);}
    else global(d,r,id,interface,version);
}
static const struct wl_registry_listener transfer_registry={transfer_global,removed};
static void offered(void *d,struct wl_data_device *dev,struct wl_data_offer *offer){(void)d;(void)dev;wl_data_offer_destroy(offer);}
static void selection(void *d,struct wl_data_device *dev,struct wl_data_offer *offer){(void)d;(void)dev;(void)offer;}
static const struct wl_data_device_listener device_listener={.data_offer=offered,.selection=selection};
int main(void){
    setbuf(stdout,NULL);payload=getenv("REDIWM_TEST_TRANSFER");assert(payload);
    display=wl_display_connect(NULL);assert(display);
    wl_registry_add_listener(wl_display_get_registry(display),&transfer_registry,NULL);
    assert(wl_display_roundtrip(display)>=0 && data_manager && transfer_seat);
    data_device=wl_data_device_manager_get_data_device(data_manager,transfer_seat);
    wl_data_device_add_listener(data_device,&device_listener,NULL);
    surface=wl_compositor_create_surface(compositor);
    xdg=xdg_wm_base_get_xdg_surface(wm,surface);xdg_surface_add_listener(xdg,&xdg_listener,NULL);
    toplevel=xdg_surface_get_toplevel(xdg);xdg_toplevel_add_listener(toplevel,&top_listener,NULL);
    xdg_toplevel_set_title(toplevel,"Desktop transfer fixture");xdg_toplevel_set_app_id(toplevel,"rediwm.desktop-transfer");wl_surface_commit(surface);
    while(wl_display_dispatch(display)>=0){}
    return 0;
}
