# Debian router for the interop testbed

An open-source Linux router that ties the host implementations
(`host/v4gwd.py` on Fedora, `host/freebsd/` on FreeBSD, `host/macos/` on
macOS) into one travelling demo, complementing the commercial examples in
`../vendor-configs/`. Debian 13 (kernel 6.x) has the RFC 5549 data plane
(`ip route ... via inet6`) the return path needs.

## Topology

```text
   Fedora ─┐
  FreeBSD ─┼─ IPv6-only segment ── Debian router ── 203.0.113.1 (target)
    macOS ─┘        (no IPv4 subnet)
```

The host segment carries **no IPv4 subnet** — only `192.0.0.11/32`
(interface-scoped) and the router's link-local / `2001:db8:1::a/64`. Hosts
get an IPv4 `/32` from `198.51.100.0/24` and reach `203.0.113.1` behind the
router; there is never any ARP for anything but 192.0.0.11 (and the host
daemons suppress even that).

## What each piece does

- **`setup.sh <iface>`** — enables forwarding, puts the router's IPv6 GUA
  and `192.0.0.11/32 scope link` on the host interface, and adds the ping
  target `203.0.113.1` on `lo`.
- **`dnsmasq.conf`** — RA (advertises this router as the IPv6 default
  router + SLAAC prefix) and DHCPv4 (`/32` leases, `Router=192.0.0.11`,
  plus RFC 3442 classless routes for clients that need the off-subnet
  gateway spelled out).
- **`v4gw-lease.sh`** (dnsmasq `dhcp-script`) — installs each host's RFC
  5549 return route `198.51.100.x/32 via inet6 <host-ll>`, finding the
  link-local by matching the DHCP MAC in the router's ND cache. This
  stands in for real route distribution (BGP/RFC 8950), which is out of
  scope here.

The host segment carries **no IPv4 address on the router** — only
`192.0.0.11/32`. dnsmasq still serves the pool there via its
`shared-network` option (the `192.0.0.11` address selects the interface
and becomes the DHCP server-id, so renewals unicast to the gateway).
`setup.sh` also NATs both families out the uplink, so the hosts reach the
real internet over their `/32` / documentation-prefix addresses.

## Run

Quick (foreground, to watch):

```sh
sudo apt install dnsmasq
sudo systemctl disable --now dnsmasq       # free the packaged instance
sudo install -m 755 v4gw-lease.sh /usr/local/sbin/v4gw-lease.sh
# edit interface= in dnsmasq.conf, then:
sudo ./setup.sh enp0s2                      # host-facing interface
sudo dnsmasq --conf-file=$PWD/dnsmasq.conf --no-daemon
```

Persistent (reboot-safe, systemd):

```sh
sudo mkdir -p /etc/v4gw && sudo cp setup.sh dnsmasq.conf /etc/v4gw/
sudo cp systemd/*.service /etc/systemd/system/     # edit the interface in each
sudo systemctl daemon-reload
sudo systemctl enable --now v4gw-router v4gw-dnsmasq
```

On the hosts, run the matching daemon (`v4gwd`, `v4gwd.py`, or
`v4gwd-arp`) and `ping 203.0.113.1` (or `1.1.1.1`).

## Per-host notes

The one fiddly cross-OS point is the DHCPv4 client accepting an
**off-subnet** default gateway (192.0.0.11 is in no host subnet). Clients
that honour option 121 (most Linux, recent macOS) get an explicit on-link
route for it; where a client refuses, set the host's IPv4 `/32` and
`default via 192.0.0.11` by hand and run the daemon in `-r`/unconditional
mode — the router side is unchanged either way.

## Status

Validated on a live testbed (Debian 13, kernel 6.12) serving real
macOS 26, FreeBSD 15.1 and Linux hosts over a bridged IPv6-only segment:
dnsmasq serves DHCPv4 with no IPv4 address on the interface
(`shared-network`), the `/32` handout and RA are honoured across all
three OSes, the lease hook installs each host's RFC 5549 return route,
and the hosts reach both a target behind the router and the real IPv4/
IPv6 internet. Reboot-safe via the systemd units.
