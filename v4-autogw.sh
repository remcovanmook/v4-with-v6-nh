#!/bin/bash

IPROUTE=/usr/sbin/ip

# Use $IFACE if set, otherwise use first positional argument
IFACE=${IFACE:-"$1"}

if [ -z "$IFACE" ]; then
    echo "Missing interface in either \$IFACE or command line"
    exit 1
fi

echo $$ > /var/run/v4-autogw.pid

while true; do
    V6DEFAULT=$($IPROUTE -6 r l default | grep "dev $IFACE" | head -1)
    V4DEFAULT=$($IPROUTE -4 r l default | grep "dev $IFACE" | head -1)

    if [ -n "$V6DEFAULT" ]; then
        EXPIRES=$(echo "$V6DEFAULT" | sed -n 's/.*expires \([0-9]\+\)sec.*/\1/p')
        EXPIRES=${EXPIRES:-600} # fallback default of 600 seconds

        # Check if the third field of V4DEFAULT is 'inet6' - if so, we need to shift fields one back
        if [ "$(echo "$V4DEFAULT" | awk '{print $3}')" == "inet6" ]; then
            V4GW=$(echo "$V4DEFAULT" | awk '{print $4" "$5" "$6}')
        else
            V4GW=$(echo "$V4DEFAULT" | awk '{print $3" "$4" "$5}')
        fi

        V6GW=$(echo "$V6DEFAULT" | awk '{print $3" "$4" "$5}')

        if [ "$V4GW" != "$V6GW" ]; then
            if [ -n "$V4DEFAULT" ]; then
                logger -t v4-autogw -p daemon.notice "changing IPv4 default gateway from $V4GW to $V6GW - sleeping for $EXPIRES seconds"
                $IPROUTE -4 route change default via inet6 $V6GW
            else
                logger -t v4-autogw -p daemon.notice "setting IPv4 default gateway to $V6GW - sleeping for $EXPIRES seconds"
                $IPROUTE -4 route add default via inet6 $V6GW
            fi
        #else
        #    logger -t v4-autogw -p daemon.notice "IPv4 gateway matches IPv6 gateway - nothing to do"
        fi

        sleep $(( $EXPIRES / 2 ))

    else
        if [ -n "$V4DEFAULT" ]; then
            logger -t v4-autogw -p daemon.notice "No default IPv6 gateway found but IPv4 gateway exists - exiting"
            rm -f /var/run/v4-autogw.pid
            exit 2
        else
            logger -t v4-autogw -p daemon.notice "No default gateways found - sleeping"
            sleep 5
        fi
    fi
done
rm -f /var/run/v4-autogw.pid
