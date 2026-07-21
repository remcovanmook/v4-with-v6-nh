#!/bin/sh
# dnsmasq dhcp-script (v4gwrd variant): a thin notifier.  dnsmasq calls us as
#   <action> <mac> <ip4> [hostname]   with DNSMASQ_INTERFACE in the environment.
# We forward "<action> <iface> <mac> <ip4>" to v4gwrd's FIFO and do nothing
# else; the daemon owns all the route logic.  This is the parallel of
# v4gw-lease.sh -- use one or the other as dnsmasq's dhcp-script.
#
# The write is bounded so a stopped daemon (FIFO present but no reader) cannot
# stall dnsmasq; when the daemon runs it holds the FIFO open and the write is
# instant.
FIFO=/run/v4gwrd/events
[ -p "$FIFO" ] || exit 0
timeout 2 sh -c 'printf "%s %s %s %s\n" "$1" "$2" "$3" "$4" > "$0"' \
    "$FIFO" "${1:-}" "${DNSMASQ_INTERFACE:-}" "${2:-}" "${3:-}" 2>/dev/null || true
exit 0
