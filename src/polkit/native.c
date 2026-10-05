#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

/* NSS ABI boundary only: no PAM, credential validation or privileged code. */
struct rediwm_polkit_account { uint32_t uid, gid; char user[256], name[256]; };
static int copy_account(const struct passwd *pw, struct rediwm_polkit_account *out) {
    size_t n = strlen(pw->pw_name);
    if (!n || n >= sizeof out->user || strpbrk(pw->pw_name, "\r\n")) return -1;
    memset(out, 0, sizeof *out);
    out->uid = pw->pw_uid;
    out->gid = pw->pw_gid;
    memcpy(out->user, pw->pw_name, n);
    n = strcspn(pw->pw_gecos, ",");
    if (n >= sizeof out->name) n = sizeof out->name - 1;
    memcpy(out->name, pw->pw_gecos, n);
    return 0;
}
int rediwm_polkit_user(uint32_t uid, struct rediwm_polkit_account *out) {
    struct passwd pw, *found = NULL;
    char buf[65536];
    if (getpwuid_r(uid, &pw, buf, sizeof buf, &found) || !found) return -1;
    return copy_account(&pw, out);
}
int rediwm_polkit_member(uint32_t uid, uint32_t gid) {
    struct rediwm_polkit_account account;
    if (rediwm_polkit_user(uid, &account)) return 0;
    if (account.gid == gid) return 1;
    int count = 0;
    getgrouplist(account.user, account.gid, NULL, &count);
    if (count <= 0 || count > 65536) return 0;
    gid_t *groups = malloc((size_t)count * sizeof *groups);
    if (!groups) return 0;
    int match = 0;
    if (getgrouplist(account.user, account.gid, groups, &count) >= 0)
        for (int i = 0; i < count; ++i) if (groups[i] == gid) match = 1;
    free(groups);
    return match;
}
int rediwm_polkit_group_user(uint32_t gid, struct rediwm_polkit_account *out) {
    struct group gr, *found = NULL;
    char buf[65536];
    if (getgrgid_r(gid, &gr, buf, sizeof buf, &found) || !found) return -1;
    for (char **member = gr.gr_mem; *member; ++member) {
        struct passwd pw, *user = NULL;
        char pwbuf[65536];
        if (!getpwnam_r(*member, &pw, pwbuf, sizeof pwbuf, &user) && user && !copy_account(&pw, out)) return 0;
    }
    return -1;
}

/* A separate mapping prevents munlock from unpinning a neighbour on a shared
 * allocator page. Password bytes never enter an allocator-owned resize buffer. */
void *rediwm_polkit_secret_new(void) {
    size_t n = (size_t)getpagesize();
    void *p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return NULL;
    if (mlock(p, n) || madvise(p, n, MADV_DONTDUMP)) { munlock(p, n); munmap(p, n); return NULL; }
    return p;
}
void rediwm_polkit_clear(void *p, size_t n) { explicit_bzero(p, n); }
void rediwm_polkit_secret_free(void *p) {
    size_t n = (size_t)getpagesize();
    explicit_bzero(p, n);
    munlock(p, n);
    munmap(p, n);
}

/* The caller registers the returned child with its event-loop pidfd watcher. */
int rediwm_polkit_spawn(const char *user, pid_t *out) {
    const char *paths[] = {"/usr/lib/polkit-1/polkit-agent-helper-1", "/usr/libexec/polkit-agent-helper-1"};
    const char *path = NULL;
    for (size_t i = 0; i < sizeof paths / sizeof paths[0]; ++i) {
        struct stat st;
        if (!stat(paths[i], &st) && S_ISREG(st.st_mode) && st.st_uid == 0 &&
            (st.st_mode & S_ISUID) && !(st.st_mode & (S_IWGRP | S_IWOTH)) && !access(paths[i], X_OK)) { path = paths[i]; break; }
    }
    if (!path) return -1;
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair)) return -1;
    pid_t pid;
    posix_spawn_file_actions_t actions;
    int rc = posix_spawn_file_actions_init(&actions);
    if (rc) goto fail;
    /* Compositor stdio is open; refuse unusual descriptors rather than let
     * dup2/close ordering accidentally remove the child's stdin or stdout. */
    if (pair[0] <= 2 || pair[1] <= 2) { posix_spawn_file_actions_destroy(&actions); goto fail; }
    rc = posix_spawn_file_actions_adddup2(&actions, pair[1], STDIN_FILENO);
    if (!rc) rc = posix_spawn_file_actions_adddup2(&actions, pair[1], STDOUT_FILENO);
    if (!rc) rc = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    char *argv[] = {(char *)path, (char *)user, NULL};
    char *env[] = {"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LANG=C", NULL};
    if (!rc) rc = posix_spawn(&pid, path, &actions, NULL, argv, env);
    posix_spawn_file_actions_destroy(&actions);
    if (rc) goto fail;
    close(pair[1]);
    if (fcntl(pair[0], F_SETFL, O_NONBLOCK) < 0) {
        kill(pid, SIGKILL);
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
        close(pair[0]); return -1;
    }
    *out = pid;
    return pair[0];
fail:
    close(pair[0]); close(pair[1]); return -1;
}
