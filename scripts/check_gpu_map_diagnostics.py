#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Read-only identity/import checks for failure-only GPU mapping diagnostics.

No framework bytes are changed. Accepts the shipped original images and the
existing DXMT A-C patch, whose sites do not overlap these guards. Runtime uses
these same UUID, segment, import-stub and callsite bytes before data-only binding.
"""
import argparse
from pathlib import Path
import struct
import uuid

# Filled from the pinned shipped images; no paths or image contents are needed
# to regenerate the metadata header.
IMAGES = []
IMAGES.append({'name': 'dxmt', 'uuid': 'DDA3DBC3-6DFD-33F8-8138-26350CA42778', 'text_size': 20725760, 'data_size': 425984, 'got': 21147480, 'got_size': 3384, 'got_index': 364, 'identity': 220944, 'mmap_slot': 21148640, 'ftruncate_slot': 21148320, 'mmap_return': 289352, 'ftruncate_return': 1876268, 'guards': [(220944, 'ffc300d1fd7b02a9fd830091a82741a9e82701a9ff1f00a9070080d264feff97fd7b42a9ffc30091c0035fd6'), (19042100, '101000f010f241f900021fd6'), (19041656, '101000f0105241f900021fd6'), (289324, '000080d2e10f40f96200805223008052e41700b9e5031caa3c8947941f0400b1'), (1876248, 'f17a4194a000f837e00314aae10313aa147b4194a0020034')]})
IMAGES.append({'name': 'virgl', 'uuid': '6B0499CC-B64D-32E7-ABD8-56512B41E17A', 'text_size': 4063232, 'data_size': 81920, 'got': 4141088, 'got_size': 3288, 'got_index': 124, 'identity': 19772, 'mmap_slot': 4141504, 'ftruncate_slot': 4141376, 'mmap_return': 0, 'ftruncate_return': 0, 'guards': [(19772, 'f85fbca9f65701a9f44f02a9fd7b03a9fdc30091f40302aaf50301aaf30300aa'), (3792900, 'b00200b010e240f900021fd6'), (3792708, 'b00200d010a240f900021fd6')]})


def check(data, image):
    if len(data) < 32 or struct.unpack_from('<4I', data) != (0xFEEDFACF, 0x100000C, 0, 6):
        raise ValueError('expected thin arm64 dylib')
    ncmd, size = struct.unpack_from('<II', data, 16)
    end = 32 + size
    if end > len(data) or size > 0x10000 or ncmd > size // 8:
        raise ValueError('invalid load commands')
    pos = 32
    seen = set()
    symtab = dysymtab = linkedit = None
    for _ in range(ncmd):
        if pos + 8 > end:
            raise ValueError('short load command')
        cmd, count = struct.unpack_from('<II', data, pos)
        if count < 8 or count % 8 or pos + count > end:
            raise ValueError('bad command size')
        if cmd == 0x1B:
            if 'uuid' in seen or count != 24 or data[pos+8:pos+24] != uuid.UUID(image['uuid']).bytes:
                raise ValueError('UUID mismatch')
            seen.add('uuid')
        elif cmd == 0x19:
            if count < 72:
                raise ValueError('short segment command')
            seg = struct.unpack_from('<II16sQQQQIIII', data, pos)
            if count != 72 + seg[9] * 80:
                raise ValueError('bad segment sections')
            name = seg[2].rstrip(b'\0')
            if name == b'__LINKEDIT':
                if linkedit is not None or seg[5] > len(data) or seg[6] > len(data)-seg[5]:
                    raise ValueError('invalid LINKEDIT range')
                linkedit = (seg[5], seg[5]+seg[6])
            if name in (b'__TEXT', b'__DATA_CONST'):
                if name in seen:
                    raise ValueError('duplicate segment')
                seen.add(name)
                addr, length, prot = (0, image['text_size'], 5) if name == b'__TEXT' else (image['text_size'], image['data_size'], 3)
                if seg[3:9] != (addr, length, addr, length, prot, prot):
                    raise ValueError('segment geometry mismatch')
            for j in range(seg[9]):
                sec = struct.unpack_from('<16s16sQQIIIIIIII', data, pos+72+j*80)
                if sec[0].rstrip(b'\0') == b'__got':
                    if 'got' in seen or sec[1].rstrip(b'\0') != b'__DATA_CONST' or (sec[2],sec[3],sec[4],sec[8],sec[9]) != (image['got'],image['got_size'],image['got'],6,image['got_index']):
                        raise ValueError('GOT geometry mismatch')
                    seen.add('got')
        elif cmd == 2:
            if symtab is not None or count != 24:
                raise ValueError('invalid or duplicate SYMTAB')
            symtab = struct.unpack_from('<6I', data, pos)
        elif cmd == 11:
            if dysymtab is not None or count != 80:
                raise ValueError('invalid or duplicate DYSYMTAB')
            dysymtab = struct.unpack_from('<20I', data, pos)
        pos += count
    if pos != end or seen != {'uuid','got',b'__TEXT',b'__DATA_CONST'} or not symtab or not dysymtab or not linkedit:
        raise ValueError('missing identity metadata')
    for start, length in ((symtab[2],symtab[3]*16),(symtab[4],symtab[5]),(dysymtab[14],dysymtab[15]*4)):
        if not length or start < linkedit[0] or start > linkedit[1] or length > linkedit[1]-start:
            raise ValueError('symbol table outside LINKEDIT')
    for offset, raw in image['guards']:
        expected = bytes.fromhex(raw)
        if data[offset:offset+len(expected)] != expected:
            raise ValueError(f'code mismatch at {offset:#x}')
    for symbol in ('mmap','ftruncate'):
        index = image['got_index'] + (image[symbol+'_slot'] - image['got']) // 8
        if index >= dysymtab[15]:
            raise ValueError('indirect import index out of bounds')
        si = struct.unpack_from('<I', data, dysymtab[14] + 4*index)[0]
        if si >= symtab[3]:
            raise ValueError('invalid import symbol')
        string, kind, section, _, value = struct.unpack_from('<IBBHQ', data, symtab[2]+16*si)
        if kind != 1 or section != 0 or value != 0:
            raise ValueError('expected external undefined import')
        if string >= symtab[5] or len(symbol)+2 > symtab[5]-string:
            raise ValueError('invalid import name')
        at = symtab[4]+string
        if data[at:at+len(symbol)+2] != ('_'+symbol).encode()+b'\0':
            raise ValueError('unexpected import target')


def header():
    out = ['/* SPDX-License-Identifier: GPL-2.0-or-later */', '/* Generated by scripts/check_gpu_map_diagnostics.py; do not edit. */', '#ifndef HV_GPU_MAP_DIAGNOSTICS_LAYOUT_H', '#define HV_GPU_MAP_DIAGNOSTICS_LAYOUT_H', '#include <stddef.h>', '#include <stdint.h>', 'struct GmdGuard { size_t offset, size; const unsigned char *bytes; };', 'struct GmdLayout { const char *name; unsigned char uuid[16]; size_t text_size, data_size, got, got_size, got_index, identity, mmap_slot, ftruncate_slot, mmap_return, ftruncate_return; const struct GmdGuard *guards; size_t guard_count; };']
    for im in IMAGES:
        name=im['name']
        for i,(offset,raw) in enumerate(im['guards']):
            out.append(f'static const unsigned char gmd_{name}_{i}[] = {{'+','.join(f'0x{x:02x}' for x in bytes.fromhex(raw))+'};')
        out.append(f'static const struct GmdGuard gmd_{name}_guards[] = {{')
        for i,(offset,_) in enumerate(im['guards']):
            out.append(f'    {{0x{offset:x}, sizeof(gmd_{name}_{i}), gmd_{name}_{i}}},')
        out.append('};')
    out.append('static const struct GmdLayout gmd_layouts[] = {')
    for im in IMAGES:
        fields=', '.join(hex(im[k]) for k in ('text_size','data_size','got','got_size','got_index','identity','mmap_slot','ftruncate_slot','mmap_return','ftruncate_return'))
        uid=','.join(f'0x{x:02x}' for x in uuid.UUID(im['uuid']).bytes)
        name=im['name']
        out.append(f'    {{"{name}", {{{uid}}}, {fields}, gmd_{name}_guards, sizeof(gmd_{name}_guards)/sizeof(gmd_{name}_guards[0])}},')
    out += ['};', '#endif', '']
    return '\n'.join(out)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', type=Path)
    parser.add_argument('--image', choices=['dxmt','virgl'])
    parser.add_argument('--emit-header', type=Path)
    args=parser.parse_args()
    if args.emit_header:
        args.emit_header.write_text(header())
    if args.check:
        if not args.image: parser.error('--check requires --image')
        try: check(args.check.read_bytes(), next(i for i in IMAGES if i['name']==args.image))
        except (ValueError,struct.error,OSError) as error: parser.exit(1, f'guard rejected: {error}\n')
        print(f'{args.image}: UUID, layout, imports and immutable code verified; no changes')

if __name__ == '__main__':
    main()
