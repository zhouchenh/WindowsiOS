/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Native synthetic images and injected libc failures. No renderer or GPU use. */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>
static int fake_stat(int,struct stat *);
static int fake_fcntl(int,int,...);
static int fake_limit(int,struct rlimit *);
static kern_return_t fake_task(task_name_t,task_flavor_t,task_info_t,mach_msg_type_number_t *);
static ssize_t fake_write(int,const void *,size_t);
static kern_return_t fake_region(vm_map_t,vm_address_t *,vm_size_t *,vm_region_flavor_t,vm_region_info_t,mach_msg_type_number_t *,mach_port_t *);
static kern_return_t fake_protect(vm_map_t,vm_address_t,vm_size_t,boolean_t,vm_prot_t);
#define fstat fake_stat
#define fcntl fake_fcntl
#define getrlimit fake_limit
#define task_info fake_task
#define write fake_write
#define vm_protect fake_protect
#define vm_region_64 fake_region
#include "../devices/gpu_map_diagnostics.c"
#undef fstat
#undef fcntl
#undef getrlimit
#undef task_info
#undef write
#undef vm_protect
#undef vm_region_64
static _Atomic int map_calls,truncate_calls,write_calls;
static int fail_syscall=1,stat_error,write_error,reenter,short_write;
static int protect_count,fail_protect,fail_again,slot_race,change_on_failure,short_region;
static uintptr_t race_slot;
static void *last_addr; static size_t last_size; static int last_prot,last_flags; static _Atomic int last_fd; static _Atomic off_t last_offset;
static char last_line[2048];
static int fake_stat(int fd,struct stat *s)
{
    (void)fd; errno=EDOM;
    if(stat_error) { errno=EBADF; return -1; }
    memset(s,0,sizeof *s); s->st_mode=S_IFREG|0600; s->st_size=234567; s->st_blocks=32; s->st_nlink=0; return 0;
}
static int fake_fcntl(int fd,int cmd,...) { (void)fd; assert(cmd==F_GETFL); errno=EIO; return stat_error?-1:O_RDWR; }
static int fake_limit(int name,struct rlimit *r) { (void)name; errno=ERANGE; r->rlim_cur=RLIM_INFINITY; return 0; }
static kern_return_t fake_task(task_name_t t,task_flavor_t f,task_info_t out,mach_msg_type_number_t *count)
{
    (void)t; assert(f==TASK_VM_INFO); errno=E2BIG;
    task_vm_info_data_t *v=(void *)out; memset(v,0,sizeof *v); v->virtual_size=500000000000; v->region_count=999;
    *count=TASK_VM_INFO_COUNT; return KERN_SUCCESS;
}
static void *original_map(void *a,size_t n,int p,int f,int d,off_t o)
{
    atomic_fetch_add(&map_calls,1); last_addr=a; last_size=n; last_prot=p; last_flags=f; last_fd=d; last_offset=o;
    errno=fail_syscall?ENOMEM:EAGAIN; return fail_syscall?MAP_FAILED:(void *)0x12340000;
}
static int original_truncate(int d,off_t n)
{
    atomic_fetch_add(&truncate_calls,1); last_fd=d; last_offset=n;
    errno=fail_syscall?ENOSPC:EAGAIN; return fail_syscall?-1:0;
}
static ssize_t fake_write(int fd,const void *buffer,size_t n)
{
    assert(fd==2 && n>0 && n<1536 && ((const char *)buffer)[n-1]=='\n');
    memcpy(last_line,buffer,n); last_line[n]=0; atomic_fetch_add(&write_calls,1);
    if(reenter) { reenter=0; assert(virgl_map(NULL,1,PROT_READ,MAP_SHARED,7,0)==MAP_FAILED); assert(errno==ENOMEM); }
    errno=EINTR;
    return write_error?-1:short_write?1:(ssize_t)n;
}
static kern_return_t fake_region(vm_map_t t,vm_address_t *a,vm_size_t *s,vm_region_flavor_t f,vm_region_info_t i,mach_msg_type_number_t *c,mach_port_t *o)
{
    kern_return_t r=vm_region_64(t,a,s,f,i,c,o);
    if(short_region && r==KERN_SUCCESS) *c=0;
    return r;
}
static kern_return_t fake_protect(vm_map_t task,vm_address_t at,vm_size_t size,boolean_t max,vm_prot_t p)
{
    protect_count++;
    if(protect_count==fail_protect || protect_count==fail_again) {
        if(change_on_failure) assert(vm_protect(task,at,size,max,p)==KERN_SUCCESS);
        return KERN_FAILURE;
    }
    kern_return_t kr=vm_protect(task,at,size,max,p);
    if(kr==KERN_SUCCESS && slot_race && (p&VM_PROT_WRITE)) {
        *(_Atomic uintptr_t *)race_slot=(uintptr_t)0x1234; slot_race=0;
    }
    return kr;
}
static void reset(void)
{
    memset(states,0,sizeof states); memset(installed,0,sizeof installed);
    for(int i=0;i<2;i++) { atomic_store(&published[i],NULL); atomic_store(&status[i],0); }
    atomic_store(&used,false); atomic_store(&poisoned,false); atomic_flag_clear(&reporting);
    atomic_store(&attempts,0); atomic_store(&suppressed,0); atomic_store(&map_calls,0); atomic_store(&truncate_calls,0); atomic_store(&write_calls,0);
    fail_syscall=1; stat_error=write_error=reenter=short_write=0;
    protect_count=fail_protect=fail_again=slot_race=change_on_failure=short_region=0; last_line[0]=0;
}
static void publish_fake(void)
{
    for(int i=0;i<2;i++) { states[i]=(struct GmdState){0x10000000+(uintptr_t)i*0x10000000,original_map,original_truncate}; atomic_store(&published[i],&states[i]); }
}
static void *fixture(int image)
{
    const struct GmdLayout *g=&gmd_layouts[image]; size_t size=g->text_size+g->data_size;
    unsigned char *b=mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0); assert(b!=MAP_FAILED);
    struct mach_header_64 *h=(void *)b;
    *h=(struct mach_header_64){MH_MAGIC_64,CPU_TYPE_ARM64,CPU_SUBTYPE_ARM64_ALL,MH_DYLIB,3,248,0,0};
    struct uuid_command *u=(void *)(b+32); *u=(struct uuid_command){LC_UUID,sizeof *u,{0}}; memcpy(u->uuid,g->uuid,16);
    struct segment_command_64 *t=(void *)(u+1); *t=(struct segment_command_64){.cmd=LC_SEGMENT_64,.cmdsize=sizeof *t,.vmaddr=0,.vmsize=g->text_size,.fileoff=0,.filesize=g->text_size,.maxprot=5,.initprot=5}; strcpy(t->segname,"__TEXT");
    struct segment_command_64 *d=(void *)(t+1); *d=(struct segment_command_64){.cmd=LC_SEGMENT_64,.cmdsize=sizeof *d+sizeof(struct section_64),.vmaddr=g->text_size,.vmsize=g->data_size,.fileoff=g->text_size,.filesize=g->data_size,.maxprot=3,.initprot=3,.nsects=1}; strcpy(d->segname,"__DATA_CONST");
    struct section_64 *s=(void *)(d+1); strcpy(s->sectname,"__got"); strcpy(s->segname,"__DATA_CONST"); s->addr=g->got; s->size=g->got_size; s->offset=(uint32_t)g->got; s->flags=S_NON_LAZY_SYMBOL_POINTERS; s->reserved1=(uint32_t)g->got_index;
    for(size_t i=0;i<g->guard_count;i++) memcpy(b+g->guards[i].offset,g->guards[i].bytes,g->guards[i].size);
    *(uintptr_t *)(b+g->mmap_slot)=(uintptr_t)original_map; *(uintptr_t *)(b+g->ftruncate_slot)=(uintptr_t)original_truncate;
    return b;
}
static void dispose(void *p,int image) { assert(!munmap(p,gmd_layouts[image].text_size+gmd_layouts[image].data_size)); }
static int install(void *p,int image) { hv_dxmt_data_lock(); int r=install_image((uintptr_t)p,image,(void *)original_map,(void *)original_truncate); hv_dxmt_data_unlock(); return r; }
static void test_passthrough(void)
{
    reset(); publish_fake(); fail_syscall=0;
    assert(dxmt_map((void *)0x5678,456,PROT_READ|PROT_WRITE,MAP_SHARED,18,-123)==(void *)0x12340000);
    assert(errno==EAGAIN && last_addr==(void *)0x5678 && last_size==456 && last_prot==3 && last_flags==MAP_SHARED && last_fd==18 && last_offset==-123);
    assert(!virgl_truncate(20,123456) && errno==EAGAIN && last_fd==20 && last_offset==123456);
    assert(atomic_load(&write_calls)==0 && atomic_load(&attempts)==0);
}
static void test_failure(void)
{
    reset(); publish_fake();
    assert(map_call(0,states[0].base+gmd_layouts[0].mmap_return,NULL,20000000,3,MAP_SHARED,9,INT64_MIN)==MAP_FAILED);
    assert(errno==ENOMEM && strstr(last_line,"image=dxmt stage=mmap site=shared-texture errno=12") && strstr(last_line,"offset=-9223372036854775808") && strstr(last_line,"file_bytes=234567") && strstr(last_line,"nlink=0") && strstr(last_line,"regions=999"));
    assert(truncate_call(0,states[0].base+gmd_layouts[0].ftruncate_return,9,INT64_MIN)==-1 && errno==ENOSPC);
    assert(strstr(last_line,"site=shared-backing") && strstr(last_line,"length=-9223372036854775808"));
    assert(virgl_map(NULL,10,1,MAP_SHARED,7,0)==MAP_FAILED && errno==ENOMEM && strstr(last_line,"image=virgl stage=mmap site=other"));
    stat_error=1; write_error=1;
    assert(dxmt_truncate(99,-10)==-1 && errno==ENOSPC && strstr(last_line,"fstat_rc=-1 fstat_errno=9") && !strstr(last_line,"file_bytes="));
    errno=ECHILD; hv_gpu_map_diagnostics_open_failed(states[1].base+100, O_EXCL|O_CREAT, EEXIST);
    assert(errno==ECHILD && strstr(last_line,"image=virgl stage=open") && strstr(last_line,"fd_metadata=unavailable"));
}
static void test_limit_reentry(void)
{
    reset(); publish_fake(); reenter=1; short_write=1;
    assert(dxmt_map(NULL,1,1,MAP_ANON,-1,0)==MAP_FAILED && errno==ENOMEM);
    assert(atomic_load(&map_calls)==2 && atomic_load(&write_calls)==1 && atomic_load(&suppressed)==1 && strstr(last_line,"fd_metadata=unavailable"));
    for(int i=0;i<100;i++) assert(dxmt_truncate(1,100)==-1 && errno==ENOSPC);
    assert(atomic_load(&attempts)==64 && atomic_load(&write_calls)==64 && atomic_load(&suppressed)==38);
    atomic_store(&suppressed,UINT64_MAX); atomic_store(&attempts,UINT64_MAX);
    assert(dxmt_truncate(1,1)==-1 && errno==ENOSPC && atomic_load(&suppressed)==UINT64_MAX && atomic_load(&write_calls)==64);
}
static void test_install(void)
{
    for(int image=0;image<2;image++) {
        reset(); void *p=fixture(image); uintptr_t page=((uintptr_t)p+gmd_layouts[image].mmap_slot)&~(uintptr_t)(vm_page_size-1);
        assert(!mprotect((void *)page,vm_page_size,PROT_READ));
        assert(install(p,image)==1 && protect_count==2 && !hv_gpu_map_diagnostics_fatal());
        vm_prot_t prot; assert(region(page,vm_page_size,&prot) && prot==VM_PROT_READ);
        hv_gpu_map_diagnostics_mark_used(); assert(install(p,image)==1 && protect_count==2);
        assert(map_call(image,0,NULL,5,1,MAP_ANON,-1,0)==MAP_FAILED && errno==ENOMEM);
        dispose(p,image);
    }
}
static void test_guard_refusal(void)
{
    for(int image=0;image<2;image++) {
        reset(); unsigned char *p=fixture(image); struct uuid_command *u=(void *)(p+32); u->uuid[0]^=1;
        assert(install(p,image)==0 && protect_count==0 && !atomic_load(&published[image])); u->uuid[0]^=1;
        for(size_t i=0;i<gmd_layouts[image].guard_count;i++) { size_t off=gmd_layouts[image].guards[i].offset; p[off]^=1; assert(install(p,image)==0 && protect_count==0); p[off]^=1; }
        short_region=1; assert(install(p,image)==0 && protect_count==0); short_region=0;
        uintptr_t *slot=(void *)(p+gmd_layouts[image].mmap_slot); *slot=123;
        assert(install(p,image)==0 && protect_count==0); *slot=(uintptr_t)original_map;
        hv_gpu_map_diagnostics_mark_used(); assert(install(p,image)==0 && protect_count==0);
        dispose(p,image);
    }
}
static void test_rollback(void)
{
    for(int failure=1;failure<=2;failure++) {
        reset(); unsigned char *p=fixture(0); fail_protect=failure; change_on_failure=1;
        uintptr_t page=((uintptr_t)p+gmd_layouts[0].mmap_slot)&~(uintptr_t)(vm_page_size-1);
        assert(!mprotect((void *)page,vm_page_size,PROT_READ));
        assert(install(p,0)==0 && !hv_gpu_map_diagnostics_fatal());
        assert(*(uintptr_t *)(p+gmd_layouts[0].mmap_slot)==(uintptr_t)original_map && *(uintptr_t *)(p+gmd_layouts[0].ftruncate_slot)==(uintptr_t)original_truncate);
        vm_prot_t prot; assert(region(page,vm_page_size,&prot) && prot==VM_PROT_READ);
        if(failure==2) { assert(atomic_load(&published[0])); int before=protect_count; assert(install(p,0)==0 && protect_count==before); }
        dispose(p,0);
    }
    reset(); unsigned char *p=fixture(0); fail_protect=2; fail_again=3;
    assert(install(p,0)==-1 && hv_gpu_map_diagnostics_fatal()); assert(hv_gpu_map_diagnostics_mark_used()==-1 && !hv_gpu_map_diagnostics_used()); int before=protect_count;
    assert(install(p,0)==-1 && protect_count==before);
    assert(hv_gpu_map_diagnostics_install(NULL,HV_GPU_MAP_VIRGL)==-1 && strstr(hv_gpu_map_diagnostics_status(0),"fatal")); dispose(p,0);
    reset(); p=fixture(0); slot_race=1; race_slot=(uintptr_t)p+gmd_layouts[0].ftruncate_slot;
    assert(install(p,0)==0 && !hv_gpu_map_diagnostics_fatal());
    assert(*(uintptr_t *)(p+gmd_layouts[0].mmap_slot)==(uintptr_t)original_map && *(uintptr_t *)race_slot==0x1234); dispose(p,0);
}
/* All threads execute their original call. Reporting is held busy so injected
   non-atomic metadata/formatting helpers are never concurrently entered. */
