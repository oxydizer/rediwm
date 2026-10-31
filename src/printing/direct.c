#define _GNU_SOURCE
#include "direct.h"
#include <cups/cups.h>
#include <cups/adminutil.h>
#include <cups/ppd.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

/* The worker is the only thread using libcups. Its default server and password
 * callback are thread-local. No subprocess, elevated uid, or host fallback. */
struct rediwm_cups {
    pthread_t thread, watchdog;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int fd, state, result, queued, reset, close_idle, password_ready;
    atomic_int stop, cancelled;
    char *method, *args[68];
    int argc, active_fd, timeout_sent;
    http_t *http;
    double deadline;
    int attempts;
    char user[256];
    char *password; /* One locked page, wiped after a logical operation. */
    char *devices[128][5];
    int count, overflow;
};
static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static void wake(struct rediwm_cups *w) {
    uint64_t one = 1;
    ssize_t n = write(w->fd, &one, sizeof(one));
    (void)n;
}
static int timeout_cb(http_t *http, void *data) {
    struct rediwm_cups *w = data;
    pthread_mutex_lock(&w->mutex);
    int fd = fcntl(httpGetFd(http), F_DUPFD_CLOEXEC, 0);
    if (w->active_fd >= 0) close(w->active_fd);
    w->active_fd = fd;
    pthread_cond_broadcast(&w->condition);
    pthread_mutex_unlock(&w->mutex);
    return !atomic_load(&w->stop) && !atomic_load(&w->cancelled) && now() < w->deadline;
}
static const char *password_cb(const char *prompt, http_t *http,
                               const char *method, const char *resource, void *data) {
    (void)prompt; (void)http; (void)method; (void)resource;
    struct rediwm_cups *w = data;
    pthread_mutex_lock(&w->mutex);
    explicit_bzero(w->password, 4096);
    if (++w->attempts > 3 || atomic_load(&w->stop) || atomic_load(&w->cancelled)) {
        pthread_mutex_unlock(&w->mutex);
        return NULL;
    }
    w->password_ready = 0;
    w->state = 1;
    wake(w);
    pthread_cond_broadcast(&w->condition);
    struct timespec end;
    clock_gettime(CLOCK_MONOTONIC, &end);
    end.tv_sec += 120;
    while (!w->password_ready && !atomic_load(&w->stop) && !atomic_load(&w->cancelled)) {
        if (pthread_cond_timedwait(&w->condition, &w->mutex, &end) == ETIMEDOUT) {
            atomic_store(&w->cancelled, 1);
            break;
        }
    }
    w->state = 0;
    w->deadline = now() + 20;
    int ok = w->password_ready && !atomic_load(&w->stop) && !atomic_load(&w->cancelled);
    if (ok) cupsSetUser(w->user);
    pthread_mutex_unlock(&w->mutex);
    return ok ? w->password : NULL;
}
static ipp_t *request(ipp_op_t op, const char *name) {
    ipp_t *r = ippNewRequest(op);
    char uri[1024];
    if (name) {
        httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof(uri), "ipp", NULL, "localhost", 0, "/printers/%s", name);
        ippAddString(r, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, uri);
    }
    ippAddString(r, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, cupsUser());
    return r;
}
static int prepare(struct rediwm_cups *w) {
    if (atomic_load(&w->stop) || atomic_load(&w->cancelled) || now() >= w->deadline) return 0;
    if (httpGetFd(w->http) < 0 && httpReconnect2(w->http, 1000, NULL)) return 0;
    return timeout_cb(w->http, w);
}
static int send_request(struct rediwm_cups *w, ipp_t *r, const char *file) {
    if (!prepare(w)) { ippDelete(r); return 1; }
    ipp_t *reply = file ? cupsDoFileRequest(w->http, r, "/admin/", file) : cupsDoRequest(w->http, r, "/admin/");
    int failed = !reply || ippGetStatusCode(reply) > IPP_STATUS_OK_EVENTS_COMPLETE;
    ippDelete(reply);
    return failed;
}
static void devices_clear(struct rediwm_cups *w) {
    for (int i = 0; i < w->count; i++) for (int j = 0; j < 5; j++) {
        free(w->devices[i][j]); w->devices[i][j] = NULL;
    }
    w->count = w->overflow = 0;
}
static void device_cb(const char *kind, const char *id, const char *info,
                      const char *model, const char *uri, const char *location, void *data) {
    (void)location;
    struct rediwm_cups *w = data;
    if (w->count >= 128) { w->overflow = 1; return; }
    const char *values[] = {uri, info, model, id, kind};
    int n = w->count++;
    for (int j = 0; j < 5; j++) {
        const char *v = values[j] ? values[j] : "";
        if (strlen(v) > 8192 || !(w->devices[n][j] = strdup(v))) w->overflow = 1;
    }
}
/* Rewrite only a declared PPD default. Values were validated in Zig; using
 * the PPD parser ensures custom sizes and PageSize/PageRegion stay consistent. */
