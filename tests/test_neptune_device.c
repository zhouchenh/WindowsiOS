/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Synthetic pinned image and native lifetime callback/transaction tests. */
#include <assert.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <errno.h>
#include <pthread.h>
static kern_return_t test_protect(vm_map_t,vm_address_t,vm_size_t,boolean_t,vm_prot_t);
static int test_join(pthread_t,void **);
#define vm_protect test_protect
#define pthread_join test_join
#include "../devices/neptune_device.c"
#undef vm_protect
#undef pthread_join

static int protects, fail_at, fail_again, reject_ops, queries, adds, releases;
static _Atomic int destroys;
static uintptr_t *race;
static const struct HvNptDeviceOps *observed_ops;
static bool fail_join;
static void *destroy_expected;
static _Atomic int compiler_done;
static pthread_mutex_t compiler_gate_mutex=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t compiler_gate_cond=PTHREAD_COND_INITIALIZER;
static bool compiler_entered, compiler_allowed;
static int finalizer_result;
static int test_join(pthread_t thread,void **result)
{ return fail_join?EINVAL:pthread_join(thread,result); }
int hv_npt_check_dxmt(void *symbol) {(void)symbol; return 0;}
int hv_npt_cleanup_set_device_ops(const struct HvNptDeviceOps *ops)
{
    assert(atomic_load(&device_image));
    observed_ops=ops;
    return !reject_ops;
}
int32_t hv_npt_device_query_interface(void *p,const void *iid,void **out)
{ (void)iid; ++queries; *out=p; return 42; }
uint32_t hv_npt_device_addref(void *p) {(void)p; ++adds; return 77;}
uint32_t hv_npt_device_release(void *p) {(void)p; ++releases; return 66;}
static kern_return_t test_protect(vm_map_t m,vm_address_t p,vm_size_t n,boolean_t max,vm_prot_t prot)
{
    ++protects;
    if (protects==fail_at || protects==fail_again) return KERN_PROTECTION_FAILURE;
    kern_return_t result=vm_protect(m,p,n,max,prot);
    if (result==KERN_SUCCESS && race && (prot&VM_PROT_WRITE)) {
        __atomic_store_n(race,1,__ATOMIC_RELEASE);
        race=NULL;
    }
    return result;
}
static uint8_t *fixture(void)
{
    uint8_t *b=mmap(NULL,0x142c000,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    assert(b!=MAP_FAILED);
    struct mach_header_64 *h=(void *)b;
    *h=(struct mach_header_64){.magic=MH_MAGIC_64,.cputype=CPU_TYPE_ARM64,
        .filetype=MH_DYLIB,.ncmds=3,.sizeofcmds=168};
    struct uuid_command *u=(void *)(h+1);
    *u=(struct uuid_command){.cmd=LC_UUID,.cmdsize=24};
    memcpy(u->uuid,hv_npt_device_uuid,16);
    struct segment_command_64 *s=(void *)(u+1);
    *s=(struct segment_command_64){.cmd=LC_SEGMENT_64,.cmdsize=72,.vmsize=0x13c4000,
        .filesize=0x13c4000,.maxprot=5,.initprot=5};
    strcpy(s->segname,"__TEXT");
    ++s;
    *s=(struct segment_command_64){.cmd=LC_SEGMENT_64,.cmdsize=72,.vmaddr=0x13c4000,
        .vmsize=0x68000,.fileoff=0x13c4000,.filesize=0x68000,.maxprot=3,.initprot=3};
    strcpy(s->segname,"__DATA_CONST");
    for (size_t i=0;i<sizeof(hv_npt_device_guards)/sizeof(hv_npt_device_guards[0]);++i) {
        const struct HvNptDeviceGuard *g=&hv_npt_device_guards[i];
        memcpy(b+g->offset,g->bytes,g->size);
    }
    uintptr_t *v=(void *)(b+HV_NPT_DEVICE_VTABLE);
    for (size_t i=0;i<3;++i) v[i]=(uintptr_t)b+hv_npt_device_targets[i];
    v[22]=(uintptr_t)b+HV_NPT_DEVICE_DTOR;
    return b;
}
static void guards(void)
{
    uint8_t *b=fixture();
    assert(device_validate((uintptr_t)b));
    for (size_t i=0;i<sizeof(hv_npt_device_guards)/sizeof(hv_npt_device_guards[0]);++i) {
        size_t p=hv_npt_device_guards[i].offset;
        b[p]^=1; assert(!device_validate((uintptr_t)b)); b[p]^=1;
    }
    b[40]^=1; assert(!device_validate((uintptr_t)b)); b[40]^=1;
    *(uint32_t *)(b+0x5000)=0x94000000|((0xd680-0x5000)/4);
    assert(!device_validate((uintptr_t)b));
    *(uint32_t *)(b+0x5000)=0;
    *(uintptr_t *)(b+HV_NPT_DEVICE_VTABLE+0xb0)=0;
    assert(!device_validate((uintptr_t)b));
    assert(!atomic_load(&device_image));
    munmap(b,0x142c000);
}
static int32_t fake_query(void *p,const void *iid,void **out)
{assert(iid==(void *)23); *out=p; return -7;}
static int32_t fake_event(void *args)
{
    struct {void *event;uint64_t value;} *a=args;
    assert(a->event==(void *)31); a->value=99; return 0;
}
static void fake_destroy(void *p) {assert(p==destroy_expected);++destroys;}
static void callbacks(void *base)
{
    assert((uintptr_t)device_calls.query==(uintptr_t)base+0xd680);
    assert((uintptr_t)device_calls.destroy==(uintptr_t)base+HV_NPT_DEVICE_DTOR);
    assert((uintptr_t)device_calls.event_value==(uintptr_t)base+HV_NPT_DEVICE_EVENT);
    uint8_t object[0x2a8]={0};
    uint64_t *queue=calloc(1,0x10030); assert(queue);
    *(uintptr_t *)object=(uintptr_t)base+HV_NPT_DEVICE_VTABLE;
    memcpy(object+0x40,&queue,8);
    queue[0]=8; queue[3]=6;
    queue[0x10008/8]=5; queue[0x10028/8]=31;
    struct HvNptDeviceSnapshot s;
    assert(observed_ops->snapshot(object,&s));
    assert(s.main_goal==7 && s.main_done==6 && s.initializer_goal==4 && s.event==(void *)31);
    queue[0]=0; assert(!observed_ops->snapshot(object,&s)); queue[0]=1;
    queue[0x10028/8]=0; assert(!observed_ops->snapshot(object,&s));
    queue[0x10008/8]=1; assert(observed_ops->snapshot(object,&s));
    device_calls.query=fake_query; device_calls.event_value=fake_event;device_calls.destroy=fake_destroy;
    void *out=NULL; uint64_t value=0;
    assert(observed_ops->query_interface(object,(void *)23,&out)==-7 && out==object);
    assert(observed_ops->event_value((void *)31,&value) && value==99);
    assert(!observed_ops->event_value(NULL,&value));
    destroy_expected=object;
    assert(observed_ops->destroy(object)); assert(destroys==1);
    free(queue);
}
static void *compiler_worker(void *arg)
{
    uint8_t *scheduler=arg;
    pthread_mutex_t *m=(void *)scheduler;
    assert(!pthread_mutex_lock(m));
    while (!__atomic_load_n(scheduler+0x150,__ATOMIC_SEQ_CST))
        assert(!pthread_cond_wait((void *)(scheduler+0x40),m));
    assert(!pthread_mutex_unlock(m));
    assert(!pthread_mutex_lock(&compiler_gate_mutex));
    compiler_entered=true;
    assert(!pthread_cond_broadcast(&compiler_gate_cond));
    while (!compiler_allowed)
        assert(!pthread_cond_wait(&compiler_gate_cond,&compiler_gate_mutex));
    assert(!pthread_mutex_unlock(&compiler_gate_mutex));
    atomic_store(&compiler_done,1);
    return NULL;
}
static void *finalizer_worker(void *device)
{ finalizer_result=observed_ops->destroy(device); return NULL; }
static void compiler_destroy(void *p)
{
    assert(p==destroy_expected && atomic_load(&compiler_done));
    ++destroys; /* Represents freeing the maps the worker previously used. */
}
static void compiler_barrier(bool failure)
{
    uint8_t *base=fixture();
    assert(mprotect(base,0x142c000,PROT_READ)==0);
    assert(install_device_image((uintptr_t)base)==1);
    uint8_t object[0x2a8]={0}, cache[0x180]={0};
    uint8_t *scheduler=cache+0x10;
    uintptr_t cache_address=(uintptr_t)cache;
    memcpy(object+0x2a0,&cache_address,8);
    *(uintptr_t *)cache=(uintptr_t)base+0x13cae88;
    assert(!pthread_mutex_init((void *)scheduler,NULL));
    assert(!pthread_cond_init((void *)(scheduler+0x40),NULL));
    pthread_t thread;
    assert(!pthread_create(&thread,NULL,compiler_worker,scheduler));
    pthread_t original=thread;
    uintptr_t begin=(uintptr_t)&thread,end=begin+8;
    memcpy(scheduler+0x138,&begin,8);memcpy(scheduler+0x140,&end,8);
    memcpy(scheduler+0x148,&end,8);
    device_calls.destroy=compiler_destroy;destroy_expected=object;fail_join=failure;
    pthread_t finalizer;
    if (failure) assert(!observed_ops->destroy(object));
    else assert(!pthread_create(&finalizer,NULL,finalizer_worker,object));
    assert(!pthread_mutex_lock(&compiler_gate_mutex));
    while (!compiler_entered)
        assert(!pthread_cond_wait(&compiler_gate_cond,&compiler_gate_mutex));
    /* A compiler which remains inside its task keeps all maps alive even
     * after stop is visible. The finalizer must be waiting in join here. */
    assert(!destroys && !atomic_load(&compiler_done));
    compiler_allowed=true;
    assert(!pthread_cond_broadcast(&compiler_gate_cond));
    assert(!pthread_mutex_unlock(&compiler_gate_mutex));
    if (failure) {
        assert(!destroys && thread==original);
        assert(!pthread_join(thread,NULL));
    } else {
        assert(!pthread_join(finalizer,NULL));
        assert(finalizer_result==1);
        assert(destroys==1 && !thread && atomic_load(&compiler_done));
    }
    assert(__atomic_load_n(scheduler+0x150,__ATOMIC_SEQ_CST)==1);
    assert(!pthread_cond_destroy((void *)(scheduler+0x40)));
    assert(!pthread_mutex_destroy((void *)scheduler));
    munmap(base,0x142c000);
}
static void transaction(const char *mode)
{
    uint8_t *b=fixture(); uintptr_t *v=(void *)(b+HV_NPT_DEVICE_VTABLE);
    if (!strcmp(mode,"interposed")) v[1]=1;
    if (!strcmp(mode,"protect-fail")) fail_at=1;
    if (!strcmp(mode,"rollback")) fail_at=2;
    if (!strcmp(mode,"rollback-fatal")) {fail_at=2;fail_again=3;}
    if (!strcmp(mode,"ops-fail")) reject_ops=1;
    if (!strcmp(mode,"race")) race=v+1;
    assert(mprotect(b,0x142c000,PROT_READ)==0);
    int r=install_device_image((uintptr_t)b);
    if (!strcmp(mode,"install")) {
        assert(r==1 && observed_ops);
        assert(install_device_image((uintptr_t)b)==1);
        void *out=NULL;
        assert(((int32_t (*)(void *,const void *,void **))v[0])(b,NULL,&out)==42);
        assert(out==b && queries==1);
        assert(((uint32_t (*)(void *))v[1])(b)==77 && adds==1);
        assert(((uint32_t (*)(void *))v[2])(b)==66 && releases==1);
        callbacks(b);
    } else {
        assert(r==(!strcmp(mode,"rollback-fatal")?-1:0));
        for (size_t i=0;i<3;++i)
            assert(v[i]==(((!strcmp(mode,"interposed")||!strcmp(mode,"race"))&&i==1)?1:
                (uintptr_t)b+hv_npt_device_targets[i]));
        if (atomic_load(&device_image))
            assert(install_device_image((uintptr_t)b)==(!strcmp(mode,"rollback-fatal")?-1:0));
        if (!strcmp(mode,"rollback-fatal")) {
            assert(hv_npt_install_device_hooks(NULL)==-1);
            assert(install_device_image(0)==-1);
            assert(strstr(hv_npt_device_hook_status(),"fatal:"));
        }
    }
    munmap(b,0x142c000);
}
static void remove_hooks(const char *mode)
{
    uint8_t *b = fixture(); uintptr_t *v = (void *)(b + HV_NPT_DEVICE_VTABLE);
    assert(!mprotect(b, 0x142c000, PROT_READ));
    assert(install_device_image((uintptr_t)b) == 1);
    if (!strcmp(mode, "remove-protect")) fail_at = protects + 1;
    if (!strcmp(mode, "remove-restore")) fail_at = protects + 2;
    if (!strcmp(mode, "remove-race")) race = v + 1;
    int result = hv_npt_rollback_device_hooks();
    if (!strcmp(mode, "remove")) {
        assert(result == 1 && !device_installed && !atomic_load(&device_fatal));
        for (size_t i = 0; i < 3; ++i) assert(v[i] == (uintptr_t)b + hv_npt_device_targets[i]);
        vm_prot_t protection; assert(device_region((uintptr_t)v, 24, &protection));
        assert(protection == VM_PROT_READ);
        assert(hv_npt_rollback_device_hooks() == 1); /* idempotent */
        assert(install_device_image((uintptr_t)b) == 0); /* original behavior for process lifetime */
    } else {
        assert(result == -1 && atomic_load(&device_fatal));
        assert(hv_npt_rollback_device_hooks() == -1 && hv_npt_install_device_hooks(NULL) == -1);
        if (!strcmp(mode, "remove-race")) {
            assert(v[1] == 1); /* never overwrite another interposer */
            assert(v[0] == (uintptr_t)b + hv_npt_device_targets[0]);
            assert(v[2] == (uintptr_t)b + hv_npt_device_targets[2]);
        }
    }
    munmap(b, 0x142c000);
}
int main(int argc,char **argv)
{
    assert(argc==2);
    if (!strncmp(argv[1],"remove",6)) remove_hooks(argv[1]);
    else if (!strcmp(argv[1],"guards")) guards();
    else if (!strcmp(argv[1],"compiler")) compiler_barrier(false);
    else if (!strcmp(argv[1],"compiler-failure")) compiler_barrier(true);
    else transaction(argv[1]);
    printf("ok: %s\n",argv[1]);return 0;
}
