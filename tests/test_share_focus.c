// SPDX-License-Identifier: GPL-2.0-or-later
/* /.henge/focus of host/share.c over its Unix socket, as the WinKit focus agent (winkit/FocusAgent.cs)
   uses it: reports reach the app's handler (heartbeats do not), text from the iOS keyboard is handed out
   once (UTF-8, \b kept), the long poll gets text queued while it waits and times out with 204, the busy
   flag, and no text is taken while no agent was ever heard from. An agent in a session that is not on the
   screen (&active=0) is not the agent: its reports are dropped and it never takes the text. No network,
   no VM. */
#include "share.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* share.c forwards ports for OAuth callbacks through the network; not here. */
void hv_net_add_hostfwd(int host_port, int guest_port) {
    (void)host_port;
    (void)guest_port;
}

static char sock_path[104];
static char got[4096];
static int calls;
static int failures;

#define CHECK(c)                                                                                                                  \
    do {                                                                                                                          \
        if (!(c)) {                                                                                                               \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);                                                          \
            failures++;                                                                                                           \
        }                                                                                                                         \
    } while (0)

static void handler(const char *json, size_t len, void *opaque) {
    (void)opaque;
    snprintf(got, sizeof got, "%.*s", (int)len, json);
    calls++;
}

/* One request on its own connection; the status, and the whole reply in out. */
static int req(const char *method, const char *path, const char *body, char *out, size_t cap) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    snprintf(a.sun_path, sizeof a.sun_path, "%s", sock_path);
    if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a) != 0) {
        perror("connect");
        exit(1);
    }
    char head[1024];
    int n = snprintf(head, sizeof head, "%s %s HTTP/1.1\r\nHost: x\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s",
                     method, path, strlen(body), body);
    for (int at = 0; at < n;) {
        ssize_t w = write(fd, head + at, (size_t)(n - at));
        if (w <= 0) break;
        at += (int)w;
    }
    size_t at = 0;
    ssize_t g;
    while (at + 1 < cap && (g = read(fd, out + at, cap - 1 - at)) > 0) at += (size_t)g;
    out[at] = 0;
    close(fd);
    return at > 12 ? atoi(out + 9) : -1;
}

static void *later(void *arg) {
    (void)arg;
    usleep(300000);
    hv_share_focus_send_text("\xe4\xbd\xa0\xe5\xa5\xbd b\b");
    return NULL;
}

int main(void) {
    char dir[] = "/tmp/hvfocus.XXXXXX";
    if (!mkdtemp(dir)) {
        perror("mkdtemp");
        return 1;
    }
    snprintf(sock_path, sizeof sock_path, "%s/s.sock", dir);
    if (hv_share_start(dir, sock_path, NULL) != 0) {
        fprintf(stderr, "hv_share_start failed\n");
        return 1;
    }
    hv_share_set_focus_handler(handler, NULL);
    char out[4096];
    CHECK(hv_share_focus_agent_seen() == -1);
    CHECK(hv_share_focus_send_text("x") == -1); /* no agent yet */
    /* an agent in another session: not counted, its report dropped */
    CHECK(req("PUT", "/.henge/focus?active=0", "{\"seq\":1,\"event\":\"focus\",\"kind\":\"text\"}", out, sizeof out) == 204);
    CHECK(calls == 0);
    CHECK(hv_share_focus_agent_seen() == -1);
    CHECK(hv_share_focus_send_text("x") == -1);
    CHECK(req("PUT", "/.henge/focus", "{\"seq\":1,\"event\":\"focus\",\"kind\":\"text\"}", out, sizeof out) == 204);
    CHECK(calls == 1 && strstr(got, "\"text\""));
    CHECK(hv_share_focus_agent_seen() >= 0);
    CHECK(req("PUT", "/.henge/focus", "{}", out, sizeof out) == 204); /* heartbeat: no report */
    CHECK(calls == 1);
    CHECK(hv_share_focus_send_text("caf\xc3\xa9") == 0);
    CHECK(hv_share_focus_text_busy() == 1);
    CHECK(req("PUT", "/.henge/focus", "{\"kind\":\"none\"}", out, sizeof out) == 200);
    CHECK(strstr(out, "\r\n\r\ncaf\xc3\xa9") != NULL);
    CHECK(hv_share_focus_text_busy() == 1); /* just taken */
    usleep(300000);
    CHECK(hv_share_focus_text_busy() == 0);
    /* the long poll gets text queued while it waits */
    pthread_t t;
    pthread_create(&t, NULL, later, NULL);
    CHECK(req("PUT", "/.henge/focus?wait=5", "{}", out, sizeof out) == 200);
    CHECK(strstr(out, "\r\n\r\n\xe4\xbd\xa0\xe5\xa5\xbd b\b") != NULL);
    pthread_join(t, NULL);
    /* text is never handed to another session's agent, even one waiting for it: it stays for the agent on
       the screen */
    CHECK(hv_share_focus_send_text("secret") == 0);
    CHECK(req("PUT", "/.henge/focus?wait=1&active=0", "{\"kind\":\"text\"}", out, sizeof out) == 204);
    CHECK(strstr(out, "secret") == NULL);
    CHECK(calls == 2);
    CHECK(hv_share_focus_text_busy() == 1);
    CHECK(req("PUT", "/.henge/focus", "{}", out, sizeof out) == 200);
    CHECK(strstr(out, "\r\n\r\nsecret") != NULL);
    /* and times out with 204 */
    CHECK(req("PUT", "/.henge/focus?wait=1", "{}", out, sizeof out) == 204);
    CHECK(req("GET", "/.henge/focus", "", out, sizeof out) == 404);

    unlink(sock_path);
    rmdir(dir);
    if (failures) {
        fprintf(stderr, "test_share_focus: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_share_focus: ok\n");
    return 0;
}
