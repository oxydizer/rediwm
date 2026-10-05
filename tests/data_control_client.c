// Background legacy data-control peer, deliberately binding the wlr protocol.
#define _GNU_SOURCE
#include "wlr-data-control-unstable-v1-client-protocol.h"
#include <assert.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>

static struct wl_display *display;
static struct wl_seat *seat;
static struct zwlr_data_control_manager_v1 *manager;
static int primary, setter;
static void source_send(void *d, struct zwlr_data_control_source_v1 *s, const char *mime, int32_t fd) {
  (void)d; (void)s; (void)mime;
  const char text[]="legacy clipboard";
  assert(write(fd,text,sizeof(text)-1)==sizeof(text)-1); close(fd);
}
static void source_cancel(void *d, struct zwlr_data_control_source_v1 *s) { (void)d; zwlr_data_control_source_v1_destroy(s); }
static const struct zwlr_data_control_source_v1_listener source_listener={source_send,source_cancel};
static void mime(void *d, struct zwlr_data_control_offer_v1 *offer, const char *type) { (void)d;(void)offer;(void)type; }
static const struct zwlr_data_control_offer_v1_listener offer_listener={mime};
static void offered(void *d,struct zwlr_data_control_device_v1 *dev,struct zwlr_data_control_offer_v1 *offer) {
  (void)d;(void)dev; zwlr_data_control_offer_v1_add_listener(offer,&offer_listener,NULL);
}
static void receive(struct zwlr_data_control_offer_v1 *offer, int which) {
  if(!offer)return;
  if(which==primary && !setter) {
    int fds[2]; assert(pipe(fds)==0);
    zwlr_data_control_offer_v1_receive(offer,"text/plain;charset=utf-8",fds[1]);
    close(fds[1]); wl_display_flush(display);
    struct pollfd fd={.fd=fds[0],.events=POLLIN};
    assert(poll(&fd,1,3000)>0);
    char buf[128]; ssize_t n=read(fds[0],buf,sizeof(buf)-1); assert(n>=0); buf[n]=0;
    printf("received %s\n",buf); close(fds[0]);
  }
  zwlr_data_control_offer_v1_destroy(offer);
}
static void selection(void *d, struct zwlr_data_control_device_v1 *dev, struct zwlr_data_control_offer_v1 *offer) { (void)d;(void)dev;receive(offer,0); }
static void primary_selection(void *d, struct zwlr_data_control_device_v1 *dev, struct zwlr_data_control_offer_v1 *offer) { (void)d;(void)dev;receive(offer,1); }
static void finished(void *d, struct zwlr_data_control_device_v1 *dev) { (void)d;(void)dev;exit(0); }
static const struct zwlr_data_control_device_v1_listener device_listener={offered,selection,finished,primary_selection};
static void global(void *d,struct wl_registry *r,uint32_t id,const char *name,uint32_t version) {
  (void)d;(void)version;
  if(!strcmp(name,"wl_seat")) seat=wl_registry_bind(r,id,&wl_seat_interface,1);
  if(!strcmp(name,"zwlr_data_control_manager_v1")) manager=wl_registry_bind(r,id,&zwlr_data_control_manager_v1_interface,2);
}
static void removed(void *d,struct wl_registry *r,uint32_t id) { (void)d;(void)r;(void)id; }
static const struct wl_registry_listener registry_listener={global,removed};
int main(int argc,char **argv) {
  setbuf(stdout,NULL); primary=argc>2 && !strcmp(argv[2],"primary");
  display=wl_display_connect(NULL);assert(display);
  wl_registry_add_listener(wl_display_get_registry(display),&registry_listener,NULL);
  assert(wl_display_roundtrip(display)>=0 && seat && manager);
  struct zwlr_data_control_device_v1 *dev=zwlr_data_control_manager_v1_get_data_device(manager,seat);
  setter=argc>1 && !strcmp(argv[1],"set");
  zwlr_data_control_device_v1_add_listener(dev,&device_listener,NULL);
  if(setter) {
    struct zwlr_data_control_source_v1 *source=zwlr_data_control_manager_v1_create_data_source(manager);
    zwlr_data_control_source_v1_add_listener(source,&source_listener,NULL);
    zwlr_data_control_source_v1_offer(source,"text/plain;charset=utf-8");
    if(primary) zwlr_data_control_device_v1_set_primary_selection(dev,source);
    else zwlr_data_control_device_v1_set_selection(dev,source);
  }
  puts("ready");
  while(wl_display_dispatch(display)>=0){}
  return 0;
}
