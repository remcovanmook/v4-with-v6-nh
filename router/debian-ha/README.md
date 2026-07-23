# Redundant active/active router pair (debian-ha)

The [`../debian/`](../debian/) IPv6-resolved-IPv4-gateway mechanism served by
**two** routers across **two** host segments, active/active: the gateway
`192.0.0.11` is an anycast VRRP VIP, and the RFC 5549 return `/32`s are
distributed between the routers by RFC 8950 iBGP. This is the multi-gateway
active/active fabric; `../debian/` is the single-router reference.

## Topology

```text
             ┌──────── MikroTik (upstream) ────────┐   eBGP 8950, ECMP over gw2+gw3
             │                                     │
        enp0s1│                               enp0s1│
          ┌───┴───┐        iBGP 8950         ┌───┴───┐
          │  gw2  │───────────────────────────│  gw3  │
          └─┬───┬─┘                           └─┬───┬─┘
      enp0s2│   │enp0s3                    enp0s2│   │enp0s3
        seg1│   │seg2                        seg1│   │seg2
   ── 2001:db8:1::/64 ─────────────────── 2001:db8:2::/64 ──
        hosts (IPv4 /32 from a shared 198.51.100.0/24 pool, gw 192.0.0.11)
```

Both routers sit on **both** segments. `192.0.0.11` is an anycast VRRP VIP,
elected per segment; staggered priority makes gw2 master on seg1 and gw3 master
on seg2, so both boxes are hot.

## Configuration

The daemon and its companions are identical to `../debian/` — install those
unchanged:

- `../debian/usr/local/sbin/v4gwrd.py` — the return-route daemon (gateway-agnostic)
- `../debian/usr/local/sbin/v4gw-lease-notify.sh` — the dnsmasq notifier
- `../debian/etc/systemd/system/v4gwrd.service` — the unit

The router configuration lives here:

- **`etc/network/interfaces.d/v4gw`** — both segments; the per-segment IPv6 GUA
  plus the link-local IPv4 /32 keepalived sources VRRP from. keepalived owns
  `192.0.0.11`.
- **`etc/v4gw/dnsmasq.conf`** — RA + DHCPv4 on both segments from one shared
  `198.51.100.0/24` pool; DHCP follows the VRRP master (see below).
- **`etc/keepalived/keepalived.conf`** — VRRP: `192.0.0.11` VIP per segment,
  staggered priority. The master answers ARP for the VIP, so unmodified (ARP)
  hosts reach the live router.
- **`etc/bird/bird.conf`** — iBGP between the two routers carrying the host
  `/32`s with RFC 8950 (IPv4 NLRI, IPv6 next hop), so each router learns the
  other's hosts as a **direct** route via the host GUA — resolved against the
  connected v6 routes, not hairpinned through the peer.
- **`usr/local/sbin/v4gw-vrrp-notify.sh`** — keepalived notify: re-binds dnsmasq
  so a segment's DHCP is served only where this node holds the VIP.

## Per-node values

Everything else is common; only these differ per box:

| | gw2 | gw3 |
|---|---|---|
| seg1 GUA (enp0s2) | `2001:db8:1::b` | `2001:db8:1::c` |
| seg2 GUA (enp0s3) | `2001:db8:2::b` | `2001:db8:2::c` |
| VRRP priority seg1 / seg2 | `200` / `100` | `100` / `200` |
| BIRD `router id` | `10.0.0.2` | `10.0.0.3` |
| BIRD `local` / `neighbor` | this / peer enp0s1 GUA | peer / this enp0s1 GUA |

Placeholders in the files are marked `# PER-NODE`.

## DHCP follows the master

dnsmasq's `shared-network` binds to `192.0.0.11`; VRRP puts that address only on
the segment's master, so each segment's DHCP is served by its master, and one
server answers per segment. `bind-dynamic` lets dnsmasq track the VIP
appearing/leaving, and the keepalived notify script nudges it on a state change.

## Status

Live on gw2/gw3: multi-segment forwarding, dnsmasq (shared pool, both segments),
VRRP election of `192.0.0.11` (staggered active/active), and the BIRD 8950 iBGP —
each router learns the other's host `/32`s as a direct route via the host GUA.
Pending: the eBGP session to the upstream MikroTik for inbound ECMP across
gw2+gw3.
