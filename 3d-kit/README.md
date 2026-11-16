# WindowsiOS 3D 加速套件

> **早期版本，仅供参考。** 这个套件对应最初只加 3D 的旧版 App（`WindowsiOS-3D`），其中的步骤（DRIVERS 盘、`setup.ps1`、
> LiveContainer 向导用的预编译 IPA 等）已经过时，那个 IPA 也不在本仓库里。
> 现在请用 [Releases](https://github.com/zktfjcksxk-spec/AppleVM/releases) 里的 **Apple VM** 和仓库根目录的说明；最新完整源码是 [`source/windowsios-full.patch`](../source)。


让 iPhone / iPad 上的 Windows 11 ARM64 虚拟机用上 **DirectX 11 GPU 加速**、贴合屏幕的分辨率和最高 8 GB 内存。
基于 [WindowsiOS](https://github.com/ammaarreshi/WindowsiOS)，3D 部分来自 UTM 的 Neptune + DXMT。

已在 iPad Pro 11" (M5) 和 iPhone 18 Pro（LiveContainer）上跑通，系统均为 27.0.1。

## 三步上手

**准备：** 一台 Mac（装了 Xcode）、数据线、你自己的 Windows 11 ARM64 镜像文件（`code.fd`、`vars.fd`、`windows11.hvsparse`、`drivers.img`，按原项目 README 制作）。

### 第 1 步：在 Mac 上运行向导

把设备插上 Mac、解锁，然后：

```bash
./setup.sh
```

向导会一路问你并自动完成：识别设备 → 安装 App → 推送 Windows 文件 → 推送 3D 驱动和脚本 → 打开 3D 开关。

安装方式二选一：
- **装进 LiveContainer（推荐）**：设备上已有 LiveContainer 就选这个。不用编译，不用每 7 天重签。
- **用自己的 Apple ID 编译安装**：需要 Xcode 和 `xcodegen`；免费账号每 7 天要重装一次。

### 第 2 步：开 JIT，启动 Windows

Windows 必须在 App 开了 JIT 之后才能运行。两种办法：

- **用 StikDebug（推荐，不需要 Mac）**
  1. 在设备上安装 StikDebug，按它自己的说明完成一次性配置（配对文件 / VPN 描述文件）。
  2. 打开 StikDebug 的 VPN。
  3. LiveContainer 用户：在 LiveContainer 设置里把 JIT 方式选为 StikDebug，并给 Windows 11 打开 “Launch with JIT”，之后每次启动会自动开 JIT。
     直接安装的用户：打开 StikDebug，点 “Enable JIT”，选 Windows 11。
- **用 Mac 通过 USB 开**：先在设备上启动 App 并保持在前台，然后运行 `./setup.sh jit`。
  需要 2–3 分钟且期间没有任何输出，这是在准备 768 MiB 的代码缓存，**不是卡住，不要打断**。

第一次启动会解包磁盘（几分钟），然后进入 Windows 桌面。

### 第 3 步：在 Windows 里输入一条命令（共两次）

1. 先装网络驱动（只需一次）：文件资源管理器 → **DRIVERS** 盘 → 右键 `install_netkvm.cmd` → 以管理员身份运行。
2. 右键开始按钮 → 终端，输入：

   ```
   irm http://10.0.2.4/setup.ps1 | iex
   ```

   - **第一次运行**：安装 3D 驱动。装完后在设备上**彻底关掉 App 再重新打开**（再开一次 JIT）。
   - **第二次运行同一条命令**：把分辨率设成贴合屏幕、只保留一个桌面，并询问是否做后台精简。
3. 验证：运行 `dxdiag`，“显示”页应为 **Red Hat VirtIO GPU 3D controller**，Feature Levels 到 **11_0**，Direct3D Acceleration: Enabled。

## 出问题时

| 现象 | 处理 |
|---|---|
| 开了 3D 后黑屏 | Mac 上 `./setup.sh 3d off`，重启 App，Windows 会回到基本显示。 |
| 想看 App 当前状态 | `./setup.sh status`（内存、JIT、3D、分辨率）。 |
| Windows 里的脚本想更新 | `./setup.sh push`。 |
| 3D 不工作想排查 | Windows 里运行 `irm http://10.0.2.4/d3dtest.ps1 | iex`，结果在共享文件夹的 `d3dtest.txt`。 |
| 想卸载 3D 驱动 | 管理员终端运行 `irm http://10.0.2.4/uninstall_3d.ps1 | iex`。 |

## 必须知道的几件事

- **不要在 Windows 里禁用 “Microsoft Basic Display Driver”。** 它是 3D 出问题时唯一的后备显示；禁用后一旦黑屏，连权限提示都点不了，只能重刷镜像。
- **最高 DirectX 11（功能级别 11_0），没有 DX12。** iOS 的 Metal 缺少 11.1 必需的功能，App 已把 DXMT 限制在 11.0，否则 Windows 会拒绝驱动、桌面合成器反复崩溃。
- **显存窗口 512 MB**，受 App 地址空间限制。
- **不要用 Windows 自己的“重启”**，可能卡死；在设备上关掉 App 再开。
- **8 GB 内存需要 Increased Memory Limit。** LiveContainer 一般自带；自己编译安装的免费账号用 `scripts/04_more_ram.sh` 申请。没有的话内存会自动降到 4–5 GB，3D 可能加载失败。
- 内存大小和 JIT 缓存可在 App 的“设置 → 高级设置”里调整（内存自动或 2–16 GB；超过 8 GB 需要设备本身内存足够，未实测）。
- 后台精简脚本会关闭自动更新（收不到安全更新），**不会**改动 Windows 安全中心。
- 已知未解决：偶发的开机早期停机和 `0x1A` 蓝屏；空闲时 JIT 缓存仍增长较快。

## 包里有什么

- `setup.sh`：Mac 端向导（以及 `jit`、`3d on|off`、`push`、`status` 子命令）。
- `ipa/`：预编译的未签名 IPA（LiveContainer 方式直接使用）和重签所需的权限文件。
- `guest/`：Windows 里运行的脚本，入口是 `setup.ps1`。
- `patches/windowsios-3d.patch` + `scripts/`：源码补丁和编译脚本（自己编译时由向导调用）。
- `tools/gmrcli/`：GetMoreRam 的 Mac 命令行版。
- `THIRD_PARTY.md`：第三方项目与许可。预编译 IPA 内含 UTM v5.0.8 的 iOS 图形框架；其余第三方文件由脚本从官方发布页下载。
