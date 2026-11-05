/* The running program's own path, for the C and C++ code that cannot import
 * platform/exe.zig. Linux reads /proc/self/exe, FreeBSD kern.proc.pathname. */
#ifndef REDIWM_SELF_EXE_H
#define REDIWM_SELF_EXE_H

#include <stddef.h>
#include <sys/types.h>
#include <unistd.h>
#if defined(__FreeBSD__)
#include <sys/sysctl.h>
#elif !defined(__linux__)
#error "platform/self_exe.h is not ported to this OS yet (docs/plans/freebsd.md, phase 1)"
#endif

/* Writes the NUL-terminated absolute path of the running executable into
 * `buf`. Returns its length, or -1 when it cannot be read or does not fit. */
static inline ssize_t rediwm_self_exe(char *buf, size_t size) {
    if (size < 2) return -1;
#if defined(__FreeBSD__)
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1 };
    size_t len = size;
    /* The length counts the terminating NUL. */
    if (sysctl(mib, 4, buf, &len, NULL, 0) != 0 || len < 2 || buf[len - 1] != '\0') return -1;
    return (ssize_t)(len - 1);
#else
    ssize_t len = readlink("/proc/self/exe", buf, size - 1);
    if (len <= 0) return -1;
    buf[len] = '\0';
    return len;
#endif
}

#endif
