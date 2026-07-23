#!/bin/sh
# keepalived notify for debian-ha.  Called as: <type> <name> <state> [priority]
# on every VRRP transition.  dnsmasq's shared-network binds to 192.0.0.11, which
# VRRP puts only on the segment's master, so a state change (VIP arriving or
# leaving) means dnsmasq must re-bind to start/stop serving that segment.  A
# reload-or-restart is idempotent and cheap.
systemctl reload-or-restart v4gw-dnsmasq >/dev/null 2>&1 || true
exit 0
