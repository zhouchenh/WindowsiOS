# Networking: how the guest reaches the network

Windows (or Linux) in the VM has one network card, a virtio-net device (`devices/virtio_net.c`;
Windows needs the NetKVM driver from WinKit). Behind it there is no real network interface. The
app runs a small user-mode network stack, [libslirp](https://gitlab.freedesktop.org/slirp/libslirp)
(the same one QEMU uses for `-netdev user`), which turns the guest's packets into ordinary
iOS socket calls. It needs no root, no entitlement and no VPN profile. The code is in
`host/net_slirp.c` and `host/dns_proxy.c`. The same code runs in the Mac tool (`build/winvm`).

## The NAT model

The guest sits alone on a private network, with libslirp as its router:

- **Outgoing connections work.** When the guest opens a TCP connection or sends a UDP datagram to
  the internet, libslirp opens a socket on the iPhone to the same address and port and relays the
  data. To the rest of the world the traffic comes from the iPhone (its Wi-Fi or cellular
  address), as with any app.
- **Incoming connections do not**, unless a port is forwarded (see [Port forwards](#port-forwards)).
  Nothing on the LAN or the internet can reach the guest's own address.
- **The host's loopback is reachable.** The gateway address (`10.0.2.2`, and every IPv6 address in
  the guest's prefix except the DNS server) maps to the iPhone's own loopback (`127.0.0.1` and
  `[::1]`), so the guest can reach services that other apps on the iPhone run on `localhost`.
- **Ping** to the outside is emulated by libslirp; ICMP other than echo is not relayed.

libslirp is not thread-safe, so it runs on its own thread with its sockets and timers. Frames the
guest sends are queued to it; frames for the guest are queued back and handed to the virtio-net
device on the CPU thread when the guest has posted receive buffers.

## Addresses

| | IPv4 | IPv6 |
| --- | --- | --- |
| Network | `10.0.2.0/24` | `fd2d:7064:6c3f:2::/64` |
| Gateway (libslirp, the iPhone's loopback) | `10.0.2.2` | `fd2d:7064:6c3f:2::2`, link-local `fe80::2` |
| DNS server | `10.0.2.3` | `fd2d:7064:6c3f:2::3` |
| Shared folder, clipboard, OAuth bridge (`host/share.c`) | `10.0.2.4`, port 80 | none (IPv4 only) |
| Guest | `10.0.2.15`, by DHCP | by SLAAC: the prefix plus an interface ID Windows picks (random by default), and temporary addresses |

**IPv4** is configured by DHCP from libslirp: address `10.0.2.15`, gateway `10.0.2.2`, DNS
`10.0.2.3`.

**IPv6** (on unless `HV_IPV6=0`) is configured by stateless autoconfiguration. Checked against
libslirp 4.9.1's source (`ip6_icmp.c`, `dhcpv6.c`):

- libslirp answers a Router Solicitation at once with a Router Advertisement, and sends one
  unsolicited every 200 to 600 seconds. It carries the prefix `fd2d:7064:6c3f:2::/64` with the
  on-link and autonomous flags (the guest forms its own addresses: SLAAC) and a router lifetime of
  1800 seconds (a default route through libslirp).
- The *managed* and *other configuration* flags are clear, so the guest asks no DHCPv6 server
  (libslirp would only answer an Information-Request with the DNS server anyway).
- The DNS server comes in the advertisement's RDNSS option (RFC 8106, which Windows 10 1703 and
  later read). libslirp adds that option only when the host's resolver configuration lists an IPv6
  name server. While the DNS proxy is on, the app adds it to advertisements that lack it
  (`hv_dns_proxy_announce`), so the guest always learns `fd2d:7064:6c3f:2::3`. It also has
  `10.0.2.3` from DHCP either way.
- libslirp answers neighbour discovery for the gateway and DNS addresses.

**Why this prefix.** It is a unique local address prefix (RFC 4193): `fd`, then a 40-bit global
ID chosen at random (`2d:7064:6c3f`), then subnet `2` to echo `10.0.2.x`. A random global ID makes
a clash with a real network the iPhone is on practically impossible. libslirp's own default,
`fec0::/64`, is the deprecated site-local range (RFC 3879), and short hand-picked prefixes such
as `fd00::/64` are what many home routers use for their own LAN, which would hide those LAN
addresses from the guest.

**Which protocol Windows uses.** The guest's only IPv6 addresses are unique local ones. Under the
default address selection rules (RFC 6724, rule 5: prefer a source whose label matches the
destination's), Windows prefers IPv4 for every name that has both an A and an AAAA record, as it
would behind any IPv4 NAT. IPv6 is used for destinations that only have IPv6, and for IPv6
literals. Through libslirp those connections leave the iPhone as its own IPv6 connections.

**When the iPhone has no IPv6.** If the iPhone's network has no IPv6 route, libslirp's
`connect()` or `sendto()` on the iPhone fails at once. libslirp then answers the guest at once: a
TCP SYN gets an ICMPv6 *destination unreachable* (an RST when the connection is refused), and a
UDP datagram gets an ICMPv6 *destination unreachable* (`tcp_input.c`, `udp6.c`). Guest
connections fail fast instead of waiting for a timeout, and since Windows prefers IPv4 for
dual-stack names anyway, nothing has to fall back. The reverse holds on an IPv6-only network
with NAT64: where the iPhone has no IPv4 path (no 464XLAT), IPv4 connections fail at once the same
way, and names the network's DNS64 answers with synthesized AAAA records stay reachable over the
guest's IPv6.

**Limits of libslirp's IPv6.** Packets with extension headers (hop-by-hop, routing, fragments,
destination options) are dropped: libslirp only handles TCP, UDP and ICMPv6 right after the
fixed header. Packets bigger than the 1500-byte MTU get an ICMPv6 *packet too big*.

## DNS

The guest's DNS server (`10.0.2.3`, or `fd2d:7064:6c3f:2::3`) is answered by the app itself,
not by a name server libslirp picks (`host/dns_proxy.c`, from Henge):

- Each UDP query becomes a `DNSServiceQueryRecord` call: the resolver every iOS and macOS app
  uses. It knows the whole DNS configuration of the iPhone (Wi-Fi or cellular, a VPN's split DNS,
  per-interface resolvers, DNS64 on IPv6-only networks) and its caches.
  The answer goes back to the guest as the frame the DNS server would have sent.
- Over IPv6 only the plain form is taken: UDP right after the fixed header, a payload length the
  frame holds and that is exactly the UDP datagram, and a correct UDP checksum. The answer carries
  its own UDP checksum, as IPv6 requires.
- Left to libslirp (which forwards them to the host's first name server of the same family, or
  answers with ICMP unreachable if there is none): DNS over TCP, queries the proxy does not parse
  (anything but one question, an optional EDNS record, class IN; zone transfers), IPv6 frames
  that are not in the plain form above, `.local` names and reverse lookups of link-local
  addresses (asking for those on iOS would bring up the local network privacy prompt).
- If the system resolver leaves 8 lookups in a row unanswered, the proxy gives up for the rest of
  the session and libslirp answers from then on.

## Port forwards

The guest cannot be reached from outside, but ports can be forwarded into it: a forward takes
connections (TCP) or datagrams (UDP) on a port of the iPhone and hands them to a port of the guest's
`10.0.2.15`. In the app they are in **Settings > Port forwarding**
(`ios/Sources/PortForwardingView.swift`); the engine is in `host/net_slirp.c` ("port forwards").

**A forward** is a rule: a name, the protocol (TCP, UDP or both), the port on the iPhone, the port
in Windows, who can connect, and on or off. Who can connect:

| Scope | Listens on | Who reaches it |
| --- | --- | --- |
| This iPhone only | `127.0.0.1` and `[::1]` | apps on the iPhone (a Remote Desktop app connecting to `localhost`, Safari for OAuth redirects) |
| Local network | the addresses of the Wi-Fi, wired and Personal Hotspot interfaces (`en…`, `bridge…`): IPv4, IPv6 unique local (`fc00::/7`) and IPv6 global, never link-local; followed as they change, plus `127.0.0.1` and `[::1]` | devices on the same Wi-Fi or wired network and on the iPhone's Personal Hotspot, over IPv4 and IPv6; not cellular (`pdp_ip…`). A global IPv6 address may be reachable from the internet where the router lets incoming IPv6 through: each forward has an **IPv6 global addresses** choice (on by default; `"ipv6Global": false` in the file), and `HV_NET_LAN_GLOBAL6=0` leaves them out of every forward |
| VPN | every usable address of the active VPN interface (`utun…`, `wg…`, `tun…`, `ppp…`, `ipsec…`, in that order of preference): its IPv4 addresses and its IPv6 ones, unique local and global, never link-local | devices on the VPN (WireGuard and similar), over IPv4 and IPv6 |

- **IPv4** is libslirp's own host forward (`slirp_add_hostfwd` / `slirp_remove_hostfwd`). The guest
  sees loopback clients as `10.0.2.2` and other clients with their own address.
- **IPv6**: libslirp cannot take an IPv6 connection to the guest's IPv4 address, so a small relay of
  the app's own listens on `[::1]`, the local network's IPv6 addresses or the VPN's and hands each TCP connection,
  and each UDP peer's datagrams (one IPv4 socket per peer, idle peers dropped after 2 minutes), to the
  IPv4 listener (the VPN's IPv4 address, or `127.0.0.1` for a VPN without IPv4). Those clients appear in the
  guest as `10.0.2.2`. At most 8 addresses of each family per forward.
- **Each family on its own**: the list shows every address a forward listens on, and for IPv4 and IPv6
  separately whether it listens, failed (with the reason), or has no address of its own right now (`none`: "the
  VPN has no IPv6 address", "no IPv6 address on the local network"; loopback still listens). An IPv6 address that
  cannot be opened leaves the others and IPv4 open; IPv4 failing closes the forward (the relays need its listener).
- Forwards always reach the guest's IPv4 address, with `HV_IPV6` on or off: a guest service has to
  listen on IPv4 (`0.0.0.0`, or a dual-stack `[::]` socket, as most Windows services do). libslirp
  could forward to the guest's IPv6 address (`slirp_add_hostxfwd`), but Windows picks that address
  itself (random interface IDs, temporary addresses), so this is left out.
- **The VPN** is the VPN interface that is up with an IPv4 address that is not link-local, else one
  with a unique local IPv6 address (`fc00::/7`), else a `utun`, `wg`, `tun` or `ppp` one with a global
  IPv6 address, preferring `utun`, `wg`, `tun`, `ppp`, then `ipsec`; the forward listens on all of its
  usable addresses (so a WireGuard VPN that gives the iPhone a global IPv6 address is reachable over IPv6
  too). iOS's own `utun` interfaces only have link-local IPv6 addresses, and the carrier's tunnels for
  Wi-Fi Calling and VoLTE (`ipsec…` with a global IPv6 address from the carrier and no IPv4) are no VPN
  the user connected: both are passed over. It is looked up again every 3 seconds while a VPN forward exists,
  and when the app's network monitor sees a change; a forward with no VPN connected waits ("no VPN")
  and opens when one comes. This works with VPNs that hand packets to iOS (the WireGuard app); a VPN
  app that runs its own network stack in user space never delivers incoming connections to other
  apps. The local network scope does not cover the VPN: it listens on the local network's own addresses
  only (looked up again every 3 seconds), never on every interface.
- **Changes** may come from any thread; the network thread applies them, closing what changed before
  opening anything, so an edited forward never finds its own old listener in the way. A port another
  app holds is reported per forward (`in_use`; also `denied`, `no_address`, `no_vpn`) and tried again
  every 3 seconds. Two enabled forwards cannot share a port and protocol: the second is refused.
- **Foreground only, unless Server mode.** Without it, iOS suspends the app in the background and
  Windows pauses with it, so nothing answers then. With **Server mode** (below) and no host 3D, Windows
  keeps running in the background and the forwards keep answering. iOS may take a suspended app's
  listening sockets away: the app opens every forward again when it returns to the foreground
  (`hv_net_fwd_reopen`).
- **Local Network permission.** Listening on the local network is what iOS's *Local Network* privacy
  covers. The app declares `NSLocalNetworkUsageDescription`; when a local network forward is on, the
  settings browse for a Bonjour type of the app's own (`_applevm._tcp`, never advertised) to bring up
  iOS's prompt and to learn whether it was refused, and then show how to turn it on.

**Saved per machine.** The forwards made in the app are kept in `port_forwards.json` in the
machine's folder (`Documents/Machines/Win11/`, or the Arch one) and opened when the machine's
network starts. The file is JSON: `{"version": 1, "rules": [{"id", "name", "protocol": "tcp" |
"udp" | "tcp+udp", "hostPort", "guestPort", "scope": "loopback" | "lan" | "vpn", "ipv6Global"
(only written when false), "enabled"}]}`. A file that cannot be read is renamed to
`port_forwards.json.bad` and the list starts empty.

**Session forwards** are not saved and last until the app quits; they show up in the same list:

- **`PUT http://10.0.2.4/.henge/expose-port`** from the guest (the OAuth bridge does this, see
  [oauth-bridge.md](oauth-bridge.md)) calls `hv_net_add_hostfwd`: TCP, this iPhone only, the same
  port on both sides, ports 1024 to 65535. So does a `localhost:<port>` in a URL the guest asks the
  app to open.
- **`/.henge/forwards`** at `10.0.2.4`: `GET` lists every forward with its state (the JSON of
  `hv_net_fwd_list_json`). `PUT` or `POST` `{"protocol": "tcp", "hostPort": 8080, "guestPort": 80}`
  adds one, always *this iPhone only* and from port 1024: the guest never opens a port to the
  network, that is the user's choice in the app. `DELETE ?id=…` removes one the guest added.
- **`HV_NET_FWD`** (`Documents/env.txt`) adds TCP forwards at start-up, comma-separated:
  `<host port>:<guest port>` (this iPhone only), `lan:<host port>:<guest port>` (local network),
  `vpn:<host port>:<guest port>` (VPN). `a.b.c.d:<host port>:<guest port>` listens on that one IPv4
  address, as a plain libslirp forward outside the list.

**In Windows** the service has to run and its firewall has to let the port in. WinKit has scripts
for this (on the WINKIT drive and in `C:\WinKit`; `winkit/README.md` explains them in Chinese):
`REMOTE-DESKTOP.bat` (`enable_rdp.ps1`: the Remote Desktop host, which only Pro, Enterprise and
Education have, with Network Level Authentication, and TCP and UDP 3389 open; `-Uninstall` puts
the previous setting back; Windows refuses Remote Desktop sign-ins to an account with a blank
password, so the script checks for one and asks the person to set a password, never setting one
itself) and `SSH-SETUP.bat` (`ssh_setup.ps1`: an OpenSSH server with key login
only and TCP 22 open; `uninstall_ssh.ps1` removes it). The firewall rules allow every profile and
every remote address, since clients through a forward keep their own address, which Windows would
not count as its local subnet.

## Server mode

**Settings > Network > Server mode** (also in the session's **More** menu) keeps Windows running while
the app is in the background or the phone is locked, so Remote Desktop and the other forwards keep
answering, from other devices or from a Remote Desktop app on the same iPhone (`127.0.0.1` / `[::1]`).
The code is `ios/Sources/ServerMode.swift` and the bridge's server mode (`winios_bridge.m`).

- **How**: iOS keeps an app with background audio (`UIBackgroundModes: audio`) running while its audio
  plays. The bridge keeps the HDA output unit running when Windows plays nothing (silence;
  `hv_audio_set_keepalive` in `host/audio_mac.c`, made at 2 ch / 48 kHz when Windows has no stream). It is
  started again when an interruption ends, after a media services reset (made again), and whenever the
  app comes back to the front (an interruption may never report its end); it is cleared when Windows
  stops. The session mixes with other apps, so there is no Now Playing entry. While Windows runs in the
  background the microphone is closed (no indicator). Going to the background takes a short
  `beginBackgroundTask` grace; disks are flushed on the way, on every memory warning and every ~32 s
  (the diagnostics timer).
- **Only without host 3D**: iOS refuses GPU work from background apps, and the 3D path
  (virglrenderer, ANGLE, DXMT on Metal) needs it. The bridge lets Windows run in the background only
  while no 3D is in use or offered and no debugger is attached (`backgroundBlocker`); otherwise it pauses
  as before. **Graphics: 3D / 2D** switches without restarting Windows (below), so "Switch to 2D now
  (Windows keeps running)" is the way into server mode; "Restart Windows without 3D" is the fallback (2D
  is offered and Windows restarts; the 3D setting stays on for the next start of the app).
- **Headless** shows an info card instead of the picture: the Metal layer is unbound (the presenter
  stops) and the display plan is frozen, so Windows keeps its resolution. **Keep the screen on** is off
  by default in server mode: the locked phone is just "the background".
- **Guard**: at a critical thermal state or a critically low battery (5%, unplugged) Windows is paused
  (its own flag, apart from the background pause) and a local notification is posted; it goes on by
  itself once the phone has cooled down (or charges) and the app is in front, or with Resume. Low Power
  Mode and the thermal state are shown in the panel.
- **Remote Desktop helper**: the forward to Windows' RDP port (3389 unless changed) with a scope picker,
  "Turn on Remote Desktop in Windows" (a WinKit helper job running `C:\WinKit\REMOTE-DESKTOP.bat`, else the
  WINKIT drive's), the addresses to connect to (both families, with the port, and this iPhone's
  loopback), and **Test connection**: an X.224 Connection Request to the forward over IPv4 and over IPv6,
  which needs Windows' TPKT Connection Confirm back. A plain TCP connect would prove nothing: the forward
  listens in the iPhone's kernel, which completes the handshake even with Windows paused.
  `C:\WinKit\RETURN-TO-SCREEN.bat` (`tscon … /dest:console`) hands a Remote Desktop session back to the
  app's screen without signing in again.
- **What it cannot do**: start at boot, start without the app, or come back after iOS ends the app
  (jetsam, which picks a background app holding gigabytes first, or a swipe up). For Windows that is a
  power cut; its disks are safe (`pwrite` + `fsync`). A phone call or an app taking the audio for itself
  can suspend the app until the interruption ends. JIT stays while the app lives; after the app is ended
  it has to be enabled again in the foreground. Under LiveContainer the background modes are
  LiveContainer's own, so background running depends on it.

### Graphics: 3D / 2D without restarting Windows

The display device (`devices/virtio_gpu.c`) offers `VIRGL` and the blob and context-init features (and
the capsets) only while the wanted mode is 3D (`hv_virtio_gpu_set_3d`). Device features are read at
every driver initialisation, so the next driver start negotiates the new mode. To start it, the app
writes `Shared/gpu_mode.txt` (`seq=<n>`, `mode=3d|2d`); WinKit's task **WinKit Graphics**
(`winkit/gpu_switch.ps1`, SYSTEM, installed by `START.bat`) restarts only the display adapter
(`pnputil /restart-device` on `PCI\VEN_1AF4&DEV_1050…`) and reports `Shared/gpu_mode_applied.txt`
(`result`, the device's status and problem code). The app waits for both the report and the driver's
renegotiation (a new driver reset, DRIVER_OK, VIRGL as wanted) and gives up after 60 s with what it
knows. A switch is refused while the app is in the background: leaving 3D tears the 3D state down on
the GPU.

- **Leaving 3D**: the driver's reset drops every 3D context and resource (`virgl_renderer_reset`) on the
  renderer's thread; the renderer itself, the hostmem window and its BAR stay, idle, so 3D can come back
  in the same run of the app: it is never torn down and made again. That thread only takes requests
  from a driver that negotiated `VIRGL`, and it only clears a picture that is still its own, so a 2D
  driver that started meanwhile keeps its scanout. A 2D driver after a switch is never taken for the
  firmware (the "firmware stage" guess needs at most one reset since the machine started).
- **Coming back to 3D** needs the renderer: only when Windows was started with host 3D (it keeps 2.5 GB
  of address space free for Metal then). A Windows started without 3D stays 2D until it is restarted
  with 3D on.
- **Risks** (shown in the app): the screen goes black for a few seconds; apps using 3D lose their
  graphics device (most recover, some crash); the known UTM Neptune context leak grows with each switch
  until the app restarts. Without host 3D, Windows' 3D driver may not start; Windows then uses its basic
  display (the screen may stay black; Remote Desktop renders on its own adapter and is not affected).
- Optionally (**Back to 3D when the app returns to the front**, off by default) the app switches back to
  3D by itself after a switch to 2D in this session.

## Why there is no bridged mode

A bridged network would put the guest on the iPhone's Wi-Fi as a device of its own, with its own
MAC and an address from the LAN's router. Desktop hypervisors do it with a privileged packet
interface; stock iOS gives an app none:

- **No `vmnet`.** `vmnet.framework` (what UTM and Virtualization.framework use on macOS for shared
  and bridged networks) does not exist on iOS.
- **No BPF, no raw link layer.** An app cannot open `/dev/bpf*`, raw sockets or `AF_NDRV`, so it
  can neither see other devices' frames nor send frames with another MAC address.
- **Network Extension does not help.** A packet tunnel provider gets IP packets (layer 3) for a
  VPN, not Ethernet frames on the Wi-Fi, and needs an entitlement and a VPN profile. There is no
  public API for layer-2 bridging or for a second MAC address on Wi-Fi.

So the guest stays behind NAT. A jailbroken device or a future iOS API would be needed for
anything else.

## Alternatives for reaching the guest

- **Local network and VPN forwards** ([Port forwards](#port-forwards)): another device reaches
  `<iPhone's address>:<port>` and lands in the guest, while the app is in the foreground. The
  iPhone's address changes with the network; a VPN gives it a steadier one.
- **An overlay VPN inside Windows.** Tailscale, ZeroTier, WireGuard and similar run inside the
  guest and only need outgoing UDP, which the NAT carries. The guest then has a stable address on
  the overlay network that your other devices can reach (RDP, SSH, file shares), from anywhere,
  with no change to the app.

## Settings

Set these as environment variables for the Mac tool, or as `KEY=VALUE` lines in
`Documents/env.txt` in the app's Documents folder on iOS (read when the machine starts; `#` starts
a comment). Restart the VM after changing them.

| Variable | Default | What it does |
| --- | --- | --- |
| `HV_IPV6` | on | `0`: IPv4 only, no IPv6 at all (no router advertisements, IPv6 frames from the guest are dropped). |
| `HV_DNS_PROXY` | on | `0`: libslirp answers DNS by forwarding to the host's first name server, and adds the IPv6 DNS server to its advertisements only if the host lists an IPv6 one. |
| `HV_NET_LOG` | off | Set: one line per frame in the log (addresses, ports, protocol), IPv4 and IPv6. |
| `HV_NET_FWD` | none | TCP forwards into the guest for this session, comma-separated: `<host port>:<guest port>` (loopback), `lan:…`, `vpn:…`, or `a.b.c.d:…` (see [Port forwards](#port-forwards)). |
| `HV_NET_FWD_FILE` | none (Mac) | The saved forwards' file for the Mac tool (on iOS it is the machine's `port_forwards.json`). |
| `HV_NET_FWD_RULES` | on | `0`: saved forwards are listed but not opened (session forwards still are). |
| `HV_NET_VPN_IF` | `utun,wg,tun,ppp,ipsec` | Which interfaces count as a VPN (name prefixes, comma-separated, preferred in this order). One with an IPv4 address or a unique local IPv6 address counts, else one with a global IPv6 address that is not `ipsec…`, so the carrier's Wi-Fi Calling / VoLTE tunnels (`ipsec…` with only a global IPv6 address) are not taken for a VPN. |
| `HV_NET_LAN_IF` | `en,bridge` | Which interfaces make up the local network: local network forwards listen on their addresses, and the settings show them. |
| `HV_NET_LAN_GLOBAL6` | on | `0`: no local network forward listens on the local network's global IPv6 addresses (each forward also has its own **IPv6 global addresses** choice). |

## Tests

- `make test-dns`: the DNS proxy's session handling, and its parser and reply builder under the
  address and undefined-behaviour sanitizers, with malformed, oversized and randomly damaged IPv4
  and IPv6 queries and router advertisements.
- `make test-net` (macOS, needs Homebrew's `libslirp`): `host/net_slirp.c` and the DNS proxy
  over the real libslirp, with stand-ins for the virtio-net device and the system resolver.
  Router and neighbour discovery, DNS over IPv6 and IPv4, a refused and an unroutable IPv6
  connection failing at once, DHCP and ARP, and the same with `HV_IPV6=0` and `HV_DNS_PROXY=0`.
  No network needed.
- `make test-net` also runs `test_net_fwd`: port forwards through libslirp to a stand-in guest that
  echoes TCP and UDP. A forward saved before start-up opens; TCP, UDP and both, over IPv4 and IPv6;
  remove, edit (moved port), off; the local network scope on loopback and this Mac's own LAN address
  when it has one, never on every interface (with no local network interface, the LAN address
  refuses); the VPN scope waiting for a VPN and following it (with `lo0` named as the VPN); a port
  in use reported, then opened once free; a second forward of a port refused; expose-port as a
  session forward; the guest's limits; reopening; the saved file, a damaged one, and
  `HV_NET_FWD_RULES=0`; names that are not UTF-8 or are cut inside a character; a machine's saved
  forwards loaded while session forwards hold their ports and slots; the IPv6 relay running out of
  descriptors; each family's state in the list and the `ipv6Global` choice (parsed, listed, saved).
- The address choice of every scope, over made-up interfaces (`tests/fake_ifaddrs.h`, documentation
  addresses only), in `test_net_fwd` and `test_net_ipv6`: the local network's IPv4, unique local and
  global IPv6 addresses (unique local first, at most 7 besides `[::1]`), never link-local, multicast,
  IPv4-mapped or cellular ones, global ones left out by the rule or `HV_NET_LAN_GLOBAL6=0`; the VPN's
  IPv4 and IPv6 addresses (a WireGuard VPN with all three kinds, one with only a unique local or only a
  global IPv6 address relayed through IPv4 loopback, the preference order), and what is passed over
  (iOS's link-local-only `utun`s, the carrier's `ipsec`).
- `make test-core` runs `test_gpu_mode` (the graphics hot switch: what each driver start is offered,
  the firmware-stage guess after a switch) and `test_audio_keepalive` (server mode's silent output over
  this Mac's own output unit).
