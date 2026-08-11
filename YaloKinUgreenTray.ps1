[CmdletBinding()]
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$privateName = 'YaloKin-Ugreen'
$vpnName = 'AmneziaVPN'
$hotspotAddress = '192.168.137.1'
$routePrefixes = @('192.168.137.0/25', '192.168.137.128/25')
$netsh = "$env:SystemRoot\System32\netsh.exe"
$logDirectory = Join-Path $env:ProgramData 'YaloKinUgreen'
$logPath = Join-Path $logDirectory 'hotspot.log'

function Get-StateLevel {
    param(
        [bool]$HotspotUp,
        [bool]$AddressReady,
        [bool]$DhcpReady,
        [bool]$RoutesReady,
        [bool]$VpnReady
    )

    if (-not $HotspotUp) { return 'Stopped' }
    if (-not ($AddressReady -and $DhcpReady -and $RoutesReady)) { return 'Degraded' }
    if (-not $VpnReady) { return 'NoVpn' }
    return 'Ready'
}

if ($SelfTest) {
    $cases = @(
        @($false, $false, $false, $false, $false, 'Stopped'),
        @($true,  $false, $false, $false, $false, 'Degraded'),
        @($true,  $true,  $true,  $true,  $false, 'NoVpn'),
        @($true,  $true,  $true,  $true,  $true,  'Ready')
    )

    foreach ($case in $cases) {
        $actual = Get-StateLevel $case[0] $case[1] $case[2] $case[3] $case[4]
        if ($actual -ne $case[5]) {
            throw "Self-test failed: expected $($case[5]), got $actual."
        }
    }

    Write-Output 'Self-test OK.'
    exit 0
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments
    exit 0
}

$createdNew = $false
$mutex = New-Object Threading.Mutex($true, 'Local\YaloKinUgreenTray', [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

function Write-Log {
    param([string]$Message)

    try {
        if (-not (Test-Path -LiteralPath $logDirectory)) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        if ((Test-Path -LiteralPath $logPath) -and
            (Get-Item -LiteralPath $logPath).Length -gt 1MB) {
            Move-Item -LiteralPath $logPath -Destination "$logPath.old" -Force
        }
        Add-Content -LiteralPath $logPath -Encoding UTF8 -Value (
            '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
        )
    }
    catch {
        # Logging must not break hotspot control.
    }
}

function Invoke-Netsh {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $previousPreference = $ErrorActionPreference
    $previousConsoleEncoding = [Console]::OutputEncoding
    try {
        $ErrorActionPreference = 'Continue'
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
        $output = @(& $netsh @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $previousConsoleEncoding
        $ErrorActionPreference = $previousPreference
    }

    $message = @($output | ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_ }) -join ' '
    Write-Log "netsh $($Arguments -join ' '): exit=$exitCode; $message"
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $message }
}

function Get-HotspotAdapter {
    $adapters = @(Get-NetAdapter -Name $privateName -IncludeHidden -ErrorAction SilentlyContinue)
    if ($adapters.Count -eq 0) { return $null }
    return $adapters[0]
}

function Test-VpnReady {
    $adapters = @(Get-NetAdapter -Name $vpnName -IncludeHidden -ErrorAction SilentlyContinue)
    if ($adapters.Count -eq 0 -or $adapters[0].Status -ne 'Up') { return $false }

    $vpnRoutes = @(Get-NetRoute `
        -AddressFamily IPv4 `
        -InterfaceIndex $adapters[0].InterfaceIndex `
        -PolicyStore ActiveStore `
        -ErrorAction SilentlyContinue |
        Where-Object DestinationPrefix -In '0.0.0.0/0', '0.0.0.0/1', '128.0.0.0/1')
    return ($vpnRoutes.Count -gt 0)
}

function Repair-HotspotRoutes {
    $adapter = Get-HotspotAdapter
    if ($null -eq $adapter -or $adapter.Status -ne 'Up') { return }

    $address = Get-NetIPAddress `
        -InterfaceIndex $adapter.InterfaceIndex `
        -AddressFamily IPv4 `
        -IPAddress $hotspotAddress `
        -ErrorAction SilentlyContinue
    if ($null -eq $address) { return }

    $ipInterface = Get-NetIPInterface `
        -InterfaceIndex $adapter.InterfaceIndex `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue
    if ($null -ne $ipInterface -and $ipInterface.InterfaceMetric -ne 1) {
        Set-NetIPInterface `
            -InterfaceIndex $adapter.InterfaceIndex `
            -AddressFamily IPv4 `
            -InterfaceMetric 1
        Write-Log "Set interface metric 1 on $privateName."
    }

    foreach ($prefix in $routePrefixes) {
        $routes = @(Get-NetRoute `
            -PolicyStore ActiveStore `
            -DestinationPrefix $prefix `
            -InterfaceIndex $adapter.InterfaceIndex `
            -ErrorAction SilentlyContinue |
            Where-Object NextHop -eq '0.0.0.0')

        if ($routes.Count -eq 0) {
            New-NetRoute `
                -DestinationPrefix $prefix `
                -InterfaceIndex $adapter.InterfaceIndex `
                -NextHop '0.0.0.0' `
                -RouteMetric 1 `
                -ErrorAction Stop | Out-Null
            Write-Log "Added route $prefix via $privateName."
            continue
        }

        foreach ($route in $routes) {
            if ($route.RouteMetric -ne 1) {
                $route | Set-NetRoute -RouteMetric 1 -Confirm:$false
                Write-Log "Set route metric 1 for $prefix."
            }
        }
    }
}

