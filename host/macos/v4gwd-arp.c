/* SPDX-License-Identifier: BSD-2-Clause
 *
 * v4gwd-arp - IPv6-Resolved IPv4 Gateway daemon, macOS variant.
 *
 * Host-side implementation of draft-vanmook-intarea-ipv6-resolved-gateway
 * (Section 4) for macOS, which -- unlike Linux (RTA_VIA) and FreeBSD
 * (RFC 5549) -- has no kernel support for IPv4 routes with an IPv6 next
 * hop.  It reaches the identical on-wire behaviour without any kernel
 * change, using a realization that needs only standard BSD tooling:
 *
 *   The special-purpose IPv4 gateway 192.0.0.11 has no host of its own;
 *   its link-layer address is simply that of the IPv6 default router --
 *   one interface, one MAC.  So instead of resolving 192.0.0.11 by ARP,
 *   this daemon:
 *
 *     1. follows the IPv6 default route on the managed interface to find
 *        the default router (RTM/NET_RT_DUMP);
 *     2. reads that router's link-layer address from the Neighbor
 *        Discovery cache (NET_RT_FLAGS | RTF_LLINFO, the source ndp(8)
 *        uses) -- never ARP;
 *     3. installs a static ARP entry  192.0.0.11 -> <router MAC>  so the
 *        stock "default via 192.0.0.11" route resolves to the router's
 *        MAC and IPv4 frames leave addressed to it, exactly as the
 *        RFC 5549 realization would put them on the wire;
 *     4. keeps the entry in sync as the IPv6 default router or its MAC
 *        changes, and removes it when no usable router remains.
 *
 * No ARP is ever emitted for 192.0.0.11 (the static entry pre-empts it);
 * the link-layer address is taken from the ND cache, satisfying the
 * draft's Section 4 host behaviour.  Reachability of the gateway is
 * driven by the IPv6 neighbor's ND state, which the kernel maintains for
 * IPv6 regardless; this daemon mirrors it into the IPv4 ARP table.
 *
 * Discovery uses the routing socket directly.  The mutation shells out to
 * arp(8) (arp -s / arp -d), whose flag/sockaddr handling is fiddly and
 * version-specific; keeping it in the proven tool avoids a hand-rolled
 * RTM_ADD.  -n performs discovery only and reports what it would do.
 *
 * Usage:
 *   v4gwd-arp [-n] [-r | -f statefile] [-i interval] ifname
 */

#include <sys/param.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>

#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>

#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>

#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>

/* The special-purpose IPv4 gateway.  Draft-provisional 192.0.0.11, overridable
 * via V4GW_GATEWAY (parsed in main) so the address is not baked in ahead of its
 * IANA assignment.  The default is unchanged. */
static char      sentinel_str[16] = "192.0.0.11";
static in_addr_t sentinel_addr;         /* network order; set from sentinel_str */
#define DEFAULT_INTERVAL 15

/* Darwin pads routing-socket sockaddrs to 4-byte (uint32_t) boundaries. */
#define ROUNDUP(a) \
    ((a) > 0 ? (1 + (((a) - 1) | (sizeof(uint32_t) - 1))) : sizeof(uint32_t))

static volatile sig_atomic_t running = 1;

static const char *ifname;
static unsigned int ifindex;
static bool require_sentinel_route = false;
static const char *sentinel_file = NULL;
static int interval = DEFAULT_INTERVAL;
static bool dry_run = false;

static int rtsock = -1;

static bool arp_installed = false;
static uint8_t installed_mac[6];

/*
 * Persistent map of resolved router MAC keyed to the interface's own MAC at
 * the time it was learned.  macOS assigns a different link-layer address per
 * network (private/randomised MACs), so the own-MAC is a per-network key: a
 * hit means we are on a network we have seen and the stored router MAC is safe
 * to re-assert during a bring-up, before Neighbor Discovery has re-resolved it
 * (this also survives a daemon restart / reboot).  A miss means a new or moved
 * network -- cede to the host's normal ARP bootstrap rather than steer traffic
 * at a stale MAC.
 *
 * The key is a heuristic, not a guarantee: if the own-MAC does not rotate and
 * the host moves to a different network, it still hits and we re-assert a stale
 * 192.0.0.11 MAC.  That is harmless -- 192.0.0.11 is the gateway only on a
 * sentinel segment, so on an ordinary network nothing routes through it and the
 * entry is never consulted.  Only landing on another sentinel segment (with a
 * different router) has any effect, and reconcile corrects the MAC in a cycle.
 *
 * On disk it is a directory with one file per network: the filename is the
 * interface own-MAC and the contents are the router MAC.  The filesystem is the
 * map -- lookup reads one file, store writes one -- so there is no in-memory
 * table, and an operator can list, read, or remove mappings with ls/cat/rm.
 */
