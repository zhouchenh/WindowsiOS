# Third-party components

`3d-kit/` (scripts and patch) redistributes nothing below: it downloads each component from its own release page.
`winkit/` does contain two Windows drivers, unmodified, as their upstreams publish them: viogpu3d with the Neptune
UMD (`winkit/viogpu3d/`) and Red Hat's NetKVM (`winkit/NetKVM/`, its license in `winkit/virtio-win_license.txt`).
No prebuilt app (IPA) is part of this repository.

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
