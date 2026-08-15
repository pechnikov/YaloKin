[CmdletBinding()]
param(
    [switch]$StatusWorker,
    [string]$StatusPath,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$privateName = 'YaloKin-Ugreen'
$vpnName = 'AmneziaVPN'
$hotspotAddress = '192.168.137.1'
$hotspotSubnet = '192.168.137.0/24'
$smbRuleName = 'YaloKin SMB'
$routePrefixes = @('192.168.137.0/25', '192.168.137.128/25')
$netsh = "$env:SystemRoot\System32\netsh.exe"
$powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$repairScript = Join-Path $PSScriptRoot 'Repair-YaloKinUgreen.ps1'
$logDirectory = Join-Path $env:ProgramData 'YaloKinUgreen'
$logPath = Join-Path $logDirectory 'hotspot.log'

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class YaloKinNativeIcon
{
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr handle);
}
'@

function New-HotspotIcon {
    param([Drawing.Color]$Color)

    $bitmap = New-Object Drawing.Bitmap 32, 32
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $brush = New-Object Drawing.SolidBrush $Color
    $whiteBrush = New-Object Drawing.SolidBrush ([Drawing.Color]::White)
    $pen = New-Object Drawing.Pen $Color, 3.4
    $body = New-Object Drawing.Drawing2D.GraphicsPath

    try {
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round

        $graphics.DrawArc($pen, 6, 2, 20, 14, 205, 130)
        $graphics.DrawArc($pen, 10, 7, 12, 8, 205, 130)
        $graphics.DrawLine($pen, 16, 15, 16, 21)

        $body.AddArc(4, 19, 6, 6, 180, 90)
        $body.AddArc(22, 19, 6, 6, 270, 90)
        $body.AddArc(22, 23, 6, 6, 0, 90)
        $body.AddArc(4, 23, 6, 6, 90, 90)
        $body.CloseFigure()
        $graphics.FillPath($brush, $body)
        $graphics.FillEllipse($whiteBrush, 20, 23, 3, 3)
        $graphics.FillEllipse($whiteBrush, 24, 23, 3, 3)

        $handle = $bitmap.GetHicon()
        try {
            return [Drawing.Icon]::FromHandle($handle).Clone()
        }
        finally {
            [void][YaloKinNativeIcon]::DestroyIcon($handle)
        }
    }
    finally {
        $body.Dispose()
        $pen.Dispose()
        $whiteBrush.Dispose()
        $brush.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Get-StateLevel {
    param(
        [bool]$HotspotUp,
        [bool]$AddressReady,
        [bool]$DhcpReady,
        [bool]$RoutesReady,
        [bool]$IcsReady,
        [bool]$SmbReady,
        [bool]$VpnReady
    )

    if (-not $HotspotUp) { return 'Stopped' }
    if (-not ($AddressReady -and $DhcpReady -and $RoutesReady -and $IcsReady -and
        $SmbReady)) {
        return 'Degraded'
    }
    if (-not $VpnReady) { return 'NoVpn' }
    return 'Ready'
}

if ($SelfTest) {
    $cases = @(
        @($false, $false, $false, $false, $false, $false, $false, 'Stopped'),
        @($true,  $false, $false, $false, $false, $false, $false, 'Degraded'),
        @($true,  $true,  $true,  $true,  $true,  $true,  $false, 'NoVpn'),
        @($true,  $true,  $true,  $true,  $true,  $true,  $true,  'Ready')
    )

    foreach ($case in $cases) {
        $actual = Get-StateLevel `
            $case[0] $case[1] $case[2] $case[3] $case[4] $case[5] $case[6]
        if ($actual -ne $case[7]) {
            throw "Self-test failed: expected $($case[7]), got $actual."
        }
    }

    $testIcon = New-HotspotIcon ([Drawing.ColorTranslator]::FromHtml('#2EAD5B'))
    try {
        if ($testIcon.Width -ne 32 -or $testIcon.Height -ne 32) {
            throw 'Self-test failed: generated tray icon must be 32x32.'
        }
    }
    finally {
        $testIcon.Dispose()
    }

    Write-Output 'Self-test OK.'
    exit 0
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $StatusWorker -and
    -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments
    exit 0
}

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
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -eq $privateName -or
            $_.InterfaceDescription -like '*Hosted Network Virtual Adapter*'
        } |
        Sort-Object `
            @{ Expression = { $_.Status -eq 'Up' }; Descending = $true },
            @{ Expression = { $_.Name -eq $privateName }; Descending = $true })
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

function Test-IcsReady {
    param($Adapter)

    if ($null -eq $Adapter) { return $false }
    try {
        $publicReady = $false
        $privateReady = $false
        $manager = New-Object -ComObject HNetCfg.HNetShare
        foreach ($connection in $manager.EnumEveryConnection()) {
            $properties = $manager.NetConnectionProps($connection)
            $configuration = $manager.INetSharingConfigurationForINetConnection($connection)
            if (-not $configuration.SharingEnabled) { continue }
            if ($configuration.SharingConnectionType -eq 0 -and
                $properties.Name -eq $vpnName) {
                $publicReady = $true
            }
            if ($configuration.SharingConnectionType -eq 1 -and
                $properties.Name -eq $Adapter.Name) {
                $privateReady = $true
            }
        }
        return ($publicReady -and $privateReady)
    }
    catch {
        return $false
    }
}

function Test-SmbAccessReady {
    $service = Get-Service LanmanServer -ErrorAction SilentlyContinue
    if ($null -eq $service -or $service.Status -ne 'Running') { return $false }

    $validRemoteAddresses = @(
        $hotspotSubnet,
        '192.168.137.0/255.255.255.0'
    )
    foreach ($rule in @(Get-NetFirewallRule `
        -DisplayName $smbRuleName `
        -ErrorAction SilentlyContinue)) {
        $port = $rule | Get-NetFirewallPortFilter
        $address = $rule | Get-NetFirewallAddressFilter
        if (
            $rule.Enabled.ToString() -eq 'True' -and
            $rule.Direction.ToString() -eq 'Inbound' -and
            $rule.Action.ToString() -eq 'Allow' -and
            $port.Protocol.ToString() -eq 'TCP' -and
            $port.LocalPort.ToString() -eq '445' -and
            @($address.LocalAddress) -contains $hotspotAddress -and
            @($address.RemoteAddress | Where-Object {
                $_ -in $validRemoteAddresses
            }).Count -gt 0
        ) { return $true }
    }
    return $false
}

function Stop-Hotspot {
    $stop = Invoke-Netsh -Arguments @('wlan', 'stop', 'hostednetwork')
    $adapter = Get-HotspotAdapter
    if ($stop.ExitCode -ne 0 -and $null -ne $adapter -and $adapter.Status -eq 'Up') {
        throw "Windows could not stop Hosted Network (exit $($stop.ExitCode))."
    }
    Write-Log 'Hotspot stopped.'
}

function Get-HotspotStatus {
    $adapter = Get-HotspotAdapter
    $hotspotUp = ($null -ne $adapter -and $adapter.Status -eq 'Up')
    $addressReady = $false
    $dhcpReady = $false
    $routesReady = $false
    $icsReady = $false
    $smbReady = $false

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
        $icsReady = Test-IcsReady $adapter
        $smbReady = Test-SmbAccessReady
    }

    $vpnReady = Test-VpnReady
    [pscustomobject]@{
        Level = Get-StateLevel `
            $hotspotUp $addressReady $dhcpReady $routesReady $icsReady $smbReady $vpnReady
        HotspotUp = $hotspotUp
        AddressReady = $addressReady
        DhcpReady = $dhcpReady
        RoutesReady = $routesReady
        IcsReady = $icsReady
        SmbReady = $smbReady
        VpnReady = $vpnReady
    }
}

function Get-StatusText {
    param($Status)

    return @(
        "Hotspot: $($Status.HotspotUp)",
        "Address ${hotspotAddress}: $($Status.AddressReady)",
        "DHCP: $($Status.DhcpReady)",
        "ICS binding: $($Status.IcsReady)",
        "SMB access: $($Status.SmbReady)",
        "Local /25 routes: $($Status.RoutesReady)",
        "AmneziaVPN route: $($Status.VpnReady)",
        "State: $($Status.Level)"
    ) -join [Environment]::NewLine
}

if ($StatusWorker) {
    if ([string]::IsNullOrWhiteSpace($StatusPath)) {
        throw 'Status worker requires -StatusPath.'
    }
    try {
        $json = Get-HotspotStatus | ConvertTo-Json -Compress
        [IO.File]::WriteAllText(
            $StatusPath,
            $json,
            [Text.UTF8Encoding]::new($false)
        )
        exit 0
    }
    catch {
        exit 1
    }
}

$createdNew = $false
$mutex = New-Object Threading.Mutex($true, 'Local\YaloKinUgreenTray', [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::EnableVisualStyles()

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
$script:stateIcons = @{
    Stopped = New-HotspotIcon ([Drawing.ColorTranslator]::FromHtml('#E53935'))
    Warning = New-HotspotIcon ([Drawing.ColorTranslator]::FromHtml('#F9A825'))
    Ready   = New-HotspotIcon ([Drawing.ColorTranslator]::FromHtml('#2EAD5B'))
}
$script:notify.Icon = $script:stateIcons.Stopped
$script:notify.Text = 'YaloKin Ugreen: starting'
$script:notify.Visible = $true
$script:lastLevel = $null
$script:lastStatus = $null
$script:backgroundRepair = $null
$script:backgroundRepairStarted = [datetime]::MinValue
$script:backgroundRepairName = $null
$script:lastRepairAttempt = [datetime]::MinValue
$script:backgroundStatus = $null
$script:backgroundStatusStarted = [datetime]::MinValue
$script:lastStatusCheck = [datetime]::MinValue
$statusResultPath = Join-Path $logDirectory 'status.pending.json'
$statusIntervalSeconds = 60
$statusTimeoutSeconds = 20
$repairTimeoutSeconds = 120

function Set-TrayStatusError {
    param([string]$Message)

    $script:notify.Icon = $script:stateIcons.Warning
    $script:notify.Text = 'YaloKin Ugreen: status unavailable'
    $script:statusItem.Text = "Status: $Message"
}

function Set-TrayStatus {
    param([Parameter(Mandatory)]$Status)

    switch ($Status.Level) {
        'Ready' {
            $script:notify.Icon = $script:stateIcons.Ready
            $tip = 'YaloKin Ugreen: ready | Amnezia: connected'
        }
        'NoVpn' {
            $script:notify.Icon = $script:stateIcons.Warning
            $tip = 'YaloKin Ugreen: ready | Amnezia: unavailable'
        }
        'Degraded' {
            $script:notify.Icon = $script:stateIcons.Warning
            $tip = 'YaloKin Ugreen: repair needed'
        }
        default {
            $script:notify.Icon = $script:stateIcons.Stopped
            $tip = 'YaloKin Ugreen: stopped'
        }
    }

    $script:notify.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
    $script:statusItem.Text = "Status: $($Status.Level)"

    if ($script:lastLevel -ne $Status.Level) {
        $icon = if ($Status.Level -eq 'Ready') {
            [Windows.Forms.ToolTipIcon]::Info
        } else {
            [Windows.Forms.ToolTipIcon]::Warning
        }
        $script:notify.ShowBalloonTip(4000, 'YaloKin Ugreen', $tip, $icon)
        Write-Log "State changed to $($Status.Level)."
        $script:lastLevel = $Status.Level
    }
}

function Stop-BackgroundStatusCheck {
    if ($null -eq $script:backgroundStatus) { return }
    if (-not $script:backgroundStatus.HasExited) {
        Stop-Process -Id $script:backgroundStatus.Id -Force -ErrorAction SilentlyContinue
    }
    $script:backgroundStatus.Dispose()
    $script:backgroundStatus = $null
    Remove-Item -LiteralPath $statusResultPath -Force -ErrorAction SilentlyContinue
}

function Update-BackgroundRepair {
    if ($null -eq $script:backgroundRepair) { return }
    if (-not $script:backgroundRepair.HasExited) {
        if (((Get-Date) - $script:backgroundRepairStarted).TotalSeconds -le
            $repairTimeoutSeconds) { return }

        Stop-Process -Id $script:backgroundRepair.Id -Force -ErrorAction SilentlyContinue
        Write-Log "$($script:backgroundRepairName) timed out after $repairTimeoutSeconds seconds."
        $script:notify.ShowBalloonTip(
            5000,
            'YaloKin Ugreen error',
            'Hotspot repair timed out. See repair.log.',
            [Windows.Forms.ToolTipIcon]::Error
        )
        $script:backgroundRepair.Dispose()
        $script:backgroundRepair = $null
        $script:lastStatusCheck = [datetime]::MinValue
        return
    }

    $exitCode = $script:backgroundRepair.ExitCode
    $name = $script:backgroundRepairName
    $script:backgroundRepair.Dispose()
    $script:backgroundRepair = $null
    if ($exitCode -eq 0) {
        Write-Log "$name succeeded."
    } else {
        Write-Log "$name failed with exit code $exitCode."
        $script:notify.ShowBalloonTip(
            5000,
            'YaloKin Ugreen error',
            "Hotspot repair failed with exit code $exitCode. See repair.log.",
            [Windows.Forms.ToolTipIcon]::Error
        )
    }
    $script:lastStatusCheck = [datetime]::MinValue
}

function Start-BackgroundRepair {
    param(
        [string]$Name = 'Automatic repair',
        [switch]$Restart
    )

    Update-BackgroundRepair
    if ($null -ne $script:backgroundRepair) {
        Write-Log "$Name skipped because a repair is already running."
        return
    }
    if (-not (Test-Path -LiteralPath $repairScript)) {
        Write-Log "Repair script not found: $repairScript"
        return
    }

    Stop-BackgroundStatusCheck
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$repairScript`" -Quiet"
    if ($Restart) { $arguments += ' -Restart' }
    $script:backgroundRepair = Start-Process `
        -FilePath $powerShell `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -PassThru
    $script:backgroundRepairStarted = Get-Date
    $script:backgroundRepairName = $Name
    $script:lastRepairAttempt = $script:backgroundRepairStarted
    $script:notify.Icon = $script:stateIcons.Warning
    $script:notify.Text = 'YaloKin Ugreen: repairing'
    $script:statusItem.Text = 'Status: repairing'
    Write-Log "$Name started in the background."
}

function Start-BackgroundStatusCheck {
    if ($null -ne $script:backgroundRepair -or
        $null -ne $script:backgroundStatus -or
        ((Get-Date) - $script:lastStatusCheck).TotalSeconds -lt
            $statusIntervalSeconds) { return }

    Remove-Item -LiteralPath $statusResultPath -Force -ErrorAction SilentlyContinue
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -StatusWorker -StatusPath `"$statusResultPath`""
    $script:backgroundStatus = Start-Process `
        -FilePath $powerShell `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -PassThru
    $script:backgroundStatusStarted = Get-Date
    $script:lastStatusCheck = $script:backgroundStatusStarted
}

function Update-BackgroundStatus {
    if ($null -eq $script:backgroundStatus) { return }
    if (-not $script:backgroundStatus.HasExited) {
        if (((Get-Date) - $script:backgroundStatusStarted).TotalSeconds -le
            $statusTimeoutSeconds) { return }

        Stop-BackgroundStatusCheck
        $script:lastStatusCheck = Get-Date
        Set-TrayStatusError 'timeout'
        Write-Log "Status check timed out after $statusTimeoutSeconds seconds."
        return
    }

    $exitCode = $script:backgroundStatus.ExitCode
    $script:backgroundStatus.Dispose()
    $script:backgroundStatus = $null
    $script:lastStatusCheck = Get-Date
    try {
        if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $statusResultPath)) {
            throw "Status worker exited with code $exitCode."
        }
        $status = Get-Content -Raw -LiteralPath $statusResultPath | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace($status.Level)) {
            throw 'Status worker returned an invalid result.'
        }
        $script:lastStatus = $status
        Set-TrayStatus $status

        if ($status.Level -eq 'Degraded' -and
            ((Get-Date) - $script:lastRepairAttempt).TotalSeconds -ge 60) {
            Start-BackgroundRepair
        }
    }
    catch {
        Set-TrayStatusError 'error'
        Write-Log "Status error: $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $statusResultPath -Force -ErrorAction SilentlyContinue
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
    $script:lastStatusCheck = [datetime]::MinValue
    Start-BackgroundStatusCheck
}

$startItem.Add_Click({ Start-BackgroundRepair -Name 'Manual repair' })
$restartItem.Add_Click({ Start-BackgroundRepair -Name 'Manual restart' -Restart })
$stopItem.Add_Click({ Invoke-TrayAction 'Stop' { Stop-Hotspot } })
$detailsItem.Add_Click({
    $text = if ($null -eq $script:lastStatus) {
        'Status check is still in progress.'
    } else {
        Get-StatusText $script:lastStatus
    }
    [void][Windows.Forms.MessageBox]::Show(
        $text,
        'YaloKin Ugreen status',
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Information
    )
})
$script:notify.Add_DoubleClick({
    $text = if ($null -eq $script:lastStatus) {
        'Status check is still in progress.'
    } else {
        Get-StatusText $script:lastStatus
    }
    [void][Windows.Forms.MessageBox]::Show(
        $text,
        'YaloKin Ugreen status'
    )
})
$logItem.Add_Click({
    Write-Log 'Log opened.'
    Start-Process notepad.exe -ArgumentList "`"$logPath`""
})
$exitItem.Add_Click({ [Windows.Forms.Application]::ExitThread() })

$script:timer = New-Object Windows.Forms.Timer
$script:timer.Interval = 1000
$script:timer.Add_Tick({
    try {
        Update-BackgroundRepair
        Update-BackgroundStatus
        Start-BackgroundStatusCheck
    }
    catch {
        Set-TrayStatusError 'error'
        Write-Log "Background monitor failed: $($_.Exception.Message)"
    }
})

Write-Log 'Tray application started.'
Start-BackgroundRepair -Name 'Automatic start'
$script:timer.Start()

try {
    [Windows.Forms.Application]::Run()
}
finally {
    $script:timer.Stop()
    $script:timer.Dispose()
    Stop-BackgroundStatusCheck
    if ($null -ne $script:backgroundRepair) {
        $script:backgroundRepair.Dispose()
    }
    $script:notify.Visible = $false
    $script:notify.Dispose()
    foreach ($icon in $script:stateIcons.Values) { $icon.Dispose() }
    $script:menu.Dispose()
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    Write-Log 'Tray application exited.'
}
