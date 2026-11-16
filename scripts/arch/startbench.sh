#!/bin/bash
# Process start-up cost of KDE/Qt programs: 20 runs each, total seconds.
U=alarm; ID=$(id -u $U)
r() { runuser -u $U -- env XDG_RUNTIME_DIR=/run/user/$ID QT_QPA_PLATFORM=offscreen "$@" >/dev/null 2>&1; }
for c in "kreadconfig6 --file kdeglobals --group General --key ColorScheme" "dolphin --version" "python3 -c pass" "pacman -Q linux-aarch64"; do
    set -- $c; which $1 >/dev/null 2>&1 || continue
    s=$(date +%s.%N); for i in $(seq 20); do r $c; done; e=$(date +%s.%N)
    awk "BEGIN{printf \"%-14s x20 %.2f s\n\", \"$1\", $e-$s}"
done
