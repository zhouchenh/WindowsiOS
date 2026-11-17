/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HENGEVM_AUDIO_MAC_H
#define HENGEVM_AUDIO_MAC_H

#include "hda.h"
#include "virtio_snd.h"

/* Attach CoreAudio playback (RemoteIO / DefaultOutput) + microphone capture (AudioQueueInput)
 * to the guest's Intel HD Audio duplex controller (macOS and iOS). */
void hv_audio_attach_hda(HvHda *hda);
/* Stops and frees the units; also turns the keep-alive off (set it again after the next attach). */
void hv_audio_shutdown(void);

/* Keep-alive (iOS background running, the app's server mode): with it on, the output unit keeps running while
 * Windows plays nothing and hears silence, and it is made at 2 ch / 48 kHz when Windows has no stream open.
 * Needs an attached HDA (-1 without). Any thread. */
int hv_audio_set_keepalive(int on);
int hv_audio_keepalive(void);
/* Starts the output again when it should run (keep-alive, or Windows playing): after an interruption ended or the
 * app came back to the front (recreate 0), or after a media services reset (recreate 1: made again). */
int hv_audio_restart_output(int recreate);
/* The machine is paused (the app in the background without server mode, or the guard): the output unit stops even
 * while Windows has a stream open (its CPUs are parked before it could stop it), so iOS can suspend the app.
 * Unpaused, it starts again if Windows plays or the keep-alive is on. */
void hv_audio_set_machine_paused(int paused);
int hv_audio_output_running(void);
/* While paused, the microphone is not opened (iOS shows its indicator while it is): Windows' capture stream hears
 * nothing. Unpaused, a stream Windows has open starts again. */
void hv_audio_pause_capture(int paused);

/* Legacy virtio-snd attachment retained for compatibility. */
void hv_audio_attach(HvVirtioSnd *d);

#endif
