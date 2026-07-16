# Windows host implementation

`v4gwd.ps1` implements the draft's Section 4 host behaviour on Windows as a
single-file PowerShell daemon that uses only the in-box `NetTCPIP` cmdlets —
**no compiler, no dependencies**, so it runs on a stock desktop as-is.

Like macOS/XNU and unlike Linux (`RTA_VIA`, kernel ≥ 5.2) and FreeBSD
(RFC 5549, 2021), the Windows TCP/IP stack has **no support for IPv4 routes
with an IPv6 next hop** — an `MIB_IPFORWARD_ROW2` next hop is a family-matched
`SOCKADDR_INET`, so an IPv4 route cannot carry an IPv6 gateway. This daemon
reaches the identical on-wire behaviour with no kernel change, the same
realization as the macOS daemon.

## Unmodified Windows already works

A stock Windows host on a sentinel segment needs **no software at all** — it
is a conforming unmodified host per the draft's Section 5.3. Verified on
Windows 11 (ARM64): with a `/32` DHCP lease whose Router option (3) is
`192.0.0.11` and no option 121/249, Windows installs `0.0.0.0/0 → 192.0.0.11`,
resolves the gateway by **ARP**, the RFC 5549 router answers with its own MAC,
and IPv4 (including the real internet) works over the `/32`. DNS arrives via
RA RDNSS (RFC 8106, on by default since Windows 10 1703). No option 121 or its
Microsoft twin option 249 must ever be sent: Windows requests both, and if
either is present it ignores the Router option per RFC 3442.

## What the daemon adds

The unmodified path depends on the gateway **answering ARP** for 192.0.0.11,
and the host's binding to that MAC is just a dynamic ARP entry — `arp -d` it
and the host ARPs again. The daemon delivers the Section 4 behaviour instead:
it keeps 192.0.0.11's link-layer address **slaved to the live IPv6 default
router**, so the host resolves the gateway from the IPv6 neighbor cache and
**never ARPs** — which is what lets an operator eventually stop answering ARP
for 192.0.0.11 at the gateway.

It:

1. **follows the IPv6 default route** on the managed interface to find the
   default router (`Get-NetRoute ::/0` → `NextHop`);
2. **reads that router's MAC from the IPv6 ND cache** (`Get-NetNeighbor`) —
   never ARP;
3. **pins a permanent IPv4 neighbor** `192.0.0.11 → <router MAC>`
   (`New-NetNeighbor -State Permanent`), so the stock `default via 192.0.0.11`
   route resolves to the router's MAC and IPv4 frames leave addressed to it —
   byte-for-byte what the RFC 5549 realization puts on the wire, and a
   permanent entry emits no ARP;
4. **keeps the entry slaved to the IPv6 default router** as it or its MAC
   changes, re-asserts it if anything external drops or replaces it (a DHCP
   reconfigure, an interface flap, an `arp -d`/`Remove-NetNeighbor` — after
   which Windows would otherwise resolve 192.0.0.11 by ARP again), and removes
   it when no usable router remains.

A one-shot `New-NetNeighbor -State Permanent` is **not** a substitute: it is
static, so the moment the IPv6 default router fails over or changes MAC it
points at a dead address and the host blackholes. Tracking the live router is
the daemon's whole job — the reconcile loop. Reconciliation is a periodic poll
(idempotent); `-IntervalSeconds` bounds how fast the gateway MAC is followed
after the IPv6 router changes.

Across a bring-up the IPv6 router may not be ND-resolved when the host first
resolves the gateway. To bridge that window the daemon remembers each resolved
router MAC keyed to the interface's own MAC (a per-network fingerprint, since
Windows can use a random hardware address per network) and re-asserts it at
startup before the host falls back to ARP. The map lives in the registry under
`HKLM\SOFTWARE\v4gwd\RouterCache` (value name = the interface own-MAC, data =
the router MAC) — the counterpart of the macOS daemon's `/var/db` map — so it
survives a reboot and can be inspected or pruned with `reg query` /
`Remove-ItemProperty`.

## Run

No build step. From an elevated PowerShell (the neighbor calls need
Administrator):

    # dry run: report discovery, make no changes (no admin needed)
    powershell -ExecutionPolicy Bypass -File v4gwd.ps1 -Interface Ethernet -DryRun

    # run in the foreground; Ctrl-C withdraws and exits
    powershell -ExecutionPolicy Bypass -File v4gwd.ps1 -Interface Ethernet

