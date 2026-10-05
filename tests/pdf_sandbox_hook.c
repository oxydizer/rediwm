// Simulate parser code execution *after* startup isolation, in the real worker.
// Only test-owned files/processes are used; never loaded by production code.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <seccomp.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include <unistd.h>
#include <wayland-client.h>

#define CHECK(expr) do { if (!(expr)) { fprintf(stderr, "PDF sandbox probe failed at %d: %s (errno=%d)\n", __LINE__, #expr, errno); _exit(97); } } while (0)

static char secret[PATH_MAX], document[PATH_MAX], write_path[PATH_MAX], font[PATH_MAX];
static char *old_secret;
static int inherited_fd, compositor_pid;
static bool fail_policy, probed;
static struct wl_display *filtered_display;

static void copy_env(char *dest, const char *name) {
    const char *value = getenv(name);
    CHECK(value && strlen(value) < PATH_MAX);
    strcpy(dest, value);
}

__attribute__((constructor)) static void init(void) {
    copy_env(secret, "REDIWM_PDF_TEST_SECRET");
    copy_env(document, "REDIWM_PDF_TEST_DOCUMENT");
    copy_env(write_path, "REDIWM_PDF_TEST_WRITE");
    copy_env(font, "REDIWM_PDF_TEST_FONT");
    old_secret = getenv("REDIWM_PDF_TEST_TOKEN");
    CHECK(old_secret);
    inherited_fd = atoi(getenv("REDIWM_PDF_TEST_FD"));
    compositor_pid = atoi(getenv("REDIWM_PDF_TEST_PID"));
    fail_policy = getenv("REDIWM_PDF_TEST_FAIL_POLICY") != NULL;
}

struct wl_display *wl_display_connect_to_fd(int fd) {
    struct wl_display *(*real)(int) = dlsym(RTLD_NEXT, "wl_display_connect_to_fd");
    CHECK(real);
    filtered_display = real(fd);
    return filtered_display;
}

int seccomp_load(scmp_filter_ctx context) {
    if (fail_policy) return -EPERM;
    int (*real)(scmp_filter_ctx) = dlsym(RTLD_NEXT, "seccomp_load");
    CHECK(real);
    return real(context);
}

static bool denied(int rc) {
    return rc == -1 && (errno == EPERM || errno == EACCES);
}

static void global(void *data, struct wl_registry *registry, uint32_t id, const char *name, uint32_t version) {
    (void)data; (void)registry; (void)id; (void)version;
    const char *blocked[] = {
        "zwlr_screencopy_manager_v1", "ext_image_copy_capture_manager_v1",
        "ext_output_image_capture_source_manager_v1", "ext_foreign_toplevel_image_capture_source_manager_v1",
        "ext_foreign_toplevel_list_v1", "zwlr_foreign_toplevel_manager_v1",
        "zwlr_data_control_manager_v1", "ext_data_control_manager_v1",
        "zwp_virtual_keyboard_manager_v1", "zwlr_virtual_pointer_manager_v1",
        "zwp_input_method_manager_v2", "zwlr_output_manager_v1", "zwlr_output_power_manager_v1",
        "ext_session_lock_manager_v1", "zwlr_layer_shell_v1", "ext_idle_notifier_v1",
        "wp_security_context_manager_v1", "xwayland_shell_v1",
    };
    for (unsigned i = 0; i < sizeof(blocked) / sizeof(blocked[0]); i++) CHECK(strcmp(name, blocked[i]));
}
static void removed(void *data, struct wl_registry *registry, uint32_t id) { (void)data; (void)registry; (void)id; }
static const struct wl_registry_listener globals = {global, removed};

static void probe(int document_fd) {
    CHECK(!fail_policy); // A failed sandbox must never get as far as Poppler.
    CHECK(getenv("REDIWM_PDF_TEST_TOKEN") == NULL && *old_secret == 0);
    CHECK(fcntl(inherited_fd, F_GETFD) == -1 && errno == EBADF);
    CHECK(denied(open(secret, O_RDONLY)));
    CHECK(denied(open(secret, O_WRONLY)));
    CHECK(denied(open(document, O_RDONLY))); // Only the retained descriptor.
    CHECK(denied(open(write_path, O_WRONLY | O_CREAT, 0600)));
    CHECK(denied(open("/proc/self/environ", O_RDONLY)));
    CHECK(denied(open("/dev/null", O_RDONLY)));
    int fd = open(font, O_RDONLY);
    CHECK(fd >= 0);
    close(fd);
    char header[5];
    CHECK(pread(document_fd, header, sizeof(header), 0) == sizeof(header));
    CHECK(!memcmp(header, "%PDF-", sizeof(header)));
    CHECK(write(document_fd, "x", 1) == -1 && errno == EBADF);
    CHECK(denied(socket(AF_INET, SOCK_STREAM, 0)));
    CHECK(denied(socket(AF_UNIX, SOCK_STREAM, 0)));
    CHECK(denied(connect(-1, NULL, 0)));
    CHECK(denied(kill(compositor_pid, 0)));
    CHECK(denied(syscall(SYS_process_vm_readv, compositor_pid, NULL, 0, NULL, 0, 0)));
    CHECK(denied(syscall(SYS_process_vm_writev, compositor_pid, NULL, 0, NULL, 0, 0)));
    char *args[] = {"/nonexistent-rediwm-pdf-sandbox-test", NULL};
    char *env[] = {NULL};
    CHECK(denied(execve(args[0], args, env)));
    CHECK(denied(syscall(SYS_io_uring_setup, 1, NULL)));
    CHECK(denied(syscall(SYS_pidfd_open, compositor_pid, 0)));
    CHECK(mmap(NULL, 3ULL << 30, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) == MAP_FAILED && errno == ENOMEM);
    fd = memfd_create("pdf-probe", MFD_CLOEXEC);
    CHECK(fd >= 0 && ftruncate(fd, 4096) == 0 && write(fd, "ok", 2) == 2);
    close(fd);

    // Use a separate event queue because this runs on the PDF worker.
    CHECK(filtered_display);
    struct wl_event_queue *queue = wl_display_create_queue(filtered_display);
    CHECK(queue);
    struct wl_registry *registry = wl_display_get_registry(filtered_display);
    wl_proxy_set_queue((struct wl_proxy *)registry, queue);
    wl_registry_add_listener(registry, &globals, NULL);
    CHECK(wl_display_roundtrip_queue(filtered_display, queue) >= 0);
    wl_registry_destroy(registry);
    wl_event_queue_destroy(queue);
    fprintf(stderr, "PASS: PDF parser filesystem, syscall, descriptor, environment and Wayland isolation\n");
}

void *poppler_document_new_from_fd(int fd, const char *password, void *error) {
    if (!probed) { probed = true; probe(fd); }
    void *(*real)(int, const char *, void *) = dlsym(RTLD_NEXT, "poppler_document_new_from_fd");
    CHECK(real);
    return real(fd, password, error);
}
