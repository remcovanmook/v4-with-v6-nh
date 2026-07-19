# NetworkManager (Linux)

NetworkManager needs **no code of its own** — the generic Linux daemon
[`../v4gwd.py`](../v4gwd.py) (draft Section 4, native `RTA_VIA` path) coexists
with it cleanly. This directory is documentation only.

## Why nothing special is needed

Linux resolves IPv4 routes with an IPv6 next hop through Neighbor Discovery
(never ARP), and `v4gwd.py` implements Section 4 by **racing** a better route
rather than replacing NM's: it installs `default via inet6 <router>` at a
lower metric (proto 199) than the DHCP-learned `default via 192.0.0.11`, so the
kernel prefers the ND-resolved next hop. NM keeps its own route as an unused
fallback and — crucially — does not remove the daemon's.

Verified on Fedora 44 Server (NetworkManager 1.56.1) against the live RFC 5549
router (`../../router/debian/`):

- **Stock unmodified NM works (§5.3).** NM's DHCPv4 client accepts the
  off-subnet Router option (192.0.0.11, on a `/32`) and *itself* adds the
  on-link `192.0.0.11/32 scope link` route to reach it, then
  `default via 192.0.0.11`. The host ARPs the gateway, the RFC 5549 router
  answers, and IPv4 — including the real internet — works. DNS arrives via RA
  RDNSS. (NM is better-behaved here than Windows, which needs the on-link
  `/32` supplied for it.)
- **The daemon takes over §4.** `v4gwd.py --require-sentinel` sees NM's
  sentinel default (metric 100) and installs
  `default via inet6 <router> proto 199 metric 50`; traffic thereafter leaves
  via the ND-resolved next hop — **zero ARP for 192.0.0.11** on the wire
  (confirmed by capture at the router during sustained traffic).
- **NM does not fight it.** `nmcli device reapply` leaves the proto-199 route
  untouched; a full connection bounce (down/up + re-DHCP) flushes routes and
  the daemon re-asserts within the same instant — it is event-driven on the
  sentinel route reappearing.

No dispatcher script, no `ipv4.never-default`, no static routes are required —
the daemon's lower-metric route is the whole integration.

## Install

NM is just the DHCP client / connection manager; install the daemon exactly as
on any Linux host:

    sudo install -m 755 ../v4gwd.py /usr/local/bin/v4gwd.py
    sudo dnf install -y python3-pyroute2          # Debian/Ubuntu: apt install python3-pyroute2
    sudo cp ../systemd/v4gwd@.service /etc/systemd/system/
    sudo systemctl enable --now v4gwd@enp0s1      # your host-facing interface

Leave the NM connection at its defaults (`ipv4.method=auto`).

## Metric coexistence

The daemon installs at metric 50; NM's DHCP default route is metric 100, so the
daemon wins. If a site lowers NM's route metric below 50
(`nmcli con mod <con> ipv4.route-metric N`), pass a correspondingly lower
`--metric` to the daemon so its `RTA_VIA` route stays preferred.

## Caveat

On a full connection bounce (`nmcli connection up`, or a carrier flap that
tears the device down), NM re-runs DHCP and briefly installs only its
metric-100 `default via 192.0.0.11` before the daemon re-asserts. During that
sub-second window the host rides the §5.3 ARP-resolved fallback — correct, if
not the zero-ARP §4 path. Steady state and `nmcli device reapply` keep the §4
route.

## Status

Validated end to end on Fedora 44 Server (NetworkManager 1.56.1, Python 3.14,
pyroute2 0.7.12) against the live Debian RFC 5549 router: stock §5.3
connectivity with RDNSS DNS; daemon §4 takeover with a zero-ARP wire capture;
and route survival across `nmcli device reapply` and a full connection bounce.
