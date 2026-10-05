// Test-only sysfs fixture. Redirect the power-supply directory, leaving all
// relative reads and enumeration on the returned descriptor unchanged.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

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
