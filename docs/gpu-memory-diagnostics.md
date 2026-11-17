<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
# GPU allocation diagnostics

This diagnostic build separates three different constraints: the guest's
host-visible graphics aperture, host virtual mappings, and physical/Metal
memory pressure. It does not change the aperture size, shared-memory backing,
DXMT staging allocations, resource ownership, or display resolution policy.

## What the counters mean

- `memory-config:` records the selected guest RAM, preallocated RAM, configured
  RAM cap, cap used at allocation, JIT size, and hostmem window. It separately
  records the configured VA-fit target and the target of the successful probe.
  A zero successful-probe value means there was no successful preallocation
  probe; the fallback allocation does not establish that headroom.
- `HV_3D_ROOM_MB` is a contiguous virtual-address fit test during startup. The
  probe is immediately unmapped. It reserves neither physical memory nor Metal
  capacity and cannot guarantee future allocations. The defaults remain
  2560 MiB with 3D and 1024 MiB without it. The optional environment override
  accepts decimal values of at least 256 MiB; malformed or overflowing values
  fall back to the default.
- `virtual size (used + reserved, not free)` includes reservations. It is not
  free address space. A sampled region gap is also not guaranteed allocatable:
  the kernel can restrict an allocation to particular address ranges, and
  other threads can change mappings during the walk.
- `iOS allows ... more` is the process's remaining dirty-memory allowance,
  not free physical RAM or contiguous mapping capacity. Metal's recommended
  working set is advisory. Do not add Metal allocations to process footprint;
  they can overlap.

The environment file is loaded once before the first JIT acquisition attempt,
and the room override is read again at RAM allocation. The existing VM-start
environment load remains in place. Editing the environment or RAM settings
cannot resize RAM already allocated in this app process; restart the app.

## Phone comparison

Use the same diagnostic IPA for both runs, with one tester at a time. No
environment-file editing, SSH, driver changes, or Windows display-topology
commands are needed.

1. **Run 1:** in Settings > Advanced, set Memory to Automatic. Leave the JIT
   cache, 3D, Sharp display preset, and all other settings unchanged. Shut down
   the guest normally before closing the app, then reopen the app and acquire
   JIT again. Start Windows. In `winvm.log`, check `memory-config:` for the
   actual selected RAM and the passed VA-fit target. The earlier baseline used
   3584 MiB RAM and a 2560 MiB target; record the actual values if they differ.
2. Unfold to the full panel at Sharp. Open and close Edge five times, using the
   same sequence and similar timing for both runs. Record the displayed
   resolution and any missing text, stale rectangles, or driver fallback.
3. Save this run's `winvm.log`, `boot_status.txt`, and `_dxmt.log` locally before
   starting the next run. Keep the full logs private: they may contain network
   addresses and other personal information.
4. **Run 2:** change only Memory to **2560 MB** in the same Advanced picker.
   Shut down the guest and fully restart the app again; reacquire JIT and start
   Windows. Confirm the selected RAM is at most 2560 MiB and the passed room
   target is still 2560 MiB. Repeat step 2 and save the second set of logs.

Collect the startup `memory-config:`, hook-installation status, memory census
and VA-gap lines, and the first allocation-failure diagnostics together with
nearby `blob ... create failed`, `shm texture: mmap failed`, scanout, submit,
fence, and cleanup lines. Keep the first failure in order: later failures can
be consequences of a failed renderer context. A bounded or incomplete VA walk
must not be treated as a complete free-space census.

If Run 2 succeeds, that supports a memory-headroom sensitivity; it does not by
itself prove VA exhaustion, identify a kernel limit, or establish a safe global
Metal budget. If it fails, compare the requested mapping size, file metadata,
errno, region observations, and census at the first failure. Keep staging and
aperture changes separate so the comparison changes only one setting.

## Scope of verification

Host tests can validate argument forwarding, errno preservation, guards,
bounded diagnostics, range-walk bookkeeping, and startup-policy parsing.
They cannot reproduce the phone's exact kernel allocation policy or establish
that Windows remains stable at the full-panel resolution. That requires the
two phone runs above.
