#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Synthetic image corruption checks and native failure injection; no GPU use."""
import importlib.util
from pathlib import Path
import platform
import struct
import subprocess
import tempfile
import unittest
import uuid
ROOT=Path(__file__).resolve().parents[1]
SPEC=importlib.util.spec_from_file_location('guard',ROOT/'scripts/check_gpu_map_diagnostics.py')
GUARD=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


def fixture(image):
    link=image['text_size']+image['data_size']
    data=bytearray(link+0x10000)
    struct.pack_into('<8I',data,0,0xFEEDFACF,0x100000C,0,6,6,424,0,0)
    struct.pack_into('<II16s',data,32,0x1B,24,uuid.UUID(image['uuid']).bytes)
    struct.pack_into('<II16sQQQQIIII',data,56,0x19,72,b'__TEXT',0,image['text_size'],0,image['text_size'],5,5,0,0)
    struct.pack_into('<II16sQQQQIIII',data,128,0x19,152,b'__DATA_CONST',image['text_size'],image['data_size'],image['text_size'],image['data_size'],3,3,1,0)
    struct.pack_into('<16s16sQQIIIIIIII',data,200,b'__got',b'__DATA_CONST',image['got'],image['got_size'],image['got'],3,0,0,6,image['got_index'],0,0)
    struct.pack_into('<II16sQQQQIIII',data,280,0x19,72,b'__LINKEDIT',link,0x10000,link,0x10000,1,1,0,0)
    struct.pack_into('<6I',data,352,2,24,link,2,link+32,18)
    dysym=[11,80]+[0]*18; dysym[14]=link+64; dysym[15]=image['got_index']+image['got_size']//8
    struct.pack_into('<20I',data,376,*dysym)
    struct.pack_into('<IBBHQ',data,link,0,1,0,0,0)
    struct.pack_into('<IBBHQ',data,link+16,6,1,0,0,0)
    data[link+32:link+50]=b'_mmap\0_ftruncate\0\0\0'
    for name,index in [('mmap',0),('ftruncate',1)]:
        offset=image['got_index']+(image[name+'_slot']-image['got'])//8
        struct.pack_into('<I',data,link+64+offset*4,index)
    for at,raw in image['guards']:
        data[at:at+len(bytes.fromhex(raw))]=bytes.fromhex(raw)
    return data


class Tests(unittest.TestCase):
    def test_original_readonly(self):
        for image in GUARD.IMAGES:
            data=fixture(image); original=bytes(data); GUARD.check(data,image); self.assertEqual(data,original)
    def test_header(self):
        self.assertEqual((ROOT/'devices/gpu_map_diagnostics_layout.h').read_text(),GUARD.header())
    def test_all_code(self):
        for image in GUARD.IMAGES:
            for at,_ in image['guards']:
                data=fixture(image); data[at]^=1
                with self.subTest(image=image['name'],offset=hex(at)),self.assertRaises(ValueError): GUARD.check(data,image)
    def test_malformed_commands(self):
        for image in GUARD.IMAGES:
            for at,value in [(0,0),(4,0),(16,1000),(20,8),(40,0),(60,8),(132,8),(192,2),(264,0),(356,8),(380,8),(352,11),(376,2),(356,80),(380,24)]:
                data=fixture(image); struct.pack_into('<I',data,at,value)
                with self.subTest(image=image['name'],offset=at,value=value),self.assertRaises((ValueError,struct.error)): GUARD.check(data,image)
            for command in (352,376):
                data=fixture(image)
                size=24 if command==352 else 80
                data[456:456+size]=data[command:command+size]
                struct.pack_into('<II',data,16,7,424+size)
                with self.assertRaises(ValueError): GUARD.check(data,image)
    def test_import_tables(self):
        for image in GUARD.IMAGES:
            link=image['text_size']+image['data_size']
            for at,value in [(360,0),(364,0xffffffff),(368,0),(372,1),(432,0),(436,0xffffffff),(link,1000)]:
                data=fixture(image); struct.pack_into('<I',data,at,value)
                with self.subTest(offset=at),self.assertRaises((ValueError,struct.error)): GUARD.check(data,image)
            for field in (4,5,8):
                data=fixture(image); data[link+field]=1 if field!=4 else 0xf
                with self.assertRaises(ValueError): GUARD.check(data,image)
    @unittest.skipUnless(platform.system()=='Darwin','native Mach-O harness')
    def test_native(self):
        with tempfile.TemporaryDirectory() as temp:
            binary=Path(temp)/'native'
            subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-O2','-pthread',str(ROOT/'tests/test_gpu_map_diagnostics.c'),str(ROOT/'devices/dxmt_data_lock.c'),'-o',str(binary)],check=True)
            subprocess.run([str(binary)],check=True)

if __name__=='__main__': unittest.main()
