#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Read-only ABI guard for the pinned DXMT device lifetime data hooks.

The derived container vtable is the only modified data: QueryInterface,
AddRef and Release. QueryInterface has an inlined AddRef and must be serialized
with the two count wrappers. Full __text B/BL audit found no direct callers to
these three entries; only Release calls its private-decrement cold helper.
Public device/D3D10/context aliases forward through the container vtable.
No executable code is changed. Existing patch_dxmt.py A-C sites are independent.
"""
import argparse
from pathlib import Path
import struct
import sys
import uuid

UUID = uuid.UUID("DDA3DBC3-6DFD-33F8-8138-26350CA42778").bytes
TEXT_SIZE = 0x13C4000
VTABLE = 0x13C4A58
TARGETS = (0xD680, 0xDBC0, 0xDBF8)
DESTRUCTOR = 0xDF08
EVENT_VALUE = 0xD8E08
GUARDS = (
    # initializer own queue construction/store at +0x18.
    (0x1187D8,
     "eafbff97e00317aa41008052ccf8fe97f80300aae00700f9800240f9400000b45ef8fe97980200f9e00317aa11f9fe97f70300aae00700f9600242f8400000b456f8fe97771200f9"),
    # native retain.
    (0xD8B38,
     "fd7bbfa9fd030091080040f92941459400008052fd7bc1a8c0035fd6"),
    # native release.
    (0xD8B54,
     "fd7bbfa9fd030091080040f91f41459400008052fd7bc1a8c0035fd6"),
    # native autorelease pool.
    (0xD8D1C,
     "f44fbea9fd7b01a9fd430091f30300aaa89a0090000d46f98c404594600200f900008052fd7b41a9f44fc2a8c0035fd6"),
    # native command-buffer factory.
    (0xD8D4C,
     "f44fbea9fd7b01a9fd430091f30300aa000040f948424594600600f900008052fd7b41a9f44fc2a8c0035fd6"),
    # native command-buffer commit.
    (0xD8D78,
     "fd7bbfa9fd030091000040f94742459400008052fd7bc1a8c0035fd6"),
    # native command-buffer status.
    (0xD8DB0,
     "f44fbea9fd7b01a9fd430091f30300aa000040f9074b4594600600f900008052fd7b41a9f44fc2a8c0035fd6"),
    # container construction, refs and queue pointer.
    (0xD43C,
     "ff8301d1f85f02a9f65703a9f44f04a9fd7b05a9fd430191f40304aaf50303aaf60302aaf70301aaf30300aa2004000f"
     "000400fd1f7c01a9a89d00f00821299108410091080000f91f0802a9a20000b4c80240f9080540f9e00316aa00013fd6"
     "7f3200b9e00240f9ff0200f9601e00f9080040f9080d40f900013fd6602200f9651e40f960220191e10313aae20316aa"
     "e30315aae40314aa92020094"),
    # whole QueryInterface and AddRef/Release.
    (0xD680,
     "ffc303d1f6570ca9f44f0da9fd7b0ea9fd830391e8a000d0085d40f9080140f9a8831df8480088520800b072621f00b4"
     "5f0000f9c89700900091c33de00b803d282440a9ea2f42a91f010aeb20014bfa001d0054c89700900095c33de003803d"
     "282440a9ea2f40a91f010aeb20014bfa001c0054c897009000adc33da0039c3c282440a9aa2f7ca91f010aeb20014bfa"
     "001b0054c89700b00011c13da0039b3c282440a9aa2f7ba91f010aeb20014bfa001a0054c89700b00015c13da0039a3c"
     "282440a9aa2f7aa91f010aeb20014bfa00190054c89700b00019c13de01f803d282440a9ea2f47a91f010aeb20014bfa"
     "00180054a89100b008e12591f50300aae00308aaf30301aaf40302aae1e0ff97e20314aae80300aae00315aa6a2e40a9"
     "5f0108eb600141fa40160054e90313aac89700b0001dc13de00b803d682a40a9eb3342a91f010beb40014cfa00180054"
     "c89700b00021c13de003803d282940a9eb3340a91f010beb40014cfa00170054c89700b00025c13da0039c3c282940a9"
     "ab337ca91f010beb40014cfa00160054c89700b00029c13da0039b3c282940a9ab337ba91f010beb40014cfa00150054"
     "c89700b0002dc13da0039a3c282940a9ab337aa91f010beb40014cfa00140054c89700b00031c13de01f803d282940a9"
     "eb3347a91f010beb40014cfa00130054c897009000b1c33de00b803d282940a9eb3342a91f010beb40014cfa20130054"
     "c897009000b5c33de003803d282540a9ea2f40a91f010aeb20014bfa20120054a09100b00084109196e0ff97692240a9"
     "3f0100eb000141fa40120054a09100b0007426918fe0ff97692a40a93f0100eb400141fa20130054e80313aac99700b0"
     "2035c13de00b803d692a40a9eb3342a93f010beb40014cfa00130054c99700b02039c13de00b803d092940a9eb3342a9"
     "3f010beb40014cfae0090054c99700b0203dc13de003803d092940a9eb3340a93f010beb40014cfae0080054a09100b0"
     "00082791f40308aa6ee0ff97882640a91f0100eb200141fae0070054692240a9ca228cd24af5b4f2aa91d3f24a77e9f2"
     "3f010aeb097290d28916bbf2c9e2d6f26903eff2000149fa60060054692240a98aa282d2aae4b3f2aaa9d3f24a20e9f2"
     "3f010aeba9138cd20903b3f249f1d6f289baf6f2000149fae0040054692240a9cae29dd2ea9fb9f22a6dcff2ead1e8f2"
     "3f010aeb89779cd2a9b9b2f26926cdf26954f3f2000149fa60030054a09100b000e0259143e0ff97e00702a9e0830091"
     "e10313aa3c44049460020034e8030091e00313aad3dfff97a09100b000482591e8830091e10300915adfff97e0830091"
     "f9910494e8dfc0396800f836e01340f9f56b4894e85fc0396800f836e00340f9f16b4894480088520800b0720c000014"
     "e00000b40820009109fd5f882a0500110afd0b88abffff354905003408008052400000f90200001408010032a9835df8"
     "eaa000d04a5d40f94a0140f95f0109eb61060054e00308aafd7b4ea9f44f4da9f6574ca9ffc30391c0035fd613200191"
     "003840f9080040f9080540f9f40302aa00013fd608008052930200f9ecffff17135c41f9930000b4e00313aa1e100394"
     "e20314aa08008052530000f9e4ffff17a03a40f9080040f9080540f900013fd608008052a9a20191890200f9dcffff17"
     "0830009109fd5f882905001109fd0a88aaffff35d2ffff17a03a40f9080040f9080540f900013fd608008052a9820191"
     "890200f9ceffff17b3020b91a06641f9080040f9080540f9daffff17da6b4894f30300aae8dfc039a800f836e01340f9"
     "a56b489402000014f30300aae85fc039c800f836e00340f99f6b4894e00313aa266a4894f30300aae00313aa236a4894"
     "0920009128fd5f880a0500112afd0b88abffff356800003400050011c0035fd6093000912afd5f884a0500112afd0b88"
     "abffff35f9ffff17f44fbea9fd7b01a9fd4300910820009109fd5f883305007113fd0988a9ffff35a0000054e00313aa"
     "fd7b41a9f44fc2a8c0035fd686344894e00313aafd7b41a9f44fc2a8c0035fd6"),
    # deleting destructor trampoline.
    (0xDF04,
     "5a160014fd7bbfa9fd03009157160094fd7bc1a8c36a4814ff8301d1"),
    # private decrement, sentinel, deleting vtable slot.
    (0x121AE44,
     "0830009109fd5f882905007109fd0a88aaffff3540000054c0035fd60900b0520afd5f884a01090b0afd0b88abffff35"
     "40ffffb4080040f9015940f920001fd6"),
    # queue sequence initialization.
    (0xF0208,
     "ff0302d1fc6f02a9fa6703a9f85f04a9f65705a9f44f06a9fd7b07a9fdc30191f50301aaf30300aa28008052000d084e"
     "0000803d1ffc01a91f0800f91fa0003900c00091560f0094"),
    # submission publication and initializer placement.
    (0xF15F4,
     "ff0302d1f65705a9f44f06a9fd7b07a9fdc30191f30300aa080040f9092d80520a1140925401a99b09d09e520a6869f8"
     "4a0500910a6829f8882a03a9089c56f9882200f9084040910021009189a20094803200f9689e56f9080d4092681e088b"
     "09d19e521501098ba80640b908050011a80600b9687e5fc80805009168fe09c8a9ffff35e00313aa78dc449492dc4494"
     "f40300aae8038052e80b00f9e8430091e80700f97642009149008052a9c31db8f62303a9e94300b9a89300d1f6a301a9"
     "e8230091e81700f9e0630091e1c30091020080d250edfc97c87e5fc808050091c87e09c8a9ffff357bdc4494080014cb"
     "a90e40f90801098ba80e00f908e485526962009121fddfc86002088b07000094fd7b47a9f44f46a9f65745a9ff030291"
     "c0035fd6ac4efc97"),
    # finish wait, chunk reset, coherent publication.
    (0xF24A0,
     "ff4303d1fc6f07a9fa6708a9f85f09a9f6570aa9f44f0ba9fd7b0ca9fd030391f30300aa48028052e89f0139288c8c52"
     "e8c30079a88a00b0088912910001c03de017803dff8b0139e043019173ae0094e89fc1396800f836e02b40f94ad94494"
     "000580524ed94494e02b00f9a89000b000e9c23de083853cc805805208400079888a00d008512591000540ad000400ad"
     "e04301913cff0094e89fc1396800f836e02b40f938d94494000580523cd94494e02b00f9a8900090000dc13de083853c"
     "88cc8552898a00d029c5249108400079200540ad000400ad1f880039e043019129ff0094e89fc139a800f83768a20091"
     "08fddf08e80000364f010014e02b40f921d9449468a2009108fddf08482900376922009168c20091e8a701a974820091"
     "756200917642009137008052f44f00a9f50b00f9e9c30091e9df02a94a008052aac31ab8eb1340f9eb2705a9ea6300b9"
     "a85301d1eba303a9e8a30091e82700f9e0e30091e1430191020080d27fe9fc9768a2009108fddf08e8250037e8124092"
     "e90f40f90a2d80521b25aa9b602340f97991ff971f0c00f168000054602340f96991ff97602340f97391ff971f1400f1"
     "c1020054602340f9e094ff973a92ff97e01b00f9e8e30091e0c3009152b0fc97e843019161430091e3e30091a08a00b0"
     "00d41291828a009042d01f916b010094e0430191e9fe0094e89fc139880cf837e83fc139c80cf837602340f9d894ff97"
     "201800b4f80300aa140080d21a0080d2150080d2590315cb33ff4393681200917f1600b108040054890215cb1f0d89eb"
     "e90300540afd7dd38a2200b52afd42935f0108eb4881889aeaef7db23f010aeb0900fc921431899a88fe7dd3282100b5"
     "80f27dd3cad844940800198b140c148b1a81009100e4004f000100ad1c0d13cbe0031caae10315aae20319aaefd94494"
     "750000b4e00315aab7d84494f5031caa05000014ba0e088b0300001400e4004f400381aca302198be00318aae10313aa"
     "82008052b394ff971f1000f140faff540800138b530315cb79fe43931c0119eb49040054890215cb1f0d89ebc9050054"
     "0afd7dd32a1d00b52afd42935f0108eb4881889aeaef7db23f010aeb0900fc920831899a09fd7dd3c91b00b500f17dd3"
     "9bd844941800138b81f37dd31c03018be00318aae4d84494180f19cbe00318aae10315aae20313aac0d94494750000b4"
     "e00315aa88d84494f50318aa1f031cebe102005464000014a80e088b1c319a9abf021ceb410200545f000014e02b40f9"
     "7dd84494e83fc13988f3ff36e01f40f979d84494602340f97194ff9740f3ffb55900001481f37dd35c03018be0031aaa"
     "c5d84494bf021cebe0090054f40315aa08000014e02b40f96bd84494e83fc1398808f837942200919f021cebc0080054"
     "800240f9ac91ff97f30300aa810080529b91ff97190400b163000054180080d207000014b913f8b7e00319aa60d84494"
     "f80300aae10319aaabd84494e00313aae10318aae20319aa830080528090ff97e00318aaa2da449408018092e8ffeff2"
     "1f0008eb62110054f30300aa1f5800f188000054f33f0139f9e300910c00001468ee7d92082100911f6100f129038052"
     "3a01889ae0031aaa45d84494f90300aa480341b2e0cf03a9e82700f9e00319aae10318aae20313aa6cd944943f6b3338"
     "e00318aa34d84494e843019161430091e3e30091a08a00b000301391828a009042d01f9132010094e04301912ffe0094"
     "e89fc13988f7ff37e83fc139c8f7ff36e01f40f924d84494942200919f021ceb81f7ff54f44f40a9750000b4e00315aa"
     "1dd84494680f40f91f0500b1f50b40f9800000548a0240f91f010aeba8010054e0031baad8f8ff97a90240f9ff0209eb"
     "c90400541c0000140a0080525f3f03d56a010037ea0309aa1f0109eba9feff54897e5fc83f010aeb01ffff5488fe0ac8"
     "5f010071ea139f5aeafe0736e00314aa8cd74494e0031baac3f8ff97a90240f9ff0209eb080100541000001409008052"
     "5f3f03d569010037e90308aaff0208eb49010054a87e5fc81f0109eb01ffff54b7fe09c83f010071e9139f5ae9fe0736"
     "e00315aa77d74494c87e5fc8080500d1c8fe09c8a9ffff35e00316aa74d7449408af85526002088be10317aa69010094"
     "08c085526002088be10317aaa901009408d385526002088be10317aaea010094f706009168a2009108fddf081f050071"
     "21d8ff54"),
    # initializer sequence and event layout.
    (0x11874C,
     "ff4301d1f85f01a9f65702a9f44f03a9fd7b04a9fd030191f70301aaf30300aa689000900025c33d0000803d00e4004f"
     "f40300aa808e813c010800f9e87495524855a672f50300aaa88e03f80080823c000002ad0018803df60300aac00e893c"
     "1f3800f9000005ad086000f900808c3c00808d3c00808e3c1f840fa908228052088400f91f40043900600f91"),
    # initializer increment and final signal/commit.
    (0x118BB0,
     "f50300aae6f7fe97f40300aae00700f9b30240f968060091a80200f9a00e40f9ecf7fe97f60300aab7e641f9f70000b4"
     "e00316aae10317aa14f9fe9721f9fe97f74e41f977ffffb5a89240f9080100b4e00316aaf1f8fe97f70300aaa1620491"
     "4cf9fe97e00317aa16f9fe97a11240f9e00316aae20313aa22f8fe97e00316aae1f7fe97"),
    # native event value bridge.
    (0xD8E08,
     "f44fbea9fd7b01a9fd430091f30300aa000040f9e14a4594600600f900008052fd7b41a9f44fc2a8c0035fd6"),
    # device pipeline pointer.
    (0xE074,
     "e8230091e00313aa7e1b0194e80740f9ff0700f9602e41f9682e01f9400100b4080040f9080540f900013fd6"),
    # pipeline vtable and scheduler placement.
    (0x54EE8,
     "a89b00d008e1399108410091080000f9280040f9083141f9e00301aa00013fd6080040f9081140f900013fd687140394"
     "600600f960420091ff040094745218a9"),
    # scheduler native mutex, condvar, vector and destroyed layout.
    (0x5631C,
     "ff8301d1fa6701a9f85f02a9f65703a9f44f04a9fd7b05a9fd430191f30300aae87495524855a672080000f900e4004f"
     "0080803c0080813c0080823c1f1c00f9693796520996a772f40300aa890e04f8f50300aaa80e0df80080843c0080853c"
     "0080863c0080873c0080883c0080893c00808a3c00808b3c1f6400f900808e3c00808f3c1f9400f9e80300aa008d8d3c"
     "008101ad08f0a752083001b91fac00f91f7c14a91f9c00f91f4005395849479419781f5379b600f9"),
    # native thread directly contains pthread_t.
    (0x566C8,
     "ff0301d1f65701a9f44f02a9fd7b03a9fdc30091f40301aaf30300aa00018052d5484794f50300aa01484794f50700f9"
     "00028052d0484794e30300aae07f00a9880240f9152000a90200009042501e91e00313aa010080d2624a4794e0000035"
     "e00313aafd7b43a9f44f42a9f65741a9ff030191c0035fd6"),
    # whole scheduler destructor and thread join ABI.
    (0x582DC,
     "f657bda9f44f01a9fd7b02a9fd830091f30300aa084005912900805209fd9f08000001911541479474d653a99f0215eb"
     "01040054f60314aa9f0215ebc104005474a200f9960500b5609240f9a00000b4140040f9bd414794e00314aab4ffffb5"
     "608a40f97f8a00f9400000b4b74147946042039155414794608202912cffff9760c201912affff976002019104414794"
     "e00313aafd7b42a9f44f41a9f657c3a84a414714942200919f0215ebc0000054880240f988ffffb4e00314aa67414794"
     "f9ffff1774d653a9f60314aa9f0215eb80fbff54b52200d1e00315aa62414794bf0214eb81ffff54769e40f974a200f9"
     "d6faffb4e00316aadf0214ebe0000054942200d1e00314aa574147949f0216eb81ffff54609e40f976a200f98b414794"
     "609240f960f9ffb5ceffff1770b3fe97"),
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
    for slot, target in enumerate(TARGETS):
        if struct.unpack_from('<Q', data, VTABLE+slot*8)[0] != 0x10000000000000 | target:
            raise ValueError(f'vtable slot {slot} changed')
    if struct.unpack_from('<Q', data, VTABLE+0xb0)[0] != 0x10000000000000 | DESTRUCTOR:
        raise ValueError('deleting destructor changed')
    # This rejects direct-call bypasses in future repackaged images even if UUID
    # and the selected function bodies were accidentally retained.
    for pc in range(0x4000, 0x12283ac, 4):
        ins, = struct.unpack_from('<I', data, pc)
        if ins & 0x7c000000 == 0x14000000:
            delta = ins & 0x3ffffff
            if delta & 0x2000000:
                delta -= 0x4000000
            if pc + 4 * delta in TARGETS:
                raise ValueError(f'direct lifetime call bypass at {pc:#x}')


def header():
    out = ['/* SPDX-License-Identifier: GPL-2.0-or-later */',
           '/* Generated by scripts/check_neptune_device.py; do not edit. */',
           '#ifndef HV_NEPTUNE_DEVICE_LAYOUT_H', '#define HV_NEPTUNE_DEVICE_LAYOUT_H',
           '#include <stddef.h>', '#include <stdint.h>',
           '#define HV_NPT_DEVICE_VTABLE 0x13c4a58u',
           '#define HV_NPT_DEVICE_DTOR 0xdf08u', '#define HV_NPT_DEVICE_EVENT 0xd8e08u',
           '#define HV_NPT_DEVICE_POOL 0xd8d1cu', '#define HV_NPT_DEVICE_RETAIN 0xd8b38u',
           '#define HV_NPT_DEVICE_RELEASE 0xd8b54u', '#define HV_NPT_DEVICE_COMMAND_BUFFER 0xd8d4cu',
           '#define HV_NPT_DEVICE_COMMIT 0xd8d78u', '#define HV_NPT_DEVICE_STATUS 0xd8db0u']
    out.append('static const uint8_t hv_npt_device_uuid[] = {' + ','.join(f'0x{x:02x}' for x in UUID) + '};')
    out.append('static const uintptr_t hv_npt_device_targets[] = {0xd680,0xdbc0,0xdbf8};')
    for i, (_, h) in enumerate(GUARDS):
        out.append(f'static const uint8_t hv_npt_device_guard_{i}[] = {{')
        b = bytes.fromhex(h)
        for j in range(0, len(b), 16):
            out.append('    ' + ','.join(f'0x{x:02x}' for x in b[j:j+16]) + ',')
        out.append('};')
    out.append('struct HvNptDeviceGuard {size_t offset, size; const uint8_t *bytes;};')
    out.append('static const struct HvNptDeviceGuard hv_npt_device_guards[] = {')
    for i, (off, _) in enumerate(GUARDS):
        out.append(f'    {{0x{off:x}, sizeof(hv_npt_device_guard_{i}), hv_npt_device_guard_{i}}},')
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
            print('DXMT device lifetime UUID, layout, code, vtable and branch guards verified')
        if args.emit_header:
            args.emit_header.write_text(header())
    except (OSError, ValueError, struct.error) as e:
        print(f'rejected: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
