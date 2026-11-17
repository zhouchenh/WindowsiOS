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
logs identify the selected source, serial before/after, size, GPU status and
failure stage. A stable serial is not itself proof of producer GPU completion.
The GPU status describes the capture command buffer, not the producer's work.
Repeated identical metadata is suppressed, with the count on the next changed
line. A failed capture leaves any previous PNG untouched; that file must not be
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

The shared-initialization candidate must remain opt-in until the paired capture
and device probe establish its effect. A useful ordering probe creates a shared
texture on A, writes and reads it on B, then submits unrelated work on A and
reads the shared texture again. The second read must preserve B's pixels. Run
both zero-initialized and supplied-data creation cases, and include A8 and BGRA
textures. A normal upload round-trip alone cannot expose this export race.

Host tests and source inspection do not substitute for those phone results.
Keep the no-op/default behavior as the comparison and record whether missing
labels, stale rectangles, or both change. A foreground timeout or retained
resource is a failed candidate test, not evidence of successful rendering.

Run `make test-fb-capture` for strict GPU failure cases, CPU capture, cropped
RGBA conversion, and the conditional late-producer cache test. When Metal is
available, it also checks every pixel of a two-by-two private-texture readback.
The tests use ASan/UBSan and do not run the Windows VM.
