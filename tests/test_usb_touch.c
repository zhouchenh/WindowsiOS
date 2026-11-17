// SPDX-License-Identifier: GPL-2.0-or-later
/* The USB touch screen on the xHCI's port 3 (devices/usb_touch.c, devices/xhci.c), with no VM: guest memory
   is an array here, the PCI side is stubbed, and the test drives the controller through its registers the
   way a driver does. Checks: the HID report descriptor (an item walker: balanced collections, ten Finger
   collections, report sizes per report ID), the report packing, the controller advertising three ports,
   each port enumerating with its own descriptors (ports 1 and 2 exactly as before), a report descriptor
   longer than 256 bytes sent whole, the HID descriptor's 16-bit length, feature reports, the touch queue
   (moves merged, downs and lifts never, room kept for lifts), delivery to the interrupt endpoint, the
   "in use" signal (only once the guest queues reads) and the queue being dropped on a controller reset. */
#include "usb_touch.h"
#include "xhci.h"

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

/* ---- stand-ins: guest memory and the PCI bus ---- */

#define RAM_PA 0x40000000ull
#define RAM_SIZE (1u << 20)
static _Alignas(4096) uint8_t ram[RAM_SIZE];
static int msix_count;

void *hv_phys_ptr(HvMachine *m, uint64_t pa, uint64_t len) {
    (void)m;
    if (pa < RAM_PA || pa + len > RAM_PA + RAM_SIZE) return NULL;
    return ram + (pa - RAM_PA);
}
int hv_phys_read(HvMachine *m, uint64_t pa, void *buf, unsigned len) {
    void *p = hv_phys_ptr(m, pa, len);
    if (!p) return -1;
    memcpy(buf, p, len);
    return 0;
}
int hv_phys_write(HvMachine *m, uint64_t pa, const void *buf, unsigned len) {
    void *p = hv_phys_ptr(m, pa, len);
    if (!p) return -1;
    memcpy(p, buf, len);
    return 0;
}
void hv_machine_wake(HvMachine *m) { (void)m; }
void hv_pci_init(HvPciDev *d, uint16_t vendor, uint16_t device, uint32_t class_rev, uint16_t sub_vendor, uint16_t sub_id) {
    (void)d, (void)vendor, (void)device, (void)class_rev, (void)sub_vendor, (void)sub_id;
}
void hv_pci_add_bar(HvPciDev *d, int bar, uint64_t size, int is64) { (void)d, (void)bar, (void)size, (void)is64; }
void hv_pci_add_pcie_cap(HvPciDev *d, uint8_t at) { (void)d, (void)at; }
void hv_pci_add_msix(HvPciDev *d, uint8_t at, int bar, uint32_t table_off, uint32_t pba_off, uint16_t nvec) {
    (void)d, (void)at, (void)bar, (void)table_off, (void)pba_off, (void)nvec;
}
int hv_pci_msix_enabled(const HvPciDev *d) { (void)d; return 1; }
void hv_pci_msix_notify(HvPciDev *d, uint16_t vec) { (void)d, (void)vec; msix_count++; }
void hv_pci_set_intx(HvPciDev *d, int level) { (void)d, (void)level; }
int hv_pcie_attach(HvPcie *p, HvPciDev *d) { (void)p, (void)d; return 3; }

static void *at(uint64_t pa) { return ram + (pa - RAM_PA); }
static void put32(uint64_t pa, uint32_t v) { memcpy(at(pa), &v, 4); }
static void put64(uint64_t pa, uint64_t v) { memcpy(at(pa), &v, 8); }
static uint32_t get32(uint64_t pa) { uint32_t v; memcpy(&v, at(pa), 4); return v; }

/* ---- 1. the report descriptor, walked item by item ---- */

