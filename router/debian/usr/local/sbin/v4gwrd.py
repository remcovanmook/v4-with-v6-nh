#!/usr/bin/env python3
"""v4gwrd - IPv6-Resolved IPv4 Gateway return-route daemon (router side).

Router-side companion to host/v4gwd.py for
draft-vanmook-intarea-ipv6-resolved-gateway.  The router reaches each host's
IPv4 /32 over the IPv6-only segment via the host's own IPv6 address (RFC 5549 /
"ip route ... via inet6").  The host's usable IPv6 identity is live state -- it
churns at bring-up (EUI-64 -> RFC 7217 link-local), a stable GUA may appear a
moment after the DHCPv4 lease, a neighbour may fail -- so, symmetrically to the
way v4gwd makes a host follow the live IPv6 gateway, this daemon makes the
router follow each host's live IPv6 next hop.

It is the tracking alternative to the one-shot dnsmasq dhcp-script
(usr/local/sbin/v4gw-lease.sh); pick one.  dnsmasq still triggers it, but only
as a thin notifier: v4gw-lease-notify.sh writes "<action> <iface> <mac> <ip4>"
to the FIFO this daemon reads.  From there the daemon owns the return route:

  1. on a lease it records the host and installs "<ip4>/32 via inet6 <next-hop>",
     tagged rt proto 195 so its routes are identifiable;
  2. it prefers the host's stable EUI-64 GUA (advertised /64 + modified-EUI-64
     of the DHCP MAC) over any other GUA, and a link-local last; the next hop is
     resolved by the kernel's own Neighbor Discovery, never ARP;
  3. it watches rtnetlink NEWNEIGH/DELNEIGH and re-slaves the route the moment a
     host's best next hop changes -- adopting the stable GUA once it resolves
     (cold-lease race), riding out link-local churn, falling back if it fails;
  4. on a lease release it withdraws the route.

Nothing is pinned into the neighbour cache: an inet6 next hop is resolved by ND
on demand.  The daemon solicits the derived GUA (a throwaway datagram, kernel-
originated ND) once per lease, after a settle delay, then relies on reactive
adoption; a host that never forms an EUI-64 GUA (link-local only, or RFC 7217
for its GUA too) simply stays on its link-local without further solicitation.

Reconciliation is idempotent; a periodic sweep re-evaluates every host, so a
monitor overrun or a missed event self-heals within RECONCILE_SEC.

Usage:  v4gwrd.py            (no options; the interface comes from each event)
"""

import errno
import ipaddress
import os
import select
import signal
import socket
import sys
import syslog
import time

from pyroute2 import IPRoute
from pyroute2.netlink import rtnl
from pyroute2.netlink.exceptions import NetlinkError

RT_PROTO = 195              # marks return routes owned by this daemon
FIFO = "/run/v4gwrd/events"
STATE = "/var/lib/v4gwrd/leases"
LEASES = "/var/lib/misc/dnsmasq.leases"
RECONCILE_SEC = 15          # periodic self-heal sweep
GUA_PROBE_DELAY = 15        # settle time before the single GUA solicitation,
                            # ~one RA interval so the host has formed its GUA
NUD_USABLE = {0x02, 0x04, 0x08, 0x10}   # REACHABLE, STALE, DELAY, PROBE

running = True


def log(msg, prio=syslog.LOG_NOTICE):
    syslog.syslog(prio, msg)
    print(msg, file=sys.stderr, flush=True)


def stop(signum, frame):
    global running
    running = False


def is_global_or_ula(addr):
    b0 = ipaddress.IPv6Address(addr).packed[0]
    return 0x20 <= b0 <= 0x3f or b0 in (0xfc, 0xfd)     # 2000::/3 or fc00::/7


def derive_gua(net, mac):
    """The host's EUI-64 GUA: advertised /64 + modified-EUI-64 of the MAC."""
    try:
        mb = bytes(int(x, 16) for x in mac.split(":"))
    except ValueError:
        return None
    if len(mb) != 6:
        return None
    iid = bytes([mb[0] ^ 0x02, mb[1], mb[2], 0xff, 0xfe, mb[3], mb[4], mb[5]])
    addr = int(net.network_address) | int.from_bytes(iid, "big")
    return str(ipaddress.IPv6Address(addr))


def kick_nud(ifname, addr):
    """Solicit `addr` by handing the kernel a throwaway datagram, so the kernel
    originates the Neighbor Solicitation (populating its own cache on reply)."""
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, ifname.encode())
        s.sendto(b"", (addr, 9))
        s.close()
    except OSError:
        pass


