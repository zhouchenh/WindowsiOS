/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Full-duplex host audio backend for macOS and iOS:
 *   - Playback (Speaker Out): low-latency RemoteIO (iOS) / DefaultOutput (macOS) AudioUnit
 *     pulling S16LE frames straight from HvHda's lock-free TX ring.
 *   - Capture (Microphone In): CoreAudio AudioQueueInput with automatic hardware sample-rate
 *     and mono-to-stereo conversion into HvHda's lock-free RX ring.
 *   - Keep-alive (the app's server mode, hv_audio_set_keepalive): the output unit keeps running while Windows
 *     plays nothing (hv_hda_pull_playback fills silence), since iOS keeps an app with background audio running
 *     only while its audio plays. Made at 2 ch / 48 kHz when Windows has no stream open. */
#include "audio_mac.h"

#include <AudioToolbox/AudioToolbox.h>
#include <TargetConditionals.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#if TARGET_OS_IPHONE
#define HV_OUTPUT_UNIT kAudioUnitSubType_RemoteIO
#else
#define HV_OUTPUT_UNIT kAudioUnitSubType_DefaultOutput
#endif

#define IN_NUM_BUFFERS 4
#define IN_BUFFER_FRAMES 960 /* 20 ms @ 48 kHz */

static pthread_mutex_t audio_mu = PTHREAD_MUTEX_INITIALIZER;

/* ---- HDA Playback (Output AudioUnit) ---- */
static AudioComponentInstance hda_out_unit;
static int hda_out_running;
static unsigned hda_out_ch, hda_out_rate;
static HvHda *attached_hda;  /* the render callback's source (hv_audio_attach_hda) */
static int keepalive;        /* hv_audio_set_keepalive */
static int guest_out;        /* Windows has its output stream running (between start_out and stop_out) */
static unsigned guest_out_ch = 2, guest_out_rate = 48000; /* its format */
static int machine_paused;   /* hv_audio_set_machine_paused: the output stays off whatever else wants it */
static int guest_in, capture_paused; /* the same for the microphone, and hv_audio_pause_capture */

static OSStatus hda_out_render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                               UInt32 bus, UInt32 frames, AudioBufferList *io) {
    (void)flags, (void)ts, (void)bus, (void)frames;
    HvHda *hda = (HvHda *)ref;
    for (UInt32 i = 0; i < io->mNumberBuffers; i++)
        hv_hda_pull_playback(hda, io->mBuffers[i].mData, io->mBuffers[i].mDataByteSize);
    return noErr;
}

static void dispose_out_locked(void) {
    if (!hda_out_unit) return;
    if (hda_out_running) AudioOutputUnitStop(hda_out_unit);
    AudioUnitUninitialize(hda_out_unit);
    AudioComponentInstanceDispose(hda_out_unit);
    hda_out_unit = NULL;
    hda_out_running = 0;
}

/* audio_mu held: the unit for this format exists and runs. 0, or -1. */
static int ensure_out_locked(HvHda *hda, unsigned channels, unsigned rate_hz) {
    if (hda_out_unit && (channels != hda_out_ch || rate_hz != hda_out_rate)) dispose_out_locked();
    if (!hda_out_unit) {
        AudioComponentDescription desc = {
            .componentType = kAudioUnitType_Output,
            .componentSubType = HV_OUTPUT_UNIT,
            .componentManufacturer = kAudioUnitManufacturer_Apple,
        };
        AudioComponent comp = AudioComponentFindNext(NULL, &desc);
        if (!comp || AudioComponentInstanceNew(comp, &hda_out_unit) != noErr) {
            hda_out_unit = NULL;
            return -1;
        }
        AudioStreamBasicDescription f = {0};
        f.mSampleRate = (Float64)rate_hz;
        f.mFormatID = kAudioFormatLinearPCM;
        f.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        f.mBytesPerPacket = f.mBytesPerFrame = 2u * channels;
        f.mFramesPerPacket = 1;
        f.mChannelsPerFrame = channels;
        f.mBitsPerChannel = 16;

        AURenderCallbackStruct cb = {hda_out_render, hda};
        if (AudioUnitSetProperty(hda_out_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f) != noErr ||
            AudioUnitSetProperty(hda_out_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb) != noErr ||
            AudioUnitInitialize(hda_out_unit) != noErr) {
            fprintf(stderr, "winvm: audio: output unit refused %u ch @ %u Hz\n", channels, rate_hz);
            AudioComponentInstanceDispose(hda_out_unit);
            hda_out_unit = NULL;
            return -1;
        }
        hda_out_ch = channels;
        hda_out_rate = rate_hz;
    }
    if (!hda_out_running && AudioOutputUnitStart(hda_out_unit) == noErr)
        hda_out_running = 1;
    return hda_out_running ? 0 : -1;
}

