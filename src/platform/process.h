/* Process attributes that differ between systems, for the C code that cannot
 * import platform/process.zig; the same contract. Linux uses prctl, FreeBSD
 * procctl. */
#ifndef REDIWM_PROCESS_H
#define REDIWM_PROCESS_H

#include <stddef.h>
#include <sys/mman.h>

#if defined(__linux__)

#include <sys/prctl.h>

/* No core dump, and other processes of the same user cannot ptrace this one
 * or read its memory. Returns 0, or -1. */
static inline int rediwm_process_deny_dumps(void) {
    return prctl(PR_SET_DUMPABLE, 0);
}

/* From now on exec cannot give this process, or anything it starts, more
 * privilege (setuid, file capabilities). Irreversible. Returns 0, or -1. */
static inline int rediwm_process_no_new_privileges(void) {
    return prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
}

/* The calling thread's name, as ps and top show it (15 characters). */
static inline void rediwm_process_set_name(const char *name) {
    (void)prctl(PR_SET_NAME, name, 0, 0, 0);
}

/* Keeps [p, p + n) out of core dumps (a password sits there). Returns 0, or -1;
 * MADV_DONTDUMP needs _GNU_SOURCE, and without it this fails, never silently
 * succeeds. */
static inline int rediwm_process_no_dump_range(void *p, size_t n) {
#ifdef MADV_DONTDUMP
    return madvise(p, n, MADV_DONTDUMP);
#else
    (void)p; (void)n;
    return -1;
#endif
}

#elif defined(__FreeBSD__)

#include <sys/types.h>
#include <sys/procctl.h>
#include <pthread.h>
#include <pthread_np.h>
#include <unistd.h>

static inline int rediwm_process_procctl(int command, int value) {
    return procctl(P_PID, getpid(), command, &value);
}

static inline int rediwm_process_deny_dumps(void) {
    return rediwm_process_procctl(PROC_TRACE_CTL, PROC_TRACE_CTL_DISABLE);
}

static inline int rediwm_process_no_new_privileges(void) {
    return rediwm_process_procctl(PROC_NO_NEW_PRIVS_CTL, PROC_NO_NEW_PRIVS_ENABLE);
}

static inline void rediwm_process_set_name(const char *name) {
    pthread_set_name_np(pthread_self(), name);
}

static inline int rediwm_process_no_dump_range(void *p, size_t n) {
    return madvise(p, n, MADV_NOCORE);
}

#else
#error "platform/process.h is not ported to this OS yet (docs/plans/freebsd.md, P.4)"
#endif

#endif
