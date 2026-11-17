/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_NEPTUNE_DEVICE_H
#define HV_NEPTUNE_DEVICE_H

/* Call once immediately after loading DXMT, before any device creation. This
 * installs verified cleanup operations and transactionally replaces the
 * concrete container's QI/AddRef/Release data slots. No code is modified.
 * Returns 1 installed, 0 safely disabled, -1 incomplete rollback: the caller
 * must refuse backend device creation after -1. */
int hv_npt_install_device_hooks(void *d3d11_create_device_symbol);
/* Undo a successful installation only before any backend device exists.
 * Returns 1 with original slots/protection restored, -1 if uncertain. */
int hv_npt_rollback_device_hooks(void);
const char *hv_npt_device_hook_status(void);

#endif
