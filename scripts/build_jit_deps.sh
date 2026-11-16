#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Builds the two dependencies of Built-in JIT (docs/builtin-jit.md) from source into the
# gitignored ios/deps:
#
#   ios/deps/StikJIT.xcframework     StikJIT 1.9.0 (MPL-2.0, StikDebug/StikJIT) with our patches,
#                                    in this order: ios/patches/stikjit-high-address.patch (from
#                                    Henge's ci/stikjit-high-address.patch: 16 hex digits in the $M
#                                    page addresses instead of 9) and
#                                    ios/patches/stikjit-ipv6-address.patch (the device address may
#                                    be IPv6, for Built-in JIT over the user's own VPN). The
#                                    WinJITHelper app extension links it.
#   ios/deps/lib/libhusk_rppairing.a On-device pairing for iOS 27 (Husk's src/rppairing-ios,
#                                    GPL-2.0-or-later, over idevice 0.1.68, MIT). The app links it;
#                                    its C interface is ios/Sources/Native/HuskRPPairing.h.
#
# and refreshes, in ios/Sources/Resources/legal (bundled as the app's legal/ folder),
# LICENSES-rppairing-crates.txt (the licence notices of every crate in libhusk_rppairing.a),
# LICENSES-stikjit-idevice-crates.txt (the same for idevice's FFI inside StikJIT.framework),
# LICENSE-StikJIT-MPL-2.0.txt, a copy of each StikJIT patch and LICENSE-GPL-2.0.txt (Husk's
# licence, the same as Apple VM's). LICENSE-GPL-3.0.txt there is kept by hand (legal/README.txt).
#
#   scripts/build_jit_deps.sh [--force]
#
# All sources are pinned to a commit and checked. Needs Xcode, xcodegen, git, python3 and
# rustup (https://rustup.rs) with any stable toolchain new enough for edition 2024 (1.85+); the
# aarch64-apple-ios target is added when missing. $RUST_TOOLCHAIN picks the toolchain
# (default: stable). Homebrew's own rustc has no iOS standard library, so the toolchain's cargo
# and rustc are used by path (rustup which), whatever comes first in PATH.
#
# Provenance note: StikJIT's repository ships idevice's FFI as a prebuilt static library
# (idevice/libidevice_ffi.a, MIT, built from jkcoxson/idevice); it is linked as shipped. Neither
# the library nor StikJIT's history names the idevice commit it was built from. StikJIT took it in
# 4e08cec (2026-09-23, "feat: migrate DDI mounting to cryptex"); its idevice.h has the FFI of
# idevice e98264c (2026-08-31) or later, and the crate versions compiled into it are those of
# idevice's Cargo.lock from 7305894 (2026-08-24) to d32c818 (2026-09-14, 0.1.68), which lists
# the same third-party crates throughout; the next Cargo.lock change (9c1ad29, 2026-10-19) no
# longer matches. Its notices come from d32c818's Cargo.lock with the features the library was
# built with (idevice-ffi's defaults, aws-lc among them, plus obfuscate), checked against every
# crate the library names (scripts/crate_notices.py --check-binary).
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
# Applied in this order; the framework is rebuilt whenever this list or a patch changes.
STIKJIT_PATCHES=(stikjit-high-address.patch stikjit-ipv6-address.patch)
# The idevice commit whose Cargo.lock gives the crates in StikJIT's libidevice_ffi.a (see above).
IDEVICE_URL="https://github.com/jkcoxson/idevice.git"
IDEVICE_REV="d32c8189c51c2789496b0768039419c3705498c3"
IDEVICE_FEATURES="obfuscate"

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

# ---------------------------------------------------------------- Rust toolchain
TOOL_CARGO=""
TOOL_RUSTC=""
rust_toolchain() {
    [ -n "$TOOL_CARGO" ] && return
    step "rustup: $RUST_TOOLCHAIN with $IOS_TARGET"
    rustup toolchain list > "$WORK/toolchains.txt"
    grep -q "^$RUST_TOOLCHAIN" "$WORK/toolchains.txt" || rustup toolchain install --profile minimal "$RUST_TOOLCHAIN"
    rustup target list --installed --toolchain "$RUST_TOOLCHAIN" > "$WORK/targets.txt"
    grep -qx "$IOS_TARGET" "$WORK/targets.txt" ||
        rustup target add --toolchain "$RUST_TOOLCHAIN" "$IOS_TARGET"
    # The toolchain's own cargo and rustc by path: `rustup run` does not put them first in PATH
    # everywhere, and cargo then picks up a rustc without the iOS standard library.
    TOOL_CARGO="$(rustup which --toolchain "$RUST_TOOLCHAIN" cargo)"
    TOOL_RUSTC="$(rustup which --toolchain "$RUST_TOOLCHAIN" rustc)"
}

# ---------------------------------------------------------------- StikJIT.xcframework
# A fresh clone of StikJIT's tag in $WORK/StikJIT, checked against STIKJIT_REV.
fetch_stikjit() {
    local src="$WORK/StikJIT"
    step "StikJIT $STIKJIT_TAG ($STIKJIT_REV)"
    rm -rf "$src"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$STIKJIT_TAG" "$STIKJIT_URL" "$src"
    [ "$(git -C "$src" rev-parse HEAD)" = "$STIKJIT_REV" ] ||
        die "StikJIT tag $STIKJIT_TAG is $(git -C "$src" rev-parse HEAD), expected $STIKJIT_REV"
}

