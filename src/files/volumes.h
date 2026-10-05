/* Mountable volumes from UDisks2, for Files' sidebar.
 *
 * A GLib thread owns a D-Bus object-manager client for the system bus and
 * publishes a flat list of every block device that has a filesystem. It says
 * nothing about which of them a user wants to see: that policy lives in
 * volumes.zig. Changes arrive coalesced and only when the list really changed,
 * announced on an eventfd, so an idle Files makes no wakeups. Mount and
 * unmount run asynchronously (with interactive polkit authorization) and
 * report through the same eventfd.
 *
 * The thread finds the daemon through DBUS_SYSTEM_BUS_ADDRESS like any D-Bus
 * client, which is how tests substitute a private bus. Without a bus or
 * UDisks2 the list stays empty. No GLib headers here: see AGENTS.md, "Build
 * and platform gotchas". */
#ifndef REDIWM_VOLUMES_H
#define REDIWM_VOLUMES_H

#include <stddef.h>
#include <stdint.h>

typedef struct vol_monitor vol_monitor;

/* Strings are NUL-terminated UTF-8, cut at a character boundary when too long
 * (`mount` is a raw path: records whose path does not fit read as unmounted).
 * Unavailable properties are empty or zero. */
typedef struct {
    char object[160];   /* block object path: the volume's identity */
    char device[64];    /* /dev node */
    char label[128];    /* IdLabel */
    char hint_name[96]; /* HintName */
    char fstype[24];    /* IdType */
    char bus[16];       /* the drive's ConnectionBus ("usb", "sdio", ...) */
    char media[24];     /* the drive's Media ("flash_sd", ...) */
    char mount[512];    /* first mount point; empty when not mounted */
    uint64_t size;      /* bytes */
    uint8_t hint_ignore, hint_system;
    uint8_t removable, optical; /* the drive's Removable and Optical */
} vol_record;

typedef struct {
    int unmount;     /* 0: a mount finished, 1: an unmount finished */
    int ok;
    char object[160];
    char path[512];  /* where a successful mount landed */
    char code[96];   /* D-Bus error name on failure, e.g. ...Error.DeviceBusy */
} vol_result;

/* Starts the thread. NULL when it cannot be started. */
vol_monitor *vol_start(void);

/* Readable when `vol_take` or `vol_next_result` has something new. */
int vol_wake_fd(const vol_monitor *m);
void vol_clear_wake(vol_monitor *m);

/* Hands over the newest list (ordered by `object`; free with free()) and
 * returns 1 if it differs from the one handed over last time, else 0. `*out`
 * is NULL for an empty list. */
int vol_take(vol_monitor *m, vol_record **out, size_t *count);

/* Starts a mount or unmount of the volume with this `object`. */
void vol_mount(vol_monitor *m, const char *object);
void vol_unmount(vol_monitor *m, const char *object);

/* Pops the oldest finished operation; 0 when there is none. */
int vol_next_result(vol_monitor *m, vol_result *out);

/* Releases the monitor. The thread frees its own state when its loop ends and
 * is never joined, so this cannot block on a bus that does not answer. `m` and
 * its wake fd are invalid afterwards. */
void vol_stop(vol_monitor *m);

#endif
