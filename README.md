# v4-with-v6-nh

Reference implementation for
[draft-vanmook-intarea-ipv6-resolved-gateway](https://datatracker.ietf.org/doc/draft-vanmook-intarea-ipv6-resolved-gateway/):
IPv4 connectivity on IPv6-only network segments via the special-purpose
gateway address **192.0.0.11**, resolved from the IPv6 neighbor cache
instead of ARP. No IPv4 subnets, no tunnelling, no translation — IPv4
packets are carried natively, end to end.

> **192.0.0.11 is provisional.** The draft requests this special-purpose
> address from IANA; it is not yet assigned. The implementations here carry it
> as a default that the `V4GW_GATEWAY` environment variable overrides, so a
> different allocation is a configuration change, not a code change.

## Layout

```text
host/    v4gwd.py — Linux host daemon (draft Section 4): sentinel detection,
         RFC 4191 router selection, route programming via IPv6 next hop;
         + systemd unit;
         systemd-networkd/ — native networkd patch;
         networkmanager/ — coexistence notes (v4gwd.py races a lower-metric
         RTA_VIA default);
         ifupdown/ — the same, for classic /etc/network/interfaces;
         freebsd/ — C daemon for FreeBSD 13.1+ (RFC 5549 data plane) with
         dhclient-exit-hooks and rc.d integration;
         macos/ — C daemon maintaining a static ARP entry that follows the
         IPv6 router;
         windows/ — PowerShell daemon + native C service, the same
         static-neighbor realization via the IP Helper API;
         packaging/ — noarch .deb / .rpm build for v4gwd.py
lab/     network-namespace lab reproducing the Section 5.1 topology, with
         conformance tests (incl. a zero-ARP assertion);
         freebsd/ — equivalent vnet-jail lab
router/  debian/ — the working testbed router (RA + DHCPv4, RFC 5549 return
         path, native reboot-persistent config);
         vendor-configs/ — configuration examples for the Section 5 router
         side (RFC 8950 return-path, 192.0.0.11 termination, the
         unmodified-host ARP tier, §5.2 enforcement) across five commercial
         platforms
docs/    conformance.md — every normative statement in Sections 4–5 mapped to
         code, kernel behaviour, or a documented gap
legacy/  the 2024/25 mechanism this work grew out of (IPv4 default route
         follows the IPv6 default gateway) — prior art, not draft-conformant
```

## Quick start

Requirements: Python 3 and pyroute2 (daemon); iproute2 and tcpdump (netns lab
and conformance tests).

```sh
pip install pyroute2

# bring up the four-namespace lab in DHCP-driven (sentinel) mode
sudo lab/topology.sh up --sentinel

# run the conformance tests
sudo lab/run-tests.sh

sudo lab/topology.sh down
```

On a real host with a DHCPv4 server handing out `192.0.0.11` as Option 3
(router), run the daemon — it manages every ethernet interface and acts where
the sentinel appears:

```sh
sudo host/v4gwd.py
```

or install `host/systemd/v4gwd.service` and `systemctl enable --now v4gwd`.

## How it maps to the draft

Linux natively resolves IPv4 routes with an IPv6 next hop through Neighbor
Discovery — never ARP. `v4gwd` uses this to implement the draft's Section 4
host behaviour from user space: it detects the 192.0.0.11 sentinel, selects an
IPv6 default router per RFC 4191, installs `default via inet6 <router>`, tracks
router-list and neighbor cache changes over netlink, and withdraws its route
when the sentinel disappears (DHCPv4 lease expiry) or no usable router remains.

FreeBSD carries the same RFC 5549 data plane in kernel. On stacks without it —
macOS, Windows, and pre-5.2 Linux — a daemon reaches the identical on-wire
behaviour by pinning 192.0.0.11 to the IPv6 default router's link-layer address
(read from the neighbor cache) and re-slaving it as that router changes.
`v4gwd` selects this static-neighbor mode automatically on a kernel below 5.2.

A user-space daemon cannot queue individual packets pending first RA reception;
this and other approximations are documented in
[docs/conformance.md](docs/conformance.md).

## Status

- Draft: -01 submitted; IntArea presentation scheduled for IETF 126 (Vienna,
  July 2026).
- Host implementations, verified on real systems:
  - Linux daemon — netns lab, 6/6 conformance tests (Fedora 44 / kernel 6.19);
  - systemd-networkd patch — applies to systemd main, `test-network` 100/100;
  - NetworkManager — Fedora 44 / NM 1.56.1: zero-ARP §4 takeover, route
    survives `reapply` and a connection bounce;
  - ifupdown — Debian 13 / dhcpcd: dhcpcd installs the sentinel + on-link /32,
    v4gwd takes over §4, route survives a renewal and an interface bounce;
  - FreeBSD daemon — vnet-jail lab, connectivity + zero-ARP (FreeBSD 15.1);
  - macOS daemon — follows the IPv6 default router with a static ARP entry for
    192.0.0.11; validated on macOS 26, zero-ARP + connectivity;
  - Windows — PowerShell `v4gwd.ps1` + native C service via IP Helper;
    validated on Windows 11 ARM64: §5.3 unmodified works, and the daemon pins
    192.0.0.11 to the ND-resolved router, follows a gateway change, and runs
    at boot.
- Prebuilt host binaries and patched systemd-networkd packages (macOS /
  FreeBSD / Fedora / Ubuntu; arm64 + amd64), plus noarch `.deb`/`.rpm` packages
  of the `v4gwd.py` daemon, are published as release assets under the `prebuilt`
  tag. Download hub with per-platform install instructions:
  <https://remcovanmook.github.io/v4-with-v6-nh/> (also each `host/*/prebuilt/`
  and `host/packaging/`).
- Router side: example configs for IOS XR, JunOS, SR OS, EOS and RouterOS in
  [router/vendor-configs/](router/vendor-configs/) (RFC 8950 return-path,
  192.0.0.11 termination and ARP tier, §5.2 enforcement). Lab behaviour
  verified on Linux/FreeBSD; commercial configs not yet hardware-tested.
- Independent implementation: FRRouting implementation offered (D. Lamparter).

## License

See [LICENSE](LICENSE).
