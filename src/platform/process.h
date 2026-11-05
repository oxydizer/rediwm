/* Process attributes that differ between systems, for the C code that cannot
 * import platform/process.zig; the same contract. Linux uses prctl. */
#ifndef REDIWM_PROCESS_H
#define REDIWM_PROCESS_H

#ifndef __linux__
#error "platform/process.h is not ported to this OS yet (docs/plans/freebsd.md, P.4)"
#endif

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

#endif
