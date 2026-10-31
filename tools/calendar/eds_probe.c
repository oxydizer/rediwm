/* Noninstalled Phase 0 probe. Run only through the private-bus harness.
 * This checks EDS's local store, not OAuth, provider sync or offline remote writes.
 * Blocking client calls are intentional in this disposable CLI process.
 */
#define _POSIX_C_SOURCE 200809L
#include <libecal/libecal.h>
#include <libedataserver/libedataserver.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define SOURCE_UID "rediwm-calendar-phase0-local"
#define EVENT_UID "rediwm-calendar-phase0-recurring"
#define ORIGINAL_TIME "20261031T090000Z"
#define MOVED_TIME "20261031T120000Z"

static const char master_text[] =
    "BEGIN:VEVENT\r\n"
    "UID:" EVENT_UID "\r\n"
    "DTSTAMP:20261001T000000Z\r\n"
    "DTSTART:20261030T090000Z\r\n"
    "DTEND:20261030T100000Z\r\n"
    "RRULE:FREQ=DAILY;COUNT=3\r\n"
    "SUMMARY:Phase 0 original series\r\n"
    "END:VEVENT\r\n";

static const char exception_text[] =
    "BEGIN:VEVENT\r\n"
    "UID:" EVENT_UID "\r\n"
    "DTSTAMP:20261001T000000Z\r\n"
    "RECURRENCE-ID:" ORIGINAL_TIME "\r\n"
    "DTSTART:" MOVED_TIME "\r\n"
    "DTEND:20261031T130000Z\r\n"
    "SUMMARY:Phase 0 moved occurrence\r\n"
    "END:VEVENT\r\n";

static void fail(const char *stage, GError *error) {
    /* Errors are from a synthetic local fixture, never provider responses. */
    fprintf(stderr, "EDS local probe: %s: %s\n", stage,
            error ? error->message : "check failed");
    g_clear_error(&error);
    exit(EXIT_FAILURE);
}

static void require_private_environment(const char *root) {
    static const char *names[] = {
        "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"
    };
    struct stat info;
    size_t length = strlen(root);
    if (!g_path_is_absolute(root) || length < 2 || root[length - 1] == '/' ||
        lstat(root, &info) != 0 || !S_ISDIR(info.st_mode) ||
        info.st_uid != getuid() || (info.st_mode & 077) != 0)
        fail("private root must be an owned mode-0700 directory", NULL);
    for (size_t index = 0; index < G_N_ELEMENTS(names); index++) {
        const char *value = g_getenv(names[index]);
        if (!value || strncmp(value, root, length) != 0 || value[length] != '/' ||
            strstr(value + length, "/../") || g_str_has_suffix(value, "/..") ||
            lstat(value, &info) != 0 || !S_ISDIR(info.st_mode) ||
            info.st_uid != getuid() || (info.st_mode & 077) != 0)
            fail("HOME and XDG paths must be private directories beneath root", NULL);
    }
    gchar *address = g_strdup_printf("unix:path=%s/bus", root);
    const char *actual = g_getenv("DBUS_SESSION_BUS_ADDRESS");
    gboolean valid = actual &&
        (g_strcmp0(actual, address) == 0 ||
         (g_str_has_prefix(actual, address) &&
          g_str_has_prefix(actual + strlen(address), ",guid=") &&
          !strchr(actual, ';')));
    g_free(address);
    if (!valid) fail("session bus must be the harness's private root/bus", NULL);
}

static ESource *open_source(ESourceRegistry *registry, gboolean writing) {
    GError *error = NULL;
    ESource *source = e_source_registry_ref_source(registry, SOURCE_UID);
    if (!writing) {
        if (!source) fail("source did not survive service restart", NULL);
        return source;
    }
    if (source) fail("write requires a fresh private store", NULL);
    source = e_source_new_with_uid(SOURCE_UID, NULL, &error);
    if (!source) fail("create source", error);
    e_source_set_display_name(source, "RediWM Phase 0 synthetic local calendar");
    e_source_set_enabled(source, TRUE);
    ESourceBackend *backend = E_SOURCE_BACKEND(
        e_source_get_extension(source, E_SOURCE_EXTENSION_CALENDAR));
    e_source_backend_set_backend_name(backend, "local");
    if (!e_source_registry_commit_source_sync(registry, source, NULL, &error))
        fail("persist source", error);
    return source;
}

