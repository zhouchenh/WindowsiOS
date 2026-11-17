/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_ACPI_H
#define HV_ACPI_H

#include <stdint.h>
#include "fw_cfg.h"

/* Populate HvFwCfg with ACPI 6.4 tables (DSDT, FACP, APIC/MADT with GICv3 + GICv2m,
 * PPTT, GTDT, MCFG, SPCR, DBG2, IORT, XSDT), RSDP, BIOS table-loader script, and
 * SMBIOS 3.0 tables for EDK2 ArmVirtQemu and Windows 11 ARM64.
 * battery: also a battery (\_SB.BAT0, PNP0C0A) and an AC adapter (\_SB.ADP0, ACPI0003) whose state the
 * guest reads from the GED page at 0x09080100 (acpi_battery.h); GED event bit 2 (0x4) makes the GED
 * notify both of them. With battery 0 the DSDT is exactly what it was without this feature. */
#define HV_ACPI_GED_BATTERY_PA 0x09080100u /* the battery registers: the GED page (0x09080000) + 0x100 */

void hv_acpi_build_and_register(HvFwCfg *fw, int ncpus, uint64_t ram_size, int spi_msi_base, int spi_msi_count,
                                int battery);

#endif
