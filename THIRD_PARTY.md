# Third-party components

`3d-kit/` (scripts and patch) redistributes nothing below: it downloads each component from its own release page.
`winkit/` does contain two Windows drivers, unmodified, as their upstreams publish them: viogpu3d with the Neptune
UMD (`winkit/viogpu3d/`) and Red Hat's NetKVM (`winkit/NetKVM/`, its license in `winkit/virtio-win_license.txt`).
The prebuilt app (`AppleVM-unsigned.ipa`, in the Releases) is WindowsiOS with `source/windowsios-full.patch`
applied (GPL-2.0-or-later; that patch is its complete source relative to WindowsiOS `0071d69`). It also carries:

| Component in the IPA | Source | License |
|---|---|---|
| virglrenderer (Neptune), DXMT, ANGLE EGL/GLESv2, libepoxy, Vulkan loader, MoltenVK, zstd: unmodified frameworks from the UTM iOS build | github.com/utmapp/UTM and the projects below | MIT / LGPL (DXMT, a separate replaceable framework) / BSD-3-Clause / Apache-2.0 / BSD |
| KosmicKrisp (Mesa's Vulkan-on-Metal driver), from the UTM iOS build, **binary-patched** in `kk_image_layout_init` (linear images are never made 2D arrays) | gitlab.freedesktop.org/osy/mesa, commit eed3e1d9bf; the change: two instructions at kk_image_layout_init, described in source/README.md | MIT |
| Arch Linux installer disk (`arch-installer.img.z`): the Arch Linux ARM `linux-aarch64` 7.3.4 kernel and an initramfs of unmodified Arch Linux ARM packages (busybox, curl, libarchive/bsdtar, util-linux, e2fsprogs, dosfstools, iproute2, systemd-stub), plus the installer scripts from `source/` | archlinuxarm.org (sources: github.com/archlinuxarm/PKGBUILDs) | GPL-2.0 (kernel, busybox, util-linux, e2fsprogs, dosfstools, iproute2), MIT (curl), BSD-2-Clause (libarchive), LGPL-2.1 (systemd) |
| EDK2 ArmVirtQemu UEFI firmware (`arch-code.fd.z`, `arch-vars.fd.z`), as shipped by QEMU | github.com/tianocore/edk2 | BSD-2-Clause-Patent |
| WinKit disk (`winkit.img`): the contents of `winkit/` | this repository | see above |
| StikJIT 1.9.0 (`Frameworks/StikJIT.framework`, the debugger of Built-in JIT's `PlugIns/WinJITHelper.appex`), **patched** with `ios/patches/stikjit-high-address.patch`; contains idevice | github.com/StikDebug/StikJIT, commit 32287268 (build: `scripts/build_jit_deps.sh`) | MPL-2.0 (idevice: MIT) |
| On-device pairing library (`libhusk_rppairing.a`, linked into the app): Husk's `src/rppairing-ios` over idevice 0.1.68 and its Rust crates | github.com/Leviidev/Husk, commit 29abb51 | GPL-2.0-or-later (idevice MIT; crates as listed in the app's `legal/LICENSES-rppairing-crates.txt`) |

| Component | Used for | Source | License |
|---|---|---|---|
| WindowsiOS | the emulator this kit patches (base commit `0071d69`) | github.com/ammaarreshi/WindowsiOS | GPL-2.0-or-later |
| Henge | WindowsiOS's binary translator and JIT core | github.com/Leviidev/Henge | GPL-2.0-or-later |
| UTM v5.0.8 (iOS build) | prebuilt virglrenderer (Neptune), DXMT, ANGLE EGL/GLESv2, libepoxy, Vulkan loader | github.com/utmapp/UTM | Apache-2.0 (bundled libraries under their own licenses) |
| virglrenderer (utmapp fork, neptune branch) | host renderer; `devices/virglrenderer.h` in the patch is its public header | github.com/utmapp/virglrenderer | MIT |
| DXMT | Direct3D 11 on Metal | github.com/3Shain/dxmt | LGPL (see its repository) |
| ANGLE | OpenGL ES on Metal | chromium.googlesource.com/angle/angle | BSD-3-Clause |
| viogpu3d v0.5 + Neptune UMD | Windows ARM64 3D driver, included unmodified in `winkit/viogpu3d/` | github.com/osy/kvm-guest-drivers-windows, github.com/osy/virtio-win-mesa | BSD-3-Clause / MIT |
| virtio-win NetKVM | Windows ARM64 network driver, included unmodified in `winkit/NetKVM/` | github.com/virtio-win/kvm-guest-drivers-windows (Red Hat) | BSD-3-Clause (`winkit/virtio-win_license.txt`) |
| QEMU (utmapp fork) | `devices/virtio_gpu3d.c` follows the design of `hw/display/virtio-gpu-virgl.c` | github.com/utmapp/qemu | GPL-2.0-or-later |
| GetMoreRam, StosSign | Apple developer services client for the Increased Memory Limit capability | github.com/hugeBlack/GetMoreRam, github.com/stossy11/StosSign | see their repositories |

The source patch and this repository's scripts are offered under GPL-2.0-or-later, matching the project they apply to.
You need your own licensed copy of Windows 11.
