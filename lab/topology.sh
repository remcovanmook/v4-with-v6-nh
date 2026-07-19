#!/bin/bash
# Network-namespace lab reproducing the end-to-end packet flow of
# draft-vanmook-intarea-ipv6-resolved-gateway, Section 5.1:
#
#   hostA ---- R1 ---- R2 ---- hostB
#
#   hostA  IPv4 198.51.100.1/32   IPv6 2001:db8:1::1/64
#   R1     no IPv4 anywhere       IPv6 link-local + 2001:db8:1::a/64
#   R2     no IPv4 anywhere       IPv6 link-local + 2001:db8:2::a/64
#   hostB  IPv4 203.0.113.5/32    IPv6 2001:db8:2::2/64
#
# Router-to-router and router-to-host IPv4 forwarding uses IPv4 routes
# with IPv6 next hops (RFC 8950 semantics, kernel RTA_VIA).  No IPv4
# address, subnet, or ARP exists anywhere in the lab.
#
# Usage: topology.sh up [--sentinel] | down | status
#   --sentinel  also install "default via 192.0.0.11 onlink" on the
#               hosts, exercising v4gwd's default DHCP-driven mode
#               (sentinel required).  Without it, v4gwd runs with
#               --unconditional (static/lab mode).

set -euo pipefail

NS=(v4nh-hostA v4nh-r1 v4nh-r2 v4nh-hostB)
V4GWD="$(cd "$(dirname "${BASH_SOURCE[0]}")/../host" && pwd)/v4gwd.py"
RUNDIR="${TMPDIR:-/tmp}/v4nh-lab"
SENTINEL_MODE=0

lladdr() {  # lladdr <ns> <iface>  -> link-local address of iface in ns
    ip -n "$1" -6 addr show dev "$2" scope link \
        | awk '/inet6/ {sub("/.*","",$2); print $2; exit}'
}

wait_lladdr() {  # DAD takes a moment
    local a
    for _ in $(seq 1 50); do
        a=$(lladdr "$1" "$2")
        [ -n "$a" ] && ! ip -n "$1" -6 addr show dev "$2" | grep -q tentative \
            && { echo "$a"; return; }
        sleep 0.2
    done
    echo "timeout waiting for link-local on $1/$2" >&2; exit 1
}

