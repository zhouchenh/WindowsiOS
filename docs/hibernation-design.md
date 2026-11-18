# Hibernation for server mode: design

Status: proposal, not implemented. Branch `duo`. This design draws on three read-only investigations: a host-side save state, how fast RAM can be written, and Windows S4 inside the guest. Anything marked UNVERIFIED has not been measured or confirmed.

## 1. The problem

In server mode, Windows keeps running while the app is in the background. iOS keeps the app alive because it plays silent audio (`ios/Sources/ServerMode.swift:8-12, 128-140`). iOS can still end the app at any moment:

- **jetsam**: iOS kills the app to reclaim memory.
- **swipe-away**: the user closes the app from the app switcher.
- **thermal kill**: iOS kills the app because the device is too hot.
- **RunningBoard kills**: the iOS process manager kills the app, for example for holding a file lock while suspended.
- **other**: our own crashes, or losing the JIT or the debugger.

To Windows, every one of these is a power cut. The goal is that a kill is not a power cut: the next launch can bring Windows back where it was.

Apple gives no warning before most of these kills. Jetsam is a SIGKILL with no callback (Apple, "Identifying high-memory use with jetsam event reports"). `applicationWillTerminate(_:)` gets about 5 seconds, and Apple only says it "may be called" for an app running in the background. A memory warning comes only after suspended apps have already been killed, and it promises no lead time. So the only protection against an unannounced kill is a save taken **before** the kill.

## 2. Recommendation

Use both mechanisms, each for what it does well.

1. **Primary: host checkpoints (Option A).** The app saves the whole machine: dirty guest RAM, vCPU state, device state, and copy-on-write clones of the disk images and `vars.fd`. All of them are captured at the same paused instant. Windows keeps running afterwards. After a kill, the next launch restores the last checkpoint. To Windows, it looks like a long freeze followed by a clock step and dropped TCP connections. Work done after the last checkpoint is lost.
   - v1 takes a full stop-and-copy on lifecycle events.
   - v2 adds rolling incremental checkpoints every 10-30 s, using dirty-page tracking in the software MMU.
2. **Secondary, opt-in: Windows hibernation (S4, Option B).** This is a "Hibernate Windows" action for the user, and optionally the critical battery and thermal guard can use it. It is supported by Microsoft and needs very little engine work. Its state lives on the guest's own disk. But Windows needs tens of seconds to hibernate, and once it has, the server is down. S4 can't protect against an unannounced kill, so it complements checkpoints and doesn't replace them.
3. **Rejected: Modern Standby (Option C).** Modern Standby keeps state in RAM, so a kill still destroys it. The board also doesn't declare it: `LOW_POWER_S0_IDLE` is not set (`devices/acpi.c:590-592`).
4. **Rejected: file-backed (`MAP_SHARED`) guest RAM.** It would trigger Apple's `fc-thrashing` jetsam reason. It would lose the ledger-exempt, no-footprint allocation (`devices/winvirt.c:23-58`, `ios/Sources/Native/winios_jit.c:155-203`). And the kernel writes pages back on its own schedule, so the file would run ahead of the saved CPU and device state.

### Why host checkpoints are feasible here

- **There is already a safe stopping point.** `hv_winvm_set_paused` makes every vCPU stop between translated blocks (`host/winvm.c:326-330`, `core/dispatch.c:864-876, 982-987`).
- **No disk I/O is in flight once the vCPUs stop.** Guest-initiated device work runs synchronously on the vCPU thread. For example, NVMe works through its whole submission queue inside the doorbell write (`devices/nvme.c:524-532`), and 2D virtio-gpu requests are handled in notify (`devices/virtio_gpu.c:475-492`).
- **The state to save is small.** It is about 60 architectural fields per CPU, the GIC and ITS arrays, and register files for NVMe, xHCI, virtio, HDA, PL011/031/061, fw_cfg, pflash and GED.
- **Everything about the TLB, MMU caches and JIT can be rebuilt.** A restore starts with an empty code cache, the same state as after a full flush (`winvm.c:379`).

## 3. What a checkpoint contains

| Part | How | Notes |
|---|---|---|
| Guest RAM (about 3.5 GB) | v1: a compact record log of non-zero 4 KB pages. v2: base image plus delta logs | Not a sparse file mirroring guest RAM: APFS doesn't keep 4 KB holes in practice (measured). Optional LZ4. Each record has a CRC32C |
| vCPUs | Architectural `HvCpu` fields (`core/cpu.h:107-190`), including FPCR and FPSR captured by each CPU thread | The exclusive monitor, TLB, ret_tab, ijc and per-CPU caches are rebuilt instead |
| Interrupts | GICv3 distributor, redistributors, CPU interfaces, ITS tables and queue pointers | Call `hv_gicv3_update` after loading |
| Devices | Explicit, versioned save and load code per device. No raw struct dumps, because the structs hold pointers, mutexes and callbacks | Host-side queues are dropped: xHCI reports, the slirp rx queue, HDA PCM rings. HDA and xHCI timestamps are rebased |
| 2D GPU | Resource table, backing lists, scanout and display override | Only allowed when the running driver negotiated 2D and the renderer is idle (`virtio_gpu.c:597`, `virtio_gpu3d.h:39-45`) |
| Disks and NVRAM | `fsync`, then `clonefile(2)` of disk0, disk1 and `vars.fd` while paused | Required for correctness. NVMe FLUSH is a no-op on iOS (`host/winvm.c:236-240`), so the live disk runs ahead of any older RAM |
| Manifest | ram_mb, ncpus, firmware hash, disk paths and sizes, device set (sound, battery, RTC, IPv6, GPU), state-format version, app build, time and host counter | A restore is refused if anything doesn't match |

