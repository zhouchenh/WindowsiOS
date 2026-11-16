# Copy to env.sh and fill in. Nothing here is uploaded anywhere.
export TEAM_ID="XXXXXXXXXX"                    # your Apple developer team id (free account works)
export BUNDLE_ID="com.example.windowsios"      # any id unique to you
export SIGN_IDENTITY="Apple Development"       # or the SHA-1 from: security find-identity -v -p codesigning
export DEVICE_UDID=""                          # xcrun devicectl list devices  (the "Identifier" for --device)
export COREDEVICE_ID=""                        # the CoreDevice UUID LLDB uses: xcrun devicectl list devices
export PROFILE=""                              # optional: .mobileprovision from 04_more_ram.sh
export SRC="$PWD/WindowsiOS"                   # where 01_get_sources.sh puts the patched source tree
export DEPS="$PWD/deps3d"                      # where 02_fetch_3d_deps.sh puts UTM's frameworks and the driver
