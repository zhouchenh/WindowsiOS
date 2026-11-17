/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef HV_NEPTUNE_HOOK_H
#define HV_NEPTUNE_HOOK_H

/* Install once, before submitting work to virgl. Only the original known image
 * is supported. The capture callback takes ownership of a Neptune object record
 * (host COM pointer at +0x10, owned registration count at +0x20); it must preserve
 * those references until cleanup has established safe GPU retirement. It must
 * not call back into virgl. submit() runs on that same backend thread at the final
 * free(context), after teardown has captured every record and released all other
 * context resources. It must submit that thread's batch, not a host proxy-call
 * batch: proxy context destruction is asynchronous. No executable memory changes.
 *
 * Returns 1 when installed (including an identical repeated request), otherwise
 * 0 with a static diagnostic from hv_npt_hook_status(). Failed installation does
 * not authorize immediate COM Release. The loaded image and callback must remain
 * alive for the process lifetime; there is deliberately no uninstall operation.
 */
int hv_npt_install_free_hook(void *virgl_symbol, void (*capture)(void *), void (*submit)(void));
const char *hv_npt_hook_status(void);

/* Must succeed before installing interception, including batches which never
 * need the weak-parent reader. Accepts the actual loaded D3D11CreateDevice. */
int hv_npt_check_dxmt(void *d3d11_create_device_symbol);

/* A passive read, for a valid queried ID3D11DeviceChild interface. Validates the
 * pinned DXMT image and exact GetDevice method before reading its weak parent
 * pointer. Never invokes GetDevice, AddRef, or dereferences that parent. Caller
 * must compare it to an independently held live device before using it. */
int hv_npt_read_child_parent(void *child, void **raw_device);

#endif
