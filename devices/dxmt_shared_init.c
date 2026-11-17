/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Opt-in, pinned native shared-texture initialization boundary. Data slots only. */
#include "dxmt_shared_init.h"
#include "dxmt_shared_init_layout.h"
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static pthread_mutex_t shared_install_mutex=PTHREAD_MUTEX_INITIALIZER;
static _Atomic(uintptr_t) shared_image;
static _Atomic(const char *) shared_status="disabled: HV_DXMT_SHARED_INIT is opt-in";
static _Atomic bool shared_fatal;
static bool shared_installed;
/* Every lifecycle transition changes the token, including off -> on between
 * polls. GPU permission and drain are independent, so clearing one cannot
 * override the other. Redundant setter calls leave the token unchanged.
 * This is a cooperative gate, not a replacement for the host GPU drain barrier. */
static _Atomic uint64_t gpu_token=1; /* allowed, not draining: initial foreground */
static _Atomic uint64_t waits, skipped, quarantined, flushes;
static _Atomic bool foreground_failed;
static pthread_mutex_t stage_mutex=PTHREAD_MUTEX_INITIALIZER;
static uint64_t active_flush, flush_busy_since;
static _Atomic uint64_t active_poll;
static struct {
    int32_t (*create[2])(void *, const void *, const void *, void **);
    uint64_t (*flush)(void *);
    int32_t (*event_value)(void *);
    uint32_t (*addref)(void *);
} shared_calls; /* Immutable before any data slot is published. */

