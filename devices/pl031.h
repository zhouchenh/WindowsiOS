/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HENGEVM_PL031_H
#define HENGEVM_PL031_H

#include <stdint.h>

#include "gicv3.h"

/* PL031 real-time clock: seconds since 1970, from host time plus an offset. The host time is UTC
   (the default, for every guest: Windows reads it as UTC with RealTimeIsUniversal=1, Linux always does),
   or with localtime set the host's local time, as QEMU's -rtc base=localtime (a fallback for a Windows
   that reads the RTC as local time; never together with RealTimeIsUniversal). What the guest writes
   lasts until the board is created again (the next VM start). */
typedef struct HvPl031 {
    HvGic *gic;
    int intid;
    int localtime;    /* 0: UTC, 1: the host's local time */
    int64_t offset;   /* guest seconds minus host seconds */
    int64_t gmtoff, gmtoff_at;  /* localtime: the zone's offset, and the second it was looked up for */
    uint32_t mr, imsc, ris;
} HvPl031;

HvPl031 *hv_pl031_create(HvMachine *m, HvGic *gic, uint64_t pa, int intid);
/* Raises the alarm interrupt when the match time has come. */
void hv_pl031_tick(HvPl031 *r);

#endif
