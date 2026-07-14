#!/bin/sh
# FreeBSD vnet-jail lab reproducing the end-to-end packet flow of
# draft-vanmook-intarea-ipv6-resolved-gateway, Section 5.1:
#
#   hostA ---- R1 ---- R2 ---- hostB
#
# Same addressing plan as the Linux netns lab (lab/topology.sh):
#   hostA 198.51.100.1/32 + 2001:db8:1::1/64
#   hostB 203.0.113.5/32  + 2001:db8:2::2/64
#   R1/R2 IPv6-only; IPv4 forwarding via RFC 5549 routes.
#
# Requires FreeBSD 13.1+ (RFC 5549 data plane), VIMAGE kernel (default
# in GENERIC), and host/freebsd/v4gwd built and in PATH or ../../host/freebsd/.
#
# Usage: freebsd-lab.sh up | test | down

set -eu

JPFX=v4nh
V4GWD="${V4GWD:-$(dirname "$0")/../../host/freebsd/v4gwd}"


lladdr() {  # lladdr <jail> <iface>
    jexec "${JPFX}$1" ifconfig "$2" inet6 | \
        awk '/inet6 fe80/ { sub("%.*","",$2); print $2; exit }'
}

up() {
    for j in hostA r1 r2 hostB; do
        jail -c name=${JPFX}$j vnet persist
    done

    # epair a: hostA-R1, epair b: R1-R2, epair c: R2-hostB
    for p in a b c; do
        ifconfig epair${p} create > /dev/null
    done
    ifconfig epaira0 vnet ${JPFX}hostA; ifconfig epaira1 vnet ${JPFX}r1
    ifconfig epairb0 vnet ${JPFX}r1;    ifconfig epairb1 vnet ${JPFX}r2
    ifconfig epairc0 vnet ${JPFX}r2;    ifconfig epairc1 vnet ${JPFX}hostB

    for j in hostA r1 r2 hostB; do
        jexec ${JPFX}$j ifconfig lo0 up
    done

    # Routers: forwarding, IPv6 only
    for j in r1 r2; do
        jexec ${JPFX}$j sysctl -q net.inet.ip.forwarding=1 \
                               net.inet6.ip6.forwarding=1
    done

    jexec ${JPFX}hostA ifconfig epaira0 inet 198.51.100.1/32 up
    jexec ${JPFX}hostA ifconfig epaira0 inet6 2001:db8:1::1/64
    jexec ${JPFX}r1    ifconfig epaira1 inet6 2001:db8:1::a/64
    jexec ${JPFX}r1    ifconfig epairb0 inet6 auto_linklocal up
    jexec ${JPFX}r2    ifconfig epairb1 inet6 auto_linklocal up
    jexec ${JPFX}r2    ifconfig epairc0 inet6 2001:db8:2::a/64
    jexec ${JPFX}hostB ifconfig epairc1 inet 203.0.113.5/32 up
    jexec ${JPFX}hostB ifconfig epairc1 inet6 2001:db8:2::2/64
    sleep 2  # DAD

    R1_A=$(lladdr r1 epaira1);  R1_B=$(lladdr r1 epairb0)
    R2_B=$(lladdr r2 epairb1);  R2_C=$(lladdr r2 epairc0)
    HA=$(lladdr hostA epaira0); HB=$(lladdr hostB epairc1)

    # Hosts: IPv6 default router (static stand-in for RA; v4gwd reads
    # the kernel default router list -- to exercise the RA path proper,
    # run rtadvd in r1/r2 instead and use "-r"/-f modes).
    jexec ${JPFX}hostA route -6 add default "${R1_A}%epaira0" > /dev/null
    jexec ${JPFX}hostB route -6 add default "${R2_C}%epairc1" > /dev/null

    # Routers: RFC 5549 /32 routes, IPv6 next hops, ND-resolved
    jexec ${JPFX}r1 route add -host 203.0.113.5  -inet6 "${R2_B}%epairb0" > /dev/null
    jexec ${JPFX}r1 route add -host 198.51.100.1 -inet6 "${HA}%epaira1"  > /dev/null
    jexec ${JPFX}r2 route add -host 198.51.100.1 -inet6 "${R1_B}%epairb1" > /dev/null
    jexec ${JPFX}r2 route add -host 203.0.113.5  -inet6 "${HB}%epairc0"  > /dev/null
    jexec ${JPFX}r1 route -6 add 2001:db8:2::/64 "${R2_B}%epairb0" > /dev/null
    jexec ${JPFX}r2 route -6 add 2001:db8:1::/64 "${R1_B}%epairb1" > /dev/null

    # Host daemons (draft Section 4)
    daemon -p /var/run/${JPFX}-hostA.pid \
        jexec ${JPFX}hostA "${V4GWD}" epaira0
    daemon -p /var/run/${JPFX}-hostB.pid \
        jexec ${JPFX}hostB "${V4GWD}" epairc1

    echo "Lab up. Try: jexec ${JPFX}hostA ping -c3 203.0.113.5"
}

test_() {
    P1=$(mktemp); P2=$(mktemp); P3=$(mktemp)
    jexec ${JPFX}hostA tcpdump -i epaira0 -nn arp -w "$P1" 2>/dev/null &
    T1=$!
    jexec ${JPFX}r1    tcpdump -i epairb0 -nn arp -w "$P2" 2>/dev/null &
    T2=$!
    jexec ${JPFX}hostB tcpdump -i epairc1 -nn arp -w "$P3" 2>/dev/null &
    T3=$!
    sleep 1

    if jexec ${JPFX}hostA ping -c3 -W2000 203.0.113.5 > /dev/null 2>&1; then
        echo "PASS: T1 IPv4 end-to-end, /32s only, IPv6-only routers"
    else
        echo "FAIL: T1 IPv4 end-to-end ping"
    fi
    sleep 1; kill $T1 $T2 $T3 2>/dev/null; wait 2>/dev/null || true

    ARP=0
    for f in "$P1" "$P2" "$P3"; do
        n=$(tcpdump -r "$f" -nn 2>/dev/null | wc -l | tr -d ' ')
        ARP=$((ARP + n))
    done
    rm -f "$P1" "$P2" "$P3"
    if [ "$ARP" -eq 0 ]; then
        echo "PASS: T2 zero ARP frames captured on all links"
    else
        echo "FAIL: T2 captured $ARP ARP frames"
    fi
}

down() {
    for f in /var/run/${JPFX}-hostA.pid /var/run/${JPFX}-hostB.pid; do
        [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true
        rm -f "$f"
    done
    for j in hostA r1 r2 hostB; do
        jail -r ${JPFX}$j 2>/dev/null || true
    done
    # epairs are destroyed with their vnet jails
    echo "Lab down."
}

case "${1:-}" in
    up) up ;;
    test) test_ ;;
    down) down ;;
    *) echo "usage: $0 up | test | down" >&2; exit 1 ;;
esac