Storage location: `Application Support/Hibernation/`, excluded from backup, never in Caches or tmp. The files use `NSFileProtectionCompleteUntilFirstUserAuthentication`, because files of class Complete can't be written while the phone is locked. The writer uses raw file descriptors and no `flock` or SQLite locks, to avoid the `0xdead10cc` kill.

Layout:

```
Hibernation/
  current            -> points at the newest committed generation
  gen-0007/
    manifest.json
    machine.state    (CPUs, GIC, devices)
    ram.base         (record log)
    ram.delta-0001..N (v2)
    disk0.img  disk1.img  vars.fd   (APFS clones, one per commit)
  gen-0006/          (previous generation, kept as a fallback)
```

**Atomic commit.** The writer builds a new generation or delta. It writes a commit record that holds the device state and a CRC, then renames or updates `current`. On restore, the app replays up to the last complete commit and discards a torn tail. Data written with `write()` sits in the kernel page cache and survives an app kill without `fsync` (standard kernel behaviour; UNVERIFIED on iOS specifically). The app still calls `fsync` at commit so that a phone crash leaves a usable older generation.

## 4. Taking a checkpoint (the pause)

1. Refuse if 3D is negotiated or the renderer is busy, if free space is too low, or if a stop-the-world flush is pending. The checkpoint waits for that flush to finish (`dispatch.c:880-914`).
2. Set paused and kick all CPUs. **New:** wait on a parked-for-pause count, because `active==0` alone also matches WFI and powered-off CPUs. **New:** each CPU thread stores FPCR and FPSR into its `HvCpu` (`enter.S:88-90` keeps them in host registers), for example by calling `hv_fp_leave` in `wait_while_paused`.
3. Take `hv_dev_lock`, `gic->mu` and every device mutex, then serialize the machine state.
4. RAM: v1 copies all non-zero pages. v2 copies the dirty pages into a no-footprint staging buffer, then clears the dirty bitmap and drops write tags.
5. `fsync`, then `clonefile` each disk image and `vars.fd`.
6. Release the locks and resume Windows. A writer thread then writes the staged pages to storage in coalesced 1-8 MB records. Single 4 KB writes are 20-40 times slower (measured).

Expected pause: 5-20 ms for 50 MB of dirty pages in v2 (measured on the M1 host: memcpy rate plus a clonefile of a 1 GB file). A v1 full save takes about 1.2-4 s at iPhone SLC-cache write speeds (third-party figures, UNVERIFIED on the foldable). For v1, Windows only has to stay paused while the pages are copied, not while they are written. With no staging buffer that large, v1 writes pages directly from guest RAM while paused, which is why v1 is limited to lifecycle events.

**Guest time.** The guest counter is raw `mach_absolute_time`, inlined in translated code (`core/translate.c:1511-1569`) and also used in `sysreg.c`, the timer and the dispatcher's deadline checks. A global **counter bias** must be added to all of these. Policy: freeze guest time across the gap (`bias = saved_guest_count - host_now`). Windows already experiences this whenever the iPhone sleeps. After a restore, the app bumps `http://10.0.2.4/resumed.txt` so that the WinKit Clock task resyncs w32time (`winkit/clock_setup.ps1:8-35`). The PL031 RTC already follows host time.

## 5. What happens on each iOS event