class Manager:
    def __init__(self, ipr):
        self.ipr = ipr
        self.hosts = {}    # mac -> {"iface": str, "ip4": str, "nh": str|None}

    # -- inspection --------------------------------------------------------

    def _index(self, ifname):
        links = self.ipr.link_lookup(ifname=ifname)
        return links[0] if links else None

    def _prefix(self, idx):
        """The interface's on-link global/ULA /64 (the advertised prefix)."""
        for r in self.ipr.get_routes(family=socket.AF_INET6):
            if r["dst_len"] != 64 or r.get_attr("RTA_OIF") != idx:
                continue
            dst = r.get_attr("RTA_DST")
            if dst and is_global_or_ula(dst):
                return ipaddress.IPv6Network(f"{dst}/64", strict=False)
        return None

    def _cache(self, idx, mac):
        """The host's IPv6 addresses in the router's ND cache: dst -> state."""
        out = {}
        try:
            neigh = self.ipr.get_neighbours(family=socket.AF_INET6, ifindex=idx)
        except NetlinkError:
            return out
        for n in neigh:
            lla = n.get_attr("NDA_LLADDR")
            dst = n.get_attr("NDA_DST")
            if lla and dst and lla.lower() == mac:
                out[dst] = n["state"]
        return out

    def best_nexthop(self, idx, mac):
        """(next hop, derived GUA): prefer the stable EUI-64 GUA, then any other
        cached GUA, then the link-local.  The GUA is returned regardless so the
        caller can keep soliciting it until the host is reachable at it."""
        prefix = self._prefix(idx)
        gua = derive_gua(prefix, mac) if prefix else None
        cache = self._cache(idx, mac)
        if gua and cache.get(gua, 0) in NUD_USABLE:
            return gua, gua
        for dst, st in cache.items():
            if st in NUD_USABLE and is_global_or_ula(dst):
                return dst, gua
        for dst, st in cache.items():
            if st in NUD_USABLE and dst.startswith("fe80"):
                return dst, gua
        return None, gua

    # -- programming -------------------------------------------------------

    def install(self, ifname, idx, ip4, nh):
        try:
            self.ipr.route("replace", family=socket.AF_INET, dst=f"{ip4}/32",
                           oif=idx, proto=RT_PROTO,
                           via={"family": socket.AF_INET6, "addr": nh})
            log(f"{ifname}: return route {ip4}/32 -> via inet6 {nh}")
        except NetlinkError as e:
            log(f"{ifname}: failed to install {ip4}/32 via {nh}: {e}",
                syslog.LOG_ERR)
            return
        # Drop any IPv4 neighbour the kernel formed: the /32 routes via inet6,
        # so it is never consulted, and it is the per-lease ARP entry we avoid.
        try:
            self.ipr.neigh("del", family=socket.AF_INET, dst=ip4, ifindex=idx)
        except NetlinkError:
            pass

    def withdraw(self, ip4, reason):
        try:
            self.ipr.route("del", family=socket.AF_INET, dst=f"{ip4}/32",
                           proto=RT_PROTO)
            log(f"withdrew return route {ip4}/32 ({reason})")
        except NetlinkError as e:
            if e.code != errno.ESRCH:
                log(f"failed to withdraw {ip4}/32: {e}", syslog.LOG_ERR)

    # -- evaluation --------------------------------------------------------

    def evaluate(self, mac):
        h = self.hosts.get(mac)
        if h is None:
            return
        idx = self._index(h["iface"])
        if idx is None:
            return                          # interface gone; sweep will retry
        nh, gua = self.best_nexthop(idx, mac)
        # Solicit the derived GUA at most once per lease, after a settle delay
        # (one RA interval, so the host has had time to form its SLAAC GUA).
        # A link-local-only or RFC 7217 host never answers; we then stay quiet
        # and rely on reactive NEWNEIGH adoption, rather than re-soliciting a
        # nonexistent address on every sweep.
        if gua and nh == gua:
            h["probe_at"] = None             # already on the GUA; nothing to do
        elif (gua and h.get("probe_at") is not None
                and time.monotonic() >= h["probe_at"]):
            kick_nud(h["iface"], gua)
            h["probe_at"] = None             # one solicitation per lease
        if nh is None or nh == h["nh"]:
            return
        self.install(h["iface"], idx, h["ip4"], nh)
        h["nh"] = nh

    def reconcile_all(self):
        for mac in list(self.hosts):
            self.evaluate(mac)

    # -- events ------------------------------------------------------------

    def on_lease(self, iface, mac, ip4):
        h = self.hosts.get(mac)
        if h and (h["iface"] != iface or h["ip4"] != ip4):
            self.withdraw(h["ip4"], "lease changed")
            h = None
        if h is None:
            h = self.hosts[mac] = {"iface": iface, "ip4": ip4, "nh": None}
        h["probe_at"] = time.monotonic() + GUA_PROBE_DELAY   # one GUA check per lease
        self.persist()
        self.evaluate(mac)

    def on_release(self, mac, ip4):
        h = self.hosts.pop(mac, None)
        if h:
            self.withdraw(h["ip4"], "lease released")
            self.persist()

    def handle_line(self, line):
        p = line.split()
        if len(p) < 4:
            return
        action, iface, mac, ip4 = p[0], p[1], p[2].lower(), p[3]
        if action in ("add", "old"):
            self.on_lease(iface, mac, ip4)
        elif action in ("del",):
            self.on_release(mac, ip4)

    # -- persistence (survive a daemon restart) ----------------------------

    def persist(self):
        try:
            os.makedirs(os.path.dirname(STATE), exist_ok=True)
            tmp = STATE + ".tmp"
            with open(tmp, "w") as f:
                for mac, h in self.hosts.items():
                    f.write(f"{mac} {h['iface']} {h['ip4']}\n")
            os.replace(tmp, STATE)
        except OSError as e:
            log(f"state write failed: {e}", syslog.LOG_ERR)

    def restore(self):
        """Reload our table on startup and prune leases dnsmasq has since
        dropped (a lease that expired while we were down)."""
        live = self._live_leases()
        try:
            with open(STATE) as f:
                lines = f.read().splitlines()
        except OSError:
            return
        for line in lines:
            p = line.split()
            if len(p) != 3:
                continue
            mac, iface, ip4 = p[0].lower(), p[1], p[2]
            if live is not None and (mac, ip4) not in live:
                continue                    # expired while we were down
            self.hosts[mac] = {"iface": iface, "ip4": ip4, "nh": None,
                               "probe_at": time.monotonic() + GUA_PROBE_DELAY}
        if self.hosts:
            log(f"restored {len(self.hosts)} lease(s) from {STATE}")

    @staticmethod
    def _live_leases():
        """{(mac, ip4)} currently in the dnsmasq leases file, or None if it
        can't be read (then we trust our own state and prune nothing)."""
        try:
            with open(LEASES) as f:
                rows = f.read().splitlines()
        except OSError:
            return None
        live = set()
        for row in rows:
            c = row.split()
            if len(c) >= 3:
                live.add((c[1].lower(), c[2]))
        return live


