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
    v4gwd.py [--require-sentinel] [--metric N] IFACE [IFACE...]

  --require-sentinel  only manage an interface while a 192.0.0.11 IPv4
                      default route exists on it (DHCP-driven mode).
                      Without this flag the daemon manages the listed
                      interfaces unconditionally (static/lab mode).
"""

import argparse
import errno
import os
import select
import signal
import socket
import sys
import syslog

from pyroute2 import IPRoute
from pyroute2.netlink import rtnl
from pyroute2.netlink.exceptions import NetlinkError

SENTINEL = "192.0.0.11"
RT_PROTO = 199          # marks routes owned by this daemon
DEFAULT_METRIC = 50     # must be lower than the sentinel route's metric

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


class Interface:
    def __init__(self, ipr, name, metric, require_sentinel):
        self.ipr = ipr
        self.name = name
        self.metric = metric
        self.require_sentinel = require_sentinel
        self.index = None
        self.installed_via = None  # IPv6 gateway we currently point at

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

    # -- route programming -------------------------------------------------

    def install(self, gw):
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

    def withdraw(self, reason):
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
            if self.installed_via:
                self.installed_via = None  # interface gone, routes gone
            return

        if self.require_sentinel and not self.sentinel_present():
            if self.installed_via:
                self.withdraw("sentinel 192.0.0.11 removed; ceasing per s4")
            return

        gw = self.select_router()
        if gw is None:
            if self.installed_via:
                self.withdraw("no IPv6 default router on interface")
            return

        state = self.nud_state(gw)
        if state not in NUD_USABLE:
            # INCOMPLETE/FAILED/NONE: solicit, keep existing route if any
            self.kick_nud(gw)

        self.install(gw)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("interfaces", nargs="+", metavar="IFACE")
    ap.add_argument("--require-sentinel", action="store_true",
                    help="act only while a 192.0.0.11 IPv4 default route "
                         "exists on the interface")
    ap.add_argument("--metric", type=int, default=DEFAULT_METRIC)
    args = ap.parse_args()

    syslog.openlog(ident="v4gwd", facility=syslog.LOG_DAEMON)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

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

    ifaces = [Interface(ipr, n, args.metric, args.require_sentinel)
              for n in args.interfaces]

    for i in ifaces:
        i.reconcile()

    poller = select.poll()
    poller.register(mon.fileno(), select.POLLIN)
    poller.register(rpipe, select.POLLIN)

    while running:
        events = poller.poll()        # block: netlink events or a signal
        for fd, _ in events:
            if fd == rpipe:
                os.read(rpipe, 64)    # drain wakeup bytes
                continue
            try:
                for _ in mon.get():   # drain; message contents don't
                    pass              # matter, reconcile is idempotent
            except OSError:
                pass                  # ENOBUFS et al.: reconcile anyway
        if running:
            for i in ifaces:
                i.reconcile()

    for i in ifaces:
        if i.installed_via:
            i.withdraw("daemon shutdown")
    ipr.close()
    mon.close()
    syslog.closelog()


if __name__ == "__main__":
    main()
