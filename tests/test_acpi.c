// SPDX-License-Identifier: GPL-2.0-or-later
/* The DSDT that devices/acpi.c builds, with and without the battery (BAT0, ADP0), and the battery's
   registers (devices/acpi_battery.c). No machine: the fw_cfg files are captured (fw_cfg_capture_stub.c).
     - Without the battery the DSDT is byte for byte what it was before the battery existed.
     - Every object in \_SB (and in each Device) is walked by its encoded length and must tile its scope
       exactly; every Package and Buffer must hold exactly the elements it declares. A wrong PkgLength
       would make Windows stop with ACPI_BIOS_ERROR.
     - The battery's AML is the expected bytes, and the GED's _EVT, run by a small interpreter, notifies
       PWRB on event bit 1 and BAT0 + ADP0 on bit 2, also when both arrive together (0x6).
     - The register mapping from the iOS battery level and state.
   With iasl installed (brew install acpica), the DSDT is also disassembled. */
#include "acpi.h"
#include "acpi_battery.h"
#include "fw_cfg_capture_stub.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures;

#define CHECK(c)                                                                                                                  \
    do {                                                                                                                          \
        if (!(c)) {                                                                                                               \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);                                                          \
            failures++;                                                                                                           \
        }                                                                                                                         \
    } while (0)

/* The DSDT (a copy) for this many CPUs, with or without the battery. */
static uint8_t *build(int ncpus, int battery, uint32_t *len) {
    HvFwCfg fw;
    memset(&fw, 0, sizeof fw);
    fw_capture_reset();
    hv_acpi_build_and_register(&fw, ncpus, 4096ull << 20, 0, 0, battery);
    uint32_t tlen = 0;
    const uint8_t *t = fw_capture_get("etc/acpi/tables", &tlen);
    if (!t || tlen < 36 || memcmp(t, "DSDT", 4) != 0) return NULL;
    uint32_t dl;
    memcpy(&dl, t + 4, 4);
    if (dl > tlen) return NULL;
    uint8_t *d = malloc(dl);
    memcpy(d, t, dl);
    *len = dl;
    return d;
}

static uint64_t fnv1a(const uint8_t *p, size_t n) {
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 1099511628211ull;
    }
    return h;
}

static int has(const uint8_t *p, size_t n, const void *needle, size_t m) {
    return memmem(p, n, needle, m) != NULL;
}

/* ---- AML walker ---- */

/* PkgLength at p: the encoded length (it counts its own bytes); *nb = how many bytes it takes. */
static size_t pkglen(const uint8_t *p, const uint8_t *end, size_t *nb) {
    if (p >= end) return 0;
    unsigned extra = p[0] >> 6;
    if (p + 1 + extra > end) return 0;
    *nb = 1 + extra;
    if (!extra) return p[0] & 0x3f;
    size_t v = p[0] & 0x0f;
    for (unsigned i = 0; i < extra; i++) v |= (size_t)p[1 + i] << (4 + 8 * i);
    return v;
}

typedef struct {
    char path[16]; /* e.g. "GED_._EVT" */
    const uint8_t *body, *end;
    uint8_t flags;
} Method;

static struct {
    char devices[64][5];
    int ndevices;
    Method methods[32];
    int nmethods;
} seen;

static int is_lead(uint8_t c) { return (c >= 'A' && c <= 'Z') || c == '_'; }

/* One data object or NameString (in a Package); returns its end or NULL. */
static const uint8_t *data_obj(const uint8_t *p, const uint8_t *end);

static const uint8_t *package(const uint8_t *p, const uint8_t *end, int var) {
    size_t nb, l = pkglen(p + 1, end, &nb);
    const uint8_t *pend = p + 1 + l;
    if (!l || pend > end) return NULL;
    const uint8_t *q = p + 1 + nb;
    uint64_t count;
    if (var) {
        if (q[0] == 0x0a) count = q[1], q += 2;
        else if (q[0] == 0x0b) count = (uint64_t)q[1] | ((uint64_t)q[2] << 8), q += 3;
        else return NULL;
    } else {
        count = *q++;
    }
    for (uint64_t i = 0; i < count; i++) {
        if (q >= pend) return NULL;
        q = data_obj(q, pend);
        if (!q) return NULL;
    }
    return q == pend ? pend : NULL;
}

