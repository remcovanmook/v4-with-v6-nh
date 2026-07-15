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
V4GWD="${V4GWD:-$(cd "$(dirname "$0")/../../host/freebsd" && pwd)/v4gwd}"
STATE="/var/run/${JPFX}-lab.env"


lladdr() {  # lladdr <jail> <iface>
    jexec "${JPFX}$1" ifconfig "$2" inet6 | \
        awk '/inet6 fe80/ { sub("%.*","",$2); print $2; exit }'
}

up() {
    for j in hostA r1 r2 hostB; do
        jail -c name=${JPFX}$j vnet persist
    done

    # epair units are assigned by the kernel -- the cloner needs a
    # numeric unit, not a letter, so "ifconfig epair create" is the only
    # portable form.  Each call prints its a-side (epairNa); the peer is
    # epairNb.  Record the names for test/down.  Links: la=hostA-R1,
    # lb=R1-R2, lc=R2-hostB.
    la=$(ifconfig epair create); HA_IF=$la;  R1A_IF=${la%a}b
    lb=$(ifconfig epair create); R1B_IF=$lb; R2B_IF=${lb%a}b
    lc=$(ifconfig epair create); R2C_IF=$lc; HB_IF=${lc%a}b

    cat > "$STATE" <<EOF
HA_IF=$HA_IF
R1A_IF=$R1A_IF
R1B_IF=$R1B_IF
R2B_IF=$R2B_IF
R2C_IF=$R2C_IF
HB_IF=$HB_IF
EOF

    ifconfig $HA_IF  vnet ${JPFX}hostA; ifconfig $R1A_IF vnet ${JPFX}r1
    ifconfig $R1B_IF vnet ${JPFX}r1;    ifconfig $R2B_IF vnet ${JPFX}r2
    ifconfig $R2C_IF vnet ${JPFX}r2;    ifconfig $HB_IF  vnet ${JPFX}hostB

    for j in hostA r1 r2 hostB; do
        jexec ${JPFX}$j ifconfig lo0 up
    done

    # Routers: forwarding, IPv6 only
    for j in r1 r2; do
        jexec ${JPFX}$j sysctl -q net.inet.ip.forwarding=1 \
                               net.inet6.ip6.forwarding=1
    done

    jexec ${JPFX}hostA ifconfig $HA_IF inet 198.51.100.1/32 up
    jexec ${JPFX}hostA ifconfig $HA_IF inet6 2001:db8:1::1/64
    jexec ${JPFX}r1    ifconfig $R1A_IF inet6 2001:db8:1::a/64
    # The R1-R2 link is link-local only. A fresh interface comes up with
    # the ND6 IFDISABLED flag set (no IPv6, no auto link-local); assigning
    # a global address clears it implicitly, but a link-local-only
    # interface must clear it explicitly with -ifdisabled, otherwise no
    # fe80 address is generated and the RFC 5549 next hop can't resolve.
    jexec ${JPFX}r1    ifconfig $R1B_IF inet6 -ifdisabled auto_linklocal up
    jexec ${JPFX}r2    ifconfig $R2B_IF inet6 -ifdisabled auto_linklocal up
    jexec ${JPFX}r2    ifconfig $R2C_IF inet6 2001:db8:2::a/64
    jexec ${JPFX}hostB ifconfig $HB_IF inet 203.0.113.5/32 up
    jexec ${JPFX}hostB ifconfig $HB_IF inet6 2001:db8:2::2/64
    sleep 2  # DAD

    R1_B=$(lladdr r1 $R1B_IF);  R2_B=$(lladdr r2 $R2B_IF)
    HA=$(lladdr hostA $HA_IF);  HB=$(lladdr hostB $HB_IF)

    # Hosts learn their IPv6 default router from Router Advertisements
    # (rtadvd, started below).  v4gwd selects its next hop from the ND6
    # default router list, and *only* RAs populate that list -- a static
    # default route never appears there, so RA acceptance is required for
    # the daemon to have anything to select.
    jexec ${JPFX}hostA sysctl -q net.inet6.ip6.accept_rtadv=1
    jexec ${JPFX}hostA ifconfig $HA_IF inet6 accept_rtadv
    jexec ${JPFX}hostB sysctl -q net.inet6.ip6.accept_rtadv=1
    jexec ${JPFX}hostB ifconfig $HB_IF inet6 accept_rtadv

    # Routers: RFC 5549 /32 routes, IPv6 next hops, ND-resolved
    jexec ${JPFX}r1 route add -host 203.0.113.5  -inet6 "${R2_B}%${R1B_IF}" > /dev/null
    jexec ${JPFX}r1 route add -host 198.51.100.1 -inet6 "${HA}%${R1A_IF}"   > /dev/null
    jexec ${JPFX}r2 route add -host 198.51.100.1 -inet6 "${R1_B}%${R2B_IF}" > /dev/null
    jexec ${JPFX}r2 route add -host 203.0.113.5  -inet6 "${HB}%${R2C_IF}"   > /dev/null
    jexec ${JPFX}r1 route -6 add 2001:db8:2::/64 "${R2_B}%${R1B_IF}" > /dev/null
    jexec ${JPFX}r2 route -6 add 2001:db8:1::/64 "${R1_B}%${R2B_IF}" > /dev/null

    # Routers advertise themselves as the IPv6 default router toward the
    # hosts.  noifprefix keeps the RA to a link-local default only (no
    # SLAAC prefix); short min/max intervals converge in seconds while a
    # long router lifetime keeps the entry stable between RAs.
    for pair in "r1 $R1A_IF" "r2 $R2C_IF"; do
        set -- $pair
        conf="/var/run/${JPFX}-ra-$2.conf"
        printf '%s:\\\n\t:noifprefix:mininterval#3:maxinterval#4:rltime#1800:\n' \
            "$2" > "$conf"
        jexec ${JPFX}$1 rtadvd -c "$conf" -p "/var/run/${JPFX}-rtadvd-$2.pid" "$2"
    done

    # Host daemons (draft Section 4). -f redirects the daemon's stdio to
    # /dev/null (v4gwd logs to syslog); without it the daemon inherits
    # our stdout and a piped/non-interactive "up" hangs waiting on EOF.
    # Start them *before* soliciting the RA, so they are already watching
    # the routing socket when the RA installs the IPv6 default and can
    # reconcile immediately rather than on their periodic (15 s) timer.
    daemon -f -p /var/run/${JPFX}-hostA.pid \
        jexec ${JPFX}hostA "${V4GWD}" $HA_IF
    daemon -f -p /var/run/${JPFX}-hostB.pid \
        jexec ${JPFX}hostB "${V4GWD}" $HB_IF

    # Prompt an immediate RA so the hosts converge now rather than on
    # rtadvd's next cycle -- the kernel's own RS burst fired at interface
    # bring-up, before rtadvd existed. rtsol -1 exits as soon as a valid
    # RA arrives; the timeout is only a safety net (rtadvd's periodic RAs
    # would converge the hosts regardless).
    timeout 8 jexec ${JPFX}hostA rtsol -1 $HA_IF || true
    timeout 8 jexec ${JPFX}hostB rtsol -1 $HB_IF || true

    # Block until both daemons have installed the IPv4 default route
    # (RA convergence + reconcile) instead of guessing a fixed delay.
    n=0
    while [ $n -lt 40 ]; do
        if jexec ${JPFX}hostA netstat -rn -f inet 2>/dev/null | grep -q '^default' &&
           jexec ${JPFX}hostB netstat -rn -f inet 2>/dev/null | grep -q '^default'; then
            break
        fi
        n=$((n + 1))
        sleep 0.5
    done

    echo "Lab up. Try: jexec ${JPFX}hostA ping -c3 203.0.113.5"
}

