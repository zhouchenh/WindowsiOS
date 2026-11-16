#include "harness.h"

#include <mach/mach_time.h>
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>

DECLARE_PROGRAM(p_svc);
DECLARE_PROGRAM(p_brk_undef);
DECLARE_PROGRAM(p_dabt);
DECLARE_PROGRAM(p_el0);
DECLARE_PROGRAM(p_sysregs);
DECLARE_PROGRAM(p_irq);
DECLARE_PROGRAM(p_fptrap);
DECLARE_PROGRAM(p_psci);
DECLARE_PROGRAM(p_smc);
DECLARE_PROGRAM(p_smc_nomaint);
extern const char exc_programs_begin[], exc_programs_finish[];

#define ACK_PA 0x20000000ull

static HvMachine m;
static uint8_t *stack;
static int failures, checks;

static void ack_write(void *opaque, uint64_t off, uint64_t val, unsigned size) {
    (void)off, (void)val, (void)size;
    ((HvMachine *)opaque)->percpu[0].irq_line = 0;
}

static void check(const char *prog, const char *what, uint64_t got, uint64_t want) {
    checks++;
    if (got != want) {
        printf("  %s: %s = %llx, expected %llx\n", prog, what, (unsigned long long)got, (unsigned long long)want);
        failures++;
    }
}

static int run(const TestProgram *p, HvCpu *cpu, uint64_t x9) {
    static HvCpu init;
    memset(&init, 0, sizeof init);
    seed_cpu(&init, 5, (uint64_t)(uintptr_t)stack + 32768);
    init.x[9] = x9;
    init.x[19] = ACK_PA;
    int before = failures;
    if (run_jit(&m, p, &init, cpu, NULL)) failures++;
    return failures != before;
}

#define ADDR(sym) ((uint64_t)(uintptr_t)(sym))

/* HV_SYNC_WAIT: a thread waiting for a CPU's acknowledgement (hv_cpu_sync) sleeps until the CPU acknowledges while
   running, or parks (park(): the host pausing the machine, CPU_OFF, WFI, the flush barrier and leaving the dispatcher
   all go through it). The CPU, on its own thread, is in the machine's tick with its TLB live while the request comes
   in (kicked, at the stop PC); then (mode 0) it leaves the dispatcher without doing the request, parking, or (mode 1)
   does the request from the tick and stays live a while longer. The sleep's timeout is made 2 s, so a wake that never
   comes shows (any later acknowledgement or park would also end the wait: none comes before the CPU stops). */
static HvMachine sm;
static HvCpu scpu;
static int s_in_tick, s_mode;

static uint64_t s_tick(HvMachine *mm, HvCpu *cpu) {
    (void)mm;
    if (!__atomic_load_n(&s_in_tick, __ATOMIC_ACQUIRE)) {
        __atomic_store_n(&s_in_tick, 1, __ATOMIC_RELEASE);
        usleep(50000);
        if (s_mode == 1) {
            hv_cpu_process_requests(cpu);
            usleep(600000);
        }
        cpu->x[0] = 7;
    }
    return 0;
}

static void *s_run(void *arg) {
    (void)arg;
    return (void *)(intptr_t)hv_run(&scpu);
}

