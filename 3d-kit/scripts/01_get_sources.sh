#!/bin/bash
# Clones WindowsiOS at the commit this kit was made against and applies the 3D patch.
set -euo pipefail
cd "$(dirname "$0")"; source ./env.sh
KIT="$(cd .. && pwd)"
[ -d "$SRC/.git" ] || git clone https://github.com/ammaarreshi/WindowsiOS "$SRC"
cd "$SRC"
git checkout -q 0071d69
git apply --check "$KIT/patches/windowsios-3d.patch" && git apply "$KIT/patches/windowsios-3d.patch"
chmod +x scripts/embed_gpu3d.sh
echo "patched source in $SRC"
