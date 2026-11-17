# WinKit：Windows 里的一键补齐包

在 **Apple VM**（本仓库 [Releases](https://github.com/zktfjcksxk-spec/AppleVM/releases) 里的 App）里装好 Windows 11 ARM64 之后，用它把功能补齐：
**网络驱动 → 3D 显卡驱动（DirectX 11）→ 打开 3D → 分辨率贴合屏幕 → 可选的后台精简**。
整个过程只在设备上操作，不需要 Mac。Windows 镜像怎么做见 [教程](../docs/windows11-vm.md)。

**App 已自带这个包**：启动 Windows 后，文件资源管理器里会直接出现一个叫 **WINKIT** 的盘，内容就是本目录，不需要另外下载或导入。

## 步骤

1. **装 App，导入 Windows 镜像**，用 StikDebug 开 JIT，进 Windows 桌面。
2. **双击运行**：文件资源管理器 → **WINKIT** 盘 → 双击 `START.bat` → 权限提示点“是”。
   它会依次：装网络驱动、装 3D 驱动、通知 App 打开 3D、询问是否做后台精简（按 `y` 执行，直接回车跳过；不会关闭透明和动画效果）、
   装登录链接桥 WinIOS Browser（见下文“登录链接用 Safari 打开”，会打开“设置”让你点一下“设为默认值”），
   再装（或更新）后台小助手、键盘焦点助手和剪贴板小助手（见下文）。以后有新版 WinKit，再双击一次 `START.bat` 就全部更新。
3. **彻底关掉 App 再打开**（上滑划掉），用 StikDebug 再开一次 JIT。
   Windows 登录后一分钟内会**自动**把分辨率调成贴合屏幕、只保留一个桌面，不用再操作。
4. 验证：运行 `dxdiag`，“显示”页应为 **Red Hat VirtIO GPU 3D controller**，Feature Levels 到 **11_0**。

`START.bat` 会把这些文件复制到 `C:\WinKit`，下面提到的 `C:\WinKit\...` 脚本在那之后才有；之前可以直接从 WINKIT 盘运行同名文件。

**改用户名**：按教程做出的镜像，账户名是原项目的默认值 Ammaar。`START.bat` 最后会问一次要不要改；以后想改，双击 `C:\WinKit`（或 WINKIT 盘）里的 `RENAME-USER.bat`，输入新名字即可，重新登录后生效。个人文件夹仍是原来的 `C:\Users\旧名字`，属正常现象。

**后台小助手**：`START.bat` 会装一个开机隐藏运行的小助手，App 顶部工具栏里的“Claude Code”一键安装靠它自动运行脚本；
它也负责**显示**：App 里“设置 → 显示”的显示大小、清晰度，以及折叠、展开、沉浸全屏时的画面大小，都由它实时改成 Windows 的分辨率和缩放（`WinKitDisplay.cs`，不用注销）。
同一步还装**键盘焦点助手**（`FocusAgent.cs`）：Windows 里的文本框得到焦点时 iPhone 键盘自动弹出，键盘挡住光标时画面上移；中文、带音调的字母和表情也能直接输入。
App 的“设置 → 输入 → 键盘”里可以关掉自动弹出和跟随光标。也可以单独安装：在 Windows 里运行 WINKIT 盘上的 `cli_setup.ps1`（右键 → 使用 PowerShell 运行，不需要管理员）；`cli_setup.ps1 -Remove` 卸载这两个助手。

## 登录链接用 Safari 打开（OAuth 桥）

Windows 里的软件（IDE、命令行工具、聊天软件等）登录时会用默认浏览器打开网页，登录完再跳回 `http://localhost:端口/...`。
Windows 里的 Edge 没有你的账号、密码和通行密钥；装了 **WinIOS Browser** 之后，这些网页会改在 **iPhone 上的 Safari**（浮在 Windows 上面的一个页面）里打开，
可以直接用 iPhone 上已登录的 Google 账号、钥匙串密码、通行密钥和面容 ID。登录完成后，跳回 `localhost` 的那一步会自动转回 Windows，Safari 页面自动关闭（有震动提示）。

1. **安装**：`START.bat` 的第 5 步会自动装；以前跑过旧版 WinKit 的，双击 WINKIT 盘（或 `C:\WinKit`）里的 `SAFARI-SIGNIN.bat` 单独安装，权限提示点“是”。
   它把 `WinIOSBrowser.exe` 复制到 `C:\Program Files\WinIOS`，注册成名为 WinIOS Browser 的浏览器（http、https、.htm、.html），并在防火墙里放行它的登录回调转发。可以重复运行。
2. **设为默认浏览器**：Windows 11 不允许程序自己改默认浏览器，所以脚本会打开“设置 → 应用 → 默认应用 → WinIOS Browser”，
   请点最上面的 **“设为默认值”**（没有这个按钮的旧版 Windows 11：把 .htm、.html、HTTP、HTTPS 逐个改成 WinIOS Browser），然后回到窗口按回车。
3. **Safari / Edge 切换**：App 的“设置”里有 **“Windows 里的登录链接用 Safari 打开”**（默认打开）。
   打开时，Windows 打开的链接都进 iPhone 上的 Safari；关掉时，WinIOS Browser 会把链接交给 Windows 里的 Edge。App 没在响应时也会自动退回 Edge。
   关着的时候点了登录链接，5 分钟内再打开这个开关，Safari 会立刻弹出那个登录页。

注意：设成默认后，**所有**从 Windows 打开的链接都会走这个桥，不只是登录。平时想在 Windows 里用 Edge 上网，就把 App 里的开关关掉；在 Edge 里点的链接始终留在 Edge。

- **卸载**：管理员运行 `C:\WinKit\uninstall_oauth.ps1`，删除程序、注册信息和防火墙规则，默认浏览器回到 Edge（Windows 可能会问一次用哪个应用打开）。
- **排查**：Windows 里的 `%TEMP%\winios_browser.log` 记录了每次调用、找到的端口和 App 的应答。工作原理见 [OAuth 桥说明（英文）](../docs/oauth-bridge.md)。

## 从其他设备连进 Windows（远程桌面、SSH、端口转发）

App 的“设置 → 端口转发”把 iPhone 上的端口转到 Windows 里。每条转发可以选**谁能连接**：

- **仅限这台 iPhone**：只有 iPhone 上的 App 能连（例如 iPhone 上的远程桌面 App 连 `localhost`）。
- **局域网**：同一 Wi-Fi、iPhone 个人热点里的设备都能连，地址在设置里显示。第一次会弹出“本地网络”权限，请点“允许”。
- **VPN**：只有 VPN（例如 WireGuard）里的设备能连，VPN 地址变了会自动跟上。

转发保存在每台虚拟机里，下次启动 Windows 时自动打开。**只有 App 在前台时才能连进来**：App 到后台后 iOS 会暂停它（Windows 也一起暂停）。
选“局域网”或“VPN”时，能连上这个端口的人都可以尝试登录 Windows：请给 Windows 账户设强密码，用完就关掉转发。

Windows 这边要先把服务打开、把防火墙放行：

1. **远程桌面**：双击 WINKIT 盘（或 `C:\WinKit`）里的 `REMOTE-DESKTOP.bat`，权限提示点“是”。
   它会打开远程桌面（保留网络级身份验证），并在防火墙里放行 TCP 和 UDP 3389。**只有专业版、企业版、教育版能被远程桌面连接**；
   家庭版会提示改用 SSH、升级到专业版，或者在 Windows 里装一个自带服务器的远程控制软件（例如 VNC 服务器）再自定义转发它的端口。
   然后在 App 里：设置 → 端口转发 → 添加端口转发 → 远程桌面。登录用 Windows 账户的**密码**（PIN 不行；微软账户用它的密码）。
   **没有密码的本地账户**不能用远程桌面登录（Windows 的规定），脚本会提示：先自己设一个密码（Ctrl+Alt+Del → 更改密码，或“设置 → 账户 → 登录选项 → 密码”）；WinKit 不会替你设。
2. **SSH**：先把公钥（每行一个 OpenSSH 公钥）放进 App 文件夹的 `Shared/ssh_authorized_keys.txt`，再双击 `SSH-SETUP.bat`，权限提示点“是”。
   它会装好 OpenSSH 服务器（只允许密钥登录）、设成开机启动，并放行 TCP 22。
   然后在 App 里添加“SSH”转发（iPhone 上 2222 → Windows 里 22），从其他设备运行 `ssh -p 2222 用户名@App 显示的地址`。
3. **其他服务**（网页服务器、文件共享等）：App 里有常用预设，也可以“自定义”任意端口；Windows 防火墙需要自己放行对应端口。

- **撤销**：管理员运行 `C:\WinKit\enable_rdp.ps1 -Uninstall`（远程桌面恢复成原来的设置，删除防火墙规则）或 `C:\WinKit\uninstall_ssh.ps1`
  （停掉并删除 SSH-SETUP 装的 OpenSSH 服务器和它的防火墙规则；`C:\ProgramData\ssh` 里的密钥保留）。
- **排查**：App 设置里每条转发都显示状态（正在监听哪些地址、端口被占用、没有 VPN 等）；App 文件夹里的 `winvm.log` 里有 `winvm: net: forward` 开头的记录。
  Windows 里的程序也可以用 `http://10.0.2.4/.henge/forwards` 查看所有转发（JSON）。

## 剪贴板和 iPhone 同步

Windows 里拷贝的文字会自动出现在 iPhone 的剪贴板上；iPhone 上拷贝的文字点一下 App 工具栏里的**粘贴按钮**（系统的“粘贴”按钮）就到了 Windows 的剪贴板里。只同步文字，最多 1 MB。

1. **安装**：`START.bat` 会自动装（“Clipboard shared with the iPhone”那一步）；以前跑过旧版 WinKit 的，双击 WINKIT 盘（或 `C:\WinKit`）里的 `CLIPBOARD.bat`，不需要管理员。
   它用 Windows 自带的 .NET 把 `clipboard_agent.cs` 编译成 `%LOCALAPPDATA%\WinKit\WinKitClipboard.exe`（没有窗口），
   并建一个计划任务 **WinKit Clipboard**：每次登录时在你自己的会话里启动它，之后每 5 分钟检查一次，意外退出会被重新拉起。可以重复运行。
2. **Windows → iPhone**：Windows 里拷贝文字，App 在前台时立刻写进 iPhone 剪贴板（屏幕下方提示“已从 Windows 拷贝”）；App 不在前台时，等回到 App 再写。
   App 设置 → **剪贴板** → “Windows → iPhone 自动同步”可以关掉。密码管理器标记为不记录的内容（如 KeePass、1Password 拷贝的密码）不会发过来。
3. **iPhone → Windows**：点工具栏里的粘贴按钮（或 App 设置 → 剪贴板 → “粘贴到 Windows”），iOS 不会弹“允许粘贴”。
   打开“点粘贴按钮后在 Windows 里粘贴（Ctrl+V）”，点粘贴按钮发过去的文字到了 Windows 剪贴板后会自动按一次 Ctrl+V，粘到光标处。回到 App 时自动发送的文字不会自动粘贴。
4. **回到 App 时自动发送（可选）**：App 自己读剪贴板时 iOS 默认每次都会问“允许粘贴吗”。想不被打扰地自动发送，先打开“回到 App 时 iPhone → Windows”，
   再到 iOS **设置 › Apple VM › 从其他 App 粘贴** 选 **允许**（这一项在 App 第一次读剪贴板之后才会出现），回到 App 设置里点“检查”。
   只有检查结果是“允许”时，App 才会在回到前台、而且剪贴板里有新文字时自动发送；密码管理器（1Password、Bitwarden 等）标记为私密的内容不会自动发送，要发就点粘贴按钮；之后如果读不到（iOS 里改成了拒绝，或者询问时点了“不允许”），自动发送会暂停，直到你再点“检查”。检查时最好用这台 iPhone 上拷贝的文字：从 Mac 等别的设备拷贝过来的文字读得慢，可能被当成“每次询问”。

- **状态**：App 设置 → 剪贴板 → “Windows 里的剪贴板小助手”显示“运行中”说明 Windows 这边正常。
- **卸载**：在命令提示符里运行 `CLIPBOARD.bat remove`，或右键 `C:\WinKit\uninstall_clipboard.ps1` → 使用 PowerShell 运行，删除计划任务、程序和日志。
- **排查**：Windows 里的 `%LOCALAPPDATA%\WinKit\clipboard.log`。工作原理见 [剪贴板说明（英文）](../docs/clipboard.md)。

## 电池和电源设置

App 会把 iPhone 的电池交给 Windows：Windows 右下角显示 iPhone 的电量；插着电源时是“已接通电源”，拔掉后是“使用电池”，充电时显示正在充电。
App 的“设置 → 系统 → 电池”可以关掉（只对 Windows，Arch Linux 没有），改动在下次启动 Windows 时生效。

使用电池时，Windows 默认会关屏幕、调暗、提示电量低、打开节电模式，电量很低时还会自己关机。`START.bat` 会运行 `power.ps1` 把这些都关掉；
以前跑过旧版 WinKit 的，双击 WINKIT 盘（或 `C:\WinKit`）里的 `POWER.bat`，权限提示点“是”。它对**每一个**电源计划、接通电源和使用电池两种情况都设置：

- 使用电池时的每一项都和接通电源时一样（处理器、PCIe、USB 等），然后：
- 睡眠、休眠、关闭显示器、调暗显示器、锁屏后关闭显示器、关闭硬盘：从不；混合睡眠：关；休眠功能关闭（`powercfg /h off`）
- 电量低和电量严重不足时的操作：不采取任何操作；电量低、严重不足、保留电量的级别：允许的最低值；电量低提醒：关
- 节电模式：不会自己打开（阈值 0）
- 合上盖子、睡眠按钮：不采取任何操作。**电源按钮保持“关机”**，因为 App 的“关机（通知 Windows）”就是按它；
  想让它也什么都不做，管理员运行 `C:\WinKit\power.ps1 -PowerButtonDoesNothing`（之后 App 的关机按钮就没有作用了）。

只用 powercfg，不用组策略：这些设置在 Windows 里仍然可以改。可以重复运行，只改不一样的地方，并逐条列出改了什么；结果也会写到 App 文件夹的 `Shared/power.txt`。

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
- **登录链接还是在 Edge 里打开**：WinIOS Browser 还不是默认浏览器（再双击一次 `SAFARI-SIGNIN.bat` 按提示选它），或 App 设置里的 Safari 开关是关着的。
- **登录页在 Safari 里打开了，但 Windows 里的软件没收到**：看 `%TEMP%\winios_browser.log`；出现 `relay_upstream_connect_failed` 说明软件已不在等待，回到软件里重新登录。

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
`WinIOSBrowser.exe` 由本仓库的 `tools/winios_browser_arm64.c` 编译（`make guest-tools`，GPL-2.0-or-later）；整个补齐盘用 `make winkit-img` 生成。
App 及其包含的第三方组件见仓库根目录的 [`THIRD_PARTY.md`](../THIRD_PARTY.md)。
