# 教程：制作 Windows 11 ARM64 虚拟机

本仓库**不提供** Windows 镜像：它包含受授权保护的 Windows，需要你用自己合法的 Windows 11 授权自己制作。
制作只需在 Mac 上做**一次**，之后得到的几个文件放进 iPhone / iPad 上的 App 即可一直使用。

> Arch Linux 不用按这个教程做：在 App 里选 Arch Linux → **安装镜像**，App 会自己下载安装（含 KDE 桌面和 GPU 驱动）。

## 最终产物（要放进 App 的文件）

| 文件 | 大小 | 是什么 |
|---|---|---|
| `code.fd` | 64 MB | UEFI 固件（EDK2 ArmVirtQemu），虚拟机的“BIOS” |
| `vars.fd` | 64 MB | UEFI 设置（NVRAM），里面有 Windows 的启动项。**必须用制作时生成的这一份**，换一份空白的会进不了系统 |
| `windows11.hvsparse` | 约 10–15 GB | Windows 系统盘的压缩打包。App 第一次启动时会自动把它解包成 `windows11.img`（32 GB 稀疏文件，只占实际写入的空间） |

也可以不打包，直接用 `windows11.img` 代替 `windows11.hvsparse`，但传输起来更慢。
驱动盘（`drivers.img` / WINKIT 盘）**不需要**：App 自带。

## 你需要

