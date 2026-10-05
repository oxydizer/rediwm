/* UDisks2 volume monitor; see volumes.h. */
#define _GNU_SOURCE
#include "volumes.h"

#include <gio/gio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <unistd.h>

#define UD_NAME "org.freedesktop.UDisks2"
#define UD_ROOT "/org/freedesktop/UDisks2"
#define UD_BLOCK UD_NAME ".Block"
#define UD_FILESYSTEM UD_NAME ".Filesystem"
#define UD_DRIVE UD_NAME ".Drive"

/* A burst of D-Bus signals (a stick appearing makes dozens) becomes one rebuild. */
#define REBUILD_DELAY_MS 40
/* Polkit may be waiting on a person, and mounting a large disk is slow. */
#define CALL_TIMEOUT_MS 300000

struct vol_monitor {
    GMainContext *context;
    GMainLoop *loop;
    GDBusObjectManager *manager; /* monitor thread only; NULL when UDisks2 is unreachable */
    gboolean rebuild_pending;    /* monitor thread only */
    int wake_fd;

    GMutex lock;
    vol_record *records; /* the newest list */
    size_t count;
    int dirty; /* `records` has not been taken yet */
    GQueue results;
};

typedef struct {
    vol_monitor *m;
    int unmount;
    char object[sizeof(((vol_record *)0)->object)];
} command;

static void wake(vol_monitor *m)
{
    uint64_t one = 1;
    ssize_t written = write(m->wake_fd, &one, sizeof one);
    (void)written; /* A full counter means a wake is already pending. */
}

/* Strings from the daemon should be UTF-8; anything else is dropped rather
 * than drawn as garbage. Cuts on a character boundary. */
static void copy_text(char *dst, size_t cap, const char *src)
{
    dst[0] = '\0';
    if (!src || !g_utf8_validate(src, -1, NULL))
        return;
    size_t n = strlen(src);
    if (n >= cap) {
        n = cap - 1;
        while (n > 0 && ((unsigned char)src[n] & 0xC0) == 0x80)
            n--;
    }
    memcpy(dst, src, n);
    dst[n] = '\0';
}

/* Paths are bytes, and a truncated one would name another place. */
static void copy_path(char *dst, size_t cap, const char *src)
{
    dst[0] = '\0';
    if (src && strlen(src) < cap)
        memcpy(dst, src, strlen(src) + 1);
}

static GDBusProxy *interface_of(GDBusObject *object, const char *name)
{
    GDBusInterface *found = g_dbus_object_get_interface(object, name);
    return found ? G_DBUS_PROXY(found) : NULL;
}

static GVariant *property(GDBusProxy *proxy, const char *name)
{
    return proxy ? g_dbus_proxy_get_cached_property(proxy, name) : NULL;
}

/* Reads a string, object path or byte-string property. */
static void text_property(GDBusProxy *proxy, const char *name, char *dst, size_t cap, int path)
{
    GVariant *value = property(proxy, name);
    if (!value)
        return;
    const char *text = NULL;
    if (g_variant_is_of_type(value, G_VARIANT_TYPE_STRING) || g_variant_is_of_type(value, G_VARIANT_TYPE_OBJECT_PATH))
        text = g_variant_get_string(value, NULL);
    else if (g_variant_is_of_type(value, G_VARIANT_TYPE_BYTESTRING))
        text = g_variant_get_bytestring(value);
    if (path)
        copy_path(dst, cap, text);
    else
        copy_text(dst, cap, text);
    g_variant_unref(value);
}

static uint8_t flag_property(GDBusProxy *proxy, const char *name)
{
    GVariant *value = property(proxy, name);
    if (!value)
        return 0;
    uint8_t flag = g_variant_is_of_type(value, G_VARIANT_TYPE_BOOLEAN) && g_variant_get_boolean(value);
    g_variant_unref(value);
    return flag;
}

