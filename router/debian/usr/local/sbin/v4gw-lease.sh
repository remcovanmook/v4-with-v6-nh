#!/bin/sh
# dnsmasq dhcp-script: maintain the RFC 5549 return route for each leased
# host.  dnsmasq invokes us as:  <action> <mac> <ipaddr> [hostname]
# and exports DNSMASQ_INTERFACE.
#
# The router reaches a host's IPv4 /32 over the IPv6-only segment via the
# host's own IPv6 address (RFC 5549 / "ip route ... via inet6").  We discover
# that address by matching the DHCP client's MAC in the router's own neighbor
# cache -- no route-distribution protocol needed for the demo.
set -eu

action=${1:-}
mac=${2:-}
ip4=${3:-}
IF=${DNSMASQ_INTERFACE:-}

[ -n "$IF" ] || exit 0
[ -n "$ip4" ] || exit 0

# Fallback return next-hop, read from the router's own ND cache by matching the
# DHCP MAC: a global address the host has actually been using (e.g. an RFC 7217
# GUA a renewing host formed) if one is cached, else the link-local its Router
# Solicitation left behind.  A cached GUA is preferred -- unlike a link-local,
# which is only meaningful one hop away, it survives a DHCP relay or a routed
# access layer.  Only *resolved* neighbours carry the MAC on their line, so
# INCOMPLETE/FAILED entries are skipped for free.  (A host using RFC 8981
# privacy temporaries can yield a rotating GUA -- servers keep use_tempaddr=0.)
find_nexthop() {
	ip -6 neigh show dev "$IF" 2>/dev/null | awk \
	    -v m="$(printf '%s' "$mac" | tr 'A-Z' 'a-z')" '
	    index(tolower($0), m) {
	        if ($1 ~ /^fe80:/)                          { if (ll  == "") ll  = $1 }
	        else if (gua == "" && $1 ~ /^([23]|f[cd])/) { gua = $1 }
	    }
	    END { if (gua != "") print gua; else if (ll != "") print ll }'
}

# Preferred return next-hop: the host's stable EUI-64 GUA.  We DERIVE it
# (advertised /64 + modified-EUI-64 of the DHCP MAC), so the address is already
# known; the only open question is whether the host actually formed it, which an
# ndisc6 Neighbor Solicitation answers.  Nothing is written to the neighbour
# cache -- the /32 route below carries this GUA as its next hop and the kernel
# resolves it by ND on the first return packet, as for any route.  A GUA is
# stable across the host's EUI-64 -> RFC 7217 link-local churn and, unlike a
# link-local, survives a DHCP relay or a routed access layer.  A host using
# RFC 7217 for its GUA has no EUI-64 address: the probe times out and we fall
# back to find_nexthop's link-local.  ndisc6 is optional; without it we skip
# straight to find_nexthop.  (Assumes a standard /64 prefix; at scale the
# operator supplies the stable identity via PD / route distribution.)
gua_nexthop() {
	command -v ndisc6 >/dev/null 2>&1 || return 0
	pfx=$(ip -6 route show dev "$IF" 2>/dev/null | \
	    awk '$1 ~ /^([23]|f[cd]).*::\/64$/ { sub(/\/64$/,"",$1); print $1; exit }')
	[ -n "$pfx" ] || return 0
	o1=${mac%%:*}; r=${mac#*:}; o2=${r%%:*}; r=${r#*:}
	o3=${r%%:*}; r=${r#*:}; o4=${r%%:*}; r=${r#*:}
	o5=${r%%:*}; o6=${r##*:}
	b1=$(printf '%02x' "$(( 0x$o1 ^ 2 ))") || return 0
	gua="${pfx}${b1}${o2}:${o3}ff:fe${o4}:${o5}${o6}"
	ndisc6 -1 -q -w 1000 "$gua" "$IF" >/dev/null 2>&1 || return 0
	printf '%s\n' "$gua"
}

case "$action" in
add|old)
	# The /32 must carry an IPv6 next hop: without it, dnsmasq's reply --
	# pinned to this interface -- has no via-inet6 to follow and the kernel
	# resolves the host's IPv4 on-link (ARP), leaving exactly the per-lease
	# ARP entry we want to avoid.  Prefer the derived+verified EUI-64 GUA;
	# fall back to a cached next hop, then to an all-nodes probe that surfaces
	# a link-local.  The kernel resolves whichever we pick by ND when the
	# first return packet needs it.
	nh=$(gua_nexthop)
	[ -n "$nh" ] || nh=$(find_nexthop)
	if [ -z "$nh" ]; then
		ping -6 -c1 -W1 "ff02::1%$IF" >/dev/null 2>&1 || \
		    ping6 -c1 -W1 "ff02::1%$IF" >/dev/null 2>&1 || true
		nh=$(find_nexthop)
	fi
	if [ -n "$nh" ]; then
		ip route replace "$ip4/32" via inet6 "$nh" dev "$IF"
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
