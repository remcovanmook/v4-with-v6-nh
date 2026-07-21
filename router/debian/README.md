# Debian router for the interop testbed

An open-source Linux router that ties the host implementations
(`host/v4gwd.py` on Fedora, `host/freebsd/` on FreeBSD, `host/macos/` on
macOS, `host/windows/` on Windows) into one travelling demo, complementing
the commercial examples in `../vendor-configs/`. Debian 13 (kernel 6.x) has
the RFC 5549 data plane (`ip route ... via inet6`) the return path needs.

## Topology

```text
   Fedora ─┐
  FreeBSD ─┤
    macOS ─┼─ IPv6-only segment ── Debian router ── 203.0.113.1 (target)
  Windows ─┘        (no IPv4 subnet)
```

The host segment carries **no IPv4 subnet** — only `192.0.0.11/32`
(interface-scoped) and the router's link-local / `2001:db8:1::a/64`. Hosts
get an IPv4 `/32` from `198.51.100.0/24` and reach `203.0.113.1` behind the
router; there is never any ARP for anything but 192.0.0.11 (and the host
daemons suppress even that).

## What each piece does

The router state lives in native config, each in its canonical location (the
`etc/` tree here mirrors `/etc/`):

- **`etc/sysctl.d/99-v4gw.conf`** — enables IPv4 + IPv6 forwarding, and keeps
  `accept_ra=2` on the uplink so it still learns its SLAAC address / default
  route once forwarding is on.
- **`etc/network/interfaces.d/v4gw`** — brings up the host interface with the
  router's IPv6 GUA and `192.0.0.11/32 scope link`, and puts the ping target
  `203.0.113.1/32` on `lo`.
- **`etc/nftables.conf`** — NATs both documentation prefixes out the uplink
  (`oifname != <host-iface>`, so it needs no default route present at load
  time). Loaded by `nftables.service`.
- **`etc/v4gw/dnsmasq.conf`** (run by **`etc/systemd/system/v4gw-dnsmasq.service`**)
  — RA (advertises this router as the IPv6 default router + SLAAC prefix, with
  RDNSS) and DHCPv4 (`/32` leases, `Router=192.0.0.11`, no option 6/121/249).
- **`usr/local/sbin/v4gw-lease.sh`** (dnsmasq `dhcp-script`, one-shot) — installs
  each host's RFC 5549 return route `198.51.100.x/32 via inet6 <host-IPv6>`, finding
  the next hop by the DHCP MAC in the router's ND cache. It prefers a stable
  global address over the link-local — deriving the host's EUI-64 GUA and
  confirming it with a neighbor solicitation (`ndisc6`); the kernel resolves
  that next hop lazily — so the route stays routable beyond the local link. A host using
  RFC 7217 for its GUA (the systemd/NetworkManager default) has no MAC-derived
  GUA to provoke and falls back to its stable link-local, routable only on the
  directly-attached segment. This hook stands in for route distribution
  (BGP/RFC 8950); at scale the operator supplies a stable per-subscriber IPv6
  identity via SAVI/ND-snooping (RFC 7513), DHCPv6-PD, or their own SOP.

dnsmasq serves the IPv4 pool on an interface with no IPv4 address of its own
via its `shared-network` option (the `192.0.0.11` address selects the
interface and becomes the DHCP server-id, so renewals unicast to the gateway).

## Install

Interface names are site-specific — edit the uplink in `99-v4gw.conf` and the
host-facing interface in `interfaces.d/v4gw`, `nftables.conf`, and
`v4gw/dnsmasq.conf` (this testbed uses `enp0s1` uplink, `enp0s2` host segment).

