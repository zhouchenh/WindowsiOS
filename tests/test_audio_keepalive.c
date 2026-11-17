/* SPDX-License-Identifier: GPL-2.0-or-later */
/* The audio keep-alive of the app's server mode (host/audio_mac.c, hv_audio_set_keepalive) over this Mac's real
   output unit (DefaultOutput; RemoteIO on iOS), with a stand-in HDA whose playback the unit pulls. The unit plays
   silence: nothing is heard.
   - Keep-alive with no Windows stream: a unit is made (2 ch / 48 kHz) and pulls (silence).
   - Windows' stream stopping leaves a kept-alive unit running; with the keep-alive off it stops, unless Windows
     still plays; Windows opening another format makes the unit again, still running after Windows stops.
   - Restart after an interruption, and a media services reset (the unit made again), keep it running.
   - Shutdown turns the keep-alive off and frees the unit; without an attached HDA the keep-alive fails.
   No output device (a headless Mac): skipped. */
#include "audio_mac.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures;
static void check(const char *what, int ok) {
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        failures++;
    }
}

/* ---- stand-ins for the HDA's rings and virtio-snd ---- */
static atomic_int pulls;
uint32_t hv_hda_pull_playback(HvHda *d, void *dst, uint32_t bytes) {
    (void)d;
    memset(dst, 0, bytes);
    atomic_fetch_add(&pulls, 1);
    return 0;
}
void hv_hda_push_capture(HvHda *d, const void *src, uint32_t bytes) { (void)d, (void)src, (void)bytes; }
uint32_t hv_virtio_snd_pull(HvVirtioSnd *d, void *dst, uint32_t bytes) {
    (void)d;
    memset(dst, 0, bytes);
    return 0;
}

static int pulled_within(int ms) {
    int before = atomic_load(&pulls);
    for (int t = 0; t < ms; t += 20) {
        usleep(20000);
        if (atomic_load(&pulls) > before) return 1;
    }
    return 0;
}

int main(void) {
    static HvHda hda; /* only its backend is used here */
    check("no HDA attached: no keep-alive", hv_audio_set_keepalive(1) == -1 && !hv_audio_output_running());
    hv_audio_set_keepalive(0);
    hv_audio_attach_hda(&hda);
    check("attached: nothing runs yet", !hv_audio_output_running());

    if (hv_audio_set_keepalive(1) != 0) {
        printf("audio keep-alive: skipped (no output unit on this Mac)\n");
        hv_audio_shutdown();
        return 0;
    }
    check("keep-alive: the unit runs", hv_audio_output_running() && hv_audio_keepalive());
    check("keep-alive: it pulls (silence)", pulled_within(1500));

    HvHdaBackend *be = &hda.backend;
    check("Windows plays", be->start_out(be->opaque, 2, 48000) == 0 && hv_audio_output_running());
    be->stop_out(be->opaque);
    check("Windows stops: kept alive, still running", hv_audio_output_running() && pulled_within(1500));

    hv_audio_set_keepalive(0);
    check("keep-alive off, Windows silent: stopped", !hv_audio_output_running());

    be->start_out(be->opaque, 2, 48000);
    hv_audio_set_keepalive(1);
    hv_audio_set_keepalive(0);
    check("keep-alive off while Windows plays: still running", hv_audio_output_running());
    be->stop_out(be->opaque);
    check("then Windows stops: stopped", !hv_audio_output_running());

    hv_audio_set_keepalive(1);
    check("Windows opens 44.1 kHz while kept alive: made again, running", be->start_out(be->opaque, 2, 44100) == 0 &&
                                                                          hv_audio_output_running());
    be->stop_out(be->opaque);
    check("... and still running after Windows stops", hv_audio_output_running() && pulled_within(1500));

    check("restart after an interruption", hv_audio_restart_output(0) == 0 && hv_audio_output_running());
    check("media services reset: made again and running", hv_audio_restart_output(1) == 0 && hv_audio_output_running() &&
                                                          pulled_within(1500));

    hv_audio_pause_capture(1); /* nothing open: only the flag (the microphone is not touched here) */
    hv_audio_pause_capture(0);

    hv_audio_shutdown();
    check("shutdown: keep-alive off, nothing runs", !hv_audio_keepalive() && !hv_audio_output_running());
    check("after shutdown a restart starts nothing", hv_audio_restart_output(0) == 0 && !hv_audio_output_running());

    printf("audio keep-alive: %s (%d failures)\n", failures ? "FAILED" : "ok", failures);
    return failures != 0;
}
