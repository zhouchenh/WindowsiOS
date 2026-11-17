/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Failure-only instrumentation. Wrappers use immutable libc entrypoints, never
   the rebound import. No TLS, allocation, stdio/ObjC or lock on the report path.
   A single best-effort write is bounded to 64 attempts/process; concurrent,
   recursive and later failures are suppressed. Open EEXIST counts too. */
#include "gpu_map_diagnostics.h"
#include "gpu_map_diagnostics_layout.h"
#include "dxmt_data_lock.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

_Static_assert(sizeof(void *) == 8 && sizeof(off_t) == 8, "64-bit ABI required");
_Static_assert(ATOMIC_POINTER_LOCK_FREE == 2 && ATOMIC_LLONG_LOCK_FREE == 2 &&
               ATOMIC_INT_LOCK_FREE == 2, "diagnostics must not lock atomics");
struct GmdState { uintptr_t base; void *(*map)(void *,size_t,int,int,int,off_t); int (*truncate)(int,off_t); };
static struct GmdState states[2];
static _Atomic(struct GmdState *) published[2];
static bool installed[2]; /* common data lock */
static _Atomic bool used, poisoned;
enum { S_OFF, S_ON, S_IMAGE, S_BYTES, S_IMPORT, S_PROTECTION, S_RACE, S_RETRY, S_USED, S_FATAL };
static _Atomic int status[2];
static atomic_flag reporting = ATOMIC_FLAG_INIT;
static _Atomic uint64_t attempts, suppressed;

static void increment_saturated(_Atomic uint64_t *counter)
{
    uint64_t n=atomic_load_explicit(counter,memory_order_relaxed);
    /* Best effort, bounded under contention; no failure-path spin loop. */
    if (n != UINT64_MAX)
        (void)atomic_compare_exchange_strong_explicit(counter,&n,n+1,memory_order_relaxed,memory_order_relaxed);
}
struct Line { char data[1536]; size_t n; };
static void put(struct Line *b, const char *s)
{
    while (*s && b->n+1<sizeof b->data) b->data[b->n++]=*s++;
}
static void number(struct Line *b, uint64_t n)
{
    char digits[20]; size_t count=0;
    do { digits[count++]=(char)('0'+n%10); n/=10; } while(n);
    while(count && b->n+1<sizeof b->data) b->data[b->n++]=digits[--count];
}
static void signed_number(struct Line *b, int64_t n)
{
    if (n<0) { put(b,"-"); number(b,0-(uint64_t)n); } else number(b,(uint64_t)n);
}
static void field(struct Line *b,const char *key,int64_t n) { put(b,key); signed_number(b,n); }
static void ufield(struct Line *b,const char *key,uint64_t n) { put(b,key); number(b,n); }

