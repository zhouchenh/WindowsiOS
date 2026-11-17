#!/usr/bin/env python3
"""Patches UTM's dxmt-native (DXMT, LGPL-2.1) in place so a Metal buffer that could not be made is
skipped instead of written through.

    python3 -I scripts/patch_dxmt.py <path to dxmt-native.framework/dxmt-native>

Why: DXMT's staging allocator makes 32 MB Metal buffers (newBufferWithLength:options:) and never
checks the result. When Metal refuses one (memory is short, e.g. after Windows switched displays and
recreated its devices), UpdateSubresource copies the upload to NULL and the app crashes on an
npt-ring thread (_platform_memmove <- __MTLBuffer_updateContents <- UpdateTexture). With the patch
that upload is dropped (Windows may draw a stale texture once) and the next one asks Metal again.

  A  __MTLBuffer_updateContents: no copy when [buffer contents] is NULL.
  B  the blit encoder's dispatch: a command whose first Metal object is nil is skipped (the copy
     from the missing staging buffer to the texture).
  C  the two staging allocators' newBuffer calls (RingBumpState<StagingBufferBlockAllocator, 32 MB>
     and <..., 2 MB> for deferred contexts, allocate_or_reuse_block): on nil, the block's capacity is
     set to 0 so the next allocation makes a new block instead of using (or recycling) the failed
     one. The third instance of that template, the 4 MB argument-buffer allocator (newBuffer call at
     0x11115c), is left alone: it writes through its own malloc'd copy, which neither A nor B
     guards, and a capacity-0 block there would cost a fresh 4 MB malloc per allocation while
     Metal keeps refusing.

Not covered: a nil destination in a blit (buffer-to-buffer, texture-to-buffer), the 32 MB copy-temp
allocator (GpuPrivateBufferBlockAllocator), nil argument buffers. None is on the crash path seen.
The patched __MTLBuffer_updateContents returns memcpy's result instead of 0 after a copy; its only
caller (the _MTLBuffer_updateContents thunk) ignores it.

Only the build it was written for is patched: UTM's dxmt-native with the UUID below (UTM's DXMT
pin 66e27f3/8b9d334). Every replaced byte is checked first; a binary that is already patched is left
alone; any other binary is left alone with a warning. The new code goes in zero padding at the end
of __TEXT (after the last section, before the segment ends). Re-sign the framework afterwards
(scripts/embed_gpu3d.sh does).
"""
import os
import struct
import subprocess
import sys
import tempfile

UUID = "DDA3DBC3-6DFD-33F8-8138-26350CA42778"

CONTENTS = 0x12296E0  # _objc_msgSend$contents stub
MEMCPY = 0x1228EF8  # _memcpy stub
NEWBUF = 0xD6CE4  # _MTLDevice_newBuffer (winemetal thunk; returns the buffer in x0)
BLIT_NEXT = 0xDA010  # __MTLBlitCommandEncoder_encodeCommands: on to the next command
CAVE_C = 0x13C2480  # zero padding after the last __TEXT section (ends 0x13C2478); __TEXT ends 0x13C4000
CAVE_B = 0x13C24A0


def rel(at, target):
    return target - at


