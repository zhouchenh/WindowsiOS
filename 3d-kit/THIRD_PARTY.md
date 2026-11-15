# Third-party components

The scripts and the patch redistribute nothing below; they download each component from its own release page.
The separate prebuilt IPA does contain the UTM iOS frameworks (virglrenderer, DXMT, ANGLE, libepoxy, Vulkan loader), unmodified, as dynamic frameworks.

| Component | Used for | Source | License |
|---|---|---|---|
| WindowsiOS | the emulator this kit patches | github.com/ammaarreshi/WindowsiOS | GPL-2.0 |
| UTM v5.0.8 (iOS build) | prebuilt virglrenderer (Neptune), DXMT, ANGLE EGL/GLESv2, libepoxy, Vulkan loader | github.com/utmapp/UTM | Apache-2.0 (bundled libraries under their own licenses) |
| virglrenderer (utmapp fork, neptune branch) | host renderer; `devices/virglrenderer.h` in the patch is its public header | github.com/utmapp/virglrenderer | MIT |
| DXMT | Direct3D 11 on Metal | github.com/3Shain/dxmt | LGPL (see its repository) |
| ANGLE | OpenGL ES on Metal | chromium.googlesource.com/angle/angle | BSD-3-Clause |
| viogpu3d v0.5 + Neptune UMD | Windows ARM64 3D driver | github.com/osy/kvm-guest-drivers-windows, github.com/osy/virtio-win-mesa | BSD-3-Clause / MIT |
| QEMU (utmapp fork) | `devices/virtio_gpu3d.c` follows the design of `hw/display/virtio-gpu-virgl.c` | github.com/utmapp/qemu | GPL-2.0-or-later |
| GetMoreRam, StosSign | Apple developer services client for the Increased Memory Limit capability | github.com/hugeBlack/GetMoreRam, github.com/stossy11/StosSign | see their repositories |

The source patch is offered under GPL-2.0-or-later, matching the project it applies to.
You need your own licensed copy of Windows 11.
