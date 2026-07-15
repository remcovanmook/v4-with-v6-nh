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

case "$action" in
add|old)
	# The client's link-local is the ND-cache entry whose MAC matches
	# the DHCP MAC (works regardless of EUI-64 vs. randomised LLAs).
	# Match the MAC anywhere on the line so the field position of
	# "ip -6 neigh show dev <if>" (lladdr in $3) vs. without dev ($5)
	# does not matter.
	ll=$(ip -6 neigh show dev "$IF" 2>/dev/null | awk \
	    -v m="$(printf '%s' "$mac" | tr 'A-Z' 'a-z')" \
	    'index(tolower($0), m) && $1 ~ /^fe80/ { print $1; exit }')
	if [ -n "$ll" ]; then
		ip route replace "$ip4/32" via inet6 "$ll" dev "$IF"
	fi
	;;
del)
	ip route del "$ip4/32" 2>/dev/null || true
	;;
esac
exit 0
