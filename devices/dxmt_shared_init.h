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
/* Initially allowed and not draining, matching the foreground host defaults.
 * GPU permission and drain are independent; either can disallow extra work.
 * False or a transition during a wait preserves the original successful resource
 * return, abandoning this diagnostic mitigation rather than starting more work. */
void hv_dxmt_shared_init_set_gpu_allowed(int allowed);
void hv_dxmt_shared_init_set_draining(int draining);
#endif
