// XCB fixture for tests/xwayland.py. Speaks line commands on stdin and
// events on stdout. Never uses the host DISPLAY; the test sets ours.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <unistd.h>
#include <xcb/xcb.h>

static xcb_connection_t *conn;
static xcb_window_t win;
static xcb_window_t popup;
static xcb_window_t dlg_win = XCB_NONE;
static xcb_atom_t atom_wm_delete;
static int mapped;
static int win_x = 40, win_y = 40;
static int log_motion = 0;

static xcb_atom_t intern(const char *name) {
    xcb_intern_atom_cookie_t cookie = xcb_intern_atom(conn, 0, (uint16_t)strlen(name), name);
    xcb_intern_atom_reply_t *reply = xcb_intern_atom_reply(conn, cookie, NULL);
    xcb_atom_t atom = reply ? reply->atom : XCB_ATOM_NONE;
    free(reply);
    return atom;
}

static void set_title(const char *title) {
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, win, XCB_ATOM_WM_NAME, XCB_ATOM_STRING, 8,
                        (uint32_t)strlen(title), title);
    xcb_flush(conn);
}

static void set_class(const char *instance, const char *class_name) {
    char buf[256];
    int n = snprintf(buf, sizeof(buf), "%s%c%s", instance, 0, class_name);
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, win, XCB_ATOM_WM_CLASS, XCB_ATOM_STRING, 8,
                        (uint32_t)n + 1, buf);
    xcb_flush(conn);
}

static void handle_event(xcb_generic_event_t *event) {
    switch (event->response_type & ~0x80) {
    case XCB_MAP_NOTIFY:
        mapped = 1;
        printf("mapped\n");
        fflush(stdout);
        break;
    case XCB_UNMAP_NOTIFY:
        mapped = 0;
        printf("unmapped\n");
        fflush(stdout);
        break;
    case XCB_CONFIGURE_NOTIFY: {
        xcb_configure_notify_event_t *cfg = (xcb_configure_notify_event_t *)event;
        if (cfg->window == win) {
            win_x = cfg->x;
            win_y = cfg->y;
        }
        printf("configure %d %d %u %u\n", cfg->x, cfg->y, cfg->width, cfg->height);
        fflush(stdout);
        break;
    }
    case XCB_CLIENT_MESSAGE: {
        xcb_client_message_event_t *cm = (xcb_client_message_event_t *)event;
        if (cm->data.data32[0] == atom_wm_delete) {
            if (dlg_win != XCB_NONE && cm->window == dlg_win) {
                xcb_destroy_window(conn, dlg_win);
                dlg_win = XCB_NONE;
                xcb_flush(conn);
                printf("dialog-close\n");
                fflush(stdout);
            } else {
                printf("close\n");
                fflush(stdout);
                exit(0);
            }
        }
        break;
    }
    case XCB_BUTTON_PRESS: {
        xcb_button_press_event_t *bp = (xcb_button_press_event_t *)event;
        printf("button-press %u %d %d\n", bp->detail, bp->event_x, bp->event_y);
        fflush(stdout);
        break;
    }
    case XCB_BUTTON_RELEASE: {
        xcb_button_release_event_t *br = (xcb_button_release_event_t *)event;
        printf("button-release %u %d %d\n", br->detail, br->event_x, br->event_y);
        fflush(stdout);
        break;
    }
    case XCB_MOTION_NOTIFY: {
        if (log_motion) {
            xcb_motion_notify_event_t *mn = (xcb_motion_notify_event_t *)event;
            printf("motion %d %d\n", mn->event_x, mn->event_y);
            fflush(stdout);
        }
        break;
    }
    case XCB_DESTROY_NOTIFY:
        printf("destroyed\n");
        fflush(stdout);
        break;
    default:
        break;
    }
}