static void report(int image, uintptr_t caller, int stage, size_t bytes,
                   int prot, int flags, int fd, off_t offset, int error)
{
    int saved=errno;
    if (atomic_flag_test_and_set_explicit(&reporting,memory_order_acquire)) {
        increment_saturated(&suppressed); errno=saved; return;
    }
    uint64_t count=atomic_load_explicit(&attempts,memory_order_relaxed);
    if (count>=64) { increment_saturated(&suppressed); goto done; }
    atomic_store_explicit(&attempts,count+1,memory_order_relaxed);
    struct Line line={{0},0};
    put(&line,"winvm: gpu-map-failure image=");
    put(&line,image>=0 ? gmd_layouts[image].name : "unknown");
    put(&line," stage="); put(&line,stage==0?"mmap":stage==1?"ftruncate":"open");
    put(&line," site=");
    struct GmdState *state=image>=0?atomic_load_explicit(&published[image],memory_order_acquire):NULL;
    const struct GmdLayout *layout=image>=0?&gmd_layouts[image]:NULL;
    if (state && stage==0 && layout->mmap_return && caller==state->base+layout->mmap_return)
        put(&line,"shared-texture");
    else if (state && stage==1 && layout->ftruncate_return && caller==state->base+layout->ftruncate_return)
        put(&line,"shared-backing");
    else put(&line,"other");
    field(&line," errno=",error);
    if (stage==0) { ufield(&line," bytes=",bytes); field(&line," prot=",prot); }
    if (stage!=1) field(&line," flags=",flags);
    if (stage!=2) field(&line,stage==0?" offset=":" length=",offset);
    if (stage!=2 && fd>=0 && !(stage==0 && (flags&MAP_ANON))) {
        struct stat info;
        int rc=fstat(fd,&info), err=rc<0?errno:0;
        field(&line," fstat_rc=",rc); field(&line," fstat_errno=",err);
        if (!rc) {
            ufield(&line," type=",info.st_mode&S_IFMT); field(&line," file_bytes=",info.st_size);
            field(&line," blocks=",info.st_blocks); ufield(&line," nlink=",info.st_nlink);
        }
        rc=fcntl(fd,F_GETFL); err=rc<0?errno:0;
        field(&line," fd_flags=",rc); field(&line," fcntl_errno=",err);
    } else put(&line," fd_metadata=unavailable");
    task_vm_info_data_t vm;
    mach_msg_type_number_t vm_count=TASK_VM_INFO_COUNT;
    kern_return_t kr=task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&vm,&vm_count);
    field(&line," task_rc=",kr);
    if (kr==KERN_SUCCESS && vm_count>=TASK_VM_INFO_REV0_COUNT) {
        ufield(&line," virtual_bytes=",vm.virtual_size); field(&line," regions=",vm.region_count);
    }
    struct rlimit limit;
    int rc=getrlimit(RLIMIT_AS,&limit), err=rc<0?errno:0;
    field(&line," as_rc=",rc); field(&line," as_errno=",err);
    if (!rc) ufield(&line," as_cur=",limit.rlim_cur);
    rc=getrlimit(RLIMIT_DATA,&limit); err=rc<0?errno:0;
    field(&line," data_rc=",rc); field(&line," data_errno=",err);
    if (!rc) ufield(&line," data_cur=",limit.rlim_cur);
    ufield(&line," attempt=",count+1);
    ufield(&line," suppressed_at_least=",atomic_load_explicit(&suppressed,memory_order_relaxed));
    /* Reserve a terminator even if future scalar fields fill the buffer. */
    if (line.n==sizeof line.data-1) line.n--;
    line.data[line.n++]='\n';
    (void)write(STDERR_FILENO,line.data,line.n); /* no retry, including EINTR */
done:
    atomic_flag_clear_explicit(&reporting,memory_order_release);
    errno=saved;
}

static void *map_call(int image,uintptr_t caller,void *addr,size_t n,int prot,int flags,int fd,off_t off)
{
    struct GmdState *state=atomic_load_explicit(&published[image],memory_order_acquire);
    void *result=state->map(addr,n,prot,flags,fd,off);
    int saved=errno;
    if (result==MAP_FAILED) report(image,caller,0,n,prot,flags,fd,off,saved);
    errno=saved; return result;
}
static int truncate_call(int image,uintptr_t caller,int fd,off_t n)
{
    struct GmdState *state=atomic_load_explicit(&published[image],memory_order_acquire);
    int result=state->truncate(fd,n), saved=errno;
    if (result<0) report(image,caller,1,0,0,0,fd,n,saved);
    errno=saved; return result;
}
#define CALLER ((uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0)))
__attribute__((noinline)) static void *dxmt_map(void *a,size_t n,int p,int f,int d,off_t o) { return map_call(0,CALLER,a,n,p,f,d,o); }
__attribute__((noinline)) static void *virgl_map(void *a,size_t n,int p,int f,int d,off_t o) { return map_call(1,CALLER,a,n,p,f,d,o); }
__attribute__((noinline)) static int dxmt_truncate(int d,off_t n) { return truncate_call(0,CALLER,d,n); }
__attribute__((noinline)) static int virgl_truncate(int d,off_t n) { return truncate_call(1,CALLER,d,n); }

