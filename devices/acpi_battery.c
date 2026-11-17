/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "acpi_battery.h"

#include <math.h>

static int store(uint32_t *field, uint32_t v) {
    return __atomic_exchange_n(field, v, __ATOMIC_ACQ_REL) != v;
}

void hv_battery_init(HvBattery *b) {
    __atomic_store_n(&b->sta, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&b->rate, HV_BATTERY_RATE_UNKNOWN, __ATOMIC_RELEASE);
    __atomic_store_n(&b->cap, HV_BATTERY_FULL_MWH, __ATOMIC_RELEASE);
    __atomic_store_n(&b->psr, 1, __ATOMIC_RELEASE);
}

int hv_battery_set(HvBattery *b, double level, int state) {
    uint32_t cap = HV_BATTERY_FULL_MWH;
    if (level >= 0.0 && !isnan(level)) {
        double mwh = level * (double)HV_BATTERY_FULL_MWH;
        if (mwh > (double)HV_BATTERY_FULL_MWH) mwh = (double)HV_BATTERY_FULL_MWH;
        cap = (uint32_t)lround(mwh);
    }
    if (cap < HV_BATTERY_MIN_MWH) cap = HV_BATTERY_MIN_MWH;

    uint32_t sta, psr;
    switch (state) {
    case HV_BATTERY_UNPLUGGED: sta = 1; psr = 0; break; /* discharging, on battery */
    case HV_BATTERY_CHARGING: sta = 2; psr = 1; break;  /* charging, on AC */
    default: sta = 0; psr = 1; break;                   /* full (or not known): idle, on AC */
    }

    int changed = 0;
    changed |= store(&b->cap, cap);
    changed |= store(&b->sta, sta);
    changed |= store(&b->psr, psr);
    changed |= store(&b->rate, HV_BATTERY_RATE_UNKNOWN);
    return changed;
}

uint32_t hv_battery_read(const HvBattery *b, uint64_t off) {
    switch (off) {
    case 0x0: return __atomic_load_n(&b->sta, __ATOMIC_ACQUIRE);
    case 0x4: return __atomic_load_n(&b->rate, __ATOMIC_ACQUIRE);
    case 0x8: return __atomic_load_n(&b->cap, __ATOMIC_ACQUIRE);
    case 0xC: return __atomic_load_n(&b->psr, __ATOMIC_ACQUIRE);
    default: return 0;
    }
}
