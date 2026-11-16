/* The shared clipboard of host/share.c over its Unix socket, as the guest's helper uses it: the slot's
   sequence numbers and origin, the long poll, loop and overtaking protection, the size cap, UTF-8
   checks, malformed requests, the app's listener and the helper's status. No network, no VM. */
#include "share.h"

#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

/* share.c forwards ports for OAuth callbacks through the network; not here. */
void hv_net_add_hostfwd(int host_port, int guest_port) {
    (void)host_port;
    (void)guest_port;
}

static char sock_path[104];
static int failures;

#define CHECK(cond, ...)                                                                                                          \
    do {                                                                                                                          \
        if (!(cond)) {                                                                                                            \
            fprintf(stderr, "FAIL %s:%d: %s: ", __FILE__, __LINE__, #cond);                                                       \
            fprintf(stderr, __VA_ARGS__);                                                                                         \
            fprintf(stderr, "\n");                                                                                                \
            failures++;                                                                                                           \
        }                                                                                                                         \
    } while (0)

typedef struct Reply {
    int status;
    unsigned long seq;
    char origin[16];
    char *body;
    size_t len;
} Reply;

static double now_s(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

static int dial(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    snprintf(a.sun_path, sizeof a.sun_path, "%s", sock_path);
    if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a) != 0) {
        perror("connect");
        exit(1);
    }
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    return fd;
}

static void send_all(int fd, const void *p, size_t n) {
    const char *c = p;
    while (n) {
        ssize_t w = send(fd, c, n, 0);
        if (w <= 0) return; /* the server may close early (413): the reply is still there */
        c += w, n -= (size_t)w;
    }
}

/* Reads the reply to the end of the connection and splits it. */
static Reply read_reply(int fd) {
    Reply r = {0};
    size_t cap = 1 << 16, len = 0;
    char *all = malloc(cap);
    for (;;) {
        if (len + 4096 > cap) all = realloc(all, cap *= 2);
        ssize_t got = recv(fd, all + len, cap - len - 1, 0);
        if (got <= 0) break;
        len += (size_t)got;
    }
    close(fd);
    all[len] = 0;
    sscanf(all, "HTTP/1.1 %d", &r.status);
    char *end = strstr(all, "\r\n\r\n");
    if (end) {
        *end = 0;
        const char *h = strstr(all, "X-Henge-Seq: ");
        if (h) r.seq = strtoul(h + 13, NULL, 10);
        h = strstr(all, "X-Henge-Origin: ");
        if (h) sscanf(h + 16, "%15[a-z]", r.origin);
        r.len = len - (size_t)(end + 4 - all);
        r.body = malloc(r.len + 1);
        memcpy(r.body, end + 4, r.len);
        r.body[r.len] = 0;
    }
    free(all);
    return r;
}

static Reply request(const char *method, const char *target, const void *body, size_t len) {
    int fd = dial();
    char head[512];
    int n = snprintf(head, sizeof head, "%s %s HTTP/1.1\r\nHost: 10.0.2.4\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n", method,
                     target, len);
    send_all(fd, head, (size_t)n);
    if (len) send_all(fd, body, len);
    return read_reply(fd);
}

static Reply raw(const void *bytes, size_t len) {
    int fd = dial();
    send_all(fd, bytes, len);
    shutdown(fd, SHUT_WR);
    return read_reply(fd);
}

static Reply put_text(const char *target, const char *text) { return request("PUT", target, text, strlen(text)); }

/* ---- the app's listener ---- */

static pthread_mutex_t heard_mu = PTHREAD_MUTEX_INITIALIZER;
static unsigned long heard_seq;
static int heard_count;

static void on_guest_clip(unsigned long seq, void *opaque) {
    CHECK(opaque == &heard_count, "listener opaque");
    pthread_mutex_lock(&heard_mu);
    heard_seq = seq;
    heard_count++;
    pthread_mutex_unlock(&heard_mu);
}