- 一台 Apple 芯片的 Mac（M1 或更新），macOS + Xcode 命令行工具，约 **80 GB** 空闲空间。
- [Homebrew](https://brew.sh)，以及这些工具：
  ```bash
  brew install wimlib qemu libslirp glib pkg-config python
  ```
  制作脚本按 Apple 芯片 Mac 上 Homebrew 的默认位置（`/opt/homebrew`）找这些工具。
  `qemu` 只用来取它附带的 UEFI 固件文件（`edk2-aarch64-code.fd`、`edk2-arm-vars.fd`），不会运行 QEMU。
- **Windows 11 24H2 ARM64 零售版 ESD**（英文版，约 4.5 GB），从微软官方服务器下载，见第 3 步。
- 你自己的 Windows 11 授权。

## 第 1 步：取得源码并打上补丁

App 和制作工具都来自 [WindowsiOS](https://github.com/ammaarreshi/WindowsiOS)，本仓库的补丁加上了 GPU、Arch Linux 等改动：

```bash
git clone https://github.com/ammaarreshi/WindowsiOS
cd WindowsiOS
git checkout 0071d69
git apply /path/to/AppleVM/source/windowsios-full.patch
```

## 第 2 步：编译 Mac 版模拟器和打包工具

```bash
make -j8 all
```

得到 `build/winvm`（Mac 上运行的同一个模拟器，用来安装 Windows）和 `build/hvsparse`（打包工具）。

## 第 3 步：下载 Windows 11 ARM64 ESD

ESD 是微软 Media Creation Tool 下载的安装文件。下载地址在微软的目录文件里，在 `WindowsiOS` 目录下运行：

```bash
mkdir -p work/downloads && cd work/downloads
# 微软的 Windows 11 24H2 目录（Media Creation Tool 用的），解开得到 products.xml
curl -L -o products.cab "https://go.microsoft.com/fwlink/?LinkId=2156292"
tar -xf products.cab
# 找出 ARM64、英文、专业版那一项的下载地址和 SHA1
python3 - <<'PY'
import xml.etree.ElementTree as ET
for f in ET.parse('products.xml').getroot().iter('File'):
    if f.findtext('Architecture') == 'ARM64' and f.findtext('LanguageCode') == 'en-us' and f.findtext('Edition') == 'Professional':
        print(f.findtext('FilePath')); print('SHA1', f.findtext('Sha1')); break
PY
```

用打印出来的地址下载，存成脚本要的名字，再核对 SHA1（必须和上面打印的一致）：

```bash
curl -L -o Win11_24H2_ARM64_en-us.esd "<上面打印出的地址>"
shasum -a 1 Win11_24H2_ARM64_en-us.esd
cd ../..
```

> 2026 年 11 月核对时，这个目录给出的是 Build **26100.4349**（`..._CLIENTCONSUMER_RET_A64FRE_en-us.esd`，4.5 GB，
> SHA1 `c78fd344e845d3b17cb91c40bf4a856459da1b6c`）。微软更新目录后版本号和 SHA1 会变，以你下载时打印的为准。

制作脚本要求 ESD 里：第 1 个映像是安装介质、第 2 个是 WinPE、**第 6 个是 Windows 11 Pro**。上面这个 ESD 正是如此
（1 安装介质、2 WinPE、3 Windows Setup、4 Home、5 Home Single Language、6 Pro）。用别的 ESD 时先检查：

```bash
wimlib-imagex info work/downloads/Win11_24H2_ARM64_en-us.esd
```

Pro 不是第 6 个的话，把 `scripts/provision_windows_arm64.py` 里 `export", ESD, "6"` 的 `6` 改成对应的序号。

## 第 4 步：自动安装 Windows

```bash
python3 scripts/provision_windows_arm64.py
```

全程无人值守，分两个阶段，**一般需要 1–4 小时**，期间不用操作：

1. **阶段 1（最长 150 分钟）**：在模拟器里启动 WinPE，给 32 GB 的虚拟盘分区，用 DISM 把 Windows 装上去，写好启动项，然后关机。
2. **阶段 2（最长 240 分钟）**：启动装好的 Windows，完成首次设置（OOBE），自动登录一次，然后关机。

脚本把进度和截图写在 `work/` 里（`prov_phase1.png`、`prov_phase2.png`），结束时打印
`SUCCESS: Windows 11 Pro ARM64 provisioned and cleanly shut down!`。

完成后 `work/` 里有：`windows11.img`（系统盘）、`code.fd`、`vars.fd`。

装好的系统：本地管理员账户 **Ammaar**（原项目的默认值）、**没有密码**、自动登录，计算机名 **Apple-VM**。
账户名可以之后用 WinKit 的 `RENAME-USER.bat` 改掉。此时 Windows 里还没有网卡驱动，没网是正常的（第 7 步装）。

## 第 5 步：打包系统盘

```bash
./build/hvsparse pack work/windows11.img work/windows11.hvsparse
```

到这里，三个最终产物都在 `work/` 里：**`code.fd`、`vars.fd`、`windows11.hvsparse`**。

## 第 6 步：装 App，放入文件

1. 从本仓库的 [Releases](https://github.com/zktfjcksxk-spec/WinKit/releases) 下载 `AppleVM-unsigned.ipa`，用你平时的方式安装
   （LiveContainer、SideStore、Sideloadly，或自己用 Xcode 签名）。重签时保留 `3d-kit/ipa/WindowsiOS.entitlements`
   里的权限：`get-task-allow`（开 JIT 必需）和 `increased-memory-limit`（大内存）。
2. 把三个文件传到设备上（AirDrop、“文件” App、iCloud 都可以）。
3. 打开 App → 左边选 **Windows 11** → **导入镜像** → 一次选中 `code.fd`、`vars.fd`、`windows11.hvsparse`。
4. 用 **StikDebug** 开 JIT（在 StikDebug 里选 **Apple VM**），点 **启动 Windows 11**。第一次会先解包系统盘（几分钟），然后进入桌面。

## 第 7 步：装 GPU 和网卡驱动

在 Windows 里：文件资源管理器 → **WINKIT** 盘 → 双击 **`START.bat`** → 权限提示点“是”。
它会装网卡驱动、3D 显卡驱动，并通知 App 打开 3D。然后彻底关掉 App 再打开、再开 JIT。

验证：运行 `dxdiag`，“显示”页应为 **Red Hat VirtIO GPU 3D controller**，Feature Levels 到 **11_0**。
更多说明见 [`winkit/README.md`](../winkit/README.md)。

## 常见问题

- **能不能不用 Mac？** 制作这一步不行：需要在 Mac 上运行模拟器装一遍 Windows。之后在设备上的所有操作都不需要 Mac。
- **为什么不直接提供做好的镜像？** 镜像里是完整的 Windows，不能公开分发。
- **`vars.fd` 弄丢了怎么办？** 重新做一遍第 4 步。空白的 `vars.fd` 里没有 Windows 的启动项。
- **想要更大的系统盘？** App 的设置 → 高级设置 → 系统盘容量可以扩容，扩完在 Windows 的“磁盘管理”里扩展 C 盘。
