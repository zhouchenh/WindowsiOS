#!/bin/bash
# Run as root in an Arch Linux ARM machine on WindowsiOS: makes /root/installer.efi, the installer as one
# EFI program (kernel, initramfs with the installer, command line). Expects the sources in /winios-src
# (scripts/build_arch_installer.sh puts them there).
set -euo pipefail
pacman -S --needed --noconfirm dosfstools mkinitcpio systemd >/dev/null
install -Dm644 /winios-src/winios_install.hook /etc/initcpio/hooks/winios_install
install -Dm644 /winios-src/winios_install.install /etc/initcpio/install/winios_install
cat > /tmp/winios-mkinitcpio.conf <<'C'
MODULES=(virtio_pci virtio_net nvme ext4 vfat nls_cp437 nls_iso8859-1 nls_utf8)
BINARIES=()
FILES=()
HOOKS=(base winios_install)
COMPRESSION="zstd"
C
echo "console=ttyAMA0,115200 console=tty0 loglevel=4" > /tmp/winios-cmdline
KVER=$(ls /usr/lib/modules | grep -m1 aarch64)
rm -f /root/installer.efi
mkinitcpio -c /tmp/winios-mkinitcpio.conf -k "$KVER" --kernelimage /boot/Image --cmdline /tmp/winios-cmdline -U /root/installer.efi
ls -la /root/installer.efi
