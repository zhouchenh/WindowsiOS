/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef WINIOS_JIT_BUDGET_H
#define WINIOS_JIT_BUDGET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum WinIOSRoomOverride {
    WINIOS_ROOM_DEFAULT,
    WINIOS_ROOM_OVERRIDE,
    WINIOS_ROOM_INVALID
};

static inline bool winios_room_space(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f';
}

/* This is a virtual-address-space fit target, in MiB, not a physical/Metal
 * budget. Preserve valid explicit settings; reject malformed/overflow input. */
static inline uint32_t winios_jit_room_mb(bool gpu3d, const char *text,
                                        enum WinIOSRoomOverride *status) {
    uint32_t fallback = gpu3d ? 2560 : 1024;
    if (status) *status = text ? WINIOS_ROOM_INVALID : WINIOS_ROOM_DEFAULT;
    if (!text) return fallback;
    while (winios_room_space(*text)) text++;
    if (*text == '+') text++;
    if (*text < '0' || *text > '9') return fallback;
    uint32_t value = 0;
    while (*text >= '0' && *text <= '9') {
        uint32_t digit = (uint32_t)(*text++ - '0');
        if (value > (UINT32_MAX - digit) / 10) return fallback;
        value = value * 10 + digit;
    }
    while (winios_room_space(*text)) text++;
    if (*text || value < 256) return fallback;
    if (status) *status = WINIOS_ROOM_OVERRIDE;
    return value;
}

/* Preserve the established RAM candidates and physical reserve. A failed VA
 * probe retries the next smaller candidate by passing the previous result.
 * phys_mb==0 means unknown; user caps below 1024 retain legacy auto behavior.
 * Ledger-exempt RAM is not subtracted from os_proc_available_memory(): that
 * metric describes the app's footprint allowance, not free physical memory. */
static inline uint64_t winios_jit_next_ram_mb(uint64_t phys_mb, uint32_t cap_mb,
                                            uint64_t previous_mb) {
    static const uint32_t candidates[] = {
        16384, 14336, 12288, 10240, 8192, 7680, 7168, 6656, 6144,
        5888, 5632, 5376, 5120, 4608, 4096, 3584, 3072, 2560, 2048
    };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        uint64_t mb = candidates[i];
        if (mb >= previous_mb) continue;
        if (phys_mb && (phys_mb < 2560 || mb > phys_mb - 2560)) continue;
        if (cap_mb >= 1024 && mb > cap_mb) continue;
        return mb;
    }
    return 0;
}

#endif