test_() {
    if [ -f "$STATE" ]; then
        . "$STATE"
    else
        echo "no lab state ($STATE); run '$0 up' first" >&2; exit 1
    fi
    P1=$(mktemp); P2=$(mktemp); P3=$(mktemp)
    jexec ${JPFX}hostA tcpdump -i $HA_IF  -nn arp -w "$P1" 2>/dev/null &
    T1=$!
    jexec ${JPFX}r1    tcpdump -i $R1B_IF -nn arp -w "$P2" 2>/dev/null &
    T2=$!
    jexec ${JPFX}hostB tcpdump -i $HB_IF  -nn arp -w "$P3" 2>/dev/null &
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
    # rtadvd runs inside the router jails and dies with them; clean up the
    # pidfiles and generated configs it leaves on the shared filesystem.
    rm -f /var/run/${JPFX}-ra-*.conf /var/run/${JPFX}-rtadvd-*.pid
    # epairs return to the host vnet when their jail is removed; destroy
    # any that survived (destroying either half removes the pair).
    if [ -f "$STATE" ]; then
        . "$STATE"
        for i in "$HA_IF" "$R1B_IF" "$R2C_IF"; do
            ifconfig "$i" destroy 2>/dev/null || true
        done
        rm -f "$STATE"
    fi
    echo "Lab down."
}

case "${1:-}" in
    up) up ;;
    test) test_ ;;
    down) down ;;
    *) echo "usage: $0 up | test | down" >&2; exit 1 ;;
esac
