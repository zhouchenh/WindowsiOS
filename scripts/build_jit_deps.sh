#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds the two dependencies of Built-in JIT (docs/builtin-jit.md) from source into the
# gitignored ios/deps:
#
#   ios/deps/StikJIT.xcframework     StikJIT 1.9.0 (MPL-2.0, StikDebug/StikJIT) with our patch
#                                    ios/patches/stikjit-high-address.patch (from Henge's
#                                    ci/stikjit-high-address.patch: 16 hex digits in the $M page
#                                    addresses instead of 9). The WinJITHelper app extension links it.
#   ios/deps/lib/libhusk_rppairing.a On-device pairing for iOS 27 (Husk's src/rppairing-ios,
#                                    GPL-2.0-or-later, over idevice 0.1.68, MIT). The app links it;
#                                    its C interface is ios/Sources/Native/HuskRPPairing.h.
#
# and refreshes, in ios/Sources/Resources/legal (bundled as the app's legal/ folder),
# LICENSES-rppairing-crates.txt (the licence notices of every crate in libhusk_rppairing.a),
# LICENSE-StikJIT-MPL-2.0.txt and a copy of the StikJIT patch.
#
#   scripts/build_jit_deps.sh [--force]
#
# Both sources are pinned to a commit and checked. Needs Xcode, xcodegen, git, python3 and
# rustup (https://rustup.rs) with any stable toolchain new enough for edition 2024 (1.85+); the
# aarch64-apple-ios target is added when missing. $RUST_TOOLCHAIN picks the toolchain
# (default: stable). Homebrew's own rustc has no iOS standard library, so the toolchain's cargo
# and rustc are used by path (rustup which), whatever comes first in PATH.
#
# Provenance note: StikJIT's repository ships idevice's FFI as a prebuilt static library
# (idevice/libidevice_ffi.a, MIT, built from jkcoxson/idevice); it is linked as shipped.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/work/jit_deps"
OUT="$ROOT/ios/deps"
LEGAL="$ROOT/ios/Sources/Resources/legal"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

STIKJIT_URL="https://github.com/StikDebug/StikJIT.git"
STIKJIT_TAG="1.9.0"
STIKJIT_REV="32287268fa5824f9edce4cb359f5833ce0cf7b00"
STIKJIT_PATCH="$ROOT/ios/patches/stikjit-high-address.patch"

HUSK_URL="https://github.com/Leviidev/Husk.git"
HUSK_REV="29abb512d81bf8cc08babcbe7f7007cb557208ef"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"
IOS_TARGET="aarch64-apple-ios"

# scripts/build_ios_deps.sh runs this with its iOS cross-compile environment exported; cargo's
# build scripts and xcodebuild must not see it.
unset CC CXX OBJCC AR NM RANLIB STRIP CFLAGS CXXFLAGS CPPFLAGS OBJCFLAGS LDFLAGS \
      PKG_CONFIG PKG_CONFIG_LIBDIR SDKROOT

die() { echo "error: $*" >&2; exit 1; }
step() { echo "== $*"; }

for tool in git xcodebuild xcodegen python3; do
    command -v "$tool" >/dev/null || die "$tool not found"
done
command -v rustup >/dev/null || die "rustup not found (https://rustup.rs, or brew install rustup)"
mkdir -p "$WORK" "$OUT/lib" "$LEGAL"

