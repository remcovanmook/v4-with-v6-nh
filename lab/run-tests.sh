#!/bin/bash
# Conformance smoke tests against the Section 5.1 lab topology.
# Run after: ./topology.sh up --sentinel
#
# T1  IPv4 end-to-end connectivity across two IPv6-only routers,
#     with /32 host addresses only (draft s5.1).
# T2  Zero ARP frames on any link during IPv4 traffic (draft s4 item 2,
#     s5.1 "No ARP is exchanged at any point").
# T3  Sentinel withdrawal: removing the 192.0.0.11 default route makes
#     the daemon withdraw its route and IPv4 connectivity ceases
#     (draft s4, lease-expiry behavior).  Sentinel mode only.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

CAP=/tmp/v4nh-lab/arp-capture
rm -f "$CAP".*

# T2 setup: capture ARP on every link before generating traffic
ip netns exec v4nh-hostA tcpdump -i a1  -nn arp -w "$CAP.a1"  2>/dev/null &
P1=$!
ip netns exec v4nh-r1    tcpdump -i r12 -nn arp -w "$CAP.r12" 2>/dev/null &
P2=$!
ip netns exec v4nh-hostB tcpdump -i b1  -nn arp -w "$CAP.b1"  2>/dev/null &
P3=$!
sleep 1

# T1
if ip netns exec v4nh-hostA ping -c3 -W2 203.0.113.5 >/dev/null 2>&1; then
    ok "T1 IPv4 end-to-end (198.51.100.1 -> 203.0.113.5), /32s only, IPv6-only routers"
else
    fail "T1 IPv4 end-to-end ping"
fi

sleep 1; kill $P1 $P2 $P3 2>/dev/null; wait $P1 $P2 $P3 2>/dev/null

# T2
ARP_TOTAL=0
for f in "$CAP".*; do
    n=$(tcpdump -r "$f" -nn 2>/dev/null | wc -l)
    ARP_TOTAL=$((ARP_TOTAL + n))
done
if [ "$ARP_TOTAL" -eq 0 ]; then
    ok "T2 zero ARP frames captured on all links"
else
    fail "T2 captured $ARP_TOTAL ARP frames"
fi

# T3 (sentinel mode only)
if ip -n v4nh-hostA route show default | grep -q 192.0.0.11; then
    ip -n v4nh-hostA route del default via 192.0.0.11 dev a1
    sleep 2
    if ip -n v4nh-hostA route show default | grep -q "proto 199"; then
        fail "T3 daemon route still present after sentinel removal"
    else
        ok "T3 daemon withdrew route after sentinel removal (lease-expiry semantics)"
    fi
    # restore
    ip -n v4nh-hostA route add default via 192.0.0.11 dev a1 onlink metric 100
    sleep 2
    if ip netns exec v4nh-hostA ping -c2 -W2 203.0.113.5 >/dev/null 2>&1; then
        ok "T3b connectivity restored after sentinel re-added (lease renewal)"
    else
        fail "T3b connectivity not restored after sentinel re-added"
    fi
else
    echo "SKIP: T3 (lab not in --sentinel mode)"
fi

# T4  First-hop diagnostics (draft s5.2): the gateway answers echo at
#     192.0.0.11, and the reply carries TTL=1 (interface-local on the
#     wire; a non-conformant forwarder would kill it at the first hop).
OUT=$(ip netns exec v4nh-hostA ping -c2 -W2 192.0.0.11 2>/dev/null)
if echo "$OUT" | grep -q "ttl=1 "; then
    ok "T4 gateway answers ping at 192.0.0.11 with TTL=1"
elif echo "$OUT" | grep -q "ttl="; then
    fail "T4 gateway answered but TTL != 1: $(echo "$OUT" | grep -o 'ttl=[0-9]*' | head -1)"
else
    fail "T4 no echo reply from 192.0.0.11"
fi

# T5  No 192.0.0.11-sourced or -destined packet ever crosses the
#     inter-router link (draft s5.2: MUST NOT appear in any forwarded
#     packet). Generate diagnostic traffic while capturing on r12.
CAPX=/tmp/v4nh-lab/leak-capture
ip netns exec v4nh-r1 tcpdump -i r12 -nn "host 192.0.0.11" -w "$CAPX" 2>/dev/null &
PX=$!
sleep 1
ip netns exec v4nh-hostA ping -c2 -W2 192.0.0.11 >/dev/null 2>&1
ip netns exec v4nh-hostA ping -c2 -W2 203.0.113.5 >/dev/null 2>&1
sleep 1; kill $PX 2>/dev/null; wait $PX 2>/dev/null
LEAK=$(tcpdump -r "$CAPX" -nn 2>/dev/null | wc -l)
if [ "$LEAK" -eq 0 ]; then
    ok "T5 zero 192.0.0.11 packets on the inter-router link"
else
    fail "T5 $LEAK packets involving 192.0.0.11 crossed the inter-router link"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
