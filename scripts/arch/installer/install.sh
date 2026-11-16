#!/bin/sh
# WindowsiOS Arch Linux installer, stage 1. Runs inside the installer's initramfs (busybox sh), started
# by the winios_install hook instead of mounting a root file system. Installs Arch Linux ARM onto the
# machine's empty system disk from the official tarball, then powers off; the app takes the installer
# disk away and starts the machine again, and the installed system's first boot (winios-firstboot)
# installs the KDE Plasma desktop and the GPU drivers.
#
# Progress goes to the screen and to the app: http://10.0.2.4/arch_install_status.txt (the app's shared
# folder), one line "<percent> <message>". Failures start with "error".

TARBALL_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
SHARE=http://10.0.2.4
T=/mnt

status() {
    echo "[winios] $*"
    echo "$*" > /tmp/status
    curl -s -m 5 -T /tmp/status $SHARE/arch_install_status.txt >/dev/null 2>&1
}

fail() {
    status "error $*"
    echo "[winios] installation stopped. The machine stays on so the screen can be read."
    while true; do sleep 3600; done
}

# ---- network: the app's user-mode network is always 10.0.2.0/24
ip link set lo up
NIC=
for n in /sys/class/net/*; do
    n=${n##*/}
    [ "$n" = lo ] && continue
    NIC=$n
    break
done
[ -n "$NIC" ] || fail "no network adapter"
ip link set "$NIC" up
ip addr add 10.0.2.15/24 dev "$NIC"
ip route add default via 10.0.2.2
echo "nameserver 10.0.2.3" > /etc/resolv.conf
echo "127.0.0.1 localhost" > /etc/hosts
sleep 1
status "1 starting"

# ---- the target: the NVMe disk that is not this installer (the installer's partition is labelled WINIOS-INST)
INST=$(blkid -L WINIOS-INST 2>/dev/null)
DISK=
for d in /sys/block/nvme*n*; do
    d=/dev/${d##*/}
    case "$INST" in "$d"p*) continue ;; esac
    DISK=$d
    break
