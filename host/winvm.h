/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_WINVM_H
#define HV_WINVM_H

#include <stddef.h>
#include <stdint.h>

#include "winvirt.h"

typedef struct HvWinVmConfig {
    const char *code_fd;      /* 64 MB EDK2 UEFI firmware (read-only) */
    const char *vars_fd;      /* 64 MB UEFI NVRAM (read/write persistent) */
    const char *disk0;        /* Primary NVMe disk image (raw or .hvsparse) */
    const char *disk1;        /* Optional secondary/installer NVMe disk image (read-only) */
    const char *share_dir;    /* Optional host folder shared over WebDAV at http://10.0.2.4/ */
    const char *share_sock;   /* Path for internal WebDAV Unix domain socket */
    int ncpus;
    uint64_t ram_mb;
    size_t jit_bytes;
    void *jit_rx;             /* Optional split RX/RW JIT pointers for iOS TXM */
    void *jit_rw;
    void *prealloc_ram;       /* Optional pre-allocated Guest RAM (ledger-exempt on iOS) */
    int no_net;
    int enable_sound;
    int battery;              /* ACPI battery + AC adapter fed by hv_winvm_set_battery (DSDT fixed per run) */
    int log;
    int stats_interval;
} HvWinVmConfig;

int hv_winvm_create(const HvWinVmConfig *cfg, char *err, size_t errlen);
void hv_winvm_start(int spawn_cpu0, void (*on_exit)(int reason));
int hv_winvm_run_cpu0(void);
void hv_winvm_stop(void);
void hv_winvm_power_button(void);
/* The host's battery: level 0..1 (negative = unknown), state 0 unknown, 1 unplugged, 2 charging, 3 full
   (UIDeviceBatteryState). The guest is notified when it changed. No-op unless cfg.battery was set. Any thread. */
void hv_winvm_set_battery(double level, int state);
void hv_winvm_flush_disks(void);
/* Stops every guest CPU where it is (1) or lets them go on (0). Devices keep running: what the
   guest already queued is finished. */
void hv_winvm_set_paused(int paused);
/* Feeds bytes to the guest serial console (blocks while its FIFO is full). */
void hv_winvm_serial_send(const char *bytes, size_t n);

/* Display & screenshot hooks (any thread) */
void hv_winvm_set_display_layer(void *ca_metal_layer);
int hv_winvm_display_size(uint32_t *w, uint32_t *h);
uint64_t hv_winvm_display_frames(void);
int hv_winvm_save_png(const char *path);
int hv_winvm_save_png_raw(const char *path);
/* Preferred display mode for virtio-gpu (e.g. the iPad screen in points); the guest driver
   is told through a display-change event. No-op without virtio-gpu. */
void hv_winvm_set_preferred_display(uint32_t w, uint32_t h);
/* virtio-gpu status line for diagnostics; returns -1 without virtio-gpu. */
int hv_winvm_gpu_status(char *buf, unsigned len);
/* Graphics hot switch (virtio_gpu.h): offer 3D or 2D from the guest's next display driver start. 0, or -1 when
   3D is asked for without the renderer loaded (the machine started without host 3D). */
int hv_winvm_gpu_set_3d(int on);
/* Deferred 3D cleanup may read GPU completion while active/inactive, never while in
   the background. Safe before VM start; does not wait for a cleanup worker. */
void hv_winvm_set_gpu_allowed(int allowed);
/* The mode: capable, offered3d, negotiated3d, driver_ok, resets (all 0 without virtio-gpu). */
void hv_winvm_gpu_mode(int *capable, int *offered3d, int *negotiated3d, int *driver_ok, uint32_t *resets);
/* The app is in the background (1) or back in front (0): the 3D renderer's background drain (virtio_gpu3d.h). */
void hv_winvm_gpu_set_background(int on);
/* The screen as shown now, the cursor blended in: BGRA, opaque, rows of w*4 bytes, malloc'd (free it). allow_gpu 0
   never touches the GPU (NULL while the screen is a 3D texture); 1 reads a 3D texture with one blit (only while the
   app may use the GPU: in front or inactive, never in the background). NULL when there is no picture. */
uint8_t *hv_winvm_display_snapshot(int allow_gpu, uint32_t *w, uint32_t *h);
/* Changes whenever the picture does (sampled, cheap); 0 when there is none. *is_texture: a 3D texture is shown. */
uint64_t hv_winvm_display_serial(int *is_texture);
/* The presenter stops drawing (its display link pauses) while the app is in the background, and starts again. */
void hv_winvm_display_set_paused(int paused);

/* Input hooks (any thread) */
void hv_winvm_key_hid(uint8_t usage, int down);
void hv_winvm_key_linux(uint16_t code, int down);
/* Normalized tablet pointer: x_norm, y_norm in [0.0, 1.0] mapped to 0..32767;
 * buttons: bit0=Left, bit1=Right, bit2=Middle; wheel: -127..127. */
void hv_winvm_tablet(double x_norm, double y_norm, uint8_t buttons, int8_t wheel);
/* One touch screen frame (the xHCI's port 3): every contact on the screen; one lifting is in it once
 * more with tip 0 (and confidence 0 to cancel it rather than end it as a tap). x_norm, y_norm in
 * [0.0, 1.0] across the Windows screen, clamped. */
typedef struct HvWinvmTouch {
    uint8_t id, tip, confidence;
    double x_norm, y_norm;
} HvWinvmTouch;
void hv_winvm_touch(const HvWinvmTouch *contacts, int n);
/* 1 while the guest reads the touch screen (Windows has its HID touch driver running on it). */
int hv_winvm_touch_ready(void);
void hv_winvm_send_ctrl_alt_del(void);
void hv_winvm_usb_stats(int *kbd_ready, int *tab_ready, uint64_t *delivered);
void hv_winvm_engine_stats(uint64_t *jit_used_bytes, uint64_t *jit_cap_bytes,
                           uint64_t *jit_full_flushes, uint64_t *wfi_ticks);
int hv_winvm_share_up(void);

HvMachine *hv_winvm_machine(void);
HvWinVirt *hv_winvm_board(void);
const char *hv_winvm_reason_name(int reason);

#endif
