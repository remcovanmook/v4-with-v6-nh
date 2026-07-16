/* SPDX-License-Identifier: BSD-2-Clause
 *
 * v4gwd - IPv6-Resolved IPv4 Gateway daemon, Windows variant.
 *
 * Host-side implementation of draft-vanmook-intarea-ipv6-resolved-gateway
 * (Section 4) for Windows, which -- like macOS and unlike Linux (RTA_VIA)
 * and FreeBSD (RFC 5549) -- has no kernel support for IPv4 routes with an
 * IPv6 next hop.  It reaches the identical on-wire behaviour with no kernel
 * change, using the same realization as the macOS daemon but driven through
 * the IP Helper API instead of the BSD routing socket:
 *
 *   The special-purpose IPv4 gateway 192.0.0.11 has no host of its own; its
 *   link-layer address is simply that of the IPv6 default router -- one
 *   interface, one MAC.  So instead of resolving 192.0.0.11 by ARP, this
 *   daemon:
 *
 *     1. follows the IPv6 default route on the managed interface to find the
 *        default router (GetIpForwardTable2, ::/0);
 *     2. reads that router's link-layer address from the IPv6 Neighbor
 *        Discovery cache (GetIpNetTable2, AF_INET6) -- never ARP;
 *     3. pins a permanent IPv4 neighbor entry  192.0.0.11 -> <router MAC>
 *        (CreateIpNetEntry2, NlnsPermanent) so the stock "default via
 *        192.0.0.11" route resolves to the router's MAC and IPv4 frames
 *        leave addressed to it, exactly as the RFC 5549 realization would
 *        put them on the wire;
 *     4. keeps the entry slaved to the IPv6 default router as it (or its
 *        MAC) changes, re-asserts it if anything external drops or replaces
 *        it (deleting the entry makes Windows resolve 192.0.0.11 by ARP
 *        again), and removes it when no usable router remains.
 *
 * The entry is NlnsPermanent, so no ARP is ever emitted for 192.0.0.11 (a
 * permanent neighbor is immune to NUD); the link-layer address is taken from
 * the IPv6 ND cache, satisfying the draft's Section 4 host behaviour.  This is
 * a different *realization* of the same result, for hosts whose kernel cannot
 * express an IPv4 route with an IPv6 next hop.
 *
 * Discovery and mutation are entirely in-process via IP Helper (no shelling
 * out to netsh/route).  Reconciliation is event-driven: NotifyRouteChange2,
 * NotifyUnicastIpAddressChange and NotifyIpInterfaceChange wake a worker that
 * runs an idempotent reconcile(); a periodic timer covers anything the
 * notifications miss (e.g. a MAC change on the existing router).
 *
 * -n performs discovery only and reports what it would program.
 *
 * Usage:
 *   v4gwd.exe [-n] [-c] [-r] [-i interval] <interface>
 *     <interface>   adapter alias ("Ethernet") or numeric interface index
 *     -n            dry run: report discovery, make no changes, no privilege
 *     -c            run in the foreground (console) instead of as a service
 *     -r            only manage while an IPv4 default route via 192.0.0.11
 *                   is present in the FIB (sentinel gate); default is
 *                   unconditional (lab mode)
 *     -i interval   periodic reconcile seconds (default 15)
 *
 * Build (Developer Command Prompt / clang-cl), see README.md:
 *   cl /W4 /O2 v4gwd.c /link iphlpapi.lib ws2_32.lib advapi32.lib
 */

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>

#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "advapi32.lib")

#define SVCNAMEW          L"v4gwd"
#define SENTINEL_STR      "192.0.0.11"
#define SENTINEL_HOST     0xC000000BUL          /* 192.0.0.11, host order   */
#define DEFAULT_INTERVAL  15
#define LOGDIR            "C:\\ProgramData\\v4gwd"
#define LOGPATH           LOGDIR "\\v4gwd.log"

/* ------------------------------------------------------------------ state */