static void test_report_descriptor(void) {
    const uint8_t *d = hv_usb_touch_report_desc;
    unsigned len = hv_usb_touch_report_desc_len;
    CHECK(len > 255); /* why the HID descriptor's length is 16-bit and EP0 replies go past 256 bytes */
    unsigned bits_in[4] = {0}, bits_feature[4] = {0};
    unsigned size = 0, count = 0, rid = 0, page = 0, last_usage = 0;
    int depth = 0, min_depth = 0, fingers = 0, confidence = 0, tlc = 0;
    for (unsigned i = 0; i < len;) {
        uint8_t b = d[i];
        CHECK(b != 0xfe); /* no long items */
        unsigned n = (b & 3) == 3 ? 4 : (b & 3);
        CHECK(i + 1 + n <= len);
        uint32_t v = 0;
        for (unsigned k = 0; k < n && i + 1 + k < len; k++) v |= (uint32_t)d[i + 1 + k] << (8 * k);
        unsigned type = (b >> 2) & 3, tag = b >> 4;
        if (type == 1) { /* global */
            if (tag == 0) page = v;
            else if (tag == 7) size = v;
            else if (tag == 9) count = v;
            else if (tag == 8) rid = v;
        } else if (type == 2 && tag == 0) { /* local: Usage */
            last_usage = v;
            if (page == 0x0d && v == 0x47) confidence++;
        } else if (type == 0) { /* main */
            if (tag == 0x8 && rid < 4) bits_in[rid] += size * count;
            else if (tag == 0xb && rid < 4) bits_feature[rid] += size * count;
            else if (tag == 0xa) {
                if (depth == 0) tlc++;
                if (page == 0x0d && last_usage == 0x22 && v == 2) fingers++;
                depth++;
            } else if (tag == 0xc) {
                depth--;
                if (depth < min_depth) min_depth = depth;
            }
        }
        i += 1 + n;
    }
    CHECK(depth == 0);
    CHECK(min_depth == 0);
    CHECK(tlc == 2);       /* Touch Screen, Device Configuration */
    CHECK(fingers == HV_TOUCH_MAX_CONTACTS);
    CHECK(confidence == HV_TOUCH_MAX_CONTACTS);
    CHECK(bits_in[1] == (HV_TOUCH_REPORT_LEN - 1) * 8); /* 63 bytes after the report ID */
    CHECK(bits_in[2] == 0 && bits_in[3] == 0);
    CHECK(bits_feature[2] == 8);  /* Contact Count Maximum */
    CHECK(bits_feature[3] == 16); /* Device Mode, Device Identifier */
    /* The config descriptor names that length (16-bit), a 64-byte endpoint, no remote wakeup. */
    const uint8_t *c = hv_usb_touch_config_desc;
    CHECK(c[2] == 34 && c[3] == 0);
    CHECK((c[7] & 0x20) == 0);
    CHECK(c[18 + 1] == 0x21 && c[18 + 6] == 0x22);
    CHECK((unsigned)(c[18 + 7] | c[18 + 8] << 8) == len);
    CHECK(c[27 + 2] == 0x81 && c[27 + 3] == 3 && (c[27 + 4] | c[27 + 5] << 8) == HV_TOUCH_REPORT_LEN);
    const uint8_t *dv = hv_usb_touch_device_desc;
    CHECK(dv[8] == 0x27 && dv[9] == 0x06 && dv[10] == 0x03 && dv[11] == 0x00);
}

/* ---- 2. packing ---- */

static void test_pack(void) {
    uint8_t r[HV_TOUCH_REPORT_LEN], r2[HV_TOUCH_REPORT_LEN];
    CHECK(hv_usb_touch_pack(r, NULL, 0, 0x1234) == 0);
    CHECK(r[0] == 1 && r[63] == 0 && r[61] == 0x34 && r[62] == 0x12);

    HvTouchContact two[2] = {{3, 1, 1, 0x0102, 0x0304}, {7, 0, 0, 40000, 32767}};
    CHECK(hv_usb_touch_pack(r, two, 2, 0) == 2);
    CHECK(r[1] == 3 && r[2] == 3 && r[3] == 0x02 && r[4] == 0x01 && r[5] == 0x04 && r[6] == 0x03);
    CHECK(r[7] == 0 && r[8] == 7 && r[9] == 0xff && r[10] == 0x7f && r[11] == 0xff && r[12] == 0x7f); /* clamped */
    CHECK(r[13] == 0 && r[63] == 2);

    HvTouchContact many[11];
    for (int i = 0; i < 11; i++) many[i] = (HvTouchContact){(uint8_t)i, 1, 1, (uint16_t)(i * 100), 5};
    CHECK(hv_usb_touch_pack(r, many, 11, 0) == HV_TOUCH_MAX_CONTACTS);
    CHECK(r[63] == HV_TOUCH_MAX_CONTACTS && r[1 + 6 * 9 + 1] == 9);

    /* moves: the same contacts, all down with confidence, in both */
    HvTouchContact a[2] = {{0, 1, 1, 10, 10}, {1, 1, 1, 20, 20}};
    hv_usb_touch_pack(r, a, 2, 0);
    a[0].x = 11;
    hv_usb_touch_pack(r2, a, 2, 1);
    CHECK(hv_usb_touch_is_motion(r, r2));
    hv_usb_touch_pack(r2, a, 1, 1); /* a contact gone */
    CHECK(!hv_usb_touch_is_motion(r, r2));
    a[1].tip = 0;
    hv_usb_touch_pack(r2, a, 2, 1); /* a lift */
    CHECK(!hv_usb_touch_is_motion(r, r2));
    a[1].tip = 1;
    a[1].id = 4;
    hv_usb_touch_pack(r2, a, 2, 1); /* another finger in the slot */
    CHECK(!hv_usb_touch_is_motion(r, r2));
    hv_usb_touch_pack(r, NULL, 0, 0);
    CHECK(!hv_usb_touch_is_motion(r, r)); /* nothing down: not a move */

    uint8_t f[4];
    CHECK(hv_usb_touch_feature(2, 0, 0, f, 4) == 2 && f[0] == 2 && f[1] == HV_TOUCH_MAX_CONTACTS);
    CHECK(hv_usb_touch_feature(3, 2, 5, f, 4) == 3 && f[0] == 3 && f[1] == 2 && f[2] == 5);
    CHECK(hv_usb_touch_feature(1, 0, 0, f, 4) < 0);
    CHECK(hv_usb_touch_feature(0xc5, 0, 0, f, 4) < 0);
}

