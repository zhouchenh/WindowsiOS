#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds the iOS app (Release, unsigned) and packs it as dist/AppleVM-Duo-unsigned.ipa.
#
#   scripts/package_ipa.sh [--utm DIR] [--no-3d] [--entitlements FILE] [--bundle-id ID] [--tipa] [--out DIR]
#
#   --utm DIR           Frameworks directory of UTM's iOS app (UTM.app/Frameworks, see docs/building.md).
#                       Default: $UTM_FRAMEWORKS, else work/utm/Payload/UTM.app/Frameworks, else
#                       3d-kit/scripts/deps3d/utm/x/Payload/UTM.app/Frameworks. When none is found the
#                       app is packed without the 3D frameworks (2D graphics only) and a warning is printed.
#   --no-3d             Do not embed the 3D frameworks even if they are found.
#   --entitlements F    Entitlements carried in the IPA's ad-hoc signature
#                       (default ios/WindowsiOS.entitlements: get-task-allow).
#   --bundle-id ID      Bundle identifier of the IPA (default com.applevm.duo, the one in repo.json).
#                       ios/Signing.local.xcconfig does not change it: a release IPA always has the
#                       repository's bundle id unless this option is given. The Built-in JIT helper
#                       (PlugIns/WinJITHelper.appex) gets ID.JITHelper.
#   --tipa              Also write dist/AppleVM-Duo-unsigned.tipa (same archive, other extension).
#   --out DIR           Output directory (default dist/).
#
# With or without 3D, the app also gets the WinKit disk (dist/WinKit/drivers.img, or $WINKIT_IMG,
# as winkit.img; `make winkit-img` builds it) and the Arch Linux installer (dist/ArchInstaller/*.z,
# scripts/build_arch_installer.py) when they exist; the summary says which were embedded.
#
# Needs ios/deps (scripts/build_ios_deps.sh and scripts/build_jit_deps.sh), Xcode and xcodegen.
# "Unsigned" means no developer certificate: the app is ad-hoc signed with its entitlements so that
# re-signing tools (SideStore, AltStore, Sideloadly, LiveContainer, ...) see get-task-allow and keep
# it. The JIT helper extension and Frameworks/StikJIT.framework are ad-hoc signed first, without
# entitlements; a re-signing tool must keep app extensions for Built-in JIT (docs/builtin-jit.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

UTM_DIR="${UTM_FRAMEWORKS:-}"
EMBED_3D=1
ENTITLEMENTS="$ROOT/ios/WindowsiOS.entitlements"
BUNDLE_ID="com.applevm.duo"
TIPA=0
OUT_DIR="$ROOT/dist"
NAME="AppleVM-Duo-unsigned"

usage() { awk 'NR>=4 && !/^#/ {exit} NR>=4 {sub(/^# ?/, ""); print}' "$0"; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --utm) UTM_DIR="${2:?--utm needs a directory}"; shift 2 ;;
        --no-3d) EMBED_3D=0; shift ;;
        --entitlements) ENTITLEMENTS="${2:?--entitlements needs a file}"; shift 2 ;;
        --bundle-id) BUNDLE_ID="${2:?--bundle-id needs an identifier}"; shift 2 ;;
        --tipa) TIPA=1; shift ;;
        --out) OUT_DIR="${2:?--out needs a directory}"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::$*"; return 0; }