static void stop_out_locked(void) {
    if (hda_out_unit && hda_out_running) {
        AudioOutputUnitStop(hda_out_unit);
        hda_out_running = 0;
    }
}

/* audio_mu held: the output runs while Windows plays or the keep-alive wants it, never while the machine is paused. */
static int out_wanted_locked(void) { return !machine_paused && (keepalive || guest_out); }

/* audio_mu held: starts the output in the format Windows opened, else the one the unit has, else 2 ch / 48 kHz. */
static int start_wanted_locked(void) {
    if (!attached_hda) return -1;
    if (guest_out) return ensure_out_locked(attached_hda, guest_out_ch, guest_out_rate);
    if (hda_out_unit) return ensure_out_locked(attached_hda, hda_out_ch, hda_out_rate);
    return ensure_out_locked(attached_hda, 2, 48000);
}

static int hda_start_out(void *opaque, unsigned channels, unsigned rate_hz) {
    HvHda *hda = (HvHda *)opaque;
    if (channels < 1 || channels > 2) channels = 2;
    if (rate_hz < 8000 || rate_hz > 192000) rate_hz = 48000;
    pthread_mutex_lock(&audio_mu);
    guest_out = 1;
    guest_out_ch = channels, guest_out_rate = rate_hz;
    /* a kept-alive unit of another format is made again; a paused machine starts it when it resumes */
    int ok = machine_paused ? 0 : ensure_out_locked(hda, channels, rate_hz);
    pthread_mutex_unlock(&audio_mu);
    return ok;
}

static void hda_stop_out(void *opaque) {
    (void)opaque;
    pthread_mutex_lock(&audio_mu);
    guest_out = 0;
    if (!out_wanted_locked()) stop_out_locked(); /* kept alive: it plays silence on */
    pthread_mutex_unlock(&audio_mu);
}

/* ---- HDA Capture (Microphone AudioQueueInput) ---- */
static AudioQueueRef hda_in_queue;
static AudioQueueBufferRef hda_in_bufs[IN_NUM_BUFFERS];
static int hda_in_running;
static unsigned hda_in_ch, hda_in_rate;
static unsigned hda_in_ch_want, hda_in_rate_want; /* what Windows opened (for a capture started again) */

static void hda_in_callback(void *opaque, AudioQueueRef aq, AudioQueueBufferRef buf,
                            const AudioTimeStamp *start_time, UInt32 num_packets,
                            const AudioStreamPacketDescription *pkt_desc) {
    (void)start_time, (void)num_packets, (void)pkt_desc;
    HvHda *hda = (HvHda *)opaque;
    if (hda && buf && buf->mAudioDataByteSize > 0)
        hv_hda_push_capture(hda, buf->mAudioData, buf->mAudioDataByteSize);

    pthread_mutex_lock(&audio_mu);
    if (hda_in_running && aq == hda_in_queue)
        AudioQueueEnqueueBuffer(aq, buf, 0, NULL);
    pthread_mutex_unlock(&audio_mu);
}

static void dispose_in_locked(void) {
    if (hda_in_queue) {
        hda_in_running = 0;
        AudioQueueStop(hda_in_queue, true);
        AudioQueueDispose(hda_in_queue, true);
        hda_in_queue = NULL;
        memset(hda_in_bufs, 0, sizeof hda_in_bufs);
    }
}

static int hda_start_in(void *opaque, unsigned channels, unsigned rate_hz) {
    HvHda *hda = (HvHda *)opaque;
    if (channels < 1 || channels > 2) channels = 2;
    if (rate_hz < 8000 || rate_hz > 192000) rate_hz = 48000;

    pthread_mutex_lock(&audio_mu);
    guest_in = 1;
    hda_in_ch_want = channels, hda_in_rate_want = rate_hz;
    if (capture_paused) { /* the app is in the background: no microphone (and no indicator) until it is back */
        pthread_mutex_unlock(&audio_mu);
        return 0;
    }
    if (hda_in_queue && (channels != hda_in_ch || rate_hz != hda_in_rate))
        dispose_in_locked();

    if (!hda_in_queue) {
        AudioStreamBasicDescription f = {0};
        f.mSampleRate = (Float64)rate_hz;
        f.mFormatID = kAudioFormatLinearPCM;
        f.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        f.mBytesPerPacket = f.mBytesPerFrame = 2u * channels;
        f.mFramesPerPacket = 1;
        f.mChannelsPerFrame = channels;
        f.mBitsPerChannel = 16;

        OSStatus st = AudioQueueNewInput(&f, hda_in_callback, hda, NULL, NULL, 0, &hda_in_queue);
        if (st != noErr || !hda_in_queue) {
            fprintf(stderr, "winvm: audio: microphone input unavailable (OSStatus=%d)\n", (int)st);
            hda_in_queue = NULL;
            pthread_mutex_unlock(&audio_mu);
            return -1;
        }
        UInt32 buf_bytes = IN_BUFFER_FRAMES * f.mBytesPerFrame;
        for (int i = 0; i < IN_NUM_BUFFERS; i++) {
            if (AudioQueueAllocateBuffer(hda_in_queue, buf_bytes, &hda_in_bufs[i]) == noErr)
                AudioQueueEnqueueBuffer(hda_in_queue, hda_in_bufs[i], 0, NULL);
        }
        hda_in_ch = channels;
        hda_in_rate = rate_hz;
    }

    if (!hda_in_running) {
        OSStatus st = AudioQueueStart(hda_in_queue, NULL);
        if (st == noErr) {
            hda_in_running = 1;
        } else {
            fprintf(stderr, "winvm: audio: AudioQueueStart(input) returned %d (mic permission pending?)\n", (int)st);
            dispose_in_locked();
        }
    }
    int ok = hda_in_running ? 0 : -1;
    pthread_mutex_unlock(&audio_mu);
    return ok;
}

