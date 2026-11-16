#!/usr/bin/env python3
"""Builds the Arch Linux installer the app carries (Arch page > Install), into dist/ArchInstaller/.

  python3 scripts/build_arch_installer.py [--efi installer.efi]

1. Gathers the installer (scripts/arch/installer) and the files it puts into the new system (tunings,
   services, first-boot setup) and has an Arch Linux ARM machine on the iPad (scripts/arch_job.sh, the
   app running Arch with its helper) build installer.efi from them: its own kernel and an initramfs that
   runs the installer, as one EFI program. --efi skips this and uses a ready one.
2. Makes installer.img: a small GPT disk with one FAT partition (label WINIOS-INST) holding it as
   \\EFI\\BOOT\\BOOTAA64.EFI, which the UEFI firmware starts when the system disk is still blank.
3. Writes the app's resources, raw-deflate compressed (NSData's zlib algorithm unpacks them):
   arch-installer.img.z, arch-code.fd.z (the firmware), arch-vars.fd.z (fresh firmware settings).
   scripts/embed_gpu3d.sh copies them into the app.
"""
import argparse, os, shutil, subprocess, sys, tarfile, tempfile, uuid, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_arch_image import write_gpt, ESP_TYPE, MT, MiB, SECTOR, run  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUT = os.path.join(REPO, 'dist', 'ArchInstaller')
DEVICE = 'YOUR_IPAD_UDID'
BUNDLE = 'your.bundle.id'
FIRMWARE = os.path.join(REPO, 'dist', '导入镜像', 'Arch', 'code.fd')
VARS = '/opt/homebrew/share/qemu/edk2-arm-vars.fd'

# What the installer copies into the new system (path in the system -> source, mode)
A = os.path.join(HERE, 'arch')
SYSTEM_FILES = {
    'usr/local/sbin/winios-growroot': (f'{A}/growroot/winios-growroot', 0o755),
    'etc/systemd/system/winios-growroot.service': (f'{A}/growroot/winios-growroot.service', 0o644),
    'usr/local/bin/winios-agent': (f'{A}/agent/winios-agent', 0o755),
    'etc/systemd/system/winios-agent.service': (f'{A}/agent/winios-agent.service', 0o644),
    'usr/local/sbin/winios-firstboot': (f'{A}/firstboot/winios-firstboot', 0o755),
    'etc/systemd/system/winios-firstboot.service': (f'{A}/firstboot/winios-firstboot.service', 0o644),
}
# The emulator tunings (scripts/arch/jit_tune.sh explains them)
SYSTEM_TEXT = {
    'etc/sysctl.d/90-winios-jit.conf': 'kernel.randomize_va_space = 0\n',
    'etc/systemd/system.conf.d/90-winios-stack.conf': '[Manager]\nDefaultLimitSTACK=160M:infinity\n',
    'etc/systemd/user.conf.d/90-winios-stack.conf': '[Manager]\nDefaultLimitSTACK=160M:infinity\n',
    'etc/security/limits.d/90-winios-stack.conf': '*    soft stack 163840\nroot soft stack 163840\n',
}


def stage_sources(tmp):
    src = os.path.join(tmp, 'winios-src')
    os.makedirs(os.path.join(src, 'root'))
    for name in ('install.sh', 'winios_install.hook', 'winios_install.install', 'build_uki.sh'):
        shutil.copy(os.path.join(A, 'installer', name), src)
    for path, (from_, mode) in SYSTEM_FILES.items():
        dst = os.path.join(src, 'root', path)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(from_, dst)
        os.chmod(dst, mode)
    for path, text in SYSTEM_TEXT.items():
        dst = os.path.join(src, 'root', path)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        open(dst, 'w').write(text)
    tar = os.path.join(tmp, 'winios-src.tar')
    with tarfile.open(tar, 'w') as t:
        t.add(src, arcname='winios-src')
    return tar


def devicectl_copy(direction, src, dst):
    args = ['xcrun', 'devicectl', 'device', 'copy', direction, '--device', DEVICE, '--domain-type',
            'appDataContainer', '--domain-identifier', BUNDLE, '--source', src, '--destination', dst]
    subprocess.run(args, capture_output=True, check=True)


def build_efi(tmp):
    tar = stage_sources(tmp)
    devicectl_copy('to', tar, 'Documents/Shared/winios-src.tar')
    job = ('set -e; rm -rf /winios-src; curl -sf http://10.0.2.4/winios-src.tar | tar -x -C /; '
           'bash /winios-src/build_uki.sh 2>&1 | tail -5; curl -sf -T /root/installer.efi http://10.0.2.4/installer.efi; echo uploaded')
    r = subprocess.run([os.path.join(HERE, 'arch_job.sh'), job, '1500'], capture_output=True, text=True,
                       env=dict(os.environ, ARCH_DEV_DIR=os.path.join(tmp, 'dev')))
    print(r.stdout[-2000:])
    if 'uploaded' not in r.stdout:
        sys.exit('building installer.efi in the Arch machine failed')
    efi = os.path.join(tmp, 'installer.efi')
    devicectl_copy('from', 'Documents/Shared/installer.efi', efi)
    return efi


def make_disk(efi, path):
    efi_bytes = os.path.getsize(efi)
    esp_first = MiB
    esp_bytes = (efi_bytes // MiB + 9) * MiB  # the program and some room for FAT itself
    disk_bytes = esp_first + esp_bytes + MiB
    with open(path, 'wb') as f:
        f.truncate(disk_bytes)
        write_gpt(f, disk_bytes, [(ESP_TYPE, uuid.uuid4(), esp_first // SECTOR,
                                   (esp_first + esp_bytes) // SECTOR - 1, 'WindowsiOS installer')])
    off = f'{path}@@{esp_first}'
    run(f'{MT}/mformat', '-i', off, '-F', '-T', str(esp_bytes // SECTOR), '-v', 'WINIOS-INST', '::')
    run(f'{MT}/mmd', '-i', off, '::/EFI', '::/EFI/BOOT')
    run(f'{MT}/mcopy', '-i', off, efi, '::/EFI/BOOT/BOOTAA64.EFI')
    print(run(f'{MT}/mdir', '-i', off, '-/', '::').stdout[-600:])


def deflate(src, dst):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)  # raw DEFLATE: what NSDataCompressionAlgorithmZlib reads
    with open(src, 'rb') as i, open(dst, 'wb') as o:
        while True:
            b = i.read(16 * MiB)
            if not b:
                break
            o.write(c.compress(b))
        o.write(c.flush())
    print(f'{os.path.basename(dst)}: {os.path.getsize(src) >> 20} MB -> {os.path.getsize(dst) / MiB:.1f} MB')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--efi', help='a ready installer.efi (skips building it in the Arch machine)')
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        efi = a.efi or build_efi(tmp)
        shutil.copy(efi, os.path.join(OUT, 'installer.efi'))
        img = os.path.join(tmp, 'installer.img')
        make_disk(efi, img)
        deflate(img, os.path.join(OUT, 'arch-installer.img.z'))
    deflate(FIRMWARE, os.path.join(OUT, 'arch-code.fd.z'))
    deflate(VARS, os.path.join(OUT, 'arch-vars.fd.z'))
    print('done:', OUT)


if __name__ == '__main__':
    main()
