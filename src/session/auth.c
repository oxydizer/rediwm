#define _GNU_SOURCE
#include <security/pam_appl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <unistd.h>
#include <pwd.h>

/* No test password, environment-selected service, or privileged compositor.
 * PAM runs away from the Wayland thread. Only a completed successful auth AND
 * account check can yield success. The UID, never $USER, selects the account. */
struct rediwm_auth {
    pthread_t thread;
    atomic_int result;
    /* Signalled once, after `result` is set, so the event loop sleeps until
     * PAM finishes instead of polling. */
    int wake;
    char user[256], password[512];
};

void rediwm_secret_clear(void *p, size_t n) { explicit_bzero(p, n); }

int rediwm_account(char *user, size_t usersz, char *name, size_t namesz,
        char *home, size_t homesz) {
    struct passwd pw, *found = NULL;
    char buf[16384];
    if (getpwuid_r(getuid(), &pw, buf, sizeof buf, &found) || !found ||
            strlen(pw.pw_name) >= usersz || strlen(pw.pw_dir) >= homesz) return -1;
    strcpy(user, pw.pw_name);
    strcpy(home, pw.pw_dir);
    size_t n = strcspn(pw.pw_gecos, ",");
    if (n >= namesz) n = namesz - 1;
    memcpy(name, pw.pw_gecos, n);
    name[n] = 0;
    return 0;
}

static int converse(int n, const struct pam_message **msg,
        struct pam_response **out, void *data) {
    struct rediwm_auth *auth = data;
    if (n <= 0 || n > PAM_MAX_NUM_MSG) return PAM_CONV_ERR;
    struct pam_response *r = calloc((size_t)n, sizeof *r);
    if (!r) return PAM_BUF_ERR;
    for (int i = 0; i < n; ++i) {
        switch (msg[i]->msg_style) {
        case PAM_PROMPT_ECHO_OFF: r[i].resp = strdup(auth->password); break;
        case PAM_PROMPT_ECHO_ON: r[i].resp = strdup(auth->user); break;
        case PAM_TEXT_INFO: case PAM_ERROR_MSG: continue;
        default: goto fail;
        }
        if (!r[i].resp) goto fail;
    }
    *out = r;
    return PAM_SUCCESS;
fail:
    for (int i = 0; i < n; ++i) {
        if (r[i].resp) explicit_bzero(r[i].resp, strlen(r[i].resp));
        free(r[i].resp);
    }
    free(r);
    return PAM_CONV_ERR;
}

static void *authenticate(void *data) {
    struct rediwm_auth *auth = data;
    struct pam_conv conv = {converse, auth};
    pam_handle_t *pam = NULL;
    /* login is the distro-provided local-login policy. An administrator can
     * provide a dedicated /etc/pam.d/rediwm policy instead. */
    const char *service = access("/etc/pam.d/rediwm", F_OK) == 0 ? "rediwm" : "login";
    int rc = pam_start(service, auth->user, &conv, &pam);
    if (rc == PAM_SUCCESS) rc = pam_authenticate(pam, PAM_DISALLOW_NULL_AUTHTOK);
    if (rc == PAM_SUCCESS) rc = pam_acct_mgmt(pam, PAM_DISALLOW_NULL_AUTHTOK);
    if (pam) pam_end(pam, rc);
    explicit_bzero(auth->password, sizeof auth->password);
    atomic_store_explicit(&auth->result, rc == PAM_SUCCESS ? 1 : -1, memory_order_release);
    uint64_t one = 1;
    ssize_t n = write(auth->wake, &one, sizeof one);
    (void)n;
    return NULL;
}

struct rediwm_auth *rediwm_auth_start(const char *password) {
    struct rediwm_auth *auth = calloc(1, sizeof *auth);
    if (!auth) return NULL;
    char name[256], home[4096];
    if (strlen(password) >= sizeof auth->password ||
            rediwm_account(auth->user, sizeof auth->user, name, sizeof name, home, sizeof home)) {
        free(auth);
        return NULL;
    }
    auth->wake = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (auth->wake < 0) {
        free(auth);
        return NULL;
    }
    (void)mlock(auth, sizeof *auth);
    (void)prctl(PR_SET_DUMPABLE, 0);
    strcpy(auth->password, password);
    atomic_init(&auth->result, 0);
    if (pthread_create(&auth->thread, NULL, authenticate, auth)) {
        close(auth->wake);
        explicit_bzero(auth, sizeof *auth);
        munlock(auth, sizeof *auth);
        free(auth);
        return NULL;
    }
    return auth;
}

/* Becomes readable when the attempt has finished; poll() then has its result. */
int rediwm_auth_fd(const struct rediwm_auth *auth) {
    return auth->wake;
}

int rediwm_auth_poll(struct rediwm_auth *auth) {
    return atomic_load_explicit(&auth->result, memory_order_acquire);
}

void rediwm_auth_destroy(struct rediwm_auth *auth) {
    pthread_join(auth->thread, NULL);
    close(auth->wake);
    explicit_bzero(auth, sizeof *auth);
    munlock(auth, sizeof *auth);
    free(auth);
}
