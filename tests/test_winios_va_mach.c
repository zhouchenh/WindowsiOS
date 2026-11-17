/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <mach/mach.h>
#include <assert.h>
#include <stdio.h>
static kern_return_t fake_region(vm_map_read_t, vm_address_t *, vm_size_t *, vm_region_flavor_t,
                                 vm_region_info_t, mach_msg_type_number_t *, mach_port_t *);
static kern_return_t fake_release(ipc_space_t, mach_port_name_t);
#define WINIOS_VA_REGION fake_region
#define WINIOS_VA_PORT_RELEASE fake_release
#include "../ios/Sources/Native/winios_va_census_mach.h"
static int released, live;
static kern_return_t next_error;
static mach_msg_type_number_t next_count=VM_REGION_BASIC_INFO_COUNT_64;
static kern_return_t fake_region(vm_map_read_t task, vm_address_t *address, vm_size_t *size,
                                 vm_region_flavor_t flavor, vm_region_info_t info,
                                 mach_msg_type_number_t *count, mach_port_t *object) {
    if(live) return vm_region_64(task,address,size,flavor,info,count,object);
    *address=20; *size=10; *count=next_count; *object=123;
    return next_error;
}
static kern_return_t fake_release(ipc_space_t task, mach_port_name_t port) {
    if(live) return mach_port_deallocate(task,port);
    assert(port==123); released++; return KERN_SUCCESS;
}
int main(void) {
    struct WiniosVaMachContext ctx={.task=mach_task_self()};
    uint64_t start,length;
    assert(!winios_va_mach_next(&ctx,0,&start,&length) && start==20 && length==10 && released==1);
    next_error=KERN_INVALID_ADDRESS;
    assert(winios_va_mach_next(&ctx,0,&start,&length)==1 && released==2);
    next_error=KERN_FAILURE;
    assert(winios_va_mach_next(&ctx,0,&start,&length)==-1 && ctx.error==KERN_FAILURE && released==3);
    next_error=KERN_SUCCESS; next_count=0;
    assert(winios_va_mach_next(&ctx,0,&start,&length)==-1 && ctx.error==KERN_INVALID_ARGUMENT && released==4);
    puts("PASS: native metadata validation and ports released on success/end/error/short metadata");
    task_vm_info_data_t vm={0};
    mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
    assert(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&vm,&count)==KERN_SUCCESS && count>=TASK_VM_INFO_REV2_COUNT);
    live=1;
    struct WiniosVaCensus result=winios_va_mach_census(vm.min_address,vm.max_address);
    assert(result.status==WINIOS_VA_COMPLETE || result.status==WINIOS_VA_CALL_LIMIT || result.status==WINIOS_VA_TIME_LIMIT);
    assert(result.calls<=2048 && result.largest_gap<=result.observed_span);
    printf("PASS: passive local Mach walk: task regions=%d walked=%u calls=%u status=%s observedMiB=%llu gapMiB=%llu (not allocatable proof)\n",
           vm.region_count,result.regions,result.calls,winios_va_status_name(result.status),
           (unsigned long long)(result.observed_span>>20),(unsigned long long)(result.largest_gap>>20));
}
