Apple VM: licences of the Built-in JIT components
================================================

Apple VM is free software under the GNU General Public License, version 2 or (at your
option) any later version (LICENSE-GPL-2.0.txt). Its source code, including the build scripts
named below, is at https://github.com/zhouchenh/WindowsiOS (branch duo).

This app as built and distributed combines that GPL code with code under the Apache License
2.0 (among others ring, in the on-device pairing library, and AWS-LC, in StikJIT's idevice
library; see the crate lists named below). The Apache License 2.0 is compatible with version 3
of the GPL but not with version 2, so the app's binaries are distributed under the GNU General
Public License, version 3 (LICENSE-GPL-3.0.txt), which "any later version" permits. Apple VM's
source code stays under GPL-2.0-or-later, as do Henge and Husk (whose licence text is the same
as LICENSE-GPL-2.0.txt).

Built-in JIT ships two third-party components inside this app:

1. Frameworks/StikJIT.framework, used by PlugIns/WinJITHelper.appex
   StikJIT 1.9.0 (commit 32287268fa5824f9edce4cb359f5833ce0cf7b00),
   https://github.com/StikDebug/StikJIT
   Licence: Mozilla Public License 2.0, see LICENSE-StikJIT-MPL-2.0.txt.
   Modified by us with two patches, applied in this order (each in this folder and in the
   Apple VM repository under ios/patches/): stikjit-high-address.patch (taken from Henge,
   https://github.com/Leviidev/Henge, ci/stikjit-high-address.patch) and
   stikjit-ipv6-address.patch (ours: the device address may be IPv6). The source code of
   StikJIT is available at the address above; scripts/build_jit_deps.sh in the Apple VM
   repository rebuilds the framework from it with the patches. The JIT scripts StikJIT bundles
   (universal.js, legacy.js: StikDebug's, under their own licences, not StikJIT's MPL-2.0) are
   removed from the framework in this app; they are never used.
   StikJIT contains idevice by Jackson Coxson (https://github.com/jkcoxson/idevice), MIT
   licence, see LICENSE-idevice-MIT.txt, as the prebuilt idevice/libidevice_ffi.a in StikJIT's
   repository, with the Rust crates idevice is built on (tokio, rustls, AWS-LC through
   aws-lc-rs, curve25519-dalek and others) under MIT, Apache-2.0, BSD-3-Clause, ISC and other
   licences: each is listed with its licence texts in LICENSES-stikjit-idevice-crates.txt
   (from idevice's Cargo.lock at commit d32c8189c51c2789496b0768039419c3705498c3, which gives
   the crate versions found in that library).

2. On-device pairing, linked into the app as libhusk_rppairing.a
   Husk's src/rppairing-ios (commit 29abb512d81bf8cc08babcbe7f7007cb557208ef),
   https://github.com/Leviidev/Husk, GPL-2.0-or-later, over idevice 0.1.68 (MIT, see
   LICENSE-idevice-MIT.txt) and the Rust crates listed with their licences in
   LICENSES-rppairing-crates.txt.

The Swift code of Built-in JIT (the helper extension, the pairing and the setup) is ported
from Henge (commit 7b55730) and Husk, both GPL-2.0-or-later.

The JIT script henge-jit.js (in the app, run by the built-in helper or by StikDebug) is
StikDebug's universal.js (https://github.com/StephenDev0/StikDebug, StikDebug/Scripts/
universal.js) as adapted by Henge. That file has no licence header of its own; the StikDebug
repository is under the GNU Affero General Public License, version 3.

3D graphics: Frameworks/dxmt-native.framework is DXMT (https://github.com/3Shain/dxmt, GNU
Lesser General Public License, version 2.1 or later) as built for iOS by UTM
(https://github.com/utmapp/dxmt, its pin 66e27f3 or 8b9d334). It is modified by us after
building: scripts/patch_dxmt.py in the Apple VM repository changes 67 bytes so that a Metal
buffer that could not be created is skipped instead of written through (the script lists every
change). The source code of DXMT is available at the addresses above.
