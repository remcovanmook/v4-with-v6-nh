# v4-with-v6-nh
In Linux, use an IPv6 default gateway address as the next hop for IPv4 traffic. 

Barely tested, may insult your boss and harm your dog. Proceed with caution.

On the side of the router, you either:
- need to have a routing daemon running which sets the next hop for the IP to one of its v6 addresses
- set a static ARP entry (ugly but works almost everywhere)
