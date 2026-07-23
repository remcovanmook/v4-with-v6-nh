#!/usr/bin/env python3
"""v4gwd - IPv6-Resolved IPv4 Gateway daemon.

Host-side reference implementation of
draft-vanmook-intarea-ipv6-resolved-gateway (Section 4).

The draft specifies that a host configured with 192.0.0.11 as its IPv4
default gateway MUST NOT perform ARP for it, and instead resolves the
next-hop link-layer address from the IPv6 default router list and
neighbor cache (RFC 4861), with router selection per RFC 4191.

Linux natively supports IPv4 routes with an IPv6 next hop (RTA_VIA,
kernel >= 5.2); such routes are resolved via Neighbor Discovery, not
ARP.  This daemon therefore implements Section 4 by:

  1. watching for the sentinel 192.0.0.11 as the IPv4 default gateway
     on a managed interface (installed by a DHCPv4 client or statically);
  2. selecting an IPv6 default router on that interface per RFC 4191
     Default Router Preference, tie-breaking on NUD reachability;
  3. installing "default via inet6 <router> dev <iface>" with a lower
     metric than the sentinel route, tagged with rt proto 199 so the
     daemon's routes are identifiable and reversible;
  4. withdrawing its route when the sentinel disappears (DHCPv4 lease
     expiry -- Section 4, "SHOULD remove ... and cease") or when no
     usable IPv6 default router remains.

On a pre-5.2 kernel (no RTA_VIA) the daemon falls back to the same
static-neighbor realization the macOS and Windows daemons use: it pins a
permanent IPv4 neighbor for 192.0.0.11 to the IPv6 default router's MAC
(read from the ND cache), so the stock "default via 192.0.0.11" installed
by DHCP resolves to that MAC with no ARP.  It follows the IPv6 router and
re-asserts the entry if an external flush leaves a dynamic (ARP-learned)
one.  The mode is selected from the running kernel version.

Per-packet queueing semantics (Section 4, startup behavior) cannot be
implemented from user space; see docs/conformance.md for the exact
mapping of normative statements to this implementation.

Purely event-driven: rtnetlink multicast groups deliver every state
change that matters.  RA-driven router-list updates and lifetime
expiries arrive as RTM_NEWROUTE/RTM_DELROUTE (AF_INET6, proto RA;
the kernel deletes expired RA routes itself), NUD transitions as
RTM_NEWNEIGH, DHCPv4 lease expiry as RTM_DELROUTE of the sentinel
route, interface state as RTM_NEWLINK.  Reconciliation is idempotent
and re-reads full state via a dump on a separate socket, so a monitor
overrun (ENOBUFS) degrades to a single redundant reconcile.

Usage:
    v4gwd.py [--unconditional] [--metric N] [IFACE ...]

  IFACE ...       interfaces to manage.  With none given, every ethernet
                  interface is managed and interfaces that appear later are
                  picked up automatically.
  --unconditional manage an interface without requiring a 192.0.0.11 default
                  route on it (static/lab mode).  By default the sentinel
                  route is required, so the daemon is inert on ordinary
                  networks and safe to leave running everywhere.
"""

import argparse
import errno
import os
import re
import select
import signal
import socket
import sys
import syslog

from pyroute2 import IPRoute
from pyroute2.netlink import rtnl
from pyroute2.netlink.exceptions import NetlinkError

# The special-purpose IPv4 gateway.  Draft-provisional 192.0.0.11; kept
# overridable via V4GW_GATEWAY so the address is not baked in ahead of its
# IANA assignment.  The default is unchanged.
SENTINEL = os.environ.get("V4GW_GATEWAY", "192.0.0.11")
RT_PROTO = 199          # marks routes owned by this daemon
DEFAULT_METRIC = 50     # must be lower than the sentinel route's metric
NUD_PERMANENT = 0x80    # linux/neighbour.h: a static, non-expiring entry

# RFC 4191 preference as encoded in RTA_PREF (ICMPV6_ROUTER_PREF_*)
PREF_RANK = {1: 2, 0: 1, 3: 0}   # high > medium > low
# RFC 4861 NUD states usable for transmission (s7.3.3)
NUD_USABLE = {0x02, 0x04, 0x08, 0x10}  # REACHABLE, STALE, DELAY, PROBE

running = True


def log(msg, prio=syslog.LOG_NOTICE):
    syslog.syslog(prio, msg)
    print(msg, file=sys.stderr, flush=True)


def stop(signum, frame):
    global running
    running = False


def kernel_has_rta_via():
    """RTA_VIA (IPv4 route with an IPv6 next hop) landed in Linux 5.2."""
    m = re.match(r"(\d+)\.(\d+)", os.uname().release)
    if not m:
        return True                        # unknown format: assume modern
    return (int(m.group(1)), int(m.group(2))) >= (5, 2)