#define ROUTER_CACHE_DIR   "/var/db/v4gwd-arp"

static void
handle_sig(int sig)
{
        (void)sig;
        running = 0;
}

/* Split a route message's packed sockaddr array into the RTAX_* slots. */
static void
get_rti_info(int addrs, struct sockaddr *sa, struct sockaddr **rti)
{
        for (int i = 0; i < RTAX_MAX; i++) {
                if (addrs & (1 << i)) {
                        rti[i] = sa;
                        sa = (struct sockaddr *)(void *)
                            ((char *)sa + ROUNDUP(sa->sa_len));
                } else {
                        rti[i] = NULL;
                }
        }
}

/* Clear the KAME embedded scope id (bytes 2-3) of a link-local address. */
static void
strip_embedded_scope(struct in6_addr *a)
{
        if (IN6_IS_ADDR_LINKLOCAL(a)) {
                a->s6_addr[2] = 0;
                a->s6_addr[3] = 0;
        }
}

/*
 * Follow the IPv6 default route on our interface: scan the routing table
 * for the ::/0 gateway route whose next hop is a link-local on ifindex.
 */
static bool
find_default_router(struct in6_addr *gw)
{
        int mib[6] = { CTL_NET, PF_ROUTE, 0, AF_INET6, NET_RT_DUMP, 0 };
        char *buf = NULL, *p, *end;
        size_t len = 0;
        bool found = false;

        if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0 || len == 0)
                return false;
        if ((buf = malloc(len)) == NULL)
                return false;
        if (sysctl(mib, 6, buf, &len, NULL, 0) < 0) {
                free(buf);
                return false;
        }

        end = buf + len;
        for (p = buf; p < end; ) {
                struct rt_msghdr *rtm = (struct rt_msghdr *)(void *)p;
                struct sockaddr *rti[RTAX_MAX];
                struct sockaddr_in6 *d6, *g6;

                p += rtm->rtm_msglen;
                if (rtm->rtm_version != RTM_VERSION)
                        continue;
                if ((rtm->rtm_flags & (RTF_GATEWAY | RTF_UP)) !=
                    (RTF_GATEWAY | RTF_UP))
                        continue;
                if (rtm->rtm_index != ifindex)
                        continue;

                get_rti_info(rtm->rtm_addrs, (struct sockaddr *)(rtm + 1), rti);
                if (rti[RTAX_DST] == NULL || rti[RTAX_GATEWAY] == NULL)
                        continue;
                if (rti[RTAX_DST]->sa_family != AF_INET6 ||
                    rti[RTAX_GATEWAY]->sa_family != AF_INET6)
                        continue;

                d6 = (struct sockaddr_in6 *)(void *)rti[RTAX_DST];
                if (!IN6_IS_ADDR_UNSPECIFIED(&d6->sin6_addr))
                        continue;       /* not the default (::/0) route */

                g6 = (struct sockaddr_in6 *)(void *)rti[RTAX_GATEWAY];
                *gw = g6->sin6_addr;
                strip_embedded_scope(gw);
                found = true;
                break;
        }

        free(buf);
        return found;
}

/*
 * Read a neighbour's link-layer address from the ND cache (the
 * NET_RT_FLAGS | RTF_LLINFO table, the same source ndp(8) reads).
 */
