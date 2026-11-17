// SPDX-License-Identifier: GPL-2.0-or-later
/* A stand-in for devices/fw_cfg.c's hv_fw_cfg_add_file that keeps a copy of every file, so tests can
   build the ACPI tables (devices/acpi.c) without a machine and look at what the firmware would get. */
#include "fw_cfg.h"

#include <stdlib.h>
#include <string.h>

#include "fw_cfg_capture_stub.h"

static struct {
    char name[56];
    uint8_t *data;
    uint32_t len;
} files[HV_FW_CFG_MAX_FILES];
static int nfiles;

int hv_fw_cfg_add_file(HvFwCfg *fc, const char *name, const void *data, uint32_t len) {
    (void)fc;
    if (nfiles >= HV_FW_CFG_MAX_FILES) return -1;
    strncpy(files[nfiles].name, name, sizeof files[nfiles].name - 1);
    files[nfiles].data = malloc(len ? len : 1);
    if (!files[nfiles].data) return -1;
    if (len) memcpy(files[nfiles].data, data, len);
    files[nfiles].len = len;
    nfiles++;
    return 0;
}

const uint8_t *fw_capture_get(const char *name, uint32_t *len) {
    for (int i = nfiles - 1; i >= 0; i--) {
        if (!strcmp(files[i].name, name)) {
            if (len) *len = files[i].len;
            return files[i].data;
        }
    }
    return NULL;
}

void fw_capture_reset(void) {
    for (int i = 0; i < nfiles; i++) free(files[i].data);
    memset(files, 0, sizeof files);
    nfiles = 0;
}
