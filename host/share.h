#ifndef HENGEVM_SHARE_H
#define HENGEVM_SHARE_H

#include <stddef.h>

/* What the Mac and the device share: a folder and the clipboard (see share.c). The guest reaches this
   at HV_SHARE_ADDR, port 80, which the network hands to the Unix socket. Returns 0, or -1 if the socket
   can't be made. agent is the gzipped helper that runs inside macOS, served to the guest; it may be NULL. */
#define HV_SHARE_ADDR "10.0.2.4"
int hv_share_start(const char *folder, const char *socket_path, const char *agent);

/* The clipboard: one slot of UTF-8 text both sides copy into (docs/clipboard.md). The guest's helper
   waits for the device's with GET /.henge/clipboard?since=N and sends its own with PUT. */
#define HV_SHARE_CLIP_MAX (1024 * 1024) /* bytes of text */
#define HV_SHARE_CLIP_FROM_DEVICE 0
#define HV_SHARE_CLIP_FROM_GUEST 1
/* The device's clipboard, for the guest to pick up. Returns the slot's new sequence number, or 0 if
   nothing changed: empty, not UTF-8, larger than HV_SHARE_CLIP_MAX, or the text the slot has already. */
unsigned long hv_share_set_clipboard(const char *text);
/* What the guest last copied, once: a malloc'd string, or NULL if nothing is new. */
char *hv_share_take_clipboard(void);
/* The slot as it is (malloc'd, or NULL when empty), its sequence number and HV_SHARE_CLIP_FROM_*. */
char *hv_share_get_clipboard(unsigned long *seq, int *origin);
/* Called on the server's thread, without locks held, each time the guest copies something new. */
typedef void (*hv_share_clip_fn)(unsigned long seq, void *opaque);
void hv_share_set_clipboard_listener(hv_share_clip_fn fn, void *opaque);
/* Seconds since the guest's clipboard helper was last heard from: 0 while it waits for news, -1 never. */
long hv_share_clipboard_agent_seen(void);
/* 1 if len bytes at text are UTF-8 without NUL and at most HV_SHARE_CLIP_MAX long. */
int hv_share_clip_valid(const char *text, size_t len);
/* Seconds since any helper in the guest was last heard from, or -1 if it never has been. */
long hv_share_agent_seen(void);

/* Enable/disable host SafariSheet handling of guest `/.henge/open-url` requests (0 -> guest falls back to Edge). */
void hv_share_set_url_handler_enabled(int enabled);
int hv_share_url_handler_enabled(void);
/* URL the guest asked the host browser to open (e.g. Google OAuth sign-in), once: malloc'd or NULL. */
char *hv_share_take_open_url(void);
/* Returns 1 (once) when the guest OAuth callback relay completed an auth redirect. */
int hv_share_take_oauth_done(void);

#endif
