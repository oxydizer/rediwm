/* Link-time fake PAM only in this standalone test executable. Production
 * builds link libpam and have no runtime auth override. */
#include "../src/session/auth.c"
#include <assert.h>
#include <stdio.h>
#include <time.h>

static int scenario, accounts;
static const struct pam_conv *conversation;
int pam_start(const char *service, const char *user, const struct pam_conv *conv, pam_handle_t **handle) {
    assert(!strcmp(service, "login") || !strcmp(service, "rediwm"));
    assert(user && *user);
    conversation = conv;
    if (scenario == 3) return PAM_SYSTEM_ERR;
    *handle = (pam_handle_t *)conv;
    return PAM_SUCCESS;
}
int pam_authenticate(pam_handle_t *handle, int flags) {
    (void)handle;
    assert(flags & PAM_DISALLOW_NULL_AUTHTOK);
    struct pam_message msg = { scenario == 4 ? 999 : PAM_PROMPT_ECHO_OFF, "Password:" };
    const struct pam_message *messages[] = { &msg };
    struct pam_response *response = NULL;
    int rc = conversation->conv(1, messages, &response, conversation->appdata_ptr);
    if (scenario == 4) { assert(rc == PAM_CONV_ERR); return rc; }
    assert(rc == PAM_SUCCESS);
    assert(!strcmp(response[0].resp, "fixture-password"));
    explicit_bzero(response[0].resp, strlen(response[0].resp));
    free(response[0].resp);
    free(response);
    return scenario == 1 ? PAM_AUTH_ERR : PAM_SUCCESS;
}
int pam_acct_mgmt(pam_handle_t *handle, int flags) {
    (void)handle; (void)flags;
    ++accounts;
    return scenario == 2 ? PAM_ACCT_EXPIRED : PAM_SUCCESS;
}
int pam_end(pam_handle_t *handle, int status) { (void)handle; (void)status; return PAM_SUCCESS; }

void rediwm_test_auth_scenario(int value) { scenario = value; accounts = 0; }

#ifndef REDIWM_AUTH_EMBEDDED_TEST
int main(void) {
    for (scenario = 0; scenario < 5; ++scenario) {
        accounts = 0;
        struct rediwm_auth *auth = rediwm_auth_start("fixture-password");
        assert(auth);
        int result = 0;
        for (int n = 0; n < 10000 && !result; ++n) {
            result = rediwm_auth_poll(auth);
            struct timespec delay = {0, 1000000};
            nanosleep(&delay, NULL);
        }
        assert(result == (scenario == 0 ? 1 : -1));
        assert(accounts == (scenario == 0 || scenario == 2));
        for (size_t n = 0; n < sizeof auth->password; ++n) assert(auth->password[n] == 0);
        rediwm_auth_destroy(auth);
    }
    char oversized[513];
    memset(oversized, 'x', sizeof oversized - 1);
    oversized[512] = 0;
    assert(rediwm_auth_start(oversized) == NULL);
    puts("PASS: PAM success, wrong password, expired account, initialization/conversation failures, secret wiping");
}

#endif