static wchar_t   g_ifarg[256];          /* interface alias or index, as given */
static NET_LUID  g_luid;
static bool      g_luid_valid = false;

static int       g_interval = DEFAULT_INTERVAL;
static bool      g_require_sentinel_route = false;
static bool      g_console = false;

static bool      g_installed = false;
static uint8_t   g_installed_mac[6];

static SERVICE_STATUS_HANDLE g_ssh;
static SERVICE_STATUS        g_status;
static HANDLE    g_stop_event = NULL;   /* manual-reset: signalled to quit    */
static HANDLE    g_wake_event = NULL;   /* auto-reset:  a change notification */

static HANDLE    g_h_route = NULL, g_h_addr = NULL, g_h_iface = NULL;

/* ---------------------------------------------------------------- logging */

static void
logmsg(const char *fmt, ...)
{
        char buf[512];
        char line[600];
        SYSTEMTIME st;
        va_list ap;

        va_start(ap, fmt);
        _vsnprintf_s(buf, sizeof(buf), _TRUNCATE, fmt, ap);
        va_end(ap);

        GetLocalTime(&st);
        _snprintf_s(line, sizeof(line), _TRUNCATE,
            "%04u-%02u-%02u %02u:%02u:%02u v4gwd: %s",
            st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, buf);

        if (g_console) {
                fprintf(stderr, "%s\n", line);
                return;
        }
        OutputDebugStringA(line);
        FILE *fp = NULL;
        if (fopen_s(&fp, LOGPATH, "a") == 0 && fp != NULL) {
                fprintf(fp, "%s\n", line);
                fclose(fp);
        }
}

