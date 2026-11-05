/* Who is on the other end of a connected unix socket, for the C and C++ code
 * that cannot import platform/peer.zig; the same contract as peer.of(). Linux
 * reads SO_PEERCRED, which glibc declares only under _GNU_SOURCE (the C++
 * compilers define it themselves). */
#ifndef REDIWM_PEER_H
#define REDIWM_PEER_H

#ifndef __linux__
#error "platform/peer.h is not ported to this OS yet (docs/plans/freebsd.md, P.9)"
#endif
#ifndef _GNU_SOURCE
#error "platform/peer.h needs _GNU_SOURCE defined before any system header"
#endif

#include <sys/socket.h>
#include <sys/types.h>

/* The user and process id of whoever made the other end of the connected unix
 * socket `fd`, as of connect(2) or socketpair(2). Either output may be NULL.
 * Returns 0, or -1 when the kernel gives no answer: refuse the peer. */
static inline int rediwm_peer_credentials(int fd, uid_t *uid, pid_t *pid) {
    struct ucred cred;
    socklen_t size = sizeof cred;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &size) != 0 || size != sizeof cred)
        return -1;
    if (uid) *uid = cred.uid;
    if (pid) *pid = cred.pid;
    return 0;
}

#endif