/* ---- 3. the controller, driven through its registers ---- */

#define DCBAA (RAM_PA + 0x1000)
#define OUTCTX(s) (RAM_PA + 0x2000 + 0x800ull * (s))
#define INCTX (RAM_PA + 0x10000)
#define CMDRING (RAM_PA + 0x11000)
#define ERST (RAM_PA + 0x12000)
#define EVSEG (RAM_PA + 0x14000) /* 1024 TRBs */
#define EP0RING(p) (RAM_PA + 0x20000 + 0x1000ull * (p))
#define EP1RING(p) (RAM_PA + 0x30000 + 0x1000ull * (p))
#define BUF (RAM_PA + 0x40000)
#define INBUF(i) (RAM_PA + 0x50000 + 0x100ull * (i))

static HvXhci *x;
static unsigned cmd_enq, ev_deq;
static unsigned ep0_enq[4], ep1_enq[4];

static void w32(uint64_t off, uint32_t v) { x->pci.bar_write(&x->pci, 0, off, v, 4); }
static uint32_t r32(uint64_t off) { return (uint32_t)x->pci.bar_read(&x->pci, 0, off, 4); }

static void put_trb(uint64_t pa, uint64_t param, uint32_t status, uint32_t control) {
    put64(pa, param);
    put32(pa + 8, status);
    put32(pa + 12, control | 1); /* cycle 1: the rings here never wrap */
}

/* The next event on the event ring: its TRB type, or 0 when there is none. */
static int next_event(uint32_t ev[4]) {
    uint64_t pa = EVSEG + 16ull * ev_deq;
    uint32_t c = get32(pa + 12);
    if ((c & 1) != 1) return 0;
    for (int i = 0; i < 4; i++) ev[i] = get32(pa + 4ull * i);
    ev_deq++;
    return (int)((c >> 10) & 0x3f);
}

static int command(uint32_t type, uint64_t ptr, int slot, int *slot_out) {
    put_trb(CMDRING + 16ull * cmd_enq++, ptr, 0, type << 10 | (uint32_t)slot << 24);
    w32(0x2000, 0); /* doorbell 0 */
    uint32_t ev[4];
    int t;
    while ((t = next_event(ev)) && t != 33) {}
    if (t != 33) return -1;
    if (slot_out) *slot_out = (int)(ev[3] >> 24);
    return (int)(ev[2] >> 24);
}

/* A control transfer on a slot's EP0: Setup, an optional Data stage, Status with IOC. Returns the
   completion code of its event (1 success, 6 stall). */
