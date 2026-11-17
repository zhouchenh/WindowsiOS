/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Capture only Neptune's verified context-destroy record frees. The rest of
 * virgl's free calls stay on a direct libc fast path, without allocation or a
 * hook lock. See scripts/check_neptune.py for the source/ABI audit. */
#include "neptune_hook.h"
#include "neptune_hook_layout.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(sizeof(void *) == 8, "Neptune hook requires 64-bit pointers");
_Static_assert(ATOMIC_POINTER_LOCK_FREE == 2, "free hook must not take an atomic lock");

enum HookStatus {
    HOOK_NOT_INSTALLED, HOOK_INSTALLED, HOOK_NO_IMAGE, HOOK_BAD_ARGUMENT,
    HOOK_BAD_HEADER, HOOK_BAD_UUID, HOOK_BAD_LAYOUT, HOOK_BAD_CODE,
    HOOK_BAD_IMPORT, HOOK_BAD_PROTECTION, HOOK_PROTECT_FAILED,
    HOOK_BIND_RACE, HOOK_RESTORE_FAILED, HOOK_RETRY_REJECTED,
    HOOK_ALREADY_DIFFERENT, HOOK_BAD_DXMT, HOOK_PREFLIGHT_READY, HOOK_FATAL
};
static _Atomic int hook_status;
static _Atomic bool hook_fatal;
static pthread_mutex_t install_mutex = PTHREAD_MUTEX_INITIALIZER;

struct HookState {
    uintptr_t image, return_pc, finish_pc, slot;
    void (*capture)(void *);
    void (*submit)(void);
};
/* Once published this storage is immutable, even if the later import CAS fails.
 * A thread which loaded the hook just before rollback may still enter it. */
static struct HookState hook_state;
static _Atomic(struct HookState *) published;
static _Atomic(uintptr_t) trusted_dxmt_image;
static bool installed; /* Only read/written with install_mutex held. */

__attribute__((noinline)) static void npt_free_hook(void *record)
{
    uintptr_t caller = (uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0));
    struct HookState *state = atomic_load_explicit(&published, memory_order_acquire);
    if (state && caller == state->return_pc) {
        state->capture(record);
        return;
    }
    if (state && caller == state->finish_pc)
        state->submit();
    free(record);
}

const char *hv_npt_hook_status(void)
{
    static const char *const messages[] = {
        "not installed", "installed: guarded deferred context cleanup",
        "disabled: renderer image not found", "disabled: invalid hook argument",
        "disabled: invalid Mach-O header", "disabled: unknown renderer UUID",
        "disabled: renderer layout mismatch", "disabled: renderer original bytes mismatch",
        "disabled: free import already interposed", "disabled: unsafe import-page protection",
        "disabled: import page cannot be made writable", "disabled: free import changed during installation",
        "disabled: import-page protection could not be restored",
        "disabled: previous publication cannot be retried", "rejected: different hook already installed",
        "disabled: DXMT build not verified", "ready: guarded free-hook preflight only",
        "fatal: free-hook protection or rollback incomplete; refuse backend devices"
    };
    /* A concurrent read-only identity failure must never hide a fatal installer
     * state, even if it passed failure()'s flag check just before publication. */
    int status=atomic_load_explicit(&hook_fatal,memory_order_acquire)?HOOK_FATAL:
        atomic_load_explicit(&hook_status,memory_order_relaxed);
    return messages[status];
}

static int failure(enum HookStatus status)
{
    if (!atomic_load_explicit(&hook_fatal,memory_order_acquire))
        atomic_store_explicit(&hook_status, status, memory_order_relaxed);
    return 0;
}

static int fatal(void)
{
    atomic_store_explicit(&hook_status,HOOK_FATAL,memory_order_relaxed);
    atomic_store_explicit(&hook_fatal,true,memory_order_release);
    return -1;
}

static bool region(uintptr_t address, size_t length, vm_prot_t *protection)
{
    if (!length || address > UINTPTR_MAX - length)
        return false;
    vm_address_t start = (vm_address_t)address;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = vm_region_64(mach_task_self(), &start, &size,
                                        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
                                        &count, &object);
    if (object != MACH_PORT_NULL)
        mach_port_deallocate(mach_task_self(), object);
    if (result != KERN_SUCCESS || start > address || size < length ||
        address - start > size - length)
        return false;
    *protection = info.protection;
    return true;
}