const char *hv_dxmt_shared_init_status(void)
{ return atomic_load_explicit(&shared_status,memory_order_acquire); }
static void set_gate_bit(uint64_t bit,int on)
{
    uint64_t old=atomic_load_explicit(&gpu_token,memory_order_acquire), next;
    do {
        if (!!(old&bit)==!!on) return;
        next=((old+4)&~UINT64_C(3)) | ((old&3)&~bit) | (on?bit:0);
    } while (!atomic_compare_exchange_weak_explicit(&gpu_token,&old,next,
        memory_order_acq_rel,memory_order_acquire));
}
void hv_dxmt_shared_init_set_gpu_allowed(int allowed) {set_gate_bit(1,allowed);}
void hv_dxmt_shared_init_set_draining(int draining) {set_gate_bit(2,draining);}
static bool gate_allowed(uint64_t token) {return (token&3)==1;}
static int reject(const char *reason)
{ atomic_store_explicit(&shared_status,reason,memory_order_release); return 0; }
static bool shared_region(uintptr_t address, size_t length, vm_prot_t *protection)
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
static bool shared_readable(uintptr_t p, size_t n)
{
    vm_prot_t protection;
    return shared_region(p, n, &protection) && (protection & VM_PROT_READ);
}
static bool shared_validate(uintptr_t base)
{
    const struct mach_header_64 *mh = (const void *)base;
    if (base > UINTPTR_MAX-0x142c000 || !shared_readable(base, sizeof(*mh)) ||
        mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_ARM64 ||
        mh->cpusubtype != CPU_SUBTYPE_ARM64_ALL || mh->filetype != MH_DYLIB ||
        mh->sizeofcmds > 0x10000 || mh->ncmds > mh->sizeofcmds/8 ||
        !shared_readable(base, sizeof(*mh)+mh->sizeofcmds)) return false;
    const uint8_t *p=(const void *)(mh+1), *end=p+mh->sizeofcmds;
    bool uuid=false, text=false, data=false;
    for (uint32_t i=0; i<mh->ncmds; ++i) {
        if ((size_t)(end-p)<8) return false;
        const struct load_command *lc=(const void *)p;
        if (lc->cmdsize<8 || lc->cmdsize%8 || lc->cmdsize>(size_t)(end-p)) return false;
        if (lc->cmd==LC_UUID) {
            if (uuid || lc->cmdsize!=sizeof(struct uuid_command) ||
                memcmp(((const struct uuid_command *)lc)->uuid,hv_shared_uuid,16)) return false;
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
    if (p!=end || !uuid || !text || !data || !shared_readable(base,0x13c4000)) return false;
    for (size_t i=0;i<sizeof(hv_shared_guards)/sizeof(hv_shared_guards[0]);++i) {
        const struct HvSharedGuard *g=&hv_shared_guards[i];
        if (g->offset>0x13c4000 || g->size>0x13c4000-g->offset ||
            memcmp((const void *)(base+g->offset),g->bytes,g->size)) return false;
    }
    /* Only legacy 2D's direct call into 2D1 is permitted; legacy itself is hooked. */
    for (size_t pc=0x4000;pc<0x12283ac;pc+=4) {
        uint32_t ins; memcpy(&ins,(const void *)(base+pc),4);
        if ((ins&0x7c000000u)==0x14000000u) {
            int64_t delta=(int32_t)(ins<<6)>>6;
            int64_t target=(int64_t)pc+delta*4;
            for (size_t j=0;j<2;++j)
                if (target==(int64_t)hv_shared_targets[j] && !(pc==0xe700 && target==0xfef4)) return false;
        }
    }
    return true;
}

static uint64_t now_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC,&ts)) return 0;
    return (uint64_t)ts.tv_sec*UINT64_C(1000000000)+(uint64_t)ts.tv_nsec;
}
static void flush_stage(int entering)
{
    pthread_mutex_lock(&stage_mutex);
    if (entering) {
        if (!active_flush++) flush_busy_since=now_ns();
    } else if (active_flush && !--active_flush) flush_busy_since=0;
    pthread_mutex_unlock(&stage_mutex);
}
void hv_dxmt_shared_init_describe(char *buffer,size_t length)
{
    if (!buffer || !length) return;
    pthread_mutex_lock(&stage_mutex);
    uint64_t active=active_flush, since=flush_busy_since, now=now_ns();
    pthread_mutex_unlock(&stage_mutex);
    uint64_t token=atomic_load_explicit(&gpu_token,memory_order_acquire);
    snprintf(buffer,length,
        "%s; allowed=%u draining=%u flush_active=%llu flush_busy_ms=%llu poll_active=%llu ready=%llu skipped=%llu quarantined=%llu failed=%u",
        hv_dxmt_shared_init_status(),(unsigned)(token&1),(unsigned)((token>>1)&1),
        (unsigned long long)active,(unsigned long long)(since && now>=since?(now-since)/1000000:0),
        (unsigned long long)atomic_load_explicit(&active_poll,memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&waits,memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&skipped,memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&quarantined,memory_order_relaxed),
        (unsigned)atomic_load_explicit(&foreground_failed,memory_order_acquire));
}
static void pause_poll(void)
{ struct timespec ts={0,1000000}; nanosleep(&ts,NULL); }
static bool gate_matches(uint64_t token)
{ return gate_allowed(token) && atomic_load_explicit(&gpu_token,memory_order_acquire)==token; }
static void log_skip(void)
{
    uint64_t n=atomic_fetch_add_explicit(&skipped,1,memory_order_relaxed)+1;
    if (n<=4 || !(n&(n-1)))
        fprintf(stderr,"[3d] shared-init: lifecycle skip, original result preserved (count=%llu)\n",(unsigned long long)n);
}
static bool affected(const void *desc)
{
    if (!desc) return false;
    uint32_t usage,flags;
    memcpy(&usage,(const uint8_t *)desc+0x1c,4);
    memcpy(&flags,(const uint8_t *)desc+0x28,4);
    return usage<=1 && (flags&0x902);
}
static int32_t finish_create(void *device,const void *desc,void **out,int32_t hr)
{
    if (hr<0 || !out || !*out || !affected(desc)) return hr;
    uint64_t token=atomic_load_explicit(&gpu_token,memory_order_acquire);
    if (!gate_allowed(token)) {log_skip(); return hr;}
    uintptr_t base=atomic_load_explicit(&shared_image,memory_order_acquire);
    uintptr_t table,container,queue;
    memcpy(&table,device,8);
    memcpy(&container,(const uint8_t *)device+0x28,8);
    bool valid=base && table==base+HV_SHARED_VTABLE && container;
    queue=0;
    if (valid) memcpy(&queue,(const uint8_t *)container+0x40,8);
    valid=valid && queue && !(queue&7);
    uint64_t start=now_ns(),goal=0,value=0;
    void *event=NULL;
    const char *failure="unexpected device layout";
    if (valid) {
        memcpy(&event,(const void *)(queue+0x10028),8);
        if (!gate_matches(token)) {log_skip(); return hr;}
        /* Only upload/zero initialization. Never commit/wait the main queue:
         * it may be waiting for this resource on a different device. */
        uint64_t call=atomic_fetch_add_explicit(&flushes,1,memory_order_relaxed)+1;
        fprintf(stderr,"[3d] shared-init: initializer flush begin call=%llu\n",(unsigned long long)call);
        /* Metal commandBuffer allocation inside flush can block. The 2 second
         * bound below applies only to polling AFTER this call returns. */
        if (!gate_matches(token)) {log_skip(); return hr;}
        flush_stage(1);
        goal=shared_calls.flush((void *)(queue+0x10008));
        flush_stage(0);
        uint64_t flush_end=now_ns();
        fprintf(stderr,"[3d] shared-init: initializer flush returned call=%llu goal=%llu flush_ms=%llu\n",
            (unsigned long long)call,(unsigned long long)goal,
            (unsigned long long)(flush_end>=start?(flush_end-start)/1000000:0));
        start=flush_end;
        failure="initializer event timeout";
        if (!goal) return hr;
        atomic_fetch_add_explicit(&active_poll,1,memory_order_relaxed);
        for (;;) {
            if (!gate_matches(token)) {
                atomic_fetch_sub_explicit(&active_poll,1,memory_order_relaxed);
                log_skip(); return hr;
            }
            struct {void *event; uint64_t value;} args={event,0};
            if (!event || shared_calls.event_value(&args)) {
                failure="initializer event unavailable"; break;
            }
            value=args.value;
            if (value>=goal) {
                atomic_fetch_sub_explicit(&active_poll,1,memory_order_relaxed);
                uint64_t elapsed=now_ns()-start;
                uint64_t n=atomic_fetch_add_explicit(&waits,1,memory_order_relaxed)+1;
                if (n<=4 || elapsed>=UINT64_C(50000000))
                    fprintf(stderr,"[3d] shared-init: ready goal=%llu value=%llu wait_ms=%llu count=%llu\n",
                        (unsigned long long)goal,(unsigned long long)value,
                        (unsigned long long)(elapsed/1000000),(unsigned long long)n);
                return hr;
            }
            uint64_t now=now_ns();
            if (!start || !now || now-start>=UINT64_C(2000000000)) break;
            pause_poll();
        }
        atomic_fetch_sub_explicit(&active_poll,1,memory_order_relaxed);
    }
    if (!gate_matches(token)) {log_skip(); return hr;}
    /* No unfinished mapping or device/initializer may be destroyed on failure.
     * Keep the creation reference and pin its live caller device permanently.
     * The caller never receives this resource. This exceptional quarantine is
     * counted/logged; it is not a successful initialization or recovery. */
    atomic_store_explicit(&foreground_failed,true,memory_order_release);
    shared_calls.addref(device);
    *out=NULL;
    uint64_t n=atomic_fetch_add_explicit(&quarantined,1,memory_order_relaxed)+1;
    fprintf(stderr,"[3d] shared-init: %s goal=%llu value=%llu; texture+device quarantined count=%llu\n",
        failure,(unsigned long long)goal,(unsigned long long)value,(unsigned long long)n);
    return (int32_t)0x80004005u;
}
static int32_t create_common(size_t which,void *device,const void *desc,const void *data,void **out)
{
    (void)atomic_load_explicit(&shared_image,memory_order_acquire);
    /* Following a foreground failure, do not create more unpublished resources.
     * Calls already in flight may each quarantine once. Background policy still
     * preserves original behavior and does not attempt any additional flush. */
    if (gate_allowed(atomic_load_explicit(&gpu_token,memory_order_acquire)) && affected(desc) &&
        atomic_load_explicit(&foreground_failed,memory_order_acquire)) {
        if (out) *out=NULL;
        return (int32_t)0x80004005u;
    }
    void *local=NULL;
    if (out) *out=NULL;
    int32_t hr=shared_calls.create[which](device,desc,data,out?&local:NULL);
    hr=finish_create(device,desc,out?&local:NULL,hr);
    if (out) *out=local;
    return hr;
}
static int32_t create_2d(void *device,const void *desc,const void *data,void **out)
{ return create_common(0,device,desc,data,out); }
static int32_t create_2d1(void *device,const void *desc,const void *data,void **out)
{ return create_common(1,device,desc,data,out); }
static int install_shared_image(uintptr_t base)
{
    if (atomic_load_explicit(&shared_fatal,memory_order_acquire)) return -1;
    if (!shared_validate(base)) return reject("disabled: shared-init image guards mismatch");
    uintptr_t *slots[2]={(void *)(base+hv_shared_slots[0]),(void *)(base+hv_shared_slots[1])};
    const uintptr_t hooks[2]={(uintptr_t)create_2d,(uintptr_t)create_2d1};
    if (shared_installed) {
        if (base!=atomic_load(&shared_image)) return reject("rejected: different shared-init image");
        for (size_t i=0;i<2;++i)
            if (__atomic_load_n(slots[i],__ATOMIC_ACQUIRE)!=hooks[i])
                return reject("rejected: shared-init slots changed");
        return 1;
    }
    if (atomic_load(&shared_image)) return reject("disabled: shared-init publication cannot retry");
    for (size_t i=0;i<2;++i)
        if (!shared_readable((uintptr_t)slots[i],8) ||
            __atomic_load_n(slots[i],__ATOMIC_ACQUIRE)!=base+hv_shared_targets[i])
            return reject("disabled: shared-init slot already interposed");
    vm_address_t page=(uintptr_t)slots[0]&~(uintptr_t)(vm_page_size-1);
    vm_prot_t protection;
    if (((uintptr_t)slots[1]&~(uintptr_t)(vm_page_size-1))!=page ||
        !shared_region(page,vm_page_size,&protection) || !(protection&VM_PROT_READ) ||
        (protection&VM_PROT_EXECUTE)) return reject("disabled: unsafe shared-init data protection");
    if (vm_protect(mach_task_self(),page,vm_page_size,FALSE,
        VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)!=KERN_SUCCESS)
        return reject("disabled: shared-init data cannot be made writable");
    for (size_t i=0;i<2;++i) shared_calls.create[i]=(void *)(base+hv_shared_targets[i]);
    shared_calls.flush=(void *)(base+HV_SHARED_FLUSH);
    shared_calls.event_value=(void *)(base+HV_SHARED_EVENT);
    shared_calls.addref=(void *)(base+HV_SHARED_ADDREF);
    atomic_store_explicit(&shared_image,base,memory_order_release);
    size_t bound=0;
    for (;bound<2;++bound) {
        uintptr_t expected=base+hv_shared_targets[bound];
        if (!__atomic_compare_exchange_n(slots[bound],&expected,hooks[bound],false,
            __ATOMIC_RELEASE,__ATOMIC_ACQUIRE)) break;
    }
    bool restored=vm_protect(mach_task_self(),page,vm_page_size,FALSE,protection)==KERN_SUCCESS;
    if (bound!=2 || !restored) {
        bool writable=!restored || vm_protect(mach_task_self(),page,vm_page_size,FALSE,
            VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)==KERN_SUCCESS;
        bool rolled_back=writable;
        if (writable) for (size_t i=0;i<bound;++i) {
            uintptr_t expected=hooks[i];
            if (!__atomic_compare_exchange_n(slots[i],&expected,base+hv_shared_targets[i],false,
                __ATOMIC_RELEASE,__ATOMIC_ACQUIRE)) rolled_back=false;
        }
        bool protected_again=vm_protect(mach_task_self(),page,vm_page_size,FALSE,protection)==KERN_SUCCESS;
        if (!rolled_back || !protected_again) {
            atomic_store_explicit(&shared_fatal,true,memory_order_release);
            reject("fatal: shared-init rollback incomplete; refuse backend devices");
            return -1;
        }
        return reject("disabled: shared-init transaction rolled back");
    }
    shared_installed=true;
    atomic_store_explicit(&shared_status,"installed: opt-in guarded shared initialization",memory_order_release);
    return 1;
}
int hv_dxmt_install_shared_init(void *create_device)
{
    pthread_mutex_lock(&shared_install_mutex);
    int result=-1;
    if (!atomic_load_explicit(&shared_fatal,memory_order_acquire)) {
        const char *env=getenv("HV_DXMT_SHARED_INIT");
        Dl_info info;
        if (!shared_installed && (!env || strcmp(env,"1")))
            result=reject("disabled: HV_DXMT_SHARED_INIT is opt-in");
        else if (!create_device || !dladdr(create_device,&info) ||
            (uintptr_t)create_device!=(uintptr_t)info.dli_fbase+0x35f10)
            result=reject("disabled: shared-init symbol identity mismatch");
        else result=install_shared_image((uintptr_t)info.dli_fbase);
    }
    pthread_mutex_unlock(&shared_install_mutex);
    return result;
}
