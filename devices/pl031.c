/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "pl031.h"

#include <stdlib.h>
#include <time.h>

/* Registers and ID values as in QEMU's hw/rtc/pl031.c. */

static const uint8_t pl031_id[8] = {0x31, 0x10, 0x14, 0x00, 0x0d, 0xf0, 0x05, 0xb1};

/* The clock the RTC counts from: host UTC seconds, or with r->localtime the host's local time (UTC plus
   the zone's offset, daylight saving included). The offset is looked up at most once a second, so a zone
   or daylight-saving change shows at the next read, and the per-tick alarm check stays cheap. */
static int64_t host_now(HvPl031 *r) {
    time_t t = time(NULL);
    if (!r->localtime) return (int64_t)t;
    if ((int64_t)t != r->gmtoff_at) {
        struct tm tm;
        r->gmtoff = localtime_r(&t, &tm) ? (int64_t)tm.tm_gmtoff : 0;
        r->gmtoff_at = (int64_t)t;
    }
    return (int64_t)t + r->gmtoff;
}

static uint32_t now(HvPl031 *r) {
    return (uint32_t)(host_now(r) + r->offset);
}

static void update(HvPl031 *r) {
    hv_gicv3_set_irq(r->gic, r->intid, (r->ris & r->imsc) != 0);
}

void hv_pl031_tick(HvPl031 *r) {
    if (r->mr && now(r) >= r->mr && !(r->ris & 1)) {
        r->ris |= 1;
        update(r);
    }
}

static uint64_t pl031_read(void *opaque, uint64_t off, unsigned size) {
    (void)size;
    HvPl031 *r = opaque;
    switch (off) {
    case 0x00: return now(r);         /* DR */
    case 0x04: return r->mr;
    case 0x08: return now(r);         /* LR reads back the current value */
    case 0x0c: return 1;              /* CR: always enabled */
    case 0x10: return r->imsc;
    case 0x14: return r->ris;
    case 0x18: return r->ris & r->imsc;
    default:
        if (off >= 0xfe0 && off < 0x1000) return pl031_id[(off - 0xfe0) >> 2];
        return 0;
    }
}

static void pl031_write(void *opaque, uint64_t off, uint64_t v, unsigned size) {
    (void)size;
    HvPl031 *r = opaque;
    switch (off) {
    case 0x04: r->mr = (uint32_t)v; hv_pl031_tick(r); break;
    case 0x08: r->offset = (int64_t)(uint32_t)v - host_now(r); break;
    case 0x10: r->imsc = (uint32_t)v & 1; break;
    case 0x1c: r->ris &= ~((uint32_t)v & 1); break;
    default: break;
    }
    update(r);
}

HvPl031 *hv_pl031_create(HvMachine *m, HvGic *gic, uint64_t pa, int intid) {
    HvPl031 *r = calloc(1, sizeof *r);
    r->gic = gic;
    r->intid = intid;
    r->gmtoff_at = -1;
    hv_machine_add_mmio(m, pa, 0x1000, r, pl031_read, pl031_write, "pl031");
    return r;
}