static int ppd_option(struct rediwm_cups *w, const char *name, const char *key, const char *value) {
    if (!prepare(w)) return 1;
    const char *download = cupsGetPPD2(w->http, name);
    if (!download) return 1;
    char path[1024];
    snprintf(path, sizeof(path), "%s", download);
    struct stat st;
    if (stat(path, &st) || !S_ISREG(st.st_mode) || st.st_size > 4 * 1024 * 1024) { unlink(path); return 1; }
    ppd_file_t *ppd = ppdOpenFile(path);
    if (!ppd) { unlink(path); return 1; }
    ppdMarkDefaults(ppd);
    ppd_option_t *option = ppdFindOption(ppd, key);
    if (!option || (!ppdFindChoice(option, value) && strncmp(value, "Custom.", 7))) {
        ppdClose(ppd); unlink(path); return 1;
    }
    if (ppdMarkOption(ppd, key, value)) { ppdClose(ppd); unlink(path); return 1; }
    char output[] = "/tmp/rediwm-cups-XXXXXX";
    int fd = mkostemp(output, O_CLOEXEC);
    FILE *out = fd >= 0 ? fdopen(fd, "w") : NULL;
    FILE *in = fopen(path, "re");
    int failed = !out || !in;
    if (out && in) {
        char *line = NULL;
        size_t cap = 0, total = 0;
        ssize_t len;
        while ((len = getline(&line, &cap, in)) >= 0) {
            total += (size_t)len;
            if (total > 4 * 1024 * 1024) { failed = 1; break; }
            char keyword[128];
            if (sscanf(line, "*Default%127[^:]:", keyword) == 1) {
                int size_default = !strcmp(keyword, "PageSize") || !strcmp(keyword, "PageRegion") ||
                    !strcmp(keyword, "PaperDimension") || !strcmp(keyword, "ImageableArea");
                ppd_choice_t *choice = ppdFindMarkedChoice(ppd, size_default ? "PageSize" : keyword);
                if (!choice && size_default) choice = ppdFindMarkedChoice(ppd, "PageRegion");
                if (choice) {
                    const char *selected = choice->choice;
                    if (!strcmp(selected, "Custom")) {
                        if (!strcmp(keyword, key) || (size_default && (!strcmp(key, "PageSize") || !strcmp(key, "PageRegion")))) selected = value;
                        else { fputs(line, out); continue; }
                    }
                    fprintf(out, "*Default%s: %s\n", keyword, selected);
                    continue;
                }
            }
            if (fwrite(line, 1, (size_t)len, out) != (size_t)len) { failed = 1; break; }
        }
        if (ferror(in)) failed = 1;
        free(line);
    }
    if (in) fclose(in);
    if (out) { if (fclose(out)) failed = 1; } else if (fd >= 0) close(fd);
    ppdClose(ppd);
    unlink(path);
    if (!failed) failed = send_request(w, request(IPP_OP_CUPS_ADD_MODIFY_PRINTER, name), output);
    unlink(output);
    return failed;
}
static ipp_t *get_printer(struct rediwm_cups *w, const char *name) {
    if (!prepare(w)) return NULL;
    return cupsDoRequest(w->http, request(IPP_OP_GET_PRINTER_ATTRIBUTES, name), "/");
}
/* Do not silently detach a queue from a CUPS class. Class membership editing
 * is outside this page's model; refuse this rename before creating anything. */