def patches():
    out = []
    a = 0xDBC20
    out.append((a, "f44fbea9fd7b01a9fd430091f30300aa000040f9ab364594688640a9620e40f90000088bad34459400008052fd7b41a9f44fc2a8c0035fd6", [
        "stp x20, x19, [sp, #-0x20]!",
        "stp x29, x30, [sp, #0x10]",
        "add x29, sp, #0x10",
        "mov x19, x0",
        "ldr x0, [x0]",
        "bl #%d" % rel(a + 0x14, CONTENTS),
        "cbz x0, #%d" % (0xDBC4C - 0xDBC38),  # NULL contents: straight to the epilogue
        "ldp x8, x1, [x19, #0x8]",
        "ldr x2, [x19, #0x18]",
        "add x0, x0, x8",
        "bl #%d" % rel(a + 0x28, MEMCPY),
        "ldp x29, x30, [sp, #0x10]",
        "ldp x20, x19, [sp], #0x20",
        "ret",
    ], "A: __MTLBuffer_updateContents skips a NULL buffer"))
    out.append((0xDA034, "20011fd6", ["b #%d" % rel(0xDA034, CAVE_B)], "B: blit dispatch goes through the nil filter"))
    # The same template code at both: [sp] = {allocated_size 0, capacity x21} at the call.
    for site, orig in ((0x5FE60, "a1db0194"), (0x974B4, "0cfe0094")):
        out.append((site, orig, ["bl #%d" % rel(site, CAVE_C)], "C: staging newBuffer at %#x through the nil wrapper" % site))
    cc = [
        "stp x29, x30, [sp, #-0x10]!",
        "mov x29, sp",
        "bl #%d" % rel(CAVE_C + 8, NEWBUF),
        "ldp x29, x30, [sp], #0x10",
        "cbnz x0, #8",
        "str xzr, [sp, #0x8]",  # the caller's Allocation capacity = 0: never used again, never recycled
        "ret",
    ]
    out.append((CAVE_C, "00" * 4 * len(cc), cc, "cave C: newBuffer wrapper"))
    bb = [
        "ldr x10, [x20, #0x10]",  # every blit command type has its first Metal object at +0x10
        "cbz x10, #8",
        "br x9",  # an object: the original jump-table dispatch
        "b #%d" % rel(CAVE_B + 12, BLIT_NEXT),  # nil: skip the command
    ]
    out.append((CAVE_B, "00" * 4 * len(bb), bb, "cave B: skip a blit command whose object is nil"))
    return out


def assemble(lines, work, tag):
    s = os.path.join(work, tag + ".s")
    o = os.path.join(work, tag + ".o")
    with open(s, "w") as f:
        f.write(".text\n" + "\n".join(lines) + "\n")
    subprocess.run(["xcrun", "--sdk", "iphoneos", "clang", "-c", "-target", "arm64-apple-ios15.0", s, "-o", o], check=True)
    text = subprocess.run(["otool", "-t", "-X", o], capture_output=True, text=True, check=True).stdout
    words = []
    for ln in text.splitlines():
        parts = ln.split()
        if len(parts) > 1:
            words += parts[1:]
    code = b"".join(struct.pack("<I", int(w, 16)) for w in words)
    if len(code) != 4 * len(lines):
        sys.exit("patch_dxmt: %s assembled to %d bytes, expected %d" % (tag, len(code), 4 * len(lines)))
    return code


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    uuid = subprocess.run(["dwarfdump", "--uuid", path], capture_output=True, text=True).stdout
    if UUID not in uuid:
        print("patch_dxmt: warning: %s is not the dxmt-native this patch was written for (%s); left unpatched"
              % (path, uuid.split()[1] if uuid.split() else "no UUID"), file=sys.stderr)
        return 0
    data = bytearray(open(path, "rb").read())
    with tempfile.TemporaryDirectory() as work:
        plan = [(addr, bytes.fromhex(orig), assemble(lines, work, "p%d" % i), desc)
                for i, (addr, orig, lines, desc) in enumerate(patches())]
    if all(bytes(data[a:a + len(new)]) == new for a, _, new, _ in plan):
        print("patch_dxmt: already patched: %s" % path)
        return 0
    for addr, orig, new, desc in plan:
        cur = bytes(data[addr:addr + len(new)])
        if cur != orig:
            sys.exit("patch_dxmt: %s: unexpected bytes at %#x (%s); nothing written" % (desc, addr, cur.hex()))
    for addr, _, new, desc in plan:
        data[addr:addr + len(new)] = new
        print("patch_dxmt: %#09x %s" % (addr, desc))
    with open(path, "wb") as f:
        f.write(data)
    print("patch_dxmt: patched %s (re-sign it)" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
