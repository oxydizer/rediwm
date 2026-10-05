// Model a killed child stuck in kernel I/O: waitpid never reports it exited.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

pid_t waitpid(pid_t pid, int *status, int options) {
    const char *path = getenv("REDIWM_TEST_STUCK_PID");
    if (path && pid > 0) {
        FILE *file = fopen(path, "r");
        long stuck = -1;
        if (file) {
            if (fscanf(file, "%ld", &stuck) != 1) stuck = -1;
            fclose(file);
        }
        if (pid == stuck) {
            if (!(options & WNOHANG)) sleep(30);
            return 0;
        }
    }
    static pid_t (*real_waitpid)(pid_t, int *, int);
    if (!real_waitpid) real_waitpid = dlsym(RTLD_NEXT, "waitpid");
    return real_waitpid(pid, status, options);
}
