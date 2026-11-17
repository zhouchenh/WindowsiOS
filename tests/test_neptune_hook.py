#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Run read-only binary guards and the native hook harness (arm64 macOS)."""
import importlib.util
from pathlib import Path
import platform
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("check_neptune", ROOT / "scripts/check_neptune.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def fixture():
    data = bytearray(0x3F4000)
    struct.pack_into("<8I", data, 0, 0xFEEDFACF, 0x100000C, 0, 6, 3, 328, 0, 0)
    struct.pack_into("<2I16s", data, 32, 0x1B, 24, CHECK.UUID_BYTES)
    struct.pack_into("<2I16s4Q4I", data, 56, 0x19, 152, b"__TEXT", 0,
                     0x3E0000, 0, 0x3E0000, 5, 5, 1, 0)
    struct.pack_into("<16s16sQQ8I", data, 128, b"__unwind_info", b"__TEXT",
                     0x3DBC80, 0x25B8, 0x3DBC80, 2, 0, 0, 0, 0, 0, 0)
    struct.pack_into("<2I16s4Q4I", data, 208, 0x19, 152, b"__DATA_CONST",
                     0x3E0000, 0x14000, 0x3E0000, 0x14000, 3, 3, 1, 0)
    struct.pack_into("<16s16sQQ8I", data, 280, b"__got", b"__DATA_CONST",
                     0x3F3020, 0xCD8, 0x3F3020, 3, 0, 0, 6, 124, 0, 0)
    for offset, raw in CHECK.GUARDS:
        expected = bytes.fromhex(raw)
        data[offset:offset + len(expected)] = expected
    return data


def dxmt_fixture():
    data = bytearray(0x13C4000)
    struct.pack_into("<8I", data, 0, 0xFEEDFACF, 0x100000C, 0, 6, 2, 96, 0, 0)
    struct.pack_into("<2I16s", data, 32, 0x1B, 24, CHECK.DXMT_UUID_BYTES)
    struct.pack_into("<2I16s4Q4I", data, 56, 0x19, 72, b"__TEXT", 0,
                     0x13C4000, 0, 0x13C4000, 5, 5, 0, 0)
    address = CHECK.DXMT_CREATE_ADDRESS
    data[address:address + len(CHECK.DXMT_CREATE_BYTES)] = CHECK.DXMT_CREATE_BYTES
    for address, offset in CHECK.GET_DEVICE:
        code = CHECK.GET_DEVICE_PREFIX + struct.pack("<I", 0xF9400014 | ((offset // 8) << 10)) + CHECK.GET_DEVICE_SUFFIX
        data[address:address + len(code)] = code
    return data


class GuardTests(unittest.TestCase):
    def test_original(self):
        data = fixture()
        original = bytes(data)
        CHECK.check(data)
        self.assertEqual(data, original)

    def test_every_guard_and_both_callers(self):
        for offset in [a for a, _ in CHECK.GUARDS] + [CHECK.FREE_RETURN - 4, CHECK.FINISH_RETURN - 4]:
            with self.subTest(offset=hex(offset)):
                data = fixture()
                data[offset] ^= 1
                with self.assertRaises(CHECK.GuardError):
                    CHECK.check(data)

    def test_unknown_malformed_and_truncated(self):
        for offset in (0, 4, 16, 20, 40, 60, 88, 112, 176, 240, 344, 348):
            with self.subTest(offset=offset):
                data = fixture()
                data[offset] ^= 0x80
                with self.assertRaises(CHECK.GuardError):
                    CHECK.check(data)
        for size in (0, 28, 39, 200, 0x3F3FFF):
            with self.subTest(size=size), self.assertRaises(CHECK.GuardError):
                CHECK.check(fixture()[:size])

    def test_dxmt_parent_and_entry_guards(self):
        data = dxmt_fixture()
        CHECK.check_dxmt(data)
        for address in [CHECK.DXMT_CREATE_ADDRESS] + [a for a, _ in CHECK.GET_DEVICE]:
            data[address] ^= 1
            with self.subTest(address=hex(address)), self.assertRaises(CHECK.GuardError):
                CHECK.check_dxmt(data)
            data[address] ^= 1
        data[40] ^= 1
        with self.assertRaises(CHECK.GuardError):
            CHECK.check_dxmt(data)

    def test_generated_header(self):
        self.assertEqual((ROOT / "devices/neptune_hook_layout.h").read_text(), CHECK.header_text())

    @unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64",
                         "native caller and Mach protection checks require arm64 macOS")
    def test_native_harness(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "test-neptune-hook"
            subprocess.run(["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                            "-pthread", str(ROOT / "tests/test_neptune_hook.c"), "-o", str(binary)], check=True)
            for case in ("guards", "install", "interposed", "protect-fail", "rollback", "race",
                         "parents", "callers", "publication"):
                subprocess.run([str(binary), case], check=True, timeout=15)


if __name__ == "__main__":
    unittest.main()
