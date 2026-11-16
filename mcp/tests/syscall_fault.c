/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * An LD_PRELOAD shim that makes socket calls fail or come back short, so the MCP server's retry and error arms are
 * taken. Only sockets are touched (never stdin, stdout or a file).
 *
 *   FSQL_FAULT="call=how/N[,call=how/N...]"
 *     call  recv send accept accept4 poll connect socket setsockopt
 *     how   an errno name (EINTR EAGAIN ECONNRESET EPIPE ECONNABORTED EMFILE ENOMEM ETIMEDOUT EBADF), or "short"
 *           (recv and send transfer one byte), or "zero" (recv returns 0: the peer closed)
 *     N     every Nth call of that kind is the faulted one (default 3)
 *
 *   cc -shared -fPIC -O1 -o syscall_fault.so syscall_fault.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

enum { C_RECV, C_SEND, C_ACCEPT, C_ACCEPT4, C_POLL, C_CONNECT, C_SOCKET, C_SETSOCKOPT, C_COUNT };
static const char *const kNames[C_COUNT] = { "recv", "send", "accept", "accept4", "poll", "connect", "socket", "setsockopt" };
static struct { int err; int mode; long every; atomic_long n; } g_f[C_COUNT];   /* mode 0 off, 1 errno, 2 short, 3 zero */
static atomic_int g_init;

static const struct { const char *n; int e; } kErr[] = {
    { "EINTR", EINTR }, { "EAGAIN", EAGAIN }, { "ECONNRESET", ECONNRESET }, { "EPIPE", EPIPE }, { "ECONNABORTED", ECONNABORTED },
    { "EMFILE", EMFILE }, { "ENOMEM", ENOMEM }, { "ETIMEDOUT", ETIMEDOUT }, { "EBADF", EBADF }, { "EIO", EIO },
};

static void init(void)
{
    if (atomic_exchange(&g_init, 1)) return;
    const char *spec = getenv("FSQL_FAULT");
    if (!spec) return;
    char buf[512];
    strncpy(buf, spec, sizeof buf - 1);
    buf[sizeof buf - 1] = 0;
    for (char *tok = strtok(buf, ","); tok; tok = strtok(NULL, ",")) {
        char *eq = strchr(tok, '=');
        if (!eq) continue;
        *eq = 0;
        char *how = eq + 1, *slash = strchr(how, '/');
        long every = 3;
        if (slash) { *slash = 0; every = atol(slash + 1); if (every < 1) every = 1; }
        for (int c = 0; c < C_COUNT; c++) {
            if (strcmp(tok, kNames[c]) != 0) continue;
            g_f[c].every = every;
            if (!strcmp(how, "short")) g_f[c].mode = 2;
            else if (!strcmp(how, "zero")) g_f[c].mode = 3;
            else for (unsigned k = 0; k < sizeof kErr / sizeof kErr[0]; k++)
                if (!strcmp(how, kErr[k].n)) { g_f[c].mode = 1; g_f[c].err = kErr[k].e; }
        }
    }
}

static int is_socket(int fd)
{
    struct stat st;
    return fd > 2 && fstat(fd, &st) == 0 && S_ISSOCK(st.st_mode);
}

/* 0: pass through; else the mode that fires now */
static int fire(int c)
{
    init();
    if (!g_f[c].mode) return 0;
    long n = atomic_fetch_add(&g_f[c].n, 1) + 1;
    return (n % g_f[c].every == 0) ? g_f[c].mode : 0;
}


ssize_t recv(int fd, void *buf, size_t len, int flags)
{
    typedef ssize_t (*fn_t)(int, void *, size_t, int);
    static fn_t real; if (!real) real = (fn_t) dlsym(RTLD_NEXT, "recv");
    if (is_socket(fd)) {
        int m = fire(C_RECV);
        if (m == 1) { errno = g_f[C_RECV].err; return -1; }
        if (m == 2 && len > 1) len = 1;
        if (m == 3) return 0;
    }
    return real(fd, buf, len, flags);
}

ssize_t send(int fd, const void *buf, size_t len, int flags)
{
    typedef ssize_t (*fn_t)(int, const void *, size_t, int);
    static fn_t real; if (!real) real = (fn_t) dlsym(RTLD_NEXT, "send");
    if (is_socket(fd)) {
        int m = fire(C_SEND);
        if (m == 1) { errno = g_f[C_SEND].err; return -1; }
        if (m == 2 && len > 1) len = 1;
    }
    return real(fd, buf, len, flags);
}

int accept(int fd, struct sockaddr *a, socklen_t *l)
{
    typedef int (*fn_t)(int, struct sockaddr *, socklen_t *);
    static fn_t real; if (!real) real = (fn_t) dlsym(RTLD_NEXT, "accept");
    int m = fire(C_ACCEPT);
    if (m == 1) { errno = g_f[C_ACCEPT].err; return -1; }
    return real(fd, a, l);
}

int accept4(int fd, struct sockaddr *a, socklen_t *l, int flags)
{
    typedef int (*fn_t)(int, struct sockaddr *, socklen_t *, int);
    static fn_t real; if (!real) real = (fn_t) dlsym(RTLD_NEXT, "accept4");
    int m = fire(C_ACCEPT4);
    if (m == 1) { errno = g_f[C_ACCEPT4].err; return -1; }
    return real(fd, a, l, flags);
}

int poll(struct pollfd *fds, nfds_t n, int timeout)
{
    typedef int (*fn_t)(struct pollfd *, nfds_t, int);
    static fn_t real; if (!real) real = (fn_t) dlsym(RTLD_NEXT, "poll");
    int m = fire(C_POLL);
    if (m == 1) { errno = g_f[C_POLL].err; return -1; }
    return real(fds, n, timeout);
}

int connect(int fd, const struct sockaddr *a, socklen_t l)
{
    typedef int (*fn_t)(int, const struct sockaddr *, socklen_t);
    static fn_t real; if (!real) real = (fn_t) dlsym(RTLD_NEXT, "connect");
    int m = fire(C_CONNECT);
    if (m == 1) { errno = g_f[C_CONNECT].err; return -1; }
    return real(fd, a, l);
}

int socket(int d, int t, int p)
{
    typedef int (*fn_t)(int, int, int);
    static fn_t real; if (!real) real = (fn_t) dlsym(RTLD_NEXT, "socket");
    int m = fire(C_SOCKET);
    if (m == 1) { errno = g_f[C_SOCKET].err; return -1; }
    return real(d, t, p);
}

int setsockopt(int fd, int lvl, int opt, const void *v, socklen_t l)
{
    typedef int (*fn_t)(int, int, int, const void *, socklen_t);
    static fn_t real; if (!real) real = (fn_t) dlsym(RTLD_NEXT, "setsockopt");
    int m = fire(C_SETSOCKOPT);
    if (m == 1) { errno = g_f[C_SETSOCKOPT].err; return -1; }
    return real(fd, lvl, opt, v, l);
}
