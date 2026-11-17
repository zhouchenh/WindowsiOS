// SPDX-License-Identifier: GPL-2.0-or-later
/* The PL031 RTC (devices/pl031.c) on its own: UTC by default, the host's local time with localtime set
   (HV_RTC=localtime), a guest write of the load register read back in both modes, the alarm interrupt
   and its clear, and the ID registers. The machine and the GIC are stand-ins. No VM. */
#include "pl031.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void *mmio_opaque;
static uint64_t (*mmio_read)(void *, uint64_t, unsigned);
static void (*mmio_write)(void *, uint64_t, uint64_t, unsigned);
static int irq_level = -1, irq_intid = -1;

int hv_machine_add_mmio(HvMachine *m, uint64_t pa, uint64_t size, void *opaque,
                        uint64_t (*read)(void *, uint64_t, unsigned),
                        void (*write)(void *, uint64_t, uint64_t, unsigned), const char *name) {
    (void)m;
    (void)pa;
    (void)size;
    (void)name;
    mmio_opaque = opaque;
    mmio_read = read;
    mmio_write = write;
    return 0;
}

void hv_gicv3_set_irq(HvGic *g, int intid, int level) {
    (void)g;
    irq_intid = intid;
    irq_level = level;
}

static int failures;

static void check(const char *what, long long got, long long want) {
    if (got != want) {
        printf("FAIL %s: got %lld, want %lld\n", what, got, want);
        failures++;
    } else {
        printf("ok   %s\n", what);
    }
}

/* |a - b| <= 2: a second can tick over between the two reads */
static int near(int64_t a, int64_t b) {
    return a - b <= 2 && b - a <= 2;
}

static uint32_t rd(uint64_t off) {
    return (uint32_t)mmio_read(mmio_opaque, off, 4);
}

static void wr(uint64_t off, uint32_t v) {
    mmio_write(mmio_opaque, off, v, 4);
}

static HvPl031 *make(int localtime) {
    HvPl031 *r = hv_pl031_create(NULL, NULL, 0x09010000, 34);
    r->localtime = localtime;
    return r;
}

static int64_t host_gmtoff(void) {
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    return tm.tm_gmtoff;
}

int main(void) {
    /* UTC (the default) */
    setenv("TZ", "Asia/Shanghai", 1);
    tzset();
    HvPl031 *r = make(0);
    check("UTC: DR within 2 s of time()", near(rd(0x00), time(NULL)), 1);
    check("UTC: LR reads the same clock", near(rd(0x08), time(NULL)), 1);
    wr(0x08, 1000000);
    check("UTC: LR write reads back", near(rd(0x00), 1000000), 1);
    check("CR: always enabled", rd(0x0c), 1);
    check("PeriphID0", rd(0xfe0), 0x31);
    check("PCellID3", rd(0xffc), 0xb1);

    /* the alarm: match now, interrupt on, then cleared */
    wr(0x10, 1);
    wr(0x04, rd(0x00));
    check("alarm raised", irq_level, 1);
    check("alarm on the RTC's INTID", irq_intid, 34);
    check("RIS set", rd(0x14) & 1, 1);
    check("MIS set", rd(0x18) & 1, 1);
    wr(0x1c, 1);
    check("alarm cleared", irq_level, 0);
    check("RIS cleared", rd(0x14) & 1, 0);
    wr(0x04, rd(0x00) + 3600);
    hv_pl031_tick(r);
    check("a future alarm does not fire", irq_level, 0);
    free(r);

    /* local time: Asia/Shanghai is UTC+8 all year */
    r = make(1);
    check("localtime Asia/Shanghai: UTC + 8 h", near(rd(0x00), (int64_t)time(NULL) + 8 * 3600), 1);
    wr(0x08, 2000000);
    check("localtime: LR write reads back", near(rd(0x00), 2000000), 1);
    check("localtime: offset relative to local time", near(r->offset, 2000000 - ((int64_t)time(NULL) + 8 * 3600)), 1);
    free(r);

    /* local time with daylight saving: whatever localtime_r says now */
    setenv("TZ", "America/New_York", 1);
    tzset();
    r = make(1);
    int64_t off = host_gmtoff();
    check("New York offset is -4 h or -5 h", off == -4 * 3600 || off == -5 * 3600, 1);
    check("localtime America/New_York: UTC + tm_gmtoff", near(rd(0x00), (int64_t)time(NULL) + off), 1);
    free(r);

    /* UTC mode ignores the zone in New York too */
    r = make(0);
    check("UTC in New York: time()", near(rd(0x00), time(NULL)), 1);
    free(r);

    /* Etc/UTC: local time equals UTC */
    setenv("TZ", "UTC", 1);
    tzset();
    r = make(1);
    check("localtime UTC: time()", near(rd(0x00), time(NULL)), 1);
    free(r);

    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("all PL031 checks passed\n");
    return 0;
}
