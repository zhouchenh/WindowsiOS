#!/bin/bash
# Copies the 3D graphics frameworks (virglrenderer with Neptune, DXMT, ANGLE EGL/GLESv2, libepoxy,
# the Vulkan loader) taken from UTM's iOS build into a built WindowsiOS.app and re-signs it.
#   scripts/embed_gpu3d.sh <WindowsiOS.app> <UTM.app/Frameworks dir> [signing identity] [provisioning profile]
# With a profile (e.g. one carrying increased-memory-limit, made by work/getmoreram/gmrcli), it is
# embedded and every entitlement it grants that the build lacks is added.
set -euo pipefail
APP="$1"
SRC="$2"
IDENT="${3:-Apple Development}"
PROFILE="${4:-}"
FW="$APP/Frameworks"
mkdir -p "$FW"
for f in virglrenderer.1 epoxy.0 vulkan.1 EGL GLESv2 dxmt-native vulkan_kosmickrisp MoltenVK zstd.1; do
    rm -rf "$FW/$f.framework"
    # A patched copy in work/3d/fw-override wins (see scripts/patch_kosmickrisp.py).
    OV="$(cd "$(dirname "$0")/.." && pwd)/work/3d/fw-override/$f.framework"
    if [ -d "$OV" ]; then cp -R "$OV" "$FW/"; echo "using patched $f"; else cp -R "$SRC/$f.framework" "$FW/"; fi
    # DXMT: a Metal buffer that could not be made is skipped instead of written through (patch_dxmt.py).
    if [ "$f" = dxmt-native ]; then python3 -I "$(dirname "$0")/patch_dxmt.py" "$FW/$f.framework/$f"; fi
    rm -rf "$FW/$f.framework/_CodeSignature"
    codesign --force --sign "$IDENT" --timestamp=none "$FW/$f.framework"
done
# Vulkan driver manifests for the loader (Venus: Linux guests' Vulkan runs on the host's Vulkan).
# Their library paths are relative to the manifest: ../../Frameworks/<driver>.framework/<driver>.
rm -rf "$APP/vulkan"; cp -R "$SRC/../vulkan" "$APP/vulkan"
# The WinKit disk (drivers and setup scripts for Windows) travels inside the app as winkit.img, so
# an imported machine needs no separate drivers.img. Taken from dist/WinKit, or $WINKIT_IMG.
# `make winkit-img` builds dist/WinKit/drivers.img (winkit/ plus WinIOSBrowser.exe, the OAuth bridge).
WK="${WINKIT_IMG:-$(cd "$(dirname "$0")/.." && pwd)/dist/WinKit/drivers.img}"
if [ -f "$WK" ]; then
    rm -f "$APP/winkit.img"
    cp "$WK" "$APP/winkit.img"
    echo "WinKit disk embedded: $WK"
else
    echo "no WinKit disk at $WK: the app is built without one (make winkit-img makes it)"
fi
# The Arch Linux installer (scripts/build_arch_installer.py): the installer disk and the firmware, packed.
AI="$(cd "$(dirname "$0")/.." && pwd)/dist/ArchInstaller"
for f in arch-installer.img.z arch-code.fd.z arch-vars.fd.z; do
    if [ -f "$AI/$f" ]; then cp "$AI/$f" "$APP/$f"; else echo "no $AI/$f: the app cannot install Arch Linux by itself"; fi
done
# Re-sign the app with the entitlements it was built with.
ENT=$(mktemp -t winios-ent).plist
codesign -d --entitlements :- "$APP" > "$ENT" 2>/dev/null
if [ -n "$PROFILE" ]; then
    cp "$PROFILE" "$APP/embedded.mobileprovision"
    PL=$(mktemp -t winios-prof).plist
    security cms -D -i "$PROFILE" > "$PL"
    for k in com.apple.developer.kernel.increased-memory-limit com.apple.developer.kernel.extended-virtual-addressing; do
        if /usr/libexec/PlistBuddy -c "Print :Entitlements:$k" "$PL" >/dev/null 2>&1; then
            /usr/libexec/PlistBuddy -c "Add :$k bool true" "$ENT" 2>/dev/null || true
            echo "entitlement added: $k"
        fi
    done
    rm -f "$PL"
fi
codesign --force --sign "$IDENT" --timestamp=none --entitlements "$ENT" --generate-entitlement-der "$APP"
rm -f "$ENT"
codesign --verify --deep --strict "$APP" && echo "embedded and signed: $APP"
