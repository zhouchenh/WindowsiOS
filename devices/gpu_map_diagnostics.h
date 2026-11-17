/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_GPU_MAP_DIAGNOSTICS_H
#define HV_GPU_MAP_DIAGNOSTICS_H
#include <stddef.h>
#include <stdint.h>
enum HvGpuMapImage { HV_GPU_MAP_DXMT, HV_GPU_MAP_VIRGL };
/* 1 installed; 0 safely unavailable; -1 unsafe rollback/protection, refuse all
   future backend creation. Call before any renderer/device use. No code writes. */
int hv_gpu_map_diagnostics_install(void *symbol, enum HvGpuMapImage image);
/* Final pre-renderer seal: 1 prevents future writes, -1 refuses fatal state. */
int hv_gpu_map_diagnostics_mark_used(void);
int hv_gpu_map_diagnostics_used(void);
int hv_gpu_map_diagnostics_fatal(void);
/* Called under the common data lock when another import installer cannot
   restore page protection. The same final seal then refuses backend entry. */
void hv_gpu_map_diagnostics_poison_imports(void);
const char *hv_gpu_map_diagnostics_status(enum HvGpuMapImage image);
/* Plain-file shm_open replacement calls this only after a failed open. It does
   not log the name/path. Caller errno is preserved even when diagnostics fail. */
void hv_gpu_map_diagnostics_open_failed(uintptr_t caller, int flags, int error);
/* Counters count attempts, not completed writes. Busy/capped reports are skipped; suppressed is a best-effort lower bound.
   Metadata is a best-effort snapshot: another thread may close/reuse the fd. */
void hv_gpu_map_diagnostics_counts(uint64_t *attempts, uint64_t *suppressed);
#endif
