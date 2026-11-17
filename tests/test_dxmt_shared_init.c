/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Actual wrapper code, synthetic image and controlled event/gate callbacks. */
#include <assert.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
static kern_return_t test_protect(vm_map_t,vm_address_t,vm_size_t,boolean_t,vm_prot_t);
static int test_clock(clockid_t,struct timespec *);
static int test_sleep(const struct timespec *,struct timespec *);
#define vm_protect test_protect
#define clock_gettime test_clock
#define nanosleep test_sleep
#include "../devices/dxmt_shared_init.c"
#undef vm_protect
#undef clock_gettime
#undef nanosleep

static int protects,fail_at,fail_again;
static uintptr_t *race;
static _Atomic uint64_t ticks;
static _Atomic unsigned creates,polls,flushed;
static unsigned mode;
static uint8_t dev[0x30],container[0x48],queue[0x10030];
static uint32_t desc[12];
static void *result_marker=(void *)0x1234;
static _Thread_local void **caller_output;
static pthread_mutex_t event_mutex=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t event_cond=PTHREAD_COND_INITIALIZER;
static unsigned event_arrived;

static int test_clock(clockid_t c,struct timespec *ts)
{
    assert(c==CLOCK_MONOTONIC);
    uint64_t t=atomic_fetch_add(&ticks,1000000)+1000000;
    ts->tv_sec=(time_t)(t/1000000000); ts->tv_nsec=(long)(t%1000000000); return 0;
}
static int test_sleep(const struct timespec *a,struct timespec *b)
{ (void)a;(void)b; atomic_fetch_add(&ticks,UINT64_C(1000000000)); return 0; }
static kern_return_t test_protect(vm_map_t m,vm_address_t p,vm_size_t n,boolean_t max,vm_prot_t prot)
{
    ++protects;
    if (protects==fail_at || protects==fail_again) return KERN_PROTECTION_FAILURE;
    kern_return_t r=vm_protect(m,p,n,max,prot);
    if (r==KERN_SUCCESS && race && (prot&VM_PROT_WRITE)) {
        __atomic_store_n(race,1,__ATOMIC_RELEASE);race=NULL;
    }
    return r;
}
static uint8_t *fixture(void)
{
    uint8_t *b=mmap(NULL,0x142c000,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    assert(b!=MAP_FAILED);
    struct mach_header_64 *h=(void *)b;
    *h=(struct mach_header_64){.magic=MH_MAGIC_64,.cputype=CPU_TYPE_ARM64,
        .filetype=MH_DYLIB,.ncmds=3,.sizeofcmds=168};
    struct uuid_command *u=(void *)(h+1);
    *u=(struct uuid_command){.cmd=LC_UUID,.cmdsize=24};memcpy(u->uuid,hv_shared_uuid,16);
    struct segment_command_64 *s=(void *)(u+1);
    *s=(struct segment_command_64){.cmd=LC_SEGMENT_64,.cmdsize=72,.vmsize=0x13c4000,
        .filesize=0x13c4000,.maxprot=5,.initprot=5};strcpy(s->segname,"__TEXT");
    ++s;*s=(struct segment_command_64){.cmd=LC_SEGMENT_64,.cmdsize=72,.vmaddr=0x13c4000,
        .vmsize=0x68000,.fileoff=0x13c4000,.filesize=0x68000,.maxprot=3,.initprot=3};
    strcpy(s->segname,"__DATA_CONST");
    for (size_t i=0;i<sizeof(hv_shared_guards)/sizeof(hv_shared_guards[0]);++i) {
        const struct HvSharedGuard *g=&hv_shared_guards[i];memcpy(b+g->offset,g->bytes,g->size);
    }
    for (size_t i=0;i<2;++i) *(uintptr_t *)(b+hv_shared_slots[i])=(uintptr_t)b+hv_shared_targets[i];
    return b;
}
static void guard_tests(void)
{
    uint8_t *b=fixture();assert(shared_validate((uintptr_t)b));
    for (size_t i=0;i<sizeof(hv_shared_guards)/sizeof(hv_shared_guards[0]);++i) {
        size_t p=hv_shared_guards[i].offset;b[p]^=1;assert(!shared_validate((uintptr_t)b));b[p]^=1;
    }
    b[40]^=1;assert(!shared_validate((uintptr_t)b));b[40]^=1;
    *(uint32_t *)(b+0x5000)=0x94000000|((0xe6c0-0x5000)/4);
    assert(!shared_validate((uintptr_t)b));munmap(b,0x142c000);
}
static int32_t fake_create(void *d,const void *de,const void *data,void **out)
{
    assert(d==dev && de==desc && data==(void *)88);atomic_fetch_add(&creates,1);
    assert(out && out!=caller_output && caller_output && !*caller_output);
    if(mode==5)return -123;
    *out=result_marker;return 0;
}
static uint64_t fake_flush(void *p)
{
    assert(p==queue+0x10008 && caller_output && !*caller_output);
    char status[512];hv_dxmt_shared_init_describe(status,sizeof(status));
    assert(strstr(status,"flush_active=") && !strstr(status,"flush_active=0"));
    atomic_fetch_add(&flushed,1);if(mode==9)hv_dxmt_shared_init_reset();return 7;
}
static int32_t fake_event(void *p)
{
    struct {void *event;uint64_t value;} *a=p;
    assert(a->event==(void *)99 && caller_output && !*caller_output);
    char status[512];hv_dxmt_shared_init_describe(status,sizeof(status));
    assert(strstr(status,"poll_active=") && !strstr(status,"poll_active=0"));
    unsigned n=atomic_fetch_add(&polls,1)+1;
    if(mode==2) {
        hv_dxmt_shared_init_set_gpu_allowed(0);
        hv_dxmt_shared_init_set_gpu_allowed(1); /* Must detect a complete transition. */
    }
    if(mode==4)return -1;
    if(mode==8){hv_dxmt_shared_init_reset();return -1;}
    if(mode==7)hv_dxmt_shared_init_set_gpu_allowed(1);
    if(mode==6) {
        pthread_mutex_lock(&event_mutex);++event_arrived;pthread_cond_broadcast(&event_cond);
        while(event_arrived<2)pthread_cond_wait(&event_cond,&event_mutex);
        pthread_mutex_unlock(&event_mutex);a->value=7;return 0;
    }
    a->value=(mode==3 || mode==2 || n==1)?6:7;return 0;
}
static void runtime_setup(void)
{
    uintptr_t base=0x10000000,table=base+HV_SHARED_VTABLE,p=(uintptr_t)container;
    memcpy(dev,&table,8);memcpy(dev+0x28,&p,8);p=(uintptr_t)queue;memcpy(container+0x40,&p,8);
    table=base+HV_SHARED_CONTAINER_VTABLE;memcpy(container,&table,8);
    p=99;memcpy(queue+0x10028,&p,8);atomic_store(&shared_image,base);
    shared_calls.create[0]=fake_create;shared_calls.create[1]=fake_create;
    shared_calls.flush=fake_flush;shared_calls.event_value=fake_event;
    desc[7]=0;desc[10]=2;hv_dxmt_shared_init_set_gpu_allowed(1);
}
static void *concurrent_create(void *which)
{
    void *out=(void *)1;caller_output=&out;
    assert(create_common((size_t)which,dev,desc,(void *)88,&out)==0 && out==result_marker);
    return NULL;
}
int main(int argc,char **argv)
{
    assert(argc==2);const char *c=argv[1];
    if(!strcmp(c,"guards")){guard_tests();return 0;}
    if(!strcmp(c,"disabled")) {
        unsetenv("HV_DXMT_SHARED_INIT");assert(hv_dxmt_install_shared_init(NULL)==0);
        setenv("HV_DXMT_SHARED_INIT","0",1);assert(hv_dxmt_install_shared_init(NULL)==0);
        assert(!atomic_load(&shared_image));return 0;
    }
    if(!strcmp(c,"install") || !strcmp(c,"interposed") || !strcmp(c,"protect-fail") ||
       !strcmp(c,"rollback") || !strcmp(c,"fatal") || !strcmp(c,"race")) {
        uint8_t *b=fixture();uintptr_t *s0=(void *)(b+hv_shared_slots[0]),*s1=(void *)(b+hv_shared_slots[1]);
        if(!strcmp(c,"interposed"))*s1=1;
        if(!strcmp(c,"protect-fail"))fail_at=1;
        if(!strcmp(c,"rollback"))fail_at=2;
        if(!strcmp(c,"fatal")){fail_at=2;fail_again=3;}
        if(!strcmp(c,"race"))race=s1;
        int r=install_shared_image((uintptr_t)b);
        if(!strcmp(c,"install")) {
            assert(r==1 && *s0==(uintptr_t)create_2d && *s1==(uintptr_t)create_2d1);
            assert(install_shared_image((uintptr_t)b)==1);
        } else if(!strcmp(c,"fatal")) {
            assert(r==-1 && install_shared_image((uintptr_t)b)==-1);
            assert(hv_dxmt_install_shared_init(NULL)==-1);
        } else {
            assert(r==0 && *s0==(uintptr_t)b+hv_shared_targets[0]);
            if(strcmp(c,"interposed") && strcmp(c,"race"))assert(*s1==(uintptr_t)b+hv_shared_targets[1]);
        }
        munmap(b,0x142c000);return 0;
    }
    runtime_setup();void *out=(void *)1;caller_output=&out;
    if(!strcmp(c,"gates")) {
        uint64_t t=atomic_load(&gpu_token);
        hv_dxmt_shared_init_set_gpu_allowed(1);assert(atomic_load(&gpu_token)==t);
        hv_dxmt_shared_init_set_draining(1);assert(!gate_allowed(atomic_load(&gpu_token)));
        hv_dxmt_shared_init_set_gpu_allowed(1);assert(!gate_allowed(atomic_load(&gpu_token)));
        assert(create_2d(dev,desc,(void *)88,&out)==0 && out==result_marker && !atomic_load(&flushed));
        hv_dxmt_shared_init_set_gpu_allowed(0);hv_dxmt_shared_init_set_draining(0);
        assert(!gate_allowed(atomic_load(&gpu_token)));
        hv_dxmt_shared_init_set_presenter_paused(1);
        hv_dxmt_shared_init_set_gpu_allowed(1);assert(!gate_allowed(atomic_load(&gpu_token)));
        assert(create_2d(dev,desc,(void *)88,&out)==0 && out==result_marker && !atomic_load(&flushed));
        hv_dxmt_shared_init_set_gpu_allowed(0);hv_dxmt_shared_init_set_presenter_paused(0);
        assert(!gate_allowed(atomic_load(&gpu_token)));
        uint64_t gate=atomic_load(&gpu_token);atomic_store(&mitigation_state,1);
        hv_dxmt_shared_init_reset();assert(atomic_load(&gpu_token)==gate && atomic_load(&mitigation_state)==2);
        hv_dxmt_shared_init_set_gpu_allowed(1);assert(gate_allowed(atomic_load(&gpu_token)));
        mode=7;assert(create_2d1(dev,desc,(void *)88,&out)==0 && atomic_load(&polls)==2);
        return 0;
    }
    if(!strncmp(c,"invalid-",8) || !strcmp(c,"null-event")) {
        uintptr_t bad=0;unsigned kind=0;
        if(!strcmp(c,"invalid-device"))memcpy(dev,&bad,8);
        else if(!strcmp(c,"invalid-container-null"))memcpy(dev+0x28,&bad,8);
        else if(!strcmp(c,"invalid-container-vtable"))memcpy(container,&bad,8);
        else if(!strcmp(c,"invalid-container-unmapped")){bad=1;memcpy(dev+0x28,&bad,8);}
        else if(!strcmp(c,"invalid-queue-null"))memcpy(container+0x40,&bad,8);
        else if(!strcmp(c,"invalid-queue-unaligned")){bad=1;memcpy(container+0x40,&bad,8);}
        else if(!strcmp(c,"invalid-queue-unmapped")){bad=8;memcpy(container+0x40,&bad,8);}
        else {assert(!strcmp(c,"null-event"));memcpy(queue+0x10028,&bad,8);kind=1;}
        assert(create_2d(dev,desc,(void *)88,&out)==0 && out==result_marker);
        assert(create_2d1(dev,desc,(void *)88,&out)==0 && out==result_marker);
        assert(atomic_load(&creates)==2 && !atomic_load(&flushed) && !atomic_load(&polls));
        assert(atomic_load(&invalid_skips[kind])==2 && atomic_load(&skipped)==2 && !atomic_load(&mitigation_state));
        return 0;
    }
    if(!strcmp(c,"not-shared"))desc[10]=0;
    else if(!strcmp(c,"background"))hv_dxmt_shared_init_set_gpu_allowed(0);
    else if(!strcmp(c,"midwait"))mode=2;
    else if(!strcmp(c,"timeout"))mode=3;
    else if(!strcmp(c,"event-error"))mode=4;
    else if(!strcmp(c,"original-error"))mode=5;
    else if(!strcmp(c,"concurrent"))mode=6;
    else if(!strcmp(c,"reset-event"))mode=8;
    else if(!strcmp(c,"reset-flush"))mode=9;
    else assert(!strcmp(c,"ready"));
    if(mode==6) {
        pthread_t a,b;assert(!pthread_create(&a,NULL,concurrent_create,(void *)0));
        assert(!pthread_create(&b,NULL,concurrent_create,(void *)1));
        assert(!pthread_join(a,NULL) && !pthread_join(b,NULL));
        assert(atomic_load(&creates)==2 && atomic_load(&flushed)==2);return 0;
    }
    int32_t hr=create_2d(dev,desc,(void *)88,&out);
    assert(!active_flush && !atomic_load(&active_poll));
    if(mode==3 || mode==4) {
        assert(hr==0 && out==result_marker && atomic_load(&failures)==1);
        assert(atomic_load(&mitigation_state)&1);
        unsigned previous_polls=atomic_load(&polls);
        assert(create_2d1(dev,desc,(void *)88,&out)==hr && out==result_marker && atomic_load(&creates)==2);
        assert(atomic_load(&flushed)==1 && atomic_load(&polls)==previous_polls);
        hv_dxmt_shared_init_reset();assert(!(atomic_load(&mitigation_state)&1));
        mode=0;
        assert(create_2d1(dev,desc,(void *)88,&out)==0 && out==result_marker);
        assert(atomic_load(&creates)==3 && atomic_load(&flushed)==2 && atomic_load(&waits)==1);
    } else if(mode==5)assert(hr==-123 && !out && !atomic_load(&flushed));
    else {
        assert(hr==0 && out==result_marker && !(atomic_load(&mitigation_state)&1));
        if(mode==8 || mode==9) {
            assert(atomic_load(&mitigation_state)==2 && !atomic_load(&failures));
            assert(atomic_load(&polls)==(mode==8?1u:0u));
            mode=0;assert(create_2d1(dev,desc,(void *)88,&out)==0 && out==result_marker);
            assert(atomic_load(&flushed)==2 && atomic_load(&waits)==1);
        }
        if(mode==2)assert(atomic_load(&polls)==1 && atomic_load(&skipped)==1);
        if(!strcmp(c,"not-shared") || !strcmp(c,"background"))assert(!atomic_load(&flushed));
        if(!strcmp(c,"ready"))assert(atomic_load(&polls)==2 && atomic_load(&waits)==1);
    }
    return 0;
}
