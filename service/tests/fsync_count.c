/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * An LD_PRELOAD shim that appends one byte to $FSQL_FSYNC_LOG for every fsync or fdatasync the process makes, so a
 * test can tell, from outside, whether an acknowledged write was synced before the answer went out.
 *   cc -shared -fPIC -O1 -o fsync_count.so fsync_count.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

static int g_logfd = -1;

static void note(void)
{
    if (g_logfd < 0) {
        const char *p = getenv("FSQL_FSYNC_LOG");
        if (!p) return;
        g_logfd = open(p, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
    }
    if (g_logfd >= 0) { ssize_t w = write(g_logfd, "F", 1); (void) w; }
}

int fsync(int fd)
{
    static int (*real)(int);
    if (!real) real = (int (*)(int)) dlsym(RTLD_NEXT, "fsync");
    note();
    return real(fd);
}

int fdatasync(int fd)
{
    static int (*real)(int);
    if (!real) real = (int (*)(int)) dlsym(RTLD_NEXT, "fdatasync");
    note();
    return real(fd);
}