static void stop_in_locked(void) {
    if (hda_in_queue && hda_in_running) {
        hda_in_running = 0;
        AudioQueueStop(hda_in_queue, true);
        for (int i = 0; i < IN_NUM_BUFFERS; i++) {
            if (hda_in_bufs[i]) AudioQueueEnqueueBuffer(hda_in_queue, hda_in_bufs[i], 0, NULL);
        }
    }
}

static void hda_stop_in(void *opaque) {
    (void)opaque;
    pthread_mutex_lock(&audio_mu);
    guest_in = 0;
    if (hda_in_queue && hda_in_running) {
        hda_in_running = 0;
        AudioQueueStop(hda_in_queue, true);
        /* Re-prime buffers so next start is instant */
        for (int i = 0; i < IN_NUM_BUFFERS; i++) {
            if (hda_in_bufs[i]) AudioQueueEnqueueBuffer(hda_in_queue, hda_in_bufs[i], 0, NULL);
        }
    }
    pthread_mutex_unlock(&audio_mu);
}

void hv_audio_attach_hda(HvHda *hda) {
    if (!hda) return;
    pthread_mutex_lock(&audio_mu);
    attached_hda = hda;
    pthread_mutex_unlock(&audio_mu);
    hda->backend = (HvHdaBackend){
        .start_out = hda_start_out,
        .stop_out = hda_stop_out,
        .start_in = hda_start_in,
        .stop_in = hda_stop_in,
        .opaque = hda,
    };
}

void hv_audio_shutdown(void) {
    pthread_mutex_lock(&audio_mu);
    keepalive = 0; /* no silent unit keeps the app alive with no machine running */
    guest_out = guest_in = 0;
    machine_paused = 0;
    capture_paused = 0;
    dispose_out_locked();
    dispose_in_locked();
    pthread_mutex_unlock(&audio_mu);
}

int hv_audio_set_keepalive(int on) {
    pthread_mutex_lock(&audio_mu);
    keepalive = on != 0;
    int rc = 0;
    if (keepalive && !attached_hda) rc = -1;
    else if (out_wanted_locked()) rc = start_wanted_locked();
    else stop_out_locked();
    int running = hda_out_running, paused = machine_paused;
    pthread_mutex_unlock(&audio_mu);
    fprintf(stderr, "winvm: audio: keep-alive %s (output %s%s)\n", on ? "on" : "off", running ? "running" : "stopped",
            paused ? ", machine paused" : "");
    return rc;
}

void hv_audio_set_machine_paused(int paused) {
    pthread_mutex_lock(&audio_mu);
    int was = machine_paused, rc = 0;
    machine_paused = paused != 0;
    if (machine_paused) stop_out_locked();
    else if (out_wanted_locked()) rc = start_wanted_locked();
    int running = hda_out_running, now = machine_paused;
    pthread_mutex_unlock(&audio_mu);
    if (was != now)
        fprintf(stderr, "winvm: audio: machine %s: output %s%s\n", now ? "paused" : "resumed",
                running ? "running" : "stopped", rc ? " (could not start it)" : "");
}

int hv_audio_keepalive(void) {
    pthread_mutex_lock(&audio_mu);
    int k = keepalive;
    pthread_mutex_unlock(&audio_mu);
    return k;
}