static int class_member(struct rediwm_cups *w, const char *name) {
    if (!prepare(w)) return -1;
    ipp_t *classes = cupsDoRequest(w->http, request(IPP_OP_CUPS_GET_CLASSES, NULL), "/");
    if (!classes) return -1;
    ipp_status_t status = ippGetStatusCode(classes);
    if (status == IPP_STATUS_ERROR_NOT_FOUND) { ippDelete(classes); return 0; }
    if (status > IPP_STATUS_OK_EVENTS_COMPLETE) { ippDelete(classes); return -1; }
    int member = 0;
    for (ipp_attribute_t *attr = ippFirstAttribute(classes); attr; attr = ippNextAttribute(classes)) {
        const char *key = ippGetName(attr);
        if (!key || strcmp(key, "member-names") || ippGetValueTag(attr) != IPP_TAG_NAME) continue;
        for (int i = 0; i < ippGetCount(attr); i++) {
            const char *value = ippGetString(attr, i, NULL);
            if (value && !strcasecmp(value, name)) member = 1;
        }
    }
    ippDelete(classes);
    return member;
}
/* CUPS has no rename transaction. Recheck names/jobs, clone settings and PPD,
 * then delete only after the new queue has been accepted. Never roll back an
 * uncertain creation: the page refreshes both identities and reports partial. */