static void fill_drive(vol_monitor *m, const char *drive_path, vol_record *r)
{
    if (!drive_path[0] || strcmp(drive_path, "/") == 0)
        return;
    GDBusObject *drive = g_dbus_object_manager_get_object(m->manager, drive_path);
    if (!drive)
        return;
    GDBusProxy *proxy = interface_of(drive, UD_DRIVE);
    text_property(proxy, "ConnectionBus", r->bus, sizeof r->bus, 0);
    text_property(proxy, "Media", r->media, sizeof r->media, 0);
    r->removable = flag_property(proxy, "Removable");
    r->optical = flag_property(proxy, "Optical");
    if (proxy)
        g_object_unref(proxy);
    g_object_unref(drive);
}

static gboolean fill_record(vol_monitor *m, GDBusObject *object, vol_record *r)
{
    GDBusProxy *filesystem = interface_of(object, UD_FILESYSTEM);
    GDBusProxy *block = interface_of(object, UD_BLOCK);
    gboolean usable = filesystem && block;
    const char *path = g_dbus_object_get_object_path(object);
    if (usable && strlen(path) >= sizeof r->object)
        usable = FALSE; /* Cannot be addressed later. */
    if (usable) {
        copy_path(r->object, sizeof r->object, path);
        text_property(block, "Device", r->device, sizeof r->device, 1);
        text_property(block, "IdLabel", r->label, sizeof r->label, 0);
        text_property(block, "HintName", r->hint_name, sizeof r->hint_name, 0);
        text_property(block, "IdType", r->fstype, sizeof r->fstype, 0);
        r->hint_ignore = flag_property(block, "HintIgnore");
        r->hint_system = flag_property(block, "HintSystem");
        GVariant *size = property(block, "Size");
        if (size) {
            if (g_variant_is_of_type(size, G_VARIANT_TYPE_UINT64))
                r->size = g_variant_get_uint64(size);
            g_variant_unref(size);
        }
        char drive[160] = "";
        text_property(block, "Drive", drive, sizeof drive, 1);
        fill_drive(m, drive, r);
        GVariant *mounts = property(filesystem, "MountPoints");
        if (mounts && g_variant_is_of_type(mounts, G_VARIANT_TYPE("aay"))) {
            gsize n = 0;
            const gchar **list = g_variant_get_bytestring_array(mounts, &n);
            if (n > 0)
                copy_path(r->mount, sizeof r->mount, list[0]);
            g_free(list);
        }
        if (mounts)
            g_variant_unref(mounts);
    }
    if (filesystem)
        g_object_unref(filesystem);
    if (block)
        g_object_unref(block);
    return usable;
}

static int by_object(const void *a, const void *b)
{
    return strcmp(((const vol_record *)a)->object, ((const vol_record *)b)->object);
}

static void rebuild(vol_monitor *m)
{
    if (!m->manager)
        return;
    GList *objects = g_dbus_object_manager_get_objects(m->manager);
    size_t capacity = g_list_length(objects), n = 0;
    vol_record *records = capacity ? calloc(capacity, sizeof *records) : NULL;
    if (records) {
        for (GList *l = objects; l; l = l->next)
            if (fill_record(m, G_DBUS_OBJECT(l->data), &records[n]))
                n++;
        qsort(records, n, sizeof *records, by_object);
    }
    g_list_free_full(objects, g_object_unref);

    g_mutex_lock(&m->lock);
    /* The records are zero-filled before each copy, so equal lists compare equal. */
    if (n != m->count || (n > 0 && memcmp(records, m->records, n * sizeof *records) != 0)) {
        free(m->records);
        m->records = n > 0 ? records : NULL;
        m->count = n;
        m->dirty = 1;
        records = n > 0 ? NULL : records;
        wake(m);
    }
    g_mutex_unlock(&m->lock);
    free(records);
}

static gboolean rebuild_later(gpointer data)
{
    vol_monitor *m = data;
    m->rebuild_pending = FALSE;
    rebuild(m);
    return G_SOURCE_REMOVE;
}

