#!/bin/bash

# This script sets the IPv4 default gateway to follow the IPv6 default gateway on the specified interface.


set -euo pipefail

IPROUTE=$(command -v ip)
command -v $IPROUTE >/dev/null 2>&1 || { echo "ip command not found"; exit 1; }
LOGGER=$(command -v logger)
RUNDIR=/var/run
IFACE=${IFACE:-"$1"}

if [ -z "$IFACE" ]; then
    echo "Missing interface in either \$IFACE or command line"
    exit 1
fi

syslog () {
   $LOGGER -t v4-autogw -p daemon.notice "$1"
}

handle_route_change() {
    local V6GW=$(echo "$1" | awk '{print $3;exit}')
    local V4GW=$($IPROUTE -4 r l default dev $IFACE | awk '{print $3;exit}')
    # Check if V4GW is 'inet6' - if so, we need to have the fourth field
    if [ "$V4GW" == "inet6" ]; then
        V4GW=$($IPROUTE -4 r l default dev $IFACE | awk '{print $4;exit}')
    fi

    if [ -n "$V6GW" ]; then
        if [ "$V4GW" != "$V6GW" ]; then
            if [ -n "$V4GW" ]; then
                syslog "Changing IPv4 default gateway from $V4GW to $V6GW"
                $IPROUTE -4 route change default via inet6 $V6GW dev $IFACE
            else
                syslog "Setting IPv4 default gateway to $V6GW"
                $IPROUTE -4 route add default via inet6 $V6GW dev $IFACE
            fi
        fi
    else
        if [ -n "$V4DEFAULT" ]; then
            syslog "No default IPv6 gateway found but IPv4 gateway exists - exiting"
            rm -f $RUNDIR/v4-autogw.{pid,fifo}
            exit 2
        else
            syslog "No IPv6 default gateways found - waiting..."
        fi
    fi
}

cleanup() {
    syslog "Cleaning up and exiting"
    if [ -n "$IP_MONITOR_PID" ]; then
        kill "$IP_MONITOR_PID"
    fi
    rm -f "$RUNDIR/v4-autogw.{pid,fifo}"
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# Setup FIFO for monitor process and PID file, set trap for SIGINT and SIGTERM
echo "$$" > "$RUNDIR/v4-autogw.pid"
IP_MONITOR_PID=""
IP_MONITOR_FIFO="$RUNDIR/v4-autogw.fifo"
rm -f "$IP_MONITOR_FIFO"
mkfifo "$IP_MONITOR_FIFO"

# Initial run at startup
handle_route_change "`$IPROUTE -6 r l default dev $IFACE`"

# Main loop to catch updates
$IPROUTE -6 monitor route dev $IFACE > "$IP_MONITOR_FIFO" &
IP_MONITOR_PID=$!
while read -r line < "$IP_MONITOR_FIFO"; do
    if echo "$line" | grep -q "^default"; then
        handle_route_change "$line"
    fi
done

rm -f "$RUNDIR/v4-autogw.{pid,fifo}"
