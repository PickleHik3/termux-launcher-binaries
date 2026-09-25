/*
 * tl-priv — the client half of Termux:Launcher's privileged lane.
 *
 *   tl-priv run <absolute path> [args...]
 *
 * When Shizuku is running and has granted Termux:Launcher, the launcher listens on the abstract
 * unix socket "\0<package>.priv". tl-priv asks it to start <path> as the shell uid (2000) in a
 * pty, receives the pty's master side over SCM_RIGHTS, relays it to the local terminal until the
 * child exits, and exits with the child's status. The launcher stages the binary under
 * /data/local/tmp/tl itself; the path given here names tlstore's copy in ~/.local/lib.
 *
 * Wire protocol, version tlpriv1 — a contract with the launcher; change both sides or neither:
 *   client → server  "tlpriv1\trun\t<path>\t<TERM>\t<rows>\t<cols>[\t<arg>]...\n"
 *   server → client  "ok\t<pid>\n"       the pty master fd rides along as SCM_RIGHTS
 *                    "err\t<message>\n"  refused; the socket then closes
 *                    "exit\t<code>\n"    after the child exited; the socket then closes
 * Closing the socket ends the child (the server kills it on EOF), so a tl-priv that dies takes its
 * child with it, and so does closing the master.
 *
 * Exit status: the child's; 126 when the server refused; 127 when nothing listens on the socket;
 * 1 when the socket closed without an exit line; 2 for a usage error. Messages go to stderr as
 * "tl-priv: ...".
 *
 * Bionic only — no Termux library, no prefix — so one static build serves every edition.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <termios.h>
#include <unistd.h>

#define PROTOCOL "tlpriv1"
#define DEFAULT_PACKAGE "com.termux"
#define EXIT_REFUSED 126
#define EXIT_NO_LANE 127

/* The local terminal's settings, kept so that every way out can put them back. */
static struct termios saved_tty;
static int tty_saved = 0;
static volatile sig_atomic_t winch_pending = 0;
static volatile sig_atomic_t stop_signal = 0;

static void restore_tty(void) {
    if (tty_saved) {
        tcsetattr(STDIN_FILENO, TCSANOW, &saved_tty);
        tty_saved = 0;
    }
}

/* Restores the terminal, prints "tl-priv: <message>" and exits with the given status. */
static void fail(int status, const char *fmt, ...) {
    va_list ap;
    restore_tty();
    fputs("tl-priv: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(status);
}

static void on_winch(int sig) { (void)sig; winch_pending = 1; }
static void on_stop(int sig) { stop_signal = sig; }

/* Writes the whole buffer, across short writes and interrupted calls. */
static int write_all(int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

/* A growable byte buffer, for the request line and for what the server sends back. */
struct buf { char *data; size_t len, cap; };

static void buf_add(struct buf *b, const char *s, size_t n) {
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap * 2 : 256;
        while (cap < b->len + n + 1) cap *= 2;
        char *data = realloc(b->data, cap);
        if (data == NULL) fail(1, "out of memory");
        b->data = data;
        b->cap = cap;
    }
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = '\0';
}

static void buf_str(struct buf *b, const char *s) { buf_add(b, s, strlen(s)); }

/* Moves the first complete line out of the buffer, without its newline. 0 when none is there yet. */
static int take_line(struct buf *in, char *line, size_t size) {
    if (in->len == 0) return 0;
    char *nl = memchr(in->data, '\n', in->len);
    if (nl == NULL) return 0;
    size_t len = (size_t)(nl - in->data);
    if (len >= size) len = size - 1;
    memcpy(line, in->data, len);
    line[len] = '\0';
    size_t rest = in->len - (size_t)(nl - in->data) - 1;
    memmove(in->data, nl + 1, rest);
    in->len = rest;
    in->data[in->len] = '\0';
    return 1;
}

/*
 * The app package this shell belongs to, which names the socket: the launcher exports it; a plain
 * Termux prefix is /data/data/<package>/files/usr; anything else is taken to be stock Termux.
 */
static void package_name(char *out, size_t size) {
    const char *env = getenv("TERMUX_APP__PACKAGE_NAME");
    if (env != NULL && *env != '\0') {
        snprintf(out, size, "%s", env);
        return;
    }
    const char *prefix = getenv("PREFIX");
    const char *head = "/data/data/";
    if (prefix != NULL && strncmp(prefix, head, strlen(head)) == 0) {
        const char *start = prefix + strlen(head);
        const char *end = strchr(start, '/');
        size_t len = end != NULL ? (size_t)(end - start) : strlen(start);
        if (len > 0 && len < size) {
            memcpy(out, start, len);
            out[len] = '\0';
            return;
        }
    }
    snprintf(out, size, "%s", DEFAULT_PACKAGE);
}

/* Connects to the abstract socket "\0<package>.priv". */
static int connect_lane(const char *package) {
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    /* sun_path[0] stays '\0': that is what makes the name abstract. */
    int len = snprintf(addr.sun_path + 1, sizeof addr.sun_path - 1, "%s.priv", package);
    if (len < 0 || (size_t)len >= sizeof addr.sun_path - 1) fail(2, "package name too long: %s", package);
    socklen_t addrlen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + (size_t)len);

    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) fail(1, "socket: %s", strerror(errno));
    if (connect(fd, (struct sockaddr *)&addr, addrlen) < 0) {
        if (errno == ECONNREFUSED || errno == ENOENT)
            fail(EXIT_NO_LANE, "Termux:Launcher's privileged lane isn't running (needs Termux:Launcher with Shizuku)");
        fail(1, "connect: %s", strerror(errno));
    }
    return fd;
}

