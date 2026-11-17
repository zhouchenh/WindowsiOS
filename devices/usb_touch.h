/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_USB_TOUCH_H
#define HV_USB_TOUCH_H

#include <stdint.h>

/* The xHCI's port 3: a USB HID multi-touch touch screen (0627:0003) in the Windows touch screen
   format (parallel mode), which Windows' inbox hidusb / hidclass / HID touch stack drives with no
   driver to install. Ten contacts per report.

   Input report 1, 64 bytes:
     [0]               report ID 1
     [1 + 6 * i]       contact i: bit 0 = Tip Switch, bit 1 = Confidence
     [2 + 6 * i]       contact i: Contact Identifier (0..15)
     [3 + 6 * i ..]    contact i: X, then Y, 16-bit little endian, 0..32767 across the whole screen
     [61..62]          Scan Time, 100 us units, wrapping
     [63]              Contact Count: how many of the slots above are valid in this report
   Valid contacts fill the first Contact Count slots. A contact that lifts is sent once with Tip
   Switch 0 (Confidence 0 as well: a cancelled contact, which Windows does not take as a tap) and is
   left out of the next report.
   Feature report 2: Contact Count Maximum (10). Feature report 3: Device Mode, Device Identifier. */
#define HV_TOUCH_MAX_CONTACTS 10
#define HV_TOUCH_REPORT_LEN 64
#define HV_TOUCH_REPORT_ID 1
#define HV_TOUCH_FEATURE_MAX_ID 2
#define HV_TOUCH_FEATURE_MODE_ID 3

typedef struct HvTouchContact {
    uint8_t id;         /* 0..15, the same for a finger from the time it lands until it lifts */
    uint8_t tip;        /* 1: on the screen; 0: lifting (sent once) */
    uint8_t confidence; /* 1: a real touch; 0 with tip 0: cancelled (not a tap) */
    uint16_t x, y;      /* 0..32767 */
} HvTouchContact;

extern const uint8_t hv_usb_touch_report_desc[];
extern const unsigned hv_usb_touch_report_desc_len;
extern const uint8_t hv_usb_touch_device_desc[18];
extern const uint8_t hv_usb_touch_config_desc[34];

/* Packs one input report; contacts past HV_TOUCH_MAX_CONTACTS are left out, X and Y are clamped to
   0..32767. Returns the number of contacts packed. */
int hv_usb_touch_pack(uint8_t out[HV_TOUCH_REPORT_LEN], const HvTouchContact *c, int n, uint16_t scan_time);

/* 1 when `next` only moves contacts `prev` already had down: the same contacts in the same slots,
   all of them down with confidence in both. A report that puts a contact down or lifts one is not a
   move (and must never be merged into another). */
int hv_usb_touch_is_motion(const uint8_t prev[HV_TOUCH_REPORT_LEN], const uint8_t next[HV_TOUCH_REPORT_LEN]);

/* The reply to GET_REPORT (feature) for report ID `id`: its length, or -1 for a report the device does
   not have. dev_mode and dev_id are what the host last set (SET_REPORT feature 3). */
int hv_usb_touch_feature(uint8_t id, uint8_t dev_mode, uint8_t dev_id, uint8_t *out, int max);

#endif
