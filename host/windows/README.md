# Windows host implementation

`v4gwd.ps1` implements the draft's Section 4 host behaviour on Windows as a
single-file PowerShell daemon built on the in-box `NetTCPIP` cmdlets. Windows
uses the static-neighbor realization (as on macOS): it pins 192.0.0.11's
link-layer address to the IPv6 default router's MAC, read from the neighbor
cache.

## Unmodified Windows (Section 5.3)

A stock Windows host on a sentinel segment works with no software. Verified on
Windows 11 (ARM64): with a `/32` DHCP lease whose Router option (3) is
`192.0.0.11`, Windows installs `0.0.0.0/0 → 192.0.0.11`, resolves the gateway
by ARP, the RFC 5549 router answers with its own MAC, and IPv4 (including the
real internet) works over the `/32`. DNS arrives via RA RDNSS (RFC 8106, on by
default since Windows 10 1703).

Never send DHCP option 121 or its Microsoft twin option 249: Windows requests
both and, per RFC 3442, honours them over the Router option — which defeats the
mechanism.

## What the daemon adds

The unmodified path binds 192.0.0.11 to the router MAC as a dynamic ARP entry.
The daemon holds that binding as a permanent entry slaved to the live IPv6
default router, so the host resolves the gateway from the neighbor cache and
never ARPs — which lets an operator stop answering ARP for 192.0.0.11 at the
gateway. It:

1. **follows the IPv6 default route** to find the router
   (`Get-NetRoute ::/0` → `NextHop`);
2. **reads that router's MAC** from the ND cache (`Get-NetNeighbor`);
3. **pins a permanent IPv4 neighbor** `192.0.0.11 → <router MAC>`
   (`New-NetNeighbor -State Permanent`), so the stock `default via 192.0.0.11`
   route resolves to it and IPv4 frames leave addressed to the router with no
   ARP;
4. **tracks the IPv6 default router** as it or its MAC changes, and re-asserts
   the entry after a DHCP reconfigure, an interface flap, or an `arp -d`.
   Reconciliation is a periodic poll; `-IntervalSeconds` sets the interval
   (default 15).

At bring-up the router may not be ND-resolved when the host first resolves the
gateway. The daemon remembers each resolved router MAC keyed to the interface's
own MAC (a per-network fingerprint, since Windows can use a random hardware
address per network) and re-asserts it at startup. The map lives in the
registry under `HKLM\SOFTWARE\v4gwd\RouterCache` (value name = the interface
own-MAC, data = the router MAC), inspectable with `reg query` /
`Remove-ItemProperty`.

## Run

From an elevated PowerShell (the neighbor calls need Administrator):

    # dry run: report discovery, make no changes (no admin needed)
    powershell -ExecutionPolicy Bypass -File v4gwd.ps1 -Interface Ethernet -DryRun

    # run in the foreground; Ctrl-C withdraws and exits
    powershell -ExecutionPolicy Bypass -File v4gwd.ps1 -Interface Ethernet

`-Interface` is an adapter alias (`Ethernet`) or a numeric interface index.
`-RequireSentinelRoute` gates management on an IPv4 default route via
192.0.0.11 (sentinel mode); the default is unconditional (lab mode).
`-IntervalSeconds` sets the reconcile interval (default 15).

Dry run prints what it would program:

    > .\v4gwd.ps1 -Interface Ethernet -DryRun
    v4gwd dry run on Ethernet (ifIndex 13)
      IPv6 default router      : fe80::60cc:acff:feaa:7c74%13
      router link-layer        : 62-CC-AC-AA-7C-74 (from ND cache)
      would pin (permanent)    : 192.0.0.11 -> 62-CC-AC-AA-7C-74

## Install as a boot-time task

Run it as a scheduled task that starts at boot as `SYSTEM` and restarts on
failure. From an elevated prompt (adjust the path and interface):

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
   `Permanent`, and a capture at the router shows zero who-has 192.0.0.11
   during traffic.
2. **Follows the IPv6 gateway.** Change the IPv6 default router (fail over to a
   second RA router, or change the current router's MAC); within one reconcile
   the pinned neighbor updates to the new MAC (log line
   `IPv4 gateway 192.0.0.11 -> <new MAC>`).
3. **Re-asserts over a flush.** `arp -d 192.0.0.11` (or `Remove-NetNeighbor`)
   drops the entry; the daemon re-pins it within the reconcile interval.
4. **Enables an ARP-silent gateway.** With the daemon maintaining the entry,
   silence the gateway's ARP responder for 192.0.0.11 — the host keeps full
   connectivity and emits no ARP.

## Native service variant

`v4gwd.c` is the same daemon as a native C Windows service on the IP Helper API
(`CreateIpNetEntry2`, `NotifyRouteChange2` / `NotifyUnicastIpAddressChange`);
build with `build.bat`. The PowerShell daemon is the recommended path.

## Status

Validated end-to-end on Windows 11 (ARM64) against the live Debian RFC 5549
router (`../../router/debian/`):

- unmodified Windows works on the sentinel segment (Section 5.3): off-subnet
  `/32` gateway accepted, DNS via RA RDNSS;
- with the daemon, `192.0.0.11` is pinned to the ND-resolved IPv6 default
  router's MAC (permanent, zero ARP), cached per-network under HKLM,
  re-asserted after an external `arp -d`, and re-slaved when the IPv6 default
  router changes;
- runs at boot via the SYSTEM scheduled task, pinning within ~3 s.

Failover tracks the host's IPv6 default-router selection: Windows keeps a
departed router until it sends a Router-Lifetime-0 RA or its advertised
lifetime expires, so prompt failover depends on that goodbye RA.