void hv_gpu_map_diagnostics_open_failed(uintptr_t caller,int flags,int error)
{
    int image=-1;
    for (int i=0;i<2;i++) {
        struct GmdState *state=atomic_load_explicit(&published[i],memory_order_acquire);
        if (state && caller>=state->base && caller-state->base<gmd_layouts[i].text_size) { image=i; break; }
    }
    report(image,caller,2,0,0,flags,-1,0,error);
}
void hv_gpu_map_diagnostics_counts(uint64_t *a,uint64_t *s)
{
    if(a) *a=atomic_load_explicit(&attempts,memory_order_relaxed);
    if(s) *s=atomic_load_explicit(&suppressed,memory_order_relaxed);
}
int hv_gpu_map_diagnostics_used(void) { return atomic_load_explicit(&used,memory_order_acquire); }
void hv_gpu_map_diagnostics_poison_imports(void) { atomic_store_explicit(&poisoned,true,memory_order_release); }
int hv_gpu_map_diagnostics_fatal(void) { return atomic_load_explicit(&poisoned,memory_order_acquire); }
int hv_gpu_map_diagnostics_mark_used(void)
{
    hv_dxmt_data_lock();
    int result=hv_gpu_map_diagnostics_fatal()?-1:1;
    if(result==1) atomic_store_explicit(&used,true,memory_order_release);
    hv_dxmt_data_unlock(); return result;
}
const char *hv_gpu_map_diagnostics_status(enum HvGpuMapImage i)
{
    static const char *const names[]={"not installed","installed","unavailable: image/layout mismatch",
        "unavailable: code mismatch","unavailable: import already interposed","unavailable: page protection",
        "unavailable: import changed","unavailable: publication cannot retry","unavailable: backend already used",
        "fatal: incomplete import rollback/protection restoration"};
    if(hv_gpu_map_diagnostics_fatal()) return names[S_FATAL];
    if((unsigned)i>=2) return names[S_IMAGE];
    return names[atomic_load_explicit(&status[i],memory_order_relaxed)];
}

