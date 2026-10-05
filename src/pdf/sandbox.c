// Applied while single-threaded, before any PDF reaches Poppler. New threads
// inherit both policies. There is deliberately no unsandboxed fallback.
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <iconv.h>
#include <linux/landlock.h>
#include <sched.h>
#include <seccomp.h>
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

static int close_inherited(int document, int display) {
    if (document < 3 || display < 3 || document == display) { errno = EINVAL; return -1; }
    int lower = document < display ? document : display;
    int upper = document < display ? display : document;
    if (lower > 3 && close_range(3, (unsigned)lower - 1, 0) < 0) return -1;
    if (upper > lower + 1 && close_range((unsigned)lower + 1, (unsigned)upper - 1, 0) < 0) return -1;
    return close_range((unsigned)upper + 1, ~0u, 0);
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

static int syscall_policy(int display) {
    scmp_filter_ctx filter = seccomp_init(SCMP_ACT_ERRNO(EPERM));
    if (!filter) return -1;
    int rc = seccomp_attr_set(filter, SCMP_FLTATR_CTL_TSYNC, 1);
    if (rc < 0) goto done;
    // File opens are checked by Landlock. No exec, fork, socket/connect,
    // ptrace, process_vm_*, pidfd, io_uring, BPF, keyring, mount or general
    // ioctl/prctl is allowed. Unsupported/new syscalls are denied as well.
    const int allowed[] = {
        SCMP_SYS(read), SCMP_SYS(write), SCMP_SYS(readv), SCMP_SYS(writev),
        SCMP_SYS(pread64), SCMP_SYS(lseek), SCMP_SYS(close), SCMP_SYS(dup),
        SCMP_SYS(dup2), SCMP_SYS(dup3), SCMP_SYS(open), SCMP_SYS(openat),
        SCMP_SYS(fstat), SCMP_SYS(fstatfs), SCMP_SYS(newfstatat), SCMP_SYS(stat), SCMP_SYS(lstat),
        SCMP_SYS(statx), SCMP_SYS(access), SCMP_SYS(faccessat), SCMP_SYS(faccessat2),
        SCMP_SYS(readlink), SCMP_SYS(readlinkat), SCMP_SYS(getdents64),
        SCMP_SYS(mmap), SCMP_SYS(mprotect), SCMP_SYS(munmap), SCMP_SYS(mremap),
        SCMP_SYS(madvise), SCMP_SYS(brk), SCMP_SYS(mlock), SCMP_SYS(munlock),
        SCMP_SYS(futex), SCMP_SYS(futex_waitv), SCMP_SYS(set_robust_list), SCMP_SYS(rseq),
        SCMP_SYS(sched_yield), SCMP_SYS(sched_getaffinity),
        SCMP_SYS(rt_sigaction), SCMP_SYS(rt_sigprocmask), SCMP_SYS(rt_sigreturn),
        SCMP_SYS(sigaltstack), SCMP_SYS(getpid), SCMP_SYS(gettid),
        SCMP_SYS(getuid), SCMP_SYS(geteuid), SCMP_SYS(getgid), SCMP_SYS(getegid),
        SCMP_SYS(clock_gettime), SCMP_SYS(gettimeofday), SCMP_SYS(clock_nanosleep),
        SCMP_SYS(nanosleep), SCMP_SYS(time), SCMP_SYS(uname), SCMP_SYS(getrandom),
        SCMP_SYS(poll), SCMP_SYS(ppoll), SCMP_SYS(select), SCMP_SYS(pselect6),
        SCMP_SYS(eventfd2), SCMP_SYS(pipe2), SCMP_SYS(ftruncate),
        SCMP_SYS(exit), SCMP_SYS(exit_group), SCMP_SYS(restart_syscall),
    };
    for (unsigned i = 0; i < sizeof(allowed) / sizeof(allowed[0]); i++) {
        // Some legacy syscalls are absent on other native architectures.
        // Skipping their pseudo-numbers leaves the default denial intact.
        if (allowed[i] < 0) continue;
        rc = seccomp_rule_add(filter, SCMP_ACT_ALLOW, allowed[i], 0);
        if (rc < 0) goto done;
    }
    const int commands[] = { F_GETFD, F_SETFD, F_GETFL, F_SETFL, F_DUPFD_CLOEXEC, F_GET_SEALS, F_ADD_SEALS };
    for (unsigned i = 0; i < sizeof(commands) / sizeof(commands[0]); i++) {
        rc = seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(fcntl), 1, SCMP_A1(SCMP_CMP_EQ, commands[i], 0));
        if (rc < 0) goto done;
    }
    rc = seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(memfd_create), 1,
                          SCMP_A1(SCMP_CMP_MASKED_EQ, ~3ULL, 0));
    if (rc < 0) goto done;
    // glibc retries pthread_create with clone when clone3 returns ENOSYS.
    rc = seccomp_rule_add(filter, SCMP_ACT_ERRNO(ENOSYS), SCMP_SYS(clone3), 0);
    if (rc < 0) goto done;
    const unsigned thread_flags = CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND |
        CLONE_THREAD | CLONE_SYSVSEM | CLONE_SETTLS | CLONE_PARENT_SETTID | CLONE_CHILD_CLEARTID;
    rc = seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(clone), 1,
                          SCMP_A0(SCMP_CMP_EQ, thread_flags, 0));
    if (rc < 0) goto done;
    rc = seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(tgkill), 1,
                          SCMP_A0(SCMP_CMP_EQ, getpid(), 0));
    if (rc < 0) goto done;
    rc = seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(sendmsg), 1,
                          SCMP_A0(SCMP_CMP_EQ, display, 0));
    if (rc < 0) goto done;
    rc = seccomp_rule_add(filter, SCMP_ACT_ALLOW, SCMP_SYS(recvmsg), 1,
                          SCMP_A0(SCMP_CMP_EQ, display, 0));
    if (rc < 0) goto done;
    rc = seccomp_load(filter);
done:
    seccomp_release(filter);
    if (rc < 0) { errno = -rc; return -1; }
    return 0;
}

int rediwm_pdf_sandbox_enter(int document, int display) {
    if (single_threaded() < 0 || close_inherited(document, display) < 0) return -1;
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
    if (single_threaded() < 0 || close_inherited(document, display) < 0) return -1;
    struct rlimit core = {0, 0}, memory = {2ULL << 30, 2ULL << 30}, files = {128, 128};
    if (setrlimit(RLIMIT_CORE, &core) < 0 || setrlimit(RLIMIT_AS, &memory) < 0 ||
        setrlimit(RLIMIT_NOFILE, &files) < 0 || prctl(PR_SET_DUMPABLE, 0) < 0 ||
        prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0) return -1;
    if (filesystem_policy() < 0) return -1;
    return syscall_policy(display);
}
