<#
    SPDX-License-Identifier: BSD-2-Clause

    v4gwd.ps1 - IPv6-Resolved IPv4 Gateway daemon, Windows variant.

    Host-side implementation of draft-vanmook-intarea-ipv6-resolved-gateway
    (Section 4) for Windows, which -- like macOS and unlike Linux (RTA_VIA)
    and FreeBSD (RFC 5549) -- has no kernel support for IPv4 routes with an
    IPv6 next hop. It reaches the identical on-wire behaviour with no kernel
    change, the same realization as the macOS daemon, using only the in-box
    NetTCPIP cmdlets so it runs on a stock desktop with no toolchain:

      The special-purpose IPv4 gateway 192.0.0.11 has no host of its own; its
      link-layer address is simply that of the IPv6 default router -- one
      interface, one MAC. So instead of resolving 192.0.0.11 by ARP, this
      daemon:

        1. follows the IPv6 default route on the managed interface to find the
           default router          (Get-NetRoute ::/0 -> NextHop);
        2. reads that router's MAC from the IPv6 Neighbor Discovery cache
           (Get-NetNeighbor)       -- never ARP;
        3. pins a permanent IPv4 neighbor  192.0.0.11 -> <router MAC>
           (New-NetNeighbor -State Permanent), so the stock "default via
           192.0.0.11" route resolves to the router's MAC and IPv4 frames
           leave addressed to it, exactly as the RFC 5549 realization would;
        4. keeps the entry slaved to the IPv6 default router as it or its MAC
           changes, re-asserts it if anything external drops or replaces it
           (a DHCP reconfigure, an interface flap, an arp -d / Remove-NetNeighbor
           -- after which Windows resolves 192.0.0.11 by ARP again), and
           removes it when no usable router remains.

    A permanent neighbor emits no ARP and is immune to NUD; the link-layer
    address is taken from the IPv6 ND cache, satisfying Section 4. This is a
    different realization of the same result, for a stack that cannot express
    an IPv4 route with an IPv6 next hop.

    A one-shot "New-NetNeighbor -State Permanent" is NOT a substitute: it is
    static, so the moment the IPv6 default router fails over or changes MAC it
    points at a dead address and the host blackholes. Tracking the live router
    is the daemon's whole job -- that is the reconcile loop below.

    Across a bring-up the IPv6 router may not be ND-resolved yet when the host
    first resolves the gateway. To bridge that window the daemon remembers each
    resolved router MAC keyed to the interface's own MAC -- a per-network
    fingerprint, since Windows can use a random hardware address per network --
    and re-asserts from that map at startup, before the host falls back to ARP.
    A miss (a new or moved network) cedes to the host's normal ARP bootstrap
    rather than steer traffic at a stale MAC. The map is persisted in the
    registry under HKLM\SOFTWARE\v4gwd\RouterCache (value name = the interface
    own-MAC, data = the router MAC) -- the macOS daemon's /var/db map -- so it
    survives a restart or reboot and can be inspected or pruned with reg query /
    Remove-ItemProperty.

    Reconciliation is a periodic poll (idempotent); the interval bounds how
    quickly the gateway MAC is followed after the IPv6 router changes.

    Usage:
      # dry run: report discovery, make no changes (no admin needed)
      powershell -ExecutionPolicy Bypass -File v4gwd.ps1 -Interface Ethernet -DryRun

      # run in the foreground (elevated); Ctrl-C withdraws and exits
      powershell -ExecutionPolicy Bypass -File v4gwd.ps1 -Interface Ethernet

    Install as a boot-time task (SYSTEM) -- see README.md.
#>

[CmdletBinding()]
param(
    # Adapter alias ("Ethernet") or numeric interface index.
    [Parameter(Mandatory = $true)]
    [string] $Interface,

    # Periodic reconcile interval, seconds. Bounds how fast we follow the gw.
    [uint32] $IntervalSeconds = 15,

    # Manage only while an IPv4 default route via 192.0.0.11 is present (-r).
    [switch] $RequireSentinelRoute,

    # Report discovery and exit; make no changes, need no privilege.
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Sentinel = '192.0.0.11'
$LogDir   = Join-Path $env:ProgramData 'v4gwd'
$LogPath  = Join-Path $LogDir 'v4gwd.log'
$RegBase  = 'HKLM:\SOFTWARE\v4gwd\RouterCache'

function Write-Log {
    param([string] $Message)
    $line = ('{0:yyyy-MM-dd HH:mm:ss} v4gwd: {1}' -f (Get-Date), $Message)
    Write-Host $line
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        Add-Content -Path $LogPath -Value $line
    } catch { }
}

