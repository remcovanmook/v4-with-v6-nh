# Draft notes — proposed additions

Working notes for the **active** draft-vanmook-intarea-ipv6-resolved-gateway
editing queue (not the `legacy/` copy). Two related findings from the Windows
interop work (2026-07); they are two sides of one coin — removing ARP for the
sentinel gateway delegates the IPv4 gateway's *identity* and its *failover*
entirely to IPv6 default-router selection.

---

## 1. Multiple gateways need no coordination — the sentinel is L2-anycast

*Suggested placement: a new subsection under deployment / operational
considerations, e.g. "Multiple gateways and redundancy."*

Because the sentinel gateway (192.0.0.11) is resolved from the IPv6 neighbor
cache rather than by ARP, its link-layer address on any host is simply that
host's current IPv6 default router. The sentinel address therefore carries no
state and requires no election: it can be configured identically on any number
of routers on a segment **with no coordination between them**, and each host
reaches whichever router it already uses for IPv6.

This is a departure from the IPv4 norm. A shared IPv4 gateway address
conventionally requires a first-hop redundancy protocol (VRRP [RFC 5798],
HSRP) precisely *because* ARP admits only one link-layer answer for a given
address — two uncoordinated routers answering ARP for the same gateway IP
produce conflicting resolutions and blackhole traffic, so the protocol elects a
single active owner of the virtual address and MAC. Removing ARP from the
gateway resolution removes that constraint: the gateway address is never placed
on the wire, so replicating it across routers is not a conflict but an anycast.

The requirement reduces to the routers having **distinct IPv6 identities**,
which Router Advertisement already enforces:

- **Distinct link-local addresses** — automatic for distinct interfaces, and
  the operative property: it is what lets a host enumerate the routers as
  separate default routers, distribute across them by RA preference
  [RFC 4191], and fail between them via Neighbor Unreachability Detection
  [RFC 4861]. The sentinel's link-layer address follows whichever default
  router the host has selected.
- **Distinct global addresses** — only where the routers share a SLAAC prefix
  (to avoid duplicate-address detection between the routers themselves). With
  distinct advertised prefixes this does not arise.

Two concerns remain, but both are ordinary and orthogonal — neither is gateway
coordination:

- **Return path.** The router a host egresses through must have a route back to
  that host's /32 (or, under source NAT, holds the flow state itself). In a
  routed deployment this is ordinary route distribution — e.g. BGP advertising
  IPv4 NLRI with an IPv6 next hop [RFC 8950] — not gateway state.
- **Address assignment.** Multiple DHCP servers on one segment still need split
  pools or DHCP failover to avoid double allocation. That is a DHCP concern,
  independent of the shared gateway.

**One-line takeaway for the draft:** the sentinel gateway carries no state and
needs no election; IPv4 first-hop redundancy and load-sharing ride entirely on
IPv6's native multi-router selection.

---

## 2. Failover is paced by IPv6 default-router selection

*Suggested placement: the host-behaviour section (companion to the
neighbor-cache-resolution text), or the same redundancy subsection.*

Because the sentinel's link-layer address tracks the IPv6 default router, IPv4
first-hop failover happens exactly when — and only as fast as — the host
changes its IPv6 default router. A conforming host (and the daemon realizations
for stacks without RFC 5549 / [RFC 8950] data-plane support) re-resolves the
sentinel the moment the ::/0 next hop changes and adds no latency of its own.
Failover timing is therefore governed by RFC 4861 router lifetime and Neighbor
Unreachability Detection, not by anything IPv4-specific.

**Operational note observed in interop testing (Windows 11, ARM64):** a router
that departs *silently* — e.g. its interface is administratively downed with no
final advertisement — is retained by hosts as a default router until its
advertised Router Lifetime expires or NUD concludes it is unreachable, which
can be slow. Fast, clean failover depends on the departing router emitting a
final Router Advertisement with **Router Lifetime 0** (the graceful-shutdown
advertisement, RFC 4861 §6.2.5). Operators deploying redundant sentinel
gateways should ensure their RA daemon sends this on shutdown.

Note that host-side IPv4 DHCP renewal does **not** affect this: the IPv4
default-gateway lifetime is decoupled from the IPv6 default-router lifetime that
actually governs the next hop. On Windows this was explicit — `ipconfig
/renew` / `/release` (DHCPv4 only) could not dislodge a stale IPv6 default
router; removing the ::/0 route (the manual equivalent of a Lifetime-0 RA) did.

**One-line caveat for the draft:** first-hop failover is free but is paced by
the host's IPv6 default-router selection; deployments wanting fast failover must
rely on graceful (Lifetime-0) router shutdown, exactly as native IPv6 does.
