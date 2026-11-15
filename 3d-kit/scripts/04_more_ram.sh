#!/bin/bash
# Optional, free developer accounts: adds the "Increased Memory Limit" capability to your App ID (the way
# GetMoreRam does) and downloads a provisioning profile that carries it. Needed for 8 GB guest RAM plus 3D.
# You type your Apple ID, password and 2FA code yourself; they are not stored. Device identity ("anisette")
# data comes from SideStore's server. The profile lasts 7 days on a free account: rerun this, then 03 and 05.
# Build the app once (03_build.sh) before this so the App ID exists.
set -euo pipefail
cd "$(dirname "$0")"; source ./env.sh
KIT="$(cd .. && pwd)"
cd "$KIT/tools/gmrcli"
if [ ! -f Sources/gmrcli/AnisetteDataHelper.swift ]; then
    # GetMoreRam's anisette helper is fetched from its own repository rather than copied here.
    curl -fsSL -o Sources/gmrcli/AnisetteDataHelper.swift \
        https://raw.githubusercontent.com/hugeBlack/GetMoreRam/main/GetMoreRam/AnisetteDataHelper.swift
fi
swift build -c release
OUT="$KIT/more_ram.mobileprovision"
./.build/release/gmrcli "$BUNDLE_ID" "$OUT"
echo "now set PROFILE=\"$OUT\" in env.sh and rerun 03_build.sh"
