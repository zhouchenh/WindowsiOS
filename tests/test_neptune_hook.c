/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Synthetic-image guards and actual native caller/publication behavior. */
#include <assert.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

static void observed_free(void *);
static kern_return_t test_protect(vm_map_t, vm_address_t, vm_size_t, boolean_t, vm_prot_t);
#define free observed_free
#define vm_protect test_protect
#include "../devices/neptune_hook.c"
#undef free
#undef vm_protect

static _Atomic unsigned frees, captures, submissions;
static int protect_calls, fail_protect_call;
static uintptr_t *race_slot;
static _Thread_local void *held_record;

static void observed_free(void *p)
{
    atomic_fetch_add(&frees, 1);
    free(p);
}

static kern_return_t test_protect(vm_map_t task, vm_address_t address, vm_size_t size,
                                  boolean_t maximum, vm_prot_t protection)
{
    if (++protect_calls == fail_protect_call)
        return KERN_PROTECTION_FAILURE;
    kern_return_t result = vm_protect(task, address, size, maximum, protection);
    if (result == KERN_SUCCESS && race_slot && (protection & VM_PROT_WRITE)) {
        __atomic_store_n(race_slot, (uintptr_t)1, __ATOMIC_RELEASE);
        race_slot = NULL;
    }
    return result;
}

static void capture_and_free(void *p)
{
    atomic_fetch_add(&captures, 1);
    observed_free(p);
}

static void capture_until_submit(void *p)
{
    assert(!held_record);
    held_record = p;
    atomic_fetch_add(&captures, 1);
}

static void submit(void)
{
    atomic_fetch_add(&submissions, 1);
    if (held_record) {
        observed_free(held_record);
        held_record = NULL;
    }
}