static bool
router_lladdr(const struct in6_addr *gw, uint8_t mac[6])
{
        int mib[6] = { CTL_NET, PF_ROUTE, 0, AF_INET6, NET_RT_FLAGS, RTF_LLINFO };
        char *buf = NULL, *p, *end;
        size_t len = 0;
        bool found = false;

        if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0 || len == 0)
                return false;
        if ((buf = malloc(len)) == NULL)
                return false;
        if (sysctl(mib, 6, buf, &len, NULL, 0) < 0) {
                free(buf);
                return false;
        }

        end = buf + len;
        for (p = buf; p < end; ) {
                struct rt_msghdr *rtm = (struct rt_msghdr *)(void *)p;
                struct sockaddr *rti[RTAX_MAX];
                struct sockaddr_in6 *d6;
                struct sockaddr_dl *sdl;
                struct in6_addr a;

                p += rtm->rtm_msglen;
                if (rtm->rtm_version != RTM_VERSION)
                        continue;
                if (rtm->rtm_index != ifindex)
                        continue;

                get_rti_info(rtm->rtm_addrs, (struct sockaddr *)(rtm + 1), rti);
                if (rti[RTAX_DST] == NULL || rti[RTAX_GATEWAY] == NULL)
                        continue;
                if (rti[RTAX_DST]->sa_family != AF_INET6 ||
                    rti[RTAX_GATEWAY]->sa_family != AF_LINK)
                        continue;

                d6 = (struct sockaddr_in6 *)(void *)rti[RTAX_DST];
                a = d6->sin6_addr;
                strip_embedded_scope(&a);
                if (!IN6_ARE_ADDR_EQUAL(&a, gw))
                        continue;

                sdl = (struct sockaddr_dl *)(void *)rti[RTAX_GATEWAY];
                if (sdl->sdl_alen != 6)
                        continue;       /* not yet resolved */
                memcpy(mac, LLADDR(sdl), 6);
                found = true;
                break;
        }

        free(buf);
        return found;
}

/*
 * Is *our* static ARP entry for 192.0.0.11 still in the kernel with the
 * expected MAC?  An external flush -- a DHCP reconfigure, an interface
 * flap, `arp -d -a` -- can drop it without any routing-socket message we
 * act on, so the steady-state check verifies against the live AF_INET
 * link-layer table (RTF_LLINFO, what `arp -a` reads) rather than trusting
 * the arp_installed flag alone.
 *
 * The entry must be RTF_STATIC ("permanent"): once ours is gone, the host
 * resolves the gateway by ordinary ARP, leaving a *dynamic* entry with the
 * same (correct) MAC.  Accepting that would defeat the daemon -- the whole
 * point is that the host never ARPs for 192.0.0.11 -- so a non-static
 * entry counts as absent and we re-assert the permanent one over it.
 */
static bool
arp_entry_present(const uint8_t mac[6])
{
        int mib[6] = { CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO };
        char *buf = NULL, *p, *end;
        size_t len = 0;
        bool found = false;

        if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0 || len == 0)
                return false;
        if ((buf = malloc(len)) == NULL)
                return false;
        if (sysctl(mib, 6, buf, &len, NULL, 0) < 0) {
                free(buf);
                return false;
        }

        end = buf + len;
        for (p = buf; p < end; ) {
                struct rt_msghdr *rtm = (struct rt_msghdr *)(void *)p;
                struct sockaddr *rti[RTAX_MAX];
                struct sockaddr_in *dst;
                struct sockaddr_dl *sdl;

                p += rtm->rtm_msglen;
                if (rtm->rtm_version != RTM_VERSION)
                        continue;
                if (rtm->rtm_index != ifindex)
                        continue;

                get_rti_info(rtm->rtm_addrs, (struct sockaddr *)(rtm + 1), rti);
                if (rti[RTAX_DST] == NULL || rti[RTAX_GATEWAY] == NULL)
                        continue;
                if (rti[RTAX_DST]->sa_family != AF_INET ||
                    rti[RTAX_GATEWAY]->sa_family != AF_LINK)
                        continue;

                dst = (struct sockaddr_in *)(void *)rti[RTAX_DST];
                if (dst->sin_addr.s_addr != (in_addr_t)sentinel_addr)
                        continue;

                sdl = (struct sockaddr_dl *)(void *)rti[RTAX_GATEWAY];
                found = (sdl->sdl_alen == 6 &&
                    memcmp(LLADDR(sdl), mac, 6) == 0 &&
                    (rtm->rtm_flags & RTF_STATIC));
                break;
        }

        free(buf);
        return found;
}

/* Run a command to completion with output discarded; 0 on exit status 0. */
static int
run(char *const argv[])
{
        pid_t pid;
        int status;

        pid = fork();
        if (pid < 0)
                return -1;
        if (pid == 0) {
                int fd = open("/dev/null", O_WRONLY);
                if (fd >= 0) {
                        dup2(fd, STDOUT_FILENO);
                        dup2(fd, STDERR_FILENO);
                        if (fd > STDERR_FILENO)
                                close(fd);
                }
                execv(argv[0], argv);
                _exit(127);
        }
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
                ;
        return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : -1;
}

