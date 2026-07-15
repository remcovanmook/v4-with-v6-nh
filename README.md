# v4-with-v6-nh

Reference implementation for
[draft-vanmook-intarea-ipv6-resolved-gateway](https://datatracker.ietf.org/doc/draft-vanmook-intarea-ipv6-resolved-gateway/):
IPv4 connectivity on IPv6-only network segments via the special-purpose
gateway address **192.0.0.11**, resolved from the IPv6 neighbor cache
instead of ARP. No IPv4 subnets, no tunnelling, no translation — IPv4
packets are carried natively, end to end.

## Layout

```
host/    v4gwd.py — Linux host daemon implementing draft Section 4
         (sentinel detection, RFC 4191 router selection, route
         programming via IPv6 next hop) + systemd unit;
         systemd-networkd/ — native networkd patch;
         freebsd/ — C daemon for FreeBSD 13.1+ (RFC 5549 data plane)
         with dhclient-exit-hooks and rc.d integration
lab/     network-namespace lab reproducing the Section 5.1 topology,
         with conformance tests (incl. a zero-ARP assertion);
         freebsd/ — equivalent vnet-jail lab
router/  vendor configuration examples for the Section 5 router side
         (RFC 8950 return-path routes, 192.0.0.11 termination, the
         unmodified-host ARP tier, and §5.2 forwarding enforcement)
         across five commercial platforms
docs/    conformance matrix: every normative statement in Sections 4–5
         mapped to code, kernel behaviour, or a documented gap
legacy/  the original 2024/25 mechanism this work grew out of
         (IPv4 default route follows the IPv6 default gateway) —
         retained as prior art; not draft-conformant
```

## Quick start

Requirements: Linux ≥ 5.2 (IPv4 routes with IPv6 next hops), Python 3,
pyroute2, iproute2, tcpdump.

```
pip install pyroute2

# bring up the four-namespace lab in DHCP-driven (sentinel) mode
sudo lab/topology.sh up --sentinel

# run the conformance tests
sudo lab/run-tests.sh

sudo lab/topology.sh down
```

On a real host with a DHCPv4 server handing out `192.0.0.11` as
Option 3 (router):

```
sudo host/v4gwd.py --require-sentinel eth0
```

or install `host/systemd/v4gwd@.service` and
`systemctl enable --now v4gwd@eth0`.

## How it maps to the draft

Linux natively resolves IPv4 routes with an IPv6 next hop through
Neighbor Discovery — never ARP. `v4gwd` uses this to implement the
draft's Section 4 host behaviour from user space: it detects the
192.0.0.11 sentinel, selects an IPv6 default router per RFC 4191,
installs `default via inet6 <router>`, tracks router-list and neighbor
cache changes over netlink, and withdraws its route when the sentinel
disappears (DHCPv4 lease expiry) or no usable router remains.

A user-space daemon cannot queue individual packets pending first RA
reception; this and other approximations are documented precisely in
[docs/conformance.md](docs/conformance.md). A native in-kernel
implementation would close those gaps.

## Status

- Draft: -00 submitted; IntArea presentation scheduled for IETF 126
  (Vienna, July 2026).
- Host implementations, all verified on real systems: Linux user-space
  daemon (netns lab, 6/6 conformance tests on Fedora 44 / kernel 6.19);
  systemd-networkd native patch (applies to systemd main, builds
  warning-free, `test-network` integration test 100/100); FreeBSD
  user-space daemon (vnet-jail lab, connectivity + zero-ARP on
  FreeBSD 15.1).
- Router-side: configuration-only; example configs for IOS XR, JunOS,
  SR OS, EOS and RouterOS in [router/vendor-configs/](router/vendor-configs/)
  (RFC 8950 return-path, 192.0.0.11 termination and ARP tier, §5.2
  enforcement). Lab behaviour verified on Linux/FreeBSD; commercial
  configs not yet hardware-tested.
- Independent implementation: FRRouting implementation offered
  (D. Lamparter).

## License

See [LICENSE](LICENSE).
