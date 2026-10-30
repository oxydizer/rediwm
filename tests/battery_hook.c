// Test-only sysfs fixture. Redirect the power-supply directory, leaving all
// relative reads and enumeration on the returned descriptor unchanged.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <linux/netlink.h>

static int event_fd = -1;

int socket(int domain, int type, int protocol) {
    static int (*real_socket)(int, int, int);
    if (!real_socket) real_socket = dlsym(RTLD_NEXT, "socket");
    if (getenv("REDIWM_TEST_BATTERY_SOCKET") && domain == AF_NETLINK && protocol == NETLINK_KOBJECT_UEVENT) {
        event_fd = real_socket(AF_UNIX, type, 0);
        return event_fd;
    }
    return real_socket(domain, type, protocol);
}

int bind(int fd, const struct sockaddr *address, socklen_t length) {
    static int (*real_bind)(int, const struct sockaddr *, socklen_t);
    if (!real_bind) real_bind = dlsym(RTLD_NEXT, "bind");
    const char *path = getenv("REDIWM_TEST_BATTERY_SOCKET");
    if (fd == event_fd && path) {
        struct sockaddr_un fixture = { .sun_family = AF_UNIX };
        if (strlen(path) >= sizeof(fixture.sun_path)) return -1;
        strcpy(fixture.sun_path, path);
        return real_bind(fd, (const struct sockaddr *)&fixture, sizeof(fixture));
    }
    return real_bind(fd, address, length);
}

static int fixture_open(int dir, const char *path, int flags, mode_t mode) {
    static int (*real_open)(int, const char *, int, ...);
    if (!real_open) real_open = dlsym(RTLD_NEXT, "openat64");
    const char *fixture = getenv("REDIWM_TEST_BATTERY_DIR");
    if (fixture && strcmp(path, "/sys/class/power_supply") == 0) path = fixture;
    return real_open(dir, path, flags, mode);
}

#define WRAP(name) \
int name(int dir, const char *path, int flags, ...) { \
    mode_t mode = 0; \
    if ((flags & O_CREAT) || (flags & O_TMPFILE) == O_TMPFILE) { \
        va_list args; va_start(args, flags); mode = va_arg(args, mode_t); va_end(args); \
    } \
    return fixture_open(dir, path, flags, mode); \
}
WRAP(openat)
WRAP(openat64)
