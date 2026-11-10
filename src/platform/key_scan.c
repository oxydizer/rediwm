/* Capabilities for the disposable scanner. No write, create or execute rights. */
#ifdef __FreeBSD__
#include <sys/capsicum.h>
#include <unistd.h>

int rediwm_key_scan_capsicum(int directory, int index) {
    cap_rights_t rights;
    if (directory >= 0) {
        cap_rights_init(&rights, CAP_READ, CAP_LOOKUP, CAP_FSTAT, CAP_SEEK,
            CAP_FCNTL);
        if (cap_rights_limit(directory, &rights) < 0) return -1;
    }
    if (index >= 0) {
        cap_rights_init(&rights, CAP_READ, CAP_FSTAT, CAP_SEEK);
        if (cap_rights_limit(index, &rights) < 0) return -1;
    }
    cap_rights_init(&rights, CAP_WRITE, CAP_FSTAT);
    if (cap_rights_limit(STDOUT_FILENO, &rights) < 0 ||
            cap_rights_limit(STDERR_FILENO, &rights) < 0) return -1;
    close(STDIN_FILENO);
    return cap_enter();
}
#endif