static bool readable(uintptr_t address, size_t length)
{
    vm_prot_t protection;
    return region(address, length, &protection) && (protection & VM_PROT_READ);
}

static bool name_is(const char name[16], const char *expected)
{
    return strncmp(name, expected, 16) == 0;
}

static bool geometry(const struct segment_command_64 *s, uint64_t addr, uint64_t size,
                     vm_prot_t protection)
{
    return s->vmaddr == addr && s->vmsize == size && s->fileoff == addr &&
           s->filesize == size && s->maxprot == protection && s->initprot == protection;
}

static bool dxmt_image(const struct mach_header_64 *mh)
{
    uintptr_t base = (uintptr_t)mh;
    if (!readable(base, sizeof(*mh)) || mh->magic != MH_MAGIC_64 ||
        mh->cputype != CPU_TYPE_ARM64 || mh->cpusubtype != CPU_SUBTYPE_ARM64_ALL ||
        mh->filetype != MH_DYLIB || mh->sizeofcmds > 0x10000u ||
        mh->ncmds > mh->sizeofcmds / sizeof(struct load_command) ||
        !readable(base, sizeof(*mh) + mh->sizeofcmds))
        return false;
    const uint8_t *next = (const void *)(mh + 1);
    const uint8_t *end = next + mh->sizeofcmds;
    bool uuid = false, text = false;
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        if ((size_t)(end - next) < sizeof(struct load_command))
            return false;
        const struct load_command *lc = (const void *)next;
        if (lc->cmdsize < sizeof(*lc) || lc->cmdsize % 8 || lc->cmdsize > (size_t)(end - next))
            return false;
        if (lc->cmd == LC_UUID) {
            if (uuid || lc->cmdsize != sizeof(struct uuid_command) ||
                memcmp(((const struct uuid_command *)lc)->uuid, hv_npt_dxmt_uuid, 16))
                return false;
            uuid = true;
        } else if (lc->cmd == LC_SEGMENT_64) {
            if (lc->cmdsize < sizeof(struct segment_command_64))
                return false;
            const struct segment_command_64 *s = (const void *)lc;
            if (s->nsects > (lc->cmdsize - sizeof(*s)) / sizeof(struct section_64) ||
                lc->cmdsize != sizeof(*s) + s->nsects * sizeof(struct section_64))
                return false;
            if (name_is(s->segname, "__TEXT")) {
                if (text || !geometry(s, 0, 0x13c4000, 5))
                    return false;
                text = true;
            }
        }
        next += lc->cmdsize;
    }
    return next == end && uuid && text && base <= UINTPTR_MAX - HV_NPT_DXMT_CREATE_ADDRESS &&
           readable(base + HV_NPT_DXMT_CREATE_ADDRESS, sizeof(hv_npt_dxmt_create_bytes)) &&
           !memcmp((const void *)(base + HV_NPT_DXMT_CREATE_ADDRESS), hv_npt_dxmt_create_bytes,
                   sizeof(hv_npt_dxmt_create_bytes));
}

int hv_npt_check_dxmt(void *create_device)
{
    Dl_info info;
    if (!create_device || !dladdr(create_device, &info) || !dxmt_image(info.dli_fbase) ||
        (uintptr_t)create_device - (uintptr_t)info.dli_fbase != HV_NPT_DXMT_CREATE_ADDRESS)
        return failure(HOOK_BAD_DXMT);
    bool loaded = false;
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        if (_dyld_get_image_header(i) == info.dli_fbase &&
            (uintptr_t)_dyld_get_image_vmaddr_slide(i) == (uintptr_t)info.dli_fbase) {
            loaded = true;
            break;
        }
    }
    if (!loaded)
        return failure(HOOK_BAD_DXMT);
    uintptr_t image = (uintptr_t)info.dli_fbase, expected = 0;
    if (!atomic_compare_exchange_strong_explicit(&trusted_dxmt_image, &expected, image,
                                                 memory_order_acq_rel, memory_order_acquire) && expected != image)
        return failure(HOOK_BAD_DXMT);
    return 1;
}

