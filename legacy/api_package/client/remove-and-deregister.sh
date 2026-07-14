#!/bin/bash
set -e

API="http://[fd00:416::]:8000"
logger "[remove] Starting IPv4 removal via $API"

IFACE=$(ip -6 route show default | awk '/dev/ { print $5; exit }')
[ -z "$IFACE" ] && logger "[remove] No IPv6 default route found" && exit 1

IPV6_ADDR=$(ip -6 addr show dev "$IFACE" scope global | awk '/inet6/ {print $2}' | head -n1 | cut -d/ -f1)
[ -z "$IPV6_ADDR" ] && logger "[remove] No global IPv6 address on $IFACE" && exit 1

ALLOWED=$(curl -s "$API/allowed/$IPV6_ADDR" | jq -r '.[]')

for IP in $ALLOWED; do
    logger "[remove] Removing $IP from $IFACE"
    ip addr del "$IP/32" dev "$IFACE" 2>/dev/null || true

    logger "[remove] Deregistering $IP from API"
    curl -s -X POST "$API/remove-route"         -H "Content-Type: application/json"         -d "{"ipv4": "$IP", "ipv6": "$IPV6_ADDR"}" > /dev/null
done