up() {
    mkdir -p "$RUNDIR"
    for n in "${NS[@]}"; do ip netns add "$n"; done

    ip link add a1 netns v4nh-hostA type veth peer name a1 netns v4nh-r1
    ip link add r12 netns v4nh-r1  type veth peer name r12 netns v4nh-r2
    ip link add b1 netns v4nh-hostB type veth peer name b1 netns v4nh-r2

    for n in "${NS[@]}"; do
        ip -n "$n" link set lo up
        for d in a1 r12 b1; do
            ip -n "$n" link set "$d" up 2>/dev/null || true
        done
    done

    # Routers: forwarding on, IPv6 GUAs for manageability. No IPv4.
    for n in v4nh-r1 v4nh-r2; do
        ip netns exec "$n" sysctl -qw net.ipv4.ip_forward=1 \
                                      net.ipv6.conf.all.forwarding=1
    done
    ip -n v4nh-r1 -6 addr add 2001:db8:1::a/64 dev a1
    ip -n v4nh-r2 -6 addr add 2001:db8:2::a/64 dev b1

    # 192.0.0.11 local termination on host-facing interfaces (draft
    # s5.2: interface-scoped, echo SHOULD be answered). Adding it with
    # "scope link" gets the interface-scoping for free from iproute2: a
    # link-scoped address is never selected as a source toward an
    # off-link destination and its connected route stays link-scoped
    # (nothing to redistribute as a subnet) -- exactly the s5.2
    # "interface-scoped, not injected" property, with no extra rules.
    # TTL=1 on originations then caps any self-sourced packet at one hop
    # -- the on-wire signal T4 checks -- while transit is unaffected. An
    # egress nftables rule on core-facing interfaces is the equally valid
    # -- and, for transit, more complete -- alternative:
    #   nft add rule inet f out oif r12 ip saddr 192.0.0.11 drop
    # The tests (T4/T5) assert the outcome, not the mechanism.
    ip -n v4nh-r1 addr add 192.0.0.11/32 scope link dev a1
    ip -n v4nh-r2 addr add 192.0.0.11/32 scope link dev b1
    for n in v4nh-r1 v4nh-r2; do
        ip netns exec "$n" sysctl -qw net.ipv4.ip_default_ttl=1
    done

    # Hosts: /32 IPv4, /64 IPv6. No IPv4 subnet, no IPv4 gateway address
    # that resolves to anything.
    ip -n v4nh-hostA addr add 198.51.100.1/32 dev a1
    ip -n v4nh-hostA -6 addr add 2001:db8:1::1/64 dev a1
    ip -n v4nh-hostB addr add 203.0.113.5/32 dev b1
    ip -n v4nh-hostB -6 addr add 2001:db8:2::2/64 dev b1

    # Collect link-local addresses (post-DAD)
    R1_A=$(wait_lladdr v4nh-r1 a1);  R1_R=$(wait_lladdr v4nh-r1 r12)
    R2_R=$(wait_lladdr v4nh-r2 r12); R2_B=$(wait_lladdr v4nh-r2 b1)
    HA=$(wait_lladdr v4nh-hostA a1); HB=$(wait_lladdr v4nh-hostB b1)

    # Hosts: IPv6 default router (static stand-in for an RA-learned
    # entry; v4gwd reads the default router list regardless of origin).
    ip -n v4nh-hostA -6 route add default via "$R1_A" dev a1
    ip -n v4nh-hostB -6 route add default via "$R2_B" dev b1

    # Routers: IPv4 /32 host routes with IPv6 next hops (RFC 8950
    # semantics).  ND resolves the link-layer address; ARP is never used.
    ip -n v4nh-r1 route add 203.0.113.5/32  via inet6 "$R2_R" dev r12
    ip -n v4nh-r1 route add 198.51.100.1/32 via inet6 "$HA"   dev a1
    ip -n v4nh-r2 route add 198.51.100.1/32 via inet6 "$R1_R" dev r12
    ip -n v4nh-r2 route add 203.0.113.5/32  via inet6 "$HB"   dev b1
    ip -n v4nh-r1 -6 route add 2001:db8:2::/64 via "$R2_R" dev r12
    ip -n v4nh-r2 -6 route add 2001:db8:1::/64 via "$R1_R" dev r12

    GWD_ARGS="--unconditional"
    if [ "$SENTINEL_MODE" = 1 ]; then
        # DHCP-driven mode: sentinel route as a DHCPv4 client would
        # install it (onlink: no subnet exists to contain the gateway).
        ip -n v4nh-hostA route add default via 192.0.0.11 dev a1 onlink metric 100
        ip -n v4nh-hostB route add default via 192.0.0.11 dev b1 onlink metric 100
        GWD_ARGS=""                 # sentinel required is the default
    fi

    # Host daemons: implement Section 4 next-hop resolution.
    ip netns exec v4nh-hostA python3 "$V4GWD" $GWD_ARGS a1 \
        >"$RUNDIR/hostA.log" 2>&1 & echo $! > "$RUNDIR/hostA.pid"
    ip netns exec v4nh-hostB python3 "$V4GWD" $GWD_ARGS b1 \
        >"$RUNDIR/hostB.log" 2>&1 & echo $! > "$RUNDIR/hostB.pid"

    sleep 1
    echo "Lab up. hostA=198.51.100.1  hostB=203.0.113.5  (sentinel mode: $SENTINEL_MODE)"
    echo "Try: ip netns exec v4nh-hostA ping -c3 203.0.113.5"
}

down() {
    for f in "$RUNDIR"/*.pid; do
        [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true
    done
    rm -rf "$RUNDIR"
    for n in "${NS[@]}"; do ip netns del "$n" 2>/dev/null || true; done
    echo "Lab down."
}

status() {
    for n in "${NS[@]}"; do
        echo "== $n =="
        ip -n "$n" -brief addr
        ip -n "$n" route
        ip -n "$n" -6 route | grep -v '^fe80\|^2001.*proto kernel' || true
    done
}

cmd="${1:-}"
[ "${2:-}" = "--sentinel" ] && SENTINEL_MODE=1
case "$cmd" in
    up) up ;;
    down) down ;;
    status) status ;;
    *) echo "usage: $0 up [--sentinel] | down | status" >&2; exit 1 ;;
esac
