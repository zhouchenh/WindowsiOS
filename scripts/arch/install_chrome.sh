#!/bin/bash
# Google Chrome (Google's own arm64 build, not Chromium) for Arch Linux ARM on WindowsiOS. Run as root.
# Keep provoking_layer/ next to this script.
# Also updates an installed copy: Google's .deb repository does not reach Arch, so run this again for a
# new version. Arch has no package for it: the .deb is unpacked into /opt/google/chrome by hand.
set -euo pipefail
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
pacman -S --needed --noconfirm alsa-lib at-spi2-core cairo libcups curl dbus expat mesa glib2 gtk3 nspr nss \
    pango systemd-libs vulkan-icd-loader libx11 libxcb libxcomposite libxdamage libxext libxfixes libxkbcommon \
    libxrandr wget xdg-utils ttf-liberation ca-certificates
curl -fL -o "$W/chrome.deb" https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb
mkdir "$W/x"
bsdtar -xf "$W/chrome.deb" -C "$W/x"
bsdtar -xf "$W/x/data.tar.xz" -C "$W/x"
rm -rf /opt/google/chrome
mkdir -p /opt/google
cp -a "$W/x/opt/google/chrome" /opt/google/
cp -a "$W/x/usr/share/." /usr/share/
chmod 4755 /opt/google/chrome/chrome-sandbox
for s in 16 24 32 48 64 128 256; do
    f=/opt/google/chrome/product_logo_$s.png
    [ -f "$f" ] && install -Dm644 "$f" /usr/share/icons/hicolor/${s}x${s}/apps/google-chrome.png
done
gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true

# GPU acceleration goes through ANGLE on Vulkan (Venus). ANGLE offers OpenGL ES 3.0, which Chrome needs,
# only with VK_EXT_provoking_vertex, which the iPad's Vulkan lacks: a small implicit layer reports it
# (provoking_layer/, next to this script; enabled by WINIOS_FAKE_PROVOKING_VERTEX=1, which the launcher sets).
L="$(cd "$(dirname "$0")" && pwd)/provoking_layer"
pacman -S --needed --noconfirm gcc vulkan-headers
gcc -shared -fPIC -O2 -o /usr/lib/libVkLayer_winios_provoking.so "$L/provoking_layer.c"
install -Dm644 "$L/VkLayer_winios_provoking.json" /usr/share/vulkan/implicit_layer.d/VkLayer_winios_provoking.json

# Its flags: /etc/chrome-flags.conf, then ~/.config/chrome-flags.conf (one or more per line).
[ -f /etc/chrome-flags.conf ] || cat > /etc/chrome-flags.conf <<'EOF'
# Flags for Google Chrome on WindowsiOS (one or more per line; # starts a comment).
# GPU acceleration: ANGLE on Vulkan (Venus, the iPad GPU). virgl cannot give Chrome the OpenGL ES 3.0 it
# needs, and Chrome has no Vulkan under Wayland, so it runs as an X11 program (XWayland).
# The launcher also turns on VK_LAYER_WINIOS_provoking_vertex, without which ANGLE stops at ES 2.0.
# No GPU at all instead: replace these lines with  --disable-gpu
--ozone-platform=x11
--use-angle=vulkan
--enable-features=Vulkan,VulkanFromANGLE,DefaultANGLEVulkan
--ignore-gpu-blocklist
EOF
rm -f /usr/bin/google-chrome-stable
cat > /usr/bin/google-chrome-stable <<'EOF'
#!/bin/bash
# Google Chrome with the flags in /etc/chrome-flags.conf and ~/.config/chrome-flags.conf.
FLAGS=()
for f in /etc/chrome-flags.conf "${XDG_CONFIG_HOME:-$HOME/.config}/chrome-flags.conf"; do
    [ -r "$f" ] && while read -r line; do line=${line%%#*}; for w in $line; do FLAGS+=("$w"); done; done < "$f"
done
export WINIOS_FAKE_PROVOKING_VERTEX=1
exec /opt/google/chrome/google-chrome "${FLAGS[@]}" "$@"
EOF
chmod 755 /usr/bin/google-chrome-stable
ln -sf google-chrome-stable /usr/bin/google-chrome
/opt/google/chrome/chrome --version