static const uint8_t *data_obj(const uint8_t *p, const uint8_t *end) {
    if (p >= end) return NULL;
    switch (p[0]) {
    case 0x00: case 0x01: case 0xff: return p + 1;
    case 0x0a: return p + 2 <= end ? p + 2 : NULL;
    case 0x0b: return p + 3 <= end ? p + 3 : NULL;
    case 0x0c: return p + 5 <= end ? p + 5 : NULL;
    case 0x0e: return p + 9 <= end ? p + 9 : NULL;
    case 0x0d: {
        const uint8_t *z = memchr(p + 1, 0, (size_t)(end - p - 1));
        return z ? z + 1 : NULL;
    }
    case 0x11: { /* Buffer: size, then exactly that many bytes */
        size_t nb, l = pkglen(p + 1, end, &nb);
        const uint8_t *bend = p + 1 + l;
        if (!l || bend > end) return NULL;
        const uint8_t *q = p + 1 + nb;
        uint64_t size;
        if (q[0] == 0x0a) size = q[1], q += 2;
        else if (q[0] == 0x0b) size = (uint64_t)q[1] | ((uint64_t)q[2] << 8), q += 3;
        else return NULL;
        return q + size == bend ? bend : NULL;
    }
    case 0x12: return package(p, end, 0);
    case 0x13: return package(p, end, 1);
    case '\\': return p + 5 <= end && is_lead(p[1]) ? p + 5 : NULL;
    default: return is_lead(p[0]) && p + 4 <= end ? p + 4 : NULL;
    }
}

/* The objects of a scope or Device body, which must end exactly at end. */
static int walk(const uint8_t *p, const uint8_t *end, const char *dev) {
    while (p < end) {
        if (p[0] == 0x5b && p + 1 < end && p[1] == 0x82) { /* Device */
            size_t nb, l = pkglen(p + 2, end, &nb);
            const uint8_t *dend = p + 2 + l;
            if (!l || dend > end) return 0;
            const uint8_t *name = p + 2 + nb;
            if (seen.ndevices < 64) memcpy(seen.devices[seen.ndevices++], name, 4);
            char nm[5] = {0};
            memcpy(nm, name, 4);
            if (!walk(name + 4, dend, nm)) {
                fprintf(stderr, "  in Device %s\n", nm);
                return 0;
            }
            p = dend;
        } else if (p[0] == 0x5b && p + 1 < end && p[1] == 0x80) { /* OperationRegion name, space, offset, length */
            const uint8_t *q = p + 2 + 4 + 1;
            q = data_obj(q, end);
            if (!q) return 0;
            q = data_obj(q, end);
            if (!q) return 0;
            p = q;
        } else if (p[0] == 0x5b && p + 1 < end && p[1] == 0x81) { /* Field */
            size_t nb, l = pkglen(p + 2, end, &nb);
            if (!l || p + 2 + l > end) return 0;
            /* name, flags, then (NameSeg, bit length) pairs */
            const uint8_t *q = p + 2 + nb + 4 + 1, *fend = p + 2 + l;
            while (q < fend) {
                if (!is_lead(q[0]) || q + 5 > fend || (q[4] & 0xc0)) return 0;
                q += 5;
            }
            if (q != fend) return 0;
            p = fend;
        } else if (p[0] == 0x08) { /* Name */
            if (p + 5 > end || !is_lead(p[1])) return 0;
            const uint8_t *q = data_obj(p + 5, end);
            if (!q || p[5] == '\\' || is_lead(p[5])) return 0;
            p = q;
        } else if (p[0] == 0x14) { /* Method */
            size_t nb, l = pkglen(p + 1, end, &nb);
            const uint8_t *mend = p + 1 + l;
            if (!l || mend > end || p + 1 + nb + 5 > mend) return 0;
            if (seen.nmethods < 32) {
                Method *m = &seen.methods[seen.nmethods++];
                snprintf(m->path, sizeof m->path, "%s.%.4s", dev, (const char *)(p + 1 + nb));
                m->flags = p[1 + nb + 4];
                m->body = p + 1 + nb + 5;
                m->end = mend;
            }
            p = mend;
        } else {
            fprintf(stderr, "  unknown opcode 0x%02x\n", p[0]);
            return 0;
        }
    }
    return p == end;
}

/* The whole DSDT: header, then exactly one Scope (\_SB_) that ends where the table ends. */
static int walk_dsdt(const uint8_t *d, uint32_t len) {
    memset(&seen, 0, sizeof seen);
    const uint8_t *p = d + 36, *end = d + len;
    if (p[0] != 0x10) return 0;
    size_t nb, l = pkglen(p + 1, end, &nb);
    if (p + 1 + l != end) return 0;
    if (memcmp(p + 1 + nb, "\\_SB_", 5) != 0) return 0;
    return walk(p + 1 + nb + 5, end, "_SB_");
}