static void
mac_str(const uint8_t mac[6], char out[18])
{
        _snprintf_s(out, 18, _TRUNCATE, "%02x:%02x:%02x:%02x:%02x:%02x",
            mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

/* Registry cache format (hyphen/upper), matching Get-NetAdapter / v4gwd.ps1. */
static void
mac_str_reg(const uint8_t mac[6], char out[18])
{
        _snprintf_s(out, 18, _TRUNCATE, "%02X-%02X-%02X-%02X-%02X-%02X",
            mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

/* ------------------------------------------------------- interface lookup */

/*
 * Resolve the interface argument (alias like "Ethernet", or a numeric index)
 * to a persistent NET_LUID.  Resolved lazily and cached: at boot the adapter
 * may not be fully up when the service starts, so a failure here is not fatal
 * -- reconcile() retries until it succeeds, mirroring the macOS daemon's
 * tolerance of a not-yet-present interface.
 */
static bool
resolve_luid(void)
{
        NET_IFINDEX idx;
        wchar_t *end = NULL;
        unsigned long n;

        if (g_luid_valid)
                return true;

        if (ConvertInterfaceAliasToLuid(g_ifarg, &g_luid) == NO_ERROR) {
                g_luid_valid = true;
                return true;
        }
        /* Not an alias -- try a numeric interface index. */
        n = wcstoul(g_ifarg, &end, 10);
        if (end != g_ifarg && (end == NULL || *end == L'\0') && n != 0 &&
            ConvertInterfaceIndexToLuid((NET_IFINDEX)n, &g_luid) == NO_ERROR) {
                g_luid_valid = true;
                return true;
        }
        return false;
}

static bool
iface_present(void)
{
        NET_IFINDEX idx;
        return ConvertInterfaceLuidToIndex(&g_luid, &idx) == NO_ERROR;
}

/*
 * The managed interface's own MAC -- the per-network key for the router-MAC
 * cache (Windows can assign a random hardware address per network, so it is a
 * per-network fingerprint, as on macOS).
 */
static bool
interface_mac(uint8_t mac[6])
{
        MIB_IF_ROW2 row;

        memset(&row, 0, sizeof(row));
        row.InterfaceLuid = g_luid;
        if (GetIfEntry2(&row) != NO_ERROR || row.PhysicalAddressLength != 6)
                return false;
        memcpy(mac, row.PhysicalAddress, 6);
        return true;
}

/*
 * Persistent map of resolved router MAC keyed to the interface own-MAC, stored
 * under HKLM\SOFTWARE\v4gwd\RouterCache (value name = own-MAC, data = router
 * MAC) -- the registry counterpart of the macOS daemon's /var/db map.  A hit
 * during a bring-up lets us re-assert a known MAC before the host resolves the
 * gateway by ARP; a miss (new/moved network) cedes to the ARP bootstrap.
 */
#define ROUTER_CACHE_KEY "SOFTWARE\\v4gwd\\RouterCache"

static bool
router_cache_lookup(const uint8_t host[6], uint8_t router[6])
{
        char name[18], val[32];
        DWORD sz = sizeof(val);
        unsigned int b[6];

        mac_str_reg(host, name);
        if (RegGetValueA(HKEY_LOCAL_MACHINE, ROUTER_CACHE_KEY, name,
            RRF_RT_REG_SZ, NULL, val, &sz) != ERROR_SUCCESS)
                return false;
        if (sscanf_s(val, "%x-%x-%x-%x-%x-%x",
            &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) != 6)
                return false;
        for (int i = 0; i < 6; i++)
                router[i] = (uint8_t)b[i];
        return true;
}

static void
router_cache_put(const uint8_t host[6], const uint8_t router[6])
{
        char name[18], val[18];
        uint8_t cur[6];

        if (router_cache_lookup(host, cur) && memcmp(cur, router, 6) == 0)
                return;                         /* unchanged */
        mac_str_reg(host, name);
        mac_str_reg(router, val);
        (void)RegSetKeyValueA(HKEY_LOCAL_MACHINE, ROUTER_CACHE_KEY, name,
            REG_SZ, val, (DWORD)(strlen(val) + 1));
}

/* ------------------------------------------------------------- discovery */

/*
 * Follow the IPv6 default route on our interface: scan the IPv6 forwarding
 * table for a ::/0 route on g_luid and return its next hop (the IPv6 default
 * router's link-local address).  Picks the lowest-metric candidate.
 */
static bool
find_default_router(IN6_ADDR *gw)
{
        PMIB_IPFORWARD_TABLE2 tbl = NULL;
        bool found = false;
        ULONG best = 0;

        if (GetIpForwardTable2(AF_INET6, &tbl) != NO_ERROR || tbl == NULL)
                return false;

        for (ULONG i = 0; i < tbl->NumEntries; i++) {
                const MIB_IPFORWARD_ROW2 *r = &tbl->Table[i];

                if (r->InterfaceLuid.Value != g_luid.Value)
                        continue;
                if (r->DestinationPrefix.PrefixLength != 0)
                        continue;               /* not ::/0 */
                if (r->DestinationPrefix.Prefix.si_family != AF_INET6 ||
                    r->NextHop.si_family != AF_INET6)
                        continue;

                if (!found || r->Metric < best) {
                        *gw = r->NextHop.Ipv6.sin6_addr;
                        best = r->Metric;
                        found = true;
                }
        }

        FreeMibTable(tbl);
        return found;
}

/*
 * Read a neighbour's link-layer address from the IPv6 ND cache (the same
 * table ndp/Get-NetNeighbor read).  Match on our interface and address; a
 * PhysicalAddressLength of 6 means it is resolved.
 */
static bool
router_lladdr(const IN6_ADDR *gw, uint8_t mac[6])
{
        PMIB_IPNET_TABLE2 tbl = NULL;
        bool found = false;

        if (GetIpNetTable2(AF_INET6, &tbl) != NO_ERROR || tbl == NULL)
                return false;

        for (ULONG i = 0; i < tbl->NumEntries; i++) {
                const MIB_IPNET_ROW2 *r = &tbl->Table[i];

                if (r->InterfaceLuid.Value != g_luid.Value)
                        continue;
                if (r->Address.si_family != AF_INET6)
                        continue;
                if (memcmp(&r->Address.Ipv6.sin6_addr, gw, sizeof(IN6_ADDR)) != 0)
                        continue;
                if (r->PhysicalAddressLength != 6)
                        continue;               /* not yet resolved */

                memcpy(mac, r->PhysicalAddress, 6);
                found = true;
                break;
        }

        FreeMibTable(tbl);
        return found;
}

/*
 * Is *our* permanent neighbor entry for 192.0.0.11 present with the expected
 * MAC?  An external flush -- a DHCP reconfigure, an interface flap, an
 * `arp -d`/Remove-NetNeighbor -- can drop it, after which Windows resolves the
 * gateway by ordinary ARP, leaving a *dynamic* entry with the same (correct)
 * MAC.  Accepting that would defeat the daemon (the whole point is that the
 * host never ARPs for 192.0.0.11), so a non-permanent entry counts as absent
 * and we re-assert the permanent one over it.
 */
static bool
neighbor_present(const uint8_t mac[6])
{
        PMIB_IPNET_TABLE2 tbl = NULL;
        bool found = false;

        if (GetIpNetTable2(AF_INET, &tbl) != NO_ERROR || tbl == NULL)
                return false;

        for (ULONG i = 0; i < tbl->NumEntries; i++) {
                const MIB_IPNET_ROW2 *r = &tbl->Table[i];

                if (r->InterfaceLuid.Value != g_luid.Value)
                        continue;
                if (r->Address.si_family != AF_INET)
                        continue;
                if (ntohl(r->Address.Ipv4.sin_addr.s_addr) != SENTINEL_HOST)
                        continue;

                found = (r->State == NlnsPermanent &&
                    r->PhysicalAddressLength == 6 &&
                    memcmp(r->PhysicalAddress, mac, 6) == 0);
                break;
        }

        FreeMibTable(tbl);
        return found;
}

static void
fill_sentinel_row(MIB_IPNET_ROW2 *row, const uint8_t mac[6])
{
        memset(row, 0, sizeof(*row));
        row->InterfaceLuid = g_luid;
        row->Address.si_family = AF_INET;
        row->Address.Ipv4.sin_family = AF_INET;
        row->Address.Ipv4.sin_addr.s_addr = htonl(SENTINEL_HOST);
        if (mac != NULL) {
                row->PhysicalAddressLength = 6;
                memcpy(row->PhysicalAddress, mac, 6);
                row->State = NlnsPermanent;
        }
}

static void
install(const uint8_t mac[6])
{
        MIB_IPNET_ROW2 row;
        char macstr[18];
        DWORD e;

        /*
         * Re-assert if the kernel entry is gone even when our flag still says
         * installed: an external flush must not leave 192.0.0.11 resolved by
         * ARP (a dynamic entry) until the router's MAC happens to change.
         */
        if (g_installed && memcmp(g_installed_mac, mac, 6) == 0 &&
            neighbor_present(mac))
                return;

        /* Replace whatever is there (dynamic or a stale permanent) atomically
         * enough: delete any existing entry, then create ours permanent. */
        fill_sentinel_row(&row, mac);
        (void)DeleteIpNetEntry2(&row);          /* ignore ERROR_NOT_FOUND */

        fill_sentinel_row(&row, mac);
        e = CreateIpNetEntry2(&row);
        if (e == ERROR_OBJECT_ALREADY_EXISTS) {
                fill_sentinel_row(&row, mac);
                e = SetIpNetEntry2(&row);
        }
        if (e != NO_ERROR) {
                mac_str(mac, macstr);
                logmsg("CreateIpNetEntry2 %s -> %s failed: %lu",
                    SENTINEL_STR, macstr, (unsigned long)e);
                return;
        }

        mac_str(mac, macstr);
        logmsg("IPv4 gateway %s -> %s (ND-resolved IPv6 default router)",
            SENTINEL_STR, macstr);
        g_installed = true;
        memcpy(g_installed_mac, mac, 6);
}

static void
withdraw(const char *reason)
{
        MIB_IPNET_ROW2 row;

        if (!g_installed)
                return;

        fill_sentinel_row(&row, NULL);
        (void)DeleteIpNetEntry2(&row);
        logmsg("withdrew permanent neighbor for %s (%s)", SENTINEL_STR, reason);
        g_installed = false;
}

/*
 * Sentinel gate (-r): an IPv4 default route via 192.0.0.11 is present in the
 * FIB on our interface.  With -r absent the interface is managed
 * unconditionally (lab mode).
 */
static bool
sentinel_in_fib(void)
{
        PMIB_IPFORWARD_TABLE2 tbl = NULL;
        bool found = false;

        if (GetIpForwardTable2(AF_INET, &tbl) != NO_ERROR || tbl == NULL)
                return false;

        for (ULONG i = 0; i < tbl->NumEntries; i++) {
                const MIB_IPFORWARD_ROW2 *r = &tbl->Table[i];

                if (r->InterfaceLuid.Value != g_luid.Value)
                        continue;
                if (r->DestinationPrefix.PrefixLength != 0)
                        continue;               /* not 0.0.0.0/0 */
                if (r->NextHop.si_family != AF_INET)
                        continue;
                if (ntohl(r->NextHop.Ipv4.sin_addr.s_addr) == SENTINEL_HOST) {
                        found = true;
                        break;
                }
        }

        FreeMibTable(tbl);
        return found;
}

/* ------------------------------------------------------------- reconcile */

static void
reconcile(void)
{
        IN6_ADDR gw;
        uint8_t mac[6], host_mac[6], cached[6];
        bool have_host_mac;

        if (!resolve_luid()) {
                g_installed = false;            /* interface not resolvable yet */
                return;
        }
        if (!iface_present()) {
                g_installed = false;            /* interface gone */
                return;
        }

        if (g_require_sentinel_route && !sentinel_in_fib()) {
                withdraw("sentinel 192.0.0.11 route removed; ceasing per draft s4");
                return;
        }

        have_host_mac = interface_mac(host_mac);

        if (find_default_router(&gw) && router_lladdr(&gw, mac)) {
                /* Router resolved via ND: pin it, and record it keyed to the
                 * interface own-MAC (persisted for the next bring-up). */
                install(mac);
                if (have_host_mac)
                        router_cache_put(host_mac, mac);
                return;
        }

        /*
         * Router not ND-resolved yet (the bring-up window).  If we have a
         * stored MAC for this network, re-assert it now, ahead of the host
         * resolving the gateway by ARP; a miss cedes to the ARP bootstrap.
         */
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
        IN6_ADDR gw;
        uint8_t mac[6];
        char a[INET6_ADDRSTRLEN], macstr[18];

        if (!resolve_luid()) {
                fprintf(stderr, "v4gwd: %ls: no such interface\n", g_ifarg);
                return 1;
        }
        printf("v4gwd dry run on %ls (LUID %llu)\n", g_ifarg,
            (unsigned long long)g_luid.Value);

        if (g_require_sentinel_route)
                printf("  sentinel %s in IPv4 FIB : %s\n", SENTINEL_STR,
                    sentinel_in_fib() ? "yes" : "no (would not manage)");

        if (!find_default_router(&gw)) {
                printf("  IPv6 default router      : none on %ls "
                    "(would remove any entry)\n", g_ifarg);
                return 0;
        }
        InetNtopA(AF_INET6, &gw, a, sizeof(a));
        printf("  IPv6 default router      : %s%%%ls\n", a, g_ifarg);

        if (!router_lladdr(&gw, mac)) {
                printf("  router link-layer        : unresolved in ND cache "
                    "(would wait)\n");
                return 0;
        }
        mac_str(mac, macstr);
        printf("  router link-layer        : %s (from ND cache)\n", macstr);
        printf("  would pin (permanent)    : %s -> %s\n", SENTINEL_STR, macstr);
        return 0;
}

/* ------------------------------------------------------ change callbacks */

static VOID WINAPI
cb_route(PVOID ctx, PMIB_IPFORWARD_ROW2 row, MIB_NOTIFICATION_TYPE type)
{
        (void)ctx; (void)row; (void)type;
        SetEvent(g_wake_event);
}

static VOID WINAPI
cb_addr(PVOID ctx, PMIB_UNICASTIPADDRESS_ROW row, MIB_NOTIFICATION_TYPE type)
{
        (void)ctx; (void)row; (void)type;
        SetEvent(g_wake_event);
}

static VOID WINAPI
cb_iface(PVOID ctx, PMIB_IPINTERFACE_ROW row, MIB_NOTIFICATION_TYPE type)
{
        (void)ctx; (void)row; (void)type;
        SetEvent(g_wake_event);
}

/* ---------------------------------------------------------- worker loop */

static void
run_worker(void)
{
        HANDLE waits[2];

        /*
         * Register for change notifications first (InitialNotification=FALSE:
         * we do the initial reconcile ourselves below).  The callbacks are
         * thin -- they only signal the worker -- so they never touch IP Helper
         * state from a callback thread or risk the CancelMibChangeNotify2
         * deadlock.  A route/address/interface change (a new RA, a DHCP bind,
         * a link flap, the default router moving) wakes us; a periodic timer
         * covers a MAC change on the existing router that emits no route event.
         */
        NotifyRouteChange2(AF_UNSPEC, cb_route, NULL, FALSE, &g_h_route);
        NotifyUnicastIpAddressChange(AF_INET, cb_addr, NULL, FALSE, &g_h_addr);
        NotifyIpInterfaceChange(AF_UNSPEC, cb_iface, NULL, FALSE, &g_h_iface);

        reconcile();

        waits[0] = g_stop_event;
        waits[1] = g_wake_event;

        for (;;) {
                DWORD w = WaitForMultipleObjects(2, waits, FALSE,
                    (DWORD)g_interval * 1000);

                if (w == WAIT_OBJECT_0)
                        break;                  /* stop */

                /* Coalesce a burst of notifications into one reconcile. */
                if (w == WAIT_OBJECT_0 + 1)
                        Sleep(150);
                reconcile();
        }

        if (g_h_route) CancelMibChangeNotify2(g_h_route);
        if (g_h_addr)  CancelMibChangeNotify2(g_h_addr);
        if (g_h_iface) CancelMibChangeNotify2(g_h_iface);

        withdraw("daemon shutdown");
}

/* -------------------------------------------------------- service glue */

static void
report(DWORD state, DWORD wait_hint)
{
        static DWORD checkpoint = 1;

        g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
        g_status.dwCurrentState = state;
        g_status.dwControlsAccepted = (state == SERVICE_START_PENDING) ? 0 :
            (SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN);
        g_status.dwWin32ExitCode = NO_ERROR;
        g_status.dwWaitHint = wait_hint;
        if (state == SERVICE_RUNNING || state == SERVICE_STOPPED)
                g_status.dwCheckPoint = 0;
        else
                g_status.dwCheckPoint = checkpoint++;
        SetServiceStatus(g_ssh, &g_status);
}

static DWORD WINAPI
ctrl_handler(DWORD ctrl, DWORD evtype, LPVOID evdata, LPVOID ctx)
{
        (void)evtype; (void)evdata; (void)ctx;
        switch (ctrl) {
        case SERVICE_CONTROL_STOP:
        case SERVICE_CONTROL_SHUTDOWN:
                report(SERVICE_STOP_PENDING, 3000);
                SetEvent(g_stop_event);
                return NO_ERROR;
        case SERVICE_CONTROL_INTERROGATE:
                return NO_ERROR;
        default:
                return ERROR_CALL_NOT_IMPLEMENTED;
        }
}

static VOID WINAPI
service_main(DWORD argc, LPWSTR *argv)
{
        (void)argc; (void)argv;

        g_ssh = RegisterServiceCtrlHandlerExW(SVCNAMEW, ctrl_handler, NULL);
        if (g_ssh == NULL)
                return;

        report(SERVICE_START_PENDING, 3000);
        logmsg("service starting, managing interface %ls", g_ifarg);
        report(SERVICE_RUNNING, 0);

        run_worker();

        report(SERVICE_STOPPED, 0);
}

/* Console Ctrl-C / close -> clean shutdown, same path as the service stop. */
static BOOL WINAPI
console_ctrl(DWORD type)
{
        (void)type;
        SetEvent(g_stop_event);
        return TRUE;
}

/* ---------------------------------------------------------------- main */

static void
usage(void)
{
        fprintf(stderr,
            "usage: v4gwd [-n] [-c] [-r] [-i interval] <interface>\n"
            "  <interface>  adapter alias (\"Ethernet\") or numeric index\n"
            "  -n  dry run (report discovery, no changes, no privilege)\n"
            "  -c  run in the foreground instead of as a service\n"
            "  -r  manage only while an IPv4 default route via 192.0.0.11 exists\n"
            "  -i  periodic reconcile seconds (default 15)\n");
        exit(1);
}

int
main(int argc, char **argv)
{
        bool dry_run = false;
        const char *ifarg = NULL;
        WSADATA wsa;

        for (int i = 1; i < argc; i++) {
                if (strcmp(argv[i], "-n") == 0) {
                        dry_run = true;
                } else if (strcmp(argv[i], "-c") == 0) {
                        g_console = true;
                } else if (strcmp(argv[i], "-r") == 0) {
                        g_require_sentinel_route = true;
                } else if (strcmp(argv[i], "-i") == 0) {
                        if (++i >= argc)
                                usage();
                        g_interval = atoi(argv[i]);
                        if (g_interval < 1)
                                usage();
                } else if (argv[i][0] == '-') {
                        usage();
                } else if (ifarg == NULL) {
                        ifarg = argv[i];
                } else {
                        usage();
                }
        }
        if (ifarg == NULL)
                usage();

        MultiByteToWideChar(CP_UTF8, 0, ifarg, -1, g_ifarg,
            (int)(sizeof(g_ifarg) / sizeof(g_ifarg[0])));

        (void)WSAStartup(MAKEWORD(2, 2), &wsa);

        if (dry_run) {
                g_console = true;
                return dry_run_report();
        }

        g_stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);   /* manual */
        g_wake_event = CreateEventW(NULL, FALSE, FALSE, NULL);  /* auto   */
        if (g_stop_event == NULL || g_wake_event == NULL) {
                fprintf(stderr, "v4gwd: CreateEvent failed: %lu\n",
                    (unsigned long)GetLastError());
                return 1;
        }

        if (g_console) {
                SetConsoleCtrlHandler(console_ctrl, TRUE);
                logmsg("running in foreground, managing interface %ls "
                    "(Ctrl-C to stop)", g_ifarg);
                run_worker();
                return 0;
        }

        (void)CreateDirectoryA(LOGDIR, NULL);
        SERVICE_TABLE_ENTRYW dispatch[] = {
                { (LPWSTR)SVCNAMEW, service_main },
                { NULL, NULL }
        };
        if (!StartServiceCtrlDispatcherW(dispatch)) {
                if (GetLastError() == ERROR_FAILED_SERVICE_CONTROLLER_CONNECT) {
                        /* Started from a console without -c: run foreground. */
                        g_console = true;
                        SetConsoleCtrlHandler(console_ctrl, TRUE);
                        logmsg("not started by the SCM; running in foreground");
                        run_worker();
                } else {
                        fprintf(stderr,
                            "v4gwd: StartServiceCtrlDispatcher failed: %lu\n",
                            (unsigned long)GetLastError());
                        return 1;
                }
        }
        return 0;
}