static void *fixture(void)
{
    uint8_t *image = mmap(NULL, 0x3f4000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(image != MAP_FAILED);
    struct mach_header_64 *mh = (void *)image;
    *mh = (struct mach_header_64){.magic=MH_MAGIC_64, .cputype=CPU_TYPE_ARM64,
        .cpusubtype=CPU_SUBTYPE_ARM64_ALL, .filetype=MH_DYLIB, .ncmds=3, .sizeofcmds=328};
    struct uuid_command *u = (void *)(mh + 1);
    *u = (struct uuid_command){.cmd=LC_UUID, .cmdsize=sizeof(*u)};
    memcpy(u->uuid, hv_npt_hook_uuid, 16);
    struct segment_command_64 *s = (void *)(u + 1);
    *s = (struct segment_command_64){.cmd=LC_SEGMENT_64, .cmdsize=152,
        .vmsize=0x3e0000, .filesize=0x3e0000, .maxprot=5, .initprot=5, .nsects=1};
    strcpy(s->segname, "__TEXT");
    struct section_64 *sec = (void *)(s + 1);
    strcpy(sec->sectname, "__unwind_info"); strcpy(sec->segname, "__TEXT");
    sec->addr=0x3dbc80; sec->size=0x25b8; sec->offset=0x3dbc80;
    s = (void *)(sec + 1);
    *s = (struct segment_command_64){.cmd=LC_SEGMENT_64, .cmdsize=152,
        .vmaddr=0x3e0000, .vmsize=0x14000, .fileoff=0x3e0000, .filesize=0x14000,
        .maxprot=3, .initprot=3, .nsects=1};
    strcpy(s->segname, "__DATA_CONST");
    sec = (void *)(s + 1);
    strcpy(sec->sectname, "__got"); strcpy(sec->segname, "__DATA_CONST");
    sec->addr=0x3f3020; sec->size=0xcd8; sec->offset=0x3f3020;
    sec->flags=S_NON_LAZY_SYMBOL_POINTERS; sec->reserved1=124;
    for (size_t i=0; i < sizeof(hv_npt_hook_guards)/sizeof(hv_npt_hook_guards[0]); ++i) {
        const struct HvNptHookGuard *g = &hv_npt_hook_guards[i];
        memcpy(image + g->offset, g->bytes, g->size);
    }
    *(uintptr_t *)(image + HV_NPT_HOOK_FREE_SLOT) = (uintptr_t)observed_free;
    return image;
}

static void seal(void *image)
{
    assert(mprotect(image, 0x3f4000, PROT_READ) == 0);
}

static void test_guards(void)
{
    uint8_t *image = fixture();
    struct mach_header_64 *mh = (void *)image;
    assert(validate_image(mh, (intptr_t)image) == HOOK_NOT_INSTALLED);
    for (size_t i=0; i < sizeof(hv_npt_hook_guards)/sizeof(hv_npt_hook_guards[0]); ++i) {
        size_t p=hv_npt_hook_guards[i].offset;
        image[p]^=1;
        assert(validate_image(mh, (intptr_t)image) == HOOK_BAD_CODE);
        image[p]^=1;
    }
    /* Both distinct caller guards matter; reject the previous code-cave patch. */
    image[HV_NPT_HOOK_FREE_RETURN-4]^=1;
    assert(validate_image(mh, (intptr_t)image) == HOOK_BAD_CODE);
    image[HV_NPT_HOOK_FREE_RETURN-4]^=1;
    image[HV_NPT_HOOK_FINISH_RETURN-4]^=1;
    assert(validate_image(mh, (intptr_t)image) == HOOK_BAD_CODE);
    image[HV_NPT_HOOK_FINISH_RETURN-4]^=1;
    image[40]^=1;
    assert(validate_image(mh, (intptr_t)image) == HOOK_BAD_UUID);
    image[40]^=1;
    mh->sizeofcmds=UINT32_MAX;
    assert(validate_image(mh, (intptr_t)image) == HOOK_BAD_HEADER);
    mh->sizeofcmds=328;
    assert(validate_image(mh, (intptr_t)image+8) == HOOK_BAD_LAYOUT);
    uint32_t saved=*(uint32_t *)(image+60);
    *(uint32_t *)(image+60)=8;
    assert(validate_image(mh, (intptr_t)image) == HOOK_BAD_HEADER);
    *(uint32_t *)(image+60)=saved;
    assert(hv_npt_install_free_hook(NULL, capture_and_free, submit) == 0);
    assert(hv_npt_install_free_hook((void *)malloc, NULL, submit) == 0);
    assert(hv_npt_install_free_hook((void *)malloc, capture_and_free, NULL) == 0);
    assert(!published);
    munmap(image, 0x3f4000);
}

static void test_install(const char *mode)
{
    uint8_t *image=fixture();
    uintptr_t *slot=(void *)(image+HV_NPT_HOOK_FREE_SLOT);
    if (!strcmp(mode,"interposed")) *slot=1;
    seal(image);
    if (!strcmp(mode,"rollback")) fail_protect_call=2;
    if (!strcmp(mode,"protect-fail")) fail_protect_call=1;
    if (!strcmp(mode,"race")) race_slot=slot;
    int ok=install_image((void *)image,(intptr_t)image,capture_and_free,submit,(uintptr_t)observed_free);
    vm_prot_t protection;
    assert(region((uintptr_t)slot,8,&protection) && protection==VM_PROT_READ);
    if (!strcmp(mode,"install")) {
        assert(ok && *slot==(uintptr_t)npt_free_hook);
        assert(published && published->capture==capture_and_free && published->submit==submit);
        assert(published->return_pc==(uintptr_t)image+HV_NPT_HOOK_FREE_RETURN);
        assert(published->finish_pc==(uintptr_t)image+HV_NPT_HOOK_FINISH_RETURN);
        assert(install_image((void *)image,(intptr_t)image,capture_and_free,submit,(uintptr_t)observed_free));
        assert(!install_image((void *)image,(intptr_t)image,capture_until_submit,submit,(uintptr_t)observed_free));
    } else {
        assert(!ok);
        if (!strcmp(mode,"race") || !strcmp(mode,"interposed")) assert(*slot==1);
        else assert(*slot==(uintptr_t)observed_free);
        if (!strcmp(mode,"rollback") || !strcmp(mode,"race")) {
            assert(published);
            assert(!install_image((void *)image,(intptr_t)image,capture_and_free,submit,(uintptr_t)observed_free));
            assert(atomic_load(&hook_status)==HOOK_RETRY_REJECTED);
        } else assert(!published);
    }
    /* Every executable guard remains unchanged after success and failure. */
    assert(validate_image((void *)image,(intptr_t)image)==HOOK_NOT_INSTALLED);
    munmap(image,0x3f4000);
}

#if defined(__aarch64__)
extern void npt_test_record_call(void *), npt_test_finish_call(void *);
extern char npt_test_record_return, npt_test_finish_return;
__asm__(".text\n.p2align 2\n.globl _npt_test_record_call\n_npt_test_record_call:\n"
        "stp x29,x30,[sp,#-16]!\nmov x29,sp\nbl _npt_free_hook\n"
        ".globl _npt_test_record_return\n_npt_test_record_return:\n"
        "ldp x29,x30,[sp],#16\nret\n"
        ".globl _npt_test_finish_call\n_npt_test_finish_call:\n"
        "stp x29,x30,[sp,#-16]!\nmov x29,sp\nbl _npt_free_hook\n"
        ".globl _npt_test_finish_return\n_npt_test_finish_return:\n"
        "ldp x29,x30,[sp],#16\nret\n");

static struct HookState caller_state(void (*capture)(void *))
{
    return (struct HookState){.return_pc=(uintptr_t)&npt_test_record_return,
        .finish_pc=(uintptr_t)&npt_test_finish_return,.capture=capture,.submit=submit};
}

static void test_callers(void)
{
    static struct HookState state;
    state=caller_state(capture_until_submit);
    atomic_store_explicit(&published,&state,memory_order_release);
    void *p=malloc(8);
    npt_test_record_call(p);
    assert(held_record==p && captures==1 && frees==0 && submissions==0);
    npt_free_hook(malloc(8)); /* another caller must go straight to free */
    assert(captures==1 && frees==1 && submissions==0);
    npt_test_finish_call(malloc(8));
    assert(!held_record && captures==1 && frees==3 && submissions==1);
    npt_test_finish_call(malloc(8)); /* empty batch still frees its context */
    assert(frees==4 && submissions==2);
}

static void *worker(void *unused)
{
    (void)unused;
    for (int i=0;i<20000;++i) {
        npt_test_record_call(malloc(8));
        npt_free_hook(malloc(8));
    }
    return NULL;
}

static void test_publication(void)
{
    pthread_t threads[4];
    static struct HookState state;
    state=caller_state(capture_and_free);
    for (int i=0;i<4;++i) assert(!pthread_create(&threads[i],NULL,worker,NULL));
    atomic_store_explicit(&published,&state,memory_order_release);
    for (int i=0;i<4;++i) assert(!pthread_join(threads[i],NULL));
    assert(frees==160000 && captures<=80000 && submissions==0);
}
#endif

static void test_parents(void)
{
    uint8_t *image=mmap(NULL,0x13c4000,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    assert(image!=MAP_FAILED);
    struct mach_header_64 *mh=(void *)image;
    *mh=(struct mach_header_64){.magic=MH_MAGIC_64,.cputype=CPU_TYPE_ARM64,
        .cpusubtype=CPU_SUBTYPE_ARM64_ALL,.filetype=MH_DYLIB,.ncmds=2,.sizeofcmds=96};
    struct uuid_command *u=(void *)(mh+1);
    *u=(struct uuid_command){.cmd=LC_UUID,.cmdsize=24};
    memcpy(u->uuid,hv_npt_dxmt_uuid,16);
    struct segment_command_64 *s=(void *)(u+1);
    *s=(struct segment_command_64){.cmd=LC_SEGMENT_64,.cmdsize=72,
        .vmsize=0x13c4000,.filesize=0x13c4000,.maxprot=5,.initprot=5};
    strcpy(s->segname,"__TEXT");
    memcpy(image+HV_NPT_DXMT_CREATE_ADDRESS,hv_npt_dxmt_create_bytes,sizeof(hv_npt_dxmt_create_bytes));
    assert(dxmt_image(mh));
    u->uuid[0]^=1; assert(!dxmt_image(mh)); u->uuid[0]^=1;
    for(size_t i=0;i<sizeof(hv_npt_parent_methods)/sizeof(hv_npt_parent_methods[0]);++i) {
        const struct HvNptParentMethod *m=&hv_npt_parent_methods[i];
        uint8_t *fn=image+m->address;
        memcpy(fn,hv_npt_get_device_prefix,16);
        uint32_t load=0xf9400014u | (uint32_t)((m->parent_offset/8)<<10);
        memcpy(fn+16,&load,4); memcpy(fn+20,hv_npt_get_device_suffix,36);
        uint8_t child[0x68]={0};
        void *unmapped_parent=(void *)(uintptr_t)1, *raw=NULL;
        memcpy(child+m->parent_offset,&unmapped_parent,sizeof(void *));
        assert(read_parent_at((uintptr_t)image,(uintptr_t)fn,(uintptr_t)child,&raw));
        assert(raw==unmapped_parent); /* Never dereferenced or AddRef'd. */
        fn[16]^=4; raw=NULL;
        assert(!read_parent_at((uintptr_t)image,(uintptr_t)fn,(uintptr_t)child,&raw));
        fn[16]^=4;
        assert(!read_parent_at((uintptr_t)image,(uintptr_t)fn+4,(uintptr_t)child,&raw));
        assert(!read_parent_at((uintptr_t)image,(uintptr_t)fn,UINTPTR_MAX,&raw));
    }
    void *raw=(void *)1;
    assert(!hv_npt_read_child_parent(NULL,&raw) && !raw);
    munmap(image,0x13c4000);
}

int main(int argc,char **argv)
{
    assert(argc==2);
    if(!strcmp(argv[1],"guards")) test_guards();
    else if(!strcmp(argv[1],"parents")) test_parents();
#if defined(__aarch64__)
    else if(!strcmp(argv[1],"callers")) test_callers();
    else if(!strcmp(argv[1],"publication")) test_publication();
#endif
    else test_install(argv[1]);
    printf("neptune hook: %s passed\n",argv[1]);
    return 0;
}
