# MikroTik RouterOS 7 -- draft-vanmook-intarea-ipv6-resolved-gateway
# Static v4-via-v6 confirmed since ~7.11
# (draft-ietf-intarea-v4-via-v6, Implementation Status)

# --- A. Return-path /32 with IPv6 next hop -------------------------
/ip route add dst-address=198.51.100.1/32 gateway=fe80::hostA%ether1
# Upstream via a peer router:
/ip route add dst-address=0.0.0.0/0 gateway=fe80::peer%ether2

# --- B/C. Terminate 192.0.0.11 + ARP -------------------------------
/ip address add address=192.0.0.11/32 interface=ether1 \
    network=192.0.0.11
# RouterOS answers ARP for owned addresses (interface arp=enabled).

# --- D. s5.2 enforcement -------------------------------------------
# Primary: filter on the upstream/core path (covers forwarded and
# transiting packets in both directions):
/ip firewall filter add chain=forward src-address=192.0.0.11 \
    action=drop comment="v6-resolved-gw: never forwarded"
/ip firewall filter add chain=forward dst-address=192.0.0.11 \
    action=drop
# Defence in depth: RouterOS is the one platform with a per-source
# TTL knob for originations:
/ip firewall mangle add chain=output src-address=192.0.0.11 \
    action=change-ttl new-ttl=set:1 comment="v6-resolved-gw: iface-local"

# --- E. DHCPv4 relay ------------------------------------------------
# /ip dhcp-relay supports option-82 insertion; RFC 3527 link
# selection is NOT exposed -- VERIFY whether your server can key on
# giaddr placement instead, or run the relay elsewhere.
/ip dhcp-relay add name=seg1 interface=ether1 \
    dhcp-server=203.0.113.53 local-address=203.0.113.254 \
    add-relay-info=yes disabled=no
