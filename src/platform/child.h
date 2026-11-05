/* Process handles for the C code that cannot import platform/child.zig; the
 * same contract as child.Handle. A handle names one process even after its
 * pid is reused, and its descriptor turns readable when the process exits,
 * without reaping it. Linux uses pidfds. */
#ifndef REDIWM_CHILD_H
#define REDIWM_CHILD_H

#ifndef __linux__
#error "platform/child.h is not ported to this OS yet (docs/plans/freebsd.md, phase 1)"
#endif

#include <stddef.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

/* A handle on a running process, or -1. */
static inline int rediwm_child_open(pid_t pid) {
    return (int)syscall(SYS_pidfd_open, pid, 0);
}

/* Signals the process the handle was opened for; 0 on success. */
static inline int rediwm_child_signal(int handle, int sig) {
    return (int)syscall(SYS_pidfd_send_signal, handle, sig, NULL, 0);
}

static inline void rediwm_child_close(int handle) {
    close(handle);
}

#endif
