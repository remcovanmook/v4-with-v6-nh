#!/bin/sh
# v4-with-v6-nh interop testbed router (Debian 13).
#
# Configures the IPv6-only host segment and the RFC 5549 data plane on a
# Linux router; dnsmasq (see dnsmasq.conf) then advertises the router via
# RA and hands out IPv4 /32 leases with the special-purpose gateway
# 192.0.0.11, while v4gw-lease.sh installs the return routes per lease.
#
# The host-facing segment carries no IPv4 subnet: only 192.0.0.11/32
# (interface-scoped) and the routers' link-local / IPv6 GUAs.  Hosts reach
# 203.0.113.1 (a target behind the router) with their v4gwd variant.
#
# Usage: sudo ./setup.sh <host-facing-interface>   (e.g. enp1s0)
set -eu

IF=${1:?usage: setup.sh <host-facing-interface>}

# Forwarding, both families.
sysctl -qw net.ipv4.ip_forward=1 \
           net.ipv6.conf.all.forwarding=1 \
           "net.ipv6.conf.${IF}.forwarding=1"

ip link set "$IF" up

# IPv6-only host segment: a GUA + the auto link-local on the router.
# No IPv4 subnet is configured here -- that is the whole point.
ip -6 addr replace 2001:db8:1::a/64 dev "$IF"

# The special-purpose gateway: interface-scoped (scope link, so it is
# never a source toward off-link destinations and never redistributed),
# and answers ARP for the unmodified-host / static-ARP tier.
ip addr replace 192.0.0.11/32 scope link dev "$IF"

# The host segment gets NO IPv4 address here -- only 192.0.0.11 above.
# dnsmasq serves the 198.51.100.0/24 pool on this interface via its
# "shared-network" option (see dnsmasq.conf), so host return traffic uses
# the per-host RFC 5549 /32 routes, never an ARP-resolved connected route.

# A stable IPv4 target behind the router for the hosts to ping.
ip addr replace 203.0.113.1/32 dev lo

# NAT the testbed out the uplink so the hosts reach the real Internet:
# 198.51.100.0/24 and 2001:db8:1::/64 are both documentation prefixes,
# not globally routable.  The uplink is whatever carries the default
# route.  Idempotent: each table is flushed and rebuilt.
UPLINK=$(ip -4 route show default | awk '{print $5; exit}')
UPLINK6=$(ip -6 route show default | awk '{print $5; exit}')
if [ -n "$UPLINK" ]; then
    nft add table ip v4gw_nat 2>/dev/null || true
    nft flush table ip v4gw_nat
    nft add chain ip v4gw_nat postrouting '{ type nat hook postrouting priority 100 ; }'
    nft add rule ip v4gw_nat postrouting \
        ip saddr 198.51.100.0/24 oifname "$UPLINK" masquerade
fi
if [ -n "${UPLINK6:-$UPLINK}" ]; then
    nft add table ip6 v4gw_nat 2>/dev/null || true
    nft flush table ip6 v4gw_nat
    nft add chain ip6 v4gw_nat postrouting '{ type nat hook postrouting priority 100 ; }'
    nft add rule ip6 v4gw_nat postrouting \
        ip6 saddr 2001:db8:1::/64 oifname "${UPLINK6:-$UPLINK}" masquerade
fi

echo "router ready on $IF:"
echo "  gateway  : 192.0.0.11 (interface-scoped)"
echo "  target   : 203.0.113.1 (ping this from the hosts)"
echo "  next     : dnsmasq --conf-file=dnsmasq.conf  (RA + DHCPv4 + returns)"
