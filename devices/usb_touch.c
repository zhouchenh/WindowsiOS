/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Port 3 of the xHCI: a USB HID multi-touch touch screen (see usb_touch.h for the report). The
   descriptors follow Microsoft's touch screen samples for the Windows HID touch stack: a Touch Screen
   application collection with ten Finger collections, Scan Time and Contact Count (input report 1),
   Contact Count Maximum (feature 2), and a Device Configuration collection (feature 3). No Device
   Certification Status blob: Windows takes it as an uncertified, working touch screen. */
#include "usb_touch.h"

#include <string.h>

/* One Finger logical collection, 70 bytes: Tip Switch and Confidence (1 bit each, 6 bits padding),
   Contact Identifier (8 bits), X and Y (16 bits, 0..32767, nominally 12 x 8 cm). The physical unit is
   reset at its end and the usage page is back on Digitizers for the next item. */
#define FINGER                                                                                     \
    0x09, 0x22,                   /* Usage (Finger) */                                             \
    0xa1, 0x02,                   /* Collection (Logical) */                                       \
    0x09, 0x42,                   /*   Usage (Tip Switch) */                                       \
    0x15, 0x00,                   /*   Logical Minimum (0) */                                      \
    0x25, 0x01,                   /*   Logical Maximum (1) */                                      \
    0x75, 0x01,                   /*   Report Size (1) */                                          \
    0x95, 0x01,                   /*   Report Count (1) */                                         \
    0x81, 0x02,                   /*   Input (Data,Var,Abs) */                                     \
    0x09, 0x47,                   /*   Usage (Confidence) */                                       \
    0x81, 0x02,                   /*   Input (Data,Var,Abs) */                                     \
    0x95, 0x06,                   /*   Report Count (6) */                                         \
    0x81, 0x03,                   /*   Input (Const,Var,Abs) */                                    \
    0x75, 0x08,                   /*   Report Size (8) */                                          \
    0x09, 0x51,                   /*   Usage (Contact Identifier) */                               \
    0x25, 0x0f,                   /*   Logical Maximum (15) */                                     \
    0x95, 0x01,                   /*   Report Count (1) */                                         \
    0x81, 0x02,                   /*   Input (Data,Var,Abs) */                                     \
    0x05, 0x01,                   /*   Usage Page (Generic Desktop) */                             \
    0x26, 0xff, 0x7f,             /*   Logical Maximum (32767) */                                  \
    0x75, 0x10,                   /*   Report Size (16) */                                         \
    0x55, 0x0e,                   /*   Unit Exponent (-2) */                                       \
    0x65, 0x11,                   /*   Unit (cm) */                                                \
    0x35, 0x00,                   /*   Physical Minimum (0) */                                     \
    0x46, 0xb0, 0x04,             /*   Physical Maximum (1200: 12.00 cm) */                        \
    0x09, 0x30,                   /*   Usage (X) */                                                \
    0x81, 0x02,                   /*   Input (Data,Var,Abs) */                                     \
    0x46, 0x20, 0x03,             /*   Physical Maximum (800: 8.00 cm) */                          \
    0x09, 0x31,                   /*   Usage (Y) */                                                \
    0x81, 0x02,                   /*   Input (Data,Var,Abs) */                                     \
    0x45, 0x00,                   /*   Physical Maximum (0) */                                     \
    0x65, 0x00,                   /*   Unit (none) */                                              \
    0x55, 0x00,                   /*   Unit Exponent (0) */                                        \
    0x05, 0x0d,                   /*   Usage Page (Digitizers) */                                  \
    0xc0                          /* End Collection */

const uint8_t hv_usb_touch_report_desc[] = {
    0x05, 0x0d,                   /* Usage Page (Digitizers) */
    0x09, 0x04,                   /* Usage (Touch Screen) */
    0xa1, 0x01,                   /* Collection (Application) */
    0x85, HV_TOUCH_REPORT_ID,     /*   Report ID (1) */
    FINGER, FINGER, FINGER, FINGER, FINGER, FINGER, FINGER, FINGER, FINGER, FINGER,
    0x55, 0x0c,                   /*   Unit Exponent (-4) */
    0x66, 0x01, 0x10,             /*   Unit (seconds) */
    0x47, 0xff, 0xff, 0x00, 0x00, /*   Physical Maximum (65535) */
    0x27, 0xff, 0xff, 0x00, 0x00, /*   Logical Maximum (65535) */
    0x75, 0x10,                   /*   Report Size (16) */
    0x95, 0x01,                   /*   Report Count (1) */
    0x09, 0x56,                   /*   Usage (Scan Time): 100 us units */
    0x81, 0x02,                   /*   Input (Data,Var,Abs) */
    0x45, 0x00,                   /*   Physical Maximum (0) */
    0x65, 0x00,                   /*   Unit (none) */
    0x55, 0x00,                   /*   Unit Exponent (0) */
    0x25, HV_TOUCH_MAX_CONTACTS,  /*   Logical Maximum (10) */
    0x75, 0x08,                   /*   Report Size (8) */
    0x09, 0x54,                   /*   Usage (Contact Count) */
    0x81, 0x02,                   /*   Input (Data,Var,Abs) */
    0x85, HV_TOUCH_FEATURE_MAX_ID, /*  Report ID (2) */
    0x09, 0x55,                   /*   Usage (Contact Count Maximum) */
    0xb1, 0x02,                   /*   Feature (Data,Var,Abs) */
    0xc0,                         /* End Collection */
    0x05, 0x0d,                   /* Usage Page (Digitizers) */
    0x09, 0x0e,                   /* Usage (Device Configuration) */
    0xa1, 0x01,                   /* Collection (Application) */
    0x85, HV_TOUCH_FEATURE_MODE_ID, /* Report ID (3) */
    0x09, 0x23,                   /*   Usage (Device Settings) */
    0xa1, 0x02,                   /*   Collection (Logical) */
    0x09, 0x52,                   /*     Usage (Device Mode) */
    0x09, 0x53,                   /*     Usage (Device Identifier) */
    0x15, 0x00,                   /*     Logical Minimum (0) */
    0x25, 0x0a,                   /*     Logical Maximum (10) */
    0x75, 0x08,                   /*     Report Size (8) */
    0x95, 0x02,                   /*     Report Count (2) */
    0xb1, 0x02,                   /*     Feature (Data,Var,Abs) */
    0xc0,                         /*   End Collection */
    0xc0,                         /* End Collection */
};

