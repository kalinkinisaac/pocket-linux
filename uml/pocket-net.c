/*
 * pocket-net — rootless networking for a User-Mode Linux guest.
 *
 * Creates an AF_UNIX SOCK_SEQPACKET socketpair, starts the UML kernel with one end
 * as its NIC (vecN:transport=fd,fd=<n>) and runs libslirp (the same user-mode NAT QEMU
 * uses for -netdev user) on the other end. No root, no tap, no capabilities.
 *
 *   pocket-net [-p tcp:HOSTPORT:GUESTPORT]... [-b BINDADDR] [-i vec0] [-m MTU] [-q] -- /path/linux-uml [args...]
 *
 * Guest network (same as QEMU user networking): 10.0.2.0/24, gateway 10.0.2.2,
 * DNS 10.0.2.3, DHCP from 10.0.2.15; IPv6 fec0::/64. Host is reachable as 10.0.2.2.
 * pocket-net exits with the exit status of the kernel and forwards SIGINT/SIGTERM/SIGHUP to it.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <libslirp.h>

#define MAX_FWD 64
#define MAX_POLL 1024
#define MAX_TIMERS 64
#define FRAME_MAX 65536

static int net_fd = -1;
static int quiet;
static volatile sig_atomic_t got_sig, child_done;
static pid_t child = -1;

struct ptimer { int used; int64_t expire; SlirpTimerId id; void *cb_opaque; };
static struct ptimer timers[MAX_TIMERS];
static struct pollfd pfds[MAX_POLL];
static int npfds;

static void logmsg(const char *fmt, ...)
{
    if (quiet) return;
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "pocket-net: "); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
    va_end(ap);
}

static int64_t now_ns(void)
{
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* ---------------- slirp callbacks ---------------- */
static slirp_ssize_t cb_send_packet(const void *buf, size_t len, void *opaque)
{
    (void)opaque;
    for (;;) {
        ssize_t n = send(net_fd, buf, len, MSG_NOSIGNAL);
        if (n >= 0) return n;
        if (errno == EINTR) continue;
        /* guest queue full / gone: drop the frame, TCP will retransmit */
        return (slirp_ssize_t)len;
    }
}
static void cb_guest_error(const char *msg, void *opaque) { (void)opaque; logmsg("guest error: %s", msg); }
static int64_t cb_clock_get_ns(void *opaque) { (void)opaque; return now_ns(); }
static void *cb_timer_new_opaque(SlirpTimerId id, void *cb_opaque, void *opaque)
{
    (void)opaque;
    for (int i = 0; i < MAX_TIMERS; i++)
        if (!timers[i].used) {
            timers[i] = (struct ptimer){ .used = 1, .expire = -1, .id = id, .cb_opaque = cb_opaque };
            return &timers[i];
        }
    logmsg("out of timers"); abort();
}
static void cb_timer_free(void *t, void *opaque) { (void)opaque; ((struct ptimer *)t)->used = 0; }
/* expire_time is in milliseconds on the clock_get_ns() time base (same as QEMU) */
static void cb_timer_mod(void *t, int64_t expire_ms, void *opaque) { (void)opaque; ((struct ptimer *)t)->expire = expire_ms; }
static void cb_register_poll_fd(int fd, void *opaque) { (void)fd; (void)opaque; }
static void cb_unregister_poll_fd(int fd, void *opaque) { (void)fd; (void)opaque; }
static void cb_notify(void *opaque) { (void)opaque; }

static int add_poll(int fd, int events, void *opaque)
{
    (void)opaque;
    if (npfds >= MAX_POLL) return -1;
    short ev = 0;
    if (events & SLIRP_POLL_IN)  ev |= POLLIN;
    if (events & SLIRP_POLL_OUT) ev |= POLLOUT;
    if (events & SLIRP_POLL_PRI) ev |= POLLPRI;
    if (events & SLIRP_POLL_ERR) ev |= POLLERR;
    if (events & SLIRP_POLL_HUP) ev |= POLLHUP;
    pfds[npfds] = (struct pollfd){ .fd = fd, .events = ev };
    return npfds++;
}
static int get_revents(int idx, void *opaque)
{
    (void)opaque;
    if (idx < 0 || idx >= npfds) return 0;
    short r = pfds[idx].revents; int ev = 0;
    if (r & POLLIN)  ev |= SLIRP_POLL_IN;
    if (r & POLLOUT) ev |= SLIRP_POLL_OUT;
    if (r & POLLPRI) ev |= SLIRP_POLL_PRI;
    if (r & POLLERR) ev |= SLIRP_POLL_ERR;
    if (r & POLLHUP) ev |= SLIRP_POLL_HUP;
    return ev;
}

