# A Linux shell for the iPhone Duo: design

Status: research and design only, nothing built. It combines the ideas of iSH, a tiny VM, a-Shell and
UTM SE in one app that mostly needs no JIT and is fast to open. Speeds are relative to native code.
Figures marked *measured* come from the cited source, which is usually not an iPhone; everything else is
an estimate. Phase 0 exists to measure the important numbers on the Duo itself.

## 1. What iOS 27 allows a sideloaded app without JIT

| What | Possible? | Notes |
|---|---|---|
| Native arm64 code compiled into the signed app | Yes, full speed | This is how a-Shell ships 158 commands ([a-shell](https://github.com/holzschu/a-shell), [ios_system](https://github.com/holzschu/ios_system)). |
| New native code added after install | Only if it is re-signed with your own certificate first; sideload only; **unverified for a non-LiveContainer app on iOS 27** | LiveContainer does it (re-signs with zsign, then `dlopen`). The certificate expires every 7 days on a free account; a paid account lasts a year. |
| Generating machine code in the app | No; only with a debugger attached (this repo's Built-in JIT) | TXM enforces it. |
| Interpreters, including threaded "gadget" interpreters made of precompiled code | Yes | iSH, UTM SE's TCTI, WasmKit, wasm3 |
| JavaScript and WebAssembly with JIT inside a **WKWebView** | Yes, with conditions; **reaching full JIT on iOS 27 is unverified** | The WebContent process holds the JIT entitlements ([process-entitlements.sh](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/Scripts/process-entitlements.sh)). The page must come from a secure origin such as `https://localhost`: iOS 26.4/27 "Enhanced Security" turns JIT off for plain http pages ([bug 324968](https://bugs.webkit.org/show_bug.cgi?id=324968)). Lockdown Mode turns WebAssembly off entirely, and the app cannot override that. WebContent was killed at about 2 GB in one report. |
| JIT in the app's own `JSContext` | No | JavaScriptCore turns JIT on only in a process that holds the entitlement ([ExecutableAllocator.cpp](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/JavaScriptCore/jit/ExecutableAllocator.cpp)). |

**Bottom line:** arbitrary third-party binaries cannot run at full native speed without JIT. Without it,
there are three routes to compiled speed:

- code bundled into the app (or re-signed into it);
- WebAssembly through WebKit;
- a library or command that has a native build.

Everything else is interpreted: about 6–30x slower than native with a good arm64 gadget interpreter
(*measured* on a Mac, [ish-arm64 benchmarks](https://github.com/OpenMinis/ish-arm64/blob/master/benchmark/BENCHMARK_PERF.md)).
Not 100x. With the debugger attached, this repo's translator is the fast tier (about 1.5–1.9x native in
noisy Mac microbenchmarks).

## 2. Architecture: one bash, one filesystem, four tiers

The shell is **real GNU bash** (or busybox ash) running as an arm64 Linux program in the user-mode layer.
That layer emulates `fork`, pipes, signals, job control and ptys, so bash behaves exactly as it does on
Linux. iOS forbids `fork` and `exec` for real processes, which is why bash cannot simply be compiled into
the app. A shell does little computing, so the interpreter is fast enough for it.

**`execve` is the switch.** Each program bash starts is sent to the cheapest tier that can run it, much
as Linux's `binfmt_misc` does:

```
                  bash (arm64 Linux, user-mode layer)  +  one rootfs in the app container
                                       |  execve()
     +---------------------------+-----+-------------+--------------------+-------------------+
     | native build exists       | .wasm file        | arm64 ELF          | needs a real kernel
     v                           v                   v                    v
  T1 native command        T2 WebAssembly in     T3 Linux user mode   T4 tiny Linux VM
     in the app (thread)      a warm WKWebView      (gadgets; native     (resumed from a
     ~1x                      (JSC JIT) ~1.5x?      library thunks;      snapshot)
                              fallback WasmKit      debugger JIT when
                                                    attached)
```

| Workload | Tier | Without JIT | With the debugger JIT |
|---|---|---|---|
| Common tools with a native build (python, git, ssh, curl, rg, vim, ffmpeg) | T1 | ~1x | ~1x |
| WebAssembly/WASI programs, including on-device `clang --target=wasm32-wasip1` | T2 | ~1.5x if JSC behaves like other browsers ([Jangda et al.](https://arxiv.org/abs/1901.09056); JSC not measured); WasmKit fallback ~5x slower than a JIT; wasm3 ~12x | same |
| Any arm64 Linux binary or Alpine `apk` package | T3 | 6–30x (*measured* on a Mac); syscall-heavy work 1–5x; less with library thunks | near native through this repo's translator (after phase 4) |
| x86/x86-64 binaries | T3 via Blink in interpreter mode (ISC; a-Shell embeds it) | ~10x slower than Blink's JIT (*measured*); slow but works | Box64 and FEX need JIT |
| Things needing a real kernel (systemd, containers, kernel modules, iptables) | T4 | UTM SE-style TCTI: ~1 min to a login on an M1 iPad (*measured*); slow | this repo's engine at JIT speed |

### T1: native commands (a-Shell)

These are commands compiled into the app as frameworks, run as threads with their own stdin, stdout, cwd
and environment (ios_system's design, BSD-3).

Reaching them from bash's `execve` needs more than ish-arm64's current "native offload", which today is
batch only: pipes rather than a tty, a process-wide `chdir`, and only absolute paths translated
(see the [source](https://github.com/OpenMinis/ish-arm64/blob/master/kernel/native_offload.c)). The
missing pieces are:

- a **pty bridge**, so interactive tools (vim, ssh, a Python REPL, pagers) work;
- **thread-local cwd and environment**.

ios_system already has both.

Sideload only: "native packages" could be added later as dylibs re-signed on the device. That works only
if phase 0 shows a plain app can do it on iOS 27.

### T2: WebAssembly through WebKit

A WKWebView loads a page from `https://localhost` through the app's own scheme handler, with COOP/COEP
headers so SharedArrayBuffer and threads work. WASI calls bridge back to the shared rootfs (a-Shell's
design).

- The view is created once at app start and kept warm.
- WasmKit (MIT) is the fallback when Lockdown Mode or the 2 GB WebContent limit rules WebKit out.
- `.wasm` files get a binfmt-style handler, so bash runs them like any other program.

### T3: Linux user mode (iSH, arm64)

The base would be **OpenMinis/ish-arm64**, an arm64 fork of iSH with threaded gadgets, an AOT image
experiment and native offload. LinuxRunner or ios-linuxkit could supply Debian, Arch or Fedora rootfs
support.

Three improvements over the base:

- **Library thunks:** calls into common libraries (libc string and memory functions, libm, zlib, crypto,
  sqlite) jump to the iPhone's native copies. Guest and host share the arm64 calling convention, so this
  is cheap. It is what Box64, FEX and iLand do, and it speeds up every apk package that links those
  libraries.
- **Debugger JIT tier:** when the debugger is attached, this repo's TXM JIT region (and later its
  translator) takes over hot code.
- **Experiment (sideload):** at apk install time, wrap an arm64 ELF's code into a signed Mach-O, with
  `svc #0` and TLS accesses patched to stubs, and load it with `dlopen`. If it works, that is close to
  native for installed packages without JIT. Its risks: 16K vs 4K pages, whether the guest's thread
  pointer is safe on XNU, guest-generated code, and re-signing per certificate.

### T4: a real kernel when needed

- **With JIT:** a "linuxvirt" board on this repo's engine: no UEFI or ACPI, direct kernel boot, virtio-blk,
  the WebDAV share for files.
- **Without JIT**, either:
  - upstream iSH's Linux kernel port (`ish-app/linux`, `arch/ish`), currently i386 and dormant, ported
    onto the arm64 gadgets; or
  - QEMU with UTM SE's TCTI backend (GPL-2.0+; the TCTI file is MIT), which boots arm64 Linux today
    without JIT.

### One filesystem, one package manager

- **Filesystem:** one rootfs in the app container (iSH's fakefs).
  - T1 commands see the same paths.
  - T2's WASI preopens map the same directories.
  - T4 mounts it over the share.
  - The Files app sees `/home` and `/root`.
- **Packages:** `apk` (Alpine aarch64) is the package manager. A package that has a native build or a
  WebAssembly build is routed to T1 or T2 automatically.

## 3. Instant launch

| Tier | How it starts | Target |
|---|---|---|
| Shell prompt | bash in T3 needs no kernel boot. The rootfs is used in place, never unpacked at launch, and the first terminal opens from the app's first frame. | < 0.5 s to a prompt |
| T1 | Part of the app. Frameworks load lazily the first time a command runs. | instant |
| T2 | One WKWebView created at launch and kept warm. Whether compiled wasm can be cached between runs is unverified; if not, the first run of a big module pays its compile. | ~0.1–0.3 s to warm, in the background |
| T3 hot paths | The gadget interpreter has no warm-up. The debugger JIT, when attached, fills its code cache as code runs. | instant |
| T4 | Never booted on demand: resumed from a saved snapshot, with guest RAM mapped back from a file and pages read only when touched. The engine has no snapshot support yet. | ~1 s to resume |

Restoring scrollback, open tabs and the working directory is a UI job, kept per session.

## 4. Duo-specific UI

- **Laptop posture:** the terminal on the top screen and a key deck on the bottom (Esc, Ctrl, Alt, Tab,
  arrows, `|`, `~`, `/`, PgUp/PgDn). It reuses `LaptopDeckView` and `WindowsKeyBar` from this repo.
- **Flat:** two panes split at the hinge (two shells, or a shell and a file browser), each with its own
  session.
- Split View and Slide Over, hardware keyboard shortcuts, and the key bar above the iOS keyboard.
- **Background:**
  - The app keeps running through the audio session; a CPU-only shell has no Metal problem.
  - `BGContinuedProcessingTask` (iOS 26+) keeps a user-started compile or package install running with
    progress shown. Whether WebContent work counts under it is unverified.

## 5. Honest limits

- Arbitrary new binaries run 6–30x slower than native without JIT. Compilers, Go builds and anything
  CPU-bound will feel it.
- JIT-heavy runtimes (Node's V8, LuaJIT, JVM) run as an interpreter inside an interpreter. Node needs
  `--jitless`.
- User mode is not Linux: no systemd, namespaces, kernel modules or raw sockets. Every "process" lives in
  one iOS process, so if iOS kills the app, every program dies.
- WebContent is killed at about 2 GB (one report). Lockdown Mode disables T2 unless the user excludes the
  app, so the T3 and WasmKit fallbacks are required, not optional.
- Every call between the app and WebKit crosses processes, so T2 must batch its I/O.
- Re-signed native packages break when the signing certificate is refreshed or revoked.

## 6. Plan

| Phase | Work | Effort | Gate |
|---|---|---|---|
| 0 | **Measure on the Duo:** wasm in WKWebView over `https://localhost` against native (CoreMark), whether JSC really JITs there on iOS 27, the WebContent memory ceiling, ish-arm64 gadgets against native, Lockdown Mode, whether a plain app can `dlopen` a dylib it re-signed, and a spike of the ELF-to-Mach-O rewrite | 1–2 weeks | Phases 2 and 3's re-signing parts start only if their spikes pass |
| 1 | T3 from ish-arm64 with Alpine `apk`, bash as the shell, instant start, the Duo terminal UI | weeks | the biggest win: arm64 Linux with no JIT |
| 2 | T2 WebAssembly runner (warm WKWebView, binfmt hook, WASI bridge) plus the WasmKit fallback | weeks | phase 0 |
| 3 | T1 native commands with a pty bridge and thread-local cwd and environment; routing from `execve`; library thunks in T3 | weeks to months | |
| 4 | This repo's debugger JIT as T3's fast tier | weeks | |
| 5 | T4: linuxvirt board with snapshot resume (with JIT); TCTI or the iSH kernel port (without) | 2–4 weeks each | |
| 6 (research) | arm64-to-WebAssembly translation through WebKit, estimated 3–8x native and unmeasured. container2wasm (Apache-2.0) is the baseline it must beat. Also the ELF-to-Mach-O rewrite if its spike passed. | months, high risk | |

## 7. Licences

- The combined app would be **GPL-3.0** with source published.
- iSH and its forks are GPL-3.0 with LICENSE.IOS. This repo is GPL-2.0-or-later and is already
  distributed as GPL-3.0.
- These combine freely: a-Shell and ios_system (BSD-3), Blink (ISC), WasmKit and wasm3 (MIT), v86 (BSD-2),
  container2wasm (Apache-2.0), zsign upstream (MIT), the TCTI backend file (MIT), and StikJIT (MPL-2.0;
  its notices must be kept).
- **Not used:** LiveContainer code (AGPL-3.0; the technique is reimplemented instead) and CheerpX/WebVM
  (proprietary).

## 8. Questions for you

1. A separate app, or a "Linux shell" machine type inside AppleVM (sharing the JIT setup and engine)?
2. Sideload only? (The App Store rules out re-signed packages and the debugger JIT.)
3. A paid developer account whose certificate the app may use for re-signing?
4. Command-line work (packages, compilers, Python/Node), or also a Linux desktop?
5. Are x86 binaries needed, or is arm64 enough?
6. Is Lockdown Mode ever on?
7. Typical memory needs: under 2 GB, or more?
