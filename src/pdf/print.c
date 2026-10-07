// Printing for the sandboxed viewer. The parser process may not connect to
// the session bus, so before the sandbox is installed it forks this helper.
// The helper never receives PDF bytes from the parser: it holds the document
// descriptor opened from the user's path, and the viewer's end of a socket
// pair can only ask it to print that document. It hands the document to the
// xdg-desktop-portal Print interface, whose dialog the person confirms.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <glib-unix.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <unistd.h>

// Viewer to helper.
#define REQUEST_PRINT 'p'
// Helper to viewer: no print portal answered, or the print job failed.
#define REPLY_UNAVAILABLE 'u'
#define REPLY_FAILED 'f'

#define PORTAL_NAME "org.freedesktop.portal.Desktop"
#define PORTAL_PATH "/org/freedesktop/portal/desktop"

typedef struct {
    int document, peer;
    char *title;
    GMainLoop *loop;
    GDBusConnection *bus;
    // While a print dialog is open: its request object and Response watch.
    gboolean busy;
    char *request;
    guint response;
    unsigned serial;
    // The viewer has exited; quit once the open dialog is answered.
    gboolean closing;
} helper;

static void reply(helper *h, char code) {
    ssize_t n;
    do n = write(h->peer, &code, 1);
    while (n < 0 && errno == EINTR);
}

static void finish(helper *h) {
    if (h->response) g_dbus_connection_signal_unsubscribe(h->bus, h->response);
    h->response = 0;
    g_clear_pointer(&h->request, g_free);
    h->busy = FALSE;
    if (h->closing) g_main_loop_quit(h->loop);
}

static void on_response(GDBusConnection *bus, const char *sender, const char *path,
                        const char *interface, const char *signal, GVariant *params, gpointer data) {
    (void)bus; (void)sender; (void)path; (void)interface; (void)signal;
    helper *h = data;
    guint32 code = 2;
    if (g_variant_is_of_type(params, G_VARIANT_TYPE("(ua{sv})"))) g_variant_get_child(params, 0, "u", &code);
    // 0 sent to the printer, 1 cancelled in the dialog, 2 failed.
    if (code == 2) reply(h, REPLY_FAILED);
    finish(h);
}

static void watch_request(helper *h, const char *path) {
    if (h->response) g_dbus_connection_signal_unsubscribe(h->bus, h->response);
    g_free(h->request);
    h->request = g_strdup(path);
    h->response = g_dbus_connection_signal_subscribe(
        h->bus, PORTAL_NAME, "org.freedesktop.portal.Request", "Response", h->request, NULL,
        G_DBUS_SIGNAL_FLAGS_NONE, on_response, h, NULL);
}

// A Response cannot arrive any more; the next print reconnects.
static void on_closed(GDBusConnection *bus, gboolean vanished, GError *error, gpointer data) {
    (void)bus; (void)vanished; (void)error;
    helper *h = data;
    if (h->busy) {
        reply(h, REPLY_FAILED);
        finish(h);
    }
}

static void on_called(GObject *source, GAsyncResult *result, gpointer data) {
    helper *h = data;
    GError *error = NULL;
    GVariant *ret = g_dbus_connection_call_with_unix_fd_list_finish(G_DBUS_CONNECTION(source), NULL, result, &error);
    if (!ret) {
        fprintf(stderr, "rediwm-pdf: print portal: %s\n", error->message);
        g_error_free(error);
        // Already reported if the bus closed under the call.
        if (h->busy) {
            reply(h, REPLY_UNAVAILABLE);
            finish(h);
        }
        return;
    }
    const char *handle = NULL;
    g_variant_get(ret, "(&o)", &handle);
    // A portal that ignored handle_token answers on a path of its own.
    if (h->busy && g_strcmp0(handle, h->request) != 0) watch_request(h, handle);
    g_variant_unref(ret);
}

