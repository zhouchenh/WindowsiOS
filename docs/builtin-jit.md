# Built-in JIT

The emulator needs JIT. On iOS 26 and 27 (devices with the Trusted Execution Monitor, TXM, such
as the iPhone Duo) only an attached debugger can give an app executable memory, so a debugger has
to attach once each time Apple VM starts. Apple VM can do that in two ways:

- **StikDebug**: the StikDebug app attaches (Apple VM asks it through a `stikjit://` link).
- **Built-in**: a debugger shipped inside Apple VM does it. No StikDebug app and no computer.

Pick one in the JIT row of the start page: **Automatic** (Built-in once it is paired, StikDebug
until then), **StikDebug** or **Built-in**.

Built-in JIT is not JIT without a debugger: there is none on stock iOS 26/27. It is the debugger
moved into the app. Apple VM carries an app extension, `PlugIns/WinJITHelper.appex`, that runs
[StikJIT](https://github.com/StikDebug/StikJIT) (the debugger StikDebug is built on). When you tap
Enable, Apple VM starts the extension; StikJIT connects to this device's own debug service through
LocalDevVPN (or [your own VPN](#using-your-own-vpn-instead-of-localdevvpn)), attaches to Apple VM and runs Apple VM's JIT script (`henge-jit.js`), which hands out
the JIT memory and the guest RAM. Then the script detaches and the extension ends: nothing keeps
running in the background.

The design and most of the code come from [Henge](https://github.com/Leviidev/Henge) (0.3, commit
`7b55730`) and [Husk](https://github.com/Leviidev/Husk) (`29abb51`).

## What you need

- iOS 26 or later (on iOS 17 to 25 use StikDebug).
- **Developer Mode** on.
- A **pairing** of this device with Apple VM, made once. On iOS 27 Apple VM makes it on the device
  itself; otherwise import a pairing file.
- **[LocalDevVPN](https://apps.apple.com/app/id6755608044)** (free, App Store), connected when you
  enable JIT. StikJIT reaches the device's debug service at 10.7.0.1 through it. Or, instead, a VPN
  of your own whose server routes an address back to this device (see
  [Using your own VPN instead of LocalDevVPN](#using-your-own-vpn-instead-of-localdevvpn)).
- Wi-Fi for the pairing on the device. Enabling JIT needs Wi-Fi or Airplane Mode too: on cellular, iOS 27
  refuses the connection (see Troubleshooting). Once JIT is on it stays on until Apple VM is closed, whatever
  the network does afterwards.
- Apple VM installed **with its app extension** and signed with `get-task-allow`: by Xcode
  (docs/building.md, section 4b), or by SideStore/AltStore from the IPA. Not inside LiveContainer
  (below).

## Steps

Open the JIT row's **Built-in JIT setup…** (or choose Built-in and tap Enable: the setup opens
when something is missing).

1. **Developer Mode.** Settings › Privacy & Security › Developer Mode: turn it on and restart the
   device. Once.
2. **Pair (once).**
   - **iOS 27: Pair with Apple VM.** Tap **Pair on this iPhone**. Apple VM announces itself on the
     local network as a computer you can pair with (allow **Local Network** when iOS asks). Open
     Settings › Privacy & Security › Developer Mode and tap **Pair with Apple VM**. Settings asks
     for a code: Apple VM shows it in the app, in the background-task banner and as a
     notification. Type it in Settings. The setup then shows "Paired on this device". Apple VM
     waits up to 5 minutes; if iOS will not let it run in the background long enough (the setup
     says so), pair in Settings straight away.
   - **Or import a pairing file**: an RPPairing plist (keys `public_key`, `private_key`,
     `identifier`) made on a computer, for example with idevice's pairing tool or the
     [StikDebug pairing-file guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md).
     Tap **Import pairing file…**, or copy it with Finder or the Files app to
     `Apple VM/StikJIT/pairingFile.plist`.
   - **Already paired StikDebug?** Its pairing works for Apple VM too: tap **Import pairing
     file…**, then **Browse › On My iPhone › StikDebug › pairingFile.plist**. StikDebug keeps
     working; both use the same pairing. (In the file picker, Browse is quicker than Recents,
     which can take a long time to load on cellular.)

   The pairing file stays in Apple VM's Documents and is only ever passed to its own helper. Each
   new pairing with Apple VM replaces the previous one on the device (pairings of StikDebug, Henge
   and others are separate).
3. **Connection.** **LocalDevVPN** (the default): install it and connect it (the setup's
   **Connect** button opens it and comes back to Apple VM). Or **My VPN**: see
   [below](#using-your-own-vpn-instead-of-localdevvpn).
4. **Prepare.** Checks that the device answers through LocalDevVPN (or your VPN) and mounts the Developer Disk
   Image, downloading it the first time. Needed again after each restart of the device, but Enable
   does it by itself, so this step is mainly a check. **Reset Developer Disk Image cache** helps
   when a download went wrong.
5. **Enable JIT.** The helper attaches; the start page shows JIT as enabled, usually within a few
   seconds (longer the first time, while the disk image is downloaded). Then start Windows.

**Turn on JIT when the app opens** (start page and setup) does step 5 by itself at each launch:
with Built-in chosen and paired, Apple VM connects LocalDevVPN first if it is off, then enables JIT
(with My VPN, it does not touch LocalDevVPN: connect your VPN yourself, or have it connect on demand).

## Using your own VPN instead of LocalDevVPN

iOS runs one VPN at a time, so LocalDevVPN and your usual VPN (WireGuard, say) push each other off.
Built-in JIT needs LocalDevVPN for one thing only: StikJIT has to reach this device's RemotePairing
service through a network interface (iOS does not answer it on loopback), and LocalDevVPN is a tunnel
that sends 10.7.0.1 straight back into the device. Any VPN whose **server sends some address back to
this device** does the same job: a hairpin, or "reflector".

How it goes, with the device's VPN address `T` and a reflector address `R`:

1. StikJIT, on the device, connects to `R`. `R` is routed into the VPN (it is in the tunnel's
   AllowedIPs, or the tunnel takes all traffic), so the packet goes to the server.
2. The server rewrites the destination `R` to `T` (DNAT), and the source to one of its own addresses
   (SNAT or masquerade), and sends the packet back down the same tunnel.
3. The packet comes into the device through the VPN's interface, addressed to `T`: RemotePairing
   answers it, and the reply goes back the same way. The source rewrite matters: without it the
   packet would come back from the device's own address `T`, and the device would answer itself
   without going through the tunnel.

The server must forward **every port** of `R`, not one: RemotePairing's port changes at each restart
of the device, and the session opens a second port for its tunnel.

**In Apple VM**: Built-in JIT setup › **3. Connection** › **My VPN**, and enter `R` (an IPv4 or IPv6
address, with or without brackets). With your VPN connected, tap **Test connection**: it connects to
`R` and sends RemotePairing's opening handshake, which needs no pairing, and once paired it also opens
a session. It says which step failed: no connection at all (VPN off, `R` not routed into it, or the
server not reflecting), connected but RemotePairing did not answer (the connection was closed, nothing
came back, or another service replied), or RemotePairing answered and the session failed (the details
say how; "tunnel port could not be reached" means the server forwards only some ports). Then **Prepare**
and **Enable** as usual. The JIT row shows whether a VPN is up instead of LocalDevVPN's state, and
Apple VM never opens LocalDevVPN in this mode. StikDebug is unaffected: it is a separate app with its
own setting.

### Server examples

These use documentation addresses: replace them with yours. The VPN is WireGuard on interface `wg0`
of a Linux server whose own tunnel address is `10.66.0.1`; the device's tunnel address is `10.66.0.2`.

**IPv4 reflector**: `R` = `10.66.1.2`, an address of a range no one uses, sent back to the device.
The device's WireGuard peer must route `R` into the tunnel and accept the reflected packets, whose
source is the server's masquerade address `10.66.0.1`: WireGuard drops a packet whose source is not in
the peer's AllowedIPs. So AllowedIPs includes both `10.66.1.2/32` and `10.66.0.1/32` (or
`10.66.0.0/16`, or `0.0.0.0/0`). With nftables:

```
table ip jit_reflector {
    chain prerouting {
        type nat hook prerouting priority dstnat;
        iifname "wg0" ip saddr 10.66.0.2 ip daddr 10.66.1.2 dnat to 10.66.0.2
    }
    chain postrouting {
        type nat hook postrouting priority srcnat;
        oifname "wg0" ip daddr 10.66.0.2 ct status dnat masquerade
    }
}
```

or with iptables:

```
iptables -t nat -A PREROUTING -i wg0 -s 10.66.0.2 -d 10.66.1.2 -j DNAT --to-destination 10.66.0.2
iptables -t nat -A POSTROUTING -o wg0 -d 10.66.0.2 -m conntrack --ctstate DNAT -j MASQUERADE
```

The server must forward IPv4 (`net.ipv4.ip_forward=1`) and its firewall must allow `wg0` to `wg0`.
`ip saddr` / `-s` keeps the reflector for that device alone: no one else reaches its RemotePairing
service through it (which would still need the pairing). Several devices take one reflector address
and one rule each.

**IPv6 reflector (NAT66)**: the simplest when the device has a global IPv6 address in the VPN, and
tested: Test connection reaches RemotePairing through it and opens a session. Three addresses of the VPN's prefix: the device's own
`T` = `2001:db8:0:1::abcd`, the reflector `R` = `2001:db8:0:2::abcd` and a source `S` =
`2001:db8:0:3::abcd`, for example the same interface identifier in three /64s. `R` and `S` are not
assigned to anything: the server rewrites `R` to `T` before routing and puts `S` on the packets it
sends back. The device's peer must route `R` into the tunnel and accept `S` as a source (both in
AllowedIPs, or `::/0`). With nftables:

```
table ip6 jit_reflector6 {
    chain prerouting {
        type nat hook prerouting priority dstnat;
        iifname "wg0" ip6 saddr 2001:db8:0:1::abcd ip6 daddr 2001:db8:0:2::abcd dnat to 2001:db8:0:1::abcd
    }
    chain postrouting {
        type nat hook postrouting priority srcnat;
        oifname "wg0" ip6 daddr 2001:db8:0:1::abcd ct status dnat snat to 2001:db8:0:3::abcd
    }
}
```

or with ip6tables:

```
ip6tables -t nat -A PREROUTING -i wg0 -s 2001:db8:0:1::abcd -d 2001:db8:0:2::abcd -j DNAT --to-destination 2001:db8:0:1::abcd
ip6tables -t nat -A POSTROUTING -o wg0 -d 2001:db8:0:1::abcd -m conntrack --ctstate DNAT -j SNAT --to-source 2001:db8:0:3::abcd
```

`masquerade` / `-j MASQUERADE` in place of the SNAT works too, with the server's own IPv6 address on
`wg0` as the source (the device's peer must then accept that one). The server must forward IPv6
(`net.ipv6.conf.all.forwarding=1`) and allow `wg0` to `wg0`. In Apple VM, enter `R`.

**IPv6 reflector to the device's IPv4 address (NAT64)**: useful when the device has a global IPv6
address in the VPN and you would rather not spend IPv4 addresses. `R` is an IPv6 address routed to the
server, for example one in a second /64 of the VPN's prefix with the device's interface identifier
(device `2001:db8:0:1::abcd`, reflector `2001:db8:0:2::abcd`), and the server translates it to the
device's IPv4 tunnel address `10.66.0.2`, with the source translated to the server's IPv4 address on
`wg0`.

A fixed IPv6-to-IPv4 mapping per address like this is stateless translation with an explicit address
mapping table (SIIT with EAM, RFC 7757), not stateful NAT64: a stateful NAT64's pool can only take the
IPv4 address from the last 32 bits of its prefix (below). The device's own IPv6 source needs a mapping
too, to an unused IPv4 address such as `10.66.2.2`, which the masquerade then turns into the server's
address. A sketch, to check against your translator's documentation:

- Jool in SIIT mode (Jool's documentation recommends its own network namespace when the same server
  also does NAT):
  `jool_siit eamt add 2001:db8:0:2::abcd/128 10.66.0.2/32` and
  `jool_siit eamt add 2001:db8:0:1::abcd/128 10.66.2.2/32`.
- TAYGA: `map 10.66.0.2 2001:db8:0:2::abcd` and `map 10.66.2.2 2001:db8:0:1::abcd` (or a
  `dynamic-pool` for the sources), with `R` and `10.66.2.2` routed to TAYGA's interface.
- Then a NAT44 masquerade of the translated packets towards the device, for example
  `oifname "wg0" ip saddr 10.66.2.2 ip daddr 10.66.0.2 masquerade` in the postrouting chain above
  (`ct status dnat` does not match them: the translator, not conntrack, rewrote the destination).

The server must forward IPv6 as well as IPv4 (`net.ipv6.conf.all.forwarding=1`).

With a stateful NAT64 (Jool's NAT64 mode with pool6 and pool4, for example) instead of a per-device
address, `R` is the device's IPv4 address embedded in the translator's IPv6 prefix (RFC 6052): with
the prefix `2001:db8:64::/96`, `R` is `2001:db8:64::a42:2` (`2001:db8:64::10.66.0.2`), and the source
becomes a pool4 address. Either way the device's peer must route `R` into the tunnel (AllowedIPs
includes it, or `::/0`) and accept the IPv4 source the reflected packets arrive with (the server's
`10.66.0.1/32`, or the pool4 address).

### Caveats

- The VPN must be connected and its server reachable whenever you enable JIT, and every packet
  between StikJIT and RemotePairing goes to the server and back: Prepare and Enable take longer than
  with LocalDevVPN, and the first Prepare after a restart of the device, which sends the Developer
  Disk Image to it, moves that image to the server and back (mobile data on cellular).
- Pairing is unchanged: one time, on the device or from a file, over Wi-Fi and the local network, not
  through the VPN.
- That iOS answers RemotePairing on a VPN's interface is not yet proven on every iOS version: if Test
  connection says it connected but RemotePairing did not answer, use LocalDevVPN.
- Apple VM's helper logs each step as `[WinJITHelper] stage: ...` in the device console (the address
  family and the port, not the address or the pairing).

## Limits

- **LiveContainer**: a copy of Apple VM running inside LiveContainer cannot start its app
  extension, so Built-in JIT is unavailable there (the setup says so). Use StikDebug, or install
  Apple VM directly with SideStore or AltStore.
- **SideStore, AltStore, SideInstaller and other signing tools must keep app extensions.** If yours
  asks, choose to keep them. If the extension is removed, the setup says the helper is missing.
- **Free Apple ID**: the extension has its own bundle id (`<Apple VM's id>.JITHelper`), so it uses
  a second App ID. Free accounts can register 10 App IDs per 7 days, and apps still expire after
  7 days.
- **Signing without `get-task-allow`** (a distribution certificate, some signing services): no
  debugger can attach. The setup says so.
- **LocalDevVPN** is a third-party app. Built-in JIT does not work without it, or without your own
  VPN set up as a reflector (above). Another VPN that routes 10.7.0.1 back to this device works too,
  with the **My VPN** setting and `10.7.0.1` as the address. The LocalDevVPN setting counts only a
  tunnel with an address in 10.7.0.0/16 as connected, and otherwise opens LocalDevVPN when it is
  installed, which disconnects the other VPN.
- On-device pairing uses iOS 27's device-initiated pairing, which Apple does not document; an iOS
  update could change it. Importing a pairing file, or StikDebug, keeps working then.

## Troubleshooting

- **"Apple VM couldn't reach this device"**: LocalDevVPN is not connected or not routing. Connect
  it, turn off other VPNs (Tailscale and the like), then try again.
- **My VPN: "couldn't connect to this device through your VPN"**: the VPN is off, the reflector
  address is not routed into it, the server does not reflect it, or the device's AllowedIPs lack the
  address the reflected packets come from. **"Connected through your VPN, but RemotePairing did not
  answer"**: the server reflects, but iOS closed the connection or did not answer RemotePairing there
  (or the port is another service): use LocalDevVPN.
- **On cellular only**, enabling JIT fails, with LocalDevVPN and with your own VPN alike: on an iPhone
  with iOS 27 (tested on 27.2.1), iOS refuses connections to its own services (RemotePairing, lockdownd)
  when the VPN's tunnel runs over the mobile network, the same way it treats a listener that refuses
  cellular. What works without Wi-Fi: turn on **Airplane Mode** (Wi-Fi stays off), connect LocalDevVPN,
  enable JIT, then turn Airplane Mode off again: JIT stays on until Apple VM is closed. Joining any Wi-Fi
  (a hotspot works) also works. (Turning only Cellular Data off has not been tested.) Apple VM still
  retries an unreachable device twice on cellular, which helped on earlier iOS versions.
- **"This device closed the connection"**: the device no longer accepts the pairing (it was
  replaced by a newer pairing, or reset). Pair again.
- **"needs Local Network access"**: Settings › Apps › Apple VM › Local Network.
- **The helper does not attach within 150 seconds**: run Prepare to see what fails.
- The app's log (Xcode console, or `scripts/launch_on_duo.sh`) has `[winios-jit]` lines for each
  step; the helper logs as `[WinJITHelper]` in the device console.

## How it is built

`scripts/build_jit_deps.sh` (also run by `scripts/build_ios_deps.sh`) builds two dependencies
from source into the gitignored `ios/deps`:

- `StikJIT.xcframework`: StikJIT 1.9.0 (tag checked against commit `32287268`) with
  `ios/patches/stikjit-high-address.patch` (Henge's `ci/stikjit-high-address.patch`: page
  addresses in its `$M` packets get 16 hex digits instead of 9) and then
  `ios/patches/stikjit-ipv6-address.patch` (ours: the device address may be IPv6, which StikJIT
  passed to idevice as IPv4 only; for My VPN). The framework is rebuilt when either patch changes.
  MPL-2.0; it contains idevice (MIT)
  as the prebuilt `libidevice_ffi.a` that StikJIT's repository ships, with the Rust crates idevice
  is built on (tokio, rustls, AWS-LC through aws-lc-rs, and others). StikJIT does not say which
  idevice commit that library is; the crates in it are those of idevice's `Cargo.lock` at
  `d32c818` (0.1.68), and the script generates their notices from it and checks them against the
  library (the provenance note in `scripts/build_jit_deps.sh` says how that commit was found).
- `lib/libhusk_rppairing.a`: Husk's `src/rppairing-ios` (commit `29abb51`, GPL-2.0-or-later), a
  small Rust wrapper of idevice 0.1.68's `PairableHost`, for on-device pairing. Built with rustup's
  toolchain for `aarch64-apple-ios` (`rustup target add` is done for you). Its C interface is
  `ios/Sources/Native/HuskRPPairing.h`.

The Xcode project (`ios/project.yml`) has the `WinJITHelper` app-extension target (iOS 26+,
`ios/WinJITHelper/`, signing from `ios/WinJITHelper.xcconfig`), which links StikJIT; the app's
**Embed StikJIT** build phase puts the framework into `Frameworks/`. The app's side is
`ios/Sources/BuiltInJIT.swift` (starting the helper, the pairing file, the port lookup),
`BuiltInJITPairing.swift` (on-device pairing), `BuiltInJITView.swift` (the picker and the setup)
and `JITSetup.swift` (the requests, shared with StikDebug). The JIT protocol on Apple VM's side
(`winios_jit.c`, `winios_brk.S`, `henge-jit.js`) is the same as for StikDebug.

The licences that ship in the app are in `ios/Sources/Resources/legal` (the app's `legal/` folder):
the GPL-2.0 and GPL-3.0 texts (the app's binaries contain Apache-2.0 code, so they are distributed
under GPL-3.0; `legal/README.txt` says why), StikJIT's MPL-2.0 with our patches, idevice's MIT
licence, and the licence notices of every Rust
crate in StikJIT's idevice library (`LICENSES-stikjit-idevice-crates.txt`) and in the pairing
library (`LICENSES-rppairing-crates.txt`). See also `THIRD_PARTY_NOTICES.md`.