function Ensure-HotspotAddress {
    $adapter = Get-HotspotAdapter
    if ($null -eq $adapter -or $adapter.Status -ne 'Up') {
        throw "Adapter '$privateName' is not active."
    }

    $address = Get-NetIPAddress `
        -InterfaceIndex $adapter.InterfaceIndex `
        -AddressFamily IPv4 `
        -IPAddress $hotspotAddress `
        -ErrorAction SilentlyContinue
    if ($null -ne $address) { return }

    $result = Invoke-Netsh -Arguments @(
        'interface', 'ipv4', 'set', 'address',
        "name=$privateName", 'source=static', "address=$hotspotAddress",
        'mask=255.255.255.0', 'gateway=none', 'store=persistent'
    )
    if ($result.ExitCode -ne 0) {
        throw "Could not set $hotspotAddress on '$privateName'."
    }

    Start-Sleep -Seconds 2
    Write-Log "Assigned $hotspotAddress/24 to $privateName."
}

function Start-Hotspot {
    Start-Service WlanSvc -ErrorAction SilentlyContinue
    Start-Service SharedAccess -ErrorAction SilentlyContinue

    $ugreenAdapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object InterfaceDescription -Like '*Ugreen*')
    if ($ugreenAdapters.Count -eq 0) { throw 'Ugreen USB Wi-Fi adapter was not found.' }
    if ($ugreenAdapters[0].Status -eq 'Disabled') {
        $ugreenAdapters[0] | Enable-NetAdapter -Confirm:$false
        Start-Sleep -Seconds 3
        $ugreenAdapters = @(Get-NetAdapter `
            -InterfaceIndex $ugreenAdapters[0].InterfaceIndex `
            -IncludeHidden `
            -ErrorAction SilentlyContinue)
    }
    if ($ugreenAdapters.Count -eq 0 -or $ugreenAdapters[0].Status -eq 'Not Present') {
        throw 'Ugreen USB Wi-Fi adapter is not available.'
    }
    Write-Log "Ugreen adapter: $($ugreenAdapters[0].Name); status=$($ugreenAdapters[0].Status); ifIndex=$($ugreenAdapters[0].InterfaceIndex)."

    $allow = Invoke-Netsh -Arguments @('wlan', 'set', 'hostednetwork', 'mode=allow')
    if ($allow.ExitCode -ne 0) { throw 'Windows could not enable Hosted Network mode.' }

    $start = Invoke-Netsh -Arguments @('wlan', 'start', 'hostednetwork')
    if ($start.ExitCode -ne 0) {
        Write-Log 'Hosted Network start failed; resetting the dedicated Ugreen adapter once.'
        $ugreenAdapters[0] | Disable-NetAdapter -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 3
        $ugreenAdapters[0] | Enable-NetAdapter -Confirm:$false -ErrorAction Stop
        Start-Sleep -Seconds 8

        $allow = Invoke-Netsh -Arguments @('wlan', 'set', 'hostednetwork', 'mode=allow')
        if ($allow.ExitCode -ne 0) { throw 'Hosted Network mode failed after Ugreen reset.' }
        $start = Invoke-Netsh -Arguments @('wlan', 'start', 'hostednetwork')
        if ($start.ExitCode -ne 0) {
            throw "Windows could not start Hosted Network after Ugreen reset (exit $($start.ExitCode))."
        }
    }

    Start-Sleep -Seconds 3
    Ensure-HotspotAddress
    Repair-HotspotRoutes
    Write-Log 'Hotspot start/repair completed.'
}

function Stop-Hotspot {
    $stop = Invoke-Netsh -Arguments @('wlan', 'stop', 'hostednetwork')
    if ($stop.ExitCode -ne 0 -and (Get-HotspotAdapter).Status -eq 'Up') {
        throw "Windows could not stop Hosted Network (exit $($stop.ExitCode))."
    }
    Write-Log 'Hotspot stopped.'
}

function Restart-Hotspot {
    [void](Invoke-Netsh -Arguments @('wlan', 'stop', 'hostednetwork'))
    Start-Sleep -Seconds 3
    Start-Hotspot
    Write-Log 'Hotspot restarted.'
}

function Get-HotspotStatus {
    $adapter = Get-HotspotAdapter
    $hotspotUp = ($null -ne $adapter -and $adapter.Status -eq 'Up')
    $addressReady = $false
    $dhcpReady = $false
    $routesReady = $false

    if ($hotspotUp) {
        $addressReady = $null -ne (Get-NetIPAddress `
            -InterfaceIndex $adapter.InterfaceIndex `
            -AddressFamily IPv4 `
            -IPAddress $hotspotAddress `
            -ErrorAction SilentlyContinue)

        $dhcpPorts = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LocalPort -In 67, 68 -and
                $_.LocalAddress -In $hotspotAddress, '0.0.0.0'
            } |
            Select-Object -ExpandProperty LocalPort -Unique)
        $dhcpReady = ($dhcpPorts -contains 67 -and $dhcpPorts -contains 68)

        $ipInterface = Get-NetIPInterface `
            -InterfaceIndex $adapter.InterfaceIndex `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue
        $routesReady = ($null -ne $ipInterface -and $ipInterface.InterfaceMetric -eq 1)
        foreach ($prefix in $routePrefixes) {
            $route = Get-NetRoute `
                -PolicyStore ActiveStore `
                -DestinationPrefix $prefix `
                -InterfaceIndex $adapter.InterfaceIndex `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.NextHop -eq '0.0.0.0' -and $_.RouteMetric -eq 1 }
            if ($null -eq $route) { $routesReady = $false }
        }
    }

    $vpnReady = Test-VpnReady
    [pscustomobject]@{
        Level = Get-StateLevel $hotspotUp $addressReady $dhcpReady $routesReady $vpnReady
        HotspotUp = $hotspotUp
        AddressReady = $addressReady
        DhcpReady = $dhcpReady
        RoutesReady = $routesReady
        VpnReady = $vpnReady
    }
}

function Get-StatusText {
    param($Status)

    return @(
        "Hotspot: $($Status.HotspotUp)",
        "Address ${hotspotAddress}: $($Status.AddressReady)",
        "DHCP: $($Status.DhcpReady)",
        "Local /25 routes: $($Status.RoutesReady)",
        "AmneziaVPN route: $($Status.VpnReady)",
        "State: $($Status.Level)"
    ) -join [Environment]::NewLine
}

$script:notify = New-Object Windows.Forms.NotifyIcon
$script:menu = New-Object Windows.Forms.ContextMenuStrip
$script:statusItem = New-Object Windows.Forms.ToolStripMenuItem
$script:statusItem.Enabled = $false
$script:statusItem.Text = 'Status: starting'
[void]$script:menu.Items.Add($script:statusItem)
[void]$script:menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))

$startItem = New-Object Windows.Forms.ToolStripMenuItem
$startItem.Text = 'Start / repair hotspot'
[void]$script:menu.Items.Add($startItem)

$restartItem = New-Object Windows.Forms.ToolStripMenuItem
$restartItem.Text = 'Restart hotspot'
[void]$script:menu.Items.Add($restartItem)

$stopItem = New-Object Windows.Forms.ToolStripMenuItem
$stopItem.Text = 'Stop hotspot'
[void]$script:menu.Items.Add($stopItem)

[void]$script:menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$detailsItem = New-Object Windows.Forms.ToolStripMenuItem
$detailsItem.Text = 'Show details'
[void]$script:menu.Items.Add($detailsItem)

$logItem = New-Object Windows.Forms.ToolStripMenuItem
$logItem.Text = 'Open log'
[void]$script:menu.Items.Add($logItem)

[void]$script:menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$exitItem = New-Object Windows.Forms.ToolStripMenuItem
$exitItem.Text = 'Exit'
[void]$script:menu.Items.Add($exitItem)

$script:notify.ContextMenuStrip = $script:menu
$script:notify.Icon = [Drawing.SystemIcons]::Application
$script:notify.Text = 'YaloKin Ugreen: starting'
$script:notify.Visible = $true
$script:lastLevel = $null

function Update-TrayStatus {
    try {
        $status = Get-HotspotStatus
        switch ($status.Level) {
            'Ready' {
                $script:notify.Icon = [Drawing.SystemIcons]::Information
                $tip = 'YaloKin Ugreen: ready | Amnezia: connected'
            }
            'NoVpn' {
                $script:notify.Icon = [Drawing.SystemIcons]::Warning
                $tip = 'YaloKin Ugreen: ready | Amnezia: unavailable'
            }
            'Degraded' {
                $script:notify.Icon = [Drawing.SystemIcons]::Error
                $tip = 'YaloKin Ugreen: repair needed'
            }
            default {
                $script:notify.Icon = [Drawing.SystemIcons]::Application
                $tip = 'YaloKin Ugreen: stopped'
            }
        }

        $script:notify.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
        $script:statusItem.Text = "Status: $($status.Level)"

        if ($script:lastLevel -ne $status.Level) {
            $icon = if ($status.Level -eq 'Ready') {
                [Windows.Forms.ToolTipIcon]::Info
            } else {
                [Windows.Forms.ToolTipIcon]::Warning
            }
            $script:notify.ShowBalloonTip(4000, 'YaloKin Ugreen', $tip, $icon)
            Write-Log "State changed to $($status.Level)."
            $script:lastLevel = $status.Level
        }
    }
    catch {
        $script:notify.Icon = [Drawing.SystemIcons]::Error
        $script:notify.Text = 'YaloKin Ugreen: status error'
        $script:statusItem.Text = 'Status: error'
        Write-Log "Status error: $($_.Exception.Message)"
    }
}

function Invoke-TrayAction {
    param([string]$Name, [scriptblock]$Action)

    try {
        & $Action
        Write-Log "$Name succeeded."
    }
    catch {
        Write-Log "$Name failed: $($_.Exception.Message)"
        $script:notify.ShowBalloonTip(
            5000,
            'YaloKin Ugreen error',
            $_.Exception.Message,
            [Windows.Forms.ToolTipIcon]::Error
        )
    }
    Update-TrayStatus
}

$startItem.Add_Click({ Invoke-TrayAction 'Start/repair' { Start-Hotspot } })
$restartItem.Add_Click({ Invoke-TrayAction 'Restart' { Restart-Hotspot } })
$stopItem.Add_Click({ Invoke-TrayAction 'Stop' { Stop-Hotspot } })
$detailsItem.Add_Click({
    $status = Get-HotspotStatus
    [void][Windows.Forms.MessageBox]::Show(
        (Get-StatusText $status),
        'YaloKin Ugreen status',
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Information
    )
})
$script:notify.Add_DoubleClick({
    $status = Get-HotspotStatus
    [void][Windows.Forms.MessageBox]::Show(
        (Get-StatusText $status),
        'YaloKin Ugreen status'
    )
})
$logItem.Add_Click({
    Write-Log 'Log opened.'
    Start-Process notepad.exe -ArgumentList "`"$logPath`""
})
$exitItem.Add_Click({ [Windows.Forms.Application]::ExitThread() })

$script:timer = New-Object Windows.Forms.Timer
$script:timer.Interval = 10000
$script:timer.Add_Tick({
    try {
        $status = Get-HotspotStatus
        if ($status.HotspotUp -and $status.AddressReady) {
            Repair-HotspotRoutes
        }
    }
    catch {
        Write-Log "Periodic route repair failed: $($_.Exception.Message)"
    }
    Update-TrayStatus
})

Write-Log 'Tray application started.'
Invoke-TrayAction 'Automatic start' { Start-Hotspot }
$script:timer.Start()

try {
    [Windows.Forms.Application]::Run()
}
finally {
    $script:timer.Stop()
    $script:timer.Dispose()
    $script:notify.Visible = $false
    $script:notify.Dispose()
    $script:menu.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    Write-Log 'Tray application exited.'
}
