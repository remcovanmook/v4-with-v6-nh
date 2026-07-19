# Conformance matrix

Mapping of normative statements in draft-vanmook-intarea-ipv6-resolved-gateway-00
to the implementations in this repository.

Host-side implementations of Section 4:

- **v4gwd** — `host/v4gwd.py`, portable Linux user-space daemon
- **networkd** — `host/systemd-networkd/` patch (native, opt-in
  `[DHCPv4] UseIPv6ResolvedGateway=`; DHCPv4 client and NDisc in one process)
- **freebsd** — `host/freebsd/v4gwd.c`, single-file C daemon for FreeBSD 13.1+
  (RFC 5549 data plane)

Per-item statuses (applied per implementation where they differ):

- **Conformant** — implemented
- **Inherited** — provided by the OS kernel's native support for IPv4 routes
  with IPv6 next hops (Linux `RTA_VIA`, kernel ≥ 5.2; FreeBSD RFC 5549 data
  plane); route installation activates it
- **Partial** — approximated; a native in-kernel implementation is required for
  full conformance, noted per item
- **Documented** — router-side; provided as configuration examples in
  `router/vendor-configs/`, verified in the lab on Linux/FreeBSD but not on
  commercial hardware

## Section 4 — Host Behavior and Next-Hop Resolution

Status column applies to all three host implementations unless the Notes say
otherwise.

| # | Requirement | Status | Notes |
|---|---|---|---|
| 4.1 | Host MUST maintain functional IPv6 ND per RFC 4861 on the interface | Inherited | Standard OS IPv6 stack |
| 4.2 | Host MUST NOT perform ARP for next hop 192.0.0.11; consult IPv6 default router list and neighbor cache, scoped to the interface | Conformant / Inherited | All three install a default route with an IPv6 next hop (v4gwd/networkd: `default via inet6 <router>` / `RTA_VIA`; freebsd: `default -inet6 <router>` over PF_ROUTE); kernel resolves via ND only. Resolution is route-level rather than literally per-packet, with identical on-wire behaviour |
| 4.3 | Usable NUD states REACHABLE, STALE, DELAY, PROBE | Inherited | Kernel ND semantics (RFC 4861 §7.3.3); v4gwd/networkd check state during router selection; freebsd selects from the kernel default-router list (`nd6_drlist`) |
| 4.4 | No reachable router after initial config: packet MAY be queued or dropped; NS SHOULD be sent to last-known router | Partial | Daemons withdraw the route (packets get "network unreachable"); v4gwd solicits via `kick_nud`, networkd defers to first RA. No implementation queues individual packets from outside the kernel |
| 4 | 192.0.0.11 MUST be treated as reserved, IPv6-resolved, unconditionally | Partial | v4gwd/freebsd: enforced only while the daemon runs. networkd: opt-in `UseIPv6ResolvedGateway=` (default false). Unconditional treatment requires a kernel implementation |
| 4 | Lease expiry: host SHOULD remove 192.0.0.11 gateway and cease IPv6-based resolution | Conformant | v4gwd (sentinel required by default): RTM_DELROUTE of the sentinel triggers withdrawal (`Interface.reconcile`; lab test T3). networkd: removed by its existing DHCPv4 route mark/sweep on lease loss/renewal. freebsd: `-f` state file from `dhclient-exit-hooks`, or `-r` FIB check |
| 4 | Cross-interface resolution MUST NOT be performed | Conformant | All routes link-scoped (v4gwd `RTA_OIF`/`oif=`; networkd per-link; freebsd per-interface daemon instance) |
| 4 (pseudocode) | Router selection: highest RFC 4191 preference, then NUD REACHABLE, then implementation-defined | Conformant | All select from the IPv6 default router list per RFC 4191 preference, ties broken by lowest router address; `RTA_PREF`/unset ⇒ medium |
| 4 (pseudocode) | Empty router list at startup: MUST queue pending first RA; Router Solicitation subject to RFC 4861 rate limiting | Partial | Kernel sends RS per its own rate limiting. Daemons cannot queue from user space (**known gap**); networkd narrows it by deferring route installation until the first RA (its own route queueing covers the interim) |
| 4 | Router failure: SHOULD re-select from router list; queued packets SHOULD be flushed and re-evaluated | Conformant / n/a | v4gwd: netlink monitor triggers re-selection. networkd: re-evaluated on every RA and on router lifetime expiry. freebsd: rtsock RTM_* messages plus a periodic reconcile (default 15 s, no neighbour/router-list notifications on rtsock). No user-space queue exists to flush |
| 4 | Bounded queue; on timeout drop and MAY generate ICMPv4 Host Unreachable | Partial | Route withdrawal yields ICMPv4-equivalent local errors (EHOSTUNREACH/ENETUNREACH) to applications |
| 4 | Route requires an IPv4 default with an IPv6 next hop (Linux `RTA_VIA` ≥ 5.2; FreeBSD RFC 5549) | Inherited | v4gwd relies on kernel support; networkd detects pre-5.2 kernels and skips with a warning; freebsd probes `kern.features.ipv4_rfc5549_support` |

## Section 5 — Router Behavior

Router-side behaviour is configuration-only. `router/vendor-configs/` provides
worked examples for IOS XR, JunOS, SR OS, EOS and RouterOS, with a per-behaviour
capability matrix; lab behaviour is verified on Linux/FreeBSD, commercial
platforms are not.

| # | Requirement | Status | Notes |
|---|---|---|---|
| 5.1 | Return-path /32 host routes with IPv6 next hop (RFC 8950) | Demonstrated / Documented | Lab installs static `via inet6` /32 routes on R1/R2; vendor configs use static v4-via-v6 where supported (EOS ≥ 4.30.1, RouterOS ≥ 7.11) and BGP extended-next-hop (RFC 8950) elsewhere. Dynamic distribution / the FRRouting implementation offered by D. Lamparter is out of scope here |
| 5.2 | 192.0.0.11 interface-scoped; not injected into routing protocols, no subnet checks, never in forwarded packets | Documented | Vendor configs terminate 192.0.0.11 locally (behaviour B) and enforce the forwarding prohibition (behaviour D) via egress ACLs on non-segment interfaces (primary, all platforms) and/or TTL=1 on originations (where a knob exists) |
| 5.3 | Router SHOULD answer ARP for 192.0.0.11 (unmodified-host tier) | Documented | Behaviour C: owning 192.0.0.11/32 on the interface answers ARP natively on most stacks; verified in the Linux/FreeBSD lab, "verify" for commercial platforms (off-subnet ARP-sender handling differs per vendor) |

## Test coverage

T1–T3 run in the network-namespace lab (`lab/run-tests.sh`) against
`host/v4gwd.py`; `lab/freebsd/freebsd-lab.sh` reproduces T1 and T2 (connectivity
and zero-ARP) in vnet jails against the FreeBSD daemon. The
`host/systemd-networkd/` patch additionally carries a `test-network`
integration test.

| Test | Draft anchor | Assertion |
|---|---|---|
| T1 | §5.1 | IPv4 /32-to-/32 connectivity across two IPv6-only routers |
| T2 | §4 item 2, §5.1 | Zero ARP frames on any link during IPv4 traffic |
| T3/T3b | §4 lease expiry | Sentinel removal ⇒ withdrawal; re-add ⇒ restoration |
| networkd | §4 item 2, §4 pseudocode | `test-network`: DHCPv4 `Router=192.0.0.11` + `IPv6SendRA=` yields a `default via inet6 …` route, no ARP-resolvable gateway, surviving an RA refresh |
