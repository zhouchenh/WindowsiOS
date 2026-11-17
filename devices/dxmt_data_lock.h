/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_DXMT_DATA_LOCK_H
#define HV_DXMT_DATA_LOCK_H
/* Serialize every DXMT __DATA_CONST protection/write/restore transaction.
   Device lifetime and shared initialization hooks occupy the same VM page. */
void hv_dxmt_data_lock(void);
void hv_dxmt_data_unlock(void);
#endif