static void on_signal(int sig)
{
    if (sig == SIGCHLD) { child_done = 1; return; }
    got_sig = sig;
}

static void usage(void)
{
    fprintf(stderr,
        "usage: pocket-net [-p tcp|udp:HOSTPORT:GUESTPORT]... [-b BINDADDR] [-i vec0] [-m MTU] [-q] -- KERNEL [ARGS...]\n"
        "  -p  forward host port to guest (repeatable), e.g. -p tcp:2222:22\n"
        "  -b  host address for forwards (default 127.0.0.1)\n"
        "  -i  guest interface name passed to UML (default vec0)\n"
        "  -m  MTU (default 1500)\n"
        "  -q  quiet\n");
    exit(2);
}

int main(int argc, char **argv)
{
    struct { int udp, hport, gport; } fwd[MAX_FWD];
    int nfwd = 0, mtu = 1500;
    const char *bind_addr = "127.0.0.1", *ifname = "vec0";
    int opt;
    while ((opt = getopt(argc, argv, "+p:b:i:m:qh")) != -1) {
        switch (opt) {
        case 'p': {
            if (nfwd >= MAX_FWD) usage();
            char proto[8] = "tcp"; int h, g;
            if (sscanf(optarg, "%7[a-z]:%d:%d", proto, &h, &g) == 3) {}
            else if (sscanf(optarg, "%d:%d", &h, &g) == 2) strcpy(proto, "tcp");
            else usage();
            fwd[nfwd].udp = strcmp(proto, "udp") == 0; fwd[nfwd].hport = h; fwd[nfwd].gport = g; nfwd++;
            break; }
        case 'b': bind_addr = optarg; break;
        case 'i': ifname = optarg; break;
        case 'm': mtu = atoi(optarg); break;
        case 'q': quiet = 1; break;
        default: usage();
        }
    }
    if (optind >= argc) usage();

    int sv[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv) < 0) { perror("socketpair"); return 1; }
    int bufsz = 4 << 20;
    for (int i = 0; i < 2; i++) {
        setsockopt(sv[i], SOL_SOCKET, SO_SNDBUF, &bufsz, sizeof bufsz);
        setsockopt(sv[i], SOL_SOCKET, SO_RCVBUF, &bufsz, sizeof bufsz);
    }
    fcntl(sv[0], F_SETFD, FD_CLOEXEC);

    struct sigaction sa = { .sa_handler = on_signal };
    sigemptyset(&sa.sa_mask);
    sigaction(SIGCHLD, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    child = fork();
    if (child < 0) { perror("fork"); return 1; }
    if (child == 0) {
        close(sv[0]);
        prctl(PR_SET_PDEATHSIG, SIGTERM);
        signal(SIGPIPE, SIG_DFL);
        int n = argc - optind;
        char **cargv = calloc(n + 2, sizeof(char *));
        for (int i = 0; i < n; i++) cargv[i] = argv[optind + i];
        char *vec; /* e.g. vec0:transport=fd,fd=4,mac=52:54:00:12:34:56 */
        if (asprintf(&vec, "%s:transport=fd,fd=%d,mtu=%d,mac=52:54:00:12:34:56", ifname, sv[1], mtu) < 0) _exit(127);
        cargv[n] = vec; cargv[n + 1] = NULL;
        execv(cargv[0], cargv);
        perror(cargv[0]);
        _exit(127);
    }
    close(sv[1]);
    net_fd = sv[0];

    SlirpConfig cfg;
    memset(&cfg, 0, sizeof cfg);
    cfg.version = 4;
    cfg.in_enabled = true;
    inet_pton(AF_INET, "10.0.2.0", &cfg.vnetwork);
    inet_pton(AF_INET, "255.255.255.0", &cfg.vnetmask);
    inet_pton(AF_INET, "10.0.2.2", &cfg.vhost);
    inet_pton(AF_INET, "10.0.2.15", &cfg.vdhcp_start);
    inet_pton(AF_INET, "10.0.2.3", &cfg.vnameserver);
    cfg.in6_enabled = true;
    inet_pton(AF_INET6, "fec0::", &cfg.vprefix_addr6);
    cfg.vprefix_len = 64;
    inet_pton(AF_INET6, "fec0::2", &cfg.vhost6);
    inet_pton(AF_INET6, "fec0::3", &cfg.vnameserver6);
    cfg.vhostname = "pocket";
    cfg.if_mtu = mtu;
    cfg.if_mru = mtu;

    static const SlirpCb cb = {
        .send_packet = cb_send_packet,
        .guest_error = cb_guest_error,
        .clock_get_ns = cb_clock_get_ns,
        .timer_free = cb_timer_free,
        .timer_mod = cb_timer_mod,
        .register_poll_fd = cb_register_poll_fd,
        .unregister_poll_fd = cb_unregister_poll_fd,
        .notify = cb_notify,
        .timer_new_opaque = cb_timer_new_opaque,
    };
    Slirp *slirp = slirp_new(&cfg, &cb, NULL);
    if (!slirp) { logmsg("slirp_new failed"); kill(child, SIGTERM); return 1; }

    struct in_addr host_addr, guest_addr;
    if (inet_pton(AF_INET, bind_addr, &host_addr) != 1) { logmsg("bad bind address %s", bind_addr); return 2; }
    inet_pton(AF_INET, "10.0.2.15", &guest_addr);
    for (int i = 0; i < nfwd; i++) {
        if (slirp_add_hostfwd(slirp, fwd[i].udp, host_addr, fwd[i].hport, guest_addr, fwd[i].gport) < 0)
            logmsg("cannot forward %s %s:%d -> %d (port busy?)", fwd[i].udp ? "udp" : "tcp", bind_addr, fwd[i].hport, fwd[i].gport);
        else
            logmsg("forward %s %s:%d -> guest:%d", fwd[i].udp ? "udp" : "tcp", bind_addr, fwd[i].hport, fwd[i].gport);
    }

    static unsigned char frame[FRAME_MAX];
    int status = 0;
    for (;;) {
        if (got_sig) { kill(child, got_sig); got_sig = 0; }
        if (child_done) {
            pid_t r = waitpid(child, &status, WNOHANG);
            if (r == child) break;
            child_done = 0;
        }

        npfds = 0;
        int self = add_poll(net_fd, SLIRP_POLL_IN, NULL);
        uint32_t timeout = 1000;
        slirp_pollfds_fill(slirp, &timeout, add_poll, NULL);
        int64_t now_ms = now_ns() / 1000000;
        for (int i = 0; i < MAX_TIMERS; i++)
            if (timers[i].used && timers[i].expire >= 0) {
                int64_t d = timers[i].expire - now_ms;
                if (d < 0) d = 0;
                if ((uint32_t)d < timeout) timeout = (uint32_t)d;
            }

        int ret = poll(pfds, npfds, (int)timeout);
        if (ret < 0 && errno != EINTR) { perror("poll"); break; }

        if (ret > 0 && (pfds[self].revents & POLLIN)) {
            for (int k = 0; k < 256; k++) {
                ssize_t n = recv(net_fd, frame, sizeof frame, MSG_DONTWAIT);
                if (n <= 0) break;
                slirp_input(slirp, frame, (int)n);
            }
        }
        slirp_pollfds_poll(slirp, ret < 0, get_revents, NULL);

        now_ms = now_ns() / 1000000;
        for (int i = 0; i < MAX_TIMERS; i++)
            if (timers[i].used && timers[i].expire >= 0 && timers[i].expire <= now_ms) {
                timers[i].expire = -1;
                slirp_handle_timer(slirp, timers[i].id, timers[i].cb_opaque);
            }
    }
    slirp_cleanup(slirp);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 0;
}
