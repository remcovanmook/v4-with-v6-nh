/* SPDX-License-Identifier: BSD-2-Clause
 *
 * v4gwd - IPv6-Resolved IPv4 Gateway daemon, FreeBSD implementation.
 *
 * Host-side reference implementation of
 * draft-vanmook-intarea-ipv6-resolved-gateway (Section 4) for
 * FreeBSD 13.1 and later.
 *
 * FreeBSD supports IPv4 routes with IPv6 next hops since commit
 * 62e1a437f328 ("routing: Allow using IPv6 next-hops for IPv4 routes
 * (RFC 5549)", 2021); such routes are resolved through IPv6 Neighbor
 * Discovery, never ARP.  This daemon implements Section 4 by:
 *
 *   1. determining that the interface's IPv4 default gateway is the
 *      sentinel 192.0.0.11 -- either unconditionally (lab mode), by
 *      finding a 192.0.0.11 default route in the FIB (-r), or via a
 *      state file maintained by dhclient-exit-hooks (-f), since
 *      dhclient cannot itself install a gateway that is not on a
 *      connected subnet;
 *   2. selecting an IPv6 default router from the kernel's default
 *      router list (sysctl net.inet6.icmp6.nd6_drlist, the same source
 *      ndp -r uses), honouring RFC 4191 Default Router Preference,
 *      with a deterministic lowest-address tie-breaker;
 *   3. installing "route add default -inet6 <router>" via a PF_ROUTE
 *      socket (RTM_ADD with an AF_INET destination and an AF_INET6
 *      gateway);
 *   4. withdrawing the route when the sentinel condition ceases
 *      (DHCPv4 lease expiry) or no usable router remains.
 *
 * Event model: PF_ROUTE delivers RTM_* messages for route changes
 * (including the kernel's RA-driven IPv6 default route updates), which
 * trigger reconciliation.  Unlike Linux netlink, rtsock carries no
 * neighbour-cache or router-list events, so a periodic reconcile
 * (default 15 s) backstops preference-only changes in the router list.
 * Reconciliation is idempotent.
 *
 * Usage:
 *   v4gwd [-r | -f statefile] [-m metric-fib] [-i interval] ifname
 */

#include <sys/param.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/time.h>

#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>

#include <netinet/in.h>
#include <arpa/inet.h>
#include <netinet6/in6_var.h>
#include <netinet/icmp6.h>
#include <netinet6/nd6.h>

#include <err.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>

#define SENTINEL_ADDR   htonl(0xc000000bU)      /* 192.0.0.11 */
#define DEFAULT_INTERVAL 15

static volatile sig_atomic_t running = 1;
static volatile sig_atomic_t reload = 0;

static const char *ifname;
static unsigned int ifindex;
static bool require_sentinel_route = false;
static const char *sentinel_file = NULL;
static int interval = DEFAULT_INTERVAL;

static int rtsock = -1;
static int rtseq = 1;

static bool route_installed = false;
static struct in6_addr installed_gw;

static void
handle_sig(int sig)
{
        if (sig == SIGHUP)
                reload = 1;
        else
                running = 0;
}

/*
 * RFC 4191 preference rank from the RA flags byte
 * (ND_RA_FLAG_RTPREF_* in <netinet/icmp6.h>).
 */
static int
pref_rank(uint8_t raflags)
{
        switch (raflags & ND_RA_FLAG_RTPREF_MASK) {
        case ND_RA_FLAG_RTPREF_HIGH:
                return 2;
        case ND_RA_FLAG_RTPREF_MEDIUM:
                return 1;
        case ND_RA_FLAG_RTPREF_LOW:
                return 0;
        default:
                return -1;      /* reserved: ignore router (RFC 4191 s2.2) */
        }
}

/*
 * Select an IPv6 default router on our interface from the kernel's
 * default router list.  Returns true and fills *gw on success.
 *
 * The list is exported by the ICMPV6CTL_ND6_DRLIST sysctl as an array
 * of struct in6_defrouter; entries with zero remaining lifetime are
 * pruned by the kernel.  Ties on preference break deterministically to
 * the numerically lowest address, matching the Linux implementations
 * in this repository.
 */
static bool
select_router(struct in6_addr *gw)
{
        int mib[4] = { CTL_NET, PF_INET6, IPPROTO_ICMPV6, ICMPV6CTL_ND6_DRLIST };
        char *buf = NULL, *p;
        size_t len = 0;
        struct in6_addr best;
        int best_rank = -1;
        bool found = false;

        if (sysctl(mib, nitems(mib), NULL, &len, NULL, 0) < 0 || len == 0)
                return false;

        buf = malloc(len);
        if (buf == NULL)
                return false;

        if (sysctl(mib, nitems(mib), buf, &len, NULL, 0) < 0) {
                free(buf);
                return false;
        }

        for (p = buf; p + sizeof(struct in6_defrouter) <= buf + len;
             p += sizeof(struct in6_defrouter)) {
                struct in6_defrouter *dr = (struct in6_defrouter *)(void *)p;
                int rank;

                if (dr->if_index != ifindex)
                        continue;

                rank = pref_rank(dr->flags);
                if (rank < best_rank)
                        continue;
                if (rank == best_rank && found &&
                    memcmp(&dr->rtaddr.sin6_addr, &best, sizeof(best)) >= 0)
                        continue;

                best_rank = rank;
                best = dr->rtaddr.sin6_addr;
                found = true;
        }

        free(buf);
        if (found)
                *gw = best;
        return found;
}