static void start_print(helper *h) {
    GError *error = NULL;
    if (h->bus && g_dbus_connection_is_closed(h->bus)) g_clear_object(&h->bus);
    if (!h->bus) {
        h->bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
        if (!h->bus) {
            fprintf(stderr, "rediwm-pdf: print: no session bus: %s\n", error->message);
            g_error_free(error);
            reply(h, REPLY_UNAVAILABLE);
            return;
        }
        g_dbus_connection_set_exit_on_close(h->bus, FALSE);
        g_signal_connect(h->bus, "closed", G_CALLBACK(on_closed), h);
    }

    // A new open file description, so the print system reads from offset 0
    // independently of the parser's reads.
    char proc[64];
    snprintf(proc, sizeof proc, "/proc/self/fd/%d", h->document);
    int fd = open(proc, O_RDONLY | O_CLOEXEC | O_NOCTTY);
    if (fd < 0) {
        fprintf(stderr, "rediwm-pdf: print: cannot reopen the document: %s\n", strerror(errno));
        reply(h, REPLY_FAILED);
        return;
    }
    GUnixFDList *fds = g_unix_fd_list_new_from_array(&fd, 1);

    // Subscribe before calling: the request path is known from the token.
    char token[32];
    snprintf(token, sizeof token, "rediwm_pdf%u", ++h->serial);
    char *sender = g_strdup(g_dbus_connection_get_unique_name(h->bus) + 1);
    g_strdelimit(sender, ".", '_');
    char *path = g_strdup_printf(PORTAL_PATH "/request/%s/%s", sender, token);
    watch_request(h, path);
    g_free(path);
    g_free(sender);
    h->busy = TRUE;

    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token));
    // RediWM has no xdg-foreign, so the dialog cannot name a parent window.
    g_dbus_connection_call_with_unix_fd_list(
        h->bus, PORTAL_NAME, PORTAL_PATH, "org.freedesktop.portal.Print", "Print",
        g_variant_new("(ssha{sv})", "", h->title, 0, &options), G_VARIANT_TYPE("(o)"),
        G_DBUS_CALL_FLAGS_NONE, -1, fds, NULL, on_called, h);
    g_object_unref(fds);
}

static gboolean on_peer(gint fd, GIOCondition condition, gpointer data) {
    helper *h = data;
    char buf[16];
    ssize_t n = (condition & G_IO_IN) ? read(fd, buf, sizeof buf) : 0;
    if (n < 0 && (errno == EINTR || errno == EAGAIN)) return G_SOURCE_CONTINUE;
    if (n <= 0) {
        h->closing = TRUE;
        if (!h->busy) g_main_loop_quit(h->loop);
        return G_SOURCE_REMOVE;
    }
    // One dialog at a time: presses while it is open do nothing.
    if (memchr(buf, REQUEST_PRINT, (size_t)n) && !h->busy) start_print(h);
    return G_SOURCE_CONTINUE;
}

static int keep_only(int a, int b) {
    int lower = a < b ? a : b, upper = a < b ? b : a;
    if (lower < 3 || lower == upper) return -1;
    if (lower > 3 && close_range(3, (unsigned)lower - 1, 0) < 0) return -1;
    if (upper > lower + 1 && close_range((unsigned)lower + 1, (unsigned)upper - 1, 0) < 0) return -1;
    return close_range((unsigned)upper + 1, ~0u, 0);
}

static int run(int document, int peer, const char *path) {
    // The viewer's other descriptors (Wayland, the caller's) are not ours.
    if (keep_only(document, peer) < 0) return 1;
    prctl(PR_SET_NAME, "rediwm-pdf-prnt", 0, 0, 0);
    signal(SIGCHLD, SIG_DFL);
    int devnull = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (devnull >= 0) {
        dup2(devnull, STDIN_FILENO);
        close(devnull);
    }

    helper h = { .document = document, .peer = peer };
    h.title = g_path_get_basename(path);
    // Job titles travel as D-Bus strings, which must be UTF-8.
    if (!g_utf8_validate(h.title, -1, NULL)) {
        g_free(h.title);
        h.title = g_strdup("Document");
    }
    h.loop = g_main_loop_new(NULL, FALSE);
    g_unix_fd_add(peer, G_IO_IN | G_IO_HUP | G_IO_ERR, on_peer, &h);
    g_main_loop_run(h.loop);
    return 0;
}

int rediwm_pdf_print_start(int document, const char *path) {
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) < 0) return -1;
    // The sandboxed viewer cannot wait(); the kernel reaps the helper.
    signal(SIGCHLD, SIG_IGN);
    pid_t pid = fork();
    if (pid < 0) {
        close(pair[0]);
        close(pair[1]);
        return -1;
    }
    if (pid == 0) {
        close(pair[0]);
        _exit(run(document, pair[1], path));
    }
    close(pair[1]);
    return pair[0];
}
