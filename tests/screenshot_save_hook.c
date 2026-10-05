#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Only screenshot staging files are affected. No sleeps or faults in ordinary
// compositor/socket writes, and no access to the host session.
static int screenshot_fd(int fd) {
    char name[64], path[4096];
    snprintf(name, sizeof(name), "/proc/self/fd/%d", fd);
    ssize_t n = readlink(name, path, sizeof(path) - 1);
    if (n < 0) return 0;
    path[n] = 0;
    return strstr(path, "/.rediwm-screenshot-") != NULL;
}

ssize_t write(int fd, const void *data, size_t len) {
    ssize_t (*real_write)(int, const void *, size_t) = dlsym(RTLD_NEXT, "write");
    const char *mode = getenv("REDIWM_SCREENSHOT_SAVE_FAULT");
    if (!mode || !screenshot_fd(fd)) return real_write(fd, data, len);
    static int first = 1;
    if (first) {
        first = 0;
        const char *marker = getenv("REDIWM_SCREENSHOT_WRITE_MARKER");
        if (marker) {
            int m = open(marker, O_CREAT | O_WRONLY | O_EXCL | O_CLOEXEC, 0600);
            if (m >= 0) close(m);
        }
        usleep(300000); // Give the test time to inspect directory publication.
        if (!strcmp(mode, "interrupt")) { errno = EINTR; return -1; }
    }
    if (!strcmp(mode, "write_fail")) { errno = ENOSPC; return -1; }
    return real_write(fd, data, len > 4096 ? 4096 : len);
}

int fsync(int fd) {
    int (*real_fsync)(int) = dlsym(RTLD_NEXT, "fsync");
    const char *mode = getenv("REDIWM_SCREENSHOT_SAVE_FAULT");
    if (mode && !strcmp(mode, "sync_fail") && screenshot_fd(fd)) {
        errno = ENOSPC;
        return -1;
    }
    return real_fsync(fd);
}

int renameat2(int olddir, const char *oldpath, int newdir, const char *newpath, unsigned flags) {
    int (*real_rename)(int, const char *, int, const char *, unsigned) = dlsym(RTLD_NEXT, "renameat2");
    const char *mode = getenv("REDIWM_SCREENSHOT_SAVE_FAULT");
    if (mode && !strcmp(mode, "publish_race") && strstr(oldpath, "/.rediwm-screenshot-")) {
        int fd = openat(newdir, newpath, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
        if (fd >= 0) { write(fd, "existing destination", 20); close(fd); }
    }
    return real_rename(olddir, oldpath, newdir, newpath, flags);
}
