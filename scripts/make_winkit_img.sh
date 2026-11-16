#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Builds the WinKit disk: a 64 MB raw image with an MBR and one FAT32 partition labelled WINKIT that
# holds winkit/ (without its README.md) plus the guest tools given on the command line (normally
# build/guest/WinIOSBrowser.exe from `make guest-tools`). Windows shows it as the WINKIT drive.
#   scripts/make_winkit_img.sh [out.img] [extra file ...]      (default out: dist/WinKit/drivers.img)
# `make winkit-img` runs it; scripts/embed_gpu3d.sh then copies the result into the app as winkit.img.
# Needs mtools (brew install mtools). Nothing is mounted: the image is written with mformat/mcopy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist/WinKit/drivers.img}"
[ $# -gt 0 ] && shift
for t in mformat mcopy mdir; do
    command -v "$t" >/dev/null || { echo "$t not found: brew install mtools" >&2; exit 1; }
done
for f in "$@"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

SIZE_MB=64
START=2048                                   # partition start (LBA), 1 MiB aligned
TOTAL=$((SIZE_MB * 2048))                    # 512-byte sectors
PART=$((TOTAL - START))

STAGE="$(mktemp -d -t winkit-img)"
TMP="$OUT.tmp"
trap 'rm -rf "$STAGE" "$TMP"' EXIT

# The files: winkit/ minus its README and macOS metadata, then the extra tools at the top level.
rsync -a --exclude '/README.md' --exclude '._*' --exclude '.DS_Store' "$ROOT/winkit/" "$STAGE/"
for f in "$@"; do cp "$f" "$STAGE/"; done

mkdir -p "$(dirname "$OUT")"
rm -f "$TMP"
dd if=/dev/zero of="$TMP" bs=1048576 count="$SIZE_MB" 2>/dev/null

# MBR: disk signature "WINK", one partition entry (type 0x0C FAT32 LBA, CHS fields unused), 0x55AA.
le32() { printf '\\%03o\\%03o\\%03o\\%03o' $(($1 & 255)) $((($1 >> 8) & 255)) $((($1 >> 16) & 255)) $((($1 >> 24) & 255)); }
mbr() { printf "$1" | dd of="$TMP" bs=1 seek="$2" conv=notrunc 2>/dev/null; }
mbr 'WINK' 440
mbr "\\000\\376\\377\\377\\014\\376\\377\\377$(le32 $START)$(le32 $PART)" 446
mbr '\125\252' 510

# FAT32 needs at least 65525 clusters, so 512-byte clusters (as Windows itself formats 64 MB).
# A fixed volume serial, so Windows sees the same WINKIT volume after every rebuild.
export MTOOLS_SKIP_CHECK=1
VOL="$TMP@@$((START * 512))"
mformat -i "$VOL" -F -c 1 -T "$PART" -h 64 -s 32 -H "$START" -v WINKIT -N 574B4954 ::

# mtools 4.0.4x puts a long-name (VFAT) entry in front of the volume label entry, which Windows' own
# format never does and chkdsk reports as an orphan. Move the label entry into the first root slot.
P0=$((START * 512))
rd() { od -An -tu"$2" -j "$1" -N "$2" "$TMP" | tr -d ' '; }
SPC=$(rd $((P0 + 13)) 1); RSV=$(rd $((P0 + 14)) 2); NFAT=$(rd $((P0 + 16)) 1)
FATSZ=$(rd $((P0 + 36)) 4); RCLUS=$(rd $((P0 + 44)) 4)
ROOT=$((P0 + (RSV + NFAT * FATSZ + (RCLUS - 2) * SPC) * 512))
if [ "$(rd $((ROOT + 11)) 1)" = 15 ] && [ "$(rd $((ROOT + 43)) 1)" = 8 ]; then
    dd if="$TMP" of="$TMP" bs=32 skip=$((ROOT / 32 + 1)) seek=$((ROOT / 32)) count=1 conv=notrunc 2>/dev/null
    dd if=/dev/zero of="$TMP" bs=32 seek=$((ROOT / 32 + 1)) count=1 conv=notrunc 2>/dev/null
fi
[ "$(rd $((ROOT + 11)) 1)" = 8 ] || { echo "unexpected root directory layout after mformat" >&2; exit 1; }

mcopy -i "$VOL" -s -m -Q "$STAGE"/* ::/

mv "$TMP" "$OUT"
trap 'rm -rf "$STAGE"' EXIT
echo "WinKit disk: $OUT"
mdir -i "$OUT@@$((START * 512))" -/ -b :: | sed 's|^::/|  |'