case "$ENTITLEMENTS" in /*) ;; *) ENTITLEMENTS="$PWD/$ENTITLEMENTS" ;; esac
[ -f "$ENTITLEMENTS" ] || die "no entitlements file at $ENTITLEMENTS"
plutil -lint -s "$ENTITLEMENTS" || die "$ENTITLEMENTS is not a valid plist"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

[ -f ios/deps/lib/libslirp.a ] && [ -f ios/deps/lib/libglib-2.0.a ] ||
    die "ios/deps is missing: run scripts/build_ios_deps.sh first"
[ -d ios/deps/StikJIT.xcframework ] && [ -f ios/deps/lib/libhusk_rppairing.a ] ||
    die "ios/deps lacks Built-in JIT's StikJIT.xcframework or libhusk_rppairing.a: run scripts/build_jit_deps.sh first"
command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"

WORK="$ROOT/build/package"
DD="$ROOT/build/DerivedData-package"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "== engine library (make ios-lib)"
make -j"$(sysctl -n hw.ncpu)" ios-lib > "$WORK/make.log" 2>&1 || { tail -40 "$WORK/make.log"; die "make ios-lib failed"; }

echo "== Xcode project (xcodegen)"
(cd ios && xcodegen generate --spec project.yml --quiet)

echo "== Release build, unsigned ($(xcodebuild -version | sed -n 1p))"
if ! xcodebuild -project ios/WindowsiOS.xcodeproj -scheme WindowsiOS -configuration Release \
        -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
        APPLEVM_RELEASE_BUNDLE_ID="$BUNDLE_ID" \
        build > "$WORK/xcodebuild.log" 2>&1; then
    grep -E "error:|BUILD FAILED" "$WORK/xcodebuild.log" | sort -u | tail -40
    die "xcodebuild failed (full log: $WORK/xcodebuild.log)"
fi
grep -E "^/.*warning:" "$WORK/xcodebuild.log" | sort -u || true

BUILT="$DD/Build/Products/Release-iphoneos/WindowsiOS.app"
[ -d "$BUILT" ] || die "the build produced no app at $BUILT"

STAGE="$WORK/stage"
APP="$STAGE/Payload/WindowsiOS.app"
mkdir -p "$STAGE/Payload"
ditto --norsrc --noextattr "$BUILT" "$APP"

# The WinKit disk and the Arch installer, whether or not the 3D frameworks are embedded
# (scripts/embed_gpu3d.sh copies the same files again when it runs).
WK="${WINKIT_IMG:-$ROOT/dist/WinKit/drivers.img}"
WINKIT=0
if [ -f "$WK" ]; then cp "$WK" "$APP/winkit.img"; WINKIT=1; fi
ARCH_FILES="arch-installer.img.z arch-code.fd.z arch-vars.fd.z"
ARCH_IN=""
for f in $ARCH_FILES; do
    if [ -f "$ROOT/dist/ArchInstaller/$f" ]; then cp "$ROOT/dist/ArchInstaller/$f" "$APP/$f"; ARCH_IN="$ARCH_IN $f"; fi
done
ARCH_IN="${ARCH_IN# }"
[ -z "$ARCH_IN" ] || [ "$ARCH_IN" = "$ARCH_FILES" ] ||
    warn "dist/ArchInstaller is incomplete (has only: $ARCH_IN): the app cannot install Arch Linux by itself"

# Built-in JIT: the StikJIT framework and the helper extension that links it, ad-hoc signed inside
# out before the app (an unsigned build leaves them unsigned). No entitlements: the helper is the
# debugger, not the app being debugged.
JIT_FW="$APP/Frameworks/StikJIT.framework"
JIT_APPEX="$APP/PlugIns/WinJITHelper.appex"
[ -d "$JIT_FW" ] || die "the build has no Frameworks/StikJIT.framework (Embed StikJIT build phase)"
[ -d "$JIT_APPEX" ] || die "the build has no PlugIns/WinJITHelper.appex"
codesign --force --sign - --timestamp=none "$JIT_FW"
codesign --force --sign - --timestamp=none --generate-entitlement-der "$JIT_APPEX"

# Ad-hoc signature carrying the entitlements; scripts/embed_gpu3d.sh reads them back from it.
codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" --generate-entitlement-der "$APP"

# 3D graphics: UTM's frameworks, put in (and the app re-signed ad hoc) by scripts/embed_gpu3d.sh.
GPU3D=0
NEEDED_FW="virglrenderer.1 epoxy.0 vulkan.1 EGL GLESv2 dxmt-native vulkan_kosmickrisp MoltenVK zstd.1"
if [ "$EMBED_3D" = 1 ]; then
    if [ -z "$UTM_DIR" ]; then
        for c in "$ROOT/work/utm/Payload/UTM.app/Frameworks" \
                 "$ROOT/3d-kit/scripts/deps3d/utm/x/Payload/UTM.app/Frameworks"; do
            [ -d "$c" ] && { UTM_DIR="$c"; break; }
        done
    fi
    missing=""
    if [ -n "$UTM_DIR" ] && [ -d "$UTM_DIR" ]; then
        for f in $NEEDED_FW; do [ -d "$UTM_DIR/$f.framework" ] || missing="$missing $f.framework"; done
        [ -d "$UTM_DIR/../vulkan" ] || missing="$missing ../vulkan"
        if [ -z "$missing" ]; then
            echo "== embedding the 3D frameworks from $UTM_DIR"
            bash "$ROOT/scripts/embed_gpu3d.sh" "$APP" "$UTM_DIR" -
            GPU3D=1
        else
            warn "$UTM_DIR lacks:$missing; packing without 3D (2D graphics only)"
        fi
    else
        warn "UTM frameworks not found (pass --utm DIR or set UTM_FRAMEWORKS); packing without 3D (2D graphics only)"
    fi
fi

echo "== archive"
IPA="$OUT_DIR/$NAME.ipa"
rm -f "$IPA"
(cd "$STAGE" && COPYFILE_DISABLE=1 zip -qry -X "$IPA" Payload)

echo "== checking the IPA"
CHECK="$WORK/check"
mkdir -p "$CHECK"
fail() { echo "IPA check failed: $*" >&2; exit 1; }
unzip -Z1 "$IPA" > "$WORK/ipa-list.txt"
BAD="$(grep -v '^Payload/' "$WORK/ipa-list.txt" || true)"
[ -z "$BAD" ] || fail "entries outside Payload/: $(echo "$BAD" | head -3 | tr '\n' ' ')"
if grep -qE '(^|/)(\._|__MACOSX|\.DS_Store)' "$WORK/ipa-list.txt"; then fail "macOS metadata files in the archive"; fi
[ "$(awk -F/ 'NF>2 && $2 ~ /\.app$/ {print $2}' "$WORK/ipa-list.txt" | sort -u)" = "WindowsiOS.app" ] ||
    fail "Payload/ must hold exactly one app, WindowsiOS.app"
unzip -q "$IPA" -d "$CHECK"
X="$CHECK/Payload/WindowsiOS.app"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$X/Info.plist" 2>/dev/null; }
EXE="$(plist CFBundleExecutable)" || fail "Info.plist has no CFBundleExecutable"
[ -f "$X/$EXE" ] && [ -x "$X/$EXE" ] || fail "executable $EXE missing or not executable"
lipo -archs "$X/$EXE" | grep -qw arm64 || fail "$EXE is not arm64"
BID="$(plist CFBundleIdentifier)" || fail "Info.plist has no CFBundleIdentifier"
[ "$BID" = "$BUNDLE_ID" ] || fail "bundle id is $BID, expected $BUNDLE_ID"
MINOS="$(plist MinimumOSVersion)" || fail "Info.plist has no MinimumOSVersion"
VER="$(plist CFBundleShortVersionString || echo '?') ($(plist CFBundleVersion || echo '?'))"
[ -f "$X/henge-jit.js" ] || fail "henge-jit.js (JIT script) missing"
# Built-in JIT: the helper, its framework and the licences that travel with them.
XA="$X/PlugIns/WinJITHelper.appex"
XF="$X/Frameworks/StikJIT.framework"
[ -d "$XA" ] || fail "PlugIns/WinJITHelper.appex (Built-in JIT helper) missing"
[ -f "$XF/StikJIT" ] && [ -f "$XF/Info.plist" ] || fail "Frameworks/StikJIT.framework (binary and Info.plist) missing"
HBID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$XA/Info.plist" 2>/dev/null)" ||
    fail "WinJITHelper.appex has no CFBundleIdentifier"
[ "$HBID" = "$BUNDLE_ID.JITHelper" ] || fail "JIT helper bundle id is $HBID, expected $BUNDLE_ID.JITHelper"
[ "$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPrincipalClass" "$XA/Info.plist" 2>/dev/null)" = WinJITHelperHandler ] ||
    fail "WinJITHelper.appex has no NSExtensionPrincipalClass WinJITHelperHandler"
otool -L "$XA/WinJITHelper" > "$WORK/helper-libs.txt"
grep -q "@rpath/StikJIT.framework/StikJIT" "$WORK/helper-libs.txt" ||
    fail "WinJITHelper does not link @rpath/StikJIT.framework"
for f in LICENSE-GPL-2.0.txt LICENSE-GPL-3.0.txt LICENSE-StikJIT-MPL-2.0.txt LICENSE-idevice-MIT.txt \
         LICENSES-stikjit-idevice-crates.txt LICENSES-rppairing-crates.txt stikjit-high-address.patch; do
    [ -f "$X/legal/$f" ] || fail "legal/$f missing"
done
codesign --verify --deep --strict "$X" || fail "the ad-hoc signature does not verify"
codesign -d --entitlements - --xml "$X" 2>/dev/null | grep -q "get-task-allow" || fail "get-task-allow missing from the signature"
if [ "$GPU3D" = 1 ]; then
    for f in $NEEDED_FW; do [ -d "$X/Frameworks/$f.framework" ] || fail "Frameworks/$f.framework missing"; done
    [ -d "$X/vulkan" ] || fail "vulkan/ (driver manifests) missing"
fi
if [ "$WINKIT" = 1 ]; then cmp -s "$WK" "$X/winkit.img" || fail "winkit.img missing or not $WK"; fi
for f in $ARCH_IN; do cmp -s "$ROOT/dist/ArchInstaller/$f" "$X/$f" || fail "$f missing or differs from dist/ArchInstaller"; done

if [ "$TIPA" = 1 ]; then cp "$IPA" "$OUT_DIR/$NAME.tipa"; fi

echo
echo "IPA:          $IPA ($(du -h "$IPA" | cut -f1 | tr -d ' '))"
if [ "$TIPA" = 1 ]; then echo "TIPA:         $OUT_DIR/$NAME.tipa"; fi
echo "size:         $(stat -f %z "$IPA") bytes"
echo "sha256:       $(shasum -a 256 "$IPA" | cut -d' ' -f1)"
echo "bundle id:    $BID, version $VER, iOS $MINOS+"
echo "entitlements: $(basename "$ENTITLEMENTS") (ad-hoc signed)"
echo "Built-in JIT: PlugIns/WinJITHelper.appex ($HBID) + Frameworks/StikJIT.framework"
if [ "$GPU3D" = 1 ]; then echo "3D:           embedded"; else echo "3D:           not embedded (2D graphics only)"; fi
if [ "$WINKIT" = 1 ]; then echo "WinKit disk:  embedded ($WK)"
else echo "WinKit disk:  not embedded (no $WK; make winkit-img builds it)"; fi
if [ "$ARCH_IN" = "$ARCH_FILES" ]; then echo "Arch Linux:   installer embedded"
elif [ -n "$ARCH_IN" ]; then echo "Arch Linux:   incomplete installer embedded ($ARCH_IN): cannot install"
else echo "Arch Linux:   installer not embedded (scripts/build_arch_installer.py builds it)"; fi
rm -rf "$CHECK"
