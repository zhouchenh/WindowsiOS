/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_ACPI_BATTERY_H
#define HV_ACPI_BATTERY_H

#include <stdint.h>

/* The host's battery as the guest's ACPI battery (\_SB.BAT0, PNP0C0A) and AC adapter (\_SB.ADP0,
 * ACPI0003): four read-only DWORD registers that the DSDT's _BST and _PSR read (acpi.c, BREG).
 *   +0x0 BSTA  _BST state: bit 0 discharging, bit 1 charging (bit 2 "critical" is never set)
 *   +0x4 BRAT  present rate in mW; 0xFFFFFFFF = unknown (iOS reports no current)
 *   +0x8 BCAP  remaining capacity in mWh, out of HV_BATTERY_FULL_MWH, never below 1%
 *   +0xC BPSR  _PSR: 1 = on AC (charging or full), 0 = on battery
 * Written by the host from any thread, read by the vCPUs: every field is accessed atomically. */
#define HV_BATTERY_FULL_MWH    10000u
#define HV_BATTERY_MIN_MWH     100u        /* 1%: Windows never sees an empty battery */
#define HV_BATTERY_VOLTAGE_MV  3850u
#define HV_BATTERY_RATE_UNKNOWN 0xFFFFFFFFu

/* The host's battery state, the same numbers as UIDeviceBatteryState. */
enum {
    HV_BATTERY_UNKNOWN = 0,
    HV_BATTERY_UNPLUGGED = 1,
    HV_BATTERY_CHARGING = 2,
    HV_BATTERY_FULL = 3,
};

typedef struct HvBattery {
    uint32_t sta, rate, cap, psr;
} HvBattery;

/* Full and on AC, until the host says otherwise. */
void hv_battery_init(HvBattery *b);
/* level: 0.0 .. 1.0, or negative when unknown (reads as full). state: HV_BATTERY_*.
 * Returns 1 when anything the guest reads changed, 0 when it is the same as before. */
int hv_battery_set(HvBattery *b, double level, int state);
/* A register (offset 0x0 .. 0xF, DWORD aligned); 0 elsewhere. */
uint32_t hv_battery_read(const HvBattery *b, uint64_t off);

#endif