# ---------------------------------------------------------------- StikJIT.xcframework
build_stikjit() {
    local src="$WORK/StikJIT"
    local stamp="$OUT/StikJIT.xcframework/.applevm-build"
    local want="$STIKJIT_REV $(shasum -a 256 "$STIKJIT_PATCH" | cut -d' ' -f1)"
    if [ "$FORCE" = 0 ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
        step "StikJIT.xcframework is up to date ($STIKJIT_TAG + patch)"
        return
    fi
    step "StikJIT $STIKJIT_TAG ($STIKJIT_REV)"
    rm -rf "$src"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$STIKJIT_TAG" "$STIKJIT_URL" "$src"
    [ "$(git -C "$src" rev-parse HEAD)" = "$STIKJIT_REV" ] ||
        die "StikJIT tag $STIKJIT_TAG is $(git -C "$src" rev-parse HEAD), expected $STIKJIT_REV"
    git -C "$src" apply "$STIKJIT_PATCH"
    step "StikJIT: xcodegen and archive (Release, iphoneos, unsigned)"
    (cd "$src" && xcodegen generate --quiet)
    xcodebuild archive -project "$src/StikJIT.xcodeproj" -scheme StikJIT -configuration Release \
        -sdk iphoneos -destination 'generic/platform=iOS' -archivePath "$src/build/StikJIT" \
        -derivedDataPath "$src/build/dd" \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO -quiet > "$WORK/stikjit.log" 2>&1 ||
        { tail -40 "$WORK/stikjit.log"; die "StikJIT archive failed (log: $WORK/stikjit.log)"; }
    rm -rf "$OUT/StikJIT.xcframework"
    xcodebuild -create-xcframework \
        -framework "$src/build/StikJIT.xcarchive/Products/Library/Frameworks/StikJIT.framework" \
        -output "$OUT/StikJIT.xcframework" > /dev/null
    echo "$want" > "$stamp"
    cp "$src/LICENSE" "$LEGAL/LICENSE-StikJIT-MPL-2.0.txt"
    # MPL-2.0: our modification travels with the app, next to the licence.
    cp "$STIKJIT_PATCH" "$LEGAL/stikjit-high-address.patch"
    echo "-> ios/deps/StikJIT.xcframework"
}

# ---------------------------------------------------------------- libhusk_rppairing.a
build_rppairing() {
    local src="$WORK/Husk"
    local crate="$src/src/rppairing-ios"
    local stamp="$OUT/lib/.libhusk_rppairing.applevm-build"
    local want="$HUSK_REV $RUST_TOOLCHAIN"
    if [ "$FORCE" = 0 ] && [ -f "$stamp" ] && [ -f "$OUT/lib/libhusk_rppairing.a" ] &&
       [ "$(cat "$stamp")" = "$want" ]; then
        step "libhusk_rppairing.a is up to date (Husk $HUSK_REV)"
        return
    fi
    step "Husk $HUSK_REV: src/rppairing-ios only (sparse, no blobs outside it)"
    if [ ! -d "$src/.git" ]; then
        rm -rf "$src"
        git init --quiet "$src"
        git -C "$src" remote add origin "$HUSK_URL"
    fi
    git -C "$src" config core.sparseCheckout true
    git -C "$src" sparse-checkout set --no-cone /src/rppairing-ios/ /src/app/Husk/HuskRPPairing.h /LICENSE
    git -C "$src" fetch --quiet --depth 1 --filter=blob:none origin "$HUSK_REV"
    git -C "$src" checkout --quiet --force "$HUSK_REV"
    [ "$(git -C "$src" rev-parse HEAD)" = "$HUSK_REV" ] || die "Husk checkout is not $HUSK_REV"

    # The C interface we compile against must be the one this commit builds.
    cmp -s "$src/src/app/Husk/HuskRPPairing.h" "$ROOT/ios/Sources/Native/HuskRPPairing.h" ||
        die "ios/Sources/Native/HuskRPPairing.h differs from Husk $HUSK_REV's src/app/Husk/HuskRPPairing.h"

    step "rustup: $RUST_TOOLCHAIN with $IOS_TARGET"
    rustup toolchain list > "$WORK/toolchains.txt"
    grep -q "^$RUST_TOOLCHAIN" "$WORK/toolchains.txt" || rustup toolchain install --profile minimal "$RUST_TOOLCHAIN"
    rustup target list --installed --toolchain "$RUST_TOOLCHAIN" > "$WORK/targets.txt"
    grep -qx "$IOS_TARGET" "$WORK/targets.txt" ||
        rustup target add --toolchain "$RUST_TOOLCHAIN" "$IOS_TARGET"
    # The toolchain's own cargo and rustc by path: `rustup run` does not put them first in PATH
    # everywhere, and cargo then picks up a rustc without the iOS standard library.
    local cargo rustc
    cargo="$(rustup which --toolchain "$RUST_TOOLCHAIN" cargo)"
    rustc="$(rustup which --toolchain "$RUST_TOOLCHAIN" rustc)"
    step "cargo build --release --locked --target $IOS_TARGET ($("$rustc" --version))"
    # The app's deployment target, or the linker warns on every object.
    (cd "$crate" && IPHONEOS_DEPLOYMENT_TARGET=17.0 RUSTC="$rustc" \
        "$cargo" build --release --locked --target "$IOS_TARGET") \
        > "$WORK/rppairing.log" 2>&1 ||
        { tail -40 "$WORK/rppairing.log"; die "cargo build failed (log: $WORK/rppairing.log)"; }
    cp "$crate/target/$IOS_TARGET/release/libhusk_rppairing.a" "$OUT/lib/libhusk_rppairing.a"
    nm -g "$OUT/lib/libhusk_rppairing.a" > "$WORK/rppairing.nm" 2>/dev/null || true
    grep -q " T _husk_rppairing_accept$" "$WORK/rppairing.nm" ||
        die "libhusk_rppairing.a does not export husk_rppairing_accept"
    step "crate licence notices"
    (cd "$crate" && PATH="$(dirname "$cargo"):$PATH" RUSTC="$rustc" \
        python3 "$crate/notices.py" "$LEGAL/LICENSES-rppairing-crates.txt")
    echo "$want" > "$stamp"
    echo "-> ios/deps/lib/libhusk_rppairing.a"
}

build_stikjit
build_rppairing
echo "=== Built-in JIT dependencies staged in $OUT"
ls -lh "$OUT/lib/libhusk_rppairing.a" "$OUT/StikJIT.xcframework/ios-arm64/StikJIT.framework/StikJIT"