int main(int argc, char *argv[]) {
    const char *inst = "xwayland-fixture";
    const char *cls = "XwaylandFixture";
    const char *title = "X11 Fixture";
    int map_initially = 1;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--no-map")) {
            map_initially = 0;
        } else if (!strcmp(argv[i], "--class") && i + 2 < argc) {
            inst = argv[++i];
            cls = argv[++i];
        } else if (!strcmp(argv[i], "--title") && i + 1 < argc) {
            title = argv[++i];
        }
    }

    conn = xcb_connect(NULL, NULL);
    if (xcb_connection_has_error(conn)) {
        fprintf(stderr, "xcb_connect failed\n");
        return 1;
    }
    const xcb_setup_t *setup = xcb_get_setup(conn);
    xcb_screen_t *screen = xcb_setup_roots_iterator(setup).data;
    win = xcb_generate_id(conn);
    uint32_t mask = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK;
    uint32_t values[] = {
        screen->white_pixel,
        XCB_EVENT_MASK_STRUCTURE_NOTIFY | XCB_EVENT_MASK_EXPOSURE |
            XCB_EVENT_MASK_BUTTON_PRESS | XCB_EVENT_MASK_BUTTON_RELEASE |
            XCB_EVENT_MASK_BUTTON_MOTION | XCB_EVENT_MASK_POINTER_MOTION,
    };
    xcb_create_window(conn, XCB_COPY_FROM_PARENT, win, screen->root, 40, 40, 400, 300, 0,
                      XCB_WINDOW_CLASS_INPUT_OUTPUT, screen->root_visual, mask, values);
    set_class(inst, cls);
    set_title(title);

    xcb_atom_t protocols = intern("WM_PROTOCOLS");
    atom_wm_delete = intern("WM_DELETE_WINDOW");
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, win, protocols, XCB_ATOM_ATOM, 32, 1, &atom_wm_delete);

    if (map_initially)
        xcb_map_window(conn, win);
    xcb_flush(conn);
    printf("created\n");
    fflush(stdout);

    int xfd = xcb_get_file_descriptor(conn);
    // select() watches the fd, so stdio must not buffer lines past the one fgets returns.
    setvbuf(stdin, NULL, _IONBF, 0);
    char line[256];
    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(0, &rfds);
        FD_SET(xfd, &rfds);
        int nfds = xfd + 1;
        if (select(nfds, &rfds, NULL, NULL, NULL) < 0)
            break;
        if (FD_ISSET(xfd, &rfds)) {
            xcb_generic_event_t *event;
            while ((event = xcb_poll_for_event(conn))) {
                handle_event(event);
                free(event);
            }
            if (xcb_connection_has_error(conn))
                break;
        }
        if (FD_ISSET(0, &rfds)) {
            if (!fgets(line, sizeof(line), stdin))
                break;
            line[strcspn(line, "\n")] = 0;
            if (strncmp(line, "keys ", 5) == 0) {
                xcb_query_keymap_reply_t *reply = xcb_query_keymap_reply(conn, xcb_query_keymap(conn), NULL);
                if (!reply) return 1;
                printf("keys %s", line + 5);
                for (int code = 8; code < 256; code++)
                    if (reply->keys[code / 8] & (1u << (code % 8))) printf(" %d", code);
                free(reply);
                printf("\n");
                fflush(stdout);
            } else if (strncmp(line, "urgent ", 7) == 0) {
                uint32_t hints[9] = {0};
                hints[0] = atoi(line + 7) ? (1u << 8) : 0;
                xcb_change_property(conn, XCB_PROP_MODE_REPLACE, win, XCB_ATOM_WM_HINTS,
                                    XCB_ATOM_WM_HINTS, 32, 9, hints);
                xcb_flush(conn);
            } else if (strcmp(line, "urgent-input") == 0) {
                uint32_t hints[9] = {(1u << 8) | 1, 1};
                xcb_change_property(conn, XCB_PROP_MODE_REPLACE, win, XCB_ATOM_WM_HINTS,
                                    XCB_ATOM_WM_HINTS, 32, 9, hints);
                xcb_flush(conn);
            } else if (strcmp(line, "demands-state") == 0) {
                xcb_atom_t attention = intern("_NET_WM_STATE_DEMANDS_ATTENTION");
                xcb_get_property_reply_t *reply = xcb_get_property_reply(conn,
                    xcb_get_property(conn, 0, win, intern("_NET_WM_STATE"), XCB_ATOM_ATOM, 0, 128), NULL);
                int found = 0;
                if (reply) {
                    xcb_atom_t *atoms = xcb_get_property_value(reply);
                    for (unsigned i = 0; i < reply->value_len; i++) if (atoms[i] == attention) found = 1;
                    free(reply);
                }
                printf("demands-state %d\n", found);
                fflush(stdout);
            } else if (strncmp(line, "demands ", 8) == 0 || strcmp(line, "activate") == 0) {
                xcb_client_message_event_t event = {0};
                event.response_type = XCB_CLIENT_MESSAGE;
                event.format = 32;
                event.window = win;
                if (strcmp(line, "activate") == 0) {
                    event.type = intern("_NET_ACTIVE_WINDOW");
                    event.data.data32[0] = 1;
                } else {
                    event.type = intern("_NET_WM_STATE");
                    event.data.data32[0] = atoi(line + 8) ? 1 : 0;
                    event.data.data32[1] = intern("_NET_WM_STATE_DEMANDS_ATTENTION");
                    event.data.data32[3] = 1;
                }
                xcb_send_event(conn, 0, screen->root,
                               XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY,
                               (const char *)&event);
                xcb_flush(conn);
            } else if (strcmp(line, "close") == 0) {
                xcb_destroy_window(conn, win);
                xcb_flush(conn);
            } else if (strcmp(line, "unmap") == 0) {
                xcb_unmap_window(conn, win);
                xcb_flush(conn);
            } else if (strcmp(line, "map") == 0) {
                xcb_map_window(conn, win);
                xcb_flush(conn);
            } else if (strncmp(line, "override ", 9) == 0) {
                uint32_t value = (uint32_t)(atoi(line + 9) != 0);
                xcb_change_window_attributes(conn, win, XCB_CW_OVERRIDE_REDIRECT, &value);
                xcb_flush(conn);
            } else if (strncmp(line, "title ", 6) == 0) {
                set_title(line + 6);
            } else if (strncmp(line, "class ", 6) == 0) {
                char instance[128], class_name[128];
                if (sscanf(line + 6, "%127s %127s", instance, class_name) == 2)
                    set_class(instance, class_name);
            } else if (strcmp(line, "popup") == 0) {
                popup = xcb_generate_id(conn);
                uint32_t pmask = XCB_CW_BACK_PIXEL | XCB_CW_OVERRIDE_REDIRECT | XCB_CW_EVENT_MASK;
                uint32_t pvalues[] = {screen->black_pixel, 1,
                                      XCB_EVENT_MASK_STRUCTURE_NOTIFY};
                xcb_create_window(conn, XCB_COPY_FROM_PARENT, popup, screen->root, win_x + 20, win_y + 20, 80, 40, 0,
                                  XCB_WINDOW_CLASS_INPUT_OUTPUT, screen->root_visual, pmask, pvalues);
                xcb_map_window(conn, popup);
                xcb_flush(conn);
                printf("popup %d %d\n", win_x + 20, win_y + 20);
                fflush(stdout);
            } else if (strncmp(line, "dialog", 6) == 0) {
                char d_inst[128] = "dialog-inst", d_cls[128] = "dialog-cls", d_title[128] = "Dialog Window";
                sscanf(line + 6, "%127s %127s %127[^\n]", d_inst, d_cls, d_title);
                dlg_win = xcb_generate_id(conn);
                uint32_t dmask = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK;
                uint32_t dvalues[] = {
                    screen->white_pixel,
                    XCB_EVENT_MASK_STRUCTURE_NOTIFY | XCB_EVENT_MASK_EXPOSURE,
                };
                xcb_create_window(conn, XCB_COPY_FROM_PARENT, dlg_win, screen->root, win_x + 30, win_y + 30, 200, 150, 0,
                                  XCB_WINDOW_CLASS_INPUT_OUTPUT, screen->root_visual, dmask, dvalues);
                char cbuf[256];
                int cn = snprintf(cbuf, sizeof(cbuf), "%s%c%s", d_inst, 0, d_cls);
                xcb_change_property(conn, XCB_PROP_MODE_REPLACE, dlg_win, XCB_ATOM_WM_CLASS, XCB_ATOM_STRING, 8,
                                    (uint32_t)cn + 1, cbuf);
                xcb_change_property(conn, XCB_PROP_MODE_REPLACE, dlg_win, XCB_ATOM_WM_NAME, XCB_ATOM_STRING, 8,
                                    (uint32_t)strlen(d_title), d_title);
                xcb_change_property(conn, XCB_PROP_MODE_REPLACE, dlg_win, XCB_ATOM_WM_TRANSIENT_FOR, XCB_ATOM_WINDOW, 32, 1, &win);
                xcb_atom_t protocols = intern("WM_PROTOCOLS");
                xcb_change_property(conn, XCB_PROP_MODE_REPLACE, dlg_win, protocols, XCB_ATOM_ATOM, 32, 1, &atom_wm_delete);
                xcb_map_window(conn, dlg_win);
                xcb_flush(conn);
                printf("dialog-mapped\n");
                fflush(stdout);
            } else if (strcmp(line, "close-dialog") == 0) {
                if (dlg_win != XCB_NONE) {
                    xcb_destroy_window(conn, dlg_win);
                    dlg_win = XCB_NONE;
                    xcb_flush(conn);
                }
            } else if (strncmp(line, "configure ", 10) == 0) {
                int x = 0, y = 0, w = 0, h = 0;
                if (sscanf(line + 10, "%d %d %d %d", &x, &y, &w, &h) == 4 && w > 0 && h > 0) {
                    uint32_t cfg[] = {(uint32_t)x, (uint32_t)y, (uint32_t)w, (uint32_t)h};
                    xcb_configure_window(conn, win,
                                         XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y |
                                             XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT,
                                         cfg);
                    xcb_flush(conn);
                }
            } else if (strncmp(line, "aspect ", 7) == 0) {
                int32_t hints[18] = {0};
                if (sscanf(line + 7, "%d %d %d %d", &hints[11], &hints[12], &hints[13], &hints[14]) == 4) {
                    hints[0] = 1u << 7; // PAspect in WM_NORMAL_HINTS
                    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, win, XCB_ATOM_WM_NORMAL_HINTS,
                                        XCB_ATOM_WM_SIZE_HINTS, 32, 18, hints);
                    xcb_flush(conn);
                }
            } else if (strncmp(line, "resize ", 7) == 0) {
                int w = 0, h = 0;
                if (sscanf(line + 7, "%d %d", &w, &h) == 2 && w > 0 && h > 0) {
                    uint32_t cfg[] = {(uint32_t)w, (uint32_t)h};
                    xcb_configure_window(conn, win, XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, cfg);
                    xcb_flush(conn);
                }
            } else if (strcmp(line, "log-motion 1") == 0) {
                log_motion = 1;
            } else if (strcmp(line, "log-motion 0") == 0) {
                log_motion = 0;
            }
        }
    }
    xcb_disconnect(conn);
    return 0;
}
