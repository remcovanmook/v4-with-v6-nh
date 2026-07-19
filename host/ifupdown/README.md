# ifupdown (Debian/Ubuntu classic)

Like NetworkManager, ifupdown needs **no code of its own** — the generic Linux
daemon [`../v4gwd.py`](../v4gwd.py) does the draft's Section 4, and ifupdown
just brings the interface up and runs a DHCP client. Documentation only.

## Setup

Configure the host-facing interface for DHCP in `/etc/network/interfaces`
(or a drop-in under `interfaces.d/`):

    auto enp0s1
    iface enp0s1 inet dhcp

Install the daemon and enable it on that interface. `--require-sentinel`
self-gates on the presence of a `192.0.0.11` default, so the unit is a no-op on
ordinary networks and safe to leave enabled anywhere:

    sudo install -m 755 ../v4gwd.py /usr/local/bin/v4gwd.py
    sudo apt install python3-pyroute2
    sudo cp ../systemd/v4gwd@.service /etc/systemd/system/
    sudo systemctl enable --now v4gwd@enp0s1

That is the whole integration: the DHCP client installs `default via
192.0.0.11`, the daemon races a lower-metric `RTA_VIA` default above it
(Section 4, no ARP), exactly as under NetworkManager.

## The one variable: the DHCP client

`--require-sentinel` keys on the DHCP client having installed the off-subnet
`default via 192.0.0.11`. Clients differ on off-subnet gateways:

- **dhcpcd** — adds the on-link `192.0.0.11/32` route itself and installs the
  default; works out of the box. Recommended for ifupdown hosts (`apt install
  dhcpcd-base`).
- **isc-dhcp-client (`dhclient`)** — does not add an on-link route for an
  off-subnet gateway, so the default can fail to install. Either switch to
  dhcpcd, or add the on-link `/32` from an exit hook —
  `/etc/dhcp/dhclient-exit-hooks.d/v4gw`:

      case "$reason:$new_routers" in
        BOUND:*192.0.0.11*|RENEW:*192.0.0.11*|REBIND:*192.0.0.11*|REBOOT:*192.0.0.11*)
          ip route replace 192.0.0.11/32 dev "$interface" scope link ;;
      esac

  This is exactly what dhcpcd and NetworkManager do automatically; with the
  `/32` present, `dhclient` installs the default and the daemon takes over.

## Status

Validated end to end on Debian 13 (trixie), ifupdown + dhcpcd, against the live
RFC 5549 router: dhcpcd installs the off-subnet `default via 192.0.0.11` with
its own on-link `/32` (stock §5.3 works), `v4gwd --require-sentinel` takes over
§4 (`RTA_VIA` default at metric 50, beating dhcpcd's metric 1002), and that
route survives a dhcpcd renewal (`dhcpcd --rebind`) and re-asserts after a full
interface bounce (`systemctl restart networking`).
