#!/usr/bin/env python3
"""Builds a bootable Arch Linux ARM disk for WindowsiOS from the official rootfs tarball.

  python3 scripts/build_arch_image.py ArchLinuxARM-aarch64-latest.tar.gz OUTDIR [--size-gib 10]

The machine boots it the way it boots Windows: EDK2 UEFI -> systemd-boot -> the Arch kernel, with
ACPI describing the board. The disk:
  GPT  1: ESP, FAT32, 512 MiB, mounted at /boot: systemd-boot, kernel Image, initramfs, loader entries
       2: root, ext4, the rest
Root logs in by itself on the screen (tty1); the kernel and boot messages also go to the serial
port, which the app writes to Documents/winvm.log.

Needs Homebrew's e2fsprogs (mke2fs, debugfs) and mtools (mformat, mcopy). The ext4 file system is
filled through debugfs from the tarball itself, so Linux owners, modes, symlinks, hard links and
file capabilities survive although macOS file systems cannot hold them.
Writes OUTDIR/disk.img (raw), then packs it to OUTDIR/windows11.hvsparse for the app's importer.
"""
import argparse, os, shutil, struct, subprocess, sys, tarfile, uuid, zlib

E2 = '/opt/homebrew/opt/e2fsprogs/sbin'
MT = '/opt/homebrew/bin'
MiB = 1 << 20
SECTOR = 512

ESP_TYPE = uuid.UUID('C12A7328-F81F-11D2-BA4B-00A0C93EC93B')
LINUX_ROOT_ARM64 = uuid.UUID('B921B045-1DF0-41C3-AF44-4C6F280D3FAE')


def run(*a, **kw):
    r = subprocess.run(a, capture_output=True, text=True, **kw)
    if r.returncode:
        sys.exit(f'{a[0]} failed ({r.returncode}):\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}')
    return r


def write_gpt(f, disk_bytes, parts):
    """parts: [(type uuid, part uuid, first lba, last lba, name)]"""
    nsec = disk_bytes // SECTOR
    entries = bytearray(128 * 128)
    for i, (t, u, first, last, name) in enumerate(parts):
        struct.pack_into('<16s16sQQQ72s', entries, i * 128, t.bytes_le, u.bytes_le, first, last, 0,
                         name.encode('utf-16le'))
    ecrc = zlib.crc32(entries)
    disk_guid = uuid.uuid4()

    def header(cur, backup, entries_lba):
        h = bytearray(92)
        struct.pack_into('<8sIIIIQQQQ16sQIII', h, 0, b'EFI PART', 0x00010000, 92, 0, 0, cur, backup,
                         34, nsec - 34, disk_guid.bytes_le, entries_lba, 128, 128, ecrc)
        struct.pack_into('<I', h, 16, zlib.crc32(h))
        return bytes(h) + bytes(SECTOR - 92)

    mbr = bytearray(SECTOR)  # protective MBR
    mbr[446:462] = struct.pack('<BBBBBBBBII', 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1, min(nsec - 1, 0xFFFFFFFF))
    mbr[510:512] = b'\x55\xaa'
    f.seek(0); f.write(mbr)
    f.write(header(1, nsec - 1, 2)); f.write(entries)
    f.seek((nsec - 33) * SECTOR); f.write(entries)
    f.write(header(nsec - 1, 1, nsec - 33))


