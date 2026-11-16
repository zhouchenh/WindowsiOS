// Stage 1 walker: granules, block sizes, TTBR0/TTBR1, TBI, permissions and
// fault codes, checked directly against hv_mmu_walk.
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dispatch.h"
#include "machine.h"
#include "mmu.h"
#include "sysreg.h"

#define PT_PA 0x80000000ull
#define PT_SIZE (1u << 20)

static uint8_t *pt;
static uint64_t pt_next;
static int failures, checks;

static uint64_t *host(uint64_t pa) {
    return (uint64_t *)(pt + (pa - PT_PA));
}

static uint64_t alloc_table(void) {
    uint64_t pa = PT_PA + pt_next;
    pt_next += 65536; /* big enough and aligned for any granule */
    memset(host(pa), 0, 65536);
    return pa;
}

/* Install a leaf for va at `leaf_level`, creating tables from the start level. */
static uint64_t *map(uint64_t root, int g, int inputsize, uint64_t va, int leaf_level, uint64_t desc,
                     uint64_t table_bits) {
    int stride = g - 3;
    int levels = (inputsize - g + stride - 1) / stride;
    uint64_t table = root;
    for (int level = 4 - levels;; level++) {
        int shift = g + stride * (3 - level);
        int idx_bits = level == 4 - levels ? inputsize - shift : stride;
        uint64_t *e = &host(table)[(va >> shift) & ((1ull << idx_bits) - 1)];
        if (level == leaf_level) {
            *e = desc;
            return e;
        }
        if (!(*e & 1)) *e = alloc_table() | 3 | table_bits;
        table = *e & 0x0000fffffffff000ull & ~((1ull << g) - 1);
    }
}

#define AF (1ull << 10)
#define PAGE 3ull
#define BLOCK 1ull
#define AP(x) ((uint64_t)(x) << 6)
#define PXN (1ull << 53)
#define UXN (1ull << 54)

static void expect(const char *what, HvCpu *cpu, uint64_t va, HvAccess acc, int el, uint64_t want_pa, uint32_t want_fsc) {
    HvWalk w;
    hv_mmu_walk(cpu, va, acc, el, &w);
    checks++;
    if (w.fsc != want_fsc || (!want_fsc && w.pa != want_pa)) {
        printf("  FAIL %s: va %llx -> pa %llx fsc %02x, expected pa %llx fsc %02x\n", what, (unsigned long long)va,
               (unsigned long long)w.pa, w.fsc, (unsigned long long)want_pa, want_fsc);
        failures++;
    }
}

