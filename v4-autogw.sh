#!/bin/bash

IPROUTE=/usr/sbin/ip

# Use $IFACE if set, otherwise use first positional argument
IFACE=${IFACE:-"$1"}

if [ -z "$IFACE" ]; then
    echo "Missing interface in either \$IFACE or command line"
    exit 1
fi

while true; do
    V6DEFAULT=$($IPROUTE -6 r l default | grep "dev $IFACE" | head -1)
    V4DEFAULT=$($IPROUTE -4 r l default | grep "dev $IFACE" | head -1)

    # Only do something if we have a defined IPv6 gateway
    if [ -n "$V6DEFAULT" ]; then
        # Check if the third field of V4DEFAULT is 'inet6' - if so, we need to shift fields one back
        if [ "$(echo "$V4DEFAULT" | awk '{print $3}')" == "inet6" ]; then
            # this is a ipv6 gateway, this typically looks like "fe80::1234:5678:90ab:cdef dev eth0"
            V4GW=$(echo "$V4DEFAULT" | awk '{print $4" "$5" "$6}')
        else
            # this is a ipv4 gateway, this typically looks like "192.168.0.1 dev eth0"
            V4GW=$(echo "$V4DEFAULT" | awk '{print $3" "$4" "$5}')
        fi

        V6GW=$(echo "$V6DEFAULT" | awk '{print $3" "$4" "$5}')

        # Only do something if we actually need to make a change to the IPv4 gateway
        if [ "$V4GW" != "$V6GW" ]; then
            if [ -n "$V4DEFAULT" ]; then
                echo "changing IPv4 default gateway from $V4GW to $V6GW"
                $IPROUTE -4 route change default via inet6 $V6GW
            else
                echo "setting IPv4 default gateway to $V6GW"
                $IPROUTE -4 route add default via inet6 $V6GW
            fi
        else
            echo "IPv4 gateway matches IPv6 gateway - nothing to do"
        fi

        EXPIRES=$(echo "$V6DEFAULT" | sed -n 's/.*expires \([0-9]\+\)sec.*/\1/p')
        if [ -z "$EXPIRES" ]; then
            EXPIRES=600  # fallback if parsing fails
        fi
        sleep $(( $EXPIRES / 2 ))

    # there's no IPv6 gateway - if there is an IPv4 gateway already defined we exit, if neither exists we wait
    else
        if [ -n "$V4DEFAULT" ]; then
            echo "No default IPv6 gateway found but IPv4 gateway exists - exiting"
            exit 2
        else
            echo "No default gateways found - sleeping"
            sleep 10
        fi
    fi
done
