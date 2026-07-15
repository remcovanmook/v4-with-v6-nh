# macOS host implementation

`v4gwd-arp.c` implements the draft's Section 4 host behaviour on macOS as
a single-file, zero-dependency C daemon.

Unlike Linux (`RTA_VIA`, kernel ≥ 5.2) and FreeBSD (RFC 5549 data plane,
2021), macOS/XNU has **no kernel support for IPv4 routes with an IPv6
next hop** — and being closed and locked down (kexts deprecated, SIP,
notarization), you can't add it. This daemon reaches the identical
on-wire behaviour with no kernel change, using a realization that needs
only standard BSD tooling.

## How it works

The special-purpose gateway 192.0.0.11 has no host of its own; its
link-layer address is simply that of the IPv6 default router — one
interface, one MAC. So instead of resolving 192.0.0.11 by ARP, the
daemon:

1. **follows the IPv6 default route** on the managed interface to find
   the default router (`NET_RT_DUMP`);
2. **reads that router's MAC from the Neighbor Discovery cache**
   (`NET_RT_FLAGS | RTF_LLINFO`, the source `ndp(8)` uses) — never ARP;
3. installs a static ARP entry `192.0.0.11 → <router MAC>` (`arp -s`), so
   the stock `default via 192.0.0.11` route resolves to the router's MAC
   and IPv4 frames leave addressed to it — byte-for-byte what the RFC 5549
   realization puts on the wire;
4. keeps the entry in sync as the IPv6 default router or its MAC changes,
   and removes it when no usable router remains.

No ARP is ever emitted for 192.0.0.11 (the static entry pre-empts it) and
the link-layer address comes from the ND cache, so the draft's Section 4
"no ARP, resolve from the neighbor cache" behaviour is met — this is just
a different *realization* of the same result, for hosts whose kernel
can't do IPv4-via-IPv6 next hops. The same trick is a viable fallback on
pre-5.2 Linux and pre-13.1 FreeBSD.

Gateway reachability is driven by the IPv6 neighbor's ND state, which the
kernel maintains for IPv6 regardless; the daemon mirrors it into the IPv4
ARP table (a `PERMANENT` static entry gets no IPv4 NUD of its own).

Discovery uses the routing socket directly; the mutation shells out to
`arp(8)`, whose flag/sockaddr handling is version-specific — keeping it in
the proven tool avoids a hand-rolled `RTM_ADD`.

## Build & run

    make                       # cc -O2 -Wall; Command Line Tools suffice
    sudo ./v4gwd-arp en0       # manage en0 unconditionally (lab mode)

Sentinel-gated modes mirror the FreeBSD daemon: `-r` manages the
interface only while an IPv4 default route via 192.0.0.11 is present in
the FIB; `-f statefile` reads a DHCP hook's Router-option record. The
IPv4 default route itself (`default via 192.0.0.11`) is installed by the
DHCPv4 client or by hand.

`-n` performs discovery only and prints what it would program, making no
changes and requiring no privilege:

    $ ./v4gwd-arp -n en7
    v4gwd-arp dry run on en7 (ifindex 21)
      IPv6 default router      : fe80::ba69:f4ff:fe1b:ea7b%en7
      router link-layer        : b8:69:f4:1b:ea:7b (from ND cache)
      would install            : arp -s 192.0.0.11 b8:69:f4:1b:ea:7b ifscope en7

For boot integration, install the daemon and the launchd job (edit the
interface in the plist first):

    sudo make install                         # -> /usr/local/sbin/v4gwd-arp
    sudo cp net.vanmook.v4gwd-arp.plist /Library/LaunchDaemons/
    sudo launchctl bootstrap system /Library/LaunchDaemons/net.vanmook.v4gwd-arp.plist

    # logs: log show --predicate 'process == "v4gwd-arp"' --last 1h
    # stop: sudo launchctl bootout system/net.vanmook.v4gwd-arp

## Status

Verified end to end on macOS 26 (Darwin 25.x, arm64, clang 15) against a
live Debian RFC 5549 router (`../../router/debian/`):

- The daemon follows the DHCP-learned IPv6 default router, reads its MAC
  from the ND cache, and installs the static ARP entry (`arp -n
  192.0.0.11` shows it `permanent`).
- With the entry in place the host performs **zero ARP for 192.0.0.11**
  during traffic (confirmed by capture at the router), and reaches both a
  target behind the router and the real IPv4 internet (`1.1.1.1`) over its
  `/32` — from an IPv6-only segment, with no kernel v4-via-v6 support.
- On shutdown it withdraws the entry cleanly.
- Runs under launchd across reboots.

The underlying mechanism is also validated OS-agnostically on the Linux
lab (a static neighbor entry for 192.0.0.11 → the router's MAC carries
end-to-end IPv4 with zero ARP frames).
