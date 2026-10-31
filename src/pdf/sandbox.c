// Applied while single-threaded, before any PDF reaches Poppler. New threads
// inherit both policies. There is deliberately no unsandboxed fallback.
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <iconv.h>
#include <linux/landlock.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

// Keep the trusted password codec resident. Poppler GLib converts supplied
// passwords to Latin-1; lazy gconv loading after Landlock would fail. This
// handle processes no PDF bytes and is kept until process exit.
static iconv_t password_codec = (iconv_t)-1;

int rediwm_pdf_open_document(const char *path) {
    // NONBLOCK prevents an accidental FIFO/device argument from hanging us
    // before we can check its type. The original inode is retained across
    // renames, symlink changes and password retries.
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOCTTY);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        errno = EINVAL;
        return -1;
    }
    if (fd < 3) {
        int moved = fcntl(fd, F_DUPFD_CLOEXEC, 3);
        close(fd);
        return moved;
    }
    return fd;
}

static int single_threaded(void) {
    DIR *dir = opendir("/proc/self/task");
    if (!dir) return -1;
    unsigned count = 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) if (entry->d_name[0] != '.') count++;
    closedir(dir);
    if (count != 1) { errno = EBUSY; return -1; }
    return 0;
}

// Closes every descriptor above stdio except `keep`; negative entries are
// unused slots.
static int close_inherited(const int *keep, unsigned count) {
    int sorted[3];
    unsigned n = 0;
    if (count > sizeof(sorted) / sizeof(sorted[0])) { errno = EINVAL; return -1; }
    for (unsigned i = 0; i < count; i++) {
        if (keep[i] < 0) continue;
        if (keep[i] < 3) { errno = EINVAL; return -1; }
        unsigned at = n++;
        while (at > 0 && sorted[at - 1] > keep[i]) { sorted[at] = sorted[at - 1]; at--; }
        if (at > 0 && sorted[at - 1] == keep[i]) { errno = EINVAL; return -1; }
        sorted[at] = keep[i];
    }
    unsigned next = 3;
    for (unsigned i = 0; i < n; i++) {
        if ((unsigned)sorted[i] > next && close_range(next, (unsigned)sorted[i] - 1, 0) < 0) return -1;
        next = (unsigned)sorted[i] + 1;
    }
    return close_range(next, ~0u, 0);
}

static int read_tree(int rules, const char *path) {
    int fd = open(path, O_PATH | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT ? 0 : -1;
    struct landlock_path_beneath_attr rule = {
        .allowed_access = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR,
        .parent_fd = fd,
    };
    int rc = (int)syscall(SYS_landlock_add_rule, rules, LANDLOCK_RULE_PATH_BENEATH, &rule, 0);
    int saved = errno;
    close(fd);
    errno = saved;
    return rc;
}

static int filesystem_policy(void) {
    int abi = (int)syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    // ABI 3 also covers truncate. Older kernels do not meet this policy.
    if (abi < 3) { errno = ENOTSUP; return -1; }
    // Use the stable ABI prefix, independently of the build machine's headers.
    struct { uint64_t fs, net, scoped; } ruleset = {
        .fs = (1ULL << 15) - 1,
    };
    if (abi >= 5) ruleset.fs |= 1ULL << 15; // device ioctl
    if (abi >= 9) ruleset.fs |= 1ULL << 16; // pathname UNIX sockets
    if (abi >= 6) ruleset.scoped = 3; // abstract UNIX sockets and signals
    int fd = (int)syscall(SYS_landlock_create_ruleset, &ruleset,
                         abi >= 6 ? sizeof(ruleset) : sizeof(uint64_t), 0);
    if (fd < 0) return -1;
    // No home, runtime directory, /proc, device tree, or blanket /usr grant.
    // The document is already open read-only; it needs no pathname grant.
    const char *paths[] = {
        "/usr/share/fonts", "/usr/local/share/fonts", "/etc/fonts",
        "/usr/share/fontconfig", "/var/cache/fontconfig", "/usr/share/poppler",
    };
    for (unsigned i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        if (read_tree(fd, paths[i]) < 0) { close(fd); return -1; }
    }
    int rc = (int)syscall(SYS_landlock_restrict_self, fd, 0);
    int saved = errno;
    close(fd);
    errno = saved;
    return rc;
}

// The syscall allow-list is built and loaded in syscall_policy.zig.
extern int rediwm_pdf_syscall_policy(int display);

// `print` is the print helper's socket (see print.c), or -1. The viewer
// may only read and write bytes on it: sendmsg is limited to `display`, so
// no descriptor can be passed out.
int rediwm_pdf_sandbox_enter(int document, int display, int print) {
    if (document < 0 || display < 0) { errno = EINVAL; return -1; }
    const int keep[] = { document, display, print };
    const unsigned kept = sizeof(keep) / sizeof(keep[0]);
    if (single_threaded() < 0 || close_inherited(keep, kept) < 0) return -1;
    // Drop terminal input, and ensure diagnostics cannot be read as input.
    int null = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (null < 0 || dup2(null, STDIN_FILENO) < 0) { if (null >= 0) close(null); return -1; }
    close(null);
    const char *stdio_paths[] = { "/proc/self/fd/1", "/proc/self/fd/2" };
    for (int i = 0; i < 2; i++) {
        int fd = open(stdio_paths[i], O_WRONLY | O_CLOEXEC | O_NOCTTY);
        if (fd < 0) fd = open("/dev/null", O_WRONLY | O_CLOEXEC);
        if (fd < 0 || dup2(fd, i + 1) < 0) { if (fd >= 0) close(fd); return -1; }
        close(fd);
    }
    if (chdir("/") < 0) return -1;
    // Do not leave inherited environment secrets in addressable memory.
    extern char **environ;
    for (char **p = environ; p && *p; p++) {
        // Zig also retains the initial environ vector. Leave its KEY= shape
        // valid for lazy stdio setup, while erasing every inherited value.
        char *value = strchr(*p, '=');
        if (!value) continue;
        volatile char *s = value + 1;
        while (*s) *s++ = 0;
    }
    if (clearenv() < 0) return -1;
    password_codec = iconv_open("ISO-8859-1", "UTF-8");
    if (password_codec == (iconv_t)-1) return -1;
    if (single_threaded() < 0 || close_inherited(keep, kept) < 0) return -1;
    struct rlimit core = {0, 0}, memory = {2ULL << 30, 2ULL << 30}, files = {128, 128};
    if (setrlimit(RLIMIT_CORE, &core) < 0 || setrlimit(RLIMIT_AS, &memory) < 0 ||
        setrlimit(RLIMIT_NOFILE, &files) < 0 || prctl(PR_SET_DUMPABLE, 0) < 0 ||
        prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0) return -1;
    if (filesystem_policy() < 0) return -1;
    return rediwm_pdf_syscall_policy(display);
}
