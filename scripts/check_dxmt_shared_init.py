#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Read-only guards for opt-in shared texture initialization before publication.

Pinned native CreateTexture2D/2D1 vtable data slots only. The one direct call to
2D1 is inside the already intercepted legacy 2D method. Internal swapchain
creators have no shared flags. A-C allocation patches and caves do not overlap
these guards. This script never changes a framework.
"""
import argparse
from pathlib import Path
import struct
import sys
import uuid
UUID = uuid.UUID("DDA3DBC3-6DFD-33F8-8138-26350CA42778").bytes
TEXT_SIZE = 0x13c4000
VTABLE = 0x13c4ca8
SLOTS = (0x13c4cd0, 0x13c4e58)
TARGETS = (0xe6c0, 0xfef4)
GUARDS = (
    (0x35f10,
     "ffc300d1fd7b02a9fd830091a82741a9e82701a9ff1f00a9070080d264feff97fd7b42a9ffc30091c0035fd6e80340f9"
     "470000b4ff0000f9480000b41f0100f9"
    ),
    (0xd43c,
     "ff8301d1f85f02a9f65703a9f44f04a9fd7b05a9fd430191f40304aaf50303aaf60302aaf70301aaf30300aa2004000f"
     "000400fd1f7c01a9a89d00f00821299108410091080000f91f0802a9a20000b4c80240f9080540f9e00316aa00013fd6"
     "7f3200b9e00240f9ff0200f9601e00f9080040f9080d40f900013fd6602200f9651e40f960220191e10313aae20316aa"
     "e30315aae40314aa92020094"
    ),
    (0xdf1c,
     "ff8301d1f85f02a9f65703a9f44f04a9fd7b05a9fd430191f50305aaf30300aaf70300aaff8e0038a89d00f008613291"
     "1ffc012909410091090000f909e10a9108a10b9109a001a9011400f903100629"
    ),
    (0xe6c0,
     "ff8301d1f65703a9f44f04a9fd7b05a9fd430191f30303aaf40302aae80301aaf50300aae1030091e00308aaf1a70094"
     "e1030091e00315aae20314aae30313aafd050094fd7b45a9f44f44a9f65743a9ff830191c0035fd6"
    ),
    (0xfef4,
     "ff4301d1f65702a9f44f03a9fd7b04a9fd030191f30300aa430000b47f0000f9e00a8052e000b072a10100b428a84039"
     "68011037281c40b91f090071a3010054e00100541f0d007121030054282040b968000035e00313aaf6fa0094fd7b44a9"
     "f44f43a9f65742a9ff430191c0035fd6e00313aa9dab0094f9ffff17e00313aaf40301aaf50302aaf60303aa55e00094"
     "60feff36e30316aae20315aae10314aae00313aa1eec0094edffff1700008052fd7b44a9f44f43a9f65742a9ff430191"
     "c0035fd601000014f30300aa3f04007181030054e00313aaa8624894e823009100200091c4020094e023009196880494"
     "e87fc0396800f836e00740f98d624894a1624894a00088520000b072fd7b44a9f44f43a9f65742a9ff430191c0035fd6"
     "f30300aae87fc039a800f836e00740f98062489402000014f30300aa92624894e00313aa0461489463d4ff97"
    ),
    (0x3ae88,
     "880240f9083141f9e00314aa00013fd6080040f9080d40f900013fd60840409108210091a98302d1aae300d1e92b0ca9"
     "a96302d1e9230da9a8d302d1e87300f9a80359b8492081521f01096a80060054680b5837ff7f0ba9e8630091e9c30291"
     "e92300a9a16302d1a2a301d1e7e30291e00314aa03008012040080d2050080d2060080d2162e0094f50300aa0003f837"
     "a00356f8400000b411130394e85f40f9a80316f8ff5f00f9e0030391e1c3029132150094002a8052bfb64794f60300aa"
     "a16302d1a28302d1e3630091e40314aa6e2d0094c80240f9080540f9e00316aa00013fd615008052760200f9"
    ),
    (0x11874c,
     "ff4301d1f85f01a9f65702a9f44f03a9fd7b04a9fd030191f70301aaf30300aa689000900025c33d0000803d00e4004f"
     "f40300aa808e813c010800f9e87495524855a672f50300aaa88e03f80080823c000002ad0018803df60300aac00e893c"
     "1f3800f9000005ad086000f900808c3c00808d3c00808e3c1f840fa908228052088400f9"
    ),
    (0x118b98,
     "ff4301d1f85f01a9f65702a9f44f03a9fd7b04a9fd030191f50300aae6f7fe97f40300aae00700f9b30240f968060091"
     "a80200f9a00e40f9ecf7fe97f60300aab7e641f9f70000b4e00316aae10317aa14f9fe9721f9fe97f74e41f977ffffb5"
     "a89240f9080100b4e00316aaf1f8fe97f70300aaa16204914cf9fe97e00317aa16f9fe97a11240f9e00316aae20313aa"
     "22f8fe97e00316aae1f7fe97bf4600f9a8c20491bfe601f9a8ea01f9a8620491bf320279bf2212a9a0620f91d9faff97"
     "a01240f908f8fe97e10300aaa10600f9a0420291f568ff97740000b4e00314aa3ef7fe97e00313aafd7b44a9f44f43a9"
     "f65742a9f85f41a9ff430191c0035fd64cb1fb97f30300aae0230091bcd1fb97e00313aae73d4494f30300aae0230091"
     "b7d1fb97e00313aae23d4494"
    ),
    (0x11a064,
     "f44fbea9fd7b01a9fd430091f30300aa00e00091053a4494689240f9680000b568e641f9480100b4e00313aac2faff97"
     "f40300aa60e20091ff394494e00314aafd7b41a9f44fc2a8c0035fd6610640f960420291e263ff97692240a9290500d1"
     "1f0109eb01010054140080d260e20091f1394494e00314aafd7b41a9f44fc2a8c0035fd6601240f9e4f2fe97600600f9"
     "680240f9080500d11f0008ebf403889a60e20091e4394494e00314aafd7b41a9f44fc2a8c0035fd6f40300aa60e20091"
     "dd394494e00314aac7384494"
    ),
    (0xd8e08,
     "f44fbea9fd7b01a9fd430091f30300aa000040f9e14a4594600600f900008052fd7b41a9f44fc2a8c0035fd6"
    ),
)

def check(data):
    if len(data) < TEXT_SIZE or struct.unpack_from('<4I', data) != (0xFEEDFACF, 0x100000C, 0, 6):
        raise ValueError('expected pinned thin arm64 dylib')
    ncmds, size = struct.unpack_from('<II', data, 16)
    if size > 0x10000 or ncmds > size // 8:
        raise ValueError('invalid load commands')
    p, found_uuid, found_text, found_data = 32, False, False, False
    for _ in range(ncmds):
        if p + 8 > 32 + size:
            raise ValueError('truncated load command')
        cmd, n = struct.unpack_from('<II', data, p)
        if n < 8 or n % 8 or p + n > 32 + size:
            raise ValueError('invalid command length')
        if cmd == 27:
            if found_uuid or n != 24 or data[p+8:p+24] != UUID:
                raise ValueError('unknown DXMT UUID')
            found_uuid = True
        if cmd == 25:
            if n < 72:
                raise ValueError('invalid segment')
            name, addr, vm, off, fs, maximum, initial, ns, _ = struct.unpack_from('<16s4Q2i2I', data, p+8)
            if n != 72 + ns * 80:
                raise ValueError('invalid section count')
            if name.rstrip(b'\0') == b'__TEXT':
                if found_text or (addr, vm, off, fs, maximum, initial) != (0, TEXT_SIZE, 0, TEXT_SIZE, 5, 5):
                    raise ValueError('text geometry changed')
                found_text = True
            if name.rstrip(b'\0') == b'__DATA_CONST':
                if found_data or (addr, vm, off, fs, maximum, initial) != (TEXT_SIZE, 0x68000, TEXT_SIZE, 0x68000, 3, 3):
                    raise ValueError('vtable segment changed')
                found_data = True
        p += n
    if p != 32 + size or not (found_uuid and found_text and found_data):
        raise ValueError('missing image guards')
    for off, h in GUARDS:
        expected = bytes.fromhex(h)
        if data[off:off+len(expected)] != expected:
            raise ValueError(f'code guard mismatch at {off:#x}')
    for off, target in zip(SLOTS, TARGETS):
        if struct.unpack_from('<Q', data, off)[0] != 0x10000000000000 | target:
            raise ValueError(f'vtable slot {off:#x} changed')
    for pc in range(0x4000, 0x12283ac, 4):
        ins, = struct.unpack_from('<I', data, pc)
        if ins & 0x7c000000 == 0x14000000:
            delta = ins & 0x3ffffff
            if delta & 0x2000000:
                delta -= 0x4000000
            target = pc + 4 * delta
            if target in TARGETS and (pc, target) != (0xe700, 0xfef4):
                raise ValueError(f'direct create bypass at {pc:#x}')


def header():
    out = ['/* SPDX-License-Identifier: GPL-2.0-or-later */',
           '/* Generated by scripts/check_dxmt_shared_init.py; do not edit. */',
           '#ifndef HV_DXMT_SHARED_INIT_LAYOUT_H', '#define HV_DXMT_SHARED_INIT_LAYOUT_H',
           '#include <stddef.h>', '#include <stdint.h>',
           '#define HV_SHARED_VTABLE 0x13c4ca8u', '#define HV_SHARED_FLUSH 0x11a064u',
           '#define HV_SHARED_EVENT 0xd8e08u', '#define HV_SHARED_CONTAINER_VTABLE 0x13c4a58u']
    out.append('static const uint8_t hv_shared_uuid[] = {' + ','.join(f'0x{x:02x}' for x in UUID) + '};')
    out.append('static const uintptr_t hv_shared_slots[] = {0x13c4cd0,0x13c4e58};')
    out.append('static const uintptr_t hv_shared_targets[] = {0xe6c0,0xfef4};')
    for i, (_, h) in enumerate(GUARDS):
        out.append(f'static const uint8_t hv_shared_guard_{i}[] = {{')
        b = bytes.fromhex(h)
        for j in range(0, len(b), 16):
            out.append('    ' + ','.join(f'0x{x:02x}' for x in b[j:j+16]) + ',')
        out.append('};')
    out.append('struct HvSharedGuard {size_t offset, size; const uint8_t *bytes;};')
    out.append('static const struct HvSharedGuard hv_shared_guards[] = {')
    for i, (off, _) in enumerate(GUARDS):
        out.append(f'    {{0x{off:x}, sizeof(hv_shared_guard_{i}), hv_shared_guard_{i}}},')
    out += ['};', '#endif', '']
    return '\n'.join(out)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--check', type=Path)
    p.add_argument('--emit-header', type=Path)
    args = p.parse_args()
    if not args.check and not args.emit_header:
        p.error('specify --check or --emit-header')
    try:
        if args.check:
            check(args.check.read_bytes())
            print('DXMT shared-init UUID, layout, code, slots and branch guards verified')
        if args.emit_header:
            args.emit_header.write_text(header())
    except (OSError, ValueError, struct.error) as e:
        print(f'rejected: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