`-Interface` is an adapter alias (`Ethernet`) or a numeric interface index.
`-RequireSentinelRoute` gates management on an IPv4 default route via
192.0.0.11 being present (sentinel mode); the default is unconditional (lab
mode). `-IntervalSeconds` sets the reconcile interval (default 15).

Dry run prints what it would program:

    > .\v4gwd.ps1 -Interface Ethernet -DryRun
    v4gwd dry run on Ethernet (ifIndex 13)
      IPv6 default router      : fe80::60cc:acff:feaa:7c74%13
      router link-layer        : 62-CC-AC-AA-7C-74 (from ND cache)
      would pin (permanent)    : 192.0.0.11 -> 62-CC-AC-AA-7C-74

## Install as a boot-time task

PowerShell has no native service protocol, so run it as a scheduled task that
starts at boot as `SYSTEM` and restarts on failure. From an elevated prompt
(adjust the path and interface):

    $act = New-ScheduledTaskAction -Execute 'powershell.exe' `
      -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\v4gwd\v4gwd.ps1 -Interface Ethernet'
    $trg = New-ScheduledTaskTrigger -AtStartup
    $pr  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
      -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName v4gwd -Action $act -Trigger $trg -Principal $pr -Settings $set -Force

    Start-ScheduledTask -TaskName v4gwd          # start now, without a reboot
    # logs: C:\ProgramData\v4gwd\v4gwd.log
    # remove: Unregister-ScheduledTask -TaskName v4gwd -Confirm:$false

## Validate

1. **Pins from the ND cache, no ARP.** With the daemon running,
   `Get-NetNeighbor -IPAddress 192.0.0.11` shows the router's MAC in state
   `Permanent`, and a capture at the router shows **zero** who-has 192.0.0.11
   during traffic.
2. **Follows the IPv6 gateway** (the core test). Change the IPv6 default router
   — fail over to a second RA router, or change the current router's MAC — and
   within one reconcile the pinned neighbor updates to the new MAC (log line
   `IPv4 gateway 192.0.0.11 -> <new MAC>`), with no ARP emitted. A one-shot
   static entry would blackhole here; the daemon does not.
3. **Re-asserts over an external flush.** `arp -d 192.0.0.11` (or
   `Remove-NetNeighbor`) drops the entry and Windows starts ARPing again; the
   daemon re-pins the permanent entry within the reconcile interval.
4. **Enables an ARP-silent gateway.** With the daemon maintaining the entry,
   silence the gateway's ARP responder for 192.0.0.11 — the host keeps full
   connectivity and emits no ARP, because it resolves the gateway from the
   neighbor cache rather than the wire.

## Optional: native service variant

`v4gwd.c` is the same daemon as a native C Windows service on the IP Helper API
(`CreateIpNetEntry2` + event-driven `NotifyRouteChange2` /
`NotifyUnicastIpAddressChange`), for sites that would rather run a real service
than a scheduled PowerShell task and have a toolchain to build it — see
`build.bat`. The PowerShell daemon is the recommended path; they are
functionally equivalent.

## Status

Validated end-to-end on Windows 11 (ARM64) against the live Debian RFC 5549
router (`../../router/debian/`):

- stock **unmodified** Windows works on the sentinel segment (Section 5.3) —
  off-subnet `/32` gateway accepted, DNS via RA RDNSS, no 121/249;
- with the daemon, `192.0.0.11` is pinned to the ND-resolved IPv6 default
  router's MAC (permanent, **zero ARP**), cached per-network under HKLM,
  re-asserted the instant an external `arp -d` flushes it (pre-empting the ARP
  fallback — the entry goes straight back to `Permanent`), and **re-slaved to a
  new router** when the IPv6 default router changes;
- runs at boot via the SYSTEM scheduled task, pinning within ~3 s and
  withdrawing cleanly on shutdown.

Note: failover is only as fast as the host's own IPv6 default-router selection.
The daemon chases the `::/0` next hop promptly, but Windows clings to a departed
router until a Router-Lifetime-0 "goodbye" RA — a silent `ifdown` on the old
router is ignored until its lifetime expires (or the route is removed by hand).
That stickiness is Windows ND behaviour, inherited by any v4-via-v6 gateway,
not a property of the daemon.
