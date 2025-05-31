#!/bin/bash

IPROUTE=/usr/sbin/ip

# Use $IFACE if set, otherwise use first positional argument
IFACE=${IFACE:-"$1"}

if [ -z "$IFACE" ]; then
    echo "Missing interface in either \$IFACE or command line"
    exit 1
fi

# Sleep function
SLEEP_PID=""
killable_sleep() {
	sleep "$1" &
	SLEEP_PID=$!
	wait $SLEEP_PID
}

# Setup PID file, set trap for SIGINT and SIGTERM
echo $$ > /var/run/v4-autogw.pid
trap 'logger -t v4-autogw -p daemon.notice "Signal received - exiting"; kill $SLEEP_PID; rm -f /var/run/v4-autogw.pid; exit 0' SIGINT SIGTERM
logger -t v4-autogw -p daemon.notice "Running on interface $IFACE"

while true; do
    V6DEFAULT=$($IPROUTE -6 r l default dev $IFACE)
    V4DEFAULT=$($IPROUTE -4 r l default dev $IFACE)

    if [ -n "$V6DEFAULT" ]; then
        EXPIRES=$(echo "$V6DEFAULT" | sed -n 's/.*expires \([0-9]\+\)sec.*/\1/p')
	EXPIRES=${EXPIRES:-600} # fallback default of 600 seconds
	SLEEP=$(( $EXPIRES / 2))

    	V4GW=$(echo "$V4DEFAULT" | awk '{print $3;exit}')
        # Check if V4DEFAULT is 'inet6' - if so, we need to have the fourth field
	if [ "$V4GW" == "inet6" ]; then
            V4GW=$(echo "$V4DEFAULT" | awk '{print $4;exit}')
        fi

        V6GW=$(echo "$V6DEFAULT" | awk '{print $3;exit}')

        if [ "$V4GW" != "$V6GW" ]; then
            if [ -n "$V4DEFAULT" ]; then
                logger -t v4-autogw -p daemon.notice "changing IPv4 default gateway from $V4GW to $V6GW - sleeping for $SLEEP seconds"
                $IPROUTE -4 route change default via inet6 $V6GW dev $IFACE
            else
                logger -t v4-autogw -p daemon.notice "setting IPv4 default gateway to $V6GW - sleeping for $SLEEP seconds"
                $IPROUTE -4 route add default via inet6 $V6GW dev $IFACE
            fi
	#else
	#    logger -t v4-autogw -p daemon.notice "IPv4 gateway matches IPv6 gateway - nothing to do"
        fi

        killable_sleep $SLEEP

    else
        if [ -n "$V4DEFAULT" ]; then
            logger -t v4-autogw -p daemon.notice "No default IPv6 gateway found but IPv4 gateway exists - exiting"
            rm -f /var/run/v4-autogw.pid
            exit 2
        else
            logger -t v4-autogw -p daemon.notice "No default gateways found - sleeping"
            killable_sleep 5
        fi
    fi
done
