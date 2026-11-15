# WinKit：不用 Mac 的一键补齐包


> **新版 App 已自带 WINKIT 驱动盘**：导入镜像时不需要再选 `drivers.img`，Windows 里会直接出现 WINKIT 盘。设备上已有的 `drivers.img` 如果比 App 自带的旧，会自动改用 App 里的那份。
在 iPhone / iPad 的 WindowsiOS 里装好 Windows 11 ARM64 之后，用这个包把功能补齐：
**网络驱动 → 3D 显卡驱动（DirectX 11）→ 打开 3D → 分辨率贴合屏幕 → 可选的后台精简**。
整个过程只在设备上操作，不需要 Mac，也不涉及签名。JIT 每次用 StikDebug 开。

## 包里有什么

| 文件 | 用途 |
|---|---|
| `WindowsiOS-3D.ipa` | 带 3D 支持的 App（未签名）。用 LiveContainer 等你平时的方式安装。 |
| `drivers.img` | 补齐盘。放进 App 后，Windows 里会多出一个叫 **WINKIT** 的磁盘。 |
| `WinKit.zip` | 和补齐盘内容相同的压缩包。Windows 已经能上网时，可以直接在 Windows 里下载解压使用。 |

## 步骤

1. **装 App，装好 Windows**（按原项目的方式，能进桌面即可）。
2. **放补齐盘**：在设备的“文件”App 里，把 `drivers.img` 放到本 App 的文件夹：
   `Machines/Win11/drivers.img`（已有同名文件就替换）。
   LiveContainer 用户的路径在 LiveContainer 文件夹下的 `Data/Application/<一串字符>/Documents/Machines/Win11/`。
3. **重启 App**，用 StikDebug 开 JIT，进 Windows 桌面。
4. **双击运行**：文件资源管理器 → **WINKIT** 盘 → 双击 `START.bat` → 权限提示点“是”。
   它会依次：装网络驱动、装 3D 驱动、通知 App 打开 3D、询问是否做后台精简（不会关闭透明和动画效果）（按 `y` 或直接回车跳过）。
5. **彻底关掉 App 再打开**（上滑划掉），用 StikDebug 再开一次 JIT。
   Windows 登录后一分钟内会**自动**把分辨率调成贴合屏幕、只保留一个桌面，不用再操作。
6. 验证：运行 `dxdiag`，“显示”页应为 **Red Hat VirtIO GPU 3D controller**，Feature Levels 到 **11_0**。

用压缩包的话：把 `WinKit.zip` 弄进 Windows（例如用 Edge 下载），右键“全部解压缩”，双击里面的 `START.bat`，后面相同。

**改用户名**：镜像自带的账户名是制作者的名字。`START.bat` 最后会问一次要不要改；以后想改，双击 `C:\WinKit`（或 WINKIT 盘）里的 `RENAME-USER.bat`，输入新名字即可，重新登录后生效。个人文件夹仍是原来的 `C:\Users\旧名字`，属正常现象。

**后台小助手**：`START.bat` 会装一个开机隐藏运行的小助手，App 顶部工具栏里的“Claude Code”一键安装靠它自动运行脚本。已经装好系统的设备，在 Windows 里运行一次 `powershell -ExecutionPolicy Bypass -File C:\WinKit\cli_setup.ps1` 即可（不需要管理员）。以前的“纯命令行启动”模式已删除；这个脚本也会清掉它留下的登录钩子（开机时先出现命令行窗口、左下角出现两个最小化窗口，就是它造成的），清完从开始菜单正常重启一次即可。

## 用 StikDebug 开 JIT

1. 安装 StikDebug，按它的说明做一次性配置，打开它的 VPN。
2. LiveContainer 用户：在 LiveContainer 设置里把 JIT 方式选为 StikDebug，并给 Windows 11 打开 “Launch with JIT”，以后启动自动开。
   直接安装的用户：打开 StikDebug → Enable JIT → 选 Windows 11。

## 出问题时

- **开 3D 后黑屏**：在“文件”App 里删除本 App 文件夹下 `Shared/gpu3d.on`（或把内容改成 `off`），重启 App，Windows 会回到基本显示。
- **第 4 步提示连不上 App**：重启 App 后再双击一次 `START.bat`；或者在“文件”App 里手动建一个名为 `gpu3d.on` 的文件放到 `Shared/` 下。
- **分辨率没有自动调整**：在 Windows 里以管理员身份运行 `C:\WinKit\setres.ps1`。
- **排查 3D**：运行 `C:\WinKit\d3dtest.ps1`，结果在 App 文件夹的 `Shared/d3dtest.txt`。
- **卸载 3D 驱动**：管理员运行 `C:\WinKit\uninstall_3d.ps1`。

## 注意

- **不要在 Windows 里禁用 “Microsoft Basic Display Driver”**，它是 3D 出问题时唯一的后备显示。
- **不要用 Windows 自己的“重启”**，可能卡死；在设备上关掉 App 再开。
- 最高 DirectX 11（功能级别 11_0），没有 DX12；显存窗口 512 MB。
- 8 GB 内存需要 App 有 Increased Memory Limit 权限（LiveContainer 一般自带），否则自动降到 4–5 GB。
- 内存大小和 JIT 缓存可在 App 的“设置 → 高级设置”里调整（内存自动或 2–16 GB；超过 8 GB 需要设备本身内存足够，未实测）。
- 后台精简会关闭自动更新（收不到安全更新），不会改动 Windows 安全中心。

## 许可

补齐盘里的 NetKVM 来自 virtio-win（见盘内 `virtio-win_license.txt`），3D 驱动来自 osy/kvm-guest-drivers-windows v0.5，均为原样二进制。
IPA 内含 UTM v5.0.8 iOS 版的图形框架（virglrenderer、DXMT、ANGLE 等），App 主体为 GPL-2.0，源码补丁见 WindowsiOS-3D-Kit。
