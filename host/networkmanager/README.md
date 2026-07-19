# NetworkManager (Linux)

The generic Linux daemon [`../v4gwd.py`](../v4gwd.py) covers NetworkManager;
this directory is documentation.

`v4gwd.py` implements Section 4 by racing a better route: it installs
`default via inet6 <router>` (proto 199, metric 50) below NM's DHCP-learned
`default via 192.0.0.11`, so the kernel prefers the ND-resolved next hop. NM
keeps its own route as a fallback and leaves the daemon's in place.

Verified on Fedora 44 Server (NetworkManager 1.56.1) against the live RFC 5549
router (`../../router/debian/`):

- **Stock NM works (§5.3).** NM's DHCPv4 client accepts the off-subnet Router
  option (192.0.0.11 on a `/32`), adds the on-link `192.0.0.11/32 scope link`
  route itself, and installs `default via 192.0.0.11`. The host ARPs the
  gateway, the RFC 5549 router answers, and IPv4 (including the real internet)
  works; DNS arrives via RA RDNSS.
- **The daemon takes over §4.** `v4gwd.py` installs
  `default via inet6 <router> proto 199 metric 50`, and traffic leaves via the
  ND-resolved next hop — zero ARP for 192.0.0.11 (confirmed by capture at the
  router).
- **Coexistence.** `nmcli device reapply` leaves the proto-199 route in place;
  a connection bounce flushes routes and the daemon re-asserts on the sentinel
  reappearing.

The daemon's lower-metric route is the whole integration; the NM connection
stays at its defaults (`ipv4.method=auto`).

## Install

    sudo install -m 755 ../v4gwd.py /usr/local/bin/v4gwd.py
    sudo dnf install -y python3-pyroute2          # Debian/Ubuntu: apt install python3-pyroute2
    sudo cp ../systemd/v4gwd.service /etc/systemd/system/
    sudo systemctl enable --now v4gwd

The daemon manages all ethernet interfaces and acts only where the 192.0.0.11
sentinel is present.

## Metric

The daemon installs at metric 50; NM's DHCP default is metric 100. If a site
lowers NM's route metric below 50 (`nmcli con mod <con> ipv4.route-metric N`),
pass a matching lower `--metric` so the daemon's route stays preferred.

## Caveat

A connection bounce (`nmcli connection up`, or a carrier flap) re-runs DHCP;
for a sub-second window before the daemon re-asserts, the host rides the §5.3
ARP-resolved default. Steady state and `nmcli device reapply` keep the §4 route.

## Status

Validated end to end on Fedora 44 Server (NetworkManager 1.56.1) against the
live Debian RFC 5549 router: stock §5.3 connectivity with RDNSS DNS; daemon §4
takeover with a zero-ARP wire capture; route survives `nmcli device reapply`
and a connection bounce.