static const Method *method(const char *path) {
    for (int i = 0; i < seen.nmethods; i++)
        if (!strcmp(seen.methods[i].path, path)) return &seen.methods[i];
    return NULL;
}

static int device_seen(const char *name) {
    for (int i = 0; i < seen.ndevices; i++)
        if (!memcmp(seen.devices[i], name, 4)) return 1;
    return 0;
}

/* ---- _EVT interpreter: Store (ESEL, Local0), If (LEqual (And (Local0, c, Zero), c)) { Notify (X, c) } ---- */

static struct {
    uint64_t esel, local0;
    char notified[8][5];
    int n;
    int bad;
} vm;

static const uint8_t *expr(const uint8_t *p, const uint8_t *end, uint64_t *v) {
    if (p >= end) { vm.bad = 1; return end; }
    switch (p[0]) {
    case 0x00: *v = 0; return p + 1;
    case 0x01: *v = 1; return p + 1;
    case 0x0a: *v = p[1]; return p + 2;
    case 0x60: *v = vm.local0; return p + 1;
    case 0x93: { /* LEqual */
        uint64_t a, b;
        p = expr(p + 1, end, &a);
        p = expr(p, end, &b);
        *v = a == b;
        return p;
    }
    case 0x7b: { /* And (a, b, target): only no target */
        uint64_t a, b;
        p = expr(p + 1, end, &a);
        p = expr(p, end, &b);
        if (p >= end || p[0] != 0x00) vm.bad = 1;
        *v = a & b;
        return p + 1;
    }
    default:
        vm.bad = 1;
        return end;
    }
}

static void run(const uint8_t *p, const uint8_t *end) {
    while (p < end && !vm.bad) {
        if (p[0] == 0x70 && p + 6 <= end && !memcmp(p + 1, "ESEL", 4) && p[5] == 0x60) {
            vm.local0 = vm.esel;
            p += 6;
        } else if (p[0] == 0xa0) {
            size_t nb, l = pkglen(p + 1, end, &nb);
            const uint8_t *iend = p + 1 + l;
            if (!l || iend > end) { vm.bad = 1; return; }
            uint64_t pred;
            const uint8_t *body = expr(p + 1 + nb, iend, &pred);
            if (pred) run(body, iend);
            p = iend;
        } else if (p[0] == 0x86 && p + 7 <= end && is_lead(p[1]) && p[5] == 0x0a) {
            if (vm.n < 8) memcpy(vm.notified[vm.n++], p + 1, 4);
            p += 7;
        } else {
            vm.bad = 1;
        }
    }
}

/* The devices _EVT notifies for these event bits, joined ("PWRB,BAT0,ADP0"). */
static const char *evt(const Method *m, uint32_t esel) {
    static char out[64];
    memset(&vm, 0, sizeof vm);
    vm.esel = esel;
    run(m->body, m->end);
    if (vm.bad) return "error";
    out[0] = 0;
    for (int i = 0; i < vm.n; i++) {
        if (i) strcat(out, ",");
        strncat(out, vm.notified[i], 4);
    }
    return out;
}

/* ---- tests ---- */

static void test_without_battery(void) {
    /* The DSDT before the battery existed (4 CPUs, as the app runs): length and FNV-1a of its bytes.
       Update these only for a deliberate change of the battery-less DSDT. */
    uint32_t len = 0;
    uint8_t *d = build(4, 0, &len);
    CHECK(d != NULL);
    if (!d) return;
    CHECK(len == 3026);
    CHECK(fnv1a(d, len) == 0x5961271faaf3d26dull);
    CHECK(!has(d, len, "BAT0", 4));
    CHECK(!has(d, len, "ADP0", 4));
    CHECK(!has(d, len, "BREG", 4));
    CHECK(!has(d, len, "ACPI0003", 8));
    CHECK(walk_dsdt(d, len));
    const Method *e = method("GED_._EVT");
    CHECK(e != NULL);
    if (e) {
        CHECK(!strcmp(evt(e, 0x2), "PWRB"));
        CHECK(!strcmp(evt(e, 0x6), "PWRB"));
        CHECK(!strcmp(evt(e, 0x4), ""));
    }
    free(d);
}