static int rename_printer(struct rediwm_cups *w, const char *old, const char *name) {
    int membership = class_member(w, old);
    if (membership) return membership > 0 ? 5 : 1;
    ipp_t *existing = get_printer(w, name);
    int absent = existing && ippGetStatusCode(existing) == IPP_STATUS_ERROR_NOT_FOUND;
    ippDelete(existing);
    if (!absent) return 1;
    ipp_t *jobs = request(IPP_OP_GET_JOBS, old);
    ippAddString(jobs, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "which-jobs", NULL, "not-completed");
    if (!prepare(w)) { ippDelete(jobs); return 1; }
    ipp_t *reply = cupsDoRequest(w->http, jobs, "/");
    int blocked = !reply || ippGetStatusCode(reply) > IPP_STATUS_OK_EVENTS_COMPLETE || ippFindAttribute(reply, "job-id", IPP_TAG_INTEGER);
    ippDelete(reply);
    if (blocked) return 1;
    ipp_t *source = get_printer(w, old);
    if (!source || ippGetStatusCode(source) > IPP_STATUS_OK_EVENTS_COMPLETE) { ippDelete(source); return 1; }
    ipp_t *add = request(IPP_OP_CUPS_ADD_MODIFY_PRINTER, name);
    const char *copy[] = {"device-uri", "printer-info", "printer-location", "printer-is-shared", "printer-error-policy", "printer-op-policy", "requesting-user-name-allowed", "requesting-user-name-denied", "job-quota-period", "job-k-limit", "job-page-limit", "port-monitor"};
    for (ipp_attribute_t *attr = ippFirstAttribute(source); attr; attr = ippNextAttribute(source)) {
        const char *key = ippGetName(attr);
        if (!key || ippGetGroupTag(attr) != IPP_TAG_PRINTER) continue;
        size_t len = strlen(key);
        int keep = len > 8 && !strcmp(key + len - 8, "-default");
        for (size_t i = 0; i < sizeof(copy)/sizeof(copy[0]); i++) if (!strcmp(key, copy[i])) keep = 1;
        if (keep) ippCopyAttribute(add, attr, 0);
    }
    ipp_attribute_t *state = ippFindAttribute(source, "printer-state", IPP_TAG_ENUM);
    ipp_attribute_t *accepting = ippFindAttribute(source, "printer-is-accepting-jobs", IPP_TAG_BOOLEAN);
    ipp_attribute_t *type = ippFindAttribute(source, "printer-type", IPP_TAG_ENUM);
    int enabled = state && ippGetInteger(state, 0) != IPP_PSTATE_STOPPED;
    int accept = accepting && ippGetBoolean(accepting, 0);
    int is_default = type && (ippGetInteger(type, 0) & CUPS_PRINTER_DEFAULT);
    ippDelete(source);
    if (!prepare(w)) { ippDelete(add); return 1; }
    const char *download = cupsGetPPD2(w->http, old);
    char path[1024] = "";
    if (download) snprintf(path, sizeof(path), "%s", download);
    else if (cupsLastError() != IPP_STATUS_ERROR_NOT_FOUND) { ippDelete(add); return 1; }
    struct stat st;
    if (*path && (stat(path, &st) || !S_ISREG(st.st_mode) || st.st_size > 4 * 1024 * 1024)) { unlink(path); ippDelete(add); return 1; }
    int failed = send_request(w, add, *path ? path : NULL);
    if (*path) unlink(path);
    if (failed) return 4;
    if (enabled && send_request(w, request(IPP_OP_RESUME_PRINTER, name), NULL)) return 4;
    if (accept && send_request(w, request(IPP_OP_CUPS_ACCEPT_JOBS, name), NULL)) return 4;
    if (is_default && send_request(w, request(IPP_OP_CUPS_SET_DEFAULT, name), NULL)) return 4;
    ipp_t *created = get_printer(w, name);
    int verified = created && ippGetStatusCode(created) <= IPP_STATUS_OK_EVENTS_COMPLETE &&
        ippFindAttribute(created, "printer-name", IPP_TAG_NAME);
    ippDelete(created);
    if (!verified) return 4;
    jobs = request(IPP_OP_GET_JOBS, old);
    ippAddString(jobs, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "which-jobs", NULL, "not-completed");
    if (!prepare(w)) { ippDelete(jobs); return 4; }
    reply = cupsDoRequest(w->http, jobs, "/");
    blocked = !reply || ippGetStatusCode(reply) > IPP_STATUS_OK_EVENTS_COMPLETE || ippFindAttribute(reply, "job-id", IPP_TAG_INTEGER);
    ippDelete(reply);
    if (blocked) return 4;
    if (send_request(w, request(IPP_OP_CUPS_DELETE_PRINTER, old), NULL)) return 4;
    return 0;
}
static int execute(struct rediwm_cups *w) {
    const char *m = w->method, *name = w->argc ? w->args[0] : NULL;
    if (!strcmp(m, "DevicesGet")) {
        devices_clear(w);
        int result = cupsGetDevices(w->http, 10, NULL, "file,smb,smbs,pdf,pipe,exec,command,beh,hpfax,mailto", device_cb, w);
        return result > IPP_STATUS_OK_EVENTS_COMPLETE || w->overflow;
    }
    if (!strcmp(m, "PrinterRename")) return rename_printer(w, name, w->args[1]);
    if (!strcmp(m, "PrinterAddOption")) return w->argc == 3 ? ppd_option(w, name, w->args[1], w->args[2]) : 1;
    ipp_op_t op = IPP_OP_CUPS_ADD_MODIFY_PRINTER;
    if (!strcmp(m, "PrinterDelete")) op = IPP_OP_CUPS_DELETE_PRINTER;
    else if (!strcmp(m, "PrinterSetDefault")) op = IPP_OP_CUPS_SET_DEFAULT;
    else if (!strcmp(m, "PrinterSetEnabled")) op = !strcmp(w->args[1], "true") ? IPP_OP_RESUME_PRINTER : IPP_OP_PAUSE_PRINTER;
    else if (!strcmp(m, "PrinterSetAcceptJobs")) op = !strcmp(w->args[1], "true") ? IPP_OP_CUPS_ACCEPT_JOBS : IPP_OP_CUPS_REJECT_JOBS;
    ipp_t *r = request(op, name);
    if (!strcmp(m, "PrinterAdd")) {
        /* Check again at the worker boundary; ADD_MODIFY itself is an upsert. */
        ipp_t *existing = get_printer(w, name);
        int absent = existing && ippGetStatusCode(existing) == IPP_STATUS_ERROR_NOT_FOUND;
        ippDelete(existing);
        if (!absent) { ippDelete(r); return 1; }
        ippAddString(r, IPP_TAG_PRINTER, IPP_TAG_URI, "device-uri", NULL, w->args[1]);
        ippAddString(r, IPP_TAG_PRINTER, IPP_TAG_NAME, "ppd-name", NULL, w->args[2]);
        ippAddString(r, IPP_TAG_PRINTER, IPP_TAG_TEXT, "printer-info", NULL, w->args[3]);
        ippAddString(r, IPP_TAG_PRINTER, IPP_TAG_TEXT, "printer-location", NULL, w->args[4]);
    } else if (!strcmp(m, "PrinterSetInfo")) ippAddString(r, IPP_TAG_PRINTER, IPP_TAG_TEXT, "printer-info", NULL, w->args[1]);
    else if (!strcmp(m, "PrinterSetDevice")) ippAddString(r, IPP_TAG_PRINTER, IPP_TAG_URI, "device-uri", NULL, w->args[1]);
    else if (!strcmp(m, "PrinterDeleteOptionDefault")) {
        char key[256];
        snprintf(key, sizeof(key), "%s-default", w->args[1]);
        ippAddOutOfBand(r, IPP_TAG_PRINTER, IPP_TAG_DELETEATTR, key);
    } else if (!strcmp(m, "PrinterAddOptionDefault")) {
        char key[256], value[65536] = "";
        snprintf(key, sizeof(key), "%s-default", w->args[1]);
        for (int i = 2; i < w->argc; i++) {
            if (i > 2) strcat(value, ",");
            if (strlen(value) + strlen(w->args[i]) >= sizeof(value)) { ippDelete(r); return 1; }
            strcat(value, w->args[i]);
        }
        cups_option_t *options = NULL;
        int count = cupsAddOption(key, value, 0, &options);
        cupsEncodeOptions2(r, count, options, IPP_TAG_PRINTER);
        cupsFreeOptions(count, options);
    }
    return send_request(w, r, NULL);
}
/* The local daemon's socket: /run/cups on most Linux systems, /var/run/cups
 * elsewhere (FreeBSD). The first when neither exists yet; probed on every
 * connect, since the daemon may start after the worker. */