static int read_parent_at(uintptr_t image, uintptr_t method, uintptr_t child, void **raw_device)
{
    if (method < image)
        return 0;
    const struct HvNptParentMethod *found = NULL;
    for (size_t i = 0; i < sizeof(hv_npt_parent_methods) / sizeof(hv_npt_parent_methods[0]); ++i) {
        if (method - image == hv_npt_parent_methods[i].address) {
            found = &hv_npt_parent_methods[i];
            break;
        }
    }
    if (!found || !readable(method, 56) ||
        memcmp((const void *)method, hv_npt_get_device_prefix, sizeof(hv_npt_get_device_prefix)) ||
        memcmp((const void *)(method + 20), hv_npt_get_device_suffix, sizeof(hv_npt_get_device_suffix)))
        return 0;
    uint32_t load;
    memcpy(&load, (const void *)(method + 16), sizeof(load));
    uint32_t expected = 0xf9400014u | (uint32_t)((found->parent_offset / 8) << 10);
    if (load != expected || child > UINTPTR_MAX - found->parent_offset ||
        !readable(child + found->parent_offset, sizeof(void *)))
        return 0;
    memcpy(raw_device, (const void *)(child + found->parent_offset), sizeof(void *));
    return 1;
}

int hv_npt_read_child_parent(void *child, void **raw_device)
{
    if (!raw_device)
        return 0;
    *raw_device = NULL;
    uintptr_t object = (uintptr_t)child, vtable, method;
    if (!readable(object, sizeof(vtable)))
        return 0;
    memcpy(&vtable, child, sizeof(vtable));
    if (vtable > UINTPTR_MAX - 3 * sizeof(void *) ||
        !readable(vtable + 3 * sizeof(void *), sizeof(method)))
        return 0;
    memcpy(&method, (const void *)(vtable + 3 * sizeof(void *)), sizeof(method));
    uintptr_t image = atomic_load_explicit(&trusted_dxmt_image, memory_order_acquire);
    if (!image) {
        Dl_info info;
        if (!dladdr((const void *)method, &info) || !dxmt_image(info.dli_fbase))
            return 0;
        bool loaded = false;
        for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
            if (_dyld_get_image_header(i) == info.dli_fbase &&
                (uintptr_t)_dyld_get_image_vmaddr_slide(i) == (uintptr_t)info.dli_fbase) {
                loaded = true;
                break;
            }
        }
        if (!loaded)
            return 0;
        image = (uintptr_t)info.dli_fbase;
        uintptr_t expected = 0;
        if (!atomic_compare_exchange_strong_explicit(&trusted_dxmt_image, &expected, image,
                                                     memory_order_acq_rel, memory_order_acquire))
            image = expected;
    }
    return read_parent_at(image, method, object, raw_device);
}