static void check_that(int ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void check_that(int ok, const char *fmt, ...) {
    checks++;
    if (ok) return;
    va_list ap;
    va_start(ap, fmt);
    printf("  FAIL ");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    failures++;
}

/* Entries of all four TLB tables that are not invalid. */
static int live_entries(HvCpu *cpu) {
    int n = 0;
    for (uint32_t i = 0; i < HV_TLB_SIZE * 4; i++) {
        const HvTlbEntry *e = &cpu->tlb[i];
        n += e->read_tag != HV_TLB_INVALID || e->write_tag != HV_TLB_INVALID || e->exec_tag != HV_TLB_INVALID;
    }
    return n;
}

static int blooms_clear(HvCpu *cpu) {
    const HvPerCpu *p = cpu->pc_state;
    for (int i = 0; i < 64; i++)
        if (p->large_2m_bloom[i]) return 0;
    for (int i = 0; i < 8; i++)
        if (p->large_big_bloom[i]) return 0;
    return 1;
}

/* 4 KB granule, 39 bits both halves, for the TLB tests: 512 pages and four 2 MB blocks in each half, all on
   RAM at BIG_PA (4 MB: two blocks' worth). User pages are EL0 RW; kernel ones EL1 only. */
#define BIG_PA 0x100000000ull
#define UPAGES 0x20000000ull
#define UBLOCKS 0x40000000ull
#define KPAGES 0xffffffc020000000ull
#define KBLOCKS 0xffffffc040000000ull
static uint64_t tlb_r0, tlb_r1;

static void tlb_tables(void) {
    pt_next = 2 * 65536;
    tlb_r0 = alloc_table();
    tlb_r1 = alloc_table();
    for (uint64_t i = 0; i < 512; i++) {
        map(tlb_r0, 12, 39, UPAGES + (i << 12), 3, (BIG_PA + (i << 12)) | PAGE | AF | AP(1), 0);
        map(tlb_r1, 12, 39, KPAGES + (i << 12), 3, (BIG_PA + (i << 12)) | PAGE | AF | AP(0), 0);
    }
    for (uint64_t b = 0; b < 4; b++) {
        map(tlb_r0, 12, 39, UBLOCKS + (b << 21), 2, (BIG_PA + ((b & 1) << 21)) | BLOCK | AF | AP(1), 0);
        map(tlb_r1, 12, 39, KBLOCKS + (b << 21), 2, (BIG_PA + ((b & 1) << 21)) | BLOCK | AF | AP(0), 0);
    }
}

static void tlb_mmu_on(HvCpu *cpu, uint64_t asid) {
    cpu->el = 1;
    cpu->mair_el1 = 0xff;
    cpu->tcr_el1 = 25 | 25u << 16 | 2u << 30 | 5ull << 32 | 1ull << 36; /* T0SZ T1SZ 25, TG0 TG1 4K, 16-bit ASIDs */
    cpu->ttbr0_el1 = asid << 48 | tlb_r0;
    cpu->ttbr1_el1 = tlb_r1;
    cpu->sctlr_el1 |= 1;
    hv_ijc_switch(cpu);
    hv_tlb_flush(cpu);
}

/* n accesses from `first`, one page apart (wrapping at 2048 pages, the blocks' worth), through TLB table `table`. */
static void tlb_touch(HvCpu *cpu, uint64_t first, uint32_t n, int table, uint64_t span) {
    uint64_t pa;
    uint64_t pan = cpu->pstate_extra;
    if (table == 2) cpu->pstate_extra |= HV_PSTATE_PAN;
    for (uint32_t i = 0; i < n; i++) {
        uint64_t va = first + (((uint64_t)i % span) << 12);
        uint32_t fsc = hv_mmu_access(cpu, va, HV_ACC_READ, table ? 1 : 0, &pa);
        if (fsc) {
            check_that(0, "TLB test setup: access to %llx (table %d) faulted %x", (unsigned long long)va, table, fsc);
            break;
        }
    }
    cpu->pstate_extra = pan;
}

/* HV_TLB_LOGFLUSH: a whole-TLB flush clears only the logged entries; check that nothing at all survives one, after
   every way entries get into the TLB and out of the logs, with 4 KB pages and 2 MB blocks in both halves. */
static void test_logged_flush(HvMachine *m, HvCpu *cpu) {
    tlb_tables();
    struct { const char *what; uint32_t user, kernel; } fills[] = {
        {"a few", 100, 100}, {"user log full", 3000, 100}, {"kernel log full", 100, 5000}, {"both full", 3000, 5000},
    };
    for (int f = 0; f < 4; f++) {
        hv_cpu_reset(cpu, m);
        tlb_mmu_on(cpu, 5);
        tlb_touch(cpu, UPAGES, fills[f].user < 512 ? fills[f].user : 512, 0, 512);
        tlb_touch(cpu, UBLOCKS, fills[f].user, 1, 2048);
        tlb_touch(cpu, KPAGES, fills[f].kernel / 2, 1, 512);
        tlb_touch(cpu, KBLOCKS, fills[f].kernel - fills[f].kernel / 2, 2, 2048);
        int before = live_entries(cpu);
        hv_tlb_flush(cpu);
        int after = live_entries(cpu);
        check_that(before > 0 && after == 0 && blooms_clear(cpu), "whole-TLB flush, %s: %d entries before, %d after%s (HV_TLB_LOGFLUSH=%d)",
                   fills[f].what, before, after, blooms_clear(cpu) ? "" : ", large-page filters set", hv_knob[HV_K_LOGFLUSH]);
    }

    /* User entries overwritten by kernel ones in the same slots, a kernel flush, a user flush, then everything. */
    hv_cpu_reset(cpu, m);
    tlb_mmu_on(cpu, 5);
    tlb_touch(cpu, UPAGES, 200, 1, 512);         /* slots 0..199 of table 1: user */
    hv_tlb_flush_kernel(cpu);
    tlb_touch(cpu, KPAGES, 100, 1, 512);         /* slots 0..99 of table 1: kernel now */
    hv_tlb_flush_user(cpu);                      /* clears 100..199, keeps the kernel ones */
    tlb_touch(cpu, UPAGES + (300 << 12), 50, 0, 512);
    tlb_touch(cpu, KBLOCKS, 30, 2, 2048);
    hv_tlb_flush(cpu);
    check_that(live_entries(cpu) == 0, "flush after kernel and user flushes over shared slots: %d entries left", live_entries(cpu));

    /* A process switch puts entries aside and back (a stash restore fills the TLB without tlb_fill). */
    hv_cpu_reset(cpu, m);
    tlb_mmu_on(cpu, 5);
    tlb_touch(cpu, UPAGES, 300, 0, 512);
    cpu->x[0] = 6ull << 48 | tlb_r0;
    hv_sysreg_msr(cpu, 0xd5182000u, 0);          /* msr ttbr0_el1, x0: ASID 6 */
    tlb_touch(cpu, UBLOCKS, 100, 0, 2048);
    cpu->x[0] = 5ull << 48 | tlb_r0;
    hv_sysreg_msr(cpu, 0xd5182000u, 0);          /* back to ASID 5: its 300 come back */
    int restored = live_entries(cpu);
    hv_tlb_flush(cpu);
    check_that(restored >= 300 && live_entries(cpu) == 0, "flush after a stash restore: %d restored, %d left", restored, live_entries(cpu));

    /* A CPU reset leaves a zeroed TLB, logged nowhere. */
    tlb_touch(cpu, KPAGES, 64, 1, 512);
    hv_cpu_reset(cpu, m);
    check_that(live_entries(cpu) == 0, "CPU reset: %d entries not invalid", live_entries(cpu));

    /* A change of TLB layout (HV_TLBT) at a flush: the logs name slots of the old one. */
    for (int round = 0; round < 2; round++) {
        tlb_mmu_on(cpu, 5);
        tlb_touch(cpu, UPAGES, 400, 0, 512);
        tlb_touch(cpu, KBLOCKS, 900, 1, 2048);
        hv_knob[HV_K_TLBT] = !hv_knob[HV_K_TLBT];
        hv_flush_blocks(m);
        check_that(live_entries(cpu) == 0, "TLB layout change to %s: %d entries left", hv_tlb_tmajor ? "table-major" : "slot-major", live_entries(cpu));
    }

    /* The user half of the branch cache starts over: no ASID keeps its id (a few logged, then more than the log). */
    for (uint32_t n = 100; n <= 700; n += 600) {
        hv_cpu_reset(cpu, m);
        tlb_mmu_on(cpu, 1);
        for (uint64_t a = 1; a <= n; a++) {
            cpu->x[0] = a << 48 | tlb_r0;
            hv_sysreg_msr(cpu, 0xd5182000u, 0);
        }
        uint32_t next = cpu->next_cid;
        hv_ijc_reset(cpu, 0);
        int kept = 0;
        for (uint32_t a = 0; a < 65536; a++)
            if (cpu->asid_cid[a] && a != n) kept++;
        check_that(kept == 0 && cpu->asid_cid[n] >= next, "user branch-cache reset after %u ASIDs: %d kept their ids, current %u (next was %u)",
                   n, kept, cpu->asid_cid[n], next);
    }
    hv_cpu_reset(cpu, m);
}

/* Can a lookup on CPU i still find tag (VA ^ salt) in its branch cache, table `flags`? It is there, and its salt is
   one a lookup may use: a kernel salt current or kept for a TTBR1 (kttbr_map), a process id some ASID has now. A reset
   leaves entries in place and only makes their salts unreachable. */
static int ijc_has(HvMachine *m, int i, uint32_t flags, uint64_t tag) {
    const uint64_t *ent = m->percpu[i].ijc + (size_t)(flags & (HV_IJC_TABLES - 1)) * (HV_IJC_TABLE_BYTES / 8) + (size_t)hv_ijc_index(tag) * 2;
    if (!tag || (ent[0] != tag && ent[2] != tag)) return 0;
    const HvCpu *c = m->cpus[i];
    if (flags & HV_BLOCK_EL1) {
        uint16_t kg = (uint16_t)((tag >> 48) ^ 0xffff);
        if (kg == (uint16_t)(c->ijc_salt[1] >> 48)) return 1;
        for (int k = 0; k < HV_KTTBR_SLOTS; k++)
            if (c->kttbr_map[k].ttbr1 && c->kttbr_map[k].kgen == kg) return 1;
        return 0;
    }
    uint16_t cid = (uint16_t)(tag >> 48);
    for (uint32_t a = 0; a < 65536; a++)
        if (c->asid_cid[a] == cid) return 1;
    return 0;
}

/* A block at va translated from guest page pa, cached in cpu's branch cache the way the dispatcher does it (its page
   in the TLB first). Returns the tag it went in under, 0 if it was not cached. */
static uint64_t cache_block(HvMachine *m, HvCpu *cpu, HvBlock *b, uint64_t va, uint64_t page_pa, uint32_t flags) {
    uint64_t pa = page_pa | (va & ((1ull << HV_TLB_PAGE_BITS) - 1));
    HvRam *r = hv_ram_lookup(m, pa);
    uint64_t pg = (pa - r->pa) >> HV_TLB_PAGE_BITS, got;
    *b = (HvBlock){.va = va, .pa = pa, .flags = flags, .ram = r, .pg = pg, .gen = r->page_gen[pg],
                   .code = (uint32_t *)(uintptr_t)(0x10000 + (va & 0xffff))};
    r->code_pages[pg] = 1;
    uint64_t save = cpu->pstate_extra;
    if (flags & HV_BLOCK_PAN) cpu->pstate_extra |= HV_PSTATE_PAN;
    uint32_t fsc = hv_mmu_access(cpu, va, HV_ACC_EXEC, (flags & HV_BLOCK_EL1) ? 1 : 0, &got);
    cpu->pstate_extra = save;
    if (fsc || got != pa) return 0;
    if (!hv_ijc_fill_checked(cpu, b)) return 0;
    return va ^ cpu->ijc_salt[flags & HV_BLOCK_EL1];
}

/* HV_IJC_PAGES: a code change drops the cached branch targets into its page under every id that can still be looked
   up (every process's, every TTBR1's), on this CPU at once and on another by request, and keeps the rest. */
static void test_code_page_drops(HvMachine *m, HvCpu *cpu, HvCpu *cpu1) {
    tlb_tables();
    hv_cpu_reset_index(cpu1, m, 1);
    hv_cpu_reset(cpu, m);
    tlb_mmu_on(cpu, 5);
    tlb_mmu_on(cpu1, 5);
    const uint64_t code_pa = BIG_PA + 0x5000, kcode_pa = BIG_PA + 0x7000, other_pa = BIG_PA + 0x6000;
    const uint64_t uva = UPAGES + 0x5010, uva_other = UPAGES + 0x6010, kva = KPAGES + 0x7020, kva_other = KPAGES + 0x6020;
    static HvBlock blk[16];
    uint64_t tag[16];
    int ok = 1;
    hv_self = cpu;
    /* User: the page cached by ASIDs 5 and 6 (both still live), another page by ASID 7. */
    ok &= (tag[0] = cache_block(m, cpu, &blk[0], uva, code_pa, 0)) != 0;
    cpu->x[0] = 6ull << 48 | tlb_r0;
    hv_sysreg_msr(cpu, 0xd5182000u, 0);
    ok &= (tag[1] = cache_block(m, cpu, &blk[1], uva, code_pa, 0)) != 0;
    cpu->x[0] = 7ull << 48 | tlb_r0;
    hv_sysreg_msr(cpu, 0xd5182000u, 0);
    ok &= (tag[2] = cache_block(m, cpu, &blk[2], uva_other, other_pa, 0)) != 0;
    /* Kernel: the same page (its kernel alias) cached under two TTBR1s' salts, a third TTBR1 current; another page too. */
    cpu->x[0] = tlb_r1;
    hv_sysreg_msr(cpu, 0xd5182020u, 0);
    cpu->x[0] = tlb_r1 | 1ull << 48; /* TCR.A1 is 0: another TTBR1 value, the same tables */
    hv_sysreg_msr(cpu, 0xd5182020u, 0);
    ok &= (tag[3] = cache_block(m, cpu, &blk[3], kva, kcode_pa, HV_BLOCK_EL1)) != 0;
    cpu->x[0] = tlb_r1 | 2ull << 48;
    hv_sysreg_msr(cpu, 0xd5182020u, 0);
    ok &= (tag[4] = cache_block(m, cpu, &blk[4], kva, kcode_pa, HV_BLOCK_EL1 | HV_BLOCK_SPX)) != 0;
    ok &= (tag[5] = cache_block(m, cpu, &blk[5], kva_other, other_pa, HV_BLOCK_EL1)) != 0;
    cpu->x[0] = tlb_r1 | 3ull << 48;
    hv_sysreg_msr(cpu, 0xd5182020u, 0);
    /* The other CPU: the user page by its ASID 5, the kernel one and another page by its kernel salt. */
    hv_self = cpu1;
    ok &= (tag[6] = cache_block(m, cpu1, &blk[6], uva, code_pa, 0)) != 0;
    ok &= (tag[7] = cache_block(m, cpu1, &blk[7], kva_other, other_pa, HV_BLOCK_EL1)) != 0;
    ok &= (tag[8] = cache_block(m, cpu1, &blk[8], kva, kcode_pa, HV_BLOCK_EL1)) != 0;
    check_that(ok && tag[3] != tag[4] && tag[0] != tag[1], "code-page drops: setup (cached %d)", ok);
    const uint32_t fl[9] = {0, 0, 0, HV_BLOCK_EL1, HV_BLOCK_EL1 | HV_BLOCK_SPX, HV_BLOCK_EL1, 0, HV_BLOCK_EL1, HV_BLOCK_EL1};
    const int on[9] = {0, 0, 0, 0, 0, 0, 1, 1, 1};
    /* The code changes in both pages, seen by CPU 0 (stores of its own): it drops its entries now, CPU 1 when it
       next looks. */
    hv_self = cpu;
    hv_invalidate_code(m, code_pa);
    hv_invalidate_code(m, kcode_pa);
    hv_self = NULL;
    hv_cpu_process_requests(cpu1);
    const int stale[9] = {1, 1, 0, 1, 1, 0, 1, 0, 1}; /* led into a changed page */
    for (int k = 0; k < 9; k++) {
        int has = ijc_has(m, on[k], fl[k], tag[k]);
        if (stale[k]) check_that(!has, "code-page drops: CPU %d's entry %d (into the changed page) kept (HV_IJC_PAGES=%d)", on[k], k, hv_knob[HV_K_IJCPAGES]);
        else if (hv_knob[HV_K_IJCPAGES]) check_that(has, "code-page drops: CPU %d's entry %d (another page) dropped", on[k], k);
    }
    /* Back on a TTBR1 whose salt cached the page: still nothing to find. */
    cpu->x[0] = tlb_r1 | 1ull << 48;
    hv_sysreg_msr(cpu, 0xd5182020u, 0);
    check_that(!ijc_has(m, 0, HV_BLOCK_EL1, kva ^ cpu->ijc_salt[1]), "code-page drops: a TTBR1 switched back to finds the dropped target");

    /* A block made before the change cannot be cached after it. */
    hv_self = cpu;
    uint64_t t = cache_block(m, cpu, &blk[13], uva_other, other_pa, 0);
    HvRam *r = hv_ram_lookup(m, other_pa);
    hv_invalidate_code(m, other_pa);
    r->code_pages[(other_pa - r->pa) >> HV_TLB_PAGE_BITS] = 1;
    check_that(t && !hv_ijc_fill_checked(cpu, &blk[13]), "code-page drops: a stale block was cached");

    /* One page cached under two VA pages (a user and a kernel alias): the change drops both. */
    t = cache_block(m, cpu, &blk[9], uva, code_pa, 0);
    uint64_t t2 = cache_block(m, cpu, &blk[10], KPAGES + 0x5020, code_pa, HV_BLOCK_EL1);
    hv_invalidate_code(m, code_pa);
    check_that(t && t2 && !ijc_has(m, 0, 0, t) && !ijc_has(m, 0, HV_BLOCK_EL1, t2), "code-page drops: a page cached under two VAs kept one");

    /* More changes than the other CPU's queue holds before it looks: it starts its cache over. */
    hv_self = cpu1;
    t = cache_block(m, cpu1, &blk[11], uva_other, other_pa, 0);
    hv_self = cpu;
    for (int k = 0; k < 20; k++) {
        cache_block(m, cpu, &blk[12], uva, code_pa, 0);
        hv_invalidate_code(m, code_pa);
    }
    hv_self = NULL;
    hv_cpu_process_requests(cpu1);
    check_that(t && !ijc_has(m, 1, 0, t), "code-page drops: a full request queue did not drop everything");
    hv_cpu_reset(cpu, m);
}

int main(void) {
    static HvMachine m;
    static HvCpu cpu, cpu1;
    hv_machine_init(&m, 1 << 20);
    printf("knobs: HV_IJC_TTBKEY=%d HV_TLB_LOGFLUSH=%d HV_IJC_PAGES=%d\n", hv_knob[HV_K_IJCTTBKEY], hv_knob[HV_K_LOGFLUSH],
           hv_knob[HV_K_IJCPAGES]);
    pt = aligned_alloc(65536, PT_SIZE);
    hv_machine_add_ram(&m, PT_PA, PT_SIZE, pt, 0);
    uint8_t *big = aligned_alloc(1u << 21, 4u << 20);
    memset(big, 0, 4u << 20);
    hv_machine_add_ram(&m, BIG_PA, 4u << 20, big, 0);
    hv_cpu_reset(&cpu, &m);

    expect("mmu off", &cpu, 0x12345678, HV_ACC_WRITE, 1, 0x12345678, 0);

    /* 16 KB granule, 48-bit TTBR0 (four levels), 39-bit TTBR1 (three levels). */
    uint64_t r0 = alloc_table(), r1 = alloc_table();
    cpu.ttbr0_el1 = r0 | 0x1234ull << 48; /* an ASID must not leak into the table address */
    cpu.ttbr1_el1 = r1;
    cpu.mair_el1 = 0x00ff;
    cpu.tcr_el1 = 16 | 2u << 14 | 25u << 16 | 1u << 30 | 5ull << 32 | 1ull << 37; /* T0SZ 16, TG0 16K, T1SZ 25, TG1 16K, TBI0 */
    cpu.sctlr_el1 |= 1;

    map(r0, 14, 48, 0x100004000, 3, 0x40008000 | PAGE | AF | AP(0), 0);
    expect("16K page", &cpu, 0x100004abc, HV_ACC_READ, 1, 0x40008abc, 0);
    expect("16K page, next page unmapped", &cpu, 0x100008000, HV_ACC_READ, 1, 0, HV_FSC_TRANSLATION(3));
    expect("16K, no level 1 table", &cpu, 0x7f0000000000, HV_ACC_READ, 1, 0, HV_FSC_TRANSLATION(1));
    expect("16K, VA above T0SZ", &cpu, 0x0001000000000000, HV_ACC_READ, 1, 0, HV_FSC_TRANSLATION(0));
    expect("TBI0 ignores the top byte", &cpu, 0x5a00000100004010, HV_ACC_READ, 1, 0x40008010, 0);
    cpu.tcr_el1 &= ~(1ull << 37);
    expect("without TBI0 a tag faults", &cpu, 0x5a00000100004010, HV_ACC_READ, 1, 0, HV_FSC_TRANSLATION(0));
    cpu.tcr_el1 |= 1ull << 37;

    map(r0, 14, 48, 0x200000000, 2, 0x82000000 | BLOCK | AF, 0);
    expect("16K: 32 MB block", &cpu, 0x201234560, HV_ACC_WRITE, 1, 0x83234560, 0);
    map(r0, 14, 48, 0x300000000, 3, 0x40010000 | PAGE, 0);
    expect("access flag clear", &cpu, 0x300000000, HV_ACC_READ, 1, 0, HV_FSC_ACCESS(3));

    /* Permissions. */
    map(r0, 14, 48, 0x100010000, 3, 0x40010000 | PAGE | AF | AP(2), 0); /* EL1 RO */
    expect("EL1 RO: read", &cpu, 0x100010000, HV_ACC_READ, 1, 0x40010000, 0);
    expect("EL1 RO: write", &cpu, 0x100010000, HV_ACC_WRITE, 1, 0, HV_FSC_PERMISSION(3));
    expect("EL1 only: EL0 read", &cpu, 0x100004000, HV_ACC_READ, 0, 0, HV_FSC_PERMISSION(3));
    map(r0, 14, 48, 0x100014000, 3, 0x40014000 | PAGE | AF | AP(1), 0); /* EL0 and EL1 RW */
    expect("EL0 RW: EL0 write", &cpu, 0x100014000, HV_ACC_WRITE, 0, 0x40014000, 0);
    expect("EL0 RW: EL1 cannot execute", &cpu, 0x100014000, HV_ACC_EXEC, 1, 0, HV_FSC_PERMISSION(3));
    expect("EL0 RW: EL0 executes", &cpu, 0x100014000, HV_ACC_EXEC, 0, 0x40014000, 0);
    cpu.pstate_extra |= HV_PSTATE_PAN;
    expect("PAN: EL1 read of an EL0 page", &cpu, 0x100014000, HV_ACC_READ, 1, 0, HV_FSC_PERMISSION(3));
    expect("PAN: EL1 page unaffected", &cpu, 0x100004000, HV_ACC_READ, 1, 0x40008000, 0);
    expect("PAN: LDTR uses EL0 rights", &cpu, 0x100014000, HV_ACC_READ, 0, 0x40014000, 0);
    cpu.pstate_extra &= ~(uint64_t)HV_PSTATE_PAN;
    map(r0, 14, 48, 0x100018000, 3, 0x40018000 | PAGE | AF | AP(3) | UXN, 0); /* RO both, EL0 XN */
    expect("UXN: EL0 exec", &cpu, 0x100018000, HV_ACC_EXEC, 0, 0, HV_FSC_PERMISSION(3));
    expect("UXN: EL1 exec", &cpu, 0x100018000, HV_ACC_EXEC, 1, 0x40018000, 0);
    map(r0, 14, 48, 0x10001c000, 3, 0x4001c000 | PAGE | AF | PXN, 0);
    expect("PXN: EL1 exec", &cpu, 0x10001c000, HV_ACC_EXEC, 1, 0, HV_FSC_PERMISSION(3));
    cpu.sctlr_el1 |= 1u << 19;
    expect("WXN: writable is not executable", &cpu, 0x100004000, HV_ACC_EXEC, 1, 0, HV_FSC_PERMISSION(3));
    cpu.sctlr_el1 &= ~(1ull << 19);
    expect("no WXN: executable", &cpu, 0x100004000, HV_ACC_EXEC, 1, 0x40008000, 0);

    /* APTable on a new level 1 table: bit 61 = no EL0, bit 62 = no writes. */
    map(r0, 14, 48, 0x500000000000, 3, 0x40020000 | PAGE | AF | AP(1), 1ull << 61);
    expect("APTable no-EL0", &cpu, 0x500000000000, HV_ACC_READ, 0, 0, HV_FSC_PERMISSION(3));
    map(r0, 14, 48, 0x600000000000, 3, 0x40024000 | PAGE | AF | AP(0), 1ull << 62);
    expect("APTable read-only", &cpu, 0x600000000000, HV_ACC_WRITE, 1, 0, HV_FSC_PERMISSION(3));
    expect("APTable read-only: read", &cpu, 0x600000000000, HV_ACC_READ, 1, 0x40024000, 0);

    /* TTBR1, 39-bit: starts at level 1. */
    map(r1, 14, 39, 0xffffffc012340000, 3, 0x40028000 | PAGE | AF, 0);
    expect("TTBR1 page", &cpu, 0xffffffc012343210, HV_ACC_READ, 1, 0x4002b210, 0);
    expect("TTBR1: hole between ranges", &cpu, 0xffff000012340000, HV_ACC_READ, 1, 0, HV_FSC_TRANSLATION(0));
    cpu.tcr_el1 |= 1u << 23;
    expect("EPD1 disables TTBR1 walks", &cpu, 0xffffffc012343210, HV_ACC_READ, 1, 0, HV_FSC_TRANSLATION(0));
    cpu.tcr_el1 &= ~(1ull << 23);

    /* Non-RAM mappings do not enter the TLB. */
    uint64_t pa;
    hv_tlb_flush(&cpu);
    hv_mmu_access(&cpu, 0x100004000, HV_ACC_READ, 1, &pa);
    checks++;
    /* 0x40008000 is not RAM here, so nothing may be filled */
    if ((*hv_tlb_ent(&cpu, (0x100004000 >> HV_TLB_PAGE_BITS) & (HV_TLB_SIZE - 1), 1)).read_tag != HV_TLB_INVALID) {
        printf("  FAIL TLB filled for non-RAM\n");
        failures++;
    }

    /* 4 KB granule, 39-bit TTBR0 (levels 1-3): pages, 2 MB and 1 GB blocks. */
    pt_next = 2 * 65536;
    uint64_t r4 = alloc_table();
    cpu.ttbr0_el1 = r4;
    cpu.tcr_el1 = 25 | 0u << 14 | 1u << 23 | 5ull << 32;
    map(r4, 12, 39, 0x12345000, 3, (PT_PA + 0xf0000) | PAGE | AF, 0);
    expect("4K page", &cpu, 0x12345678, HV_ACC_READ, 1, PT_PA + 0xf0678, 0);
    map(r4, 12, 39, 0x40200000, 2, 0x80400000 | BLOCK | AF, 0);
    expect("4K: 2 MB block", &cpu, 0x40212345, HV_ACC_READ, 1, 0x80412345, 0);
    map(r4, 12, 39, 0x4000000000 - 0x40000000, 1, 0xc0000000 | BLOCK | AF, 0);
    expect("4K: 1 GB block", &cpu, 0x3fc0123456, HV_ACC_READ, 1, 0xc0123456, 0);
    hv_tlb_flush(&cpu);
    hv_mmu_access(&cpu, 0x12345678, HV_ACC_READ, 1, &pa);
    checks++;
    if ((*hv_tlb_ent(&cpu, (0x12345678 >> HV_TLB_PAGE_BITS) & (HV_TLB_SIZE - 1), 1)).read_tag == HV_TLB_INVALID) {
        printf("  FAIL a 4K RAM mapping did not enter the 4K TLB\n");
        failures++;
    }

    /* 64 KB granule, 42-bit TTBR0 (levels 2-3): pages and 512 MB blocks. */
    uint64_t r6 = alloc_table();
    cpu.ttbr0_el1 = r6;
    cpu.tcr_el1 = 22 | 1u << 14 | 1u << 23 | 5ull << 32;
    map(r6, 16, 42, 0x123450000, 3, 0x40050000 | PAGE | AF, 0);
    expect("64K page", &cpu, 0x12345abcd, HV_ACC_READ, 1, 0x4005abcd, 0);
    map(r6, 16, 42, 0x200000000, 2, 0x60000000 | BLOCK | AF, 0);
    expect("64K: 512 MB block", &cpu, 0x21234abcd, HV_ACC_READ, 1, 0x7234abcd, 0);
    map(r6, 16, 42, 0x300000000, 3, 0x40060000 | BLOCK | AF, 0);
    expect("block descriptor at level 3 is invalid", &cpu, 0x300000000, HV_ACC_READ, 1, 0, HV_FSC_TRANSLATION(3));

    /* TLBI RVAE1IS: 6 pages of 4 KB from the base drop, the ones after stay; also for a kernel range. */
    {
        static const uint64_t bases[2] = {0x100000000ull, 0xfffffe0012340000ull};
        for (int b = 0; b < 2; b++) {
            hv_tlb_flush(&cpu);
            int table = (bases[b] >> 55) & 1 ? 1 : 0;
            for (int k = 0; k < 8; k++) {
                uint64_t va = bases[b] + ((uint64_t)k << HV_TLB_PAGE_BITS);
                HvTlbEntry *t = &(*hv_tlb_ent(&cpu, (va >> HV_TLB_PAGE_BITS) & (HV_TLB_SIZE - 1), table));
                t->read_tag = va - HV_TLB_ADJ;
                t->addend = 0;
            }
            cpu.el = 1;
            cpu.x[1] = 5ull << 48 | 1ull << 46 | 0ull << 44 | 2ull << 39 | ((bases[b] >> 12) & 0x1fffffffffull);
            hv_sysreg_sys(&cpu, 0xd5088221u, 0); /* tlbi rvae1is, x1 */
            for (int k = 0; k < 8; k++) {
                uint64_t va = bases[b] + ((uint64_t)k << HV_TLB_PAGE_BITS);
                int dropped = (*hv_tlb_ent(&cpu, (va >> HV_TLB_PAGE_BITS) & (HV_TLB_SIZE - 1), table)).read_tag == HV_TLB_INVALID;
                checks++;
                if (dropped != (k < 6)) {
                    printf("  FAIL range TLBI, base %llx page %d: %s\n", (unsigned long long)bases[b], k,
                           dropped ? "dropped" : "kept");
                    failures++;
                }
            }
        }
    }

    /* A big kernel-range TLBI drops the kernel pages in the range and keeps the rest, the processes' entries included
       (it used to flush everything). 512 pages goes page by page, 6144 pages by a scan. */
    {
        static const struct { uint32_t scale, num, pages; } ranges[2] = {{1, 7, 512}, {2, 2, 6144}};
        const uint64_t base = 0xfffffe0040000000ull;
        for (int r = 0; r < 2; r++) {
            hv_tlb_flush(&cpu);
            const int32_t ks[6] = {0, 1, (int32_t)ranges[r].pages / 2, (int32_t)ranges[r].pages - 1, (int32_t)ranges[r].pages, (int32_t)ranges[r].pages + 300};
            for (int k = 0; k < 6; k++) {
                uint64_t va = base + ((uint64_t)ks[k] << HV_TLB_PAGE_BITS);
                HvTlbEntry *t = hv_tlb_ent(&cpu, (va >> HV_TLB_PAGE_BITS) & (HV_TLB_SIZE - 1), 1);
                t->read_tag = va - HV_TLB_ADJ;
                t->addend = 0;
            }
            uint64_t uva = 0x100000000ull + ((uint64_t)7000 << HV_TLB_PAGE_BITS); /* a process's page, in a slot outside the range's */
            HvTlbEntry *u = hv_tlb_ent(&cpu, (uva >> HV_TLB_PAGE_BITS) & (HV_TLB_SIZE - 1), 0);
            u->read_tag = uva - HV_TLB_ADJ;
            u->addend = 0;
            cpu.el = 1;
            cpu.x[1] = 0ull << 48 | 1ull << 46 | (uint64_t)ranges[r].scale << 44 | (uint64_t)ranges[r].num << 39 | ((base >> 12) & 0x1fffffffffull);
            hv_sysreg_sys(&cpu, 0xd5088221u, 0); /* tlbi rvae1is, x1 */
            for (int k = 0; k < 6; k++) {
                uint64_t va = base + ((uint64_t)ks[k] << HV_TLB_PAGE_BITS);
                int dropped = hv_tlb_ent(&cpu, (va >> HV_TLB_PAGE_BITS) & (HV_TLB_SIZE - 1), 1)->read_tag == HV_TLB_INVALID;
                checks++;
                if (dropped != (ks[k] < (int32_t)ranges[r].pages)) {
                    printf("  FAIL big kernel range %u pages, page %d: %s\n", ranges[r].pages, ks[k], dropped ? "dropped" : "kept");
                    failures++;
                }
            }
            checks++;
            if (hv_tlb_ent(&cpu, (uva >> HV_TLB_PAGE_BITS) & (HV_TLB_SIZE - 1), 0)->read_tag == HV_TLB_INVALID) {
                printf("  FAIL big kernel range %u pages dropped a process's entry\n", ranges[r].pages);
                failures++;
            }
        }
    }

    /* A TLBI by VA and ASID forgets the indirect-branch cache entries of that page
       for that address space, and nothing else. Entries are filled the way the dispatcher does it. */
    {
        hv_cpu_reset(&cpu, &m);
        cpu.tcr_el1 = 0;
        cpu.ttbr0_el1 = 7ull << 48;
        hv_ijc_switch(&cpu);
        uint64_t salt = cpu.ijc_salt[0];
        static const uint64_t vas[3] = {0x100004010ull, 0x100004ffcull, 0x100008010ull}; /* page P twice, then page Q */
        uint64_t *ents[3];
        static HvBlock fake[3];
        for (int i = 0; i < 3; i++) {
            fake[i] = (HvBlock){.va = vas[i], .flags = 0, .code = (uint32_t *)(uintptr_t)0x1234};
            hv_ijc_fill(&cpu, &fake[i]);
            ents[i] = m.percpu[0].ijc + (size_t)hv_ijc_index(vas[i] ^ salt) * 2;
        }
        hv_tlb_flush_va_asid(&cpu, 0x100004000ull, 7);
        int want[3] = {0, 0, 1};
        for (int i = 0; i < 3; i++) {
            checks++;
            if ((ents[i][0] != 0) != want[i]) {
                printf("  FAIL branch cache after TLBI of page P: entry %d %s\n", i, ents[i][0] ? "kept" : "dropped");
                failures++;
            }
        }
        /* Another address space's TLBI of page Q leaves this one's entry alone. */
        hv_tlb_flush_va_asid(&cpu, 0x100008000ull, 9);
        checks++;
        if (!ents[2][0]) {
            printf("  FAIL another ASID's TLBI dropped our entry\n");
            failures++;
        }
        hv_tlb_flush_va_asid(&cpu, 0x100008000ull, -1); /* all address spaces */
        checks++;
        uint64_t now = vas[2] ^ cpu.ijc_salt[0]; /* what a lookup would compare against now */
        if (m.percpu[0].ijc[(size_t)hv_ijc_index(now) * 2] == now) {
            printf("  FAIL an all-ASID TLBI kept the entry\n");
            failures++;
        }
    }

    /* Windows 11 ARM64 TCR.A1 == 1 process switch (ASID in TTBR1[63:48], TTBR0[63:48] == 0):
       KiSwapProcess switches TTBR1 -> (0, KPA_SYS), TTBR0 -> PA_B, TTBR1 -> (ASID_B, KPA_B).
       Verify:
       1. Switching back to (ASID_A, PA_A) restores Process A's stashed user TLB entry.
       2. Reusing freed PA_A for a new process ASID_C != ASID_A does NOT restore dead Process A's entry.
       3. Transient ASID 0 switches with no user IJC fills do not churn next_cid. */
    {
        hv_cpu_reset(&cpu, &m);
        cpu.el = 1;
        cpu.tcr_el1 = (1ull << 22) | (1ull << 36); /* A1 = 1, AS = 1 (16-bit ASID in TTBR1) */
        cpu.ttbr0_el1 = 0x40010000ull;             /* PA_A */
        cpu.ttbr1_el1 = (11ull << 48) | 0x40020000ull; /* ASID 11, KPA_A */
        hv_ijc_switch(&cpu);

        /* Simulate a user TLB fill in Process A (ASID 11, PA_A). */
        uint64_t uva = 0x7ff700001000ull;
        uint32_t sl = (uva >> HV_TLB_PAGE_BITS) & (HV_TLB_SIZE - 1);
        HvTlbEntry *ue = hv_tlb_ent(&cpu, sl, 0);
        ue->read_tag = uva - HV_TLB_ADJ;
        ue->addend = 0x1234000;
        cpu.user_fills[0] = (uint16_t)hv_tlb_code(sl, 0);
        cpu.nuser_fills = 1;

        uint32_t cid_before = cpu.next_cid;

        /* KiSwapProcess A -> B (ASID 22, PA_B = 0x40030000). */
        cpu.x[0] = 0x40000000ull; /* ASID 0, KPA_SYS */
        hv_sysreg_msr(&cpu, 0xd5182020u, 0); /* msr ttbr1_el1, x0 */
        cpu.x[0] = 0x40030000ull; /* PA_B */
        hv_sysreg_msr(&cpu, 0xd5182000u, 0); /* msr ttbr0_el1, x0 */
        cpu.x[0] = (22ull << 48) | 0x40040000ull; /* ASID 22, KPA_B */
        hv_sysreg_msr(&cpu, 0xd5182020u, 0); /* msr ttbr1_el1, x0 */

        checks++;
        if (hv_tlb_ent(&cpu, sl, 0)->read_tag != HV_TLB_INVALID) {
            printf("  FAIL TCR.A1 switch A->B kept Process A's user TLB entry\n");
            failures++;
        }

        /* Switch B -> A: Process A's user TLB entry should be restored from stash. */
        cpu.x[0] = 0x40000000ull;
        hv_sysreg_msr(&cpu, 0xd5182020u, 0);
        cpu.x[0] = 0x40010000ull; /* PA_A */
        hv_sysreg_msr(&cpu, 0xd5182000u, 0);
        cpu.x[0] = (11ull << 48) | 0x40020000ull; /* ASID 11, KPA_A */
        hv_sysreg_msr(&cpu, 0xd5182020u, 0);

        checks++;
        if (hv_tlb_ent(&cpu, sl, 0)->read_tag != uva - HV_TLB_ADJ) {
            printf("  FAIL TCR.A1 switch B->A did not restore Process A's user TLB entry\n");
            failures++;
        }

        /* Now Process A exits and PA_A (0x40010000) is reused by Process C (ASID 33) without TLBI ASIDE1:
           Process C must NOT inherit Process A's stashed user TLB entry! */
        cpu.x[0] = 0x40000000ull;
        hv_sysreg_msr(&cpu, 0xd5182020u, 0);
        cpu.x[0] = 0x40010000ull; /* same PA_A! */
        hv_sysreg_msr(&cpu, 0xd5182000u, 0);
        cpu.x[0] = (33ull << 48) | 0x40020000ull; /* new ASID 33, even same KPA_A! */
        hv_sysreg_msr(&cpu, 0xd5182020u, 0);

        checks++;
        if (hv_tlb_ent(&cpu, sl, 0)->read_tag != HV_TLB_INVALID) {
            printf("  FAIL TCR.A1 reused PA_A under new ASID 33 leaked dead Process A's user TLB entry\n");
            failures++;
        }

        /* Transient ASID 0 switches with no user IJC fills must allocate at most 1 ASID-0 cid. Four processes, each
           with its own ASID and table base (an ASID back with another base is another address space, HV_IJC_TTBKEY):
           once each has an id, switching among them through ASID 0 gives out no more. */
        uint32_t cid_mid = cpu.next_cid, cid_warm = 0;
        for (int iter = 0; iter < 104; iter++) {
            if (iter == 4) cid_warm = cpu.next_cid;
            cpu.x[0] = 0x40000000ull;
            hv_sysreg_msr(&cpu, 0xd5182020u, 0);
            cpu.x[0] = 0x40050000ull + ((uint64_t)(iter & 3) << 16);
            hv_sysreg_msr(&cpu, 0xd5182000u, 0);
            cpu.x[0] = ((22ull + (iter & 3)) << 48) | 0x40040000ull;
            hv_sysreg_msr(&cpu, 0xd5182020u, 0);
        }
        checks++;
        if (cpu.next_cid != cid_warm || cid_mid - cid_before > 4 || cid_warm - cid_mid > 5) {
            printf("  FAIL transient ASID 0 switches churned next_cid (%u -> %u -> %u -> %u)\n",
                   cid_before, cid_mid, cid_warm, cpu.next_cid);
            failures++;
        }
    }

    /* HV_IJC_TTBKEY: branch-cache ids keyed by ASID and TTBR0 base, with the ASID in TTBR0 (TCR.A1 0) and in TTBR1
       (TCR.A1 1, Windows' KiSwapProcess order: TTBR1 to ASID 0, TTBR0, TTBR1 to the new ASID). */
    for (int a1 = 0; a1 < 2; a1++) {
        hv_cpu_reset(&cpu, &m);
        cpu.el = 1;
        cpu.tcr_el1 = (uint64_t)a1 << 22 | 1ull << 36;
        const uint64_t base_a = 0x40100000ull, base_b = 0x40200000ull, base_c = 0x40300000ull, kpa = 0x40400000ull;
        /* Switch to (asid, base) as the guest would. */
        #define SWITCH_TO(asid, base) do { \
            if (a1) { cpu.x[0] = kpa; hv_sysreg_msr(&cpu, 0xd5182020u, 0); cpu.x[0] = (base); hv_sysreg_msr(&cpu, 0xd5182000u, 0); \
                      cpu.x[0] = (uint64_t)(asid) << 48 | kpa; hv_sysreg_msr(&cpu, 0xd5182020u, 0); } \
            else { cpu.x[0] = (uint64_t)(asid) << 48 | (base); hv_sysreg_msr(&cpu, 0xd5182000u, 0); } } while (0)
        SWITCH_TO(9, base_a);
        uint64_t salt_a = cpu.ijc_salt[0];
        static HvBlock blk;
        blk = (HvBlock){.va = 0x7ff600001230ull, .flags = 0, .code = (uint32_t *)(uintptr_t)0x5678};
        hv_ijc_fill(&cpu, &blk);
        SWITCH_TO(10, base_b);
        uint64_t salt_b = cpu.ijc_salt[0];
        SWITCH_TO(9, base_a);
        checks++;
        if (cpu.ijc_salt[0] != salt_a || salt_b == salt_a) {
            printf("  FAIL A1=%d: a process switched back to (same ASID, same base) lost its branch-cache id\n", a1);
            failures++;
        }
        /* ASID 9 now names another address space (base C) without a TLBI by ASID first. */
        SWITCH_TO(9, base_c);
        uint64_t tag = blk.va ^ cpu.ijc_salt[0];
        uint64_t *ent = m.percpu[0].ijc + (size_t)hv_ijc_index(tag) * 2;
        int hit = ent[0] == tag || ent[2] == tag;
        checks++;
        if (hv_knob[HV_K_IJCTTBKEY] ? (hit || cpu.ijc_salt[0] == salt_a) : cpu.ijc_salt[0] != salt_a) {
            printf("  FAIL A1=%d HV_IJC_TTBKEY=%d: ASID 9 with a new table base %s the old process's cached target\n", a1,
                   hv_knob[HV_K_IJCTTBKEY], hit ? "finds" : "does not find");
            failures++;
        }
        /* And the ASID with its own base again keeps the id it has now. */
        uint64_t salt_c = cpu.ijc_salt[0];
        SWITCH_TO(10, base_b);
        SWITCH_TO(9, base_c);
        checks++;
        if (cpu.ijc_salt[0] != salt_c) {
            printf("  FAIL A1=%d: switching back to (ASID 9, base C) gave a new id\n", a1);
            failures++;
        }
        #undef SWITCH_TO
    }

    test_logged_flush(&m, &cpu);
    test_code_page_drops(&m, &cpu, &cpu1);

    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