# Resolve the interface argument (alias or numeric index) to an ifIndex.
# Re-resolved every reconcile: an ifIndex can change across a disable/enable,
# and at boot the adapter may not exist yet -- a miss just defers a cycle.
function Get-ManagedIfIndex {
    if ($Interface -match '^\d+$') {
        $idx = [int] $Interface
        if (Get-NetAdapter -InterfaceIndex $idx -ErrorAction SilentlyContinue) { return $idx }
        return $null
    }
    $a = Get-NetAdapter -Name $Interface -ErrorAction SilentlyContinue
    if ($a) { return $a.ifIndex }
    return $null
}

# Follow the IPv6 default route on our interface -> the router's link-local
# next hop (lowest metric wins). $null if there is no usable default router.
function Get-DefaultRouterLinkLocal {
    param([int] $IfIndex)
    $r = Get-NetRoute -InterfaceIndex $IfIndex -AddressFamily IPv6 `
            -DestinationPrefix '::/0' -ErrorAction SilentlyContinue |
         Sort-Object RouteMetric | Select-Object -First 1
    if ($r) { return $r.NextHop }
    return $null
}

# Read the router's MAC from the IPv6 ND cache. Skip unresolved/incomplete
# entries (no or all-zero link-layer address).
function Get-RouterMac {
    param([int] $IfIndex, [string] $RouterLinkLocal)
    $n = Get-NetNeighbor -InterfaceIndex $IfIndex -AddressFamily IPv6 `
            -IPAddress $RouterLinkLocal -ErrorAction SilentlyContinue |
         Where-Object { $_.LinkLayerAddress -and
                        $_.LinkLayerAddress -ne '00-00-00-00-00-00' } |
         Select-Object -First 1
    if ($n) { return $n.LinkLayerAddress }
    return $null
}

# The managed interface's own MAC ("2E-A6-31-A8-D4-5D") -- the per-network key
# for the router-MAC cache (see the header note).
function Get-InterfaceMac {
    param([int] $IfIndex)
    $a = Get-NetAdapter -InterfaceIndex $IfIndex -ErrorAction SilentlyContinue
    if ($a -and $a.MacAddress) { return $a.MacAddress }
    return $null
}

# Look up the last resolved router MAC for this own-MAC (this network); $null
# if none. The registry is the map -- one value per network, HKLM so it
# persists across restart/reboot (the macOS /var/db map).
function Get-CachedRouterMac {
    param([string] $HostMac)
    try {
        return (Get-ItemProperty -Path $RegBase -Name $HostMac -ErrorAction Stop).$HostMac
    } catch { return $null }
}

# Store the own-MAC -> router-MAC mapping (idempotent).
function Set-CachedRouterMac {
    param([string] $HostMac, [string] $RouterMac)
    if ((Get-CachedRouterMac $HostMac) -eq $RouterMac) { return }
    if (-not (Test-Path $RegBase)) { New-Item -Path $RegBase -Force | Out-Null }
    New-ItemProperty -Path $RegBase -Name $HostMac -Value $RouterMac `
        -PropertyType String -Force | Out-Null
}

# Our permanent sentinel neighbor, if present (any interface).
function Get-SentinelNeighbor {
    Get-NetNeighbor -AddressFamily IPv4 -IPAddress $Sentinel `
        -ErrorAction SilentlyContinue | Where-Object State -eq 'Permanent' |
        Select-Object -First 1
}

