#include "jit_region.h"

#include <stdio.h>
#include <stdlib.h>

static uint32_t movz_x0(uint32_t imm) {
    return 0xd2800000u | (imm & 0xffff) << 5;
}

/* Both shapes: macOS MAP_JIT, and the iOS split mapping (RX plus an RW alias). */
static int one(const char *what) {
    HvJitRegion region;
    if (hv_jit_region_open(&region, 1 << 20) != 0) {
        printf("%s: could not map the JIT region\n", what);
        return 1;
    }
    uint32_t *code = hv_jit_reserve(&region, 2);
    static const uint32_t body[2] = {0xd2800540, 0xd65f03c0}; /* mov x0, #42; ret */
    hv_jit_write(&region, code, body, sizeof body);
    hv_jit_finish(&region, code, 2);
    long (*fn)(void) = (long (*)(void))code;
    long got = fn();
    printf("%s: jit region returned %ld\n", what, got);
    int bad = got != 42;

    /* hv_jit_finish2: two ranges rewritten over and over (each run once before, so the old words are in the
       instruction cache), then one wait for both. A range left out keeps running its old code. */
    uint32_t *a = hv_jit_reserve(&region, 2), *b = hv_jit_reserve(&region, 2048);
    b += 2046; /* in another cache line, and page, than a */
    long (*fa)(void) = (long (*)(void))a, (*fb)(void) = (long (*)(void))b;
    int stale2 = 0;
    for (uint32_t i = 1; i <= 2000; i++) {
        uint32_t wa[2] = {movz_x0(i), 0xd65f03c0}, wb[2] = {movz_x0(i + 7), 0xd65f03c0};
        hv_jit_write(&region, a, wa, sizeof wa);
        hv_jit_write(&region, b, wb, sizeof wb);
        hv_jit_finish2(&region, a, 2, b, 2);
        stale2 += fa() != (long)i;
        stale2 += fb() != (long)(i + 7);
    }
    printf("%s: hv_jit_finish2, 2000 rewrites of two ranges: %d stale\n", what, stale2);
    bad |= stale2 != 0;

    /* hv_jit_finish_branch: one B rewritten as another B (chaining). Without a wait a CPU may still run the old one
       for a while (the chain's stub covers that); after a DSB and an ISB of its own it must run the new one. */
    uint32_t *f = hv_jit_reserve(&region, 6);
    const uint32_t fbody[6] = {0x14000001u, movz_x0(1), 0xd65f03c0, movz_x0(2), 0xd65f03c0, 0xd503201f};
    hv_jit_write(&region, f, fbody, sizeof fbody);
    hv_jit_finish(&region, f, 6);
    long (*ff)(void) = (long (*)(void))f;
    int stale_b = 0;
    for (int i = 0; i < 4000; i++) {
        long want = ff() == 1 ? 2 : 1; /* the B now goes to "1", run it (cached), then send it to the other */
        uint32_t insn = 0x14000000u | (want == 1 ? 1u : 3u);
        hv_jit_write(&region, f, &insn, 4);
        hv_jit_finish_branch(&region, f);
        __asm__ volatile("dsb ish\n\tisb" ::: "memory");
        stale_b += ff() != want;
    }
    printf("%s: hv_jit_finish_branch, 4000 B rewrites: %d stale\n", what, stale_b);
    bad |= stale_b != 0;
    hv_jit_region_close(&region);
    return bad;
}

int main(void) {
    int bad = one("MAP_JIT");
    setenv("HV_JIT_SPLIT", "1", 1);
    bad |= one("split");
    return bad;
}
