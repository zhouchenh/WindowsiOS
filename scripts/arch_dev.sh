#!/bin/bash
# Arch Linux bring-up on the iPad (development helper):
#   arch_dev.sh boot [extra launch args]    restart the app on Arch with JIT
#   arch_dev.sh sh 'command'                type a command into the serial console, print new log output
#   arch_dev.sh log [n]                     last n lines of the guest log
#   arch_dev.sh shot name.png               screenshot of the guest screen
U=YOUR_IPAD_UDID; B=your.bundle.id; CORE=YOUR_COREDEVICE_ID
D=${ARCH_DEV_DIR:-/tmp/archdev}; mkdir -p "$D"
pull() { rm -f "$D/$2"; xcrun devicectl device copy from --device $U --domain-type appDataContainer --domain-identifier $B --source "$1" --destination "$D/$2" >/dev/null 2>&1; }
push() { xcrun devicectl device copy to --device $U --domain-type appDataContainer --domain-identifier $B --source "$1" --destination "$2" >/dev/null 2>&1; }
case "$1" in
boot)
    shift
    ENVJ=${ARCH_ENV:-'{"MTL_DEBUG_LAYER":"0"}'}
    (xcrun devicectl device process launch --device $U --console --start-stopped --terminate-existing --environment-variables "$ENVJ" -- $B -winios.autoStart YES -winios.machine Arch "$@" > "$D/console.log" 2>&1 &)
    sleep 7; PID=$(xcrun devicectl device info processes --device $U 2>/dev/null | grep WindowsiOS.app/WindowsiOS | awk '{print $1}')
    lldb -b -o 'script lldb.debugger.SetAsync(False)' -o "device select $CORE" -o "device process attach -p $PID" \
        -o "command script import $(dirname "$0")/_lldb_txm_jit.py" -o 'txm_jit_run' > "$D/lldb.log" 2>&1
    tail -1 "$D/lldb.log" | cut -c1-70 ;;
sh)
    pull Documents/winvm.log before.log; n=$(wc -l < "$D/before.log" 2>/dev/null || echo 0)
    printf '%s\r' "$2" > "$D/serial.in"; push "$D/serial.in" Documents/serial.in
    sleep "${3:-8}"; pull Documents/winvm.log after.log; tail -n +$((n + 1)) "$D/after.log" ;;
log)
    pull Documents/winvm.log winvm.log; tail -n "${2:-40}" "$D/winvm.log" ;;
shot)
    echo 1 > "$D/req"; push "$D/req" Documents/screenshot.request; sleep 11; pull Documents/latest_screen.png "$2"; echo "$D/$2" ;;
esac
