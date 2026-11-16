/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Dual-mapped RX/RW JIT allocator for iOS 17..27 (including iOS 26/27 TXM).
 * Adapted from Henge (Leviidev/Henge, GPL-2.0-or-later).
 */
#ifndef WINIOS_JIT_H
#define WINIOS_JIT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WinIosDualMapping {
    uint8_t *rw_addr;
    uint8_t *rx_addr;
    size_t   size;
} WinIosDualMapping;

#define WINIOS_JIT_MAX_BYTES ((size_t)768u << 20)     /* the most the app reserves room for */
/* 256 MiB by default: with a bigger cache Windows fills it less often, but dropping translations of
   rewritten code pages gets slow enough to stall a frame (150-190 ms measured at 768 MiB against
   33 ms at 256 MiB, same frame rate; scripts/bench). Also enables JIT three times faster. */
#define WINIOS_JIT_DEFAULT_BYTES ((size_t)256u << 20)

/* User limits from the app's advanced settings, set before JIT is acquired: the JIT code cache
   (MiB, 0 = the default) and the most guest RAM to reserve (MiB, 0 = as much as fits). */
void winios_jit_configure(uint32_t jit_mb, uint32_t ram_mb);
size_t winios_jit_configured_bytes(void);
void winios_jit_install_trap_handler(void);
bool winios_jit_is_debugger_attached(void);
bool winios_jit_acquire(size_t bytes, bool detach_after);
bool winios_jit_is_live(void);
WinIosDualMapping winios_jit_mapping(void);
void *winios_jit_guest_ram(uint64_t *out_bytes);
/* The virtio-gpu 3D hostmem window reserved before guest RAM (NULL if none). */
void *winios_gpu_window(uint64_t *out_bytes);
const char *winios_jit_status_text(void);
size_t winios_available_memory_bytes(void);

#ifdef __cplusplus
}
#endif

#endif
