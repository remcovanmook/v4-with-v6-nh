#!/bin/bash

# This script sets the IPv4 default gateway to follow the IPv6 default gateway on the specified interface.

IPROUTE=/usr/sbin/ip
RUNDIR=/var/run
IFACE=${IFACE:-"$1"}

if [ -z "$IFACE" ]; then
    echo "Missing interface in either \$IFACE or command line"
    exit 1
fi

syslog () {
   /usr/bin/logger -t v4-autogw -p daemon.notice "$1"
}

handle_route_change() {
    local V6GW=$(echo "$1" | awk '{print $3;exit}')
    local V4DEFAULT=$($IPROUTE -4 r l default dev $IFACE)
    local V4GW=$($IPROUTE -4 r l default dev $IFACE | awk '{print $3;exit}')
    # Check if V4DEFAULT is 'inet6' - if so, we need to have the fourth field
    if [ "$V4GW" == "inet6" ]; then
        V4GW=$(e$IPROUTE -4 r l default dev $IFACE | awk '{print $4;exit}')
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

# Setup FIFO for monitor process and PID file, set trap for SIGINT and SIGTERM
IP_MONITOR_PID=""
IP_MONITOR_FIFO="$RUNDIR/v4-autogw.fifo"
rm -f $IP_MONITOR_FIFO; mkfifo $IP_MONITOR_FIFO
echo $$ > $RUNDIR/v4-autogw.pid
trap 'syslog "Signal received - exiting"; kill $IP_MONITOR_PID; rm -f $RUNDIR/v4-autogw.{pid,fifo}; exit 0' SIGINT SIGTERM

# Initial run at startup
handle_route_change "`$IPROUTE -6 r l default dev $IFACE`"

# Main loop to catch updates
ip -6 monitor route > "$IP_MONITOR_FIFO" &
IP_MONITOR_PID=$!
while read -r line < "$IP_MONITOR_FIFO"; do
    if echo "$line" | grep -q "^default"; then
        handle_route_change "$line"
    fi
done
