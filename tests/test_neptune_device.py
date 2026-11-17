#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""ABI guard negatives, generated metadata and native callback/rollback tests."""
import importlib.util
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('guard', ROOT / 'scripts/check_neptune_device.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def fixture():
    b = bytearray(0x142C000)
    struct.pack_into('<8I', b, 0, 0xFEEDFACF, 0x100000C, 0, 6, 3, 168, 0, 0)
    struct.pack_into('<II16s', b, 32, 27, 24, guard.UUID)
    struct.pack_into('<II16s4Q2i2I', b, 56, 25, 72, b'__TEXT', 0, guard.TEXT_SIZE,
                     0, guard.TEXT_SIZE, 5, 5, 0, 0)
    struct.pack_into('<II16s4Q2i2I', b, 128, 25, 72, b'__DATA_CONST', guard.TEXT_SIZE,
                     0x68000, guard.TEXT_SIZE, 0x68000, 3, 3, 0, 0)
    for off, h in guard.GUARDS:
        b[off:off+len(h)//2] = bytes.fromhex(h)
    for i, target in enumerate(guard.TARGETS):
        struct.pack_into('<Q', b, guard.VTABLE+8*i, 0x10000000000000 | target)
    struct.pack_into('<Q', b, guard.VTABLE+0xb0, 0x10000000000000 | guard.DESTRUCTOR)
    return b


class Guards(unittest.TestCase):
    def test_generated_header(self):
        self.assertEqual((ROOT/'devices/neptune_device_layout.h').read_text(), guard.header())

    def test_supported(self):
        guard.check(fixture())

    def test_identity_code_and_slots(self):
        b = fixture()
        offsets = [40, 64, 136, guard.VTABLE, guard.VTABLE+8, guard.VTABLE+16, guard.VTABLE+0xb0]
        offsets += [off for off, _ in guard.GUARDS]
        for off in offsets:
            with self.subTest(offset=hex(off)):
                b[off] ^= 1
                with self.assertRaises(ValueError):
                    guard.check(b)
                b[off] ^= 1

    def test_branch_bypass(self):
        b = fixture()
        for target in guard.TARGETS:
            struct.pack_into('<I', b, 0x5000, 0x94000000 | ((target-0x5000)//4))
            with self.assertRaisesRegex(ValueError, 'bypass'):
                guard.check(b)

    @unittest.skipUnless(sys.platform == 'darwin', 'Mach-O runtime harness requires macOS')
    def test_native(self):
        # A split implementation worktree may supply the cleanup header explicitly;
        # normal integrated builds use devices/ in this repository.
        include = os.environ.get('HV_NPT_TEST_CLEANUP_INCLUDE', str(ROOT/'devices'))
        with tempfile.TemporaryDirectory(prefix='neptune-device-') as d:
            exe = Path(d)/'test'
            subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                            '-I'+include, str(ROOT/'tests/test_neptune_device.c'), str(ROOT/'devices/dxmt_data_lock.c'), '-o', str(exe)], check=True)
            for case in ('guards', 'install', 'interposed', 'protect-fail', 'rollback',
                         'rollback-fatal', 'ops-fail', 'race', 'compiler', 'compiler-failure', 'remove', 'remove-protect', 'remove-restore', 'remove-race', 'remove-used'):
                with self.subTest(case=case):
                    subprocess.run([str(exe), case], check=True, capture_output=True, text=True)


if __name__ == '__main__':
    unittest.main()
