/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Pinned DXMT data-only lifetime interception. Install before creating devices.
 * QI contains an inlined AddRef, so all three IUnknown slots must participate. */
#include "neptune_device.h"
#include "dxmt_data_lock.h"
#include "neptune_device_layout.h"
#include "neptune_hook.h"
#include "neptune_cleanup.h"
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

static _Atomic(uintptr_t) device_image;
static _Atomic(const char *) device_status = "not installed";
static _Atomic bool device_fatal;
static bool device_installed, device_creation_started;
static struct {
    int32_t (*query)(void *, const void *, void **);
    int32_t (*event_value)(void *);
    int32_t (*pool)(void *), (*retain)(void *), (*release)(void *);
    int32_t (*command_buffer)(void *), (*commit)(void *), (*status)(void *);
    void (*destroy)(void *);
} device_calls; /* Immutable before device_image release publication. */

const char *hv_npt_device_hook_status(void)
{
    return atomic_load_explicit(&device_status, memory_order_acquire);
}
static int reject(const char *reason)
{
    atomic_store_explicit(&device_status, reason, memory_order_release);
    return 0;
}
static bool device_region(uintptr_t address, size_t length, vm_prot_t *protection)
{
    if (!length || address > UINTPTR_MAX - length) return false;
    vm_address_t start = address;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = vm_region_64(mach_task_self(), &start, &size,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (result != KERN_SUCCESS || start > address || size < length || address-start > size-length)
        return false;
    *protection = info.protection;
    return true;
}
static bool device_readable(uintptr_t p, size_t n)
{
    vm_prot_t protection;
    return device_region(p, n, &protection) && (protection & VM_PROT_READ);
}
static bool device_validate(uintptr_t base)
{
    const struct mach_header_64 *mh = (const void *)base;
    if (base > UINTPTR_MAX-0x142c000 || !device_readable(base, sizeof(*mh)) ||
        mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_ARM64 ||
        mh->cpusubtype != CPU_SUBTYPE_ARM64_ALL || mh->filetype != MH_DYLIB ||
        mh->sizeofcmds > 0x10000 || mh->ncmds > mh->sizeofcmds/8 ||
        !device_readable(base, sizeof(*mh)+mh->sizeofcmds)) return false;
    const uint8_t *p=(const void *)(mh+1), *end=p+mh->sizeofcmds;
    bool uuid=false, text=false, data=false;
    for (uint32_t i=0; i<mh->ncmds; ++i) {
        if ((size_t)(end-p)<8) return false;
        const struct load_command *lc=(const void *)p;
        if (lc->cmdsize<8 || lc->cmdsize%8 || lc->cmdsize>(size_t)(end-p)) return false;
        if (lc->cmd==LC_UUID) {
            if (uuid || lc->cmdsize!=sizeof(struct uuid_command) ||
                memcmp(((const struct uuid_command *)lc)->uuid,hv_npt_device_uuid,16)) return false;
            uuid=true;
        } else if (lc->cmd==LC_SEGMENT_64) {
            if (lc->cmdsize<sizeof(struct segment_command_64)) return false;
            const struct segment_command_64 *s=(const void *)lc;
            if (s->nsects>(lc->cmdsize-sizeof(*s))/sizeof(struct section_64) ||
                lc->cmdsize!=sizeof(*s)+s->nsects*sizeof(struct section_64)) return false;
            bool is_text=!strncmp(s->segname,"__TEXT",16);
            bool is_data=!strncmp(s->segname,"__DATA_CONST",16);
            if (is_text || is_data) {
                uint64_t addr=is_text?0:0x13c4000, size=is_text?0x13c4000:0x68000;
                vm_prot_t prot=is_text?5:3;
                if ((is_text?text:data) || s->vmaddr!=addr || s->fileoff!=addr ||
                    s->vmsize!=size || s->filesize!=size || s->maxprot!=prot || s->initprot!=prot)
                    return false;
                text|=is_text; data|=is_data;
            }
        }
        p+=lc->cmdsize;
    }
    if (p!=end || !uuid || !text || !data || !device_readable(base,0x13c4000)) return false;
    for (size_t i=0;i<sizeof(hv_npt_device_guards)/sizeof(hv_npt_device_guards[0]);++i) {
        const struct HvNptDeviceGuard *g=&hv_npt_device_guards[i];
        if (g->offset>0x13c4000 || g->size>0x13c4000-g->offset ||
            memcmp((const void *)(base+g->offset),g->bytes,g->size)) return false;
    }
    /* No immediate branch may bypass these data slots. All internal branches
     * inside QI/AddRef/Release target interior instructions, not their entries. */
    for (size_t pc=0x4000;pc<0x12283ac;pc+=4) {
        uint32_t ins; memcpy(&ins,(const void *)(base+pc),4);
        if ((ins&0x7c000000u)==0x14000000u) {
            int64_t delta=(int32_t)(ins<<6)>>6;
            int64_t target=(int64_t)pc+delta*4;
            for (size_t j=0;j<3;++j) if (target==(int64_t)hv_npt_device_targets[j]) return false;
        }
    }
    uintptr_t dtor;
    if (!device_readable(base+HV_NPT_DEVICE_VTABLE,0xb8)) return false;
    memcpy(&dtor,(const void *)(base+HV_NPT_DEVICE_VTABLE+0xb0),8);
    return dtor==base+HV_NPT_DEVICE_DTOR;
}

static int device_snapshot(void *device, struct HvNptDeviceSnapshot *out)
{
    /* The lifecycle mutex and deferred private reference protect these fields.
     * No kernel, COM, Metal or driver call belongs in this snapshot. */
    uintptr_t base=atomic_load_explicit(&device_image,memory_order_acquire), vtable, queue;
    if (!base || !device || !out) return 0;
    memcpy(&vtable,device,8);
    if (vtable!=base+HV_NPT_DEVICE_VTABLE) return 0;
    memcpy(&queue,(const uint8_t *)device+0x40,8);
    if (!queue || queue%8) return 0;
    uint64_t next=__atomic_load_n((uint64_t *)queue,__ATOMIC_ACQUIRE), seq;
    out->main_done=__atomic_load_n((uint64_t *)(queue+0x18),__ATOMIC_ACQUIRE);
    memcpy(&seq,(const void *)(queue+0x10008),8);
    memcpy(&out->event,(const void *)(queue+0x10028),8);
    memcpy(&out->initializer_queue,(const void *)(queue+0x10020),8);
    if (!next || !seq || (seq>1 && (!out->event || !out->initializer_queue))) return 0;
    out->main_goal=next-1;
    out->initializer_goal=seq-1;
    return 1;
}
static int device_event_value(void *event, uint64_t *out)
{
    uintptr_t base=atomic_load_explicit(&device_image,memory_order_acquire);
    if (!base || !event || !out) return 0;
    /* Native bridge ABI: the event object and returned uint64 share an argument
     * structure. Call the exact native bridge, avoiding its mutable dispatch table. */
    struct {void *event; uint64_t value;} args={event,0};
    if (device_calls.event_value(&args)) return 0;
    *out=args.value;
    return 1;
}
static void *device_barrier_begin(void *queue)
{
    if (!atomic_load_explicit(&device_image,memory_order_acquire) || !queue ||
        !hv_npt_cleanup_gpu_allowed()) return NULL;
    void *pool=NULL;
    device_calls.pool(&pool);
    if (!pool) return NULL;
    struct {void *queue, *buffer;} args={queue,NULL};
    if (hv_npt_cleanup_gpu_allowed()) device_calls.command_buffer(&args);
    if (args.buffer) {
        /* commandBuffer is autoreleased. Keep one explicit ticket reference
         * across nonblocking polls; no DXMT resource is encoded or flushed. */
        device_calls.retain(&args.buffer);
        if (hv_npt_cleanup_gpu_allowed()) device_calls.commit(&args.buffer);
        else {
            /* The factory may have blocked across background entry. Release
             * the uncommitted ticket; never issue a new commit while paused. */
            device_calls.release(&args.buffer);
            args.buffer=NULL;
        }
    }
    device_calls.release(&pool);
    return args.buffer;
}
static int device_barrier_status(void *ticket)
{
    if (!atomic_load_explicit(&device_image,memory_order_acquire) || !ticket) return -1;
    struct {void *buffer; uint64_t status;} args={ticket,0};
    if (device_calls.status(&args)) return -1;
    /* A newly rejected/error command may finish before earlier work. Only
     * Completed proves execution after earlier buffers on this same queue. */
    return args.status==4 ? 1 : args.status==5 ? -1 : 0;
}
static void device_barrier_release(void *ticket)
{
    if (ticket) device_calls.release(&ticket);
}
_Static_assert(sizeof(pthread_t)==8 && sizeof(pthread_mutex_t)==64 && sizeof(pthread_cond_t)==48,
    "pinned DXMT native pthread ABI required");

static int stop_compiler(void *device, uintptr_t base)
{
    uintptr_t cache, vtable, begin, end, capacity;
    memcpy(&cache,(const uint8_t *)device+0x2a0,8);
    if (!cache) return 1; /* Partially constructed device has no compiler. */
    memcpy(&vtable,(const void *)cache,8);
    if (vtable!=base+0x13cae88u) return 0;
    uint8_t *scheduler=(void *)(cache+0x10);
    memcpy(&begin,scheduler+0x138,8);
    memcpy(&end,scheduler+0x140,8);
    memcpy(&capacity,scheduler+0x148,8);
    if ((!begin && (end || capacity)) || begin%8 || capacity%8 || end<begin ||
        capacity<end || (end-begin)%8 || (end-begin)/8>4096)
        return 0;
    /* submit() can grow/reallocate the workers vector, but only CPU pipeline
     * creation calls it; no valid API producer remains at the final private
     * reference decision. Worker continuations push the internal deque directly
     * and never call submit(), so this snapshot is stable during stop/join.
     * Holding the native worker mutex across stop publication prevents a lost
     * wake between the wait predicate and pthread_cond_wait. */
    pthread_mutex_t *mutex=(void *)scheduler;
    if (pthread_mutex_lock(mutex)) return 0;
    __atomic_store_n(scheduler+0x150,1,__ATOMIC_SEQ_CST);
    if (pthread_mutex_unlock(mutex)) return 0;
    if (pthread_cond_broadcast((void *)(scheduler+0x40))) return 0;
    for (uintptr_t entry=begin;entry<end;entry+=8) {
        pthread_t thread;
        memcpy(&thread,(const void *)entry,8);
        if (!thread) continue;
        if (pthread_join(thread,NULL)) return 0;
        memset((void *)entry,0,8); /* std::thread is now nonjoinable. */
    }
    /* Original scheduler destructor later clears/destroys all native objects
     * once. We have only stopped and joined; shader and PSO maps still exist. */
    return 1;
}
static int device_destroy(void *device)
{
    uintptr_t base=atomic_load_explicit(&device_image,memory_order_acquire);
    if (!stop_compiler(device,base)) return 0;
    device_calls.destroy(device);
    return 1;
}
static int32_t device_query_interface(void *device,const void *iid,void **out)
{
    (void)atomic_load_explicit(&device_image,memory_order_acquire);
    return device_calls.query(device,iid,out);
}
static const struct HvNptDeviceOps device_ops={
    .snapshot=device_snapshot,.event_value=device_event_value,.destroy=device_destroy,
    .barrier_begin=device_barrier_begin,.barrier_status=device_barrier_status,
    .barrier_release=device_barrier_release,
    .query_interface=device_query_interface
};

static int install_device_image(uintptr_t base)
{
    if (atomic_load_explicit(&device_fatal,memory_order_acquire)) return -1;
    if (!device_validate(base)) return reject("disabled: DXMT device guards mismatch");
    uintptr_t *slots=(void *)(base+HV_NPT_DEVICE_VTABLE);
    const uintptr_t hooks[3]={(uintptr_t)hv_npt_device_query_interface,
        (uintptr_t)hv_npt_device_addref,(uintptr_t)hv_npt_device_release};
    if (device_installed) {
        if (base!=atomic_load(&device_image)) return reject("rejected: different DXMT image");
        for (size_t i=0;i<3;++i)
            if (__atomic_load_n(slots+i,__ATOMIC_ACQUIRE)!=hooks[i])
                return reject("rejected: installed DXMT slots changed");
        return 1;
    }
    if (device_creation_started) return reject("disabled: backend creation already started");
    if (atomic_load(&device_image)) return reject("disabled: previous device publication cannot retry");
    for (size_t i=0;i<3;++i)
        if (__atomic_load_n(slots+i,__ATOMIC_ACQUIRE)!=base+hv_npt_device_targets[i])
            return reject("disabled: DXMT lifetime slots already interposed");
    vm_address_t page=(uintptr_t)slots&~(uintptr_t)(vm_page_size-1);
    vm_prot_t protection;
    if (!device_region(page,vm_page_size,&protection) || !(protection&VM_PROT_READ) ||
        (protection&VM_PROT_EXECUTE)) return reject("disabled: unsafe DXMT vtable protection");
    if (vm_protect(mach_task_self(),page,vm_page_size,FALSE,
        VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)!=KERN_SUCCESS)
        return reject("disabled: DXMT vtable cannot be made writable");
    /* Callback state is ready before any slot becomes reachable. Installation
     * is explicitly before the first device; no live thread may consume a
     * partially installed vtable. On failure all slots we own are rolled back. */
    device_calls.query=(void *)(base+hv_npt_device_targets[0]);
    device_calls.event_value=(void *)(base+HV_NPT_DEVICE_EVENT);
    device_calls.pool=(void *)(base+HV_NPT_DEVICE_POOL);
    device_calls.retain=(void *)(base+HV_NPT_DEVICE_RETAIN);
    device_calls.release=(void *)(base+HV_NPT_DEVICE_RELEASE);
    device_calls.command_buffer=(void *)(base+HV_NPT_DEVICE_COMMAND_BUFFER);
    device_calls.commit=(void *)(base+HV_NPT_DEVICE_COMMIT);
    device_calls.status=(void *)(base+HV_NPT_DEVICE_STATUS);
    device_calls.destroy=(void *)(base+HV_NPT_DEVICE_DTOR);
    atomic_store_explicit(&device_image,base,memory_order_release);
    size_t bound=0;
    bool ready=hv_npt_cleanup_set_device_ops(&device_ops)!=0;
    if (ready) for (;bound<3;++bound) {
        uintptr_t expected=base+hv_npt_device_targets[bound];
        if (!__atomic_compare_exchange_n(slots+bound,&expected,hooks[bound],false,
            __ATOMIC_RELEASE,__ATOMIC_ACQUIRE)) break;
    }
    bool restored=vm_protect(mach_task_self(),page,vm_page_size,FALSE,protection)==KERN_SUCCESS;
    if (!ready || bound!=3 || !restored) {
        /* Failed protection restore leaves the page writable. If it succeeded,
         * regain write access before undoing a partial CAS transaction. */
        bool writable=!restored || vm_protect(mach_task_self(),page,vm_page_size,FALSE,
            VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)==KERN_SUCCESS;
        bool rolled_back=writable;
        if (writable) for (size_t i=0;i<bound;++i) {
            uintptr_t expected=hooks[i];
            if (!__atomic_compare_exchange_n(slots+i,&expected,base+hv_npt_device_targets[i],false,
                __ATOMIC_RELEASE,__ATOMIC_ACQUIRE)) rolled_back=false;
        }
        bool protected_again=vm_protect(mach_task_self(),page,vm_page_size,FALSE,protection)==KERN_SUCCESS;
        if (!rolled_back || !protected_again) {
            reject("fatal: DXMT hook rollback incomplete; do not create backend devices");
            atomic_store_explicit(&device_fatal,true,memory_order_release);
            return -1;
        }
        return reject("disabled: DXMT lifetime transaction rolled back");
    }
    device_installed=true;
    atomic_store_explicit(&device_status,"installed: guarded QI/AddRef/Release retirement",memory_order_release);
    return 1;
}

int hv_npt_install_device_hooks(void *create_device)
{
    /* A previous partial transaction poisons this process, including calls
     * whose new symbol fails identity checks. Never downgrade fatal to off. */
    hv_dxmt_data_lock();
    int result=-1;
    if (!atomic_load_explicit(&device_fatal,memory_order_acquire)) {
        Dl_info info;
        if (!hv_npt_check_dxmt(create_device)) result=reject("disabled: DXMT identity unknown");
        else if (!dladdr(create_device,&info)) result=reject("disabled: DXMT image unavailable");
        else result=install_device_image((uintptr_t)info.dli_fbase);
    }
    hv_dxmt_data_unlock();
    return result;
}

void hv_npt_device_hooks_mark_used(void)
{
    hv_dxmt_data_lock();
    device_creation_started = true;
    hv_dxmt_data_unlock();
}

int hv_npt_rollback_device_hooks(void)
{
    hv_dxmt_data_lock();
    int result = -1;
    if (atomic_load_explicit(&device_fatal, memory_order_acquire)) goto done;
    if (!device_installed) { result = 1; goto done; }
    if (device_creation_started) {
        reject("refused: lifetime hooks must remain after backend creation started");
        result = 0;
        goto done;
    }
    uintptr_t base = atomic_load_explicit(&device_image, memory_order_acquire);
    uintptr_t *slots = (void *)(base + HV_NPT_DEVICE_VTABLE);
    const uintptr_t hooks[3] = {(uintptr_t)hv_npt_device_query_interface,
        (uintptr_t)hv_npt_device_addref, (uintptr_t)hv_npt_device_release};
    vm_address_t page = (uintptr_t)slots & ~(uintptr_t)(vm_page_size - 1);
    vm_prot_t protection;
    if (!device_region(page, vm_page_size, &protection) || !(protection & VM_PROT_READ) ||
        (protection & VM_PROT_EXECUTE) || vm_protect(mach_task_self(), page, vm_page_size, FALSE,
            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) goto fatal;
    bool restored = true;
    for (size_t i = 0; i < 3; ++i) {
        uintptr_t expected = hooks[i];
        if (!__atomic_compare_exchange_n(slots + i, &expected, base + hv_npt_device_targets[i], false,
                __ATOMIC_RELEASE, __ATOMIC_ACQUIRE)) restored = false;
    }
    if (vm_protect(mach_task_self(), page, vm_page_size, FALSE, protection) != KERN_SUCCESS)
        restored = false;
    if (!restored) goto fatal;
    device_installed = false;
    /* Keep callback publication immutable and prevent later reinstall. This
     * operation is allowed only before backend creation, so no deferred device
     * can refer to it. Original COM behavior is used for this process. */
    reject("disabled: DXMT lifetime hooks restored after capture-hook refusal");
    result = 1;
    goto done;
fatal:
    atomic_store_explicit(&device_fatal, true, memory_order_release);
    reject("fatal: DXMT lifetime hook removal incomplete; refuse backend devices");
done:
    hv_dxmt_data_unlock();
    return result;
}
