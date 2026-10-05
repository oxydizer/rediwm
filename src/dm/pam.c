#define _GNU_SOURCE
#include <security/pam_appl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>
#include <errno.h>

/* The PAM conversation of a rediwm-dm worker. Each PAM message becomes one
 * frame to the daemon ('Q', a kind byte, the text; see proto.zig), and the
 * call blocks for the reply: 'A' plus the raw answer bytes, or 'N' for none.
 * No JSON: answers are opaque bytes and are wiped as soon as PAM has a copy.
 * The daemon cancels by closing the socket (and killing this process), which
 * makes the read fail and the conversation return PAM_CONV_ERR. */

#define MAX_FRAME (64 * 1024)
#define MAX_ANSWER 4096

static int send_all(int fd, const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n > 0) {
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

static int read_all(int fd, void *buf, size_t n) {
    uint8_t *p = buf;
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        p += r;
        n -= (size_t)r;
    }
    return 0;
}

static int ask(int fd, char kind, const char *text) {
    size_t len = text ? strnlen(text, MAX_FRAME - 2) : 0;
    uint32_t frame = (uint32_t)(len + 2);
    char head[2] = {'Q', kind};
    if (send_all(fd, &frame, sizeof frame) || send_all(fd, head, 2)) return -1;
    return len ? send_all(fd, text, len) : 0;
}

/* Reads the reply into a fresh, locked answer. Returns 0 with *out NULL for
 * 'N', 0 with *out set for 'A', -1 on any error. */
static int reply(int fd, char **out) {
    uint32_t len = 0;
    *out = NULL;
    if (read_all(fd, &len, sizeof len) || len < 1 || len > MAX_ANSWER + 1) return -1;
    char tag;
    if (read_all(fd, &tag, 1)) return -1;
    size_t n = len - 1;
    if (tag == 'N') return n == 0 ? 0 : -1;
    if (tag != 'A') return -1;
    char *answer = calloc(1, n + 1);
    if (!answer) return -1;
    mlock(answer, n + 1);
    if (read_all(fd, answer, n) || memchr(answer, 0, n)) {
        explicit_bzero(answer, n + 1);
        free(answer);
        return -1;
    }
    *out = answer;
    return 0;
}

static int converse(int num_msg, const struct pam_message **msg,
                    struct pam_response **resp, void *appdata_ptr) {
    if (num_msg <= 0 || num_msg > PAM_MAX_NUM_MSG) return PAM_CONV_ERR;
    int fd = (int)(intptr_t)appdata_ptr;
    struct pam_response *r = calloc((size_t)num_msg, sizeof *r);
    if (!r) return PAM_BUF_ERR;

    for (int i = 0; i < num_msg; ++i) {
        char kind;
        switch (msg[i]->msg_style) {
        case PAM_PROMPT_ECHO_OFF: kind = 's'; break;
        case PAM_PROMPT_ECHO_ON: kind = 'v'; break;
        case PAM_TEXT_INFO: kind = 'i'; break;
        case PAM_ERROR_MSG: kind = 'e'; break;
        default: goto fail;
        }
        if (ask(fd, kind, msg[i]->msg) || reply(fd, &r[i].resp)) goto fail;
        /* PAM owns the answer now; it frees (and should wipe) it. */
        if (r[i].resp) munlock(r[i].resp, strlen(r[i].resp) + 1);
    }
    *resp = r;
    return PAM_SUCCESS;

fail:
    for (int i = 0; i < num_msg; ++i) {
        if (r[i].resp) {
            explicit_bzero(r[i].resp, strlen(r[i].resp));
            free(r[i].resp);
        }
    }
    free(r);
    return PAM_CONV_ERR;
}

/* pam_start copies the conversation struct, so a stack one is fine. */
pam_handle_t *rediwm_pam_start(const char *service, const char *user,
                               const char *confdir, int ctrl_fd) {
    struct pam_conv conv = {converse, (void *)(intptr_t)ctrl_fd};
    pam_handle_t *pamh = NULL;
    int rc = confdir && confdir[0]
        ? pam_start_confdir(service, user, &conv, confdir, &pamh)
        : pam_start(service, user, &conv, &pamh);
    return rc == PAM_SUCCESS ? pamh : NULL;
}

int rediwm_pam_authenticate(pam_handle_t *pamh) {
    return pam_authenticate(pamh, 0);
}

int rediwm_pam_acct_mgmt(pam_handle_t *pamh) {
    int rc = pam_acct_mgmt(pamh, 0);
    if (rc == PAM_NEW_AUTHTOK_REQD) rc = pam_chauthtok(pamh, PAM_CHANGE_EXPIRED_AUTHTOK);
    return rc;
}

int rediwm_pam_setcred(pam_handle_t *pamh, int flags) { return pam_setcred(pamh, flags); }
int rediwm_pam_putenv(pam_handle_t *pamh, const char *nameval) { return pam_putenv(pamh, nameval); }
int rediwm_pam_open_session(pam_handle_t *pamh) { return pam_open_session(pamh, 0); }
int rediwm_pam_close_session(pam_handle_t *pamh) { return pam_close_session(pamh, 0); }
int rediwm_pam_end(pam_handle_t *pamh, int status) { return pam_end(pamh, status); }
char **rediwm_pam_getenvlist(pam_handle_t *pamh) { return pam_getenvlist(pamh); }
const char *rediwm_pam_strerror(pam_handle_t *pamh, int err) { return pam_strerror(pamh, err); }
