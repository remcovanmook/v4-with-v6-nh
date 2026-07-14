#!/usr/bin/env python3

# Non-functional work in progress

import os
import sys
import time
import signal
import socket
import syslog
from pyroute2 import IPRoute, NetlinkError
from datetime import datetime

PID_FILE = "/var/run/v4-autogw.pid"
running = True

# Setup syslog
syslog.openlog(ident="v4-autogw", facility=syslog.LOG_DAEMON)

def log_notice(message):
    syslog.syslog(syslog.LOG_NOTICE, message)

def handle_signal(signum, frame):
    global running
    running = False

signal.signal(signal.SIGINT, handle_signal)
signal.signal(signal.SIGTERM, handle_signal)

iface = os.environ.get("IFACE", sys.argv[1] if len(sys.argv) > 1 else None)
if not iface:
    print("Missing interface in either $IFACE or command line", file=sys.stderr)
    sys.exit(1)

with open(PID_FILE, "w") as f:
    f.write(str(os.getpid()))

ip = IPRoute()

def get_default_route(family, ifindex):
    routes = ip.get_routes(family=family)
    for route in routes:
        if route.get('dst_len') == 0 and route.get('oif') == ifindex:
            return route
    return None

def get_gateway(route):
    for attr in route.get('attrs', []):
        if attr[0] == 'RTA_GATEWAY':
            return attr[1]
    return None

def get_expires(route):
    # Valid if tattrs exist for expiration
    tstamp = route.get('ts', 0)
    lifetime = route.get('lifetime', {})
    preferred = lifetime.get('preferred', 0)
    if preferred > 0 and tstamp > 0:
        # tstamp is in seconds since epoch
        expires_at = tstamp + preferred
        now = int(time.time())
        return max(10, expires_at - now)  # fallback to minimum of 10s
    return 600  # fallback default

try:
    ifindex_list = ip.link_lookup(ifname=iface)
    if not ifindex_list:
        log_notice(f"Interface {iface} not found")
        sys.exit(1)
    ifindex = ifindex_list[0]

    while running:
        v6route = get_default_route(socket.AF_INET6, ifindex)
        v4route = get_default_route(socket.AF_INET, ifindex)

        if v6route:
            expires = get_expires(v6route)

            v6gw = get_gateway(v6route)
            v4gw = get_gateway(v4route) if v4route else None

            if v6gw != v4gw:
                try:
                    if v4route:
                        log_notice(f"changing IPv4 default gateway from {v4gw} to {v6gw} - sleeping for {expires} seconds")
                        ip.route('replace', dst='0.0.0.0/0', gateway=v6gw, family=socket.AF_INET)
                    else:
                        log_notice(f"setting IPv4 default gateway to {v6gw} - sleeping for {expires} seconds")
                        ip.route('add', dst='0.0.0.0/0', gateway=v6gw, family=socket.AF_INET)
                except NetlinkError as e:
                    log_notice(f"Failed to update IPv4 route: {e}")

            time.sleep(expires // 2)

        else:
            if v4route:
                log_notice("No default IPv6 gateway found but IPv4 gateway exists - exiting")
                break
            else:
                log_notice("No default gateways found - sleeping")
                for _ in range(5):
                    if not running:
                        break
                    time.sleep(1)

finally:
    if os.path.exists(PID_FILE):
        os.remove(PID_FILE)
    ip.close()
    syslog.closelog()
