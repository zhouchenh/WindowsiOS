/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Pure startup policy tests: no guest, debugger, Metal calls or allocations. */
#include "../ios/Sources/Native/winios_jit_budget.h"

#include <assert.h>
#include <stdio.h>

static void check_room(bool gpu3d, const char *value, uint32_t expected,
                       enum WinIOSRoomOverride expected_status) {
    enum WinIOSRoomOverride status = WINIOS_ROOM_DEFAULT;
    assert(winios_jit_room_mb(gpu3d, value, &status) == expected);
    assert(status == expected_status);
}

static void overrides(void) {
    check_room(false, NULL, 1024, WINIOS_ROOM_DEFAULT);
    check_room(true, NULL, 2560, WINIOS_ROOM_DEFAULT);
    check_room(false, "4096", 4096, WINIOS_ROOM_OVERRIDE);
    check_room(true, "256", 256, WINIOS_ROOM_OVERRIDE);
    check_room(true, " \t+03072\r\n", 3072, WINIOS_ROOM_OVERRIDE);
    check_room(true, "4294967295", UINT32_MAX, WINIOS_ROOM_OVERRIDE);
    const char *invalid[] = {
        "", " ", "0", "255", "-256", "+", "0x100", "256MiB", "256 0",
        "256.0", "4294967296", "18446744073709551616", "999999999999999999999999"
    };
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        check_room(true, invalid[i], 2560, WINIOS_ROOM_INVALID);
        check_room(false, invalid[i], 1024, WINIOS_ROOM_INVALID);
    }
    assert(winios_jit_room_mb(true, "3584", NULL) == 3584);
}

static void ram_selection(void) {
    /* Existing physical reserve is independent of the VA override. */
    assert(winios_jit_next_ram_mb(8192, 0, UINT64_MAX) == 5632);
    assert(winios_jit_next_ram_mb(8191, 0, UINT64_MAX) == 5376);
    assert(winios_jit_next_ram_mb(4608, 0, UINT64_MAX) == 2048);
    assert(winios_jit_next_ram_mb(4607, 0, UINT64_MAX) == 0);
    assert(winios_jit_next_ram_mb(1, 0, UINT64_MAX) == 0); /* no unsigned underflow */
    assert(winios_jit_next_ram_mb(0, 0, UINT64_MAX) == 16384); /* unknown hardware size */
    assert(winios_jit_next_ram_mb(UINT64_MAX, 0, UINT64_MAX) == 16384);
    assert(winios_jit_next_ram_mb(32768, 4096, UINT64_MAX) == 4096);
    assert(winios_jit_next_ram_mb(32768, 4000, UINT64_MAX) == 3584);
    assert(winios_jit_next_ram_mb(32768, 1024, UINT64_MAX) == 0);
    assert(winios_jit_next_ram_mb(32768, 1023, UINT64_MAX) == 16384);
    /* Simulate two failed VA-fit probes: the production selector must move
     * down without ever exceeding either the physical reserve or user cap. */
    uint64_t mb = winios_jit_next_ram_mb(8192, 4096, UINT64_MAX);
    assert(mb == 4096);
    mb = winios_jit_next_ram_mb(8192, 4096, mb);
    assert(mb == 3584);
    mb = winios_jit_next_ram_mb(8192, 4096, mb);
    assert(mb == 3072);
    unsigned count = 0;
    uint64_t previous = UINT64_MAX;
    while ((mb = winios_jit_next_ram_mb(0, 0, previous))) {
        assert(mb < previous && mb >= 2048);
        previous = mb;
        assert(++count <= 19);
    }
    assert(count == 19 && previous == 2048);
    assert(winios_jit_next_ram_mb(0, 0, 0) == 0);
}

int main(void) {
    overrides();
    ram_selection();
    puts("PASS: JIT headroom override validation and RAM candidate selection");
    return 0;
}