static void schedule(vol_monitor *m)
{
    if (m->rebuild_pending)
        return;
    m->rebuild_pending = TRUE;
    GSource *source = g_timeout_source_new(REBUILD_DELAY_MS);
    g_source_set_callback(source, rebuild_later, m, NULL);
    g_source_attach(source, m->context);
    g_source_unref(source);
}

static void on_object(GDBusObjectManager *manager, GDBusObject *object, gpointer data)
{
    (void)manager;
    (void)object;
    schedule(data);
}

static void on_interface(GDBusObjectManager *manager, GDBusObject *object, GDBusInterface *iface, gpointer data)
{
    (void)manager;
    (void)object;
    (void)iface;
    schedule(data);
}

static void on_properties(GDBusObjectManagerClient *manager, GDBusObjectProxy *object, GDBusProxy *iface, GVariant *changed,
                          const gchar *const *invalidated, gpointer data)
{
    (void)manager;
    (void)object;
    (void)iface;
    (void)changed;
    (void)invalidated;
    schedule(data);
}

static void push_result(vol_monitor *m, const vol_result *result)
{
    vol_result *copy = malloc(sizeof *copy);
    if (!copy)
        return;
    *copy = *result;
    g_mutex_lock(&m->lock);
    g_queue_push_tail(&m->results, copy);
    wake(m);
    g_mutex_unlock(&m->lock);
}

static void finish_command(GObject *source, GAsyncResult *res, gpointer data)
{
    command *cmd = data;
    GError *error = NULL;
    GVariant *reply = g_dbus_proxy_call_finish(G_DBUS_PROXY(source), res, &error);
    vol_result result;
    memset(&result, 0, sizeof result);
    result.unmount = cmd->unmount;
    copy_path(result.object, sizeof result.object, cmd->object);
    if (reply) {
        result.ok = 1;
        if (!cmd->unmount && g_variant_is_of_type(reply, G_VARIANT_TYPE("(s)"))) {
            const char *path = NULL;
            g_variant_get(reply, "(&s)", &path);
            copy_path(result.path, sizeof result.path, path);
        }
        g_variant_unref(reply);
    } else {
        char *name = g_dbus_error_get_remote_error(error);
        copy_text(result.code, sizeof result.code, name);
        g_free(name);
        g_error_free(error);
    }
    push_result(cmd->m, &result);
    free(cmd);
}

static gboolean run_command(gpointer data)
{
    command *cmd = data;
    vol_monitor *m = cmd->m;
    GDBusProxy *filesystem = NULL;
    GDBusObject *object = m->manager ? g_dbus_object_manager_get_object(m->manager, cmd->object) : NULL;
    if (object) {
        filesystem = interface_of(object, UD_FILESYSTEM);
        g_object_unref(object);
    }
    if (!filesystem) {
        vol_result result;
        memset(&result, 0, sizeof result);
        result.unmount = cmd->unmount;
        copy_path(result.object, sizeof result.object, cmd->object);
        copy_text(result.code, sizeof result.code, "rediwm.Error.Gone");
        push_result(m, &result);
        free(cmd);
        return G_SOURCE_REMOVE;
    }
    GVariantBuilder options;
    g_variant_builder_init(&options, G_VARIANT_TYPE("a{sv}"));
    g_dbus_proxy_call(filesystem, cmd->unmount ? "Unmount" : "Mount", g_variant_new("(a{sv})", &options),
                      G_DBUS_CALL_FLAGS_ALLOW_INTERACTIVE_AUTHORIZATION, CALL_TIMEOUT_MS, NULL, finish_command, cmd);
    g_object_unref(filesystem); /* The call holds its own reference. */
    return G_SOURCE_REMOVE;
}

static gboolean quit_loop(gpointer data)
{
    g_main_loop_quit(data);
    return G_SOURCE_REMOVE;
}

