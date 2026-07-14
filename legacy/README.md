# Legacy mechanism (prior art)

This directory preserves the original 2024/25 work this repository
started as: a daemon that copies the host's IPv6 default gateway into
the IPv4 routing table (`ip -4 route replace default via inet6 <v6gw>`),
plus deployment tooling (bird configurations and a registration API for
distributing /32 host routes with IPv6 next hops).

It predates, and directly motivated,
draft-vanmook-intarea-ipv6-resolved-gateway. It is **not** an
implementation of the draft: there is no 192.0.0.11 sentinel, no
RFC 4191 router selection, and no DHCPv4-driven lifecycle. It is
retained unchanged as prior art. For the draft-conformant
implementation, see `../host/`.