static int control(int slot, int port, uint8_t type, uint8_t req, uint16_t value, uint16_t index, uint16_t len,
                   uint64_t data) {
    uint64_t ring = EP0RING(port);
    uint64_t setup = (uint64_t)type | (uint64_t)req << 8 | (uint64_t)value << 16 | (uint64_t)index << 32 |
                     (uint64_t)len << 48;
    int in = (type & 0x80) != 0;
    uint32_t trt = len ? (in ? 3u : 2u) : 0u;
    put_trb(ring + 16ull * ep0_enq[port]++, setup, 8, 2u << 10 | 1u << 6 | trt << 16);
    if (len) put_trb(ring + 16ull * ep0_enq[port]++, data, len, 3u << 10 | (uint32_t)in << 16);
    put_trb(ring + 16ull * ep0_enq[port]++, 0, 0, 4u << 10 | 1u << 5 | (uint32_t)(len && in ? 0 : 1) << 16);
    w32(0x2000 + 4u * (unsigned)slot, 1);
    uint32_t ev[4];
    int t;
    while ((t = next_event(ev)) && t != 32) {}
    if (t != 32) return -1;
    return (int)(ev[2] >> 24);
}

static void start_controller(void) {
    memset(ram, 0, sizeof ram);
    cmd_enq = ev_deq = 0;
    memset(ep0_enq, 0, sizeof ep0_enq);
    memset(ep1_enq, 0, sizeof ep1_enq);
    w32(0x70, (uint32_t)DCBAA);
    w32(0x74, (uint32_t)(DCBAA >> 32));
    w32(0x58, (uint32_t)CMDRING | 1);
    w32(0x5c, (uint32_t)(CMDRING >> 32));
    put64(ERST, EVSEG);
    put32(ERST + 8, 1024);
    w32(0x1020, 2);   /* IMAN: IE */
    w32(0x1028, 1);   /* ERSTSZ */
    w32(0x1030, (uint32_t)ERST);
    w32(0x1034, (uint32_t)(ERST >> 32));
    w32(0x40, 1 | 4); /* run, interrupts on */
}

/* Port reset, Enable Slot, Address Device: the slot for the device on `port`. */
static int address(int port) {
    w32(0x440 + 16u * (unsigned)(port - 1), 1u << 4 | 1u << 9);
    uint32_t ev[4];
    CHECK(next_event(ev) == 34 && (ev[0] >> 24) == (uint32_t)port);
    int slot = 0;
    CHECK(command(9, 0, 0, &slot) == 1);
    CHECK(slot >= 1);
    memset(at(INCTX), 0, 33 * 32);
    put32(INCTX + 4, 3); /* add slot and EP0 */
    uint8_t *sc = at(INCTX + 32);
    sc[6] = (uint8_t)port;
    put32(INCTX + 64 + 4, 4u << 3 | 64u << 16); /* control, MPS 64 */
    put64(INCTX + 64 + 8, EP0RING(port) | 1);
    put64(DCBAA + 8ull * (unsigned)slot, OUTCTX(slot));
    CHECK(command(11, INCTX, slot, NULL) == 1);
    return slot;
}

