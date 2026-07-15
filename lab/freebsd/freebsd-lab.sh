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
RUNDIR="${TMPDIR:-/tmp}"   # all runtime artefacts (pidfiles, rtadvd conf)

# Predictable, role-based interface names (owner_peer).  A renamed
# interface keeps its name across the vnet move, so up/test/down can all
# reference these constants with no shared state file.  (An ifconfig
# group would be simpler, but group membership is *not* preserved across
# the vnet move, so it can't enumerate interfaces once they are in jails.)
HA_IF=hostA_r1;   R1A_IF=r1_hostA   # link a: hostA <-> r1
R1B_IF=r1_r2;     R2B_IF=r2_r1      # link b: r1   <-> r2
R2C_IF=r2_hostB;  HB_IF=hostB_r2    # link c: r2   <-> hostB


lladdr() {  # lladdr <jail> <iface>
    jexec "${JPFX}$1" ifconfig "$2" inet6 | \
        awk '/inet6 fe80/ { sub("%.*","",$2); print $2; exit }'
}

up() {
    for j in hostA r1 r2 hostB; do
        jail -c name=${JPFX}$j vnet persist
    done

    # Create three epairs and rename each half to its role-based name.
    # "ifconfig epair create" is the only portable form (the cloner needs
    # a numeric unit, not a letter) and prints the a-side (epairNa); the
    # peer is epairNb.  Renaming both halves up front means test/down need
    # no record of the kernel-assigned names.
    for spec in "$HA_IF $R1A_IF" "$R1B_IF $R2B_IF" "$R2C_IF $HB_IF"; do
        set -- $spec
        ep=$(ifconfig epair create)
        ifconfig "$ep" name "$1"
        ifconfig "${ep%a}b" name "$2"
    done

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

    # Wait for the link-local addresses we depend on to be generated,
    # rather than sleeping a fixed interval for DAD: read them in a loop
    # until all four are present.  (DAD completing before the addresses
    # are used as an RS/traffic source is covered by the rtsol/route
    # solicitation below, which blocks on an RA round-trip.)
    n=0
    while [ $n -lt 40 ]; do
        R1_B=$(lladdr r1 $R1B_IF);  R2_B=$(lladdr r2 $R2B_IF)
        HA=$(lladdr hostA $HA_IF);  HB=$(lladdr hostB $HB_IF)
        if [ -n "$R1_B" ] && [ -n "$R2_B" ] && [ -n "$HA" ] && [ -n "$HB" ]; then
            break
        fi
        n=$((n + 1))
        sleep 0.25
    done

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
    # SLAAC prefix); short min/max intervals get the first unsolicited RA
    # out within seconds while a long router lifetime keeps the entry
    # stable between RAs.
    for pair in "r1 $R1A_IF" "r2 $R2C_IF"; do
        set -- $pair
        conf="${RUNDIR}/${JPFX}-ra-$2.conf"
        printf '%s:\\\n\t:noifprefix:mininterval#3:maxinterval#4:rltime#1800:\n' \
            "$2" > "$conf"
        jexec ${JPFX}$1 rtadvd -c "$conf" -p "${RUNDIR}/${JPFX}-rtadvd-$2.pid" "$2"
    done

    # Solicit an immediate RA on each host.  rtadvd delays its first
    # *unsolicited* RA by up to 16 s (RFC 4861), but answers a Router
    # Solicitation within half a second.  rtsol sends the RS and exits
    # once a valid RA arrives -- plain, no -1 (some FreeBSD builds reject
    # that flag).  Best-effort: the poll below still covers a missed
    # reply, falling back to rtadvd's unsolicited cycle.
    timeout 8 jexec ${JPFX}hostA rtsol $HA_IF & ra=$!
    timeout 8 jexec ${JPFX}hostB rtsol $HB_IF & rb=$!
    wait $ra || true
    wait $rb || true

    # Wait for both hosts to learn the router from an RA (a non-empty ND6
    # default router list).  Starting the daemons only after this lets
    # their startup reconcile install the IPv4 default immediately, rather
    # than waiting out their 15 s periodic reconcile.
    n=0
    while [ $n -lt 40 ]; do
        if jexec ${JPFX}hostA ndp -r 2>/dev/null | grep -q fe80 &&
           jexec ${JPFX}hostB ndp -r 2>/dev/null | grep -q fe80; then
            break
        fi
        n=$((n + 1))
        sleep 0.5
    done

    # Host daemons (draft Section 4). -f redirects the daemon's stdio to
    # /dev/null (v4gwd logs to syslog); without it the daemon inherits
    # our stdout and a piped/non-interactive "up" hangs waiting on EOF.
    daemon -f -p ${RUNDIR}/${JPFX}-hostA.pid \
        jexec ${JPFX}hostA "${V4GWD}" $HA_IF
    daemon -f -p ${RUNDIR}/${JPFX}-hostB.pid \
        jexec ${JPFX}hostB "${V4GWD}" $HB_IF

    # Confirm both daemons have installed the IPv4 default before returning.
    n=0
    while [ $n -lt 20 ]; do
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
    P1=$(mktemp); P2=$(mktemp); P3=$(mktemp)
    jexec ${JPFX}hostA tcpdump -i $HA_IF  -nn arp -w "$P1" 2>/dev/null &
    T1=$!
    jexec ${JPFX}r1    tcpdump -i $R1B_IF -nn arp -w "$P2" 2>/dev/null &
    T2=$!
    jexec ${JPFX}hostB tcpdump -i $HB_IF  -nn arp -w "$P3" 2>/dev/null &
    T3=$!
    sleep 1

    if jexec ${JPFX}hostA ping -c3 -i 0.2 -W2000 203.0.113.5 > /dev/null 2>&1; then
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
    for f in ${RUNDIR}/${JPFX}-hostA.pid ${RUNDIR}/${JPFX}-hostB.pid; do
        [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true
        rm -f "$f"
    done
    # SIGKILL rtadvd *before* removing the jails.  On a normal signal it
    # sends its final zero-lifetime RAs (MAX_FINAL_RTR_ADVERTISEMENTS),
    # which makes "jail -r" on each router block ~10 s waiting for it;
    # SIGKILL skips that.  Jails share the host PID namespace, so the
    # recorded rtadvd PIDs are killable from here.
    for f in ${RUNDIR}/${JPFX}-rtadvd-*.pid; do
        [ -f "$f" ] && kill -9 "$(cat "$f")" 2>/dev/null || true
    done
    for j in hostA r1 r2 hostB; do
        jail -r ${JPFX}$j 2>/dev/null || true
    done
    rm -f ${RUNDIR}/${JPFX}-ra-*.conf ${RUNDIR}/${JPFX}-rtadvd-*.pid
    # epairs are destroyed with their jail; destroy any that survived
    # (destroying either half removes the pair) by their fixed a-side
    # names -- the halves created above.
    for i in "$HA_IF" "$R1B_IF" "$R2C_IF"; do
        ifconfig "$i" destroy 2>/dev/null || true
    done
    echo "Lab down."
}

case "${1:-}" in
    up) up ;;
    test) test_ ;;
    down) down ;;
    *) echo "usage: $0 up | test | down" >&2; exit 1 ;;
esac
