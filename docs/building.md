# Building Apple VM (Duo edition)

These steps build the app from source on an Apple Silicon Mac with **macOS 27** and **Xcode 27.2**
(iOS 27.2 SDK). The result is either an unsigned IPA for sideloading or an app signed with your own
Apple account and installed from Xcode. Nothing here needs the original authors' certificates.

The app still has its upstream name in the source tree: the Xcode target, scheme and bundle are
`WindowsiOS`; the name on the home screen is **Apple VM**.

## 1. Tools

1. Install Xcode 27.2 from the App Store or developer.apple.com, open it once, and accept the license.
   If Xcode says the iOS platform is missing, install it (Xcode > Settings > Components, or
   `xcodebuild -downloadPlatform iOS`). Check:

   ```sh
   xcode-select -p          # /Applications/Xcode.app/Contents/Developer
   xcodebuild -version      # Xcode 27.2
   xcrun --sdk iphoneos --show-sdk-version   # 27.2
   ```

   If `xcode-select -p` prints `/Library/Developer/CommandLineTools`, run
   `sudo xcode-select -s /Applications/Xcode.app`.

2. Install [Homebrew](https://brew.sh), then:

   ```sh
   brew install xcodegen meson ninja mtools libslirp pkgconf python
   ```

   `scripts/build_ios_deps.sh` runs meson with `/opt/homebrew/bin/python3`. For the freestanding
   Windows guest helpers in `tools/` you also need `brew install llvm lld` (not needed for the app).

## 2. Source

```sh
git clone -b duo https://github.com/zhouchenh/WindowsiOS.git AppleVM-Duo
cd AppleVM-Duo
```

## 3. Engine, tests and the iOS libraries

```sh
make -j8 all && make test-core      # macOS runner build/winvm, build/hvsparse, core JIT/MMU tests
scripts/build_ios_deps.sh           # once: libffi + glib + libslirp for iOS into ios/deps/
make -j8 ios-lib                    # build/ios/libwinvm.a (the engine for the app)
```

`build_ios_deps.sh` downloads libffi 3.5.0, glib 2.83.0 and libslirp 4.9.1, cross-compiles them for
arm64 iOS 17.0 and takes a few minutes. It only needs to run again when the script changes; its
logs are in `work/ios_deps_build/*.log`.

## 4a. Unsigned IPA (for SideStore, AltStore, Sideloadly, LiveContainer)

```sh
scripts/package_ipa.sh              # add --tipa for a .tipa copy as well
```

This regenerates the Xcode project, builds the Release configuration without signing, and writes
`dist/AppleVM-Duo-unsigned.ipa`. It then checks the archive (a single `Payload/WindowsiOS.app`,
an arm64 executable, the JIT script, the signature) and prints its size and SHA-256.

"Unsigned" means no developer certificate: the app is ad-hoc signed with
`ios/WindowsiOS.entitlements`, so that the tool that signs it for your device sees and keeps
`get-task-allow`, which JIT needs. Use `--entitlements ios/WindowsiOS-IncreasedMemory.entitlements`
if you will re-sign with an account that has the Increased Memory Limit capability.

The IPA's bundle id is `com.applevm.duo`, the one in `repo.json`, even if your
`ios/Signing.local.xcconfig` (section 4b) sets another; pass `--bundle-id ID` for a different one.

### 3D graphics (optional)

Without extra files the IPA has 2D graphics only. The 3D path (virtio-gpu with virglrenderer,
DXMT, ANGLE and Vulkan) uses unmodified frameworks from UTM's iOS build, which are not in git.
Unpack UTM 5.0.8 where the script looks for it:

```sh
mkdir -p work/utm
curl -L -o work/utm/UTM.ipa https://github.com/utmapp/UTM/releases/download/v5.0.8/UTM.ipa
unzip -q work/utm/UTM.ipa -d work/utm      # gives work/utm/Payload/UTM.app/Frameworks
scripts/package_ipa.sh
```

Or pass any other `UTM.app/Frameworks` directory with `--utm DIR` (or `UTM_FRAMEWORKS=DIR`).
The frameworks are copied in by `scripts/embed_gpu3d.sh`, which also puts these into the app when
they exist: `dist/WinKit/drivers.img` (the WinKit disk, see `winkit/`) and
`dist/ArchInstaller/*.z` (the Arch Linux installer, `scripts/build_arch_installer.py`). Patched
frameworks in `work/3d/fw-override/` take precedence over UTM's.

## 4b. Signed build from Xcode (free or paid Apple account)

1. Make your signing settings. They live in a gitignored file, so they never end up in a commit:

   ```sh
   cp ios/Signing.example.xcconfig ios/Signing.local.xcconfig
   ```

   Edit `ios/Signing.local.xcconfig`:
   - `DEVELOPMENT_TEAM`: your 10-character team id (Xcode > Settings > Accounts; a free
     "Personal Team" works).
   - `PRODUCT_BUNDLE_IDENTIFIER`: an id of your own, for example `com.yourname.applevm.duo`.
   - Paid Apple Developer Program members can uncomment
     `CODE_SIGN_ENTITLEMENTS = WindowsiOS-IncreasedMemory.entitlements`, which adds
     `increased-memory-limit` and `extended-virtual-addressing` (more guest RAM, larger address
     space). A free team cannot sign these; keep the default `WindowsiOS.entitlements`
     (`get-task-allow` only).

   The defaults (bundle id `com.applevm.duo`, automatic signing, no team) are in
   `ios/Signing.xcconfig`; your local file overrides them. Do not put signing settings in
   `ios/project.yml`: settings there would override the xcconfig.

2. Generate the project and build, either in Xcode:

   ```sh
   cd ios && xcodegen generate --spec project.yml && open WindowsiOS.xcodeproj
   ```

   then pick your device and press Run; or on the command line (device connected, Developer Mode on):

   ```sh
   cd ios && xcodegen generate --spec project.yml && cd ..
   xcodebuild -project ios/WindowsiOS.xcodeproj -scheme WindowsiOS -configuration Release \
     -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
     -allowProvisioningUpdates build
   ```

   With automatic signing Xcode registers the App ID (with the capabilities in the entitlements
   file) and makes the provisioning profile. Changes to `Signing.local.xcconfig` take effect on the
   next build; rerun `xcodegen` only after changing `project.yml`.

3. Optional 3D frameworks: embed them into the signed app and re-sign it with your certificate
   (`security find-identity -v -p codesigning` lists it; use its SHA-1 if you have several):

   ```sh
   APP=build/DerivedData/Build/Products/Release-iphoneos/WindowsiOS.app
   bash scripts/embed_gpu3d.sh "$APP" work/utm/Payload/UTM.app/Frameworks "Apple Development"
   xcrun devicectl device install app --device <DEVICE_UDID> "$APP"
   ```

Free accounts: the app expires after 7 days and a free team can register only a few App IDs a week.

## 5. JIT on the device

The emulator needs JIT, enabled by a debugger on every launch: with
[StikDebug](https://github.com/StephenDev0/StikDebug) on the device (the app asks it through a
`stikjit://` link, passing its own bundle id and the JIT script), or from
the Mac with `scripts/launch_on_duo.sh <DEVICE_UDID> <your bundle id>` (pass your bundle id: the
script's default is the original WindowsiOS one). Both need `get-task-allow`, which every build
here has.

## 6. Disk images

The app does not contain Windows. Make the Windows 11 ARM64 machine on the Mac as described in
[docs/windows11-vm.md](windows11-vm.md) (Chinese) and import `code.fd`, `vars.fd` and
`windows11.hvsparse` in the app. Arch Linux installs from inside the app when the installer is
embedded (section 4a). You need your own Windows 11 license.

## Continuous integration

`.github/workflows/build.yml` runs on every push and pull request on GitHub's `xcode-27` runner
(macOS 27, Xcode 27): `make all` and `make test-core`, `scripts/build_ios_deps.sh` (cached by the
script's hash), `make ios-lib`, `xcodegen`, then `scripts/package_ipa.sh`. The unsigned IPA (2D
only: CI does not fetch UTM) is uploaded as the run's artifact `AppleVM-Duo-unsigned-<commit>`.

## AltStore / SideStore source

`repo.json` is a source template for AltStore and SideStore. For a release: attach
`AppleVM-Duo-unsigned.ipa` to a GitHub release, then in `repo.json` set the version's `version`,
`buildVersion`, `date`, `localizedDescription`, `downloadURL`, and `size` and `sha256` as printed by
`scripts/package_ipa.sh`. Users add the raw URL of `repo.json` as a source.

## Troubleshooting

- `ios/deps is missing`: run `scripts/build_ios_deps.sh` (step 3).
- `pkg-config` or `slirp` errors in `make all`: `brew install libslirp pkgconf`.
- `Signing for "WindowsiOS" requires a development team`: create `ios/Signing.local.xcconfig`
  (step 4b), or build unsigned with `scripts/package_ipa.sh`.
- `Provisioning profile ... doesn't include the com.apple.developer.kernel.increased-memory-limit
  entitlement`: your team cannot use it (free accounts); go back to `WindowsiOS.entitlements`.
- `Failed to register bundle identifier`: the id is taken by another team; choose another.
