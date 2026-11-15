# WinKit：Windows 里的一键补齐包

在 **Apple VM**（本仓库 [Releases](https://github.com/zktfjcksxk-spec/WinKit/releases) 里的 App）里装好 Windows 11 ARM64 之后，用它把功能补齐：
**网络驱动 → 3D 显卡驱动（DirectX 11）→ 打开 3D → 分辨率贴合屏幕 → 可选的后台精简**。
整个过程只在设备上操作，不需要 Mac。Windows 镜像怎么做见 [教程](../docs/windows11-vm.md)。

**App 已自带这个包**：启动 Windows 后，文件资源管理器里会直接出现一个叫 **WINKIT** 的盘，内容就是本目录，不需要另外下载或导入。

## 步骤

1. **装 App，导入 Windows 镜像**，用 StikDebug 开 JIT，进 Windows 桌面。
2. **双击运行**：文件资源管理器 → **WINKIT** 盘 → 双击 `START.bat` → 权限提示点“是”。
   它会依次：装网络驱动、装 3D 驱动、通知 App 打开 3D、询问是否做后台精简（按 `y` 执行，直接回车跳过；不会关闭透明和动画效果）。
3. **彻底关掉 App 再打开**（上滑划掉），用 StikDebug 再开一次 JIT。
   Windows 登录后一分钟内会**自动**把分辨率调成贴合屏幕、只保留一个桌面，不用再操作。
4. 验证：运行 `dxdiag`，“显示”页应为 **Red Hat VirtIO GPU 3D controller**，Feature Levels 到 **11_0**。

`START.bat` 会把这些文件复制到 `C:\WinKit`，下面提到的 `C:\WinKit\...` 脚本在那之后才有；之前可以直接从 WINKIT 盘运行同名文件。

**改用户名**：按教程做出的镜像，账户名是原项目的默认值 Ammaar。`START.bat` 最后会问一次要不要改；以后想改，双击 `C:\WinKit`（或 WINKIT 盘）里的 `RENAME-USER.bat`，输入新名字即可，重新登录后生效。个人文件夹仍是原来的 `C:\Users\旧名字`，属正常现象。

**后台小助手**：`START.bat` 会装一个开机隐藏运行的小助手，App 顶部工具栏里的“Claude Code”一键安装靠它自动运行脚本。也可以单独安装：在 Windows 里运行 WINKIT 盘上的 `cli_setup.ps1`（右键 → 使用 PowerShell 运行，不需要管理员）。

## 用 StikDebug 开 JIT

1. 安装 StikDebug，按它的说明做一次性配置，打开它的 VPN。
2. LiveContainer 用户：在 LiveContainer 设置里把 JIT 方式选为 StikDebug，并给 Apple VM 打开 “Launch with JIT”，以后启动自动开。
   直接安装的用户：打开 StikDebug → Enable JIT → 选 Apple VM。

## 出问题时

- **开 3D 后黑屏**：在“文件”App 里删除本 App 文件夹下 `Shared/gpu3d.on`（或把内容改成 `off`），重启 App，Windows 会回到基本显示。
- **第 2 步提示连不上 App**：重启 App 后再双击一次 `START.bat`；或者在“文件”App 里手动建一个名为 `gpu3d.on` 的文件放到 `Shared/` 下。
- **分辨率没有自动调整**：在 Windows 里以管理员身份运行 `C:\WinKit\setres.ps1`。
- **排查 3D**：运行 `C:\WinKit\d3dtest.ps1`，结果在 App 文件夹的 `Shared/d3dtest.txt`。
- **卸载 3D 驱动**：管理员运行 `C:\WinKit\uninstall_3d.ps1`。

## 注意

- **不要在 Windows 里禁用 “Microsoft Basic Display Driver”**，它是 3D 出问题时唯一的后备显示。
- Windows 自己的“重启”偶尔会卡在黑屏；卡住时在设备上关掉 App 再开即可。“关机”没有这个问题。
- 直接划掉 App 相当于给 Windows 断电：刚改的设置可能丢失。改了设置后先从开始菜单关机。
- 最高 DirectX 11（功能级别 11_0），没有 DX12；显存窗口 512 MB。
- 8 GB 内存需要 App 有 Increased Memory Limit 权限（LiveContainer 一般自带），否则自动降到 4–5 GB。
- 内存大小和 JIT 缓存可在 App 的“设置 → 高级设置”里调整（内存自动或 2–16 GB；超过 8 GB 需要设备本身内存足够，未实测）。
- 后台精简会关闭自动更新（收不到安全更新），不会改动 Windows 安全中心。

## 许可

补齐盘里的 NetKVM 来自 virtio-win（见盘内 `virtio-win_license.txt`），3D 驱动来自 osy/kvm-guest-drivers-windows v0.5，均为原样二进制。
App 及其包含的第三方组件见仓库根目录的 [`THIRD_PARTY.md`](../THIRD_PARTY.md)。
