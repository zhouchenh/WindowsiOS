# 预编译 IPA（未签名）

> **本仓库不包含这个旧版 IPA。** 以下说明仅供参考；当前的 App 是 [Releases](https://github.com/zktfjcksxk-spec/AppleVM/releases) 里的 `AppleVM-unsigned.ipa`
> （Bundle ID `com.applevm.app`），重签时同样保留 `WindowsiOS.entitlements` 里的权限。


`WindowsiOS-3D-unsigned.ipa` 是打好补丁、已嵌入 3D 框架的 App，**没有签名**，Bundle ID 是占位的 `org.windowsios.app3d`。

**最简单的用法：** 运行上级目录的 `./setup.sh` 并选择 LiveContainer 方式，向导会直接把它装进 LiveContainer，不需要签名。

其他用法：用你自己的账号重签后安装（Sideloadly、AltStore/SideStore、或 Xcode + `codesign` 都可以）。重签时请保留这些权限（见 `WindowsiOS.entitlements`）：

- `get-task-allow`：从 Mac 用 LLDB 开 JIT 必需。
- `com.apple.developer.kernel.increased-memory-limit`：8 GB 客户机内存 + 3D 需要。免费账号要先用 `scripts/04_more_ram.sh` 给你的 App ID 加上这个能力，并用它下载的描述文件签名；没有它也能运行，但内存会自动降到 4–5 GB 左右，且 3D 框架可能因地址空间不足而加载失败。

安装后仍然需要：

1. 自己的 Windows 11 ARM64 镜像和固件文件，放进 App 的 `Documents/Machines/Win11`。
2. 每次启动开 JIT：用设备上的 StikDebug，或在 Mac 上运行 `./setup.sh jit`。
3. 打开 3D 开关：`./setup.sh 3d on`（即在 App 的 `Documents` 里写入 `gpu3d.on`）。

IPA 内含来自 UTM v5.0.8 iOS 版的框架（virglrenderer、DXMT、ANGLE、libepoxy、Vulkan loader），各自的许可见上级目录的 `THIRD_PARTY.md`；DXMT 为 LGPL，以独立动态框架形式提供，可自行替换。App 主体为 GPL-2.0，对应源码即 `patches/windowsios-3d.patch` + 原项目提交 `0071d69`。
