/* Session-only Bash loadable builtin. Uses Bash's installed public builtin
 * ABI and Readline's getc hook, without timers, traps, synthetic keys, or
 * replacing the user's prompt/startup hooks. Qualified on Bash 5.3/Readline 8.3.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <sys/socket.h>
#include <readline/readline.h>
#include "protocol.h"
#include "../../platform/peer.h"
#ifndef RL_STATE_READSTR
#define RL_STATE_READSTR 0
#endif

/* Stable loadable-builtin ABI; no dependency on distro-private Bash headers. */
typedef struct { char *word; int flags; } Word;
typedef struct WordList { struct WordList *next; Word *word; } WordList;
struct builtin {
    char *name; int (*function)(WordList *); int flags;
    char *const *long_doc; const char *short_doc; char *handle;
};
extern int cd_builtin(WordList *);
extern int get_current_prompt_level(void);
extern int count_all_jobs(void);
extern int last_command_exit_value;
extern int executing_builtin;
extern char *get_string_value(const char *);
extern char *decode_prompt_string(char *);
extern void initialize_readline(void);
extern void check_signals_and_traps(void);

static int channel = -1;
static pid_t owner;
static rl_getc_func_t *previous_getc;
static struct ft_request pending;
static uint64_t applied;
static int following_error;
static struct ft_status last;
static struct ft_status queued_status;
static bool status_queued;

static void flush_status(void) {
    if (status_queued && send(channel,&queued_status,sizeof queued_status,MSG_DONTWAIT|MSG_NOSIGNAL)==sizeof queued_status) {
        last=queued_status; status_queued=false;
    }
}

static int safe_prompt(void) {
    const unsigned long unsafe = RL_STATE_METANEXT | RL_STATE_MOREINPUT |
        RL_STATE_ISEARCH | RL_STATE_NSEARCH | RL_STATE_SEARCH | RL_STATE_NUMERICARG |
        RL_STATE_MACROINPUT | RL_STATE_MACRODEF | RL_STATE_COMPLETING |
        RL_STATE_MULTIKEY | RL_STATE_VIMOTION | RL_STATE_CHARSEARCH | RL_STATE_READSTR;
    return !executing_builtin && get_current_prompt_level() == 1 && rl_end == 0 &&
        rl_pending_input == 0 && (rl_readline_state & RL_STATE_READCMD) &&
        !(rl_readline_state & unsafe);
}

static void report(int flags, int error) {
    struct ft_status s = { .magic = FT_MAGIC, .flags = flags | (following_error ? FT_ERROR : 0),
        .serial = applied, .error = error ? error : following_error, .jobs = count_all_jobs() };
    if (!getcwd(s.path, sizeof s.path)) s.path[0] = 0;
    queued_status=s;
    status_queued=memcmp(&s,&last,sizeof s)!=0;
    flush_status();
}

static void apply_request(void) {
    if (!pending.serial || !safe_prompt()) return;
    /* Absolute path + explicit -- bypass CDPATH and option interpretation.
     * cd_builtin validates access and maintains Bash's PWD/OLDPWD itself. */
    Word path = { .word = pending.path, .flags = 0 };
    Word option = { .word = "--", .flags = 0 };
    WordList tail = { .next = NULL, .word = &path };
    WordList args = { .next = &tail, .word = &option };
    int saved_status = last_command_exit_value;
    int result = cd_builtin(&args);
    following_error=result;
    last_command_exit_value = saved_status;
    applied = pending.serial;
    pending.serial = 0;
    report(FT_READY | (result ? FT_ERROR : 0), result);
    /* Re-expand the configured prompt, including \w, after a successful cd.
     * No text from Files is ever parsed as shell code. */
    if (!result) {
        char *ps1 = get_string_value("PS1");
        char *prompt = decode_prompt_string(ps1 ? ps1 : "");
        if (prompt) { rl_set_prompt(prompt); free(prompt); }
        rl_redisplay();
    }
}

static int terminal_getc(FILE *stream) {
    if (channel < 0 || getpid() != owner) return previous_getc(stream);
    for (;;) {
        apply_request();
        report(safe_prompt() ? FT_READY : FT_EDITING, 0);
        struct pollfd fds[2] = {{fileno(stream), POLLIN, 0}, {channel, POLLIN | (status_queued ? POLLOUT : 0), 0}};
        int rc = poll(fds, 2, -1);
        if (rc < 0) {
            if (errno == EINTR) { rl_check_signals(); check_signals_and_traps(); continue; }
            return previous_getc(stream);
        }
        if (fds[1].revents) {
            if (fds[1].revents & POLLOUT) flush_status();
            struct ft_request request;
            ssize_t n;
            /* At most the socket's bounded receive queue; keep only latest. */
            while ((n = recv(channel, &request, sizeof request, MSG_DONTWAIT | MSG_TRUNC)) > 0) {
                if (n == sizeof request && request.magic == FT_MAGIC && request.reserved == 0 &&
                    request.serial > applied && request.path[0] == '/' &&
                    memchr(request.path, 0, sizeof request.path)) pending = request;
            }
            if (n == 0 || (fds[1].revents & (POLLHUP | POLLERR | POLLNVAL))) {
                close(channel); channel = -1;
                return previous_getc(stream);
            }
            apply_request();
        }
        if (fds[0].revents) {
            int ch = previous_getc(stream);
            following_error=0;
            /* Report ordinary accept-line/EOF keys once. Printable paste bytes
             * must not alternate two 4 KiB status packets per character. The
             * hook itself remains the authority even for custom bindings. */
            if ((ch=='\r' || ch=='\n' || ch==4) &&
                !(rl_readline_state & (RL_STATE_MOREINPUT | RL_STATE_SEARCH | RL_STATE_COMPLETING))) report(FT_BUSY, 0);
            return ch;
        }
    }
}

static int terminal_builtin(WordList *args) {
    if (args && args->word && !strcmp(args->word->word,"protect")) {
        if (fcntl(3,F_SETFD,FD_CLOEXEC)<0) return 1;
        const char *rc=getenv("REDIWM_FILES_RC_FD");
        if (rc) { int fd=atoi(rc); if (fd>=4) (void)fcntl(fd,F_SETFD,FD_CLOEXEC); }
        return 0;
    }
    if (channel >= 0) return 0;
    uid_t uid;
    pid_t pid;
    if (rediwm_peer_credentials(3, &uid, &pid) ||
        uid != getuid() || pid != getppid()) return 1;
    channel = fcntl(3, F_DUPFD_CLOEXEC, 10);
    close(3);
    if (channel < 0) return 1;
    owner = getpid();
    initialize_readline();
    previous_getc = rl_getc_function ? rl_getc_function : rl_getc;
    rl_getc_function = terminal_getc;
    return 0;
}

static char *const doc[] = { "Private Files directory coordination.", NULL };
struct builtin rediwm_terminal_struct = {
    "rediwm_terminal", terminal_builtin, 1, doc, "rediwm_terminal", NULL
};

/* Refuse unloading while Readline still points into this library. */
void rediwm_terminal_builtin_unload(char *name) {
    (void)name;
    if (rl_getc_function == terminal_getc) rl_getc_function = previous_getc;
    if (channel >= 0) close(channel);
    channel = -1;
}
