<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
# Explorer text and stale-frame investigation

The reported failure is missing text in Explorer's WinUI command bar and labels,
plus stale rectangles or white trails in Explorer and the login screen. Start
and Settings can render correctly in the same 3D session. The available saved
image showed Settings with readable text; it did not reproduce the Explorer
failure. A phone comparison is therefore still required.

## What the source establishes

`devices/fb_metal.m` clears the entire drawable and draws the whole current
scanout. The 3D `RESOURCE_FLUSH` path marks that texture changed; it does not copy
only a damaged rectangle. A missing host damage-region copy is not supported by
this code. The presenter does cache its last serial, so a producer writing after
the flush could leave an old frame displayed. A simulated late producer can
exercise that assumption, but does not establish that the guest violates it.

The guest KMD at [v0.5 / ed821008](https://github.com/osy/kvm-guest-drivers-windows/tree/ed821008215ded87d2d03495240d5aad6d8e42ba)
normally waits for each present's GPU completion token before emitting scanout
and flush commands. Its deadline fallback and unfenced paths are separate
cases. A continuous-redraw workaround would conceal ordering failures without
establishing their cause, and is not part of this change.

The matching guest UMD source is
[fc5f1fc8a389](https://github.com/osy/virtio-win-mesa/tree/fc5f1fc8a389e125e7d5f979f7b88a2708d161ee).
It contains the End-query version fix. The shipped renderer's query-End code
also increments the version. The older reused-query defect discussed in
[upstream issue 8](https://github.com/osy/kvm-guest-drivers-windows/issues/8)
is therefore not a missing host patch here. That report also describes a
distinct monitored-fence execution-ordering problem. Its relationship to this
phone's symptoms has not been measured.

In [DXMT 8b9d334](https://github.com/utmapp/dxmt/tree/8b9d33470d6417734bf156d87d265ca2ede0aaa8),
`CreateDeviceTextureInternal` queues initial zeroes or supplied data in the
resource initializer. The native shared-texture branch then returns the object.
`GetSharedHandle` publishes its shared-memory descriptor without completing that
initialization, and `ImportSharedTexture` correctly avoids initializing an
imported texture. This allows the following ordering:

1. Device A creates and exports a shared texture; its initial clear is pending.
2. Device B imports it, writes pixels, and finishes its own GPU work.
3. A later submits work, flushing its old initializer; that clear overwrites B's
   pixels.

This is a concrete source-level race, including for shared A8 glyph textures.
It has not yet been demonstrated as the cause of Explorer's missing text on the
phone. Completing only the initializer before publishing a newly created shared
resource addresses this ordering. Waiting for the main queue instead could
deadlock on cross-device dependencies and is unsuitable.

## Capture protocol

The raw PNG capture must fail if the active 3D texture cannot be read. Falling
back to an old CPU framebuffer would make the comparison misleading. Capture
logs identify the file name, selected source, serial before/after, size, pixel format, GPU status and
failure stage. A stable serial is not itself proof of producer GPU completion.
The GPU status describes the capture command buffer, not the producer's work.
Each explicit raw capture always logs, including identical repeated captures.
Periodic mini-map, diagnostics and Mac harness PNG captures remain silent and
retain their CPU fallback through the original API. A failed capture leaves any previous PNG untouched; that file must not be
treated as a fresh result. CPU-only capture still works, and callers explicitly
requesting the snapshot API's CPU fallback retain that option.

Use the app's **Capture the screen now (raw)** action in Debug/Status once the
lead has included it and the strict-capture change in an IPA:

1. Keep the app in the foreground with the 3D driver fully loaded. Open Explorer
   to This PC and reproduce the blank command bar or labels. Avoid personal
   filenames in the capture. Hold the scene still for five seconds.
2. Take an iPhone screenshot, capture the raw screen, then take a second iPhone
   screenshot. Save the timestamped `screen-*.png`, `latest_screen.png`, and the
   nearby capture, scanout and numeric memory-census lines. Note whether capture
   itself changed the displayed image.
3. With the guest scene still untouched, pan or zoom the app view to force a
   host redraw. Capture again. This must not change Windows display topology.
4. Separately, move the Explorer window once, stop for five seconds, and repeat
   the paired captures for a white trail. This guest repaint is a separate test
   from the host-only pan/zoom.

A correct raw texture with a wrong phone image, especially if host pan/zoom
repairs it, points toward presentation. Matching corruption in both after a
settled forced redraw points upstream. Guest resizing, opening a menu, or
connecting RDP can change composition, so those actions do not isolate the host
presenter. No new RDP connection or display-topology change is needed here.

## Candidate validation

The candidate is **off by default**. Set `HV_DXMT_SHARED_INIT=1` in `env.txt` and
restart the app to enable it for a lead-coordinated comparison. Remove the line
and restart for the baseline. UUID, instruction and original vtable-slot guards
restrict it to the inspected DXMT. It changes two data slots before device
creation, leaving the existing `patch_dxmt.py` upload guards untouched. An
incomplete rollback refuses backend creation for the rest of the process.

Successful shared DEFAULT/IMMUTABLE Texture2D creation completes the initializer
before returning the resource. The caller cannot observe the result pointer
during that wait. Event polling has a two-second deadline **after** the native
initializer flush returns. Original creation and that flush may themselves
block in Metal, so this is not an end-to-end timeout. Logs and 3D status expose
active flush/poll counts and the elapsed continuous flush-busy interval; that
interval is not the age of the oldest concurrent call.

GPU-disallowed or background-drain states bypass the extra flush/wait and retain
the original creation result. A lifecycle transition while polling also bypasses
the mitigation. Such results are logged as skipped, not synchronized. A genuine
foreground timeout/error preserves the original successful texture and reference,
and disables only the additional mitigation work until renderer reset or VM exit.
It does not fail later texture creation or retain extra references. Invalid
per-call layouts or a missing initializer event skip the mitigation before any
extra native call. Those cases log once per reason and count as skipped.

Three independent gates cover app GPU permission, presenter pause and background
drain. All must permit work. The bridge supplies app permission on **every**
DidEnterBackground/DidBecomeActive trip, including plain trips that only pause
guest CPUs; already-entered or queued backend work can outlive that pause.
Renderer reset and VM exit advance a mitigation epoch, so an older in-flight
failure cannot disable the new epoch. The shared-init and Neptune installers
serialize their transactions through one DXMT data-page lock before backend
creation, because their distinct slots occupy the same protected page.

Keep the candidate opt-in until paired capture and a device probe establish its
effect. A useful ordering probe creates a shared
texture on A, writes and reads it on B, then submits unrelated work on A and
reads the shared texture again. The second read must preserve B's pixels. Run
both zero-initialized and supplied-data creation cases, and include A8 and BGRA
textures. Include an explicit producer Flush before export and a control that
forces real producer GPU completion: an empty immediate-context Flush currently
need not submit pending initializer work. A normal upload round-trip alone cannot
expose this export race.

Host tests and source inspection do not substitute for those phone results.
Keep the no-op/default behavior as the comparison and record whether missing
labels, stale rectangles, or both change. A foreground timeout or disabled mitigation is a failed candidate test, not
evidence of successful rendering.

Run `make test-fb-capture` for strict GPU failure cases, CPU capture, cropped
RGBA conversion, and the conditional late-producer cache test. When Metal is
available, it also checks every pixel of a two-by-two private-texture readback.
The tests use ASan/UBSan and do not run the Windows VM.
Run `make test-dxmt-shared-init` for the candidate's guard, lifecycle, publication,
timeout and rollback tests. Those use synthetic backend operations; a pass does
not establish the two-device race or its correction on the phone.

## Manual two-device probe

`make shared-init-probe` builds `build/guest/SharedInitProbe.exe` without running
Windows. The separate `make test-shared-init-probe` target exercises its ordering
and result classification in a fake COM model on the host. Neither target is in
`guest-tools` or `START.bat`.

After the lead relays the user's explicit approval for this diagnostic, copy the
executable beside `winkit/shared_init_probe.ps1` in the guest and run that launcher
in Windows PowerShell. Keep the phone app in front and avoid concurrent GPU tests.
The launcher writes a new local temporary text report, then prints it. No adapter,
registry, service, display topology, or network settings are changed. The probe
selects the hardware VirtIO adapter and never falls back to WARP. Each case uses
64-by-64 BGRA8, R8 or A8 textures; unsupported cases are reported as partial coverage.

The report pairs a stress case (creator Flush before export) with a control that
waits for a fresh creator EVENT first. Device B writes and verifies a sentinel,
then unrelated work on A forces its pending initializer work to run. A second B
read shows whether that sentinel changed. Every completion uses a new EVENT to
avoid the already-fixed query-reuse defect. Polls have five-second limits; a
120-second watchdog exits only the probe process if a native call blocks.

Compare matched controls and stress runs with the mitigation OFF and ON in
separate app processes. `CHANGED_AFTER_A` with a stable control supports this
ordering candidate. Baseline/control/API failures are inconclusive, and a stable
probe does not prove the cause of Explorer's missing text. Exit 0 means all pairs
stable, 1 a mismatch/error, 2 partial or unsupported coverage, 3 setup failure,
and 124 the watchdog. Keep paired raw PNGs and the corresponding host logs.
