// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef FW_CFG_CAPTURE_STUB_H
#define FW_CFG_CAPTURE_STUB_H

#include <stdint.h>

/* The last file added under this name (NULL when none); owned by the stub until fw_capture_reset. */
const uint8_t *fw_capture_get(const char *name, uint32_t *len);
void fw_capture_reset(void);

#endif