static void test_sync_wait(void) {
    if (hv_machine_init(&sm, 1 << 20) != 0) return;
    uint32_t *code = aligned_alloc(16384, 16384);
    code[0] = 0xd503201f;             /* (the stop) */
    hv_machine_add_ram(&sm, ADDR(code), 16384, code, 1);
    sm.tick = s_tick;
    uint32_t saved_us = hv_sync_wait_us;
    hv_sync_wait_us = 2000000;
    for (int mode = 0; mode < 2; mode++) {
        hv_cpu_reset(&scpu, &sm);
        scpu.pc = ADDR(code);
        sm.stop_pc = ADDR(code);
        scpu.exit_req = 1; /* kicked: the dispatcher ticks before it looks at the PC */
        __atomic_store_n(&s_in_tick, 0, __ATOMIC_RELEASE);
        s_mode = mode;
        pthread_attr_t at;
        pthread_attr_init(&at);
        pthread_attr_setstacksize(&at, 16u << 20);
        pthread_t th;
        pthread_create(&th, &at, s_run, NULL);
        while (!__atomic_load_n(&s_in_tick, __ATOMIC_ACQUIRE)) usleep(100);
        uint64_t seq = hv_cpu_post(&scpu, 0);
        uint64_t t0 = mach_absolute_time();
        hv_cpu_sync(NULL, &scpu, seq);
        double ms = (mach_absolute_time() - t0) / 24000.0;
        void *r;
        pthread_join(th, &r);
        const char *what = mode ? "acknowledged by a running CPU" : "the CPU parked";
        printf("sync wait (HV_SYNC_WAIT=%d), %s: %.1f ms\n", hv_knob[HV_K_SYNCWAIT], what, ms);
        check("sync wait", what, ms > 20 && ms < 400, 1);
        check("sync wait", "the CPU ran on", (intptr_t)r == HV_EXIT_HALT && scpu.x[0] == 7, 1);
    }
    hv_sync_wait_us = saved_us;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    hv_machine_init(&m, 4 << 20);
    printf("knobs:");
    for (int k = HV_K_FASTICACHE; k < HV_K_COUNT; k++) printf(" %s=%d", hv_knob_name(k), hv_knob[k]);
    printf("\n");
    stack = aligned_alloc(16384, 65536);
    hv_machine_add_ram(&m, ADDR(exc_programs_begin), exc_programs_finish - exc_programs_begin,
                       (void *)exc_programs_begin, 1);
    hv_machine_add_ram(&m, ADDR(stack), 65536, stack, 0);
    hv_machine_add_mmio(&m, ACK_PA, 0x1000, &m, NULL, ack_write, "irq ack");
    m.trace = getenv("HV_TRACE") != NULL;
    static HvCpu c;

    static const TestProgram svc = TEST_PROGRAM(p_svc);
    if (!run(&svc, &c, 0)) {
        check("svc", "ESR", c.x[1], 0x56000042);
        check("svc", "ELR", c.x[2], c.x[6]);
        check("svc", "SPSR", c.x[3], 0x800003c5);
        check("svc", "NZCV after ERET", c.x[4], 0x80000000);
        check("svc", "vector", c.x[7], 0x200);
        check("svc", "count", c.x[24], 1);
    }

    static const TestProgram bu = TEST_PROGRAM(p_brk_undef);
    if (!run(&bu, &c, 0)) {
        check("brk", "ESR", c.x[1], 0xf2000007);
        check("brk", "ELR", c.x[2], c.x[3]);
        check("udf", "ESR", c.x[4], 0x02000000);
        check("udf", "ELR", c.x[5], c.x[6]);
    }

    static const TestProgram da = TEST_PROGRAM(p_dabt);
    if (!run(&da, &c, 0)) {
        check("dabt", "load ESR", c.x[1], 0x96000010);
        check("dabt", "load FAR", c.x[2], 0x10000);
        check("dabt", "ELR", c.x[3], c.x[4]);
        check("dabt", "store ESR (WnR)", c.x[5], 0x96000050);
        check("dabt", "store FAR", c.x[6], 0x10010);
        check("dabt", "no writeback on a fault", c.x[10], 0x10000);
    }

    static const TestProgram el0 = TEST_PROGRAM(p_el0);
    uint64_t sp0 = ADDR(stack) + 8192;
    uint64_t sp1 = ADDR(stack) + 32768;
    if (!run(&el0, &c, sp0)) {
        check("el0", "SP at EL0", c.x[10], sp0);
        check("el0", "SVC vector (lower EL)", c.x[13], 0x400);
        check("el0", "MRS SCTLR_EL1 at EL0: ESR", c.x[14], 0x02000000);
        check("el0", "MRS SCTLR_EL1 at EL0: vector", c.x[15], 0x400);
        check("el0", "TPIDR_EL0 write/read", c.x[18], 0x55);
        check("el0", "still at EL0", c.el, 0);
        check("el0", "SP_EL1 banked", c.sp_el1, sp1);
        check("el0", "exceptions", c.x[24], 2);
    }

    static const TestProgram sr = TEST_PROGRAM(p_sysregs);
    static HvCpu seeded;
    seed_cpu(&seeded, 5, 0);
    if (!run(&sr, &c, 0)) {
        check("sysregs", "TPIDR_EL1", c.x[2], seeded.x[1]);
        check("sysregs", "CurrentEL", c.x[3], 4);
        check("sysregs", "DAIF after set", c.x[4], 0x3c0);
        check("sysregs", "DAIF after clr", c.x[5], 0x300);
        check("sysregs", "NZCV", c.x[7], 0x60000000);
        check("sysregs", "CNTVCT advances", c.x[9] > c.x[8], 1);
        check("sysregs", "CNTFRQ", c.x[10], 24000000);
        check("sysregs", "4K granule advertised", (c.x[11] >> 28) & 0xf, 0);
        check("sysregs", "16K granule advertised", (c.x[11] >> 20) & 0xf, 1);
        check("sysregs", "SP_EL0 via SPSel", c.x[12], 0);
        check("sysregs", "SP_EL1 via SPSel", c.x[13], sp1);
        check("sysregs", "MIDR implementer", c.x[14] >> 24, 0x41);
        check("sysregs", "FPCR", c.x[17], 1u << 24);
        check("sysregs", "VBAR", c.x[18], c.vbar_el1);
        check("sysregs", "CNTV_CVAL", c.x[21], 0x123);
        check("sysregs", "CNTV_CTL ISTATUS", c.x[23], 5);
    }
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    check("host", "mach_absolute_time is 24 MHz (timebase 125/3)", (uint64_t)tb.numer * 1000 + tb.denom, 125003);

    static const TestProgram irq = TEST_PROGRAM(p_irq);
    m.percpu[0].irq_line = 1;
    if (!run(&irq, &c, 0)) {
        check("irq", "masked IRQ not taken across WFI", c.x[1], 0);
        check("irq", "taken after DAIFClr", c.x[2], 1);
        check("irq", "vector", c.x[3], 0x280);
        check("irq", "ELR = next instruction", c.x[4], c.x[5]);
        check("irq", "line acknowledged", m.percpu[0].irq_line, 0);
    }
    m.percpu[0].irq_line = 0;

    static const TestProgram fp = TEST_PROGRAM(p_fptrap);
    if (!run(&fp, &c, 0)) {
        check("fptrap", "ESR", c.x[1], 0x1fe00000);
        check("fptrap", "one trap", c.x[2], 1);
        double d1, d2, d0;
        memcpy(&d1, &seeded.v[1], 8);
        memcpy(&d2, &seeded.v[2], 8);
        d0 = d1 + d2;
        uint64_t want;
        memcpy(&want, &d0, 8);
        check("fptrap", "FADD retried", c.x[3], want);
    }

    static const TestProgram ps = TEST_PROGRAM(p_psci);
    if (!run(&ps, &c, 0)) {
        check("psci", "PSCI_VERSION", c.x[3], 0x10000);
        check("psci", "PSCI_FEATURES(CPU_ON)", c.x[2], 0);
    }

    /* Self-modifying code runs from a writable copy. */
    const TestProgram *smc_progs[2];
    static const TestProgram smc1 = TEST_PROGRAM(p_smc), smc2 = TEST_PROGRAM(p_smc_nomaint);
    smc_progs[0] = &smc1;
    smc_progs[1] = &smc2;
    uint8_t *code = aligned_alloc(16384, 16384);
    hv_machine_add_ram(&m, ADDR(code), 16384, code, 0);
    for (int i = 0; i < 2; i++) {
        const TestProgram *p = smc_progs[i];
        size_t len = (const char *)p->end - (const char *)p->start + 4;
        memcpy(code, p->start, len);
        TestProgram copy = {p->name, NULL, code, code + ((const char *)p->end - (const char *)p->start)};
        if (!run(&copy, &c, 0)) check(p->name, "1 then 2 after patching", c.x[1], 3);
    }

    /* Code that other pages' exits are chained into changes (HV_XCHAIN_PAGES lists those exits per page): every such
       exit must go back to its stub, or it keeps jumping into the old translation. 4 KB pages of a writable copy:
       page 0 and page 2 branch into page 1, which sets x0 and goes on to page 3 (the stop). At a guest PA other than
       the host address: an exit to another page is chained only where the page's host addend is not 0. */
    {
        uint32_t *xc = aligned_alloc(16384, 16384);
        const uint64_t XPA = 0x50000000ull;
        hv_machine_add_ram(&m, XPA, 16384, xc, 0);
        const uint32_t P = 1024; /* words per 4 KB page */
        #define MOVZ(rd, imm) (0xd2800000u | (uint32_t)(imm) << 5 | (rd))
        #define B_TO(from, to) (0x14000000u | ((uint32_t)((int32_t)(to) - (int32_t)(from)) & 0x3ffffff))
        memset(xc, 0, 16384);
        xc[0] = MOVZ(0, 0), xc[1] = B_TO(1, P);                  /* page 0 -> page 1 */
        xc[2 * P] = MOVZ(1, 5), xc[2 * P + 1] = B_TO(2 * P + 1, P); /* page 2 -> page 1 */
        xc[P] = MOVZ(0, 1), xc[P + 1] = B_TO(P + 1, 3 * P);       /* page 1: x0 = n, -> page 3 */
        const uint32_t *g = (const uint32_t *)(uintptr_t)XPA; /* guest addresses (the MMU is off) */
        TestProgram from0 = {"xchain0", NULL, g, g + 3 * P}, from2 = {"xchain2", NULL, g + 2 * P, g + 3 * P};
        uint64_t chained_before = m.stats.chained;
        /* One CPU throughout (no reset between runs): an exit to another page is chained once that page is in the
           TLB, from the second run on. */
        if (run(&from0, &c, 0)) failures++;
        for (uint32_t n = 1; n <= 4; n++) {
            if (n == 3) hv_flush_blocks(&m); /* every chain and list starts over, slots from 0 again */
            if (n > 1) {
                uint32_t insn = MOVZ(0, n);
                hv_phys_write(&m, XPA + 4 * P, &insn, 4); /* as a device or another CPU would: page 1 is code */
            }
            for (int round = 0; round < 2; round++) /* the second round runs through the chains the first made */
                for (int from = 0; from < 2; from++) {
                    const TestProgram *p = from ? &from2 : &from0;
                    c.x[0] = 0;
                    c.pc = (uint64_t)(uintptr_t)p->start;
                    m.stop_pc = (uint64_t)(uintptr_t)p->end;
                    int r = hv_run(&c);
                    check("xchain", from ? "page 2 into page 1" : "page 0 into page 1", r == HV_EXIT_HALT ? c.x[0] : ~0ull, n);
                }
        }
        check("xchain", "cross-page exits chained (and chained again after each change)", m.stats.chained - chained_before, 8);
        #undef MOVZ
        #undef B_TO
    }

    test_sync_wait();

    printf("%d checks, %d failures\n", checks, failures);
    return failures != 0;
}
