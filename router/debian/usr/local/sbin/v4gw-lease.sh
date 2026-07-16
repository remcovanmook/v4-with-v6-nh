#!/bin/sh
# dnsmasq dhcp-script: maintain the RFC 5549 return route for each leased
# host.  dnsmasq invokes us as:  <action> <mac> <ipaddr> [hostname]
# and exports DNSMASQ_INTERFACE.
#
# The router reaches a host's IPv4 /32 over the IPv6-only segment via the
# host's link-local (RFC 5549 / "ip route ... via inet6").  We discover
# that link-local by matching the DHCP client's MAC in the router's own
# neighbor cache -- no route-distribution protocol needed for the demo.
set -eu

action=${1:-}
mac=${2:-}
ip4=${3:-}
IF=${DNSMASQ_INTERFACE:-}

[ -n "$IF" ] || exit 0
[ -n "$ip4" ] || exit 0

# The client's link-local is the ND-cache entry whose MAC matches the DHCP
# MAC (works regardless of EUI-64 vs. randomised LLAs).  Match the MAC
# anywhere on the line so the field position of "ip -6 neigh show dev <if>"
# (lladdr in $3) vs. without dev ($5) does not matter.
find_ll() {
	ip -6 neigh show dev "$IF" 2>/dev/null | awk \
	    -v m="$(printf '%s' "$mac" | tr 'A-Z' 'a-z')" \
	    'index(tolower($0), m) && $1 ~ /^fe80/ { print $1; exit }'
}

case "$action" in
add|old)
	# A host that only speaks DHCPv4 may not have populated the router's
	# ND cache yet.  Without the /32 route below, dnsmasq's reply to the
	# client -- sent pinned to this interface -- has no via-inet6 next hop
	# to follow, so the kernel falls back to resolving the host's IPv4
	# on-link (ARP), leaving exactly the per-lease ARP entry we want to
	# avoid.  So on a cache miss, provoke Neighbor Discovery once and retry.
	ll=$(find_ll)
	if [ -z "$ll" ]; then
		ping -6 -c1 -W1 "ff02::1%$IF" >/dev/null 2>&1 || \
		    ping6 -c1 -W1 "ff02::1%$IF" >/dev/null 2>&1 || true
		ll=$(find_ll)
	fi
	if [ -n "$ll" ]; then
		# Pin the source to the link-scoped sentinel (also the DHCP
		# server-id): otherwise the kernel prefers the global-scoped
		# target 203.0.113.1 as the source for replies and return
		# traffic, so clients would see answers from the wrong address.
		ip route replace "$ip4/32" via inet6 "$ll" dev "$IF" \
		    src 192.0.0.11
	fi
	# Drop any IPv4 neighbour entry the kernel formed for this host.  With
	# the /32 routed via inet6 it is never consulted for forwarding, and
	# it is precisely the "ARP entry for a leased host" we do not want; if
	# the route above is in place, none reappears.
	ip -4 neigh del "$ip4" dev "$IF" 2>/dev/null || true
	;;
del)
	ip route del "$ip4/32" 2>/dev/null || true
	ip -4 neigh del "$ip4" dev "$IF" 2>/dev/null || true
	;;
esac
exit 0