| iOS event | Today | With this design |
|---|---|---|
| Entering server mode or going to the background (after auto-2D finishes) | Windows keeps running in 2D | **Base checkpoint.** v1: full stop-and-copy, run inside the background task the app already holds (`winios_bridge.m:470-511`). v2: pre-copy (write non-zero pages while Windows runs, repeat for pages dirtied meanwhile, then a short final pause). Then rolling incrementals |
| While in the background (v2) | - | Incremental checkpoint every 10-30 s, adaptive: a longer interval when the dirty rate is low, a skip when nothing changed |
| Phone locked | Same as background | Same as background. The file protection class allows writes while locked |
| Memory warning or `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` | `fsync` of disk0 only (`winios_bridge.m:412-417`) | Immediate incremental checkpoint (v2), or a v1 full save if the last one is old. The writer is bounded (64-256 MB staging) so its own page-cache use doesn't make things worse |
| Thermal `.serious` | Shown only | Checkpoint now, before a possible `0xc00010ff` kill |
| Thermal `.critical` or battery critical (`ServerMode.swift:280-310`) | Pauses Windows and notifies | Checkpoint, then pause as today. If the user opted in to S4: ask Windows to hibernate instead, then stop |
| Audio interruption begins (keep-alive stops, app becomes suspendable) | Logged only (`winios_bridge.m:399-410`) | `beginBackgroundTask`, take a checkpoint, then pause Windows before iOS suspends the app |
| `applicationWillTerminate` (about 5 s; may not arrive) | Disk sync dispatched asynchronously, so it may never run (`winios_bridge.m:746-753`) | **Synchronous** final incremental checkpoint (v2) or disk sync (v1), within the 5 s. Never rely on it |
| Jetsam, swipe-away, thermal or RunningBoard kill, crash, JIT loss | Power cut | Nothing can run. The next launch restores the last commit. Loss window = checkpoint interval plus writer lag |
| Foreground with 3D in use | - | **No checkpoints** (Metal, virgl, Neptune and hostmem state can't be saved). The status bar says "Not protected while 3D is on". The app switches to 2D when it goes to the background, as today, and the base checkpoint follows |
| Windows shuts down or reboots cleanly (PSCI SYSTEM_OFF or SYSTEM_RESET) | Disk flushed | Delete all checkpoints: they no longer match the disk. After an S4 hibernate, also set a "hibernated" flag (section 7) |
| User taps "Hibernate now" | - | Foreground: switch to 2D if needed (the hot switch needs the GPU), take a full checkpoint, stop the VM. Optionally use S4 instead (section 7) |

## 6. Resuming

On launch, if `current` points at a valid commit:

1. **Show the resume card.** "Windows was saved at 14:32:05 (3 min ago). Resume / Start Windows fresh / Decide later." Decide later keeps the checkpoint and doesn't start the VM. Whether Resume should happen automatically when server mode is on is an open question (section 12).
2. **Re-acquire the JIT** with the existing debugger-based flow (`winios_jit.c`). It allocates the preallocated guest RAM. **RAM size must equal the manifest's `ram_mb`.** Today the size can vary from launch to launch (`winios_bridge.m:1828-1839`). While a checkpoint exists, the app asks for the saved size. If it can't get it, it refuses with the reason ("Windows was saved with 3584 MB; only 3072 MB is available now") and offers Retry or Start fresh.
3. **Check the manifest:** config fingerprint, state-format version, firmware hash, disk sizes. On a mismatch, refuse and explain.
4. **Swap the disks back.** Clone the snapshot's disk0, disk1 and `vars.fd` over the live files (unlink, then clone, so the snapshot copy stays restorable). Anything Windows wrote after the checkpoint is discarded. That is what makes the restore consistent.
5. **Build the board with the identical config,** but skip `hv_winvirt_reset_cpu` (`winvm.c:254`).
6. **Load RAM:** read the base, replay deltas up to the last commit, decode LZ4 into the no-footprint region. Don't use `mmap MAP_PRIVATE`, whose dirtied pages count toward the footprint.
7. **Load CPU and device state.** Then set the counter bias, call `hv_gicv3_update` and `hv_timer_update`, re-run `on_config_write` so BARs are placed again, re-fire the fw_cfg ramfb callback, rebase the HDA `base_ns`/`last_ns` and the xHCI touch timers, and restart the audio backends for running streams. The GED battery event is raised again from the current host battery.
8. **Start the vCPUs** with `hv_winvm_start` (`winvm.c:397-412`). The JIT cache starts empty, so expect a few seconds of retranslation warm-up (UNVERIFIED).
9. **Network.** slirp starts fresh and port forwards are reapplied from the rule store (`net_slirp.c:2150-2155`). Old TCP connections (RDP, SSH, share) get an RST on their next segment (`tcp_input.c:381-401`) and fail quickly. Clients reconnect. The guest IP stays 10.0.2.15, so slirp state isn't saved.
10. **Clock.** Bump `resumed.txt` so that w32time resyncs.
11. **3D.** Every checkpoint is a 2D machine, so Windows always resumes in 2D. If the user's saved preference is 3D and the app is in the foreground, run the existing 2D-to-3D hot switch (`ServerMode.swift:330-357`) once the desktop is up. In the background, stay in 2D until the app comes forward.
12. **Housekeeping.** The restored generation stays as the fallback until the next commit succeeds.

**Start Windows fresh** cold-boots from the live disk, as after a power cut today, and deletes the checkpoints after a confirmation. **WINKIT updates:** while a checkpoint exists, the bundled-WINKIT replacement (`winios_bridge.m:1866-1879`) is held back, because the restored Windows has that volume mounted and cached.

## 7. Windows S4 (opt-in)

- **Step 1, a test** (needs the user's go-ahead, because it changes the guest; it can run on the Mac): `powercfg /h on`, `powercfg /h /type full`, `powercfg /a`. Microsoft says Windows ignores the hardware-reduced sleep fields in the FADT, and Snapdragon laptops without `_S4` do hibernate. But a Parallels user saw Hibernate greyed out in a 24H2 Arm VM, so this is UNVERIFIED for our board.
- **If Windows refuses:** add `\_S4` and `\_S5` at root scope, add `SLEEP_CONTROL_REG` and `SLEEP_STATUS_REG` to the FADT as GAS fields pointing at unused GED page offsets, and decode SLP_TYP and SLP_EN in `ged_write`. QEMU's GED is the model. About 40-80 lines.
- **Trigger:** a PNP0C0E sleep button on a new GED bit with `SBUTTONACTION=2`, or a WinKit helper that runs `shutdown /h` over the 10.0.2.4 channel. The power button keeps meaning shut down.
- **WinKit `power.ps1`:** today it forces hibernation off (`winkit/power.ps1:193-198`). The opt-in path runs `powercfg /h on` and `/type full`, keeps `HIBERNATEIDLE=0`, and sets `HiberbootEnabled=0`. Without that last setting, every "Shut down (ask Windows)" becomes a fast-startup hibernate exposed to config changes.
- **Host side:** a "hibernate requested" flag turns the next SYSTEM_OFF into "hibernated". While that flag is set, the app locks RAM size, CPU count (4), the battery device, the WINKIT disk and the ACPI tables, and explains any refusal.
- **Cost:** about 10-60 s to hibernate and 15-60 s to resume (estimates, unmeasured). A hiberfil of about 1.4 GB on C:. The guest drivers (virtio-gpu and Neptune, NetKVM, virtio-snd, xHCI HID, stornvme in dump mode) are untested through D3 and resume, and no crash dump has ever completed on this board.

## 8. User interface

All strings in Chinese and English (`L(...)`), like the rest of the app.

- **Server mode settings, a new "Hibernation" section:**
  - "Protect Windows from being closed" toggle (default proposed: on with server mode).
  - Save interval: 10 s / 30 s / 2 min / only when leaving the app.
  - Storage used, with a "Delete saved state" button.
  - The S4 opt-in: "Let Windows hibernate itself (slower, needs setup in Windows)".
- **Status bar:** "Saved 12 s ago". "Not protected: 3D is on". "Not saved: low storage" (amber).
- **"Hibernate now"** in the power menu, next to "Shut down (ask Windows)".
- **Resume card** at launch, as in section 6. Refusals state the exact mismatch.
- **Notifications:** "Windows was restored to 14:32" after a resume that followed a kill, and "Couldn't save Windows: storage is low" when a checkpoint fails in the background.

## 9. Storage and wear

- **RAM base:** about 1.5-3.5 GB, depending on how much of RAM is zero (unmeasured) and on LZ4 (ratio 1.74 on proxy data). Two generations kept: up to about 7 GB worst case.
- **Delta logs:** dirty MB per interval, bounded by compaction.
- **Disk clones:** they share blocks with the live image. Their real cost is the blocks Windows has rewritten since the oldest kept commit.
- **Minimum free space:** refuse checkpoints and show a warning below a threshold (proposed: 2 x the base size + 2 GB), so that iOS doesn't start purging (`0xbaddd15c`).
- **Wear:** writes per day ≈ unique dirty bytes per interval × intervals per day. For example, 10 MB every 10 s comes to about 86 GB/day. That is why v1 saves only on lifecycle events, v2 adapts its interval to the dirty rate, and a full 3.5 GB dump is never made on a timer. Heavy writing can also trigger Apple's non-fatal `EXC_RESOURCE` disk-write report.

## 10. Phased plan

| Phase | Work | Effort |
|---|---|---|
| 0. Spikes and measurements | Mac: dirty-rate counter (core instrumentation only); clonefile time on a real 64 GB+ fragmented Windows image; the S4 `powercfg` test (needs the user's OK). Phone: does `willTerminate` arrive on swipe-away in server mode (log from `BackgroundTest.swift`); clonefile time and whether it captures dirty buffered data; NAND write speed | 2-4 days |
| 1. Mac v1 round trip | Pause protocol (count of parked CPUs, FPCR/FPSR capture). CPU save/load. Counter bias through translator, sysreg, timer and dispatcher. GIC and ITS. PCIe generic. virtio and virtio-net. 2D virtio-gpu. NVMe. xHCI. HDA. PL011/031/061, GED, fw_cfg, pflash. Disk and `vars.fd` clones. RAM stop-and-copy. Manifest and format. `build/winvm` flags: `--checkpoint-dir`, a `checkpoint` command in `--cmd-file`, `--restore` | about 3 weeks (about 2-2.5k LOC) |
| 2. iOS v1 | Lifecycle triggers from section 5. Fix the async `willTerminate` sync. Audio-interruption and thermal `.serious` hooks. Pin RAM size and hold the WINKIT swap. Data protection class. Resume card and settings UI. 3D hot switch after resume | 1-1.5 weeks |
| 3. v2 incremental | Dirty bitmap set where write tags are granted (`core/mmu.c:725, 782, 974, 1359-1379`, `core/memop.c:341`). Grant write tags only on actual writes for clean pages. DMA marks via `hv_dma_written` (`core/machine.c:550-557`) plus about 13 direct-pointer sites. Pre-copy base. Delta log, compaction, two generations. Adaptive interval | about 2 weeks (400-600 LOC) |
| 4. S4 opt-in | WinKit `power.ps1` option, trigger, hibernated flag, config lock, ACPI fallback only if phase 0 shows it is needed | 3-5 days |
| 5. Soak on the phone | Section 11 | 1-2 weeks |

Total: about 6-9 engineer-weeks. A useful v1 (phases 0-2) takes about 4-5 weeks. Phases 1 and 3 can start without the phone.

## 11. Test plan

### Mac first (`build/winvm`, `host/main_mac.m`)

1. **Round-trip identity.** Save, restore immediately, save again. The two device-state blobs and the RAM hashes must match. Run this per device in the core tests as well.
2. **Kill and restore of a running Windows.**
   - Boot Windows and open apps.
   - Create file A, checkpoint, then create file B.
   - `kill -9` the process, relaunch with `--restore`.
   - Expect: the desktop responds (`--screenshot`), A exists, B does not, `chkdsk C: /scan` is clean, and there is no Kernel-Power 41 or unexpected-shutdown event. `w32tm /stripchart` shows the clock back in sync after the `resumed.txt` bump.
3. **Under load.** Checkpoint during a large file copy, Windows Update, a CPU-bound job and audio playback. Kill at random times; repeat 100 times in a script. Expect no NTFS errors and no hangs. Lost interrupts or timers would show up as a stuck guest.
4. **Ordering faults.** Kill during the writer, during the clone, and during the commit. Expect a fallback to the previous generation, never a mixed state.
5. **Clock.** Save, reboot the Mac, restore. Interrupt time must not run backwards. Expect no 0x101 or watchdog bug checks.
6. **Refusals.** Different `--ram`, `--cpus`, firmware, disk or `--sound`; a newer state-format version. Each must be refused with the right message.
7. **Network.** RDP session and port forward before the checkpoint. After the restore, the old session drops quickly and a new one connects.
8. **Pause length and dirty rate.** Log both for an idle server guest. These numbers drive the v2 interval.
9. **S4** (if approved). `shutdown /h` with `HV_PSCI_LOG=1`. Timestamp Kernel-Power events 42 and 107, then resume through the normal boot.

### Then the phone

1. Background in server mode, then a forced kill: from the debugger, a jetsam caused by memory pressure from another app, and swipe-away. Relaunch, re-acquire the JIT, resume.
2. Lock the phone overnight with periodic checkpoints. Measure wear and battery use.
3. Thermal `.serious` and `.critical`, low battery, an audio interruption (phone call).
4. Reboot the phone between save and restore. Install an app update between save and restore; the result depends on the version policy.
5. Low storage, where checkpoints should be refused and the user warned.
6. A 3D session in the foreground, then going to the background: auto-2D, then the base checkpoint, then a kill, then resume in 2D, then the hot switch to 3D in the foreground.
7. Timings: base save, incremental pause, restore, and time until the first RDP connection.

## 12. Risks

- **Disk corruption** if the RAM checkpoint and the disk clone are not taken at the same instant, or if a restore runs against the live disk. This is the main correctness risk. Mitigations: a single code path for checkpoints, the swap-back step on restore, and phase-1 kill-loop testing.
- **Counter-bias regressions.** The bias is a hot-path translator change. Any comparison of host time against a guest deadline that is missed causes stuck timers or watchdog bug checks.
- **Missing device state.** One forgotten field, such as a pending interrupt bit, gives a guest that hangs after a restore while looking fine at first. Mitigations: round-trip identity tests and long soaks.
- **Restore depends on getting the same RAM size** from the JIT preallocation. A launch that gets less RAM can't resume.
- **3D sessions are unprotected** while in the foreground.
- **Storage and wear** on a phone that may be nearly full. QLC NAND drops to tens of MB/s once its SLC cache is exhausted (third-party report).
- **App updates.** If the state format changes, checkpoints are refused. Device-model changes are the risky part; translator changes are not, because the JIT cache is dropped anyway.
- **Kills by the sideloading tool** when it reinstalls or re-signs the app (UNVERIFIED). Checkpoints in Application Support must survive this.
- **Assumptions not yet confirmed on device:** that page-cache data survives an app kill on iOS, and how long clonefile takes on large images.

## 13. Questions for you

1. **How much loss is acceptable after a kill?** It sets the v2 interval (10 s, 30 s, 2 min) and so the NAND wear.
2. **Storage budget:** is up to about 7 GB for two generations acceptable, or should only one generation be kept (smaller, but a corrupt checkpoint can't fall back)?
3. **On relaunch after a kill:** resume automatically when server mode is on, or always ask?
4. **3D in the foreground:** accept it as unprotected, or offer a periodic prompt to switch to 2D and save?
5. **Across app updates:** allow a resume when the state-format version matches, or always refuse?
6. **The S4 test:** may I enable hibernation in the Mac guest and run `powercfg /h on`, `powercfg /h /type full` and `powercfg /a`? This reverses the current WinKit policy.
7. **Critical battery or heat:** keep pausing Windows (after a checkpoint), or stop it completely (checkpoint or S4)?
8. **"Start Windows fresh":** delete the checkpoint right away, or keep it until the next successful checkpoint?
9. **The Mac app:** should `build/winvm` and the Mac app also get this feature (save on quit and restore), or should it stay a test harness only?

---

## Review notes (adversarial critic, not yet folded into the design)

# Hibernation design: corrections from the adversarial review

Checked against the code on branch `duo`. Nothing was edited. Items marked UNVERIFIED were not measured or confirmed.

## A. Consistency of the snapshot (pause, threads, locks)

1. **The checkpoint can't reuse `hv_winvm_set_paused`.**
   - There is one `m.paused` flag (`host/winvm.c:326-330`), and `applyPause` (`winios_bridge.m:~428-437`) drives it from two reasons: `_pausedInBackground` and `_guardPaused`.
   - If a checkpoint sets and clears that same flag, it will un-pause a machine the guard paused, or the reverse.
   - `applyPause` also calls `hv_audio_set_machine_paused(1)`, and `applyAudioKeepAlive` turns the keep-alive off while paused. If the checkpoint goes through that path, the silent audio stops and iOS suspends the app in the middle of the save.
   - **Fix:** add a separate checkpoint-pause count in core that `run_loop` checks (`core/dispatch.c:982-987`). It must not touch audio or the keep-alive.
2. **Some host threads inject events without `hv_dev_lock`.**
   - `hv_winvirt_power_button` and `hv_winvirt_set_battery` (`devices/winvirt.c:257-268`) do an atomic `ged_events |= ...` and then `hv_gicv3_pend` from the main thread.
   - Holding `gic->mu` doesn't cover `ged_events` or `b->bat`. A battery event that lands between saving GED and saving the GIC gives a mismatched pair.
   - **Fix:** take a host-event lock, or queue these events while paused and save them after taking `gic->mu`.
3. **Paused CPUs must also drain cross-CPU work.**
   - `wait_while_paused` parks the CPU (`dispatch.c:864-876`), and `hv_cpu_process_requests` (TLBI or IPI requests) only runs at the top of the loop.
   - Before serializing, the checkpoint must confirm: no queued requests, `flush_pending==0`, `stw_active==0`, and no PSCI CPU_ON half done (`cpu->off` / `parked_off`).
   - Save `off`, `halted` and the CPU_ON entry state for each CPU. `wait_while_off` ignores `paused` (`dispatch.c:850-857`), so CPUs that are off need their own case in the parked-count protocol.
4. **What runs on which thread, as found in the code.**
   - NVMe and HDA DMA run on CPU0. HDA runs in `tick_locked` (`winvirt.c:97-107`).
   - virtio-net RX runs in `hv_net_poll` from the CPU0 tick (`net_slirp.c:2081-2095`), not on the slirp thread. Pausing the CPUs therefore stops guest-RAM writes from these devices. That part of the draft is right.
   - Audio callbacks only touch host-side rings (`host/audio_mac.c`).
   - The 3D worker (`virtio_gpu3d.c:1667`) and the Neptune cleanup worker (`neptune_cleanup.c:476`) can touch guest RAM. Require both to be idle.
5. **The device list doesn't match the board.**
   - The Windows board creates: pflash0/1, GICv3+ITS, PL011, PL031, PL061, fw_cfg + fb_display (ramfb), GED/battery, PCIe, virtio-net, NVMe0, xHCI, HDA, virtio-gpu and the optional NVMe1 (`winvirt.c:167-233`).
   - It creates **no virtio-input and no virtio-snd**, and `enable_sound` is ignored (`winvirt.c:234`). Scope phase 1 to the real set and add `fb_display`. A guard should refuse a checkpoint if an unknown device is attached.
6. **The 2D GPU loses its pixels.**
   - Each 2D resource has a host buffer `r->pixels` (`virtio_gpu.c:302`, filled by TRANSFER_TO_HOST at `:404`). Saving only "resource table, backing lists, scanout" brings back black or stale surfaces until DWM redraws every damaged region.
   - **Fix:** save the pixels, or on restore re-run a full TRANSFER_TO_HOST from the backing pages, which are in guest RAM. Save the cursor image too.
7. **GIC state the draft doesn't list.**
   - The host-side `lpi_pending[]` for each redistributor (`devices/gicv3.h:30`).
   - Any cached LPI configuration or ITS translation cache. Either save it or invalidate it so it is read again from guest RAM.
   - `m.percpu[c].irq_line` and `fiq_line`, recomputed through `hv_gicv3_update`.

## B. Guest time

8. **The counter bias is needed in more places.**
   - `PMCCNTR_EL0` is derived from the same counter (`core/translate.c` around the `PMCCNTR_EL0` case, "x192"), and Windows reads it in every `KiSwapContext`. Without the bias it jumps backwards after a restore across a phone reboot.
   - Also bias xHCI MFINDEX and the HDA wall clock (`xhci.c` and `hda.c` both read host time), and the `sysreg.c` helper path for commpage type 0.
   - A cheaper way to do it: the translator already loads `COMMPAGE_TIMEBASE_OFFSET` (`translate.c:~1514-1538`). Emit one extra load of a machine-global bias next to it, rather than patching each site.
9. **Pin the timebase in the manifest.** The translator chooses the counter register from the commpage timebase type. Record the type and frequency, and refuse a restore on a host where they differ (Mac → phone, or a different SoC).

## C. Disks and NVRAM

10. **Disk 1 is often the WinKit image bundled in the app.**
    - `disk1Path` = `[NSBundle mainBundle] pathForResource:@"winkit"` (`winios_bridge.m:1866-1879`), opened read-only (`hv_disk_open(..., 0, 1)`, `winvm.c:226-229`).
    - An app update replaces the bundle, so the old `winkit.img` is gone. "Holding back the WINKIT swap" can't help, and the restored Windows has the old FAT/NTFS volume mounted and cached.
    - **Fix:** copy the bundled image into the generation once per distinct hash. Whether `clonefile` from the Bundle container into the Data container works under the sandbox is UNVERIFIED, so fall back to a copy.
11. **A clone per v2 delta doesn't scale.**
    - Every incremental commit needs disks that match its RAM, so each delta needs its own clone of a 64 GB+ image every 10-30 s.
    - `clonefile` costs roughly in proportion to the extent count (UNVERIFIED). Each clone also forces later `pwrite`s to copy-on-write the shared extents, so the live image fragments further with every clone. Clones get slower and guest I/O degrades over time.
    - **Alternative:** at the base commit, clone the disks once. Then log every `hv_disk_write` (offset + data) into the same delta log as the RAM pages. A restore clones the base disk and replays the disk writes up to the last commit. Disk writes are written twice, but deltas no longer need clones and fragmentation stops growing.
12. **`fsync` alone doesn't make data durable on Apple platforms.**
    - Darwin `fsync(2)` doesn't flush the drive's cache. `F_FULLFSYNC` does, and `F_BARRIERFSYNC` gives ordering (Apple `fcntl(2)` and `fsync(2)` man pages).
    - Use `F_FULLFSYNC` (or a barrier) before the `current` rename, or "a phone crash leaves a usable older generation" doesn't hold.
13. **`vars.fd` is simpler than it looks.** pflash keeps the whole bank in memory (`f->data`) and writes through with `pwrite` (`devices/pflash.c:23-25`). Store `f->data` (64 MB, mostly 0xFF, compresses well) in `machine.state` instead of cloning it.
14. **The restore swap is destructive and runs too early.**
    - "Unlink live, then clone" throws away newer disk data before the RAM image is known to be good.
    - **Order:** verify the CRCs of the whole RAM log first. Then rename the live disk to `*.pre-restore` and keep it until the restored VM has run for a while and committed a new generation.
    - Also compare the live disk's identity (inode, size, mtime) with what the app last wrote. If the user swapped `windows11.img` through Files, ask before overwriting it.
15. **Deleting checkpoints on SYSTEM_OFF or RESET is a policy choice, not a correctness rule.** Because the restore swaps the disks back, an old checkpoint stays self-consistent. Delete it because the user expects a cold boot and to avoid rolling back a Windows Update reboot. The stated reason, "they no longer match the disk", is wrong.

## D. iOS, JIT and VA constraints

16. **More boot-time sizes must be pinned.**
    - The hostmem window is chosen at launch, 512 or 256 MB (`winios_jit.c:162-172`). It sets the size of the virtio-gpu hostmem BAR (`virtio_gpu.c:558-559`), which the guest can see whenever the GPU is 3D-capable, even in 2D.
    - The 3D-room probe (`g_cfg_3d_room_mb`) and `winios_jit_configure_3d` also change which RAM sizes fit.
    - **Fix:** the manifest records `hostmem_bytes`, whether 3D is capable, and the room. The allocator needs an exact-size mode that never steps down (today `winios_jit_next_ram_mb` steps down, `winios_jit.c:~178`).
17. **A staging buffer competes for address space.** Without the extended-VA entitlement the address space is about 7 GB, and guest RAM takes what's left (`winios_jit.c:157-160`). A 64-256 MB no-footprint staging buffer has to be reserved at JIT-acquire time, before guest RAM, or it can't be had later. Budget it in the RAM pin.
18. **Nothing brings Windows back after a kill until the user opens the app.** iOS doesn't relaunch a killed audio app. The JIT (built-in pairing or a debugger) is re-acquired only in the foreground, so "resume automatically" can only mean "at the next manual launch".
    - **Add a dead-man notification:** a local notification scheduled for about now + 2×interval and pushed later on each heartbeat. If the app dies, it fires: "Windows stopped; open to resume".
19. **Watchdog.** A synchronous save on the main thread at background, memory warning or `willTerminate` risks a `0x8badf00d` kill. Do the work on a writer queue. In `willTerminate`, block only on an already-staged incremental, and only for less than about 4 s. Apple says the method has "approximately five seconds", and that it may be called for an app running in the background (Apple, `applicationWillTerminate(_:)`). The app registers for `UIApplicationWillTerminateNotification` (`winios_bridge.m:297`).
20. **The audio interruption arrives after the fact.**
    - The notification comes once the output unit has already stopped, and it is dispatched async to main (`winios_bridge.m:399-410`). iOS may suspend the app before `beginBackgroundTask` runs (UNVERIFIED).
    - Suspension isn't a kill. The process stays in memory, and the real risk is a jetsam while suspended. Request the background task on the AVFoundation thread, then save.
21. **The page cache and memory pressure.**
    - Writing or reading 1.5-3.5 GB through the unified buffer cache, and especially doing it at a memory warning, adds the very pressure that causes jetsam.
    - Use `F_NOCACHE` with page-aligned 1-8 MB writes and reads for the RAM log, both when saving and when loading.
    - `0xbaddd15c` as "storage purge" is UNVERIFIED. Drop that code or cite a source.
22. **Data protection.** A clone shares extents, and so encryption keys, with its source. It keeps the disk image's protection class (UNVERIFIED that APFS refuses to change it). Make sure the live images are already `CompleteUntilFirstUserAuthentication`, or clones written while locked will fail.

## E. ACPI, firmware and S4

23. **Fingerprint the bytes, not only versions.** Add a hash of the generated ACPI tables, the DTB and `code.fd` to the manifest. ACPI is built at board creation (`winvirt.c:203`), and any app build that moves MMIO, IRQs or the DSDT breaks a restored guest silently, even when the state format is unchanged.
24. **S4 groundwork.**
    - `ged_write` is a no-op today (`winvirt.c:90-95`). The FADT has HW_REDUCED_ACPI set and no FACS (`acpi.c:585-592`), so the ACPI hardware-signature check (ACPI spec, FACS Hardware Signature) doesn't apply. Windows' own S4 memory-map check still does, so the lock on RAM size and CPU count is right.
    - How Windows on ARM64 actually turns off after S4 is UNVERIFIED: PSCI SYSTEM_OFF or a SLEEP_CONTROL_REG write. Run phase 0 with `HV_PSCI_LOG=1` before writing the "hibernate requested" logic.
    - "Windows ignores the hardware-reduced FADT sleep fields" and "Snapdragon laptops without `_S4`" stay UNVERIFIED. Get Microsoft links or drop them.
25. **"File-backed RAM rejected" is already partly the code.** The bridge sets `HV_RAM_FILE` (`winios_bridge.m:~1826`), and when preallocation fails `winvirt.c:139-156` uses an unlinked `MAP_SHARED` file with a prefault thread. Note that a checkpoint on that path has the same `fc-thrashing` exposure. Or refuse "protection" when the no-footprint preallocation failed.

## F. Wear and storage

26. **Clean shutdown in a phase.** Phases 1-3 never define what happens to the live image after a resume from gen N when gen N+1 commits: the old generation's clones keep pinning rewritten blocks. Delete generation N-1 only after N+1's `F_FULLFSYNC`. With the disk-write log from item 11, storage cost = base clone + logged disk writes, which can be bounded.

## G. A simpler alternative worth a spike

27. **Copy-on-write snapshot of guest RAM:** `mach_vm_remap(copy=TRUE)` or `vm_copy` of the guest RAM range at the pause, then write from the snapshot while Windows runs.
    - This gives a full stop-and-copy with a pause of milliseconds, and no dirty bitmap for v1.
    - Risks, all UNVERIFIED:
      - Does a ledger-tagged named entry (`hv_alloc_no_footprint`, `winvirt.c:23-58`, owner `TASK_NULL`) allow a delayed copy?
      - Copy-on-write fault pages would be charged to the footprint: the dirty rate times the save time, a jetsam risk.
      - Does it cost VA the app can't spare?
    - If it works, v1 can checkpoint on a timer without the phase-3 MMU work.
