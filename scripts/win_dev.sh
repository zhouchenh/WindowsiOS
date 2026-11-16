#!/bin/bash
# Windows on the iPad (development helper), the counterpart of scripts/arch_dev.sh:
#   win_dev.sh boot                restart the app on Windows 11 with JIT
#   win_dev.sh job 'command line'  have the WinKit helper start it (cmd /c ...) in a new console
#   win_dev.sh shot name.png       screenshot of the guest screen
U=YOUR_IPAD_UDID; B=your.bundle.id; CORE=YOUR_COREDEVICE_ID
D=${ARCH_DEV_DIR:-/tmp/archdev}; mkdir -p "$D"
push() { xcrun devicectl device copy to --device $U --domain-type appDataContainer --domain-identifier $B --source "$1" --destination "$2" >/dev/null 2>&1; }
pull() { rm -f "$D/$2"; xcrun devicectl device copy from --device $U --domain-type appDataContainer --domain-identifier $B --source "$1" --destination "$D/$2" >/dev/null 2>&1; }
case "$1" in
boot)
    ENVJ=${WIN_ENV:-'{"MTL_DEBUG_LAYER":"0"}'}
    (xcrun devicectl device process launch --device $U --console --start-stopped --terminate-existing --environment-variables "$ENVJ" -- $B -winios.autoStart YES -winios.machine Win11 > "$D/console.log" 2>&1 &)
    sleep 7; PID=$(xcrun devicectl device info processes --device $U 2>/dev/null | grep WindowsiOS.app/WindowsiOS | awk '{print $1}')
    lldb -b -o 'script lldb.debugger.SetAsync(False)' -o "device select $CORE" -o "device process attach -p $PID" \
        -o "command script import $(dirname "$0")/_lldb_txm_jit.py" -o 'txm_jit_run' > "$D/lldb.log" 2>&1
    tail -1 "$D/lldb.log" | cut -c1-70 ;;
job)
    printf '%s\r\n%s\r\n' "$(uuidgen)" "$2" > "$D/agent_job.txt"; push "$D/agent_job.txt" Documents/Shared/agent_job.txt ;;
shot)
    echo 1 > "$D/req"; push "$D/req" Documents/screenshot.request; sleep 11; pull Documents/latest_screen.png "$2"; echo "$D/$2" ;;
esac