static const char *local_socket(void) {
    static const char *const paths[] = {"/run/cups/cups.sock", "/var/run/cups/cups.sock"};
    struct stat st;
    for (size_t i = 0; i < sizeof paths / sizeof paths[0]; i++)
        if (!stat(paths[i], &st) && S_ISSOCK(st.st_mode)) return paths[i];
    return paths[0];
}
static void close_connection(struct rediwm_cups *w) {
    if (w->active_fd >= 0) close(w->active_fd);
    w->active_fd = -1;
    if (w->http) { httpClose(w->http); w->http = NULL; }
    explicit_bzero(w->password, 4096);
    w->attempts = 0;
    cupsSetUser(NULL);
}
static void *run(void *data) {
    struct rediwm_cups *w = data;
    pthread_setname_np(pthread_self(), "rediwm-cups");
    cupsSetServer(local_socket());
    cupsSetPasswordCB2(password_cb, w);
    pthread_mutex_lock(&w->mutex);
    while (!atomic_load(&w->stop)) {
        while (!w->queued && !w->close_idle && !atomic_load(&w->stop)) pthread_cond_wait(&w->condition, &w->mutex);
        if (atomic_load(&w->stop)) break;
        if (w->reset || w->close_idle) { close_connection(w); w->reset = w->close_idle = 0; }
        if (!w->queued) continue;
        w->queued = 0;
        w->deadline = now() + 20;
        pthread_mutex_unlock(&w->mutex);
        if (!w->http) {
            const char *path = local_socket();
            cupsSetServer(path);
            w->http = httpConnect2(path, 631, NULL, AF_UNIX, HTTP_ENCRYPTION_NEVER, 1, 1000, NULL);
        }
        int result = 1;
        if (w->http) {
            pthread_mutex_lock(&w->mutex);
            if (w->active_fd >= 0) close(w->active_fd);
            w->active_fd = fcntl(httpGetFd(w->http), F_DUPFD_CLOEXEC, 0);
            pthread_cond_broadcast(&w->condition);
            pthread_mutex_unlock(&w->mutex);
            httpSetTimeout(w->http, 0.2, timeout_cb, w);
            result = execute(w);
        }
        pthread_mutex_lock(&w->mutex);
        w->result = atomic_load(&w->cancelled) ? 2 : result;
        if (result && w->attempts >= 3) w->result = 3;
        w->state = 2;
        pthread_cond_broadcast(&w->condition);
        wake(w);
    }
    close_connection(w);
    pthread_mutex_unlock(&w->mutex);
    return NULL;
}
/* An absolute deadline also stops a peer that drip-feeds bytes and therefore
 * never triggers libcups' inactivity timeout. This thread sleeps on a condition
 * with no deadline when idle or awaiting user input. */