def q(p):
    if '"' in p or '\n' in p:
        raise ValueError(p)
    return '"' + p + '"'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('tarball'); ap.add_argument('out')
    ap.add_argument('--size-gib', type=int, default=10)
    ap.add_argument('--hostname', default='archios')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    stage = os.path.join(a.out, 'stage'); shutil.rmtree(stage, ignore_errors=True)
    files_dir = os.path.join(stage, 'files'); esp_dir = os.path.join(stage, 'esp')
    os.makedirs(files_dir); os.makedirs(os.path.join(esp_dir, 'EFI', 'BOOT')); os.makedirs(os.path.join(esp_dir, 'loader', 'entries'))

    disk_bytes = a.size_gib << 30
    esp_first, esp_bytes = MiB, 512 * MiB
    root_first = esp_first + esp_bytes
    root_bytes = disk_bytes - root_first - MiB  # room for the backup GPT
    esp_uuid, root_uuid, fs_uuid = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()

    cmdline = (f'root=PARTUUID={root_uuid} rw rootwait console=ttyAMA0,115200 console=tty0 '
               f'loglevel=4 systemd.show_status=1')
    here = os.path.dirname(os.path.abspath(__file__))  # scripts/
    overlays = {
        './etc/hostname': f'{a.hostname}\n',
        './etc/fstab': ('# <device>  <dir>  <type>  <options>  <dump> <pass>\n'
                        f'PARTUUID={esp_uuid}  /boot  vfat  defaults,nofail,x-systemd.device-timeout=15s  0 2\n'),
        './etc/systemd/system/getty@tty1.service.d/autologin.conf':
            '[Service]\nExecStart=\nExecStart=-/sbin/agetty -o \'-p -f -- \\\\u\' --noclear --autologin root %I $TERM\n',
        './etc/motd': ('\nArch Linux ARM on WindowsiOS\n'
                       '  root logs in by itself on this screen. Users: root/root, alarm/alarm.\n'
                       '  Before the first pacman -Syu:  pacman-key --init && pacman-key --populate archlinuxarm\n'
                       '  /boot is the EFI partition (kernel and boot loader).\n\n'),
        # Suit the emulator's translator (see scripts/arch/jit_tune.sh): no address randomization, so
        # libraries keep their addresses from process to process and their translated code is reused,
        # and a 160 MB stack limit, which keeps stack and library pages apart in its 64 MB software TLB.
        './etc/sysctl.d/90-winios-jit.conf': 'kernel.randomize_va_space = 0\n',
        './etc/systemd/system.conf.d/90-winios-stack.conf': '[Manager]\nDefaultLimitSTACK=160M:infinity\n',
        './etc/systemd/user.conf.d/90-winios-stack.conf': '[Manager]\nDefaultLimitSTACK=160M:infinity\n',
        './etc/security/limits.d/90-winios-stack.conf': '*    soft stack 163840\nroot soft stack 163840\n',
        # Grows the root partition and file system at boot when the app made the disk bigger.
        './usr/local/sbin/winios-growroot': open(os.path.join(here, 'arch', 'growroot', 'winios-growroot')).read(),
        './etc/systemd/system/winios-growroot.service':
            open(os.path.join(here, 'arch', 'growroot', 'winios-growroot.service')).read(),
    }
    executables = {'./usr/local/sbin/winios-growroot'}
    extra_symlinks = {'./etc/systemd/system/multi-user.target.wants/winios-growroot.service':
             '/etc/systemd/system/winios-growroot.service'}
    created_dirs = {'./etc/systemd/system/getty@tty1.service.d', './etc/systemd/system.conf.d',
                    './etc/systemd/user.conf.d', './etc/sysctl.d', './etc/security/limits.d',
                    './usr/local/sbin', './etc/systemd/system/multi-user.target.wants'}

    cmds = []
    dir_bytes = {}  # directory -> bytes its entries need (debugfs's ln and symlink do not grow a full directory)
    dir_at = {}     # directory -> index in cmds just after its mkdir

    def entry(path):
        parent = os.path.dirname(path) or '/'
        dir_bytes[parent] = dir_bytes.get(parent, 24) + 8 + (len(os.path.basename(path)) + 3) // 4 * 4
    links = {}      # hard link target -> extra names
    seen = set()
    n_files = 0

    def meta(path, m, mode_type):
        cmds.append(f'sif {q(path)} mode 0{mode_type | (m.mode & 0o7777):o}')
        cmds.append(f'sif {q(path)} uid {m.uid}')
        cmds.append(f'sif {q(path)} gid {m.gid}')

    print('reading', a.tarball, flush=True)
    t = tarfile.open(a.tarball, 'r:gz')
    for m in t:
        name = m.name if m.name.startswith('./') else './' + m.name.lstrip('/')
        name = name.rstrip('/') or '.'
        path = '/' if name == '.' else name[1:]
        if name.startswith('./boot/') and name.count('/') > 2:  # device trees: unused (ACPI describes the board)
            continue
        if name.startswith('./boot/') and m.isfile():      # the kernel and initramfs go to the ESP
            with open(os.path.join(esp_dir, os.path.basename(name)), 'wb') as o:
                shutil.copyfileobj(t.extractfile(m), o)
            continue
        if name.startswith('./boot/') and m.isdir():
            continue
        if path != '/': entry(path)
        if m.isdir():
            if path != '/': cmds.append(f'mkdir {q(path)}')
            meta(path, m, 0o040000)
            dir_at[path] = len(cmds)
        elif m.issym():
            cmds.append(f'symlink {q(path)} {q(m.linkname)}')
            cmds.append(f'sif {q(path)} uid {m.uid}'); cmds.append(f'sif {q(path)} gid {m.gid}')
        elif m.islnk():
            target = '/' + (m.linkname[2:] if m.linkname.startswith('./') else m.linkname.lstrip('/'))
            cmds.append(f'ln {q(target)} {q(path)}')
            links[target] = links.get(target, 1) + 1
        elif m.isfile():
            data = overlays.pop(name, None)
            src = os.path.join(files_dir, f'{n_files // 2000}', f'{n_files}')
            os.makedirs(os.path.dirname(src), exist_ok=True)
            with open(src, 'wb') as o:
                if data is not None: o.write(data.encode())
                else: shutil.copyfileobj(t.extractfile(m), o)
            n_files += 1
            if name == './usr/lib/systemd/boot/efi/systemd-bootaa64.efi':  # also the ESP's boot loader
                shutil.copy(src, os.path.join(esp_dir, 'EFI', 'BOOT', 'BOOTAA64.EFI'))
            cmds.append(f'write {q(src)} {q(path)}')
            meta(path, m, 0o100000)
            for k, v in m.pax_headers.items():
                if k.startswith('SCHILY.xattr.'):
                    xf = src + '.xattr'
                    with open(xf, 'wb') as o: o.write(v.encode('utf-8', 'surrogateescape'))
                    cmds.append(f'ea_set -f {q(xf)} {q(path)} {k[len("SCHILY.xattr."):]}')
        else:
            print('skipped (type %r):' % m.type, name)
        seen.add(name)
    for target, count in links.items():
        cmds.append(f'sif {q(target)} links_count {count}')
    # files the tarball did not have
    for name, data in overlays.items():
        d = os.path.dirname(name)
        if d in created_dirs:
            parts = d[2:].split('/')
            for i in range(1, len(parts) + 1):
                sub = './' + '/'.join(parts[:i])
                if sub not in seen:
                    cmds.append(f'mkdir {q(sub[1:])}'); cmds.append(f'sif {q(sub[1:])} mode 040755'); seen.add(sub)
        src = os.path.join(files_dir, f'extra{len(cmds)}')
        with open(src, 'w') as o: o.write(data)
        cmds.append(f'write {q(src)} {q(name[1:])}')
        mode = '0100755' if name in executables else '0100644'
        cmds.append(f'sif {q(name[1:])} mode {mode}'); cmds.append(f'sif {q(name[1:])} uid 0'); cmds.append(f'sif {q(name[1:])} gid 0')
    for name, target in extra_symlinks.items():
        d = os.path.dirname(name)
        if d not in seen:
            cmds.append(f'mkdir {q(d[1:])}'); cmds.append(f'sif {q(d[1:])} mode 040755'); seen.add(d)
        cmds.append(f'symlink {q(name[1:])} {q(target)}')
    # grow every directory up front to hold all its entries
    grow = {}
    for d, nbytes in dir_bytes.items():
        extra = -(-nbytes // 3800) - 1
        if extra > 0 and d in dir_at: grow.setdefault(dir_at[d], []).extend([f'expand_dir {q(d)}'] * extra)
    out = []
    for i, c in enumerate(cmds):
        out.extend(grow.get(i, []))
        out.append(c)
    out.extend(grow.get(len(cmds), []))
    print(f'{sum(len(v) for v in grow.values())} directory blocks added up front', flush=True)
    cmds = out
    script = os.path.join(stage, 'debugfs.cmd')
    with open(script, 'w') as o: o.write('\n'.join(cmds) + '\n')
    print(f'{n_files} files, {len(cmds)} debugfs commands', flush=True)

    # ESP contents
    if not os.path.exists(os.path.join(esp_dir, 'EFI', 'BOOT', 'BOOTAA64.EFI')): sys.exit('systemd-boot missing from the tarball')
    with open(os.path.join(esp_dir, 'loader', 'loader.conf'), 'w') as o:
        o.write('default arch.conf\ntimeout 0\nconsole-mode keep\n')
    with open(os.path.join(esp_dir, 'loader', 'entries', 'arch.conf'), 'w') as o:
        o.write(f'title   Arch Linux ARM\nlinux   /Image\ninitrd  /initramfs-linux.img\noptions {cmdline}\n')
    for need in ('Image', 'initramfs-linux.img'):
        if not os.path.exists(os.path.join(esp_dir, need)): sys.exit(f'{need} missing from the tarball')

    # root file system
    root_img = os.path.join(a.out, 'root.img')
    if os.path.exists(root_img): os.unlink(root_img)
    print('mke2fs', flush=True)
    run(f'{E2}/mke2fs', '-q', '-F', '-t', 'ext4', '-L', 'archroot', '-U', str(fs_uuid), '-E', 'lazy_itable_init=0,lazy_journal_init=0',
        root_img, f'{root_bytes // 1024}k')
    print('debugfs: filling the root file system (takes a while)', flush=True)
    r = subprocess.run([f'{E2}/debugfs', '-w', '-f', script, root_img], capture_output=True, text=True)
    errs = [l for l in r.stderr.splitlines() if l and not l.startswith('debugfs ') and 'Allocated inode' not in l]
    open(os.path.join(a.out, 'debugfs.err'), 'w').write('\n'.join(errs))
    print(f'debugfs exit {r.returncode}, {len(errs)} messages (debugfs.err)', flush=True)
    r = subprocess.run([f'{E2}/e2fsck', '-fy', root_img], capture_output=True, text=True)
    open(os.path.join(a.out, 'e2fsck.log'), 'w').write(r.stdout + r.stderr)
    print('e2fsck exit', r.returncode, '(0: clean, 1: fixed)', flush=True)
    if r.returncode > 1: sys.exit('e2fsck found errors it could not fix: see e2fsck.log')

    # the disk
    disk = os.path.join(a.out, 'disk.img')
    print('assembling', disk, flush=True)
    with open(disk, 'wb') as f:
        f.truncate(disk_bytes)
        write_gpt(f, disk_bytes, [
            (ESP_TYPE, esp_uuid, esp_first // SECTOR, (esp_first + esp_bytes) // SECTOR - 1, 'EFI system'),
            (LINUX_ROOT_ARM64, root_uuid, root_first // SECTOR, (root_first + root_bytes) // SECTOR - 1, 'Arch Linux ARM'),
        ])
        f.seek(root_first)
        with open(root_img, 'rb') as r_:
            while True:
                b = r_.read(16 * MiB)
                if not b: break
                if b.count(0) == len(b): f.seek(len(b), 1)
                else: f.write(b)
    off = f'{disk}@@{esp_first}'
    run(f'{MT}/mformat', '-i', off, '-F', '-T', str(esp_bytes // SECTOR), '-v', 'ESP', '::')
    run(f'{MT}/mcopy', '-i', off, '-s', '-Q', *[os.path.join(esp_dir, x) for x in sorted(os.listdir(esp_dir))], '::/')
    print(run(f'{MT}/mdir', '-i', off, '-/', '::').stdout[-1500:])
    os.unlink(root_img)
    print('esp', esp_uuid, 'root', root_uuid)
    print('done:', disk)


def find_member(tarball, member, dest):
    t = tarfile.open(tarball, 'r:gz')
    for m in t:
        if m.name == member:
            with open(dest, 'wb') as o: shutil.copyfileobj(t.extractfile(m), o)
            return dest
    sys.exit(member + ' not in the tarball')


if __name__ == '__main__':
    main()