def ethernet_ifnames(ipr):
    """Names of the host's ethernet interfaces (ARPHRD_ETHER)."""
    names = set()
    for link in ipr.get_links():
        if link.get("ifi_type") == 1:      # ARPHRD_ETHER
            name = link.get_attr("IFLA_IFNAME")
            if name:
                names.add(name)
    return names


class Interface:
    def __init__(self, ipr, name, metric, require_sentinel, static_arp=False):
        self.ipr = ipr
        self.name = name
        self.metric = metric
        self.require_sentinel = require_sentinel
        self.static_arp = static_arp
        self.index = None
        self.installed_via = None  # IPv6 gateway our RTA_VIA route points at
        self.installed_mac = None  # router MAC our static neighbor points at

    def active(self):
        return self.installed_via is not None or self.installed_mac is not None

    def resolve_index(self):
        links = self.ipr.link_lookup(ifname=self.name)
        self.index = links[0] if links else None
        return self.index

    # -- route table inspection ------------------------------------------

    def _default_routes(self, family):
        out = []
        for r in self.ipr.get_routes(family=family):
            if r["dst_len"] != 0:
                continue
            if r.get_attr("RTA_OIF") != self.index:
                continue
            out.append(r)
        return out

    def sentinel_present(self):
        for r in self._default_routes(socket.AF_INET):
            if r.get("proto") == RT_PROTO:
                continue
            if r.get_attr("RTA_GATEWAY") == SENTINEL:
                return True
        return False

    def nud_state(self, gw):
        try:
            neigh = self.ipr.get_neighbours(
                family=socket.AF_INET6, ifindex=self.index, dst=gw)
        except NetlinkError:
            return 0
        return neigh[0]["state"] if neigh else 0

    def router_lladdr(self, gw):
        """The IPv6 default router's link-layer address from the ND cache."""
        try:
            neigh = self.ipr.get_neighbours(
                family=socket.AF_INET6, ifindex=self.index, dst=gw)
        except NetlinkError:
            return None
        return neigh[0].get_attr("NDA_LLADDR") if neigh else None

    def select_router(self):
        """RFC 4191 selection: highest preference, then NUD REACHABLE,
        then most recently seen (last in netlink dump order)."""
        best = None
        best_key = None
        for r in self._default_routes(socket.AF_INET6):
            gw = r.get_attr("RTA_GATEWAY")
            if gw is None:
                continue
            pref = PREF_RANK.get(r.get_attr("RTA_PREF"), 1)  # absent => medium
            reachable = 1 if self.nud_state(gw) == 0x02 else 0
            key = (pref, reachable)
            if best_key is None or key >= best_key:
                best, best_key = gw, key
        return best

    # -- ND cache nudging --------------------------------------------------

    def kick_nud(self, gw):
        """Trigger a Neighbor Solicitation for gw by handing the kernel a
        throwaway datagram (Section 4, item 4: NS SHOULD be sent)."""
        try:
            s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE,
                         self.name.encode())
            s.sendto(b"", (gw, 9))
            s.close()
        except OSError:
            pass

    # -- programming: native RTA_VIA route --------------------------------

    def _install_route(self, gw):
        if self.installed_via == gw:
            return
        try:
            self.ipr.route(
                "replace", family=socket.AF_INET, dst="0.0.0.0/0",
                oif=self.index, priority=self.metric, proto=RT_PROTO,
                via={"family": socket.AF_INET6, "addr": gw})
            log(f"{self.name}: IPv4 default -> via inet6 {gw} "
                f"(metric {self.metric}, proto {RT_PROTO})")
            self.installed_via = gw
        except NetlinkError as e:
            log(f"{self.name}: failed to install route via {gw}: {e}",
                syslog.LOG_ERR)

    # -- programming: pre-5.2 static-neighbor fallback --------------------

    def _neighbor_present(self, mac):
        """Is *our* permanent sentinel neighbor still installed with this MAC?
        An external flush leaves a *dynamic* (ARP-learned) entry with the same
        MAC; that counts as absent, so we re-assert the permanent one and keep
        ARP suppressed -- the whole point of Section 4."""
        try:
            neigh = self.ipr.get_neighbours(
                family=socket.AF_INET, ifindex=self.index, dst=SENTINEL)
        except NetlinkError:
            return False
        for n in neigh:
            if (n["state"] & NUD_PERMANENT) and n.get_attr("NDA_LLADDR") == mac:
                return True
        return False

    def _pin_neighbor(self, gw):
        """No RTA_VIA on this kernel: pin a permanent IPv4 neighbor for the
        sentinel to the IPv6 router's MAC, so the stock 'default via
        192.0.0.11' resolves to it without ARP (the macOS/Windows approach)."""
        mac = self.router_lladdr(gw)
        if mac is None:
            return                     # router MAC not resolved yet; retry
        if self.installed_mac == mac and self._neighbor_present(mac):
            return
        try:
            self.ipr.neigh("replace", family=socket.AF_INET, dst=SENTINEL,
                           lladdr=mac, ifindex=self.index, state=NUD_PERMANENT)
            log(f"{self.name}: IPv4 gateway {SENTINEL} -> {mac} "
                f"(static neighbor; kernel < 5.2, no RTA_VIA)")
            self.installed_mac = mac
        except NetlinkError as e:
            log(f"{self.name}: failed to pin {SENTINEL} -> {mac}: {e}",
                syslog.LOG_ERR)

    def install(self, gw):
        if self.static_arp:
            self._pin_neighbor(gw)
        else:
            self._install_route(gw)

    def withdraw(self, reason):
        if self.static_arp:
            if self.installed_mac is None:
                return
            try:
                self.ipr.neigh("del", family=socket.AF_INET, dst=SENTINEL,
                               ifindex=self.index)
                log(f"{self.name}: withdrew static neighbor for {SENTINEL} "
                    f"({reason})")
            except NetlinkError as e:
                if e.code not in (errno.ENOENT, errno.ESRCH):
                    log(f"{self.name}: failed to withdraw neighbor: {e}",
                        syslog.LOG_ERR)
            self.installed_mac = None
            return
        try:
            self.ipr.route(
                "del", family=socket.AF_INET, dst="0.0.0.0/0",
                oif=self.index, priority=self.metric, proto=RT_PROTO)
            log(f"{self.name}: withdrew IPv4 default route ({reason})")
        except NetlinkError as e:
            if e.code != errno.ESRCH:
                log(f"{self.name}: failed to withdraw route: {e}",
                    syslog.LOG_ERR)
        self.installed_via = None

    # -- reconciliation ------------------------------------------------

    def reconcile(self):
        if self.resolve_index() is None:
            self.installed_via = None  # interface gone, routes/neigh gone
            self.installed_mac = None
            return

        if self.require_sentinel and not self.sentinel_present():
            if self.active():
                self.withdraw(f"sentinel {SENTINEL} removed; ceasing per s4")
            return

        gw = self.select_router()
        if gw is None:
            if self.active():
                self.withdraw("no IPv6 default router on interface")
            return

        state = self.nud_state(gw)
        if state not in NUD_USABLE:
            # INCOMPLETE/FAILED/NONE: solicit, keep existing entry if any
            self.kick_nud(gw)

        self.install(gw)