/* The local terminal's size; 24x80 when there is no terminal to ask. */
static struct winsize local_winsize(void) {
    struct winsize ws;
    if ((ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) < 0 && ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) < 0)
        || ws.ws_row == 0 || ws.ws_col == 0) {
        memset(&ws, 0, sizeof ws);
        ws.ws_row = 24;
        ws.ws_col = 80;
    }
    return ws;
}

/*
 * One recvmsg() into the buffer, keeping any fd that rides along. The "ok" line and its fd are one
 * message on the server side, but nothing says they arrive in one read here, so the fd is taken
 * whenever it shows up and the line is assembled separately. Returns bytes read, 0 at EOF.
 */
static ssize_t recv_chunk(int sock, struct buf *in, int *fd_out) {
    char data[4096];
    char control[CMSG_SPACE(sizeof(int))];
    struct iovec iov = { data, sizeof data };
    struct msghdr msg;
    memset(&msg, 0, sizeof msg);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof control;

    ssize_t n;
    do n = recvmsg(sock, &msg, MSG_CMSG_CLOEXEC); while (n < 0 && errno == EINTR);
    if (n < 0) return -1;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c != NULL; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS) continue;
        int fd;
        memcpy(&fd, CMSG_DATA(c), sizeof fd);
        if (*fd_out < 0) *fd_out = fd;   /* one master is all there is; drop any other */
        else close(fd);
    }
    if (n > 0) buf_add(in, data, (size_t)n);
    return n;
}

