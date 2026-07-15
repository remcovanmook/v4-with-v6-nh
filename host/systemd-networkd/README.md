# systemd-networkd native implementation

`0001-network-support-IPv6-resolved-IPv4-gateway-192.0.0.1.patch`
implements the draft's Section 4 host behaviour natively in
systemd-networkd (patch against systemd main; applies with `git am` and
compiles warning-free), behind an opt-in `[DHCPv4] UseIPv6ResolvedGateway=`
boolean (default false), with a `systemd.network(5)` man page entry.
Router-preference ties break deterministically (lowest address).
Lease renewal and loss are handled by networkd's existing DHCPv4 route
mark/sweep. Pre-5.2 kernels (no `RTA_VIA` for IPv4) are detected and
the route is skipped with a warning. An integration test in
`test-network` drives the mechanism end to end using networkd's own
DHCP server (`Router=192.0.0.11`) and `IPv6SendRA=`, asserting the
`default via inet6 …` route, the absence of an ARP-resolvable gateway,
and survival across an RA refresh.

Because networkd runs the DHCPv4 client and the NDisc (RA) state
machine in one process, this implementation avoids the split-stack IPC
consideration in the draft's Section 6 entirely:

- DHCPv4 Router option == 192.0.0.11 → the IPv4 default route is
  programmed with an IPv6 next hop (`RTA_VIA`) pointing at the NDisc
  default router selected per RFC 4191 preference; the kernel resolves
  the link-layer address via ND, never ARP.
- The route is re-evaluated on every RA and on router lifetime expiry.
- If no IPv6 default router is known yet when the lease arrives,
  installation is deferred until the first RA (draft Section 4 startup
  behaviour; networkd's own route queueing covers the interim).
- RFC 3442 classless-static-route precedence over the Router option is
  preserved.

Validated on Fedora 44 (systemd main, kernel 6.19): the patch applies
with `git am`, `systemd-networkd` builds warning-free, and the
`test-network` integration test passes 100/100 runs (the deferred
DHCP-before-RA path included — a newly learned default router
re-evaluates the pending IPv4 default via the NDisc router handler).

Build:

    git clone https://github.com/systemd/systemd && cd systemd
    git am .../0001-network-support-IPv6-resolved-IPv4-gateway-192.0.0.1.patch
    meson setup build -Dnetworkd=true && ninja -C build systemd-networkd

Together with `../v4gwd.py` (portable, DHCP-client-agnostic) this gives
two host-side implementations; an independent FRRouting router-side
implementation has been offered separately.