static enum HookStatus validate_image(const struct mach_header_64 *mh, intptr_t slide)
{
    uintptr_t base = (uintptr_t)mh;
    if (!readable(base, sizeof(*mh)) || mh->magic != MH_MAGIC_64 ||
        mh->cputype != CPU_TYPE_ARM64 || mh->cpusubtype != CPU_SUBTYPE_ARM64_ALL ||
        mh->filetype != MH_DYLIB || mh->sizeofcmds > 0x10000u ||
        mh->ncmds > mh->sizeofcmds / sizeof(struct load_command) ||
        !readable(base, sizeof(*mh) + mh->sizeofcmds))
        return HOOK_BAD_HEADER;
    /* This image's __TEXT VM address is zero, so slide must equal its header. */
    if ((uintptr_t)slide != base || base > UINTPTR_MAX - 0x3f4000u)
        return HOOK_BAD_LAYOUT;
    const uint8_t *next = (const void *)(mh + 1);
    const uint8_t *end = next + mh->sizeofcmds;
    bool found_uuid = false, found_text = false, found_const = false, found_got = false;
    for (uint32_t i = 0; i < mh->ncmds; ++i) {
        if ((size_t)(end - next) < sizeof(struct load_command))
            return HOOK_BAD_HEADER;
        const struct load_command *lc = (const void *)next;
        if (lc->cmdsize < sizeof(*lc) || lc->cmdsize % 8 || lc->cmdsize > (size_t)(end - next))
            return HOOK_BAD_HEADER;
        if (lc->cmd == LC_UUID) {
            if (found_uuid || lc->cmdsize != sizeof(struct uuid_command))
                return HOOK_BAD_HEADER;
            const struct uuid_command *u = (const void *)lc;
            if (memcmp(u->uuid, hv_npt_hook_uuid, sizeof(u->uuid)))
                return HOOK_BAD_UUID;
            found_uuid = true;
        } else if (lc->cmd == LC_SEGMENT_64) {
            if (lc->cmdsize < sizeof(struct segment_command_64))
                return HOOK_BAD_HEADER;
            const struct segment_command_64 *s = (const void *)lc;
            if (s->nsects > (lc->cmdsize - sizeof(*s)) / sizeof(struct section_64) ||
                lc->cmdsize != sizeof(*s) + s->nsects * sizeof(struct section_64))
                return HOOK_BAD_HEADER;
            bool text = name_is(s->segname, "__TEXT"), data = name_is(s->segname, "__DATA_CONST");
            if (text || data) {
                if ((text && (found_text || !geometry(s, 0, HV_NPT_HOOK_TEXT_SIZE, 5))) ||
                    (data && (found_const || !geometry(s, 0x3e0000, 0x14000, 3))))
                    return HOOK_BAD_LAYOUT;
                uint64_t last = 0;
                const struct section_64 *sec = (const void *)(s + 1);
                for (uint32_t j = 0; j < s->nsects; ++j, ++sec) {
                    if (memcmp(sec->segname, s->segname, 16) || sec->addr != sec->offset ||
                        sec->addr < s->vmaddr || sec->size > s->filesize ||
                        sec->addr - s->vmaddr > s->filesize - sec->size)
                        return HOOK_BAD_LAYOUT;
                    if (sec->addr + sec->size > last)
                        last = sec->addr + sec->size;
                    if (name_is(sec->sectname, "__got")) {
                        if (!data || found_got || sec->addr != 0x3f3020 || sec->size != 0xcd8 ||
                            sec->flags != S_NON_LAZY_SYMBOL_POINTERS || sec->reserved1 != 124)
                            return HOOK_BAD_LAYOUT;
                        found_got = true;
                    }
                }
                if (text && last != HV_NPT_HOOK_TEXT_SECTION_END)
                    return HOOK_BAD_LAYOUT;
                found_text |= text;
                found_const |= data;
            }
        }
        next += lc->cmdsize;
    }
    if (next != end || !found_uuid)
        return HOOK_BAD_UUID;
    if (!found_text || !found_const || !found_got)
        return HOOK_BAD_LAYOUT;
    for (size_t i = 0; i < sizeof(hv_npt_hook_guards) / sizeof(hv_npt_hook_guards[0]); ++i) {
        const struct HvNptHookGuard *g = &hv_npt_hook_guards[i];
        if (g->offset > HV_NPT_HOOK_TEXT_SIZE || g->size > HV_NPT_HOOK_TEXT_SIZE - g->offset ||
            !readable(base + g->offset, g->size) ||
            memcmp((const void *)(base + g->offset), g->bytes, g->size))
            return HOOK_BAD_CODE;
    }
    return HOOK_NOT_INSTALLED;
}