def open_fifo():
    os.makedirs(os.path.dirname(FIFO), exist_ok=True)
    try:
        os.mkfifo(FIFO, 0o600)
    except FileExistsError:
        pass
    # O_RDWR keeps a writer on the pipe so reads never see EOF; non-blocking so
    # a quiet FIFO does not stall the poll loop.
    return os.open(FIFO, os.O_RDWR | os.O_NONBLOCK)


def serve(mgr, fifo_fd, mon, rpipe):
    poller = select.poll()
    poller.register(fifo_fd, select.POLLIN)
    poller.register(mon.fileno(), select.POLLIN)
    poller.register(rpipe, select.POLLIN)
    buf = b""
    while running:
        events = poller.poll(RECONCILE_SEC * 1000)
        if not events:
            mgr.reconcile_all()             # periodic self-heal
            continue
        for fd, _ in events:
            if fd == rpipe:
                os.read(rpipe, 64)
            elif fd == fifo_fd:
                try:
                    buf += os.read(fifo_fd, 4096)
                except OSError:
                    continue
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    mgr.handle_line(line.decode(errors="replace"))
            else:
                try:
                    for _ in mon.get():     # drain; reconcile is idempotent
                        pass
                except OSError:
                    pass
                if running:
                    mgr.reconcile_all()


def main():
    syslog.openlog(ident="v4gwrd", facility=syslog.LOG_DAEMON)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    rpipe, wpipe = os.pipe()
    os.set_blocking(wpipe, False)
    signal.set_wakeup_fd(wpipe)

    ipr = IPRoute()
    mon = IPRoute()
    mon.bind(groups=rtnl.RTMGRP_IPV4_ROUTE |
                    rtnl.RTMGRP_IPV6_ROUTE |
                    rtnl.RTMGRP_LINK |
                    rtnl.RTMGRP_NEIGH)

    mgr = Manager(ipr)
    fifo_fd = open_fifo()
    mgr.restore()
    log("starting: tracking return routes, following each host's IPv6 next hop")
    mgr.reconcile_all()

    serve(mgr, fifo_fd, mon, rpipe)

    os.close(fifo_fd)
    try:
        os.unlink(FIFO)                     # let the notifier see the daemon is gone
    except OSError:
        pass
    ipr.close()
    mon.close()
    syslog.closelog()


if __name__ == "__main__":
    main()
