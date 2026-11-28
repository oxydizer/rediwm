/* Executed by posix_spawn: PTY setup runs in a fresh, single-threaded process.
 * Never run libc/GIO between fork and exec in the multithreaded Files client. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <gio/gio.h>

static void place_scope(void) {
    /* Parent resolved the same nested/headless policy as app_scope.place.
     * Finish placement before executing startup files or any shell children. */
    GError *error = NULL;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!bus) { g_clear_error(&error); return; }
    char name[96];
    snprintf(name, sizeof name, "app-rediwm-files-terminal-%ld.scope", (long)getpid());
    GVariantBuilder props, aux, pids;
    g_variant_builder_init(&props, G_VARIANT_TYPE("a(sv)"));
    g_variant_builder_init(&pids, G_VARIANT_TYPE("au"));
    g_variant_builder_add(&pids, "u", (guint32)getpid());
    g_variant_builder_add(&props, "(sv)", "PIDs", g_variant_builder_end(&pids));
    g_variant_builder_add(&props, "(sv)", "Slice", g_variant_new_string("app.slice"));
    g_variant_builder_add(&props, "(sv)", "CollectMode", g_variant_new_string("inactive-or-failed"));
    g_variant_builder_init(&aux, G_VARIANT_TYPE("a(sa(sv))"));
    GVariant *reply = g_dbus_connection_call_sync(bus, "org.freedesktop.systemd1",
        "/org/freedesktop/systemd1", "org.freedesktop.systemd1.Manager", "StartTransientUnit",
        g_variant_new("(ssa(sv)a(sa(sv)))", name, "fail", &props, &aux), NULL,
        G_DBUS_CALL_FLAGS_NO_AUTO_START, 1500, NULL, &error);
    if (reply) g_variant_unref(reply);
    g_clear_error(&error);
    g_object_unref(bus);
}

int main(int argc, char **argv) {
    if (argc < 5) return 125;
    /* scope, directory, shell/plugin (or --external/--run + command argv) */
    int external = !strcmp(argv[3], "--external");
    if (!strcmp(argv[1], "1")) place_scope();
    if (chdir(argv[2])) { perror("Terminal directory"); return 125; }
    if (!strcmp(argv[3], "--run")) { execv(argv[4], argv + 4); perror("Run file"); return 127; }
    if (external) { execvp(argv[4], argv + 4); perror("External terminal"); return 127; }
    if (setsid() < 0 || ioctl(STDIN_FILENO, TIOCSCTTY, 0) < 0) {
        perror("Terminal session"); return 125;
    }
    signal(SIGINT, SIG_DFL); signal(SIGQUIT, SIG_DFL); signal(SIGHUP, SIG_DFL);
    signal(SIGPIPE, SIG_DFL); signal(SIGCHLD, SIG_DFL); signal(SIGTSTP, SIG_DFL);
    signal(SIGTTIN, SIG_DFL); signal(SIGTTOU, SIG_DFL);
    setenv("TERM", "xterm-256color", 1);
    setenv("COLORTERM", "truecolor", 1);
    /* No inherited multiplexer identity, activation token, or stale dimensions. */
    unsetenv("TMUX"); unsetenv("STY"); unsetenv("COLUMNS"); unsetenv("LINES");
    unsetenv("XDG_ACTIVATION_TOKEN"); unsetenv("DESKTOP_STARTUP_ID");
    const char *shell = argv[3];
    setenv("SHELL",shell,1);
    const char *base = strrchr(shell, '/'); base = base ? base + 1 : shell;
    if (!strcmp(base, "bash") && argv[4][0]) {
        /* Anonymous rcfile: startup config remains on disk untouched. fd 3 is
         * private until the builtin duplicates it with CLOEXEC. */
        int rc = memfd_create("files-terminal-rc", 0);
        static const char script[] =
            "if builtin enable -f \"$REDIWM_FILES_BASH_PLUGIN\" rediwm_terminal; then\n"
            "  builtin rediwm_terminal protect\n"
            "else\n"
            "  exec 3<&-\n"
            "fi\n"
            "unset REDIWM_FILES_RC_FD\n"
            "[[ -r $HOME/.bashrc ]] && source \"$HOME/.bashrc\"\n"
            "builtin rediwm_terminal 2>/dev/null || exec 3<&-\n"
            "unset REDIWM_FILES_BASH_PLUGIN\n";
        if (rc < 0 || write(rc, script, sizeof script - 1) != sizeof script - 1 || lseek(rc, 0, SEEK_SET) < 0) return 125;
        setenv("REDIWM_FILES_BASH_PLUGIN", argv[4], 1);
        char rc_env[32]; snprintf(rc_env,sizeof rc_env,"%d",rc);
        setenv("REDIWM_FILES_RC_FD",rc_env,1);
        char file[64]; snprintf(file, sizeof file, "/proc/self/fd/%d", rc);
        execl(shell, base, "--rcfile", file, "-i", (char *)NULL);
    } else {
        close(3);
        execl(shell, base, "-i", (char *)NULL);
    }
    perror("Terminal shell"); return 127;
}
