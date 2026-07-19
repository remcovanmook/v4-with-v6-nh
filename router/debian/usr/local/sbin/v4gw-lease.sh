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

# The client's return next-hop, discovered from the router's own ND cache by
# matching the DHCP MAC.  Prefer a global address (in the advertised prefix)
# over the link-local: a GUA is stable across the EUI-64 -> RFC 7217
# link-local churn seen at bring-up, and -- unlike a link-local, which is only
# meaningful one hop away -- it is a routable next-hop that survives a DHCP
# relay or a routed access layer.  Fall back to the link-local for a host that
# has not formed a GUA yet.  Only *resolved* neighbours carry the MAC on their
# line, so stale INCOMPLETE/FAILED entries (e.g. an abandoned EUI-64 LL) are
# skipped for free.  (Assumes one advertised prefix per segment; a host using
# RFC 8981 privacy temporaries can yield a rotating GUA -- servers keep
# use_tempaddr=0.)
find_nexthop() {
	ip -6 neigh show dev "$IF" 2>/dev/null | awk \
	    -v m="$(printf '%s' "$mac" | tr 'A-Z' 'a-z')" '
	    index(tolower($0), m) {
	        if ($1 ~ /^fe80:/)                          { if (ll  == "") ll  = $1 }
	        else if (gua == "" && $1 ~ /^([23]|f[cd])/) { gua = $1 }
	    }
	    END { if (gua != "") print gua; else if (ll != "") print ll }'
}

# Actively resolve the host's stable GUA into the ND cache before we look it
# up.  At a cold lease the router has only seen the host's link-local (from its
# Router Solicitation); its GUA is never solicited, and an all-nodes probe
# surfaces only link-locals.  We form the host's EUI-64 GUA (advertised /64 +
# modified-EUI-64 of the DHCP MAC) and ping it -- that address is stable across
# the host's EUI-64 -> RFC 7217 link-local churn.  A host that uses RFC 7217
# for its GUA too has no such address, so this is a harmless miss and we fall
# back to its (equally stable) link-local.  (Assumes a standard /64 prefix; at
# scale the operator supplies the stable identity via PD / route distribution.)
provoke_gua() {
	pfx=$(ip -6 route show dev "$IF" 2>/dev/null | \
	    awk '$1 ~ /^([23]|f[cd]).*::\/64$/ { sub(/\/64$/,"",$1); print $1; exit }')
	[ -n "$pfx" ] || return 0
	o1=${mac%%:*}; r=${mac#*:}; o2=${r%%:*}; r=${r#*:}
	o3=${r%%:*}; r=${r#*:}; o4=${r%%:*}; r=${r#*:}
	o5=${r%%:*}; o6=${r##*:}
	b1=$(printf '%02x' "$(( 0x$o1 ^ 2 ))") || return 0
	gua="${pfx}${b1}${o2}:${o3}ff:fe${o4}:${o5}${o6}"
	ping -6 -c1 -W1 "$gua" >/dev/null 2>&1 || \
	    ping6 -c1 -W1 "$gua" >/dev/null 2>&1 || true
}

case "$action" in
add|old)
	# A host that only speaks DHCPv4 may not have populated the router's
	# ND cache yet.  Without the /32 route below, dnsmasq's reply to the
	# client -- sent pinned to this interface -- has no via-inet6 next hop
	# to follow, so the kernel falls back to resolving the host's IPv4
	# on-link (ARP), leaving exactly the per-lease ARP entry we want to
	# avoid.  So provoke the stable GUA into the cache, then look up; on a
	# miss, fall back to an all-nodes probe (surfaces a link-local) and retry.
	provoke_gua
	nh=$(find_nexthop)
	if [ -z "$nh" ]; then
		ping -6 -c1 -W1 "ff02::1%$IF" >/dev/null 2>&1 || \
		    ping6 -c1 -W1 "ff02::1%$IF" >/dev/null 2>&1 || true
		nh=$(find_nexthop)
	fi
	if [ -n "$nh" ]; then
		# Pin the source to the link-scoped sentinel (also the DHCP
		# server-id): otherwise the kernel prefers the global-scoped
		# target 203.0.113.1 as the source for replies and return
		# traffic, so clients would see answers from the wrong address.
		ip route replace "$ip4/32" via inet6 "$nh" dev "$IF" \
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