static int configure_image(const struct mach_header_64 *mh, intptr_t slide,
                           void (*capture)(void *), void (*submit)(void), uintptr_t expected_free,
                           bool dry_run)
{
    if (atomic_load_explicit(&hook_fatal,memory_order_acquire)) return -1;
    enum HookStatus check = validate_image(mh, slide);
    if (check != HOOK_NOT_INSTALLED)
        return failure(check);
    uintptr_t base = (uintptr_t)mh;
    uintptr_t *slot = (void *)(base + HV_NPT_HOOK_FREE_SLOT);
    if (installed) {
        if (hook_state.image == base && hook_state.capture == capture && hook_state.submit == submit &&
            __atomic_load_n(slot, __ATOMIC_ACQUIRE) == (uintptr_t)npt_free_hook) {
            atomic_store_explicit(&hook_status, HOOK_INSTALLED, memory_order_relaxed);
            return 1;
        }
        return failure(HOOK_ALREADY_DIFFERENT);
    }
    if (atomic_load_explicit(&published, memory_order_acquire))
        return failure(HOOK_RETRY_REJECTED);
    vm_address_t page = (vm_address_t)slot & ~(vm_address_t)(vm_page_size - 1);
    vm_prot_t old_protection;
    if (!region(page, vm_page_size, &old_protection) || !(old_protection & VM_PROT_READ) ||
        (old_protection & VM_PROT_EXECUTE))
        return failure(HOOK_BAD_PROTECTION);
    if (__atomic_load_n(slot, __ATOMIC_ACQUIRE) != expected_free)
        return failure(HOOK_BAD_IMPORT);
    if (vm_protect(mach_task_self(), page, vm_page_size, FALSE,
                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
        return failure(HOOK_PROTECT_FAILED);
    if (dry_run) {
        /* Exercise page permission changes before any DXMT data slots change.
         * Never publish callback state or replace the free import here. */
        if (vm_protect(mach_task_self(),page,vm_page_size,FALSE,old_protection)!=KERN_SUCCESS) {
            if (vm_protect(mach_task_self(),page,vm_page_size,FALSE,old_protection)!=KERN_SUCCESS)
                return fatal();
            return failure(HOOK_RESTORE_FAILED);
        }
        if (__atomic_load_n(slot,__ATOMIC_ACQUIRE)!=expected_free)
            return failure(HOOK_BAD_IMPORT);
        atomic_store_explicit(&hook_status,HOOK_PREFLIGHT_READY,memory_order_relaxed);
        return 1;
    }
    hook_state = (struct HookState){base, base + HV_NPT_HOOK_FREE_RETURN,
                                   base + HV_NPT_HOOK_FINISH_RETURN, (uintptr_t)slot, capture, submit};
    atomic_store_explicit(&published, &hook_state, memory_order_release);
    uintptr_t expected = expected_free;
    bool bound = __atomic_compare_exchange_n(slot, &expected, (uintptr_t)npt_free_hook, false,
                                             __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
    if (vm_protect(mach_task_self(), page, vm_page_size, FALSE, old_protection) != KERN_SUCCESS) {
        /* State remains alive if a thread already loaded our hook. No immediate
         * cleanup is attempted here, even when the import is rolled back. */
        bool rolled_back=true;
        if (bound) {
            expected = (uintptr_t)npt_free_hook;
            rolled_back=__atomic_compare_exchange_n(slot, &expected, expected_free, false,
                                                     __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
        }
        bool protected_again=vm_protect(mach_task_self(), page, vm_page_size, FALSE,
                                        old_protection)==KERN_SUCCESS;
        if (!rolled_back || !protected_again) return fatal();
        return failure(HOOK_RESTORE_FAILED);
    }
    if (!bound)
        return failure(HOOK_BIND_RACE);
    installed = true;
    atomic_store_explicit(&hook_status, HOOK_INSTALLED, memory_order_relaxed);
    return 1;
}

static int configure_free_hook(void *virgl_symbol,void (*capture)(void *),void (*submit)(void),
                               bool dry_run)
{
    if (!virgl_symbol || !capture || !submit)
        return failure(HOOK_BAD_ARGUMENT);
    if (!dry_run && !atomic_load_explicit(&trusted_dxmt_image, memory_order_acquire))
        return failure(HOOK_BAD_DXMT);
    Dl_info info;
    if (!dladdr(virgl_symbol, &info))
        return failure(HOOK_NO_IMAGE);
    const struct mach_header_64 *mh = NULL;
    intptr_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        if (_dyld_get_image_header(i) == info.dli_fbase) {
            mh = (const void *)info.dli_fbase;
            slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    if (!mh)
        return failure(HOOK_NO_IMAGE);
    /* Resolve libc independently of this image's import and refuse an existing
     * free interposer. The hot path still calls app/libc free directly. */
    void *malloc_library = dlopen("/usr/lib/system/libsystem_malloc.dylib", RTLD_NOW | RTLD_LOCAL);
    void *libc_free = malloc_library ? dlsym(malloc_library, "free") : NULL;
    bool canonical = libc_free && libc_free == (void *)free;
    if (malloc_library)
        dlclose(malloc_library);
    if (!canonical)
        return failure(HOOK_BAD_IMPORT);
    return configure_image(mh,slide,capture,submit,(uintptr_t)libc_free,dry_run);
}

static int guarded_request(void *symbol,void (*capture)(void *),void (*submit)(void),bool dry_run)
{
    pthread_mutex_lock(&install_mutex);
    int result=atomic_load_explicit(&hook_fatal,memory_order_acquire)?-1:
        configure_free_hook(symbol,capture,submit,dry_run);
    pthread_mutex_unlock(&install_mutex);
    return result;
}
int hv_npt_preflight_free_hook(void *symbol,void (*capture)(void *),void (*submit)(void))
{ return guarded_request(symbol,capture,submit,true); }
int hv_npt_install_free_hook(void *symbol,void (*capture)(void *),void (*submit)(void))
{ return guarded_request(symbol,capture,submit,false); }
