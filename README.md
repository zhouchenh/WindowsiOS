# Apple VM

Windows 11 ARM64 and Arch Linux virtual machines on iPhone / iPad, **with GPU acceleration** (Windows: DirectX 11).
This repository holds the app (**Apple VM**, in the Releases), the Windows GPU driver kit, the tutorial for making
the Windows 11 machine, and the source patch. It is a modification of
[WindowsiOS](https://github.com/ammaarreshi/WindowsiOS) (itself built on [Henge](https://github.com/Leviidev/Henge)),
not an independent project; the 3D path comes from [UTM](https://github.com/utmapp/UTM)'s Neptune (virglrenderer)
and DXMT, and the Windows 3D driver from [osy's viogpu3d](https://github.com/osy/kvm-guest-drivers-windows).
See [Upstream](#upstream). The documentation is in Chinese.

iPhone / iPad 上带 **GPU 加速**的 Windows 11 ARM64 和 Arch Linux 虚拟机（Windows：DirectX 11）。
本仓库包含 App（**Apple VM**，在 Releases 里）、Windows 的 GPU 驱动安装包、Windows 11 虚拟机制作教程和源码补丁。
它是 [WindowsiOS](https://github.com/ammaarreshi/WindowsiOS)（基于 [Henge](https://github.com/Leviidev/Henge)）的修改版，
不是独立项目；3D 部分来自 UTM 的 Neptune（virglrenderer）和 DXMT，Windows 里的 3D 驱动来自 osy 的 viogpu3d。上游见文末。

## 从哪开始

- **装 App**：[Releases](https://github.com/zktfjcksxk-spec/WinKit/releases) 里的 `AppleVM-unsigned.ipa`（未签名，用 LiveContainer / SideStore / Sideloadly 等安装）。
- **Windows 11**：按 **[教程：制作 Windows 11 ARM64 虚拟机](docs/windows11-vm.md)** 在 Mac 上做一次镜像，
  得到 `code.fd`、`vars.fd`、`windows11.hvsparse` 三个文件，在 App 里导入；再在 Windows 里运行 WINKIT 盘的 `START.bat` 装 GPU 驱动。
- **Arch Linux**：不用做镜像，App 里选 Arch Linux → **安装镜像**，自动下载安装（KDE 桌面 + GPU 驱动）。

## 内容

| 目录 | 是什么 | 用在哪 |
|---|---|---|
| [`winkit/`](winkit) | 装进 Windows 的补齐包：3D 显卡驱动（viogpu3d + Neptune UMD）、网卡驱动（NetKVM）、一键安装 `START.bat` / `winkit.ps1`、分辨率 `setres.ps1`、3D 自检 `d3dtest.ps1`、卸载 `uninstall_3d.ps1`、可选精简 `tune.ps1`、改用户名、后台小助手 | Windows 里，双击 `START.bat`（说明：[`winkit/README.md`](winkit/README.md)） |
| [`docs/`](docs) | [Windows 11 虚拟机制作教程](docs/windows11-vm.md) | Mac 上 |
| [`source/`](source) | `windowsios-full.patch`：Release 里那个 App 的完整源码改动（相对 WindowsiOS `0071d69`），GPL 要求随二进制提供 | `git apply` 到原项目上 |
| [`3d-kit/`](3d-kit) | （早期版本，仅供参考）给原版 WindowsiOS 加 3D 的套件：模拟器补丁、取依赖和构建脚本、`setup.sh` 向导、提高内存上限的工具 | 见 [`3d-kit/README.md`](3d-kit/README.md) |

不包含：Windows 镜像（需要自己做，见教程）。编译好的 App 在 Releases 里，不在代码里；`winkit/` 就是 App 自带的 WINKIT 盘里的全部内容。
你需要自己合法的 Windows 11 授权。

`3d-kit/` 是**早期版本**，仅留作参考：它给原版 WindowsiOS 只加 3D，其中的说明和向导对应当时的旧 App。现在请直接用 Releases 里的 App，它已包含 3D。

## Upstream

| 上游 | 本仓库用到的部分 | 许可 |
|---|---|---|
| [ammaarreshi/WindowsiOS](https://github.com/ammaarreshi/WindowsiOS) | App 的基础：`source/windowsios-full.patch`（和早期的 `3d-kit/patches/windowsios-3d.patch`）都打在它的提交 `0071d69` 上 | GPL-2.0-or-later |
| [Leviidev/Henge](https://github.com/Leviidev/Henge) | WindowsiOS 的模拟器核心 | GPL-2.0-or-later |
| [utmapp/UTM](https://github.com/utmapp/UTM) | App 里的图形框架：virglrenderer（Neptune）、DXMT、ANGLE、libepoxy、Vulkan loader、MoltenVK、KosmicKrisp，取自 UTM 的 iOS 版 | Apache-2.0，各库按各自许可 |
| [Arch Linux ARM](https://archlinuxarm.org) | App 里的 Arch 安装盘（内核和安装工具）；系统本身在安装时从它的官方源下载 | 各软件包按各自许可（GPL-2.0 等） |
| [osy/kvm-guest-drivers-windows](https://github.com/osy/kvm-guest-drivers-windows)、[osy/virtio-win-mesa](https://github.com/osy/virtio-win-mesa) | `winkit/viogpu3d/`：viogpu3d v0.5 驱动和 Neptune UMD，原样 | BSD-3-Clause / MIT |
| [virtio-win/kvm-guest-drivers-windows](https://github.com/virtio-win/kvm-guest-drivers-windows)（Red Hat） | `winkit/NetKVM/`：ARM64 网卡驱动，原样，许可见 `winkit/virtio-win_license.txt` | BSD-3-Clause |

完整列表：[`THIRD_PARTY.md`](THIRD_PARTY.md)。

## 许可

本仓库自己的脚本和补丁：GPL-2.0-or-later（[`LICENSE`](LICENSE)），与它所修改的 WindowsiOS / Henge 一致。
`winkit/viogpu3d/` 和 `winkit/NetKVM/` 中的驱动按各自上游的许可原样分发。
