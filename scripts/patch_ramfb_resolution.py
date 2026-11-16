import sys, struct, lzma
src, dst, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
d = bytearray(open(src,'rb').read())
SEC, DATAOFF = 0x4ee10, 24
sec_size = int.from_bytes(d[SEC:SEC+3],'little')
start, end = SEC + DATAOFF, SEC + sec_size
comp = bytes(d[start:end])
usize = struct.unpack_from('<Q', comp, 5)[0]
dec = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE)
fv = bytearray(dec.decompress(comp)); assert len(fv) == usize
T = 0x7766e0  # 640x480 entry; 800x600 at +36, 1024x768 at +72
assert struct.unpack_from('<III', fv, T) == (0,640,480)
assert struct.unpack_from('<III', fv, T+36) == (0,800,600)
assert struct.unpack_from('<III', fv, T+72) == (0,1024,768)
struct.pack_into('<II', fv, T+36+4, W, H)  # boot-default slot (mode 1)
filt = [{'id': lzma.FILTER_LZMA1, 'dict_size': 1<<24, 'lc':3, 'lp':0, 'pb':2, 'preset': 9 | lzma.PRESET_EXTREME}]
new = bytearray(lzma.compress(bytes(fv), format=lzma.FORMAT_ALONE, filters=filt))
assert new[:5] == comp[:5], (new[:5].hex(), comp[:5].hex())
struct.pack_into('<Q', new, 5, usize)
print(f"orig compressed {len(comp)}  new {len(new)}  room {len(comp)-len(new)}")
if len(new) > len(comp): sys.exit("new stream larger than original; cannot patch in place")
d[start:end] = bytes(new) + b'\x00' * (len(comp) - len(new))
# verify round trip
chk = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(bytes(d[start:end]), max_length=usize)
assert chk == bytes(fv)
assert struct.unpack_from('<III', chk, T+36) == (0, W, H)
open(dst,'wb').write(d)
print("patched ok:", dst)
