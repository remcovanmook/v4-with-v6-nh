#!/bin/bash

# This script sets the IPv4 default gateway to follow the IPv6 default gateway on the specified interface.

set -euo pipefail

V6_WELLKNOWN=("2000::" "fe80::1" "fd00::1")

IPROUTE=$(command -v ip)
command -v $IPROUTE >/dev/null 2>&1 || { echo "ip command not found"; exit 1; }
LOGGER=$(command -v logger)
RUNDIR=/var/run
IFACE=${IFACE:-"$1"}


if [ -z "$IFACE" ]; then
    echo "Missing interface in either \$IFACE or command line"
    exit 1
fi

# Read current IPv4 default route into ROUTE array
read -ra ROUTE <<< "$($IPROUTE -4 route show default dev $IFACE)"

syslog () {
   $LOGGER -t v4-autogw -p daemon.notice "$1"
}

cleanup() {
    syslog "Cleaning up and exiting"
    if [ -n "$IP_MONITOR_PID" ]; then
        kill "$IP_MONITOR_PID"
    fi
    rm -f "$RUNDIR/v4-autogw.{pid,fifo}"
    exit ${$1:"0"}
}

trap 'cleanup 0' SIGINT SIGTERM EXIT

handle_route_change() {
    local V6GW=$(echo "$1" | awk '{print $3;exit}')
    if [ -n "$V6GW" ]; then
        syslog "Setting IPv4 default gateway to $V6GW"
        $IPROUTE -4 route replace default via inet6 $V6GW dev $IFACE
    fi
}

# See if there's anything to be done at all
if [ ${ROUTE[2]} = "inet6" ]; then
    for item in "${V6_WELLKNOWN[@]}"; do
    if [[ "${ROUTE[3]}" == "$item" ]]; then
        syslog "IPv4 gateway already set using well-known IPv6 address, assuming no dynamic gateway necessary"
        exit 2
    fi
    done
fi

# Setup FIFO for monitor process and PID file, set trap for SIGINT and SIGTERM
echo "$$" > "$RUNDIR/v4-autogw.pid"
IP_MONITOR_PID=""
IP_MONITOR_FIFO="$RUNDIR/v4-autogw.fifo"
rm -f "$IP_MONITOR_FIFO"
mkfifo "$IP_MONITOR_FIFO"

# Initial run at startup
handle_route_change "$($IPROUTE -6 r l default dev $IFACE)"

# Main loop to catch updates
$IPROUTE -6 monitor route dev $IFACE > "$IP_MONITOR_FIFO" &
IP_MONITOR_PID=$!
while read -r line < "$IP_MONITOR_FIFO"; do
    if echo "$line" | grep -q "^default"; then
        handle_route_change "$line"
    fi
done
