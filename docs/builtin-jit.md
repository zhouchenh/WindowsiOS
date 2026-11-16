# Built-in JIT

The emulator needs JIT. On iOS 26 and 27 (devices with the Trusted Execution Monitor, TXM, such
as the iPhone Duo) only an attached debugger can give an app executable memory, so a debugger has
to attach once each time Apple VM starts. Apple VM can do that in two ways:

- **StikDebug**: the StikDebug app attaches (Apple VM asks it through a `stikjit://` link).
- **Built-in**: a debugger shipped inside Apple VM does it. No StikDebug app and no computer.

Pick one in the JIT row of the start page: **Automatic** (Built-in once it is paired, StikDebug
until then), **StikDebug** or **Built-in**.

Built-in JIT is not JIT without a debugger: there is none on stock iOS 26/27. It is the debugger
moved into the app. Apple VM carries an app extension, `PlugIns/WinJITHelper.appex`, that runs
[StikJIT](https://github.com/StikDebug/StikJIT) (the debugger StikDebug is built on). When you tap
Enable, Apple VM starts the extension; StikJIT connects to this device's own debug service through
LocalDevVPN, attaches to Apple VM and runs Apple VM's JIT script (`henge-jit.js`), which hands out
the JIT memory and the guest RAM. Then the script detaches and the extension ends: nothing keeps
running in the background.

The design and most of the code come from [Henge](https://github.com/Leviidev/Henge) (0.3, commit
`7b55730`) and [Husk](https://github.com/Leviidev/Husk) (`29abb51`).

## What you need

- iOS 26 or later (on iOS 17 to 25 use StikDebug).
- **Developer Mode** on.
- A **pairing** of this device with Apple VM, made once. On iOS 27 Apple VM makes it on the device
  itself; otherwise import a pairing file.
- **[LocalDevVPN](https://apps.apple.com/app/id6755608044)** (free, App Store), connected when you
  enable JIT. StikJIT reaches the device's debug service at 10.7.0.1 through it.
- Wi-Fi for the pairing on the device. Enabling JIT works on cellular too (see Troubleshooting).
- Apple VM installed **with its app extension** and signed with `get-task-allow`: by Xcode
  (docs/building.md, section 4b), or by SideStore/AltStore from the IPA. Not inside LiveContainer
  (below).

## Steps

Open the JIT row's **Built-in JIT setup…** (or choose Built-in and tap Enable: the setup opens
when something is missing).

1. **Developer Mode.** Settings › Privacy & Security › Developer Mode: turn it on and restart the
   device. Once.
2. **Pair (once).**
   - **iOS 27: Pair with Apple VM.** Tap **Pair on this iPhone**. Apple VM announces itself on the
     local network as a computer you can pair with (allow **Local Network** when iOS asks). Open
     Settings › Privacy & Security › Developer Mode and tap **Pair with Apple VM**. Settings asks
     for a code: Apple VM shows it in the app, in the background-task banner and as a
     notification. Type it in Settings. The setup then shows "Paired on this device". Apple VM
     waits up to 5 minutes; if iOS will not let it run in the background long enough (the setup
     says so), pair in Settings straight away.
   - **Or import a pairing file**: an RPPairing plist (keys `public_key`, `private_key`,
     `identifier`) made on a computer, for example with idevice's pairing tool or the
     [StikDebug pairing-file guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md).
     Tap **Import pairing file…**, or copy it with Finder or the Files app to
     `Apple VM/StikJIT/pairingFile.plist`.

   The pairing file stays in Apple VM's Documents and is only ever passed to its own helper. Each
   new pairing with Apple VM replaces the previous one on the device (pairings of StikDebug, Henge
   and others are separate).
3. **LocalDevVPN.** Install it and connect it (the setup's **Connect** button opens it and comes
   back to Apple VM).
4. **Prepare.** Checks that the device answers through LocalDevVPN and mounts the Developer Disk
   Image, downloading it the first time. Needed again after each restart of the device, but Enable
   does it by itself, so this step is mainly a check. **Reset Developer Disk Image cache** helps
   when a download went wrong.
5. **Enable JIT.** The helper attaches; the start page shows JIT as enabled, usually within a few
   seconds (longer the first time, while the disk image is downloaded). Then start Windows.

**Turn on JIT when the app opens** (start page and setup) does step 5 by itself at each launch:
with Built-in chosen and paired, Apple VM connects LocalDevVPN first if it is off, then enables JIT.

## Limits

- **LiveContainer**: a copy of Apple VM running inside LiveContainer cannot start its app
  extension, so Built-in JIT is unavailable there (the setup says so). Use StikDebug, or install
  Apple VM directly with SideStore or AltStore.
- **SideStore, AltStore, SideInstaller and other signing tools must keep app extensions.** If yours
  asks, choose to keep them. If the extension is removed, the setup says the helper is missing.
- **Free Apple ID**: the extension has its own bundle id (`<Apple VM's id>.JITHelper`), so it uses
  a second App ID. Free accounts can register 10 App IDs per 7 days, and apps still expire after
  7 days.
- **Signing without `get-task-allow`** (a distribution certificate, some signing services): no
  debugger can attach. The setup says so.
- **LocalDevVPN** is a third-party app. Built-in JIT does not work without it or another VPN that
  routes 10.7.0.1 to this device.
- On-device pairing uses iOS 27's device-initiated pairing, which Apple does not document; an iOS
  update could change it. Importing a pairing file, or StikDebug, keeps working then.

## Troubleshooting

- **"Apple VM couldn't reach this device"**: LocalDevVPN is not connected or not routing. Connect
  it, turn off other VPNs (Tailscale and the like), then try again.
- **On cellular only**, LocalDevVPN can show Connected while iOS sends the connection over the
  mobile network. Apple VM retries twice by itself. If it still fails, turn Cellular Data off in
  Control Center, wait 2 seconds, turn it on again; or join any Wi-Fi once (a hotspot works).
- **"This device closed the connection"**: the device no longer accepts the pairing (it was
  replaced by a newer pairing, or reset). Pair again.
- **"needs Local Network access"**: Settings › Apps › Apple VM › Local Network.
- **The helper does not attach within 150 seconds**: run Prepare to see what fails.
- The app's log (Xcode console, or `scripts/launch_on_duo.sh`) has `[winios-jit]` lines for each
  step; the helper logs as `[WinJITHelper]` in the device console.

## How it is built

`scripts/build_jit_deps.sh` (also run by `scripts/build_ios_deps.sh`) builds two dependencies
from source into the gitignored `ios/deps`:

- `StikJIT.xcframework`: StikJIT 1.9.0 (tag checked against commit `32287268`) with
  `ios/patches/stikjit-high-address.patch` (Henge's `ci/stikjit-high-address.patch`: page
  addresses in its `$M` packets get 16 hex digits instead of 9). MPL-2.0; it contains idevice (MIT)
  as the prebuilt `libidevice_ffi.a` that StikJIT's repository ships, with the Rust crates idevice
  is built on (tokio, rustls, AWS-LC through aws-lc-rs, and others). StikJIT does not say which
  idevice commit that library is; the crates in it are those of idevice's `Cargo.lock` at
  `d32c818` (0.1.68), and the script generates their notices from it and checks them against the
  library (the provenance note in `scripts/build_jit_deps.sh` says how that commit was found).
- `lib/libhusk_rppairing.a`: Husk's `src/rppairing-ios` (commit `29abb51`, GPL-2.0-or-later), a
  small Rust wrapper of idevice 0.1.68's `PairableHost`, for on-device pairing. Built with rustup's
  toolchain for `aarch64-apple-ios` (`rustup target add` is done for you). Its C interface is
  `ios/Sources/Native/HuskRPPairing.h`.

The Xcode project (`ios/project.yml`) has the `WinJITHelper` app-extension target (iOS 26+,
`ios/WinJITHelper/`, signing from `ios/WinJITHelper.xcconfig`), which links StikJIT; the app's
**Embed StikJIT** build phase puts the framework into `Frameworks/`. The app's side is
`ios/Sources/BuiltInJIT.swift` (starting the helper, the pairing file, the port lookup),
`BuiltInJITPairing.swift` (on-device pairing), `BuiltInJITView.swift` (the picker and the setup)
and `JITSetup.swift` (the requests, shared with StikDebug). The JIT protocol on Apple VM's side
(`winios_jit.c`, `winios_brk.S`, `henge-jit.js`) is the same as for StikDebug.

The licences that ship in the app are in `ios/Sources/Resources/legal` (the app's `legal/` folder):
StikJIT's MPL-2.0 with our patch, idevice's MIT licence, and the licence notices of every Rust
crate in StikJIT's idevice library (`LICENSES-stikjit-idevice-crates.txt`) and in the pairing
library (`LICENSES-rppairing-crates.txt`). See also `THIRD_PARTY_NOTICES.md`.
