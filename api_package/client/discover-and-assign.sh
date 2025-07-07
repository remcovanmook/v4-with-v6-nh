#!/bin/bash
set -e

API="http://[fd00:416::]:8000"
logger "[assign] Starting IPv4 assignment via $API"

IFACE=$(ip -6 route show default | awk '/dev/ { print $5; exit }')
[ -z "$IFACE" ] && logger "[assign] No IPv6 default route found" && exit 1

IPV6_ADDR=$(ip -6 addr show dev "$IFACE" scope global | awk '/inet6/ {print $2}' | head -n1 | cut -d/ -f1)
[ -z "$IPV6_ADDR" ] && logger "[assign] No global IPv6 address on $IFACE" && exit 1

logger "[assign] Interface: $IFACE, IPv6: $IPV6_ADDR"

ALLOWED=$(curl -s "$API/allowed/$IPV6_ADDR" | jq -r '.[]')

for IP in $ALLOWED; do
    logger "[assign] Adding $IP to $IFACE"
    ip addr add "$IP/32" dev "$IFACE" 2>/dev/null || true

    logger "[assign] Registering $IP with API"
    curl -s -X POST "$API/set-route"         -H "Content-Type: application/json"         -d "{"ipv4": "$IP", "ipv6": "$IPV6_ADDR"}" > /dev/null
done
