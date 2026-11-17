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
 * 0 safely disabled, or -1 sticky incomplete rollback/protection failure: the
 * caller MUST refuse backend device creation for the rest of the process.
 * A static diagnostic is available from hv_npt_hook_status(). Failure does
 * not authorize immediate COM Release. The loaded image and callback must remain
 * alive for the process lifetime; there is deliberately no uninstall operation.
 */
/* Dry-run BEFORE installing DXMT lifetime hooks: validates the loaded renderer,
 * exact code/layout, canonical libc free import, and reversible data-page write
 * access. Does not publish callbacks or mutate the GOT; does not require the
 * DXMT check. Return values match install. A successful preflight is not a
 * reservation: if actual free installation subsequently fails after device
 * hooks installed, caller MUST refuse backend creation persistently. */
int hv_npt_preflight_free_hook(void *virgl_symbol, void (*capture)(void *), void (*submit)(void));
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
