<!-- SPDX-License-Identifier: GPL-2.0-or-later -->
# Neptune context cleanup

Windows can destroy a Neptune context without explicitly releasing every D3D
object registered in it. The shipped renderer frees those registration records,
but never releases their host COM references. DXMT devices, command queues,
threads and Metal allocations can therefore outlive the context.

The affected renderer is `virglrenderer.1.framework/virglrenderer.1`, UUID
`6B0499CC-B64D-32E7-ABD8-56512B41E17A`. Its call at image offset `0x265d0c`
frees each leftover `npt_object`. The matching historical source is UTM's
[virglrenderer 451505ad](https://github.com/utmapp/virglrenderer/blob/451505ad0aa449290f2c0672da6877d57ee770e5/src/neptune/npt_context.c);
the registration ownership rule was introduced in
[02ca82b](https://github.com/utmapp/virglrenderer/commit/02ca82b32f0bb733f90577d3846aaa44780c9579).
This establishes the inspected layout, not an assertion that the shipped binary
was built from that exact commit. The UUID and instruction checks identify the
supported binary.

Each record has a host interface pointer at `+0x10`, a non-owning COM identity at
`+0x18`, and a registration count at `+0x20`. Every registration owns one COM
reference. Cleanup must release the interface exactly that many times. Releasing
until COM returns zero would also consume references owned by scanout, shared
resources or other objects. The identity is not separately released.

## Why release is deferred

Replacing the leftover `free()` with immediate `Release()` is unsafe for this
DXMT. In the inspected [DXMT 8b9d334 source](https://github.com/utmapp/dxmt/blob/8b9d33470d6417734bf156d87d265ca2ede0aaa8/src/dxmt/dxmt_command_queue.cpp),
queue destruction stops the finish worker before necessarily retiring every
submitted Metal command buffer. Queue members also own no-copy argument buffers
and other backing allocations. Releasing a Metal buffer reference does not prove
that the GPU has stopped using its separately owned backing memory.

The app keeps a device alive when its last public COM reference is released,
until DXMT's own submitted and retired counters establish that its GPU work has
finished. This protects devices reached indirectly through COM private data as
well as devices explicitly registered in Neptune's table. Enumerating only the
leftover table records would miss those indirect owners.

The guarded DXMT hooks preserve the public/private reference-count transitions.
At public count zero, cleanup retains the private reference that the original
implementation would have dropped immediately. Its worker compares main-queue
retirement with the submitted sequence and separately checks the resource
initializer's completion event. A device waiting for counters stays pending
without an age or queue-length cutoff. Retries back off from 10 ms to at most
one second, resetting when retirement makes progress. Waiting behind other work
does not permanently quarantine a normally released device.

An initializer command buffer refused in the background can finish with an
error without executing its shared-event signal. Once the main queue has retired
and that event has stalled for five seconds of allowed time, cleanup submits an
empty command buffer on the initializer's **own** queue. It retains that buffer
and polls its status without a synchronous GPU wait. Only `Completed` establishes
retirement; an errored, nil, or pending recovery buffer leaves the private pin
held and retryable. There is at most one outstanding recovery buffer per device
job. Cleanup never flushes pending CPU-side initializer uploads just to obtain a
signal, and it never writes a guessed value into the shared event.

This relies on Metal's [same-queue execution order](https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/MetalProgrammingGuide/Cmd-Submiss/Cmd-Submiss.html)
and [successful command-buffer completion](https://developer.apple.com/documentation/metal/mtlcommandbuffer/status).
A newly rejected recovery buffer is not evidence that preceding work retired.
The factory may block at the queue's buffer limit, so the native helper checks
foreground permission again after it returns and before committing. If permission
was revoked, it releases the uncommitted buffer and retries after foreground return.
Every ticket records the initializer goal covered by its submission. A successful
proof remains valid only while the newly sampled initializer goal does not exceed
that recorded goal. A newer public-zero job can run before an older job in backoff
and consume its own pin, so private counts alone cannot identify the older proof's
generation. When the goal rises, cleanup releases any old ticket and clears its
completed proof and stall window. A fresh stall and barrier must cover the newer
uploads. Before destruction it samples the counters again under the lifetime lock
and rechecks both retirement evidence and reference counts.

The watchdog reports a native call stalled beyond five seconds of allowed time.
A passive event/status read returning later is rechecked rather than permanently
quarantined: suspension does not invalidate a successful result. An entered
destructor cannot be cancelled. Invalid object state or a failed finalizer still
retains the affected objects and reports the failure.

`QueryInterface`, `AddRef`, and `Release` transitions are serialized: the pinned
`QueryInterface` contains an inlined reference increment. This prevents a device
from being destroyed between a public-reference resurrection and its private
reference increment. Plain initializer counters are sampled while API writers
are excluded. Backend event reads and deleting destructors run outside that
lock; no renderer thread waits for GPU retirement.

GPU retirement alone is insufficient: an unflushed draw can already have started
shader compilation. This DXMT's pipeline-cache member destruction would free
task maps before its scheduler joins the compiler workers. After the final
private-reference decision, cleanup first stops the scheduler, wakes its workers
and joins every native thread while those maps still exist. Only then does it
call the original device destructor. Native thread layout and scheduler code
are guarded too. A failed join retains the sealed device; a blocked join is
reported by the watchdog. Neither case permits freeing the maps.

Neptune's leftover records are collected on their backend thread and sealed into
a batch at the actual end of its destructor, after the rings stop. The public
virgl destroy/reset API only sends a render-server request; its return is not
that boundary. The cleanup worker releases each record's owned registrations.
Any resulting final DXMT device release follows the retirement path above.

A backend destructor can itself block. Separate workers handle leftover
registration batches and device retirement, so a blocked leftover `Release`
does not stall normally released devices. The watchdog reports an entered call
and elapsed allowed time rather than cancelling the thread or freeing objects
that call may still use. Device counter waits have no permanent expiry. Leftover
batch timeout/queue overflow retains remaining registrations. Quarantine is a
safe fallback, not proof of successful reclamation.
Before publishing a failed device job to quarantine, its worker releases any
retained empty-buffer ticket outside the lifetime mutex. Releasing the ticket
does not consume any remaining device pin. Ticket ownership is cleared from the
job before entering native release, so a blocked release or concurrent watchdog
cannot release it twice.
The watchdog never performs this cleanup on behalf of the worker.

## Guarded interception

The frameworks on disk are unchanged. The app checks the loaded renderer's UUID,
object-layout instructions and original destructor bytes, then redirects that
image's imported `free` pointer. The hook compares its return address with the
validated record-free and final context-free callsites. All other frees go
directly to libc; their path does not allocate or lock. Record frees retain the
objects in a thread-local batch; the final context free submits that batch.

The renderer hook is preflighted first, including its import slot and reversible
data-page permission change. A rejected preflight leaves device lifetimes alone.
DXMT's concrete device vtable is checked against its expected original functions,
then its data-page slots are redirected before Neptune can create devices.
Only data pages are made writable, with their protection restored afterward.
There are no writes to executable memory. Unknown images, unexpected bytes or
refused page protection keep the original behavior and report the reason.
Overrides in `work/3d/fw-override` receive the same runtime checks.
If the final record hook safely refuses before any backend creation, the three
DXMT lifetime slots are CAS-restored with their original page protection. The
process then keeps original lifetime behavior. Backend creation irreversibly
seals this rollback path, including a failed initialization attempt; existing
devices or deferred jobs can never lose their lifetime hooks. An uncertain GOT
or vtable rollback, or a later refusal after that seal, prevents further backend
creation for the process. Both DXMT installers use the same data-page lock.
Status reports
the device and record hooks separately; startup logs give each guard result.

The existing guarded `scripts/patch_dxmt.py` upload-failure protection is unchanged.

Set `HV_NPT_DEFER_RELEASE=0` in the machine's `env.txt`, then restart the app, to
disable this cleanup and restore the previous leak behavior for comparison.

## App lifecycle integration

`hv_winvm_set_gpu_allowed(int)` is safe before VM creation and initially allows
GPU work. The iOS bridge sets it to zero on `UIApplicationDidEnterBackground`
and back to one on `UIApplicationDidBecomeActive`. Merely inactive states such
as Control Center remain allowed. `WillEnterForeground` is too early.

While disallowed, device snapshots and passive event/status reads continue with
10 ms to one-second monotonic retry deadlines. The separate watchdog and initializer
stall clocks count foreground time only. A device whose queues are sampled as
retired returns to the queue with `paused_ready=1`, allowing other devices to be
polled. New barrier creation/commit, final device destruction, and arbitrary
leftover-registration `Release` calls wait for foreground permission.

Keeping final destruction gated is deliberate: a device's COM private data can
release another device's swapchain, whose destructor calls `WaitUntilGPUIdle` and
may commit work. That destructor call chain was confirmed in the shipped binary;
its reachability from this guest has not been demonstrated. Direct queue retirement
does not prove the entire recursively released COM graph is submission-free.
Bare empty-buffer ticket release does not execute that DXMT graph.

A call already entered in DXMT cannot be cancelled; its references stay owned,
and an entered finalizer can span a later background transition. The lifecycle
callbacks apply to every trip, including plain background trips that only pause
guest CPUs. Presenter pause and background drain remain separate permissions for
the optional shared-initialization mitigation.

This conservative gate delays already-quiescent device destruction while away.
An auto-2D trip therefore need not immediately reclaim all DXMT memory in the
background. `paused_ready` counts last-sampled ready retirement jobs, including a
current job just marked ready; it is not an instantaneous claim after a new public
resurrection. Passive sampling clears readiness when counters advance beyond the
available proof. Final destruction resumes when permission returns.

## Verification on the phone

The host tests validate reference accounting, guards and cleanup control flow.
Run `make test-neptune` for synthetic Mach-O guard checks, native interposition
rollback tests, compiler stop/join tests and fake-COM retirement scenarios.
The 40 cleanup scenarios include an initializer goal of 5 whose event remains 4
after a simulated hour, recovery through a successful same-queue buffer, rejected
and nil recovery buffers, one retained pending ticket, exponential polling backoff,
background transitions, public-reference resurrection, and a passive getter that
returns ready after a six-second stall with the lifecycle gate unwired. Native
callback tests cover queue-offset validation, statuses 0 through 5, ticket retain/
release balance, and a factory that returns after background entry without a new
commit. They also force a newer epoch to consume its private pin before an older
pending or completed goal-5 barrier is revisited at goal 7; neither proof permits
early deletion. Quarantine tests cover event-read failure, invalid snapshots and
counts, plus a native ticket release blocked while the main thread acquires the
lifetime mutex and invokes the watchdog. Background tests show two devices making
passive progress without new barriers, finalizers, or leftover COM releases.
A host Metal smoke test also held an earlier command buffer on an event:
the later empty buffer remained pending until that event was signaled, after which
both completed. These are host results, not a phone reclamation measurement.
They do not establish Metal retirement or memory recovery on the phone. The lead
builds the test IPA with the approved UTM framework directory; this branch does
not change the guest or its drivers.

1. Start a fresh app process with 3D enabled. Keep it in the foreground, let the
   Windows desktop settle, and save the startup cleanup check plus the first
   `memory: footprint ... Metal ... (working set ...)` census lines.
2. Open and fully close a 3D application, such as Edge or an existing D3D test
   app, ten times. Leave time between cycles for context-destroy and cleanup
   completion logs. Do not change display topology. Context creation/destruction
   must actually occur; minimizing a window is not a teardown test.
3. After each cycle, wait for cleanup to retire and for the desktop to settle.
   Compare `live_ctxs`, Neptune counts, `dxmt-encode`/`npt-ring` thread counts and
   Metal allocation size against the settled baseline. Counts and memory can
   fluctuate or cache; they should not grow by another device/queue each cycle.
4. Check each cleanup batch's reference count, device retirement counters, elapsed time and
   result. A quarantined or stuck batch is a failed reclamation test even though
   it preserves safety. `stalled_init` counts initializer jobs stalled for at least
   five allowed seconds; `barriers` counts successful recovery proofs, and
   `slow_calls`/`stalled_call` identify returned/current native-call stalls. A
   retirement line with `barrier=1` may legitimately show a stale initializer
   event below its goal, but `barrier_goal` must cover that initializer goal.
   `paused_ready` reports last-sampled ready jobs waiting for foreground destruction.
   Save these fields and the surrounding census lines.
5. Repeat a normal background and
   foreground trip while cleanup is pending. The app must remain responsive;
   new barrier submissions, finalizers and leftover COM releases must wait for
   foreground, while passive retirement reads continue. An already-entered
   finalizer may still finish after the background transition. This test does
   not require a graphics mode or display-topology change inside Windows.
6. For comparison, repeat in a fresh app process with
   `HV_NPT_DEFER_RELEASE=0`. Remove that override and restart afterward.

There was no post-census device log available during initial development. The
baseline, successful reclamation and behavior under actual Metal errors must be
measured on the next device run. Logs can contain private network addresses;
share sanitized numeric census and cleanup lines, not whole logs in commits.
