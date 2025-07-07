Internet Engineering Task Force                              Remco van Mook
Internet-Draft                                              Novoserve B.V.
Intended status: Standards Track                         9 July 2025
Expires: 9 January 2026

Network Working Group                                     R. van Mook
Internet-Draft                                           Novoserve B.V.
Intended status: Standards Track                           9 July 2025
Expires: 9 January 2026

Title:      Request for IANA Assignment: IPv6-Resolved IPv4 Gateway
Author:     Remco van Mook
Filename:   draft-mook-ipv6-resolved-ipv4-gateway-00.txt
Pages:      XX
Date:       2025-07-09

Status of This Memo

   This Internet-Draft is submitted in full conformance with the
   provisions of BCP 78 and BCP 79.

   Internet-Drafts are working documents of the Internet Engineering
   Task Force (IETF).  Note that other groups may also distribute
   working documents as Internet-Drafts.  The list of current Internet-
   Drafts is at https://datatracker.ietf.org/drafts/current/.

   Internet-Drafts are draft documents valid for a maximum of six months
   and may be updated, replaced, or obsoleted by other documents at any
   time.  It is inappropriate to use Internet-Drafts as reference
   material or to cite them other than as "work in progress."

   This Internet-Draft will expire on 9 January 2026.

Copyright Notice

   Copyright (c) 2025 IETF Trust and the persons identified as the
   document authors. All rights reserved.

   This document is subject to BCP 78 and the IETF Trust's Legal
   Provisions Relating to IETF Documents
   (https://trustee.ietf.org/license-info) in effect on the date of
   publication of this document. Please review these documents
   carefully, as they describe your rights and restrictions with respect
   to this document.

Abstract

   This document requests the allocation of a new IPv4 special-purpose
   address from the IANA IPv4 Special-Purpose Address Registry. The
   proposed address, 192.0.0.11/32, is intended to serve as a signal to
   IPv4 hosts in IPv6-only networks that the link-layer resolution for
   the default gateway should be derived from the IPv6 default gateway
   learned via IPv6 Router Advertisements and Neighbor Discovery.

   This approach enables IPv4 communication without requiring IPv4
   subnets or the use of ARP. It maintains backward compatibility with
   existing IPv4 host software that expects a default gateway IP
   address, while avoiding the need to implement legacy link-layer
   protocols.

   Importantly, this method does not require tunneling or translation.
   IPv4 packets remain fully native and unaltered, which simplifies
   deployment and ensures minimal disruption across existing
   infrastructure. While it's unlikely that any modern host or gateway
   would be unable to process a native IPv4 packet, that doesn’t mean we
   cannot evolve the internal mechanics of next-hop resolution.

Table of Contents

   1. Introduction
   2. Rationale
   3. Compatibility Considerations
   4. Requested IANA Assignment
   5. Security Considerations
   6. Informative References
   Author's Address

1. Introduction

   In IPv6-only infrastructure environments, such as modern data centers
   and ISP networks, IPv4 communication may still be required by
   applications or systems. However, traditional IPv4 mechanisms like
   ARP and subnet configuration impose unnecessary complexity in such
   environments.

   Hosts in these environments typically receive IPv6 configuration
   through SLAAC or DHCPv6, including a default gateway. This document
   proposes a method by which IPv4 traffic may also be sent without
   requiring ARP or an IPv4 subnet: by configuring a well-known IPv4
   address (192.0.0.11) as the default gateway, and resolving its
   link-layer address using the IPv6 default gateway learned by the host.

   Crucially, this method does not involve any tunneling or translation
   mechanisms. IPv4 packets remain standard and native throughout,
   requiring no encapsulation or rewriting in transit. While it is
   unlikely for any end host or intermediate gateway to be unable to
   process an ordinary IPv4 packet any time soon, the opportunity still
   exists to evolve the way we determine where those packets are sent.

   This document defines the behavior and compatibility expectations
   for hosts and forwarding stacks using this mechanism and requests
   IANA assignment of 192.0.0.11/32 for this purpose.

2. Rationale

   The key goal is to enable IPv4 communication in environments that
   are natively IPv6-only, without relying on dual-stack or tunneling.
   This is accomplished by decoupling IPv4 next-hop resolution from ARP
   and instead aligning it with the IPv6 default gateway.

   By defining 192.0.0.11 as a special-purpose IPv4 address, hosts can
   be configured with IPv4 /32 addresses and this default gateway,
   eliminating the need for any IPv4 subnet or address resolution
   mechanisms.

   In environments where host operating systems do not support this
   special behavior natively, interoperability can still be achieved.
   Routers may be configured to respond to ARP requests for 192.0.0.11
   with their own link-layer address. This allows traditional ARP-based
   stacks to reach the IPv6-based next hop using standard IPv4 behavior.

   Additionally, the use of a fixed, well-known gateway address enables
   DHCPv4 servers to signal this behavior without requiring any protocol
   extensions. By including a static route for 192.0.0.11 in DHCP
   responses, backward-compatible clients can operate normally, while
   enhanced clients can interpret the address as a signal to use IPv6
   neighbor discovery instead of ARP.

3. Compatibility Considerations

   - Hosts continue to use standard IPv4 protocol semantics and packet
     formats.
   - Applications requiring IPv4 continue to function as expected.
   - No changes are required to the IPv4 packet format.
   - The only change is that 192.0.0.11 is interpreted by the host stack
     as an indicator to use the link-layer information from the IPv6
     default gateway.
   - In environments where this behavior is not supported:
     - Routers may respond to ARP requests for 192.0.0.11 with their own
       MAC address, enabling compatibility with legacy stacks.
     - DHCPv4 responses can include a route for 192.0.0.11, signaling
       the expected next hop while remaining valid in all standard
       implementations.
   - These fallback mechanisms allow the address to function in legacy
     environments while enabling enhanced behavior where supported.

4. Requested IANA Assignment

   This document requests the following addition to the IANA IPv4
   Special-Purpose Address Registry:

   Address Block: 192.0.0.11/32
   Name: IPv6-Resolved Default Gateway
   RFC: [This document]
   Allocation Date: [To be assigned]
   Termination Date: N/A
   Source: False
   Destination: True
   Forwardable: True
   Global: No
   Reserved-by-Protocol: No

5. Security Considerations

   This approach reduces ARP-related attack surfaces by removing ARP
   from the network. It assumes integrity of IPv6 neighbor discovery,
   and any associated risks (e.g., spoofed RAs) are equivalent to
   standard IPv6 host risks.

6. Informative References

   [RFC4861]  Narten, T., Nordmark, E., Simpson, W., and H. Soliman,
   "Neighbor Discovery for IP version 6 (IPv6)",
   RFC 4861, September 2007.

   [RFC8174]  Leiba, B., "Ambiguity of Uppercase vs Lowercase in RFC 2119
   Key Words", BCP 14, RFC 8174, May 2017.

   [RFC7600]  Kumari, W. and P. Ebersman, "IPv4 Run-Out and IPv4-Only
   Terminology Considerations", RFC 7600, August 2015.

   [RFC7606]  Chen, E., Scudder, J., "Revised Error Handling for BGP
   UPDATE Messages", RFC 7606, August 2015.

   [v4-via-v6] Ananthakrishnan, H., et al., "IPv4 Unicast Transmission
   Using an IPv6 Fabric", draft-ietf-intarea-v4-via-v6,
   IETF, March 2024.

Author's Address

   Remco van Mook
   Novoserve B.V.
   Email: remco@novoserve.com