static gpointer monitor_thread(gpointer data)
{
    vol_monitor *m = data;
    g_main_context_push_thread_default(m->context);

    GError *error = NULL;
    m->manager = g_dbus_object_manager_client_new_for_bus_sync(G_BUS_TYPE_SYSTEM, G_DBUS_OBJECT_MANAGER_CLIENT_FLAGS_NONE, UD_NAME,
                                                               UD_ROOT, NULL, NULL, NULL, NULL, &error);
    if (error)
        g_error_free(error);
    if (m->manager) {
        g_signal_connect(m->manager, "object-added", G_CALLBACK(on_object), m);
        g_signal_connect(m->manager, "object-removed", G_CALLBACK(on_object), m);
        g_signal_connect(m->manager, "interface-added", G_CALLBACK(on_interface), m);
        g_signal_connect(m->manager, "interface-removed", G_CALLBACK(on_interface), m);
        g_signal_connect(m->manager, "interface-proxy-properties-changed", G_CALLBACK(on_properties), m);
        rebuild(m);
    }
    /* Runs even without UDisks2, so mount requests are answered and a stop
     * request always has a loop to end. */
    g_main_loop_run(m->loop);

    g_clear_object(&m->manager);
    g_main_context_pop_thread_default(m->context);
    g_main_loop_unref(m->loop);
    g_main_context_unref(m->context);
    free(m->records);
    for (gpointer item; (item = g_queue_pop_head(&m->results));)
        free(item);
    g_mutex_clear(&m->lock);
    close(m->wake_fd);
    free(m);
    return NULL;
}

vol_monitor *vol_start(void)
{
    vol_monitor *m = calloc(1, sizeof *m);
    if (!m)
        return NULL;
    m->wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (m->wake_fd < 0) {
        free(m);
        return NULL;
    }
    g_mutex_init(&m->lock);
    g_queue_init(&m->results);
    m->context = g_main_context_new();
    m->loop = g_main_loop_new(m->context, FALSE);
    GThread *thread = g_thread_try_new("rediwm-volumes", monitor_thread, m, NULL);
    if (!thread) {
        g_main_loop_unref(m->loop);
        g_main_context_unref(m->context);
        g_mutex_clear(&m->lock);
        close(m->wake_fd);
        free(m);
        return NULL;
    }
    g_thread_unref(thread); /* Never joined. */
    return m;
}

int vol_wake_fd(const vol_monitor *m)
{
    return m->wake_fd;
}

void vol_clear_wake(vol_monitor *m)
{
    uint64_t count;
    ssize_t got = read(m->wake_fd, &count, sizeof count);
    (void)got; /* EAGAIN: nothing was pending. */
}

int vol_take(vol_monitor *m, vol_record **out, size_t *count)
{
    int changed = 0;
    *out = NULL;
    *count = 0;
    g_mutex_lock(&m->lock);
    if (m->dirty) {
        changed = 1;
        m->dirty = 0;
        *count = m->count;
        if (m->count > 0) {
            *out = malloc(m->count * sizeof **out);
            if (*out)
                memcpy(*out, m->records, m->count * sizeof **out);
            else
                *count = 0;
        }
    }
    g_mutex_unlock(&m->lock);
    return changed;
}

static void submit(vol_monitor *m, const char *object, int unmount)
{
    command *cmd = calloc(1, sizeof *cmd);
    if (!cmd)
        return;
    cmd->m = m;
    cmd->unmount = unmount;
    copy_path(cmd->object, sizeof cmd->object, object);
    g_main_context_invoke(m->context, run_command, cmd);
}

void vol_mount(vol_monitor *m, const char *object)
{
    submit(m, object, 0);
}

void vol_unmount(vol_monitor *m, const char *object)
{
    submit(m, object, 1);
}

int vol_next_result(vol_monitor *m, vol_result *out)
{
    g_mutex_lock(&m->lock);
    vol_result *next = g_queue_pop_head(&m->results);
    g_mutex_unlock(&m->lock);
    if (!next)
        return 0;
    *out = *next;
    free(next);
    return 1;
}

void vol_stop(vol_monitor *m)
{
    g_main_context_invoke(m->context, quit_loop, m->loop);
}