static void test_with_battery(void) {
    for (int ncpus = 1; ncpus <= 8; ncpus++) {
        uint32_t len = 0, len0 = 0;
        uint8_t *d = build(ncpus, 1, &len);
        uint8_t *d0 = build(ncpus, 0, &len0);
        CHECK(d != NULL && d0 != NULL);
        if (!d || !d0) return;
        CHECK(walk_dsdt(d0, len0));
        CHECK(walk_dsdt(d, len));
        CHECK(device_seen("BAT0") && device_seen("ADP0") && device_seen("PWRB") && device_seen("GED_"));
        CHECK(len > len0);
        free(d0);
        free(d);
    }

    uint32_t len = 0;
    uint8_t *d = build(4, 1, &len);
    CHECK(d != NULL);
    if (!d) return;
    CHECK(walk_dsdt(d, len));
    CHECK(has(d, len, "PNP0C0A", 8));
    CHECK(has(d, len, "ACPI0003", 9));
    static const uint8_t opreg[] = {0x5b, 0x80, 'B', 'R', 'E', 'G', 0x00, 0x0c, 0x00, 0x01, 0x08, 0x09, 0x0a, 0x10};
    static const uint8_t field[] = {0x5b, 0x81, 0x1a, 'B', 'R', 'E', 'G', 0x03, 'B', 'S', 'T', 'A', 0x20,
                                    'B', 'R', 'A', 'T', 0x20, 'B', 'C', 'A', 'P', 0x20, 'B', 'P', 'S', 'R', 0x20};
    static const uint8_t bstp[] = {0x08, 'B', 'S', 'T', 'P', 0x12, 0x0e, 0x04, 0x00, 0x0c, 0xff, 0xff, 0xff, 0xff,
                                   0x0b, 0x10, 0x27, 0x0b, 0x0a, 0x0f};
    static const uint8_t bst[] = {0x14, 0x30, '_', 'B', 'S', 'T', 0x08,
                                  0x70, 'B', 'S', 'T', 'A', 0x88, 'B', 'S', 'T', 'P', 0x00, 0x00,
                                  0x70, 'B', 'R', 'A', 'T', 0x88, 'B', 'S', 'T', 'P', 0x01, 0x00,
                                  0x70, 'B', 'C', 'A', 'P', 0x88, 'B', 'S', 'T', 'P', 0x0a, 0x02, 0x00,
                                  0xa4, 'B', 'S', 'T', 'P'};
    static const uint8_t psr[] = {0x14, 0x0b, '_', 'P', 'S', 'R', 0x00, 0xa4, 'B', 'P', 'S', 'R'};
    static const uint8_t pcl[] = {0x08, '_', 'P', 'C', 'L', 0x12, 0x07, 0x01, '\\', '_', 'S', 'B', '_'};
    static const uint8_t sta[] = {0x08, '_', 'S', 'T', 'A', 0x0a, 0x1f};
    CHECK(has(d, len, opreg, sizeof opreg));
    CHECK(has(d, len, field, sizeof field));
    CHECK(has(d, len, bstp, sizeof bstp));
    CHECK(has(d, len, bst, sizeof bst));
    CHECK(has(d, len, psr, sizeof psr));
    CHECK(has(d, len, pcl, sizeof pcl));
    CHECK(has(d, len, sta, sizeof sta));

    /* _BIF: 13 elements, warning and low capacity 0 */
    static const uint8_t bif_head[] = {0x08, '_', 'B', 'I', 'F', 0x12};
    const uint8_t *b = memmem(d, len, bif_head, sizeof bif_head);
    CHECK(b != NULL);
    if (b) {
        const uint8_t *q = b + 5;
        CHECK(data_obj(q, d + len) != NULL);
        size_t nb;
        pkglen(q + 1, d + len, &nb);
        q += 1 + nb;
        CHECK(*q == 13);
        static const uint8_t ints[] = {0x00, 0x0b, 0x10, 0x27, 0x0b, 0x10, 0x27, 0x01, 0x0b, 0x0a, 0x0f, 0x00, 0x00, 0x0a, 0x64, 0x0a, 0x64};
        CHECK(!memcmp(q + 1, ints, sizeof ints));
    }

    CHECK(method("BAT0._BST") && method("BAT0._BST")->flags == 0x08);
    CHECK(method("ADP0._PSR") && method("ADP0._PSR")->flags == 0x00);
    const Method *e = method("GED_._EVT");
    CHECK(e && e->flags == 0x09);
    if (e) {
        CHECK(!strcmp(evt(e, 0x0), ""));
        CHECK(!strcmp(evt(e, 0x2), "PWRB"));
        CHECK(!strcmp(evt(e, 0x4), "BAT0,ADP0"));
        CHECK(!strcmp(evt(e, 0x6), "PWRB,BAT0,ADP0"));
        CHECK(!strcmp(evt(e, 0x1), ""));
    }

    /* The checksum the firmware's loader writes makes the table sum to zero. */
    uint8_t sum = 0;
    for (uint32_t i = 0; i < len; i++) sum = (uint8_t)(sum + d[i]);
    d[9] = (uint8_t)(d[9] - sum);
    sum = 0;
    for (uint32_t i = 0; i < len; i++) sum = (uint8_t)(sum + d[i]);
    CHECK(sum == 0);

    /* iasl, when installed: the disassembler must take the table without errors. */
    if (system("command -v iasl >/dev/null 2>&1") == 0) {
        char dir[] = "/tmp/hvacpi.XXXXXX";
        if (mkdtemp(dir)) {
            char path[64], cmd[256];
            snprintf(path, sizeof path, "%s/dsdt.aml", dir);
            FILE *f = fopen(path, "wb");
            if (f) {
                fwrite(d, 1, len, f);
                fclose(f);
                snprintf(cmd, sizeof cmd, "cd %s && iasl -d dsdt.aml >iasl.log 2>&1 && ! grep -q Error iasl.log", dir);
                int r = system(cmd);
                if (r != 0) {
                    snprintf(cmd, sizeof cmd, "cat %s/iasl.log >&2", dir);
                    (void)system(cmd);
                }
                CHECK(r == 0);
            }
            snprintf(cmd, sizeof cmd, "rm -rf %s", dir);
            (void)system(cmd);
        }
    } else {
        printf("  (iasl not installed: disassembly skipped)\n");
    }
    free(d);
}

