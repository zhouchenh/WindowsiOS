#!/bin/bash
U=alarm; ID=$(id -u $U)
run() { runuser -u $U -- env LANG=C.UTF-8 XDG_RUNTIME_DIR=/run/user/$ID DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$ID/bus WAYLAND_DISPLAY=wayland-1 "$@" 2>/dev/null; }
Q="qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects"
{
echo "loaded: $(run $Q.loadedEffects | tr '\n' ' ')"
echo "active: $(run $Q.activeEffects | tr '\n' ' ')"
for e in blur contrast backgroundcontrast wobblywindows magiclamp overview slide zoom windowview fadingpopups scale glide; do
  echo "$e supported=$(run $Q.isEffectSupported $e) loaded=$(run $Q.isEffectLoaded $e)"
done
} > /root/fxcheck.txt
curl -s -T /root/fxcheck.txt http://10.0.2.4/fxcheck.txt
