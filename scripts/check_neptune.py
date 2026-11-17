#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Verify the one Neptune image supported by the read-only-code free-import hook.

This script never patches a framework. It verifies the original teardown and COM
record layout in UTM virglrenderer.1 UUID 6B0499CC-B64D-32E7-ABD8-56512B41E17A.
The runtime hook changes only that loaded image's free import pointer; the exact
original caller PC identifies records for deferred cleanup. Unknown UUIDs,
modified code (including the abandoned executable patch), and different mappings
are rejected. Re-signing the original framework does not change these guards.

Source ownership audit: utmapp/virglrenderer
02ca82b32f0bb733f90577d3846aaa44780c9579, src/neptune/npt_context.c. Each regs
registration owns a host COM reference; identity is non-owning. The binary's
original instruction guards establish its layout independently of source pin.

    python3 -I scripts/check_neptune.py --check path/to/virglrenderer.1
    python3 -I scripts/check_neptune.py --emit-header devices/neptune_hook_layout.h
"""
import argparse
from pathlib import Path
import struct
import sys
import uuid

UUID = "6B0499CC-B64D-32E7-ABD8-56512B41E17A"
UUID_BYTES = uuid.UUID(UUID).bytes
TEXT_SIZE = 0x3E0000
SECTION_END = 0x3DE238
DATA_CONST = (0x3E0000, 0x14000, 0x3E0000, 0x14000, 3, 3)
GOT = (0x3F3020, 0xCD8, 0x3F3020, 6, 124)
FREE_SLOT = 0x3F3130
FREE_RETURN = 0x265D10
FINISH_RETURN = 0x265E88
DXMT_UUID_BYTES = uuid.UUID("DDA3DBC3-6DFD-33F8-8138-26350CA42778").bytes
DXMT_CREATE_ADDRESS = 0x35F10
DXMT_CREATE_BYTES = bytes.fromhex("ffc300d1fd7b02a9fd830091a82741a9e82701a9ff1f00a9070080d2"
                                 "64feff97fd7b42a9ffc30091c0035fd6")
# Queried ID3D11DeviceChild GetDevice method VM address -> passive parent offset.
# No this-adjusting thunks are accepted. Every method is exactly 56 bytes with
# only instruction 4 (ldr x20, [x0, #offset]) varying.
GET_DEVICE = (
    (0xD1D4, 0x10), (0x113DC, 0x10), (0x12104, 0x10), (0x129A8, 0x10),
    (0x1619C, 8), (0x17918, 0x10), (0x18248, 0x10), (0x2401C, 8),
    (0x252D0, 8), (0x265F4, 8), (0x278BC, 8), (0x31910, 0x28),
    (0x33204, 0x50), (0x33DC8, 0x58), (0x3CCF8, 0x30), (0x3F120, 0x50),
    (0x3FBF8, 0x60), (0x5A578, 0x18), (0x5AC04, 0x18), (0x5B268, 0x18),
    (0x5B864, 0x18), (0x5BE88, 0x18), (0x5C4EC, 0x18), (0x5D9D4, 0x10),
    (0x60FB0, 0x10), (0xCFD00, 8), (0xD1478, 0x20),
)
GET_DEVICE_PREFIX = bytes.fromhex("f44fbea9fd7b01a9fd430091f30301aa")
GET_DEVICE_SUFFIX = bytes.fromhex("b40000b4880240f9080540f9e00314aa00013fd6740200f9fd7b41a9f44fc2a8c0035fd6")

# All executable bytes remain original. The entire destructor protects the
# stopped-ring/queue ordering as well as distinguishing free callsites.
GUARDS = (
    (0x265BEC,
     "ff0301d1f65701a9f44f02a9fd7b03a9fdc30091f30300aa080040b9e80300f9"
     "600a00d000dc1b9151f8ff9774c2049188fedf08e801003660e2029142e10494"
     "9ffe9f0860e2039121e1049460e2029140e10494609640f9e123009131e10494"
     "60e2039114e1049460e2029130e1049475820191763640f9df0215eb20010054"
     "d42200d1d60640f9e00314aa1dac0494e00314aa44a90494df0215eb21ffff54"
     "140080d276224091087790527502088b04000014942200919f0208f1c0000054"
     "a06a74f880ffffb491a00494bf6a34f8f9ffff17086f90526002088b14e10494"
     "e00313aa5a9a0494e00313aa3597049460c20191f0e00494605240f991e00494"
     "60620a910ae10494602a41f9010080d2f5b2f697200100b4f40300aa800a40f9"
     "88e00494602a41f9e10314aaeeb2f697f40300aa40ffffb5602a41f9010080d2"
     "aeb2f697602e41f9010080d2e6b2f697800100b4f40300aa950a40f9a00a40f9"
     "78e00494e00315aa76e00494602e41f9e10314aadcb2f697f40300aae0feffb5"
     "602e41f9010080d29cb2f69760820991c9e0049460420891e5e00494e00313aa"
     "b4930494082391526002088bdf920494081591526002088bdde00494e00313aa"
     "109c0494c0ba41f9010080d28bb2f697086690526002088bd5e0049460fe40f9"
     "0100009021703a9184b2f69760e20691cfe00494680a42b9a8000034e80300f9"
     "600a00d000541c91d9f7ff97600241f94ce00494c09641f9010080d2b2b2f697"
     "e00100b4f40300aa08000014e00315aa44e00494c09641f9e10314aaaab2f697"
     "f40300aac00000b4950a40f9a00e40b9e0feff370ee00494f5ffff17c09641f9"
     "010080d265b2f697085d90526002088bafe0049460e205918fe0049460e20491"
     "abe0049460820091a9e00494600640f92ce00494e00313aa2ae00494fd7b43a9"
     "f44f42a9f65741a9ff030191c0035fd6"),
    (0x264198, "950200f997120079985a01a9992200b9"),
    (0x264398, "c82240b908050011c82200b9"),
    (0x2651A0, "080840f9140940f9d40200b4092140b93f090071c303005429050051092100b9"
                 "60420891dee30494880240f9080940f9e00314aa00013fd6"),
    (0x39DF2C, "b00200d0109a40f900021fd6"),
)


class GuardError(ValueError):
    pass


def check(data):
    if len(data) < 32:
        raise GuardError("truncated Mach-O header")
    magic, cpu, subtype, filetype, ncmds, sizeofcmds, _, _ = struct.unpack_from("<8I", data)
    if (magic, cpu, subtype, filetype) != (0xFEEDFACF, 0x0100000C, 0, 6):
        raise GuardError("expected a thin arm64 dylib")
    end = 32 + sizeofcmds
    if end > len(data) or ncmds > sizeofcmds // 8:
        raise GuardError("invalid Mach-O load commands")
    found_uuid = text = const = got = None
    offset = 32
    for _ in range(ncmds):
        if offset + 8 > end:
            raise GuardError("truncated load command")
        cmd, size = struct.unpack_from("<2I", data, offset)
        if size < 8 or size % 8 or offset + size > end:
            raise GuardError("invalid load command size")
        if cmd == 0x1B:
            if size != 24 or found_uuid is not None:
                raise GuardError("invalid or duplicate UUID")
            found_uuid = bytes(data[offset + 8:offset + 24])
        if cmd == 0x19:
            if size < 72:
                raise GuardError("truncated segment")
            name, addr, vmsize, fileoff, filesize, maxprot, initprot, nsects, _ = \
                struct.unpack_from("<16s4Q4I", data, offset + 8)
            if size != 72 + nsects * 80:
                raise GuardError("invalid segment sections")
            name = name.rstrip(b"\0")
            if name in (b"__TEXT", b"__DATA_CONST"):
                geometry = (addr, vmsize, fileoff, filesize, maxprot, initprot)
                last = 0
                for i in range(nsects):
                    sec = offset + 72 + i * 80
                    secname, segname, secaddr, secsize, secoff = struct.unpack_from("<16s16sQQI", data, sec)
                    if (segname.rstrip(b"\0") != name or secaddr != secoff or secaddr < addr
                            or secaddr + secsize > addr + filesize):
                        raise GuardError("unsupported section mapping")
                    last = max(last, secaddr + secsize)
                    if secname.rstrip(b"\0") == b"__got":
                        if name != b"__DATA_CONST" or got is not None:
                            raise GuardError("unexpected GOT")
                        flags, reserved1 = struct.unpack_from("<II", data, sec + 64)
                        got = (secaddr, secsize, secoff, flags, reserved1)
                if name == b"__TEXT":
                    if text is not None:
                        raise GuardError("duplicate text segment")
                    text = (*geometry, last)
                else:
                    if const is not None:
                        raise GuardError("duplicate data-const segment")
                    const = geometry
        offset += size
    if offset != end or found_uuid != UUID_BYTES:
        raise GuardError("unsupported UUID or malformed load commands")
    if text != (0, TEXT_SIZE, 0, TEXT_SIZE, 5, 5, SECTION_END) or const != DATA_CONST or got != GOT:
        raise GuardError("unexpected text/import mapping")
    if len(data) < DATA_CONST[0] + DATA_CONST[1]:
        raise GuardError("truncated mapped segments")
    for offset, raw in GUARDS:
        expected = bytes.fromhex(raw)
        if data[offset:offset + len(expected)] != expected:
            raise GuardError("unexpected original bytes at %#x" % offset)


def header_text():
    out = ["/* SPDX-License-Identifier: GPL-2.0-or-later */",
           "/* Generated by scripts/check_neptune.py --emit-header; do not edit. */",
           "#ifndef HV_NEPTUNE_HOOK_LAYOUT_H", "#define HV_NEPTUNE_HOOK_LAYOUT_H",
           "#include <stddef.h>", "#include <stdint.h>", "",
           "#define HV_NPT_HOOK_TEXT_SIZE 0x3e0000u",
           "#define HV_NPT_HOOK_TEXT_SECTION_END 0x3de238u",
           "#define HV_NPT_HOOK_FREE_SLOT 0x3f3130u",
           "#define HV_NPT_HOOK_FREE_RETURN 0x265d10u",
           "#define HV_NPT_HOOK_FINISH_RETURN 0x265e88u", "",
           "#define HV_NPT_DXMT_CREATE_ADDRESS 0x35f10u", "",
           "struct HvNptHookGuard { size_t offset, size; const uint8_t *bytes; };", ""]

    def array(name, value):
        out.append("static const uint8_t %s[] = {" % name)
        for i in range(0, len(value), 12):
            out.append("    " + ", ".join("0x%02x" % b for b in value[i:i + 12]) + ",")
        out.extend(["};", ""])

    array("hv_npt_hook_uuid", UUID_BYTES)
    for i, (_, raw) in enumerate(GUARDS):
        array("hv_npt_hook_guard_%d" % i, bytes.fromhex(raw))
    out.append("static const struct HvNptHookGuard hv_npt_hook_guards[] = {")
    for i, (offset, raw) in enumerate(GUARDS):
        out.append("    {0x%x, %d, hv_npt_hook_guard_%d}," % (offset, len(bytes.fromhex(raw)), i))
    out.extend(["};", "", "/* Passive DXMT child-parent reader: exact methods, never invoked. */",
                "struct HvNptParentMethod { size_t address, parent_offset; };",
                "static const struct HvNptParentMethod hv_npt_parent_methods[] = {"])
    out.extend("    {0x%x, 0x%x}," % pair for pair in GET_DEVICE)
    out.extend(["};", ""])
    array("hv_npt_dxmt_uuid", DXMT_UUID_BYTES)
    array("hv_npt_dxmt_create_bytes", DXMT_CREATE_BYTES)
    array("hv_npt_get_device_prefix", GET_DEVICE_PREFIX)
    array("hv_npt_get_device_suffix", GET_DEVICE_SUFFIX)
    out.extend(["#endif", ""])
    return "\n".join(out)


def check_dxmt(data):
    if len(data) < 32:
        raise GuardError("truncated DXMT header")
    magic, cpu, subtype, filetype, ncmds, size, _, _ = struct.unpack_from("<8I", data)
    if (magic, cpu, subtype, filetype) != (0xFEEDFACF, 0x100000C, 0, 6):
        raise GuardError("expected thin arm64 DXMT")
    if size > 0x10000 or 32 + size > len(data) or ncmds > size // 8:
        raise GuardError("bad DXMT commands")
    offset, found_uuid, found_text = 32, False, False
    for _ in range(ncmds):
        if offset + 8 > 32 + size:
            raise GuardError("truncated DXMT command")
        cmd, length = struct.unpack_from("<2I", data, offset)
        if length < 8 or length % 8 or offset + length > 32 + size:
            raise GuardError("bad DXMT command size")
        if cmd == 0x1B:
            if found_uuid or length != 24 or data[offset + 8:offset + 24] != DXMT_UUID_BYTES:
                raise GuardError("unsupported DXMT UUID")
            found_uuid = True
        elif cmd == 0x19:
            if length < 72:
                raise GuardError("truncated DXMT segment")
            name, addr, vmsize, fileoff, filesize, maxprot, initprot, nsects, _ = \
                struct.unpack_from("<16s4Q4I", data, offset + 8)
            if length != 72 + nsects * 80:
                raise GuardError("bad DXMT sections")
            if name.rstrip(b"\0") == b"__TEXT":
                if found_text or (addr, vmsize, fileoff, filesize, maxprot, initprot) != \
                        (0, 0x13C4000, 0, 0x13C4000, 5, 5):
                    raise GuardError("unsupported DXMT text mapping")
                found_text = True
        offset += length
    if offset != 32 + size or not found_uuid or not found_text:
        raise GuardError("missing DXMT guards")
    if data[DXMT_CREATE_ADDRESS:DXMT_CREATE_ADDRESS + len(DXMT_CREATE_BYTES)] != DXMT_CREATE_BYTES:
        raise GuardError("unexpected DXMT D3D11CreateDevice code")
    for address, parent_offset in GET_DEVICE:
        expected = GET_DEVICE_PREFIX + struct.pack("<I", 0xF9400014 | ((parent_offset // 8) << 10)) + GET_DEVICE_SUFFIX
        if data[address:address + len(expected)] != expected:
            raise GuardError("unsupported GetDevice code at %#x" % address)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", type=Path)
    group.add_argument("--check-dxmt", type=Path)
    group.add_argument("--emit-header", type=Path)
    args = parser.parse_args()
    try:
        if args.emit_header:
            args.emit_header.write_text(header_text())
        elif args.check:
            check(args.check.read_bytes())
            print("check_neptune: original image verified for guarded deferred-release hook")
        else:
            check_dxmt(args.check_dxmt.read_bytes())
            print("check_neptune: DXMT passive parent methods verified")
        return 0
    except (GuardError, OSError) as error:
        print("check_neptune: %s; hook must remain disabled" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