static bool region(uintptr_t address,size_t length,vm_prot_t *protection)
{
    if(!length || address>UINTPTR_MAX-length) return false;
    vm_address_t start=address; vm_size_t size=0;
    vm_region_basic_info_data_64_t info; mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    kern_return_t kr=vm_region_64(mach_task_self(),&start,&size,VM_REGION_BASIC_INFO_64,(vm_region_info_t)&info,&count,&object);
    if(MACH_PORT_VALID(object)) mach_port_deallocate(mach_task_self(),object);
    if(kr!=KERN_SUCCESS || count<VM_REGION_BASIC_INFO_COUNT_64 || start>address || size<length || address-start>size-length) return false;
    *protection=info.protection; return true;
}
static bool readable(uintptr_t a,size_t n) { vm_prot_t p; return region(a,n,&p) && (p&VM_PROT_READ); }
static bool name_is(const char name[16],const char *expected) { return !strncmp(name,expected,16); }
static bool image_valid(uintptr_t base,int image)
{
    const struct GmdLayout *g=&gmd_layouts[image];
    const struct mach_header_64 *mh=(const void *)base;
    if(!readable(base,sizeof(*mh)) || mh->magic!=MH_MAGIC_64 || mh->cputype!=CPU_TYPE_ARM64 ||
       mh->cpusubtype!=CPU_SUBTYPE_ARM64_ALL || mh->filetype!=MH_DYLIB || mh->sizeofcmds>0x10000 ||
       mh->ncmds>mh->sizeofcmds/8 || !readable(base,sizeof(*mh)+mh->sizeofcmds) ||
       base>UINTPTR_MAX-g->text_size-g->data_size) return false;
    const uint8_t *at=(const void *)(mh+1), *end=at+mh->sizeofcmds;
    bool uuid=false,text=false,data=false,got=false;
    for(uint32_t i=0;i<mh->ncmds;i++) {
        if((size_t)(end-at)<8) return false;
        const struct load_command *lc=(const void *)at;
        if(lc->cmdsize<8 || lc->cmdsize%8 || lc->cmdsize>(size_t)(end-at)) return false;
        if(lc->cmd==LC_UUID) {
            if(uuid || lc->cmdsize!=sizeof(struct uuid_command) || memcmp(((const struct uuid_command *)lc)->uuid,g->uuid,16)) return false;
            uuid=true;
        } else if(lc->cmd==LC_SEGMENT_64) {
            if(lc->cmdsize<sizeof(struct segment_command_64)) return false;
            const struct segment_command_64 *seg=(const void *)lc;
            if(seg->nsects>(lc->cmdsize-sizeof(*seg))/sizeof(struct section_64) ||
               lc->cmdsize!=sizeof(*seg)+seg->nsects*sizeof(struct section_64)) return false;
            bool t=name_is(seg->segname,"__TEXT"), d=name_is(seg->segname,"__DATA_CONST");
            if(t||d) {
                size_t addr=t?0:g->text_size, n=t?g->text_size:g->data_size; int prot=t?5:3;
                if((t&&text)||(d&&data)||seg->vmaddr!=addr||seg->vmsize!=n||seg->fileoff!=addr||seg->filesize!=n||seg->maxprot!=prot||seg->initprot!=prot) return false;
                if(t) text=true; else data=true;
            }
            const struct section_64 *sec=(const void *)(seg+1);
            for(uint32_t j=0;j<seg->nsects;j++,sec++) if(name_is(sec->sectname,"__got")) {
                if(got || !d || !name_is(sec->segname,"__DATA_CONST") || sec->addr!=g->got || sec->size!=g->got_size || sec->offset!=g->got || sec->flags!=S_NON_LAZY_SYMBOL_POINTERS || sec->reserved1!=g->got_index) return false;
                got=true;
            }
        }
        at+=lc->cmdsize;
    }
    return at==end && uuid && text && data && got;
}
static bool code_valid(uintptr_t base,int image)
{
    const struct GmdLayout *g=&gmd_layouts[image];
    for(size_t i=0;i<g->guard_count;i++) {
        const struct GmdGuard *b=&g->guards[i];
        if(!readable(base+b->offset,b->size) || memcmp((const void *)(base+b->offset),b->bytes,b->size)) return false;
    }
    return true;
}
static int refuse(int i,int reason) { atomic_store_explicit(&status[i],reason,memory_order_relaxed); return 0; }
static int poison(void) { atomic_store_explicit(&poisoned,true,memory_order_release); return -1; }