done
[ -n "$DISK" ] || fail "no system disk"
SECTORS=$(cat /sys/block/${DISK#/dev/}/size)
[ "$SECTORS" -gt $((8 * 1024 * 1024 * 2)) ] || fail "the system disk is smaller than 8 GB"
# never overwrite something: the disk must still be blank
if [ "$(dd if="$DISK" bs=1M count=1 2>/dev/null | tr -d '\000' | wc -c)" -ne 0 ]; then
    fail "the system disk is not empty"
fi

# ---- partitions: ESP (512 MiB, /boot) and root (the rest)
status "3 partitioning"
printf 'label: gpt\nsize=512MiB, type=uefi, name="EFI system"\ntype=B921B045-1DF0-41C3-AF44-4C6F280D3FAE, name="Arch Linux ARM"\n' |
    sfdisk -q "$DISK" || fail "partitioning"
sleep 1
ESP=${DISK}p1
ROOT=${DISK}p2
mkfs.fat -F 32 -n ESP "$ESP" >/dev/null || fail "formatting the EFI partition"
mkfs.ext4 -q -F -L archroot "$ROOT" || fail "formatting the root partition"
mkdir -p $T
mount -t ext4 "$ROOT" $T || fail "mounting root"
mkdir -p $T/boot
mount -t vfat "$ESP" $T/boot || fail "mounting the EFI partition"

# ---- the official root file system
status "5 downloading Arch Linux ARM"
curl -sfL -m 30 -o /tmp/tar.md5 "$TARBALL_URL.md5" || fail "cannot reach os.archlinuxarm.org"
TOTAL=$(curl -sfIL "$TARBALL_URL" | sed -n 's/^[Cc]ontent-[Ll]ength: *\([0-9]*\).*/\1/p' | tail -1)
curl -sfL -o $T/rootfs.tar.gz "$TARBALL_URL" &
PID=$!
while kill -0 $PID 2>/dev/null; do
    sleep 5
    HAVE=$(stat -c %s $T/rootfs.tar.gz 2>/dev/null || echo 0)
    if [ -n "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
        status "$((5 + HAVE * 45 / TOTAL)) downloading Arch Linux ARM ($((HAVE >> 20)) of $((TOTAL >> 20)) MB)"
    fi
done
wait $PID || fail "download"
WANT=$(cut -d' ' -f1 /tmp/tar.md5)
GOT=$(md5sum $T/rootfs.tar.gz | cut -d' ' -f1)
[ "$WANT" = "$GOT" ] || fail "the download is damaged (md5 $GOT, expected $WANT)"
status "52 unpacking"
bsdtar -xpf $T/rootfs.tar.gz -C $T 2>/tmp/bsdtar.err || {
    # FAT (/boot) cannot hold owners or links: only fatal when something outside /boot failed
    grep -v '^bsdtar: \./boot/\|Can.t restore time\|Can.t set permissions\|Error exit delayed' /tmp/bsdtar.err | grep -q . &&
        fail "unpacking: $(head -c 300 /tmp/bsdtar.err)"
}
rm -f $T/rootfs.tar.gz
rm -rf $T/boot/dtbs # device trees: unused, ACPI describes the board

# ---- boot loader (systemd-boot) and its entry
status "70 setting up"
ROOT_UUID=$(blkid -s PARTUUID -o value "$ROOT")
ESP_UUID=$(blkid -s PARTUUID -o value "$ESP")
mkdir -p $T/boot/EFI/BOOT $T/boot/loader/entries
cp $T/usr/lib/systemd/boot/efi/systemd-bootaa64.efi $T/boot/EFI/BOOT/BOOTAA64.EFI || fail "no systemd-boot"
printf 'default arch.conf\ntimeout 0\nconsole-mode keep\n' > $T/boot/loader/loader.conf
printf 'title   Arch Linux ARM\nlinux   /Image\ninitrd  /initramfs-linux.img\noptions root=PARTUUID=%s rw rootwait console=ttyAMA0,115200 console=tty0 loglevel=4 systemd.show_status=1\n' \
    "$ROOT_UUID" > $T/boot/loader/entries/arch.conf
[ -f $T/boot/Image ] && [ -f $T/boot/initramfs-linux.img ] || fail "kernel missing from the download"

# ---- the system's settings (the same as scripts/build_arch_image.py writes)
printf '# <device>  <dir>  <type>  <options>  <dump> <pass>\nPARTUUID=%s  /boot  vfat  defaults,nofail,x-systemd.device-timeout=15s  0 2\n' \
    "$ESP_UUID" > $T/etc/fstab
echo archios > $T/etc/hostname
mkdir -p $T/etc/systemd/system/getty@tty1.service.d
printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty -o %s --noclear --autologin root %%I $TERM\n' "'-p -f -- \\\\u'" \
    > $T/etc/systemd/system/getty@tty1.service.d/autologin.conf
cat > $T/etc/pacman.d/mirrorlist <<'EOF'
# one consistent mirror set (the geo-redirecting default can serve a database ahead of its files)
Server = http://ca.us.mirror.archlinuxarm.org/$arch/$repo
Server = http://dk.mirror.archlinuxarm.org/$arch/$repo
Server = http://fl.us.mirror.archlinuxarm.org/$arch/$repo
EOF
cp -a /winios/root/. $T/ # the WindowsiOS files: tunings, services, first-boot setup
mkdir -p $T/etc/systemd/system/multi-user.target.wants
for s in winios-growroot winios-agent winios-firstboot; do
    ln -sf /etc/systemd/system/$s.service $T/etc/systemd/system/multi-user.target.wants/$s.service
done
printf '\nArch Linux ARM on WindowsiOS\n  Users: root/root, alarm/alarm.\n  /boot is the EFI partition (kernel and boot loader).\n\n' > $T/etc/motd

sync
umount $T/boot
umount $T
status "75 base system installed: restarting into it"
sleep 2
poweroff -f