def serve(mon, rpipe, ifaces, refresh):
    """Block on netlink events (or a signal) and reconcile on each wake."""
    poller = select.poll()
    poller.register(mon.fileno(), select.POLLIN)
    poller.register(rpipe, select.POLLIN)
    while running:
        for fd, _ in poller.poll():
            if fd == rpipe:
                os.read(rpipe, 64)    # drain wakeup bytes
                continue
            try:
                for _ in mon.get():   # drain; contents don't matter,
                    pass              # reconcile is idempotent
            except OSError:
                pass                  # ENOBUFS et al.: reconcile anyway
        if running:
            refresh()                 # pick up newly appeared interfaces
            for i in ifaces.values():
                i.reconcile()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("interfaces", nargs="*", metavar="IFACE",
                    help="interfaces to manage (default: all ethernet)")
    ap.add_argument("--unconditional", action="store_true",
                    help="manage without requiring the sentinel default route "
                         "(static/lab mode); the sentinel route is required "
                         "by default")
    ap.add_argument("--metric", type=int, default=DEFAULT_METRIC)
    args = ap.parse_args()

    syslog.openlog(ident="v4gwd", facility=syslog.LOG_DAEMON)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    static_arp = not kernel_has_rta_via()
    require_sentinel = not args.unconditional
    auto = not args.interfaces
    dp = "static neighbor (no RTA_VIA)" if static_arp else "native RTA_VIA"
    scope = "all ethernet interfaces" if auto else " ".join(args.interfaces)
    log(f"starting: {dp}; gateway {SENTINEL}; managing {scope}; "
        f"{'sentinel required' if require_sentinel else 'unconditional'}")

    # Wakeup pipe so signals interrupt poll() (PEP 475 retries EINTR)
    rpipe, wpipe = os.pipe()
    os.set_blocking(wpipe, False)
    signal.set_wakeup_fd(wpipe)

    ipr = IPRoute()
    mon = IPRoute()
    mon.bind(groups=rtnl.RTMGRP_IPV4_ROUTE |
                    rtnl.RTMGRP_IPV6_ROUTE |
                    rtnl.RTMGRP_LINK |
                    rtnl.RTMGRP_NEIGH)

    ifaces = {}    # name -> Interface, grown as ethernet interfaces appear

    def refresh():
        names = ethernet_ifnames(ipr) if auto else set(args.interfaces)
        for n in names:
            if n not in ifaces:
                ifaces[n] = Interface(ipr, n, args.metric,
                                      require_sentinel, static_arp)

    refresh()
    for i in ifaces.values():
        i.reconcile()

    serve(mon, rpipe, ifaces, refresh)

    for i in ifaces.values():
        if i.active():
            i.withdraw("daemon shutdown")
    ipr.close()
    mon.close()
    syslog.closelog()


if __name__ == "__main__":
    main()