static void write_events(ECalClient *client) {
    GError *error = NULL;
    gchar *uid = NULL;
    ICalComponent *master = i_cal_component_new_from_string(master_text);
    if (!master) fail("parse master fixture", NULL);
    if (!e_cal_client_create_object_sync(client, master, E_CAL_OPERATION_FLAG_NONE,
                                         &uid, NULL, &error))
        fail("create recurring event", error);
    if (g_strcmp0(uid, EVENT_UID) != 0) fail("local backend changed fixture UID", NULL);
    g_free(uid);
    i_cal_component_set_summary(master, "Phase 0 edited series");
    if (!e_cal_client_modify_object_sync(client, master, E_CAL_OBJ_MOD_ALL,
                                         E_CAL_OPERATION_FLAG_NONE, NULL, &error))
        fail("edit whole series", error);
    g_object_unref(master);
    ICalComponent *exception = i_cal_component_new_from_string(exception_text);
    if (!exception) fail("parse exception fixture", NULL);
    if (!e_cal_client_modify_object_sync(client, exception, E_CAL_OBJ_MOD_THIS,
                                         E_CAL_OPERATION_FLAG_NONE, NULL, &error))
        fail("move one occurrence", error);
    g_object_unref(exception);
}

static void check_time(ICalTime *time, const char *expected) {
    if (!time) fail("missing occurrence time", NULL);
    gchar *actual = i_cal_time_as_ical_string(time);
    gboolean matches = g_strcmp0(actual, expected) == 0;
    g_free(actual);
    g_object_unref(time);
    if (!matches) fail("occurrence time or original identity changed", NULL);
}

static void read_events(ECalClient *client) {
    GError *error = NULL;
    ICalComponent *master = NULL;
    ICalComponent *exception = NULL;
    if (!e_cal_client_get_object_sync(client, EVENT_UID, NULL, &master, NULL, &error))
        fail("read recurring master", error);
    if (g_strcmp0(i_cal_component_get_summary(master), "Phase 0 edited series") != 0)
        fail("series edit did not persist", NULL);
    ICalProperty *rule = i_cal_component_get_first_property(master, I_CAL_RRULE_PROPERTY);
    if (!rule) fail("recurrence rule missing", NULL);
    ICalRecurrence *recurrence = i_cal_property_get_rrule(rule);
    if (!recurrence || i_cal_recurrence_get_count(recurrence) != 3)
        fail("recurrence count changed", NULL);
    g_object_unref(recurrence);
    g_object_unref(rule);
    g_object_unref(master);
    if (!e_cal_client_get_object_sync(client, EVENT_UID, ORIGINAL_TIME,
                                      &exception, NULL, &error))
        fail("read moved occurrence by original identity", error);
    if (g_strcmp0(i_cal_component_get_summary(exception), "Phase 0 moved occurrence") != 0)
        fail("exception edit did not persist", NULL);
    check_time(i_cal_component_get_recurrenceid(exception), ORIGINAL_TIME);
    check_time(i_cal_component_get_dtstart(exception), MOVED_TIME);
    g_object_unref(exception);
}

int main(int argc, char **argv) {
    if (argc != 3 || (strcmp(argv[1], "write") != 0 && strcmp(argv[1], "read") != 0)) {
        fputs("usage: eds-probe write|read PRIVATE_ROOT\n", stderr);
        return EXIT_FAILURE;
    }
    require_private_environment(argv[2]);
    gboolean writing = strcmp(argv[1], "write") == 0;
    GError *error = NULL;
    ESourceRegistry *registry = e_source_registry_new_sync(NULL, &error);
    if (!registry) fail("connect private source registry", error);
    ESource *source = open_source(registry, writing);
    /* EDS's documented -1 sentinel skips waiting for remote connectivity. */
    EClient *base = e_cal_client_connect_sync(source, E_CAL_CLIENT_SOURCE_TYPE_EVENTS,
                                             G_MAXUINT32, NULL, &error);
    if (!base) fail("connect local calendar", error);
    ECalClient *client = E_CAL_CLIENT(base);
    if (writing) write_events(client);
    read_events(client);
    printf("{\"status\":\"pass\",\"scope\":\"eds_local_store\",\"stage\":\"%s\","
           "\"series_edit\":true,\"moved_occurrence\":true,"
           "\"provider_qualification\":false}\n", argv[1]);
    g_object_unref(base);
    g_object_unref(source);
    g_object_unref(registry);
    return EXIT_SUCCESS;
}