static void *watchdog(void *data) {
    struct rediwm_cups *w = data;
    pthread_setname_np(pthread_self(), "rediwm-cups-io");
    pthread_mutex_lock(&w->mutex);
    while (!atomic_load(&w->stop)) {
        if (w->state != 0 || w->active_fd < 0 || w->timeout_sent) {
            pthread_cond_wait(&w->condition, &w->mutex);
            continue;
        }
        struct timespec end = { .tv_sec = (time_t)w->deadline,
            .tv_nsec = (long)((w->deadline - (time_t)w->deadline) * 1e9) };
        if (pthread_cond_timedwait(&w->condition, &w->mutex, &end) == ETIMEDOUT &&
            w->state == 0 && w->active_fd >= 0 && now() >= w->deadline) {
            w->timeout_sent = 1;
            shutdown(w->active_fd, SHUT_RDWR);
        }
    }
    pthread_mutex_unlock(&w->mutex);
    return NULL;
}
struct rediwm_cups *rediwm_cups_create(void) {
    struct rediwm_cups *w = calloc(1, sizeof(*w));
    if (!w) return NULL;
    w->password = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (w->password == MAP_FAILED) { free(w); return NULL; }
    if (mlock(w->password, 4096)) { munmap(w->password, 4096); free(w); return NULL; }
    madvise(w->password, 4096, MADV_DONTDUMP);
    w->fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (w->fd < 0) goto fail;
    if (pthread_mutex_init(&w->mutex, NULL)) goto fail_fd;
    pthread_condattr_t attr;
    pthread_condattr_init(&attr);
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
    int err = pthread_cond_init(&w->condition, &attr);
    pthread_condattr_destroy(&attr);
    if (err) goto fail_mutex;
    w->state = 2;
    w->active_fd = -1;
    if (pthread_create(&w->thread, NULL, run, w)) goto fail_condition;
    if (pthread_create(&w->watchdog, NULL, watchdog, w)) {
        atomic_store(&w->stop, 1);
        pthread_mutex_lock(&w->mutex);
        pthread_cond_broadcast(&w->condition);
        pthread_mutex_unlock(&w->mutex);
        pthread_join(w->thread, NULL);
        goto fail_condition;
    }
    return w;
fail_condition: pthread_cond_destroy(&w->condition);
fail_mutex: pthread_mutex_destroy(&w->mutex);
fail_fd: close(w->fd);
fail: munlock(w->password, 4096); munmap(w->password, 4096); free(w); return NULL;
}
void rediwm_cups_cancel(struct rediwm_cups *w) {
    atomic_store(&w->cancelled, 1);
    pthread_mutex_lock(&w->mutex);
    if (w->active_fd >= 0) shutdown(w->active_fd, SHUT_RDWR);
    pthread_cond_broadcast(&w->condition);
    pthread_mutex_unlock(&w->mutex);
}
void rediwm_cups_destroy(struct rediwm_cups *w) {
    atomic_store(&w->stop, 1);
    rediwm_cups_cancel(w);
    pthread_join(w->thread, NULL);
    pthread_join(w->watchdog, NULL);
    free(w->method);
    for (int i = 0; i < w->argc; i++) free(w->args[i]);
    devices_clear(w);
    close(w->fd);
    pthread_cond_destroy(&w->condition);
    pthread_mutex_destroy(&w->mutex);
    munlock(w->password, 4096); munmap(w->password, 4096);
    free(w);
}
int rediwm_cups_fd(struct rediwm_cups *w) { return w->fd; }
int rediwm_cups_state(struct rediwm_cups *w) {
    pthread_mutex_lock(&w->mutex); int state = w->state; pthread_mutex_unlock(&w->mutex); return state;
}
int rediwm_cups_result(struct rediwm_cups *w) { return w->result; }
const char *rediwm_cups_device(struct rediwm_cups *w, int i, int field) {
    return i < w->count && field < 5 ? w->devices[i][field] : NULL;
}
int rediwm_cups_submit(struct rediwm_cups *w, const char *method, int argc, const char *const *args, int reset) {
    if (argc < 0 || argc > 68) return -1;
    char *m = strdup(method), *copy[68] = {0};
    int ok = m != NULL;
    for (int i = 0; i < argc; i++) if (!(copy[i] = strdup(args[i]))) ok = 0;
    if (!ok) { free(m); for (int i = 0; i < argc; i++) free(copy[i]); return -1; }
    pthread_mutex_lock(&w->mutex);
    if (w->state != 2) {
        pthread_mutex_unlock(&w->mutex);
        free(m);
        for (int i = 0; i < argc; i++) free(copy[i]);
        return -1;
    }
    free(w->method); w->method = m;
    for (int i = 0; i < w->argc; i++) free(w->args[i]);
    memcpy(w->args, copy, sizeof(copy)); w->argc = argc;
    w->state = 0; w->queued = 1; w->reset = reset; w->timeout_sent = 0;
    w->deadline = now() + 20;
    atomic_store(&w->cancelled, 0);
    pthread_cond_broadcast(&w->condition);
    pthread_mutex_unlock(&w->mutex);
    return 0;
}
void rediwm_cups_credentials(struct rediwm_cups *w, const char *user, const char *password, unsigned long len) {
    pthread_mutex_lock(&w->mutex);
    if (w->state == 1 && len < 4096 && strlen(user) < sizeof(w->user)) {
        snprintf(w->user, sizeof(w->user), "%s", user);
        explicit_bzero(w->password, 4096);
        memcpy(w->password, password, len);
        w->password_ready = 1;
        w->state = 0;
        w->deadline = now() + 20;
        pthread_cond_broadcast(&w->condition);
    }
    pthread_mutex_unlock(&w->mutex);
}
void rediwm_cups_finish(struct rediwm_cups *w) {
    pthread_mutex_lock(&w->mutex);
    w->close_idle = 1;
    pthread_cond_broadcast(&w->condition);
    pthread_mutex_unlock(&w->mutex);
}
