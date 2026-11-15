#!/bin/bash
# Downloads the 3D pieces from their own release pages (nothing is bundled in this kit):
#   UTM.ipa v5.0.8  -> virglrenderer (Neptune), DXMT, ANGLE (EGL/GLESv2), libepoxy, Vulkan loader for iOS
#   viogpu3d v0.5   -> the Windows ARM64 3D driver (Microsoft attestation signed)
set -euo pipefail
cd "$(dirname "$0")"; source ./env.sh
mkdir -p "$DEPS/utm" "$DEPS/viogpu3d"
cd "$DEPS"
[ -f utm/UTM.ipa ] || curl -L -o utm/UTM.ipa https://github.com/utmapp/UTM/releases/download/v5.0.8/UTM.ipa
[ -d utm/x ] || unzip -q -o utm/UTM.ipa -d utm/x
[ -f viogpu3d/drv.zip ] || curl -L -o viogpu3d/drv.zip https://github.com/osy/kvm-guest-drivers-windows/releases/download/v0.5/viogpu3d-arm64x-signed.zip
[ -d viogpu3d/x ] || unzip -q -o viogpu3d/drv.zip -d viogpu3d/x
ls utm/x/Payload/UTM.app/Frameworks | grep -E "virglrenderer|dxmt|EGL|GLESv2|epoxy|vulkan.1"
ls viogpu3d/x/drivers/viogpu3d