/*
 * The KAME stack expects link-local gateway addresses on the routing
 * socket with the scope (interface index) embedded in bytes 2-3 of the
 * address, not in sin6_scope_id.  route(8) does the same conversion.
 */
static void
fill_gateway(struct sockaddr_in6 *sin6, const struct in6_addr *gw)
{
        memset(sin6, 0, sizeof(*sin6));
        sin6->sin6_len = sizeof(*sin6);
        sin6->sin6_family = AF_INET6;
        sin6->sin6_addr = *gw;
        if (IN6_IS_ADDR_LINKLOCAL(gw) || IN6_IS_ADDR_MC_LINKLOCAL(gw)) {
                sin6->sin6_addr.s6_addr[2] = (ifindex >> 8) & 0xff;
                sin6->sin6_addr.s6_addr[3] = ifindex & 0xff;
        }
}

/*
 * Send RTM_ADD/RTM_CHANGE/RTM_DELETE for the IPv4 default route with an
 * IPv6 gateway.  Sockaddrs on the routing socket are laid out back to
 * back, each padded to a multiple of sizeof(long) (SA_SIZE()).
 */
static int
route_msg(u_char type, const struct in6_addr *gw)
{
        struct {
                struct rt_msghdr hdr;
                char space[512];
        } m;
        struct sockaddr_in dst, mask;
        struct sockaddr_in6 gw6;
        char *cp = m.space;
        ssize_t n;

        memset(&m, 0, sizeof(m));
        memset(&dst, 0, sizeof(dst));
        memset(&mask, 0, sizeof(mask));

        dst.sin_len = sizeof(dst);
        dst.sin_family = AF_INET;
        /* dst 0.0.0.0 */
        mask.sin_len = sizeof(mask);
        mask.sin_family = AF_INET;
        /* mask 0.0.0.0 */
        fill_gateway(&gw6, gw);

        memcpy(cp, &dst, sizeof(dst));
        cp += SA_SIZE(&dst);
        memcpy(cp, &gw6, sizeof(gw6));
        cp += SA_SIZE(&gw6);
        memcpy(cp, &mask, sizeof(mask));
        cp += SA_SIZE(&mask);

        m.hdr.rtm_msglen = (u_short)(sizeof(m.hdr) + (cp - m.space));
        m.hdr.rtm_version = RTM_VERSION;
        m.hdr.rtm_type = type;
        m.hdr.rtm_index = (u_short)ifindex;
        m.hdr.rtm_flags = RTF_UP | RTF_GATEWAY | RTF_STATIC;
        m.hdr.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK;
        m.hdr.rtm_pid = getpid();
        m.hdr.rtm_seq = rtseq++;

        n = write(rtsock, &m, m.hdr.rtm_msglen);
        if (n < 0)
                return -errno;
        return 0;
}

static void
install(const struct in6_addr *gw)
{
        char abuf[INET6_ADDRSTRLEN];
        int r;

        if (route_installed && IN6_ARE_ADDR_EQUAL(&installed_gw, gw))
                return;

        r = route_msg(route_installed ? RTM_CHANGE : RTM_ADD, gw);
        if (r == -EEXIST) {
                /* A stale route from a previous run; take it over. */
                r = route_msg(RTM_CHANGE, gw);
        }
        if (r < 0) {
                syslog(LOG_ERR, "%s: failed to install IPv4 default via "
                    "IPv6 next hop: %s", ifname, strerror(-r));
                return;
        }

        inet_ntop(AF_INET6, gw, abuf, sizeof(abuf));
        syslog(LOG_NOTICE, "%s: IPv4 default -> via inet6 %s", ifname, abuf);
        route_installed = true;
        installed_gw = *gw;
}

static void
withdraw(const char *reason)
{
        int r;

        if (!route_installed)
                return;

        r = route_msg(RTM_DELETE, &installed_gw);
        if (r < 0 && r != -ESRCH)
                syslog(LOG_ERR, "%s: failed to withdraw route: %s",
                    ifname, strerror(-r));
        else
                syslog(LOG_NOTICE, "%s: withdrew IPv4 default route (%s)",
                    ifname, reason);
        route_installed = false;
}

/*
 * Sentinel checks.  Two mechanisms:
 *
 * -f statefile: dhclient-exit-hooks writes the Router option value into
 *    the file on BOUND/RENEW/REBIND and removes it on EXPIRE/RELEASE
 *    (see dhclient-exit-hooks in this directory).  This is the practical
 *    mode on FreeBSD, since dhclient cannot install a default route via
 *    a gateway that is not on a connected subnet.
 *
 * -r: scan the FIB (NET_RT_DUMP sysctl) for an IPv4 default route with
 *    gateway 192.0.0.11, for setups that inject the sentinel route by
 *    other means.
 */
