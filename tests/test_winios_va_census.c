/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "../ios/Sources/Native/winios_va_census.h"
#include <assert.h>
#include <stdio.h>

struct Region { uint64_t address, length; int result; };
struct Input {
    struct Region rows[4];
    unsigned count, used, ticks;
    uint64_t time_step, start_time;
};
static int next(void *opaque, uint64_t cursor, uint64_t *address, uint64_t *length) {
    struct Input *in = opaque;
    (void)cursor;
    if (in->used == in->count) return 1;
    struct Region r = in->rows[in->used++];
    *address = r.address; *length = r.length;
    return r.result;
}
static uint64_t now(void *opaque) {
    struct Input *in = opaque;
    return in->start_time + in->time_step * in->ticks++;
}
static struct WiniosVaCensus run(struct Input *in, uint64_t lo, uint64_t hi, unsigned calls, uint64_t time) {
    return winios_va_census(lo, hi, calls, time, next, now, in);
}
int main(void) {
    struct Input in = {.rows={{20,10,0},{50,10,0}}, .count=2};
    struct WiniosVaCensus r = run(&in,10,100,8,100);
    assert(r.status==WINIOS_VA_COMPLETE && r.largest_gap==40 && r.regions==2 && r.calls==3 && r.observed_span==90);
    in=(struct Input){.rows={{5,20,0},{30,90,0}},.count=2};
    r=run(&in,10,100,8,100);
    assert(r.status==WINIOS_VA_COMPLETE && r.largest_gap==5 && r.regions==2 && r.calls==2 && r.observed_span==90);
    in=(struct Input){.rows={{101,10,0}},.count=1}; r=run(&in,10,100,8,100);
    assert(r.status==WINIOS_VA_COMPLETE && r.largest_gap==90 && r.regions==0);
    in=(struct Input){0}; r=run(&in,0,100,8,100);
    assert(r.status==WINIOS_VA_COMPLETE && r.largest_gap==100 && r.calls==1);
    in=(struct Input){.rows={{20,10,0},{50,10,0}},.count=2}; r=run(&in,10,100,1,100);
    assert(r.status==WINIOS_VA_CALL_LIMIT && r.largest_gap==10 && r.observed_span==20 && r.calls==1);
    in=(struct Input){.rows={{20,10,0}},.count=1,.time_step=10}; r=run(&in,10,100,8,20);
    assert(r.status==WINIOS_VA_TIME_LIMIT && r.largest_gap==10 && r.calls==1 && r.observed_span==20);
    in=(struct Input){0}; r=run(&in,0,100,0,100);
    assert(r.status==WINIOS_VA_CALL_LIMIT && r.calls==0 && !r.largest_gap);
    in=(struct Input){0}; r=run(&in,0,100,8,0);
    assert(r.status==WINIOS_VA_TIME_LIMIT && r.calls==0);
    in=(struct Input){.rows={{20,10,0},{0,0,-1}},.count=2}; r=run(&in,10,100,8,100);
    assert(r.status==WINIOS_VA_QUERY_ERROR && r.largest_gap==10 && r.observed_span==20);
    const struct Region malformed[]={ {20,0,0},{UINT64_MAX-3,8,0},{0,5,0},{20,10,2} };
    for(unsigned i=0;i<sizeof malformed/sizeof malformed[0];i++) {
        in=(struct Input){.count=1}; in.rows[0]=malformed[i]; r=run(&in,10,100,8,100);
        assert(r.status==WINIOS_VA_MALFORMED && r.calls==1 && !r.largest_gap && !r.observed_span);
    }
    in=(struct Input){.rows={{10,20,0},{25,20,0}},.count=2}; r=run(&in,10,100,8,100);
    assert(r.status==WINIOS_VA_MALFORMED && !r.largest_gap && r.observed_span==20);
    in=(struct Input){.rows={{10,20,0},{0,5,0}},.count=2}; r=run(&in,10,100,8,100);
    assert(r.status==WINIOS_VA_MALFORMED && r.observed_span==20);
    in=(struct Input){0}; r=run(&in,100,100,8,100);
    assert(r.status==WINIOS_VA_BAD_BOUNDS && !r.calls);
    r=run(&in,100,0,8,100); assert(r.status==WINIOS_VA_BAD_BOUNDS && !r.calls);
    in=(struct Input){.start_time=UINT64_MAX}; r=run(&in,0,100,8,100);
    assert(r.status==WINIOS_VA_TIME_LIMIT && !r.calls);
    in=(struct Input){.start_time=UINT64_MAX-10,.time_step=20}; r=run(&in,0,100,8,100);
    assert(r.status==WINIOS_VA_TIME_LIMIT && !r.calls);
    in=(struct Input){.rows={{UINT64_MAX-10,10,0}},.count=1}; r=run(&in,UINT64_MAX-20,UINT64_MAX,8,100);
    assert(r.status==WINIOS_VA_COMPLETE && r.largest_gap==10 && r.observed_span==20);
    puts("PASS: VA gaps, clipping, malformed regions, overflow, termination and budgets");
}