# Is an IPv4 default route via 192.0.0.11 present on our interface? (-r gate)
function Test-SentinelRoute {
    param([int] $IfIndex)
    $d = Get-NetRoute -InterfaceIndex $IfIndex -AddressFamily IPv4 `
            -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
    return [bool] ($d | Where-Object NextHop -eq $Sentinel)
}

# Pin (or correct) the permanent neighbor 192.0.0.11 -> $Mac on $IfIndex.
# Idempotent: a no-op if the right permanent entry is already present; else it
# replaces whatever is there (a dynamic ARP-learned entry, or a stale MAC).
function Set-SentinelNeighbor {
    param([int] $IfIndex, [string] $Mac)
    $cur = Get-NetNeighbor -InterfaceIndex $IfIndex -AddressFamily IPv4 `
              -IPAddress $Sentinel -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($cur -and $cur.State -eq 'Permanent' -and $cur.LinkLayerAddress -eq $Mac) {
        return
    }
    if ($cur) {
        Remove-NetNeighbor -InterfaceIndex $IfIndex -IPAddress $Sentinel `
            -Confirm:$false -ErrorAction SilentlyContinue
    }
    New-NetNeighbor -InterfaceIndex $IfIndex -IPAddress $Sentinel `
        -LinkLayerAddress $Mac -State Permanent -PolicyStore ActiveStore |
        Out-Null
    Write-Log "IPv4 gateway $Sentinel -> $Mac (ND-resolved IPv6 default router)"
}

# Remove our permanent entry; the host reverts to ARP (Section 5.3).
function Remove-SentinelNeighbor {
    param([string] $Reason)
    $cur = Get-SentinelNeighbor
    if ($cur) {
        Remove-NetNeighbor -InterfaceIndex $cur.InterfaceIndex `
            -IPAddress $Sentinel -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "withdrew permanent neighbor for $Sentinel ($Reason)"
    }
}

# One idempotent pass: resolve interface, gate, follow the v6 router, pin.
function Invoke-Reconcile {
    $ifx = Get-ManagedIfIndex
    if (-not $ifx) { return }                    # interface not present yet

    if ($RequireSentinelRoute -and -not (Test-SentinelRoute -IfIndex $ifx)) {
        Remove-SentinelNeighbor 'sentinel 192.0.0.11 route removed; ceasing per draft s4'
        return
    }

    $hostMac = Get-InterfaceMac -IfIndex $ifx

    $ll = Get-DefaultRouterLinkLocal -IfIndex $ifx
    if ($ll) {
        $mac = Get-RouterMac -IfIndex $ifx -RouterLinkLocal $ll
        if ($mac) {
            # Router resolved via ND: pin it, and record it keyed to our own
            # MAC (persisted for the next bring-up).
            Set-SentinelNeighbor -IfIndex $ifx -Mac $mac
            if ($hostMac) { Set-CachedRouterMac -HostMac $hostMac -RouterMac $mac }
            return
        }
    }

    # Router not ND-resolved yet (the bring-up window). If we have a stored MAC
    # for this network, re-assert it now, ahead of the host resolving the
    # gateway by ARP; a miss cedes to the host's ARP bootstrap.
    if ($hostMac) {
        $cached = Get-CachedRouterMac -HostMac $hostMac
        if ($cached) { Set-SentinelNeighbor -IfIndex $ifx -Mac $cached; return }
    }
    Remove-SentinelNeighbor 'no IPv6 default router resolved yet; ceding to ARP bootstrap'
}

# -DryRun: report what would be programmed and exit.
function Invoke-DryRun {
    $ifx = Get-ManagedIfIndex
    if (-not $ifx) { Write-Host "v4gwd: ${Interface}: no such interface"; return 1 }
    Write-Host "v4gwd dry run on $Interface (ifIndex $ifx)"
    if ($RequireSentinelRoute) {
        $ok = Test-SentinelRoute -IfIndex $ifx
        Write-Host ("  sentinel {0} in IPv4 FIB : {1}" -f $Sentinel,
            $(if ($ok) { 'yes' } else { 'no (would not manage)' }))
    }
    $ll = Get-DefaultRouterLinkLocal -IfIndex $ifx
    if (-not $ll) {
        Write-Host "  IPv6 default router      : none (would remove any entry)"
        return 0
    }
    Write-Host "  IPv6 default router      : $ll%$ifx"
    $mac = Get-RouterMac -IfIndex $ifx -RouterLinkLocal $ll
    if (-not $mac) {
        Write-Host "  router link-layer        : unresolved in ND cache (would wait)"
        return 0
    }
    Write-Host "  router link-layer        : $mac (from ND cache)"
    Write-Host "  would pin (permanent)    : $Sentinel -> $mac"
    return 0
}

# ---------------------------------------------------------------- main

if ($DryRun) { exit (Invoke-DryRun) }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log 'not elevated; New-NetNeighbor/Remove-NetNeighbor need Administrator'
}

Write-Log "starting, managing interface $Interface (interval ${IntervalSeconds}s)"
try {
    Invoke-Reconcile
    while ($true) {
        Start-Sleep -Seconds $IntervalSeconds
        Invoke-Reconcile
    }
} finally {
    Remove-SentinelNeighbor 'daemon shutdown'
    Write-Log 'stopped'
}
