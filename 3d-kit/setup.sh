#!/bin/bash
# WindowsiOS 3D kit: one interactive script. Plug the iPhone/iPad into the Mac, unlock it, run:
#     ./setup.sh
# Later:  ./setup.sh jit      enable JIT from the Mac (if you do not use StikDebug)
#         ./setup.sh 3d on    / 3d off
#         ./setup.sh push     refresh the Windows-side scripts on the device
#         ./setup.sh status   what the app reports
set -uo pipefail
KIT="$(cd "$(dirname "$0")" && pwd)"
CFG="$KIT/.setup.env"
APPID_PREBUILT="org.windowsios.app3d"
say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ok: %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  !  %s\033[0m\n' "$*"; }
die()  { printf '\033[31m  x  %s\033[0m\n' "$*"; exit 1; }
ask()  { local a; read -r -p "  $1 " a; printf '%s' "$a"; }
pause(){ read -r -p "  $1 (press Enter) " _; }

[ -f "$CFG" ] && source "$CFG"
save() { cat > "$CFG" <<EOF
UDID="${UDID:-}"
CDID="${CDID:-}"
MODE="${MODE:-}"
HOSTAPP="${HOSTAPP:-}"
DOCS="${DOCS:-}"
PROC="${PROC:-}"
EOF
}

dc_to()   { xcrun devicectl device copy to   --device "$UDID" --domain-type appDataContainer --domain-identifier "$HOSTAPP" --source "$1" --destination "$2" 2>&1 | grep -q "File Size"; }
dc_from() { xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier "$HOSTAPP" --source "$1" --destination "$2" >/dev/null 2>&1; }
dc_ls()   { xcrun devicectl device info files --device "$UDID" --domain-type appDataContainer --domain-identifier "$HOSTAPP" --subdirectory "$1" 2>/dev/null; }
put_text(){ local t; t=$(mktemp); printf '%s' "$1" > "$t"; dc_to "$t" "$2"; local r=$?; rm -f "$t"; return $r; }

need_tools() {
    command -v xcrun >/dev/null || die "Xcode command line tools are required (xcode-select --install)."
    xcrun devicectl --version >/dev/null 2>&1 || die "This needs Xcode 15 or newer (devicectl)."
    command -v python3 >/dev/null || die "python3 is required."
}

pick_device() {
    say "1. Device"
    local j; j=$(mktemp)
    xcrun devicectl list devices --json-output "$j" >/dev/null 2>&1
    local list; list=$(python3 - "$j" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for x in d.get("result", {}).get("devices", []):
    hp, dp, cp = x.get("hardwareProperties", {}), x.get("deviceProperties", {}), x.get("connectionProperties", {})
    if hp.get("platform") not in ("iOS", "iPadOS"): continue
    if cp.get("tunnelState") == "unavailable": continue
    print("|".join([hp.get("udid", ""), x.get("identifier", ""), dp.get("name", "?"), hp.get("marketingName", "?"), dp.get("osVersionNumber", "?")]))
PY
)
    rm -f "$j"
    [ -n "$list" ] || die "No iPhone/iPad found. Plug it in, unlock it, tap Trust, and make sure Developer Mode is on."
    local n=0; while IFS='|' read -r u c name model os; do n=$((n+1)); echo "   $n) $name  ($model, iOS $os)"; done <<< "$list"
    local pick=1; [ "$n" -gt 1 ] && pick=$(ask "Which device? [1-$n]")
    IFS='|' read -r UDID CDID DNAME DMODEL DOS <<< "$(sed -n "${pick:-1}p" <<< "$list")"
    [ -n "$UDID" ] || die "No device chosen."
    ok "$DNAME ($DMODEL)"
}

find_lc_container() {   # the data folder LiveContainer gave our app
    dc_ls "Documents/Data/Application" | awk '{print $1}' | grep -E "Library/Preferences/$APPID_PREBUILT\.plist$" | head -1 | cut -d/ -f1
}

install_livecontainer() {
    HOSTAPP=$(xcrun devicectl device info apps --device "$UDID" 2>/dev/null | awk 'tolower($0) ~ /livecontainer/ {print $2; exit}')
    [ -n "$HOSTAPP" ] || die "LiveContainer is not installed on this device."
    PROC="LiveContainer.app/LiveContainer"
    local ipa; ipa=$(ls "$KIT"/../WindowsiOS-3D-unsigned.ipa "$KIT"/WindowsiOS-3D-unsigned.ipa "$KIT"/ipa/*.ipa 2>/dev/null | head -1)
    [ -n "$ipa" ] || die "Put WindowsiOS-3D-unsigned.ipa next to this script (or in ipa/)."
    local t; t=$(mktemp -d); unzip -q -o "$ipa" -d "$t"
    echo "  copying the app into LiveContainer..."
    dc_to "$t/Payload/WindowsiOS.app" "Documents/Applications/$APPID_PREBUILT.app" || die "Could not copy into LiveContainer."
    rm -rf "$t"
    ok "app is in LiveContainer"
    echo
    echo "  On the device: open LiveContainer, start \"Windows 11\" once (it will say files are missing), then come back."
    pause "Done that?"
    local id=""; for _ in 1 2 3 4 5 6; do id=$(find_lc_container); [ -n "$id" ] && break; sleep 3; done
    [ -n "$id" ] || die "LiveContainer has not created the app's data folder yet. Start \"Windows 11\" in LiveContainer once and run this script again."
    DOCS="Documents/Data/Application/$id/Documents"
    ok "app data folder found"
}

install_xcode() {
    command -v xcodegen >/dev/null || die "xcodegen is required for building (brew install xcodegen)."
    local ident team bid
    ident=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
    [ -n "$ident" ] || die "No 'Apple Development' signing identity. Sign in to Xcode > Settings > Accounts with your Apple ID once."
    team=$(security find-certificate -c "$ident" -p | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')
    bid=$(ask "Bundle ID to use [com.$(whoami | tr -cd 'a-z0-9').windowsios]:"); bid=${bid:-com.$(whoami | tr -cd 'a-z0-9').windowsios}
    cat > "$KIT/scripts/env.sh" <<EOF
export TEAM_ID="$team"
export BUNDLE_ID="$bid"
export SIGN_IDENTITY="$ident"
export DEVICE_UDID="$UDID"
export COREDEVICE_ID="$CDID"
export PROFILE="${PROFILE:-}"
export SRC="$KIT/WindowsiOS"
export DEPS="$KIT/deps3d"
EOF
    ( cd "$KIT/scripts" && ./01_get_sources.sh && ./02_fetch_3d_deps.sh && ./03_build.sh ) || die "Build failed (see the output above)."
    xcrun devicectl device install app --device "$UDID" "$KIT/WindowsiOS/build/DerivedData-kit/Build/Products/Release-iphoneos/WindowsiOS.app" | tail -1
    HOSTAPP="$bid"; DOCS="Documents"; PROC="WindowsiOS.app/WindowsiOS"
    ok "installed as $bid"
    warn "8 GB guest RAM with 3D needs the Increased Memory Limit capability: scripts/04_more_ram.sh (optional)."
}

push_machine() {
    say "3. Windows files"
    if dc_ls "$DOCS/Machines/Win11" | grep -qE "windows11\.(img|hvsparse)"; then
        ok "the device already has a Windows disk"
        [ "$(ask 'Replace it? This erases the Windows on the device. (y/N)')" = "y" ] || return 0
    fi
    echo "  Needed, made as the original project's README describes: code.fd, vars.fd, windows11.hvsparse, drivers.img"
    local dir; dir=$(ask "Folder that holds them (drag it here):"); dir=${dir%/}; dir=${dir//\\ / }
    for f in code.fd vars.fd; do [ -f "$dir/$f" ] || die "$f not found in $dir"; done
    [ -f "$dir/windows11.hvsparse" ] || die "windows11.hvsparse not found in $dir"
    for f in code.fd vars.fd drivers.img; do
        [ -f "$dir/$f" ] && { dc_to "$dir/$f" "$DOCS/Machines/Win11/$f" && ok "$f" || die "copying $f failed"; }
    done
    echo "  copying windows11.hvsparse ($(du -h "$dir/windows11.hvsparse" | cut -f1)); this takes several minutes, keep the device unlocked..."
    dc_to "$dir/windows11.hvsparse" "$DOCS/Machines/Win11/windows11.hvsparse" && ok "Windows image" || die "copying the Windows image failed"
}

push_guest() {
    say "4. Windows-side scripts and 3D driver"
    local drv="$KIT/deps3d/viogpu3d/x/drivers/viogpu3d"
    if [ ! -d "$drv" ]; then
        mkdir -p "$KIT/deps3d/viogpu3d"
        echo "  downloading the viogpu3d driver (v0.5) from its release page..."
        curl -fL -o "$KIT/deps3d/viogpu3d/drv.zip" https://github.com/osy/kvm-guest-drivers-windows/releases/download/v0.5/viogpu3d-arm64x-signed.zip || die "download failed"
        unzip -q -o "$KIT/deps3d/viogpu3d/drv.zip" -d "$KIT/deps3d/viogpu3d/x"
    fi
    local n=0
    for f in "$KIT"/guest/*.ps1; do dc_to "$f" "$DOCS/Shared/$(basename "$f")" && n=$((n+1)); done
    for f in "$drv"/*; do dc_to "$f" "$DOCS/Shared/viogpu3d/$(basename "$f")" && n=$((n+1)); done
    ok "$n files in the app's shared folder (Windows sees it at http://10.0.2.4/)"
}

set_3d() {
    put_text "$1" "$DOCS/gpu3d.on" && ok "host 3D: $1 (takes effect the next time the app starts)" || die "could not write the 3D switch"
}

jit_help() {
    say "JIT"
    cat <<'EOF'
  Windows only runs once JIT is enabled for the app. Two ways:

  A) StikDebug, on the device, no Mac needed (recommended):
       1. Install StikDebug and set it up once (its pairing file / VPN profile, as its own guide describes).
       2. Turn StikDebug's VPN on.
       3. LiveContainer users: in LiveContainer's settings choose StikDebug as the JIT enabler and switch
          "Launch with JIT" on for Windows 11; starting the app then enables JIT by itself.
          Installed directly: open StikDebug, tap "Enable JIT", pick Windows 11.

  B) From this Mac over USB:   ./setup.sh jit
       Start the app on the device first, keep it in front and unlocked. Takes 2-3 minutes with no
       output while it prepares the 768 MiB code cache. That is normal, do not interrupt it.
EOF
}

jit_mac() {
    [ -n "${UDID:-}" ] || die "Run ./setup.sh first."
    local py="$KIT/WindowsiOS/scripts"
    if [ ! -f "$py/_lldb_txm_jit.py" ]; then
        mkdir -p "$py"
        curl -fsSL -o "$py/_lldb_txm_jit.py" https://raw.githubusercontent.com/ammaarreshi/WindowsiOS/0071d69/scripts/_lldb_txm_jit.py || die "could not fetch the LLDB script"
    fi
    local pid; pid=$(xcrun devicectl device info processes --device "$UDID" 2>/dev/null | awk -v p="$PROC" 'index($0, p) {print $1; exit}')
    [ -n "$pid" ] || die "The app is not running. Start it on the device, keep it in front, then run this again."
    dc_from "$DOCS/boot_status.txt" /tmp/.wios_status 2>/dev/null
    if grep -q "jit_live: true" /tmp/.wios_status 2>/dev/null; then ok "JIT is already on (StikDebug or an earlier run)."; return 0; fi
    echo "  enabling JIT for pid $pid: 2-3 minutes, no output meanwhile..."
    PYTHONPATH="$py" xcrun lldb -b -o "script lldb.debugger.SetAsync(False)" -o "device select $CDID" \
        -o "device process attach -p $pid" -o "command script import $py/_lldb_txm_jit.py" -o "txm_jit_run" 2>&1 | grep -E "txm-jit\] (SUCCESS|Blessed)|error" | tail -3
}

status() {
    [ -n "${UDID:-}" ] || die "Run ./setup.sh first."
    dc_from "$DOCS/boot_status.txt" /tmp/.wios_status || die "No status yet: start the app on the device."
    grep -E "vm_status|jit_status|uptime_sec|ram_mb|fb_size|gpu:" /tmp/.wios_status | cut -c1-200
}

windows_steps() {
    say "5. In Windows (after it reaches the desktop)"
    cat <<'EOF'
  a) Network driver, once: File Explorer > the DRIVERS disk > right-click install_netkvm.cmd > Run as administrator.
  b) Right-click Start > Terminal, then type:

         irm http://10.0.2.4/setup.ps1 | iex

     First run installs the 3D driver. Then close the app completely on the device, start it again
     (JIT again), and run the SAME command a second time: it fits the screen and offers a clean-up.
  c) Check: dxdiag > Display should show "Red Hat VirtIO GPU 3D controller", Feature Levels 11_0.

  If the screen ever stays black:  ./setup.sh 3d off   then restart the app. Windows falls back to its
  basic display. Never disable "Microsoft Basic Display Driver" in Windows: it is that fallback.
EOF
}

wizard() {
    need_tools
    pick_device
    say "2. How is the app installed?"
    echo "   1) Into LiveContainer (already on the device). No Xcode build, no 7-day re-signing."
    echo "   2) Build and install with my own Apple ID (needs Xcode; free accounts re-sign every 7 days)."
    MODE=$(ask "Choose [1/2]:"); MODE=${MODE:-1}
    if [ "$MODE" = "2" ]; then install_xcode; else MODE=1; install_livecontainer; fi
    save
    push_machine
    push_guest
    say "3D switch"
    set_3d on
    local cpu; cpu=$(ask "CPU name to show in Windows [Enter = Apple Silicon]:")
    [ -n "$cpu" ] && put_text "$cpu" "$DOCS/cpu_name.txt" && ok "CPU name: $cpu"
    jit_help
    windows_steps
    say "Ready"
    echo "  Start \"Windows 11\" on the device now. First start unpacks the disk (a few minutes)."
    echo "  Settings saved in $CFG"
}

case "${1:-}" in
    "")      wizard ;;
    jit)     jit_mac ;;
    push)    [ -n "${UDID:-}" ] || die "Run ./setup.sh first."; push_guest ;;
    3d)      [ -n "${UDID:-}" ] || die "Run ./setup.sh first."; case "${2:-}" in on|off) set_3d "$2" ;; *) die "usage: ./setup.sh 3d on|off" ;; esac ;;
    status)  status ;;
    help|-h|--help) sed -n 2,8p "$0"; jit_help ;;
    *)       die "unknown command: $1  (try ./setup.sh help)" ;;
esac
