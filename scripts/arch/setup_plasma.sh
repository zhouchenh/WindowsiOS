#!/bin/bash
# Arch Linux ARM on WindowsiOS: updates the system and installs KDE Plasma (Wayland) with Mesa's
# virgl driver, and an automatic login of user alarm into Plasma. Log: /root/setup.log
#   curl -s http://10.0.2.4/setup_plasma.sh | bash
set -x
exec > >(tee -a /root/setup.log) 2>&1
echo "=== start $(date)"
# one consistent mirror set (the geo-redirecting default served a database ahead of its files)
cat > /etc/pacman.d/mirrorlist <<'ML'
Server = http://ca.us.mirror.archlinuxarm.org/$arch/$repo
Server = http://dk.mirror.archlinuxarm.org/$arch/$repo
Server = http://fl.us.mirror.archlinuxarm.org/$arch/$repo
ML
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Syyu --noconfirm
pacman -S --noconfirm --needed \
    plasma-desktop plasma-workspace kwin sddm sddm-kcm konsole dolphin kscreen kinfocenter \
    plasma-pa plasma-nm breeze breeze-gtk xdg-desktop-portal-kde xorg-xwayland \
    mesa mesa-utils vulkan-tools noto-fonts
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf <<'CONF'
[Autologin]
User=alarm
Session=plasma
Relogin=false

[General]
DisplayServer=wayland
CONF
systemctl enable sddm
# The network: NetworkManager instead of the base image's systemd-networkd. Plasma's network icon and
# the desktop programs that ask whether they are online go by NetworkManager, and showed "no network"
# while networkd ran it. Takes over at the next boot (switching now would cut this session's link).
systemctl disable systemd-networkd.socket systemd-networkd
systemctl enable NetworkManager
echo "=== done $(date)"
