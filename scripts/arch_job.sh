#!/bin/bash
# Runs shell commands in the Arch guest through its winios-agent and prints the output.
#   arch_job.sh 'commands' [timeout seconds]
U=YOUR_IPAD_UDID; B=your.bundle.id
D=${ARCH_DEV_DIR:-/tmp/archdev}; mkdir -p "$D"
id=$(uuidgen); printf '%s\n%s\n' "$id" "$1" > "$D/job.txt"; : > "$D/empty"
xcrun devicectl device copy to --device $U --domain-type appDataContainer --domain-identifier $B --source "$D/empty" --destination Documents/Shared/linux_out.txt >/dev/null 2>&1
xcrun devicectl device copy to --device $U --domain-type appDataContainer --domain-identifier $B --source "$D/job.txt" --destination Documents/Shared/linux_job.txt >/dev/null 2>&1
end=$((SECONDS + ${2:-120}))
while [ $SECONDS -lt $end ]; do
    sleep 4
    rm -f "$D/out.txt"
    xcrun devicectl device copy from --device $U --domain-type appDataContainer --domain-identifier $B --source Documents/Shared/linux_out.txt --destination "$D/out.txt" >/dev/null 2>&1
    if [ "$(head -1 "$D/out.txt" 2>/dev/null)" = "$id" ]; then tail -n +2 "$D/out.txt"; exit 0; fi
done
echo "(no answer within ${2:-120}s)"; exit 1
