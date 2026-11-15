#!/bin/bash
# Builds the iOS app, embeds the 3D frameworks and signs it. Needs Xcode, xcodegen (brew install xcodegen)
# and the iOS dependencies the upstream project builds with scripts/build_ios_deps.sh.
set -euo pipefail
cd "$(dirname "$0")"; source ./env.sh
cd "$SRC"
[ -d ios/deps/lib ] || bash scripts/build_ios_deps.sh
make ios-lib
[ -d ios/WindowsiOS.xcodeproj ] || (cd ios && xcodegen generate)
xcodebuild -project ios/WindowsiOS.xcodeproj -scheme WindowsiOS -configuration Release \
    -destination "id=$DEVICE_UDID" -derivedDataPath build/DerivedData-kit -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" "CODE_SIGN_IDENTITY=Apple Development" \
    PROVISIONING_PROFILE_SPECIFIER= PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build | tail -3
APP=build/DerivedData-kit/Build/Products/Release-iphoneos/WindowsiOS.app
scripts/embed_gpu3d.sh "$APP" "$DEPS/utm/x/Payload/UTM.app/Frameworks" "$SIGN_IDENTITY" ${PROFILE:+"$PROFILE"}
echo "built: $SRC/$APP"
