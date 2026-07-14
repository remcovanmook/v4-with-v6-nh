# Vendor configuration examples

Example configurations implementing the router-side behaviour of
draft-vanmook-intarea-ipv6-resolved-gateway on commercial platforms.
The router side is deliberately configuration-only; these examples
cover the five behaviours:

  A. RFC 8950 return-path routes (/32 with IPv6 next hop): static
     and/or BGP extended next-hop encoding
  B. Local termination of 192.0.0.11 (answers ping, draft s5.2)
  C. ARP response for 192.0.0.11 (unmodified-host tier, draft s5.3)
  D. Enforcement of the s5.2 forwarding prohibition: packets with
     source or destination 192.0.0.11 never leave the segment. The
     MUST NOT is in the draft; the mechanism is an operator choice --
     an egress ACL on core/upstream interfaces (complete: also
     catches transiting third-party packets), TTL=1 on originations
     (belt-and-braces where a knob exists), or both.
  E. DHCPv4 relay with option 82 / RFC 3527 link selection and a
     loopback-sourced giaddr

## Capability matrix

| Behaviour | IOS XR | JunOS | SR OS | EOS | RouterOS 7 |
|---|---|---|---|---|---|
| A: static v4-via-v6     | no [1]   | no [1]   | no [1]   | yes (>=4.30.1) [2] | yes (>=7.11) [2] |
| A: BGP RFC 8950         | yes      | yes      | yes      | yes      | yes (7.x) |
| B: terminate 192.0.0.11 | pattern  | yes      | pattern  | yes      | yes |
| C: answer ARP           | verify   | verify   | verify   | verify   | yes |
| D: egress ACL           | yes      | yes      | yes      | yes      | yes |
| D: TTL=1 origination    | no knob  | no knob  | no knob  | no knob  | yes (mangle) |
| E: relay + link-select  | verify   | verify   | yes      | verify   | partial |

[1] Not listed in the implementation status of
    draft-ietf-intarea-v4-via-v6; BGP is the supported RFC 8950 path.
[2] Confirmed in draft-ietf-intarea-v4-via-v6 (Implementation Status).

"pattern" = achievable via loopback + route, see per-file notes.
"verify"  = expected to work but not confirmed against current
            documentation or hardware; validate before relying on it.

## Two cross-platform wrinkles to test on every platform

1. **ARP sanity checks.** In the unmodified-host tier the ARP request
   for 192.0.0.11 arrives with a sender IP (the host /32) that is on
   no subnet the router knows. Several platforms log, rate-limit, or
   drop ARP from "non-connected" sources. Owning 192.0.0.11/32 on the
   interface makes the router answer natively on most stacks, but the
   off-subnet-sender path is exactly the code path that differs per
   vendor. The lab's Linux/FreeBSD behaviour is verified; commercial
   platforms are not.

2. **Enforcement mechanism choice.** The egress ACL is the primary
   tool: two terms on every non-segment interface make the s5.2
   MUST NOT structurally true regardless of what any stack
   originates, and it works on every platform. TTL=1 on
   originations is available only where a knob exists (Linux and
   FreeBSD default-TTL sysctls, RouterOS mangle) and only covers
   self-sourced packets; treat it as defence in depth, not the
   mechanism.
