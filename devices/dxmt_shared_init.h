/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_DXMT_SHARED_INIT_H
#define HV_DXMT_SHARED_INIT_H
#include <stddef.h>
/* Install before creating any DXMT devices. Disabled unless environment
 * HV_DXMT_SHARED_INIT=1. Returns 1 installed, 0 disabled/rejected, -1 sticky
 * rollback failure: caller MUST refuse backend device creation in this process.
 * No dependency on Neptune lifetime hooks. No executable memory is modified. */
int hv_dxmt_install_shared_init(void *d3d11_create_device_symbol);
const char *hv_dxmt_shared_init_status(void);
/* Active native-flush count and elapsed continuous busy interval, not oldest job
 * age. Safe while backend calls stall; its brief statistics mutex never spans a
 * backend call. Suitable for the host 3D status/memory census. */
void hv_dxmt_shared_init_describe(char *buffer,size_t length);
/* Initially allowed, presenter unpaused, not draining (foreground defaults).
 * App permission, presenter pause and drain are independent disallow sources.
 * False or a transition during a wait preserves the original successful resource
 * return, abandoning this diagnostic mitigation rather than starting more work. */
void hv_dxmt_shared_init_set_gpu_allowed(int allowed);
void hv_dxmt_shared_init_set_draining(int draining);
void hv_dxmt_shared_init_set_presenter_paused(int paused);
/* Renderer reset/VM exit clears only mitigation-disable state, not lifecycle
 * gates or cumulative counters. Old in-flight calls cannot relatch a new epoch.
 * Timeout/error always preserves the original successful resource/reference. */
void hv_dxmt_shared_init_reset(void);
#endif
