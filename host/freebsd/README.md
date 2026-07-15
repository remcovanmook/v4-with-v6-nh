# FreeBSD host implementation

`v4gwd.c` implements the draft's Section 4 host behaviour on
FreeBSD 13.1+ as a single-file, zero-dependency C daemon.

FreeBSD's RFC 5549 data plane (commit `62e1a437f328`, 2021) resolves
IPv4 routes with IPv6 next hops through Neighbor Discovery, never ARP.
The daemon selects an IPv6 default router from the kernel's default
router list (`net.inet6.icmp6.nd6_drlist`, the same source as
`ndp -r`) per RFC 4191 preference with a deterministic lowest-address
tie-breaker, and programs `default -inet6 <router>` over a PF_ROUTE
socket. Kernel support is probed via the
`kern.features.ipv4_rfc5549_support` feature(3) knob.

The RA-learned router list is the primary source, reflecting real
deployments. For deployments that instead configure a **static** IPv6
default route (no Router Advertisements), the daemon falls back to that
route's gateway — scanning the FIB for an `RTF_STATIC` default and using
its next hop — but only when the router list is empty, so an RA-learned
router always wins.

Platform differences vs. the Linux implementations:

- **Events**: rtsock has no neighbour-cache or router-list
  notifications, so RTM_* route messages trigger reconciliation and a
  periodic reconcile (default 15 s, `-i`) backstops preference-only
  router-list changes.
- **DHCP integration**: where dhclient(8) cannot install a default route
  via 192.0.0.11 (no onlink equivalent), the sentinel signal comes from
  `dhclient-exit-hooks` (install alongside any existing hooks), which
  maintains a state file consumed with `-f`. With neither flag the daemon
  manages the interface unconditionally (lab mode).
- **`-r` is Linux-oriented, not for FreeBSD**: it watches the FIB for a
  192.0.0.11 default route, but installing the `-inet6` default *replaces*
  that route (FreeBSD allows only one default route, unlike Linux's
  metric-keyed coexistence), so `-r` erases its own sentinel and then
  withdraws. Use `-f` (whose state file is independent of the FIB) or
  unconditional mode on FreeBSD.

Build & run:

    make            # bsd.prog.mk; or: cc -O2 -o v4gwd v4gwd.c
    cp v4gwd.rc /usr/local/etc/rc.d/v4gwd
    sysrc v4gwd_enable=YES v4gwd_interface=em0 \
          v4gwd_flags="-f /var/run/v4gwd.em0.router"

A vnet-jail lab equivalent to the Linux netns lab is in
`../../lab/freebsd/freebsd-lab.sh` (up | test | down), including the
zero-ARP assertion.

Status: validated on FreeBSD 15.1-RELEASE. The vnet-jail lab passes
end-to-end IPv4 connectivity and the zero-ARP assertion; both next-hop
sources — the RA-learned default router list and the static IPv6
default-route fallback — are exercised and confirmed. Also verified on a
live testbed against a Debian RFC 5549 router (`../../router/debian/`):
the daemon takes over the DHCP-learned default with an `-inet6` next hop
(ND-resolved, no ARP for the gateway) and the host reaches the real IPv4
internet over its `/32`, surviving reboots via the rc.d service.
