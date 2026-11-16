#!/bin/bash
# GPU benchmarks inside the Plasma session: glmark2 (OpenGL ES, off-screen) and vkmark (Vulkan).
#   gbench.sh tag     -> /root/gbench-<tag>.txt, also uploaded to the app's shared folder
T=${1:-run}; U=alarm; ID=$(id -u $U)
run() { runuser -u $U -- env LANG=C.UTF-8 XDG_RUNTIME_DIR=/run/user/$ID DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$ID/bus WAYLAND_DISPLAY=wayland-1 "$@"; }
O=/root/gbench-$T.txt
{
echo "== $T $(date)"
echo "== vulkaninfo"; run vulkaninfo --summary 2>&1 | grep -i -E "deviceName|driverName|apiVersion|driverInfo|ERROR" | head -8
echo "== glmark2 GLES (off-screen 1280x720)"
run timeout 600 glmark2-es2-wayland --off-screen -s 1280x720 -b build:use-vbo=true -b texture:texture-filter=linear -b shading:shading=phong -b effect2d:kernel=1,1,1,1,1\;1,1,1,1,1\;1,1,1,1,1 -b refract 2>&1 | grep -E "GL_RENDERER|GL_VERSION|FPS|Score"
echo "== glmark2 with Zink (GL over Vulkan)"
run env MESA_LOADER_DRIVER_OVERRIDE=zink timeout 600 glmark2-es2-wayland --off-screen -s 1280x720 -b build:use-vbo=true -b texture:texture-filter=linear -b shading:shading=phong -b effect2d:kernel=1,1,1,1,1\;1,1,1,1,1\;1,1,1,1,1 -b refract 2>&1 | grep -E "GL_RENDERER|GL_VERSION|FPS|Score|rror"
echo "== vkmark (1280x720)"
run timeout 600 vkmark --winsys headless -s 1280x720 -b vertex -b texture -b shading -b effect2d -b cube 2>&1 | grep -E "Vendor|Device|FPS|Score|rror" | head -12
} > $O 2>&1
curl -s -T $O http://10.0.2.4/gbench-$T.txt
echo done