```sh
sudo apt install dnsmasq nftables ndisc6
sudo systemctl disable --now dnsmasq        # free the packaged instance

# The tree mirrors its destinations:
sudo cp etc/sysctl.d/99-v4gw.conf                /etc/sysctl.d/
sudo cp etc/network/interfaces.d/v4gw            /etc/network/interfaces.d/
sudo cp etc/nftables.conf                        /etc/nftables.conf   # merge if you already have rules
sudo mkdir -p /etc/v4gw && sudo cp etc/v4gw/dnsmasq.conf /etc/v4gw/
sudo cp etc/systemd/system/v4gw-dnsmasq.service  /etc/systemd/system/
sudo install -m 755 usr/local/sbin/v4gw-lease.sh /usr/local/sbin/

sudo systemctl daemon-reload
sudo sysctl --system                        # forwarding + accept_ra
sudo systemctl enable --now nftables        # NAT
sudo ifup enp0s2                            # host segment (or just reboot)
sudo systemctl enable --now v4gw-dnsmasq    # RA + DHCPv4
# logs: journalctl -u v4gw-dnsmasq -f
```

### Return route: one-shot hook or tracking daemon

`v4gw-lease.sh` resolves the next hop once, when dnsmasq fires. Its parallel is
**`usr/local/sbin/v4gwrd.py`** — a long-running daemon (the router mirror of
`host/v4gwd.py`) that *follows* each host's live IPv6 next hop the way `v4gwd`
follows the host's live gateway. dnsmasq then runs the thin
**`usr/local/sbin/v4gw-lease-notify.sh`**, which only forwards
`<action> <iface> <mac> <ip4>` to the daemon's FIFO; the daemon owns the route.
It adopts the stable EUI-64 GUA as soon as it resolves (winning the cold-lease
race), re-slaves across link-local churn or a neighbor failure, and rebuilds its
routes from `/var/lib/v4gwrd/leases` on restart. Choose one as the `dhcp-script`:

```sh
sudo install -m 755 usr/local/sbin/v4gwrd.py            /usr/local/sbin/
sudo install -m 755 usr/local/sbin/v4gw-lease-notify.sh /usr/local/sbin/
sudo cp etc/systemd/system/v4gwrd.service               /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now v4gwrd
# then point dhcp-script= at the notifier and restart dnsmasq:
sudo sed -i 's#dhcp-script=.*#dhcp-script=/usr/local/sbin/v4gw-lease-notify.sh#' /etc/v4gw/dnsmasq.conf
sudo systemctl restart v4gw-dnsmasq
# logs: journalctl -u v4gwrd -f
```

The daemon needs only Python 3 + pyroute2, and solicits next hops through the
kernel's own ND — so unlike the one-shot hook it needs no `ndisc6`.

It is reboot-safe by construction: `systemd-sysctl`, `nftables.service`,
`ifupdown`, and `v4gw-dnsmasq.service` each restore their own part. On the
hosts, run the matching daemon (`v4gwd`, `v4gwd.py`, `v4gwd-arp`, or
`v4gwd.ps1`) and `ping 203.0.113.1` (or `1.1.1.1`).

## Per-host notes

The DHCPv4 client must accept an off-subnet default gateway (192.0.0.11 is in
no host subnet); Linux, FreeBSD, macOS and Windows all do. Option 121 and
Microsoft's option 249 must not be sent — per RFC 3442 they take precedence
over option 3 and defeat the IPv6-resolved path (see the notes in
`dnsmasq.conf`). If a client refuses the off-subnet gateway, set the host's
IPv4 `/32` and `default via 192.0.0.11` by hand; the router side is unchanged.

## Status

Validated on a live testbed (Debian 13, kernel 6.12) serving real
macOS 26, FreeBSD 15.1, Linux, and Windows 11 (ARM64) hosts over a bridged
IPv6-only segment: dnsmasq serves DHCPv4 with no IPv4 address on the interface
(`shared-network`), the `/32` handout and RA (with RDNSS) are honoured across
all four OSes, the lease hook installs each host's RFC 5549 return route, and
the hosts reach both a target behind the router and the real IPv4/IPv6
internet. The native config is reboot-safe — verified cold: forwarding, NAT,
addresses, and dnsmasq all come up from config alone.