build_stikjit() {
    local src="$WORK/StikJIT"
    local stamp="$OUT/StikJIT.xcframework/.applevm-build"
    local want="$STIKJIT_REV" patch
    for patch in "${STIKJIT_PATCHES[@]}"; do
        [ -f "$ROOT/ios/patches/$patch" ] || die "ios/patches/$patch is missing"
        want+=" $patch:$(shasum -a 256 "$ROOT/ios/patches/$patch" | cut -d' ' -f1)"
    done
    if [ "$FORCE" = 0 ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
        step "StikJIT.xcframework is up to date ($STIKJIT_TAG + ${STIKJIT_PATCHES[*]})"
        return
    fi
    fetch_stikjit
    for patch in "${STIKJIT_PATCHES[@]}"; do
        step "StikJIT: applying $patch"
        git -C "$src" apply "$ROOT/ios/patches/$patch"
    done
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
    # MPL-2.0: our modifications travel with the app, next to the licence.
    for patch in "${STIKJIT_PATCHES[@]}"; do cp "$ROOT/ios/patches/$patch" "$LEGAL/$patch"; done
    echo "-> ios/deps/StikJIT.xcframework"
}

# ---------------------------------------------------------------- StikJIT's idevice crates
# The licence notices of every crate in StikJIT's prebuilt libidevice_ffi.a (provenance note above).
stikjit_notices() {
    local src="$WORK/idevice"
    local lib="$WORK/StikJIT/idevice/libidevice_ffi.a"
    local notices="$LEGAL/LICENSES-stikjit-idevice-crates.txt"
    local stamp="$OUT/StikJIT.xcframework/.applevm-notices"
    local want="$STIKJIT_REV $IDEVICE_REV $IDEVICE_FEATURES $(shasum -a 256 "$ROOT/scripts/crate_notices.py" | cut -d' ' -f1)"
    if [ "$FORCE" = 0 ] && [ -f "$stamp" ] && [ -f "$notices" ] && [ "$(cat "$stamp")" = "$want" ]; then
        step "StikJIT's idevice crate notices are up to date (idevice $IDEVICE_REV)"
        return
    fi
    if [ ! -f "$lib" ] || [ "$(git -C "$WORK/StikJIT" rev-parse HEAD 2>/dev/null)" != "$STIKJIT_REV" ]; then
        fetch_stikjit
    fi
    step "idevice $IDEVICE_REV: the Cargo.lock of StikJIT's libidevice_ffi.a"
    if [ ! -d "$src/.git" ]; then
        rm -rf "$src"
        git init --quiet "$src"
        git -C "$src" remote add origin "$IDEVICE_URL"
    fi
    git -C "$src" fetch --quiet --depth 1 --filter=blob:none origin "$IDEVICE_REV"
    git -C "$src" -c advice.detachedHead=false checkout --quiet --force "$IDEVICE_REV"
    [ "$(git -C "$src" rev-parse HEAD)" = "$IDEVICE_REV" ] || die "idevice checkout is not $IDEVICE_REV"
    rust_toolchain
    step "crate licence notices for StikJIT's libidevice_ffi.a"
    PATH="$(dirname "$TOOL_CARGO"):$PATH" RUSTC="$TOOL_RUSTC" python3 "$ROOT/scripts/crate_notices.py" \
        --features "$IDEVICE_FEATURES" --check-binary "$lib" "$src/ffi" "$notices" \
        "Third-party notices for idevice's FFI (StikJIT's prebuilt idevice/libidevice_ffi.a, built from
https://github.com/jkcoxson/idevice; crates as in its Cargo.lock at $IDEVICE_REV, features:
default + $IDEVICE_FEATURES), linked into Frameworks/StikJIT.framework/StikJIT."
    echo "$want" > "$stamp"
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

    rust_toolchain
    local cargo="$TOOL_CARGO" rustc="$TOOL_RUSTC"
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
    # GPL-2.0 section 1: the licence goes with the program. Husk's is the same GPL-2.0 text as
    # Apple VM's own LICENSE; ship it once, and say so if that ever changes.
    if cmp -s "$src/LICENSE" "$ROOT/LICENSE"; then
        cp "$src/LICENSE" "$LEGAL/LICENSE-GPL-2.0.txt"
    else
        cp "$ROOT/LICENSE" "$LEGAL/LICENSE-GPL-2.0.txt"
        cp "$src/LICENSE" "$LEGAL/LICENSE-Husk.txt"
        echo "warning: Husk's LICENSE differs from Apple VM's; it is in legal/LICENSE-Husk.txt: list it in legal/README.txt and package_ipa.sh" >&2
    fi
    echo "$want" > "$stamp"
    echo "-> ios/deps/lib/libhusk_rppairing.a"
}

build_stikjit
stikjit_notices
build_rppairing
echo "=== Built-in JIT dependencies staged in $OUT"
ls -lh "$OUT/lib/libhusk_rppairing.a" "$OUT/StikJIT.xcframework/ios-arm64/StikJIT.framework/StikJIT"
