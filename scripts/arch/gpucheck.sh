#!/bin/bash
# What KWin draws with, and which desktop effects it can load. Output: /root/gpucheck.txt
U=alarm; ID=$(id -u $U)
run() { runuser -u $U -- env XDG_RUNTIME_DIR=/run/user/$ID DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$ID/bus WAYLAND_DISPLAY=wayland-1 "$@"; }
{
echo "== eglinfo (Wayland)"; run eglinfo -B -p wayland 2>&1 | grep -i -E "vendor|renderer|version string" | head -6
echo "== kwin support information"; run qdbus6 org.kde.KWin /KWin supportInformation 2>&1 | grep -i -E "^Compositing|OpenGL vendor|OpenGL renderer|OpenGL version|GLSL|Driver:|Direct rendering|Platform|Animation|Qt Graphics" | head -14
for e in blur wobblywindows magiclamp overview kwin4_effect_translucency slide zoom; do
    printf 'load %-24s ' $e; run qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect $e 2>&1
done
echo "== active effects"; run qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.activeEffects 2>&1 | tr '\n' ' '; echo
echo "== loaded effects"; run qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadedEffects 2>&1 | tr '\n' ' '; echo
} > /root/gpucheck.txt 2>&1
curl -s -T /root/gpucheck.txt http://10.0.2.4/gpucheck.txt