static void *thread_calls(void *arg) { (void)arg; for(int i=0;i<100;i++) { assert(virgl_truncate(4,5)==-1); assert(errno==ENOSPC); } return NULL; }
static void test_concurrency(void)
{
    reset(); publish_fake(); atomic_flag_test_and_set(&reporting);
    pthread_t threads[8]; for(int i=0;i<8;i++) assert(!pthread_create(&threads[i],NULL,thread_calls,NULL));
    for(int i=0;i<8;i++) assert(!pthread_join(threads[i],NULL));
    assert(atomic_load(&truncate_calls)==800 && atomic_load(&write_calls)==0 && atomic_load(&suppressed)>0);
    atomic_flag_clear(&reporting);
}
#if defined(__aarch64__)
extern const char gmd_test_return[];
__attribute__((naked,noinline)) static void *real_caller(void *a,size_t n,int p,int f,int d,off_t o)
{
    __asm__("stp x29, x30, [sp, #-16]!\n"
            "mov x29, sp\n"
            "bl _dxmt_map\n"
            ".globl _gmd_test_return\n"
            "_gmd_test_return:\n"
            "ldp x29, x30, [sp], #16\n"
            "ret\n");
}
static void test_actual_return_pc(void)
{
    reset(); publish_fake();
    states[0].base=(uintptr_t)gmd_test_return-gmd_layouts[0].mmap_return;
    assert(real_caller(NULL,10,1,MAP_SHARED,8,0)==MAP_FAILED && errno==ENOMEM);
    assert(strstr(last_line,"site=shared-texture"));
}
#else
static void test_actual_return_pc(void) { }
#endif
static void *thread_install(void *p) { assert(install(p,0)==1); return NULL; }
static void test_concurrent_install(void)
{
    reset(); void *p=fixture(0); pthread_t a,b;
    assert(!pthread_create(&a,NULL,thread_install,p)); assert(!pthread_create(&b,NULL,thread_install,p));
    assert(!pthread_join(a,NULL)); assert(!pthread_join(b,NULL)); assert(protect_count==2);
    assert(hv_gpu_map_diagnostics_mark_used()==1); dispose(p,0);
    reset(); hv_dxmt_data_lock(); hv_gpu_map_diagnostics_poison_imports(); hv_dxmt_data_unlock();
    assert(hv_gpu_map_diagnostics_mark_used()==-1 && !hv_gpu_map_diagnostics_used());
}
int main(void)
{
    test_passthrough(); test_failure(); test_limit_reentry(); test_install(); test_guard_refusal(); test_rollback(); test_concurrency(); test_actual_return_pc(); test_concurrent_install();
    puts("gpu map diagnostics: 9 native groups passed"); return 0;
}