static int heard(unsigned long *seq) {
    pthread_mutex_lock(&heard_mu);
    int n = heard_count;
    if (seq) *seq = heard_seq;
    pthread_mutex_unlock(&heard_mu);
    return n;
}

/* ---- a long poll on its own thread ---- */

typedef struct Poll {
    char target[64];
    Reply reply;
    double took;
} Poll;

static void *poll_thread(void *arg) {
    Poll *p = arg;
    double t0 = now_s();
    p->reply = request("GET", p->target, NULL, 0);
    p->took = now_s() - t0;
    return NULL;
}

static void free_reply(Reply *r) {
    free(r->body);
    r->body = NULL;
}

static void test_utf8(void) {
    static const struct {
        const char *s;
        size_t len;
        int ok;
    } cases[] = {
        {"", 0, 1},
        {"plain ascii", 11, 1},
        {"caf\xc3\xa9", 5, 1},
        {"\xe4\xb8\xad\xe6\x96\x87", 6, 1},        /* 中文 */
        {"\xf0\x9f\x98\x80", 4, 1},                /* an emoji (4 bytes) */
        {"\xf4\x8f\xbf\xbf", 4, 1},                /* U+10FFFF */
        {"\xff", 1, 0},                            /* never in UTF-8 */
        {"\x80", 1, 0},                            /* a continuation byte first */
        {"\xc0\xaf", 2, 0},                        /* overlong '/' */
        {"\xe0\x80\xaf", 3, 0},                    /* overlong, three bytes */
        {"\xed\xa0\x80", 3, 0},                    /* a UTF-16 surrogate */
        {"\xf4\x90\x80\x80", 4, 0},                /* past U+10FFFF */
        {"\xe2\x82", 2, 0},                        /* cut short */
        {"a\xc3", 2, 0},                           /* cut short at the end */
        {"a\0b", 3, 0},                            /* NUL */
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++)
        CHECK(hv_share_clip_valid(cases[i].s, cases[i].len) == cases[i].ok, "utf8 case %zu", i);
    CHECK(!hv_share_clip_valid(NULL, 0), "NULL");
    char *big = malloc(HV_SHARE_CLIP_MAX + 1);
    memset(big, 'x', HV_SHARE_CLIP_MAX + 1);
    CHECK(hv_share_clip_valid(big, HV_SHARE_CLIP_MAX), "exactly the cap");
    CHECK(!hv_share_clip_valid(big, HV_SHARE_CLIP_MAX + 1), "past the cap");
    free(big);
}

