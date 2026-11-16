#!/bin/bash
U=alarm; ID=$(id -u $U)
run() { runuser -u $U -- env LANG=C.UTF-8 XDG_RUNTIME_DIR=/run/user/$ID DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$ID/bus WAYLAND_DISPLAY=wayland-1 QT_QPA_PLATFORM=wayland "$@"; }
case "$1" in
apps) (run konsole >/dev/null 2>&1 &); (run dolphin >/dev/null 2>&1 &); (run kinfocenter >/dev/null 2>&1 &) ;;
overview) run qdbus6 org.kde.kglobalaccel /component/kwin invokeShortcut Overview ;;
esac