int main(int argc, char **argv) {
    if (argc < 3 || strcmp(argv[1], "run") != 0) {
        fputs("usage: tl-priv run <absolute path> [args...]\n", stderr);
        return 2;
    }
    const char *path = argv[2];
    if (path[0] != '/') fail(2, "the program must be an absolute path: %s", path);
    /* The request is one tab-separated line; an argument that could break it is refused here. */
    for (int i = 2; i < argc; i++)
        if (strpbrk(argv[i], "\t\n") != NULL) fail(2, "an argument may not contain a tab or a newline");
    const char *term = getenv("TERM");
    if (term == NULL || *term == '\0' || strpbrk(term, "\t\n") != NULL) term = "xterm-256color";

    char package[128];
    package_name(package, sizeof package);
    int sock = connect_lane(package);

    /* The request. */
    struct winsize ws = local_winsize();
    struct buf req = { NULL, 0, 0 };
    char size[64];
    snprintf(size, sizeof size, "\t%u\t%u", (unsigned)ws.ws_row, (unsigned)ws.ws_col);
    buf_str(&req, PROTOCOL "\trun\t");
    buf_str(&req, path);
    buf_str(&req, "\t");
    buf_str(&req, term);
    buf_str(&req, size);
    for (int i = 3; i < argc; i++) {
        buf_str(&req, "\t");
        buf_str(&req, argv[i]);
    }
    buf_str(&req, "\n");
    if (write_all(sock, req.data, req.len) < 0) fail(1, "could not talk to the lane: %s", strerror(errno));
    free(req.data);

    /* The answer: one line, "ok" with the master fd attached or "err" with the reason. */
    struct buf in = { NULL, 0, 0 };
    int master = -1;
    char line[4096];
    while (!take_line(&in, line, sizeof line)) {
        ssize_t n = recv_chunk(sock, &in, &master);
        if (n < 0) fail(1, "could not read from the lane: %s", strerror(errno));
        if (n == 0) fail(1, "the lane closed without answering");
    }
    if (strncmp(line, "err\t", 4) == 0) fail(EXIT_REFUSED, "%s", line + 4);
    if (strncmp(line, "ok\t", 3) != 0) fail(1, "unexpected answer from the lane: %s", line);
    if (master < 0) fail(1, "the lane said ok but sent no terminal");

    /*
     * Raw mode: keys go to the child untranslated and the child's own tty does the echoing. The
     * settings are restored on every exit — normal, fail() and the signals handled below. The
     * handlers only set a flag and are installed without SA_RESTART, so poll() returns EINTR and
     * the loop acts on it.
     */
    if (isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &saved_tty) == 0) {
        struct termios raw = saved_tty;
        cfmakeraw(&raw);
        tty_saved = 1;
        atexit(restore_tty);
        tcsetattr(STDIN_FILENO, TCSANOW, &raw);
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_winch;
    sigaction(SIGWINCH, &sa, NULL);
    sa.sa_handler = on_stop;
    sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);   /* only ever raised when stdin is not a raw terminal */
    signal(SIGPIPE, SIG_IGN);
    ioctl(master, TIOCSWINSZ, &ws);

    /*
     * The relay: stdin → master, master → stdout, until the master reports EOF or EIO, which is
     * the child being gone. The socket is watched too, so an exit line that arrives before the
     * last of the output is kept in the buffer rather than lost.
     */
    struct pollfd fds[3] = {
        { STDIN_FILENO, POLLIN, 0 },
        { master, POLLIN, 0 },
        { sock, POLLIN, 0 },
    };
    int stdin_open = 1, sock_open = 1;
    static char io[65536];
    for (;;) {
        if (stop_signal) break;
        if (winch_pending) {
            winch_pending = 0;
            struct winsize now = local_winsize();
            ioctl(master, TIOCSWINSZ, &now);
        }
        fds[0].fd = stdin_open ? STDIN_FILENO : -1;
        fds[2].fd = sock_open ? sock : -1;
        if (poll(fds, 3, -1) < 0) {
            if (errno == EINTR) continue;
            fail(1, "poll: %s", strerror(errno));
        }
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t n = read(STDIN_FILENO, io, sizeof io);
            if (n > 0) {
                if (write_all(master, io, (size_t)n) < 0) break;
            } else if (n == 0 || (errno != EINTR && errno != EAGAIN)) {
                stdin_open = 0;   /* the child keeps running; only its input is over */
            }
        }
        if (fds[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t n = read(master, io, sizeof io);
            if (n > 0) {
                if (write_all(STDOUT_FILENO, io, (size_t)n) < 0) break;
            } else if (n == 0 || (errno != EINTR && errno != EAGAIN)) {
                break;   /* EOF or EIO: the child has gone */
            }
        }
        if (fds[2].revents & (POLLIN | POLLHUP | POLLERR)) {
            if (recv_chunk(sock, &in, &master) <= 0) sock_open = 0;
        }
    }
    close(master);
    restore_tty();
    if (stop_signal) {
        /* Leaving closes the socket, and the server ends the child on EOF. */
        return 128 + (int)stop_signal;
    }

    /* The child is gone; the lane says how it went. The line may already be in the buffer. */
    int status = 1;
    for (;;) {
        if (take_line(&in, line, sizeof line)) {
            if (strncmp(line, "exit\t", 5) == 0) {
                status = (int)strtol(line + 5, NULL, 10);
                break;
            }
            continue;   /* anything else is not ours to interpret */
        }
        if (!sock_open) break;
        if (recv_chunk(sock, &in, &master) <= 0) break;
    }
    close(sock);
    free(in.data);
    return status;
}