static bool
sentinel_in_file(void)
{
        char buf[64];
        FILE *fp;
        bool ok = false;

        fp = fopen(sentinel_file, "r");
        if (fp == NULL)
                return false;
        if (fgets(buf, sizeof(buf), fp) != NULL)
                ok = strncmp(buf, "192.0.0.11", 10) == 0;
        fclose(fp);
        return ok;
}

static bool
sentinel_in_fib(void)
{
        int mib[7] = { CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0, 0 };
        char *buf = NULL, *p;
        size_t len = 0;
        bool found = false;

        if (sysctl(mib, nitems(mib), NULL, &len, NULL, 0) < 0 || len == 0)
                return false;
        buf = malloc(len);
        if (buf == NULL)
                return false;
        if (sysctl(mib, nitems(mib), buf, &len, NULL, 0) < 0) {
                free(buf);
                return false;
        }

        for (p = buf; p < buf + len;) {
                struct rt_msghdr *rtm = (struct rt_msghdr *)(void *)p;
                struct sockaddr *sa, *dst = NULL, *gw = NULL;
                char *q;
                int i;

                p += rtm->rtm_msglen;
                if (rtm->rtm_version != RTM_VERSION)
                        continue;

                q = (char *)(rtm + 1);
                for (i = 1; i <= RTA_NETMASK; i <<= 1) {
                        if ((rtm->rtm_addrs & i) == 0)
                                continue;
                        sa = (struct sockaddr *)(void *)q;
                        if (i == RTA_DST)
                                dst = sa;
                        else if (i == RTA_GATEWAY)
                                gw = sa;
                        q += SA_SIZE(sa);
                }

                if (dst == NULL || gw == NULL)
                        continue;
                if (dst->sa_family != AF_INET || gw->sa_family != AF_INET)
                        continue;
                if (((struct sockaddr_in *)(void *)dst)->sin_addr.s_addr != 0)
                        continue;
                if ((rtm->rtm_flags & RTF_GATEWAY) == 0)
                        continue;
                if (((struct sockaddr_in *)(void *)gw)->sin_addr.s_addr ==
                    SENTINEL_ADDR) {
                        found = true;
                        break;
                }
        }

        free(buf);
        return found;
}

static void
reconcile(void)
{
        struct in6_addr gw;

        ifindex = if_nametoindex(ifname);
        if (ifindex == 0) {
                route_installed = false;        /* interface gone */
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

        if (!select_router(&gw)) {
                withdraw("no IPv6 default router on interface");
                return;
        }

        install(&gw);
}

static bool
kernel_supports_rfc5549(void)
{
        int v = 0;
        size_t len = sizeof(v);

        /* feature(3) knob added with the RFC 5549 data-plane support. */
        if (sysctlbyname("kern.features.ipv4_rfc5549_support",
            &v, &len, NULL, 0) == 0)
                return v != 0;

        /* Knob absent: old kernel, or renamed.  Proceed; RTM_ADD will
         * fail with a clear error if the support is really missing. */
        return true;
}

static void
usage(void)
{
        fprintf(stderr,
            "usage: v4gwd [-r | -f statefile] [-i interval] ifname\n");
        exit(1);
}

int
main(int argc, char **argv)
{
        struct pollfd pfd;
        char msgbuf[2048];
        int ch;

        while ((ch = getopt(argc, argv, "rf:i:")) != -1) {
                switch (ch) {
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

        ifindex = if_nametoindex(ifname);
        if (ifindex == 0)
                err(1, "%s", ifname);

        openlog("v4gwd", LOG_PID | LOG_PERROR, LOG_DAEMON);

        if (!kernel_supports_rfc5549())
                errx(1, "kernel lacks RFC 5549 support (IPv4 routes with "
                    "IPv6 next hops); FreeBSD 13.1 or newer is required");

        rtsock = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC);
        if (rtsock < 0)
                err(1, "socket(PF_ROUTE)");

        signal(SIGINT, handle_sig);
        signal(SIGTERM, handle_sig);
        signal(SIGHUP, handle_sig);

        reconcile();

        pfd.fd = rtsock;
        pfd.events = POLLIN;

        while (running) {
                int n = poll(&pfd, 1, interval * 1000);

                if (n > 0) {
                        /* Drain; contents don't matter, reconciliation
                         * is idempotent and re-reads full state. Skip
                         * echoes of our own messages. */
                        ssize_t r = read(rtsock, msgbuf, sizeof(msgbuf));
                        struct rt_msghdr *rtm =
                            (struct rt_msghdr *)(void *)msgbuf;

                        if (r >= (ssize_t)sizeof(*rtm) &&
                            rtm->rtm_pid == getpid())
                                continue;
                }
                if (reload)
                        reload = 0;
                reconcile();
        }

        withdraw("daemon shutdown");
        close(rtsock);
        closelog();
        return 0;
}
