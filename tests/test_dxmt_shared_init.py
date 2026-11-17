#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Pinned image negatives, metadata drift, native creation and rollback tests."""
import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('guard', ROOT/'scripts/check_dxmt_shared_init.py')
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
    for off, target in zip(guard.SLOTS, guard.TARGETS):
        struct.pack_into('<Q', b, off, 0x10000000000000 | target)
    return b


class Guards(unittest.TestCase):
    def test_header(self):
        self.assertEqual((ROOT/'devices/dxmt_shared_init_layout.h').read_text(), guard.header())

    def test_valid(self):
        guard.check(fixture())

    def test_reject_mutations(self):
        b = fixture()
        for off in [40, 64, 136, *guard.SLOTS, *(x[0] for x in guard.GUARDS)]:
            with self.subTest(offset=hex(off)):
                b[off] ^= 1
                with self.assertRaises(ValueError):
                    guard.check(b)
                b[off] ^= 1

    def test_no_bypass(self):
        for target in guard.TARGETS:
            b = fixture()
            struct.pack_into('<I', b, 0x5000, 0x94000000 | ((target-0x5000)//4))
            with self.assertRaisesRegex(ValueError, 'bypass'):
                guard.check(b)

    def test_existing_allocation_patch_independent(self):
        b = fixture()
        # A-C bodies/caves remain outside the shared initialization guards.
        for off, size in [(0xdbc20, 0x38), (0xda034, 4), (0x5fe60, 4),
                          (0x974b4, 4), (0x13c2480, 0x50)]:
            b[off:off+size] = b'\0'*size
        guard.check(b)

    @unittest.skipUnless(sys.platform == 'darwin', 'Mach runtime harness requires macOS')
    def test_native(self):
        with tempfile.TemporaryDirectory(prefix='dxmt-shared-') as d:
            exe = Path(d)/'test'
            subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                            str(ROOT/'tests/test_dxmt_shared_init.c'), str(ROOT/'devices/dxmt_data_lock.c'), '-o', str(exe)], check=True)
            for case in ('guards', 'install', 'interposed', 'protect-fail', 'rollback',
                         'fatal', 'race', 'disabled', 'ready', 'not-shared', 'background',
                         'gates', 'midwait', 'timeout', 'event-error', 'original-error', 'concurrent'):
                with self.subTest(case=case):
                    subprocess.run([str(exe), case], check=True, capture_output=True, text=True)


if __name__ == '__main__':
    unittest.main()