int main(void) {
    test_utf8();

    char dir[] = "/tmp/hvclip.XXXXXX";
    if (!mkdtemp(dir)) {
        perror("mkdtemp");
        return 1;
    }
    snprintf(sock_path, sizeof sock_path, "%s/s.sock", dir);
    if (hv_share_start(dir, sock_path, NULL) != 0) {
        fprintf(stderr, "hv_share_start failed\n");
        return 1;
    }
    hv_share_set_clipboard_listener(on_guest_clip, &heard_count);
    CHECK(hv_share_clipboard_agent_seen() == -1, "never seen yet");

    /* Empty at first. */
    Reply r = request("GET", "/.henge/clipboard", NULL, 0);
    CHECK(r.status == 204 && r.seq == 0 && r.len == 0, "empty: %d seq %lu", r.status, r.seq);
    free_reply(&r);
    long seen = hv_share_clipboard_agent_seen();
    CHECK(seen >= 0 && seen <= 1, "seen after a request: %ld", seen);

    /* The device copies: the helper gets it, from the host. */
    CHECK(hv_share_set_clipboard("caf\xc3\xa9 \xe4\xb8\xad") == 1, "first copy is seq 1");
    CHECK(hv_share_set_clipboard("caf\xc3\xa9 \xe4\xb8\xad") == 0, "the same text again changes nothing");
    CHECK(hv_share_set_clipboard("") == 0, "empty refused");
    CHECK(hv_share_set_clipboard("\xff") == 0, "not UTF-8 refused");
    CHECK(hv_share_set_clipboard(NULL) == 0, "NULL refused");
    r = request("GET", "/.henge/clipboard", NULL, 0);
    CHECK(r.status == 200 && r.seq == 1 && !strcmp(r.origin, "host") && !strcmp(r.body, "caf\xc3\xa9 \xe4\xb8\xad"), "host text: %d %lu %s",
          r.status, r.seq, r.origin);
    free_reply(&r);
    CHECK(hv_share_take_clipboard() == NULL, "the device's own text is not news for the device");

    /* A long poll is answered as soon as the device copies. */
    Poll p = {.target = "/.henge/clipboard?since=1"};
    pthread_t t;
    pthread_create(&t, NULL, poll_thread, &p);
    usleep(300 * 1000);
    CHECK(hv_share_clipboard_agent_seen() == 0, "a waiting poll counts as alive");
    CHECK(hv_share_set_clipboard("next") == 2, "seq 2");
    pthread_join(t, NULL);
    CHECK(p.reply.status == 200 && p.reply.seq == 2 && !strcmp(p.reply.body, "next"), "long poll: %d %lu", p.reply.status, p.reply.seq);
    CHECK(p.took < 2.0, "long poll answered at once (%.2f s)", p.took);
    free_reply(&p.reply);
    CHECK(hv_share_clipboard_agent_has() == 1, "the helper had 1: %lu", hv_share_clipboard_agent_has());

    /* With nothing new it waits as long as asked, then says what there is. */
    double t0 = now_s();
    r = request("GET", "/.henge/clipboard?since=2&wait=1", NULL, 0);
    double took = now_s() - t0;
    CHECK(r.status == 200 && r.seq == 2 && took >= 0.9 && took < 3, "timeout: %d seq %lu after %.2f s", r.status, r.seq, took);
    free_reply(&r);

    /* A number from before the app restarted is answered at once. */
    t0 = now_s();
    r = request("GET", "/.henge/clipboard?since=99", NULL, 0);
    CHECK(r.status == 200 && r.seq == 2 && now_s() - t0 < 1, "stale since");
    free_reply(&r);
    CHECK(hv_share_clipboard_agent_has() == 2, "a stale since= is not taken as had: %lu", hv_share_clipboard_agent_has());

    /* The guest copies: the app hears of it, once. */
    r = put_text("/.henge/clipboard?agent=a1&n=1", "from windows \xf0\x9f\x98\x80");
    CHECK(r.status == 204 && r.seq == 3, "guest put: %d %lu", r.status, r.seq);
    free_reply(&r);
    unsigned long hs = 0;
    CHECK(heard(&hs) == 1 && hs == 3, "listener: %d, seq %lu", heard(NULL), hs);
    char *taken = hv_share_take_clipboard();
    CHECK(taken && !strcmp(taken, "from windows \xf0\x9f\x98\x80"), "take");
    free(taken);
    CHECK(hv_share_take_clipboard() == NULL, "take only once");
    unsigned long seq = 0;
    int origin = -1;
    char *now = hv_share_get_clipboard(&seq, &origin);
    CHECK(now && seq == 3 && origin == HV_SHARE_CLIP_FROM_GUEST, "get: seq %lu origin %d", seq, origin);
    free(now);
    r = request("GET", "/.henge/clipboard?since=2", NULL, 0);
    CHECK(r.status == 200 && !strcmp(r.origin, "guest"), "origin guest: %s", r.origin);
    free_reply(&r);

    /* Loops stop: the guest's text again from the guest, or sent back by the device, is no change. */
    r = put_text("/.henge/clipboard?agent=a1&n=2", "from windows \xf0\x9f\x98\x80");
    CHECK(r.status == 204 && r.seq == 3 && heard(NULL) == 1, "same text from the guest: seq %lu heard %d", r.seq, heard(NULL));
    free_reply(&r);
    CHECK(hv_share_set_clipboard("from windows \xf0\x9f\x98\x80") == 0, "the device sending the guest's text back");
    /* ...unless the person sends it on purpose. */
    CHECK(hv_share_push_clipboard("from windows \xf0\x9f\x98\x80") == 4, "a push is always a change");
    now = hv_share_get_clipboard(&seq, &origin);
    CHECK(seq == 4 && origin == HV_SHARE_CLIP_FROM_DEVICE, "pushed: %lu %d", seq, origin);
    free(now);

    /* The device's text copied in the guest is the guest's copy (the person copied it there to get it
       back on the device, which may hold something else by now), and so is a forced repeat. */
    r = put_text("/.henge/clipboard?agent=a1&n=3", "from windows \xf0\x9f\x98\x80");
    CHECK(r.status == 204 && r.seq == 5 && !strcmp(r.origin, "guest"), "the device's text from the guest: %lu %s", r.seq, r.origin);
    free_reply(&r);
    CHECK(heard(&hs) == 2 && hs == 5, "told of it: %d %lu", heard(NULL), hs);
    r = put_text("/.henge/clipboard?agent=a1&n=4", "from windows \xf0\x9f\x98\x80");
    CHECK(r.seq == 5, "then a repeat again: %lu", r.seq);
    free_reply(&r);
    r = put_text("/.henge/clipboard?agent=a1&n=5&force=1", "from windows \xf0\x9f\x98\x80");
    CHECK(r.seq == 6 && heard(NULL) == 2, "force=1 is a change (still pending, so not told again): %lu", r.seq);
    free_reply(&r);
    taken = hv_share_take_clipboard();
    CHECK(taken && !strcmp(taken, "from windows \xf0\x9f\x98\x80"), "take the guest's copy");
    free(taken);
    CHECK(hv_share_push_clipboard("pushed again") == 7, "the device again");
    CHECK(hv_share_push_clipboard("\xc0\xaf") == 0 && hv_share_push_clipboard("") == 0, "a push is still checked");

    /* A PUT overtaken by a newer one from the same helper is dropped; another helper's is not. */
    r = put_text("/.henge/clipboard?agent=a1&n=7", "seven");
    CHECK(r.seq == 8, "n=7: %lu", r.seq);
    free_reply(&r);
    r = put_text("/.henge/clipboard?agent=a1&n=6", "six");
    CHECK(r.status == 204 && r.seq == 8, "n=6 dropped: %lu", r.seq);
    free_reply(&r);
    r = put_text("/.henge/clipboard?agent=b2&n=1", "other helper");
    CHECK(r.seq == 9, "a restarted helper: %lu", r.seq);
    free_reply(&r);
    r = put_text("/.henge/clipboard", "no count");
    CHECK(r.seq == 10, "without agent/n: %lu", r.seq);
    free_reply(&r);
    /* Told once until the app takes it: seven was news, the rest came while it still waited. */
    CHECK(heard(NULL) == 3, "heard %d", heard(NULL));

    /* Empty is no change; a byte order mark is dropped. */
    r = put_text("/.henge/clipboard", "");
    CHECK(r.status == 204 && r.seq == 10, "empty put");
    free_reply(&r);
    r = put_text("/.henge/clipboard", "\xef\xbb\xbf" "bom");
    now = hv_share_get_clipboard(NULL, NULL);
    CHECK(r.seq == 11 && now && !strcmp(now, "bom"), "bom");
    free(now);
    free_reply(&r);

    /* Not UTF-8 text: refused, and the slot stays. */
    static const char *bad[] = {"\xff\xfe", "a\xc0\xaf", "\xed\xa0\x80", "trail\xe2\x82", "\xf4\x90\x80\x80"};
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        r = put_text("/.henge/clipboard", bad[i]);
        CHECK(r.status == 400, "bad %zu: %d", i, r.status);
        free_reply(&r);
    }
    r = request("PUT", "/.henge/clipboard", "a\0b", 3);
    CHECK(r.status == 400, "NUL: %d", r.status);
    free_reply(&r);

    /* Too large: by its Content-Length, and chunked (no length up front). */
    size_t big_len = HV_SHARE_CLIP_MAX + 1;
    char *big = malloc(big_len);
    memset(big, 'y', big_len);
    r = request("PUT", "/.henge/clipboard", big, big_len);
    CHECK(r.status == 413, "too large: %d", r.status);
    free_reply(&r);
    r = request("PUT", "/.henge/clipboard", big, HV_SHARE_CLIP_MAX);
    CHECK(r.status == 204 && r.seq == 12, "exactly the cap: %d %lu", r.status, r.seq);
    free_reply(&r);
    {
        int fd = dial();
        const char *head = "PUT /.henge/clipboard HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n";
        send_all(fd, head, strlen(head));
        char line[32];
        for (size_t sent = 0; sent < big_len + 65536; sent += 65536) {
            int n = snprintf(line, sizeof line, "%x\r\n", 65536);
            send_all(fd, line, (size_t)n);
            send_all(fd, big, 65536);
            send_all(fd, "\r\n", 2);
        }
        send_all(fd, "0\r\n\r\n", 5);
        r = read_reply(fd);
        CHECK(r.status == 413, "chunked too large: %d", r.status);
        free_reply(&r);
    }
    free(big);
    now = hv_share_get_clipboard(&seq, NULL);
    CHECK(seq == 12 && now && strlen(now) == HV_SHARE_CLIP_MAX, "slot unchanged by refused PUTs: %lu", seq);
    free(now);

    /* Malformed requests: answered or dropped, and the server carries on. */
    static const char *junk[] = {"\r\n\r\n", "GARBAGE\r\n\r\n", "GET\r\n\r\n", "PUT /.henge/clipboard HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc",
                                 "PUT /.henge/clipboard HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n",
                                 "GET /.henge/clipboard?since=abc&wait=-5 HTTP/1.1\r\nConnection: close\r\n\r\n"};
    for (size_t i = 0; i < sizeof junk / sizeof junk[0]; i++) {
        r = raw(junk[i], strlen(junk[i]));
        free_reply(&r);
    }
    r = request("GET", "/.henge/clipboard", NULL, 0);
    CHECK(r.status == 200 && r.seq == 12, "still serving: %d %lu", r.status, r.seq);
    free_reply(&r);
    r = request("DELETE", "/.henge/clipboard", NULL, 0);
    CHECK(r.status == 404, "other methods: %d", r.status);
    free_reply(&r);

    /* A guest that PUTs over and over: one notification in flight until the app takes the text, and
       the take gets the newest. Then the next copy is news again. */
    taken = hv_share_take_clipboard();
    CHECK(taken && strlen(taken) == HV_SHARE_CLIP_MAX, "the newest before the flood");
    free(taken);
    int before = heard(NULL);
    for (int i = 0; i < 300; i++) {
        char t[32];
        snprintf(t, sizeof t, "flood %d", i);
        r = put_text("/.henge/clipboard", i % 2 ? t : "flood"); /* each one a change */
        free_reply(&r);
    }
    CHECK(heard(&hs) == before + 1 && hs == 13, "flood: heard %d more, seq %lu", heard(NULL) - before, hs);
    taken = hv_share_take_clipboard();
    CHECK(taken && !strcmp(taken, "flood 299"), "the newest after the flood: %s", taken ? taken : "(none)");
    free(taken);
    CHECK(hv_share_take_clipboard() == NULL, "taken once");
    r = put_text("/.henge/clipboard", "after the flood");
    free_reply(&r);
    CHECK(heard(NULL) == before + 2, "news again after the take: %d", heard(NULL) - before);
    free(hv_share_take_clipboard());

    unlink(sock_path);
    rmdir(dir);
    if (failures) {
        fprintf(stderr, "test_share_clip: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_share_clip: ok\n");
    return 0;
}
