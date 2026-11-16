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

The guest cannot be reached from outside, but single TCP ports can be forwarded into it:

- **`PUT http://10.0.2.4/.henge/expose-port`** from the guest (the OAuth bridge does this, see
  [oauth-bridge.md](oauth-bridge.md)) calls `hv_net_add_hostfwd`: a libslirp host forward
  `127.0.0.1:<port> → 10.0.2.15:<port>`, plus a small bridge that listens on `[::1]:<port>` and
  connects to `127.0.0.1:<port>`. Ports 1024 to 65535 only.
- **`HV_NET_FWD=<host port>:<guest port>`** (debugging) adds one such IPv4 forward at start-up.

These listen on the iPhone's loopback only, so only apps on the iPhone itself (Safari, for the
OAuth redirect) can connect. They always reach the guest's IPv4 address `10.0.2.15`, with IPv6
on or off: a guest service has to listen on IPv4 (`0.0.0.0`, or a dual-stack `[::]` socket, as
most Windows services do). A service that listens only on the guest's IPv6 addresses is not
reachable through a forward. libslirp could forward to the guest's IPv6 address
(`slirp_add_hostxfwd`), but Windows picks that address itself (random interface IDs, temporary
addresses), so this is left out. Turning IPv6 on changes nothing for forwards.

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

- **LAN-bound forwards.** A forward could listen on the iPhone's Wi-Fi address (or `0.0.0.0`)
  instead of loopback, so other devices on the LAN reach `<iPhone's address>:<port>` and land in
  the guest. iOS would ask for the *Local Network* permission (the app would need
  `NSLocalNetworkUsageDescription` in its Info.plist), and the address changes with the network.
  Not implemented: today's forwards are loopback-only by design.
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
| `HV_NET_FWD` | none | `<host port>:<guest port>`: one more forward from the host's `127.0.0.1` into the guest. |

## Tests

- `make test-dns`: the DNS proxy's session handling, and its parser and reply builder under the
  address and undefined-behaviour sanitizers, with malformed, oversized and randomly damaged IPv4
  and IPv6 queries and router advertisements.
- `make test-net` (macOS, needs Homebrew's `libslirp`): `host/net_slirp.c` and the DNS proxy
  over the real libslirp, with stand-ins for the virtio-net device and the system resolver.
  Router and neighbour discovery, DNS over IPv6 and IPv4, a refused and an unroutable IPv6
  connection failing at once, DHCP and ARP, and the same with `HV_IPV6=0` and `HV_DNS_PROXY=0`.
  No network needed.
