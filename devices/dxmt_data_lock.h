/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_DXMT_DATA_LOCK_H
#define HV_DXMT_DATA_LOCK_H
/* Serialize framework data-page protection/write/restore transactions.
   Device/shared-init vtables share DXMT pages; virgl free/mmap imports share
   another page. Acquire this before any installer-specific mutex. */
void hv_dxmt_data_lock(void);
void hv_dxmt_data_unlock(void);
#endif