static void test_controller(void) {
    static uint8_t dummy_machine[64];
    static HvPcie bus;
    x = hv_xhci_create((HvMachine *)(void *)dummy_machine, &bus);
    CHECK(x != NULL);
    if (!x) return;
    CHECK(((r32(4) >> 24) & 0xff) == 3);    /* HCSPARAMS1 MaxPorts */
    CHECK(((r32(0x808) >> 8) & 0xff) == 3); /* USB 2 protocol: compatible port count */

    start_controller();
    uint32_t ev[4];
    for (int p = 1; p <= 3; p++) {
        CHECK(next_event(ev) == 34);
        CHECK((ev[0] >> 24) == (uint32_t)p); /* a connect on every port */
        CHECK(r32(0x440 + 16u * (unsigned)(p - 1)) & 1);
    }

    /* Every port's device, its descriptors from its own table: ports 1 and 2 as before. */
    static const uint8_t kbd_dev[18] = {18, 1, 0, 2, 0, 0, 0, 64, 0x27, 6, 2, 0, 0, 1, 1, 2, 3, 1};
    static const uint8_t tab_dev[18] = {18, 1, 0, 2, 0, 0, 0, 64, 0x27, 6, 1, 0, 0, 1, 1, 4, 5, 1};
    static const unsigned report_len[4] = {0, 64, 63, 0};
    int slots[4] = {0};
    for (int p = 1; p <= 3; p++) {
        int slot = slots[p] = address(p);
        memset(at(BUF), 0xee, 2048);
        CHECK(control(slot, p, 0x80, 6, 0x0100, 0, 18, BUF) == 1);
        if (p == 1) CHECK(memcmp(at(BUF), kbd_dev, 18) == 0);
        if (p == 2) CHECK(memcmp(at(BUF), tab_dev, 18) == 0);
        if (p == 3) CHECK(memcmp(at(BUF), hv_usb_touch_device_desc, 18) == 0);
        CHECK(((uint8_t *)at(BUF))[18] == 0xee);

        memset(at(BUF), 0xee, 2048);
        CHECK(control(slot, p, 0x80, 6, 0x0200, 0, 255, BUF) == 1);
        const uint8_t *cfg = at(BUF);
        CHECK(cfg[2] == 34 && cfg[34] == 0xee);
        unsigned hid_len = cfg[25] | cfg[26] << 8;
        if (p < 3) CHECK(hid_len == report_len[p]);
        else CHECK(hid_len == hv_usb_touch_report_desc_len && cfg[31] == 64);
        if (p == 1) CHECK(cfg[14] == 3 && cfg[15] == 1 && cfg[16] == 1 && cfg[31] == 8); /* boot keyboard */
        if (p == 2) CHECK(cfg[15] == 0 && cfg[31] == 8);

        /* the whole report descriptor in one reply, nothing more */
        memset(at(BUF), 0xee, 2048);
        CHECK(control(slot, p, 0x81, 6, 0x2200, 0, 1024, BUF) == 1);
        const uint8_t *rd = at(BUF);
        CHECK(rd[hid_len] == 0xee && rd[hid_len - 1] == 0xc0);
        if (p == 3) CHECK(memcmp(rd, hv_usb_touch_report_desc, hv_usb_touch_report_desc_len) == 0);

        CHECK(control(slot, p, 0x00, 9, 1, 0, 0, 0) == 1); /* SET_CONFIGURATION */
    }

    /* The touch screen: its strings, feature reports and Device Mode. */
    int ts = slots[3];
    memset(at(BUF), 0, 256);
    CHECK(control(ts, 3, 0x80, 6, 0x0306, 0x0409, 255, BUF) == 1);
    const char *name = "WindowsiOS USB Touchscreen";
    const uint8_t *sd = at(BUF);
    CHECK(sd[0] == 2 + 2 * strlen(name) && sd[1] == 3);
    for (size_t i = 0; i < strlen(name); i++) CHECK(sd[2 + 2 * i] == (uint8_t)name[i]);
    CHECK(control(ts, 3, 0xa1, 1, 0x0302, 0, 2, BUF) == 1);
    CHECK(sd[0] == 2 && sd[1] == HV_TOUCH_MAX_CONTACTS);
    uint8_t mode[3] = {3, 2, 0};
    memcpy(at(BUF + 0x400), mode, 3);
    CHECK(control(ts, 3, 0x21, 9, 0x0303, 0, 3, BUF + 0x400) == 1); /* SET_REPORT: multi-input mode */
    memset(at(BUF), 0, 4);
    CHECK(control(ts, 3, 0xa1, 1, 0x0303, 0, 3, BUF) == 1);
    CHECK(sd[0] == 3 && sd[1] == 2 && sd[2] == 0);
    memset(at(BUF), 0xee, 128);
    CHECK(control(ts, 3, 0xa1, 1, 0x0101, 0, 64, BUF) == 1); /* input report 1: nothing down */
    CHECK(sd[0] == 1 && sd[63] == 0 && sd[64] == 0xee);

    /* Configure EP1 IN. With the endpoint running but no read queued (as UEFI leaves it), not in use. */
    memset(at(INCTX), 0, 33 * 32);
    put32(INCTX + 4, 1u | 1u << 3);
    ((uint8_t *)at(INCTX + 32))[6] = 3;
    put32(INCTX + 32 * 4 + 4, 7u << 3 | 64u << 16); /* interrupt IN, MPS 64 */
    put64(INCTX + 32 * 4 + 8, EP1RING(3) | 1);
    CHECK(command(12, INCTX, ts, NULL) == 1);
    usleep(15000);
    hv_xhci_poll(x);
    CHECK(hv_xhci_touch_ready(x) == 0);

    /* The queue: moves merge into the move before them; downs and lifts are never merged. */
    HvTouchContact c[2] = {{0, 1, 1, 100, 200}, {1, 1, 1, 300, 400}};
    hv_xhci_touch(x, c, 1);                  /* 1: finger 0 down */
    c[0].x = 110;
    hv_xhci_touch(x, c, 1);                  /* 2: a move */
    c[0].x = 120;
    hv_xhci_touch(x, c, 1);                  /*    merged into 2 */
    CHECK(x->ctail - x->chead == 2);
    hv_xhci_touch(x, c, 2);                  /* 3: finger 1 down */
    c[1].y = 410;
    hv_xhci_touch(x, c, 2);                  /* 4: a move */
    c[1].tip = 0, c[1].confidence = 0;
    hv_xhci_touch(x, c, 2);                  /* 5: finger 1 lifts */
    hv_xhci_touch(x, c, 1);                  /* 6: finger 0 alone */
    CHECK(x->ctail - x->chead == 6);

    /* The guest queues 8 reads: the 6 reports go out, one per read, with a transfer event each. */
    for (int i = 0; i < 8; i++) put_trb(EP1RING(3) + 16ull * ep1_enq[3]++, INBUF(i), 64, 1u << 10 | 1u << 5);
    w32(0x2000 + 4u * (unsigned)ts, 3);
    CHECK(x->chead == x->ctail);
    int transfers = 0;
    while (next_event(ev) == 32) {
        CHECK((ev[2] >> 24) == 1 && ((ev[3] >> 16) & 0x1f) == 3);
        transfers++;
    }
    CHECK(transfers == 6);
    const uint8_t *r1 = at(INBUF(0)), *r2 = at(INBUF(1)), *r3 = at(INBUF(2)), *r5 = at(INBUF(4)), *r6 = at(INBUF(5));
    CHECK(r1[0] == 1 && r1[1] == 3 && r1[2] == 0 && (r1[3] | r1[4] << 8) == 100 && (r1[5] | r1[6] << 8) == 200 && r1[63] == 1);
    CHECK((r2[3] | r2[4] << 8) == 120 && r2[63] == 1);
    CHECK(r3[63] == 2 && r3[7] == 3 && r3[8] == 1 && (r3[11] | r3[12] << 8) == 400);
    CHECK(r5[63] == 2 && r5[7] == 0 && r5[8] == 1); /* the lift: tip and confidence off */
    CHECK(r6[63] == 1 && r6[1] == 3);
    CHECK(((uint8_t *)at(INBUF(6)))[0] == 0); /* reads 7 and 8 still waiting */

    /* Reads queued: in use. */
    usleep(15000);
    hv_xhci_poll(x);
    CHECK(hv_xhci_touch_ready(x) == 1);

    /* A full queue keeps its last 32 places for downs and lifts (nothing is taken from it here). */
    c[1].tip = c[1].confidence = 1;
    for (int i = 0; i < 224; i++) hv_xhci_touch(x, c, 1 + (i & 1)); /* finger 1 down, up, down... */
    CHECK(x->ctail - x->chead == 224);
    uint64_t dropped = x->touch_dropped;
    hv_xhci_touch(x, c, 2); /* the same contacts again: a move, no room for it */
    CHECK(x->touch_dropped == dropped + 1);
    CHECK(x->ctail - x->chead == 224);
    hv_xhci_touch(x, c, 1); /* a contact gone: kept */
    CHECK(x->ctail - x->chead == 225);
    for (int i = 0; i < 40; i++) hv_xhci_touch(x, c, 1 + (i & 1));
    CHECK(x->ctail - x->chead == HV_XHCI_REPORTS);

    /* A controller reset drops it all: nothing from before is replayed to the next driver. */
    w32(0x40, 2); /* HCRST */
    CHECK(x->chead == x->ctail);
    CHECK(x->touch_slot == 0);
    CHECK(hv_xhci_touch_ready(x) == 0);
    CHECK(x->touch_state[0] == 1 && x->touch_state[63] == 0);

    /* Disabling the slot drops the queue too. */
    start_controller();
    for (int p = 1; p <= 3; p++) CHECK(next_event(ev) == 34);
    ts = address(3);
    CHECK(x->touch_slot == ts);
    hv_xhci_touch(x, c, 1);
    CHECK(x->ctail - x->chead == 1);
    CHECK(command(10, 0, ts, NULL) == 1);
    CHECK(x->touch_slot == 0 && x->chead == x->ctail);
    CHECK(msix_count > 0);
}

int main(void) {
    test_report_descriptor();
    test_pack();
    test_controller();
    if (failures) {
        fprintf(stderr, "test_usb_touch: %d failure(s)\n", failures);
        return 1;
    }
    printf("test_usb_touch: report descriptor %u bytes; all checks passed\n", hv_usb_touch_report_desc_len);
    return 0;
}