const unsigned hv_usb_touch_report_desc_len = sizeof hv_usb_touch_report_desc;

const uint8_t hv_usb_touch_device_desc[18] = {
    18, 1, 0x00, 0x02, 0, 0, 0, 64,
    0x27, 0x06, 0x03, 0x00, /* WindowsiOS USB Touchscreen (0627:0003) */
    0x00, 0x01, 1, 6, 7, 1,
};

/* Bus powered without remote wakeup (bmAttributes 0x80): Windows does not selectively suspend a HID
   device that cannot wake itself, and the xHCI has no device-initiated resume. The HID descriptor's
   report length is 16-bit (the descriptor is longer than 255 bytes). EP1 IN carries one 64-byte report
   per 1 ms frame. */
const uint8_t hv_usb_touch_config_desc[34] = {
    9, 2, 34, 0, 1, 1, 0, 0x80, 50,
    9, 4, 0, 0, 1, 3, 0, 0, 0,                                    /* HID, no boot protocol */
    9, 0x21, 0x11, 0x01, 0, 1, 0x22,
    (uint8_t)(sizeof hv_usb_touch_report_desc & 0xff), (uint8_t)(sizeof hv_usb_touch_report_desc >> 8),
    7, 5, 0x81, 3, HV_TOUCH_REPORT_LEN, 0, 1,                     /* EP1 IN, 64 bytes, 1 ms */
};

static uint16_t clamp15(uint16_t v) {
    return v > 32767 ? 32767 : v;
}

int hv_usb_touch_pack(uint8_t out[HV_TOUCH_REPORT_LEN], const HvTouchContact *c, int n, uint16_t scan_time) {
    memset(out, 0, HV_TOUCH_REPORT_LEN);
    out[0] = HV_TOUCH_REPORT_ID;
    if (n < 0 || !c) n = 0;
    if (n > HV_TOUCH_MAX_CONTACTS) n = HV_TOUCH_MAX_CONTACTS;
    for (int i = 0; i < n; i++) {
        uint8_t *p = out + 1 + 6 * i;
        uint16_t x = clamp15(c[i].x), y = clamp15(c[i].y);
        p[0] = (uint8_t)((c[i].tip ? 1u : 0u) | (c[i].confidence ? 2u : 0u));
        p[1] = c[i].id & 0x0f;
        p[2] = (uint8_t)(x & 0xff);
        p[3] = (uint8_t)(x >> 8);
        p[4] = (uint8_t)(y & 0xff);
        p[5] = (uint8_t)(y >> 8);
    }
    out[61] = (uint8_t)(scan_time & 0xff);
    out[62] = (uint8_t)(scan_time >> 8);
    out[63] = (uint8_t)n;
    return n;
}

int hv_usb_touch_is_motion(const uint8_t prev[HV_TOUCH_REPORT_LEN], const uint8_t next[HV_TOUCH_REPORT_LEN]) {
    int n = next[63];
    if (n == 0 || n != prev[63] || n > HV_TOUCH_MAX_CONTACTS) return 0;
    for (int i = 0; i < n; i++) {
        const uint8_t *a = prev + 1 + 6 * i, *b = next + 1 + 6 * i;
        if ((a[0] & 3) != 3 || (b[0] & 3) != 3 || a[1] != b[1]) return 0;
    }
    return 1;
}

int hv_usb_touch_feature(uint8_t id, uint8_t dev_mode, uint8_t dev_id, uint8_t *out, int max) {
    uint8_t r[3];
    int len;
    if (id == HV_TOUCH_FEATURE_MAX_ID) {
        r[0] = id, r[1] = HV_TOUCH_MAX_CONTACTS;
        len = 2;
    } else if (id == HV_TOUCH_FEATURE_MODE_ID) {
        r[0] = id, r[1] = dev_mode, r[2] = dev_id;
        len = 3;
    } else {
        return -1;
    }
    if (len > max) len = max;
    memcpy(out, r, (size_t)len);
    return len;
}
