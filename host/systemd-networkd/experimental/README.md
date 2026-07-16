# Experimental: placeholder next hop during startup deferral

`placeholder-nexthop-during-deferral.patch` is an **optional companion** to
`../0001-network-support-IPv6-resolved-IPv4-gateway-192.0.0.1.patch`, applied
on top of it. It is **deliberately not part of the canonical patch.**

## The window it addresses

When a DHCPv4 lease names the sentinel 192.0.0.11 but no IPv6 default router
is known yet (the first RA has not arrived), the canonical patch *defers* the
IPv4 default route until it is. That is the honest, standards-clean behaviour.

During that sub-second window there is no IPv4 default route. An
interface-pinned IPv4 send — e.g. `systemd-resolved` querying a DHCP-supplied
DNS server on a socket bound to the link (`SO_BINDTODEVICE`) — has nothing to
follow, so the kernel resolves the destination **on-link** and emits an IPv4
ARP for it. Observed at boot as `who-has 1.1.1.1`.

## What the patch does

Instead of installing nothing during the deferral, it installs the IPv4
default via a bogus, never-assigned link-local next hop —
`fe80::c000:c` (`0xc000000c` = 192.0.0.12, one past the sentinel). An
interface-pinned send then resolves the *IPv6* next hop via Neighbor
Discovery (an unanswered NS → dropped), and never ARPs the destination. The
canonical patch's existing stale-route sweep replaces the placeholder with the
real router the instant the first RA lands.

## Status

- **Compiles** clean (systemd 259.5, incremental build).
- **Mechanism proven**: an interface-pinned send over a `via inet6` route
  emits zero IPv4 ARP (verified directly with a throwaway route).
- **Not runtime-validated** end to end — reproducing the boot race needs a
  reboot with an IPv4 DNS server still handed out.

## Why it is kept out of the canonical patch

The gap is a benign, self-healing race: networkd already sends the Router
Solicitation on link-up and the RA answers in microseconds, so the real
default installs within about a second. The gap only exists because the
*first* RS is subject to RFC 4861's random initial delay while DHCPv4 has
none.

The primary, defensible fix is not to hand out an IPv4 service address that
must ride the v4-via-v6 path at all — serve DNS over IPv6 (RA RDNSS), see
`../../../router/debian/dnsmasq.conf`. That removes the trigger.

Synthesising a route to a made-up address to paper over a boot-time race is
exactly the kind of thing a standards reviewer would (rightly) question, so it
does not belong in the patch proposed upstream. It lives here as a pragmatic,
opt-in host-side belt-and-suspenders for anyone who wants the window closed
for *whatever* might reach for IPv4 in it, not just DNS.