/* Already serialized with all other framework data-page installers. */
static int install_image(uintptr_t base,int image,void *map,void *truncate)
{
    if(hv_gpu_map_diagnostics_fatal()) return -1;
    if(!image_valid(base,image)) return refuse(image,S_IMAGE);
    if(!code_valid(base,image)) return refuse(image,S_BYTES);
    const struct GmdLayout *g=&gmd_layouts[image];
    uintptr_t slot[2]={base+g->mmap_slot,base+g->ftruncate_slot};
    uintptr_t original[2]={(uintptr_t)map,(uintptr_t)truncate};
    uintptr_t replacement[2]={image?(uintptr_t)virgl_map:(uintptr_t)dxmt_map,image?(uintptr_t)virgl_truncate:(uintptr_t)dxmt_truncate};
    if(installed[image]) {
        if(states[image].base!=base) return refuse(image,S_IMAGE);
        for(int n=0;n<2;n++) if(!readable(slot[n],8)||atomic_load_explicit((_Atomic uintptr_t *)slot[n],memory_order_acquire)!=replacement[n]) return poison();
        return 1;
    }
    if(hv_gpu_map_diagnostics_used()) return refuse(image,S_USED);
    if(atomic_load_explicit(&published[image],memory_order_acquire)) return refuse(image,S_RETRY);
    if(!map || !truncate) return refuse(image,S_IMPORT);
    if(!vm_page_size || (vm_page_size&(vm_page_size-1))) return refuse(image,S_PROTECTION);
    uintptr_t page=slot[0]&~(uintptr_t)(vm_page_size-1);
    if((slot[1]&~(uintptr_t)(vm_page_size-1))!=page || slot[0]%8 || slot[1]%8) return refuse(image,S_PROTECTION);
    vm_prot_t protection;
    if(!region(page,vm_page_size,&protection) || !(protection&VM_PROT_READ) || (protection&VM_PROT_EXECUTE)) return refuse(image,S_PROTECTION);
    for(int n=0;n<2;n++) if(atomic_load_explicit((_Atomic uintptr_t *)slot[n],memory_order_acquire)!=original[n]) return refuse(image,S_IMPORT);
    if(vm_protect(mach_task_self(),page,vm_page_size,false,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)!=KERN_SUCCESS) {
        /* A failed protection request is not proof of unchanged permissions. */
        if(vm_protect(mach_task_self(),page,vm_page_size,false,protection)!=KERN_SUCCESS) return poison();
        return refuse(image,S_PROTECTION);
    }
    states[image]=(struct GmdState){base,(void *(*)(void *,size_t,int,int,int,off_t))map,(int (*)(int,off_t))truncate};
    atomic_store_explicit(&published[image],&states[image],memory_order_release);
    int changed=0;
    for(;changed<2;changed++) {
        uintptr_t expected=original[changed];
        if(!atomic_compare_exchange_strong_explicit((_Atomic uintptr_t *)slot[changed],&expected,replacement[changed],memory_order_release,memory_order_acquire)) break;
    }
    bool restored=vm_protect(mach_task_self(),page,vm_page_size,false,protection)==KERN_SUCCESS;
    if(changed==2 && restored) { installed[image]=true; atomic_store(&status[image],S_ON); return 1; }
    /* Restoring read-only protection can fail after publication. Make writable
       again before rollback; preserve state forever for already-loaded hooks. */
    if(vm_protect(mach_task_self(),page,vm_page_size,false,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)!=KERN_SUCCESS) return poison();
    bool rolled=true;
    for(int n=changed-1;n>=0;n--) {
        uintptr_t expected=replacement[n];
        if(!atomic_compare_exchange_strong_explicit((_Atomic uintptr_t *)slot[n],&expected,original[n],memory_order_release,memory_order_acquire)) rolled=false;
    }
    if(vm_protect(mach_task_self(),page,vm_page_size,false,protection)!=KERN_SUCCESS || !rolled) return poison();
    return refuse(image,changed==2?S_PROTECTION:S_RACE);
}

int hv_gpu_map_diagnostics_install(void *symbol,enum HvGpuMapImage image)
{
    if(hv_gpu_map_diagnostics_fatal()) return -1;
    if((unsigned)image>=2) return 0;
    Dl_info info;
    if(!symbol || !dladdr(symbol,&info) || (uintptr_t)symbol-(uintptr_t)info.dli_fbase!=gmd_layouts[image].identity) return refuse(image,S_IMAGE);
    bool loaded=false;
    for(uint32_t i=0;i<_dyld_image_count();i++) if(_dyld_get_image_header(i)==info.dli_fbase && (uintptr_t)_dyld_get_image_vmaddr_slide(i)==(uintptr_t)info.dli_fbase) { loaded=true; break; }
    if(!loaded) return refuse(image,S_IMAGE);
    /* Resolve only canonical libc symbols, before publication. No dlclose: the
       published original targets must remain valid for the process lifetime. */
    void *lib=dlopen("/usr/lib/system/libsystem_kernel.dylib",RTLD_NOW|RTLD_LOCAL);
    void *map=lib?dlsym(lib,"mmap"):NULL, *truncate=lib?dlsym(lib,"ftruncate"):NULL;
    if(map!=(void *)mmap || truncate!=(void *)ftruncate) return refuse(image,S_IMPORT);
    hv_dxmt_data_lock();
    int result=install_image((uintptr_t)info.dli_fbase,image,map,truncate);
    hv_dxmt_data_unlock(); return result;
}