static void test_registers(void) {
    HvBattery b;
    hv_battery_init(&b);
    CHECK(hv_battery_read(&b, 0x0) == 0);
    CHECK(hv_battery_read(&b, 0x4) == 0xFFFFFFFFu);
    CHECK(hv_battery_read(&b, 0x8) == 10000);
    CHECK(hv_battery_read(&b, 0xC) == 1);
    CHECK(hv_battery_read(&b, 0x10) == 0);
    CHECK(hv_battery_read(&b, 0x2) == 0);

    CHECK(hv_battery_set(&b, 0.42, HV_BATTERY_UNPLUGGED) == 1);
    CHECK(hv_battery_read(&b, 0x0) == 1); /* discharging */
    CHECK(hv_battery_read(&b, 0x8) == 4200);
    CHECK(hv_battery_read(&b, 0xC) == 0); /* on battery */
    CHECK(hv_battery_read(&b, 0x4) == 0xFFFFFFFFu);
    CHECK(hv_battery_set(&b, 0.42, HV_BATTERY_UNPLUGGED) == 0); /* the same again: no event */

    CHECK(hv_battery_set(&b, 0.8, HV_BATTERY_CHARGING) == 1);
    CHECK(hv_battery_read(&b, 0x0) == 2);
    CHECK(hv_battery_read(&b, 0x8) == 8000);
    CHECK(hv_battery_read(&b, 0xC) == 1);

    CHECK(hv_battery_set(&b, 0.8, HV_BATTERY_FULL) == 1); /* optimized charging: held below 100%, plugged */
    CHECK(hv_battery_read(&b, 0x0) == 0);
    CHECK(hv_battery_read(&b, 0x8) == 8000);
    CHECK(hv_battery_read(&b, 0xC) == 1);

    CHECK(hv_battery_set(&b, 1.0, HV_BATTERY_FULL) == 1);
    CHECK(hv_battery_read(&b, 0x8) == 10000);

    CHECK(hv_battery_set(&b, -1.0, HV_BATTERY_UNKNOWN) == 0); /* unknown reads as full on AC: unchanged */
    CHECK(hv_battery_read(&b, 0x0) == 0 && hv_battery_read(&b, 0x8) == 10000 && hv_battery_read(&b, 0xC) == 1);

    CHECK(hv_battery_set(&b, 0.0, HV_BATTERY_UNPLUGGED) == 1);
    CHECK(hv_battery_read(&b, 0x8) == 100); /* never an empty battery */
    CHECK(hv_battery_set(&b, 0.004, HV_BATTERY_UNPLUGGED) == 0);
    CHECK(hv_battery_set(&b, 1.5, HV_BATTERY_UNPLUGGED) == 1);
    CHECK(hv_battery_read(&b, 0x8) == 10000);
    CHECK(hv_battery_set(&b, 0.05, 7) == 1); /* a state iOS may add later: idle on AC */
    CHECK(hv_battery_read(&b, 0x0) == 0 && hv_battery_read(&b, 0xC) == 1 && hv_battery_read(&b, 0x8) == 500);
}

int main(void) {
    test_registers();
    test_without_battery();
    test_with_battery();
    fw_capture_reset();
    if (failures) {
        fprintf(stderr, "test_acpi: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_acpi: ok\n");
    return 0;
}