static void
mac_str(const uint8_t mac[6], char out[18])
{
        snprintf(out, 18, "%02x:%02x:%02x:%02x:%02x:%02x",
            mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

static void
install(const uint8_t mac[6])
{
        char macstr[18];
        char ifbuf[IF_NAMESIZE];
        char *sv[] = { "/usr/sbin/arp", "-s", sentinel_str, NULL,
            "ifscope", NULL, NULL };

        /*
         * Re-assert if the kernel entry is gone even when our flag still
         * says installed: an external flush must not leave 192.0.0.11
         * unresolved until the router's MAC happens to change.
         */
        if (arp_installed && memcmp(installed_mac, mac, 6) == 0 &&
            arp_entry_present(mac))
                return;

        mac_str(mac, macstr);
        strlcpy(ifbuf, ifname, sizeof(ifbuf));
        sv[3] = macstr;
        sv[5] = ifbuf;

        if (run(sv) != 0) {
                syslog(LOG_ERR, "%s: arp -s %s %s failed",
                    ifname, sentinel_str, macstr);
                return;
        }
        syslog(LOG_NOTICE, "%s: IPv4 gateway %s -> %s "
            "(ND-resolved IPv6 default router)", ifname, sentinel_str, macstr);
        arp_installed = true;
        memcpy(installed_mac, mac, 6);
}

static void
withdraw(const char *reason)
{
        char ifbuf[IF_NAMESIZE];
        char *dv[] = { "/usr/sbin/arp", "-d", sentinel_str,
            "ifscope", NULL, NULL };

        if (!arp_installed)
                return;

        strlcpy(ifbuf, ifname, sizeof(ifbuf));
        dv[4] = ifbuf;
        (void)run(dv);
        syslog(LOG_NOTICE, "%s: withdrew static ARP for %s (%s)",
            ifname, sentinel_str, reason);
        arp_installed = false;
}

/*
 * Sentinel checks.  -f statefile: a DHCP hook records the Router option.
 * -r: the IPv4 FIB carries a default route via 192.0.0.11.  With neither,
 * the interface is managed unconditionally (lab mode).
 */
static bool
sentinel_in_file(void)
{
        char buf[64];
        FILE *fp;
        bool ok = false;

        if ((fp = fopen(sentinel_file, "r")) == NULL)
                return false;
        if (fgets(buf, sizeof(buf), fp) != NULL)
                ok = strncmp(buf, sentinel_str, strlen(sentinel_str)) == 0;
        fclose(fp);
        return ok;
}

static bool
sentinel_in_fib(void)
{
        int mib[6] = { CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0 };
        char *buf = NULL, *p, *end;
        size_t len = 0;
        bool found = false;

        if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0 || len == 0)
                return false;
        if ((buf = malloc(len)) == NULL)
                return false;
        if (sysctl(mib, 6, buf, &len, NULL, 0) < 0) {
                free(buf);
                return false;
        }

        end = buf + len;
        for (p = buf; p < end; ) {
                struct rt_msghdr *rtm = (struct rt_msghdr *)(void *)p;
                struct sockaddr *rti[RTAX_MAX];
                struct sockaddr_in *dst, *gw;

                p += rtm->rtm_msglen;
                if (rtm->rtm_version != RTM_VERSION)
                        continue;
                if ((rtm->rtm_flags & RTF_GATEWAY) == 0)
                        continue;

                get_rti_info(rtm->rtm_addrs, (struct sockaddr *)(rtm + 1), rti);
                if (rti[RTAX_DST] == NULL || rti[RTAX_GATEWAY] == NULL)
                        continue;
                if (rti[RTAX_DST]->sa_family != AF_INET ||
                    rti[RTAX_GATEWAY]->sa_family != AF_INET)
                        continue;

                dst = (struct sockaddr_in *)(void *)rti[RTAX_DST];
                gw = (struct sockaddr_in *)(void *)rti[RTAX_GATEWAY];
                if (dst->sin_addr.s_addr != 0)
                        continue;       /* not the default route */
                if (gw->sin_addr.s_addr == sentinel_addr) {
                        found = true;
                        break;
                }
        }

        free(buf);
        return found;
}

/* Path of the per-network entry file (named by the interface own-MAC). */
static void
router_cache_path(const uint8_t host[6], char *out, size_t outlen)
{
        char h[18];

        mac_str(host, h);
        snprintf(out, outlen, ROUTER_CACHE_DIR "/%s", h);
}

/* Fill `router` from the stored entry for this own-MAC; false if none. */
static bool
router_cache_lookup(const uint8_t host[6], uint8_t router[6])
{
        char path[64], line[32];
        FILE *fp;
        bool ok = false;

        router_cache_path(host, path, sizeof(path));
        if ((fp = fopen(path, "r")) == NULL)
                return false;
        if (fgets(line, sizeof(line), fp) != NULL &&
            sscanf(line, "%hhx:%hhx:%hhx:%hhx:%hhx:%hhx",
                &router[0], &router[1], &router[2],
                &router[3], &router[4], &router[5]) == 6)
                ok = true;
        fclose(fp);
        return ok;
}

/* Store the own-MAC -> router-MAC mapping (idempotent, atomic). */
static void
router_cache_put(const uint8_t host[6], const uint8_t router[6])
{
        char path[64], tmp[72], r[18];
        uint8_t cur[6];
        FILE *fp;

        if (router_cache_lookup(host, cur) && memcmp(cur, router, 6) == 0)
                return;                         /* unchanged */

        (void) mkdir(ROUTER_CACHE_DIR, 0755);
        router_cache_path(host, path, sizeof(path));
        snprintf(tmp, sizeof(tmp), "%s.tmp", path);
        if ((fp = fopen(tmp, "w")) == NULL)
                return;
        mac_str(router, r);
        fprintf(fp, "%s\n", r);
        fclose(fp);
        (void) rename(tmp, path);
}

/*
 * The interface's own link-layer (MAC) address -- used as a per-network key
 * (see the cache note above).
 */
static bool
iface_lladdr(const char *ifn, uint8_t mac[6])
{
        struct ifaddrs *ifap, *ifa;
        bool found = false;

        if (getifaddrs(&ifap) != 0)
                return false;
        for (ifa = ifap; ifa != NULL; ifa = ifa->ifa_next) {
                struct sockaddr_dl *sdl;

                if (ifa->ifa_addr == NULL ||
                    ifa->ifa_addr->sa_family != AF_LINK ||
                    strcmp(ifa->ifa_name, ifn) != 0)
                        continue;
                sdl = (struct sockaddr_dl *)(void *)ifa->ifa_addr;
                if (sdl->sdl_alen == 6) {
                        memcpy(mac, LLADDR(sdl), 6);
                        found = true;
                        break;
                }
        }
        freeifaddrs(ifap);
        return found;
}

static void
reconcile(void)
{
        struct in6_addr gw;
        uint8_t mac[6], host_mac[6];
        bool have_host_mac;

        ifindex = if_nametoindex(ifname);
        if (ifindex == 0) {
                arp_installed = false;          /* interface gone */
                return;
        }

        if (sentinel_file != NULL && !sentinel_in_file()) {
                withdraw("sentinel state cleared; ceasing per draft s4");
                return;
        }
        if (require_sentinel_route && !sentinel_in_fib()) {
                withdraw("sentinel 192.0.0.11 route removed; ceasing per draft s4");
                return;
        }

        have_host_mac = iface_lladdr(ifname, host_mac);

        if (find_default_router(&gw) && router_lladdr(&gw, mac)) {
                /* Router resolved via ND: install it, and record it keyed to
                 * the interface's own MAC (persisted for the next bring-up). */
                install(mac);
                if (have_host_mac)
                        router_cache_put(host_mac, mac);
                return;
        }

        /*
         * The router MAC is not resolvable yet -- the startup/transition
         * window before an RA has repopulated the ND cache.  If we have a
         * stored router MAC for this interface own-MAC, we are on a network we
         * have seen: re-assert it now, ahead of the host resolving the gateway
         * by ARP (the DAD on the host's own address buys us ~a second).  A miss
         * (new or moved network) means the stored mappings do not apply -- cede
         * to the host's normal ARP bootstrap rather than steer traffic at a
         * stale MAC.
         */
        uint8_t cached[6];
        if (have_host_mac && router_cache_lookup(host_mac, cached)) {
                install(cached);
                return;
        }
        withdraw("no IPv6 default router resolved yet; ceding to ARP bootstrap");
}

/* -n: discovery only.  Report what would be programmed and exit. */
static int
dry_run_report(void)
{
        struct in6_addr gw;
        uint8_t mac[6];
        char a[INET6_ADDRSTRLEN], macstr[18];

        ifindex = if_nametoindex(ifname);
        if (ifindex == 0) {
                fprintf(stderr, "v4gwd-arp: %s: no such interface\n", ifname);
                return 1;
        }
        printf("v4gwd-arp dry run on %s (ifindex %u)\n", ifname, ifindex);

        if (require_sentinel_route)
                printf("  sentinel %s in IPv4 FIB : %s\n", sentinel_str,
                    sentinel_in_fib() ? "yes" : "no (would not manage)");
        if (sentinel_file != NULL)
                printf("  sentinel state file      : %s\n",
                    sentinel_in_file() ? "active" : "inactive (would not manage)");

        if (!find_default_router(&gw)) {
                printf("  IPv6 default router      : none on %s "
                    "(would remove any entry)\n", ifname);
                return 0;
        }
        inet_ntop(AF_INET6, &gw, a, sizeof(a));
        printf("  IPv6 default router      : %s%%%s\n", a, ifname);

        if (!router_lladdr(&gw, mac)) {
                printf("  router link-layer        : unresolved in ND cache "
                    "(would wait)\n");
                return 0;
        }
        mac_str(mac, macstr);
        printf("  router link-layer        : %s (from ND cache)\n", macstr);
        printf("  would install            : arp -s %s %s ifscope %s\n",
            sentinel_str, macstr, ifname);
        return 0;
}

static void
usage(void)
{
        fprintf(stderr, "usage: v4gwd-arp [-n] [-r | -f statefile] "
            "[-i interval] ifname\n");
        exit(1);
}

int
main(int argc, char **argv)
{
        struct pollfd pfd;
        char msgbuf[2048];
        int ch;

        const char *envgw = getenv("V4GW_GATEWAY");
        struct in_addr sa;
        if (envgw && *envgw)
                snprintf(sentinel_str, sizeof sentinel_str, "%s", envgw);
        if (inet_aton(sentinel_str, &sa) == 0)
                errx(2, "invalid V4GW_GATEWAY '%s'", sentinel_str);
        sentinel_addr = sa.s_addr;

        while ((ch = getopt(argc, argv, "nrf:i:")) != -1) {
                switch (ch) {
                case 'n':
                        dry_run = true;
                        break;
                case 'r':
                        require_sentinel_route = true;
                        break;
                case 'f':
                        sentinel_file = optarg;
                        break;
                case 'i':
                        interval = atoi(optarg);
                        if (interval < 1)
                                usage();
                        break;
                default:
                        usage();
                }
        }
        argc -= optind;
        argv += optind;
        if (argc != 1 || (require_sentinel_route && sentinel_file != NULL))
                usage();
        ifname = argv[0];

        if (dry_run)
                return dry_run_report();

        openlog("v4gwd-arp", LOG_PID | LOG_PERROR, LOG_DAEMON);

        /*
         * Do not require the interface to exist yet.  At boot the daemon can be
         * started before the NIC is up; exiting here would make launchd
         * throttle-restart us until it appears -- tens of seconds later, well
         * after the network has been brought up and the gateway ARP-resolved.
         * Staying alive and watching the routing socket lets us re-assert the
         * gateway the instant the interface is configured.  reconcile() handles
         * a not-yet-present interface, and the poll loop wakes on its arrival.
         */
        ifindex = if_nametoindex(ifname);
        if (ifindex == 0)
                syslog(LOG_NOTICE, "%s: not present yet, waiting", ifname);

        rtsock = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC);
        if (rtsock < 0)
                err(1, "socket(PF_ROUTE)");

        signal(SIGINT, handle_sig);
        signal(SIGTERM, handle_sig);

        reconcile();

        pfd.fd = rtsock;
        pfd.events = POLLIN;

        /*
         * rtsock has no neighbour-cache notifications, so a route-socket
         * wakeup (default route / link changes) plus a periodic reconcile
         * cover MAC and reachability changes.  Reconciliation is idempotent.
         */
        while (running) {
                int n = poll(&pfd, 1, interval * 1000);

                if (n > 0)
                        (void)read(rtsock, msgbuf, sizeof(msgbuf));
                reconcile();
        }

        withdraw("daemon shutdown");
        close(rtsock);
        closelog();
        return 0;
}
