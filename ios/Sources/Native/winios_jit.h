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
/* Before JIT is acquired: whether 3D will be on (probes more VA room for Metal).
 * Reads HV_3D_ROOM_MB from the process environment again before RAM allocation;
 * callers using env.txt must load it before acquiring JIT. */
void winios_jit_configure_3d(bool on);
size_t winios_jit_configured_bytes(void);
void winios_jit_install_trap_handler(void);
bool winios_jit_is_debugger_attached(void);
/* Whether a debugger traces this process right now (P_TRACED, one sysctl). Unlike CS_DEBUGGED, which
   stays set for the life of the process once any debugger attached, this clears when it detaches. */
bool winios_jit_is_traced(void);
/* A debugger still attached a few seconds after the JIT region was held and the debugger that gave it
   was told to let go: a second StikDebug session, say. While one is attached every trap stops the app
   until it answers. Asks it to detach (the JIT script answers that brk), at most three times per launch.
   Only while such a session is the likely one: within 30 s of the helper being told to let go and
   while a debugger has stayed attached since; a debugger that attaches after the process was seen
   untraced is left alone (it would stop on a brk it does not handle at every continue).
   Cheap when there is nothing to do; returns true when a detach request was sent. Main thread only.
   While winios_jit_set_helper_pending(true) holds, a debugger attached at any time is taken for the
   built-in helper still on its way (it runs henge-jit.js, which answers the detach) and asked to let
   go, up to three times per stretch of pending requests.
   Adapted from Henge's JITBootstrap.releaseLingeringDebugger (Leviidev/Henge ca44144). */
bool winios_jit_release_lingering_debugger(void);
/* Whether a built-in JIT helper enable request (BuiltInJIT.swift) is still outstanding. Main thread only. */
void winios_jit_set_helper_pending(bool pending);
bool winios_jit_acquire(size_t bytes, bool detach_after);
bool winios_jit_is_live(void);
WinIosDualMapping winios_jit_mapping(void);
void *winios_jit_guest_ram(uint64_t *out_bytes);
/* Emit allocation facts after stderr capture starts. Configuration may have
 * changed since the once-per-process RAM allocation, so log both values. */
void winios_jit_log_memory_config(uint64_t selected_ram_mb);
/* The virtio-gpu 3D hostmem window reserved before guest RAM (NULL if none). */
void *winios_gpu_window(uint64_t *out_bytes);
const char *winios_jit_status_text(void);
size_t winios_available_memory_bytes(void);

#ifdef __cplusplus
}
#endif

#endif
