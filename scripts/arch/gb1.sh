#!/bin/bash
# One GPU benchmark at a time: gb1.sh gl|zink|vk tag -> /root/gb-<tag>-<which>.txt (+ uploaded)
W=$1; T=$2; U=alarm; ID=$(id -u $U)
run() { runuser -u $U -- env LANG=C.UTF-8 XDG_RUNTIME_DIR=/run/user/$ID DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$ID/bus WAYLAND_DISPLAY=wayland-1 "$@"; }
B='-b build:use-vbo=true -b texture:texture-filter=linear -b shading:shading=phong -b refract'
O=/root/gb-$T-$W.txt
case $W in
gl)   run timeout 400 glmark2-es2-wayland --off-screen -s 1280x720 $B 2>&1 | grep -E "GL_RENDERER|GL_VERSION|FPS|Score|rror" > $O ;;
zink) run env MESA_LOADER_DRIVER_OVERRIDE=zink timeout 400 glmark2-es2-wayland --off-screen -s 1280x720 $B 2>&1 | grep -E "GL_RENDERER|GL_VERSION|FPS|Score|rror" > $O ;;
vk)   run timeout 400 vkmark --winsys headless -s 1280x720 -b vertex -b texture -b shading -b cube 2>&1 | grep -E "Vendor|Device|FPS|Score|rror" > $O ;;
esac
echo "exit=$?" >> $O; cat $O
