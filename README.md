# v4-with-v6-nh
In Linux, use your IPv6 default gateway ethernet next-hop address as the next hop for IPv4 traffic. 
This allows you to set individual IPv4 addresses on a public interface without ever defining a local IPv4 subnet or gateway.

Barely tested, may insult your boss and harm your dog. Proceed with caution.

On the side of the router, you either:
- need to have a routing daemon running which sets the next hop for the IP to one of its v6 addresses
- set a static ARP entry (ugly but works almost everywhere)

Work in progress:
- fully daemonized in C
- Python version
- Bird configuration to use OSPFv3 to advertise your local IPv4 addresses with your IPv6 next-hop
- Datacenter level API to assign, register and deregister local IPv4 addresses with your IPv6 next-hop using a route reflector