int hv_audio_restart_output(int recreate) {
    pthread_mutex_lock(&audio_mu);
    int rc = 0;
    if (recreate) {
        /* after a media services reset every unit is invalid: made again from scratch */
        unsigned ch = hda_out_unit ? hda_out_ch : 2, rate = hda_out_unit ? hda_out_rate : 48000;
        dispose_out_locked();
        if (guest_out) ch = guest_out_ch, rate = guest_out_rate;
        if (out_wanted_locked() && attached_hda) rc = ensure_out_locked(attached_hda, ch, rate);
    } else if (hda_out_unit && out_wanted_locked()) {
        /* an interruption stopped it behind our back: start it again (starting a running unit does nothing) */
        rc = AudioOutputUnitStart(hda_out_unit) == noErr ? 0 : -1;
        hda_out_running = rc == 0;
    } else if (out_wanted_locked() && attached_hda) {
        rc = start_wanted_locked();
    }
    int running = hda_out_running;
    pthread_mutex_unlock(&audio_mu);
    if (keepalive || recreate)
        fprintf(stderr, "winvm: audio: output %s (%s)\n", running ? "running again" : "not running",
                recreate ? "media services reset" : "restart");
    return rc;
}

int hv_audio_output_running(void) {
    pthread_mutex_lock(&audio_mu);
    int r = hda_out_unit && hda_out_running;
    pthread_mutex_unlock(&audio_mu);
    return r;
}

void hv_audio_pause_capture(int paused) {
    pthread_mutex_lock(&audio_mu);
    capture_paused = paused != 0;
    int restart = !capture_paused && guest_in && attached_hda;
    if (capture_paused) stop_in_locked();
    pthread_mutex_unlock(&audio_mu);
    if (restart) hda_start_in(attached_hda, hda_in_ch_want, hda_in_rate_want);
}

/* ---- Legacy virtio-snd compatibility ---- */
static AudioComponentInstance vsnd_unit;
static int vsnd_running;
static unsigned vsnd_ch, vsnd_fmt, vsnd_rate;

static OSStatus vsnd_render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                            UInt32 frames, AudioBufferList *io) {
    (void)flags, (void)ts, (void)bus, (void)frames;
    HvVirtioSnd *d = ref;
    for (UInt32 i = 0; i < io->mNumberBuffers; i++)
        hv_virtio_snd_pull(d, io->mBuffers[i].mData, io->mBuffers[i].mDataByteSize);
    return noErr;
}

static int vsnd_start(void *opaque, unsigned channels, unsigned format, unsigned rate_hz) {
    HvVirtioSnd *d = opaque;
    if (vsnd_unit && (channels != vsnd_ch || format != vsnd_fmt || rate_hz != vsnd_rate)) {
        AudioOutputUnitStop(vsnd_unit);
        AudioUnitUninitialize(vsnd_unit);
        AudioComponentInstanceDispose(vsnd_unit);
        vsnd_unit = NULL;
        vsnd_running = 0;
    }
    if (!vsnd_unit) {
        AudioComponentDescription desc = {kAudioUnitType_Output, HV_OUTPUT_UNIT,
                                          kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent comp = AudioComponentFindNext(NULL, &desc);
        if (!comp || AudioComponentInstanceNew(comp, &vsnd_unit) != noErr) return -1;
        unsigned bytes = format == HV_VSND_FMT_S16 ? 2 : 4;
        AudioStreamBasicDescription f = {0};
        f.mSampleRate = rate_hz;
        f.mFormatID = kAudioFormatLinearPCM;
        f.mFormatFlags = (format == HV_VSND_FMT_FLOAT ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) |
                         kAudioFormatFlagIsPacked;
        f.mBytesPerPacket = f.mBytesPerFrame = bytes * channels;
        f.mFramesPerPacket = 1;
        f.mChannelsPerFrame = channels;
        f.mBitsPerChannel = bytes * 8;
        AURenderCallbackStruct cb = {vsnd_render, d};
        if (AudioUnitSetProperty(vsnd_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f) != noErr ||
            AudioUnitSetProperty(vsnd_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb) != noErr ||
            AudioUnitInitialize(vsnd_unit) != noErr) {
            AudioComponentInstanceDispose(vsnd_unit);
            vsnd_unit = NULL;
            return -1;
        }
        vsnd_ch = channels, vsnd_fmt = format, vsnd_rate = rate_hz;
    }
    if (!vsnd_running && AudioOutputUnitStart(vsnd_unit) == noErr) vsnd_running = 1;
    return vsnd_running ? 0 : -1;
}

static void vsnd_stop(void *opaque) {
    (void)opaque;
    if (vsnd_unit && vsnd_running) AudioOutputUnitStop(vsnd_unit);
    vsnd_running = 0;
}

void hv_audio_attach(HvVirtioSnd *d) {
    d->backend = (HvVirtioSndBackend){vsnd_start, vsnd_stop, d};
}
