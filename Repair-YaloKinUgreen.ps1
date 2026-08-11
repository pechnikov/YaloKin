[CmdletBinding()]
param(
    [string]$PublicName = 'AmneziaVPN',
    [string]$Ssid = 'YaloKin-Ugreen',
    [string]$PrivateName,
    [switch]$IcsWorker,
    [switch]$ForcePrivate,
    [switch]$Quiet,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$hotspotAddress = '192.168.137.1'
$routePrefixes = @('192.168.137.0/25', '192.168.137.128/25')
$netsh = "$env:SystemRoot\System32\netsh.exe"
$logDirectory = Join-Path $env:ProgramData 'YaloKinUgreen'
$logPath = Join-Path $logDirectory 'repair.log'

function Write-RepairLog {
    param([string]$Message)

    try {
        if (-not (Test-Path -LiteralPath $logDirectory)) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        Add-Content -LiteralPath $logPath -Encoding UTF8 -Value (
            '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
        )
    }
    catch {
        # Logging must not prevent repair.
    }

    if (-not $Quiet) { Write-Output $Message }
}

function Test-IcsRoleSet {
    param(
        [object[]]$Bindings,
        [string]$ExpectedPublic,
        [string]$ExpectedPrivate
    )

    $publicReady = @($Bindings | Where-Object {
        $_.Name -eq $ExpectedPublic -and $_.Type -eq 'Public'
    }).Count -eq 1
    $privateReady = @($Bindings | Where-Object {
        $_.Name -eq $ExpectedPrivate -and $_.Type -eq 'Private'
    }).Count -eq 1
    return ($publicReady -and $privateReady)
}

if ($SelfTest) {
    $good = @(
        [pscustomobject]@{ Name = 'AmneziaVPN'; Type = 'Public' },
        [pscustomobject]@{ Name = 'Hosted'; Type = 'Private' }
    )
    $bad = @([pscustomobject]@{ Name = 'Old hosted'; Type = 'Private' })
    if (-not (Test-IcsRoleSet $good 'AmneziaVPN' 'Hosted')) {
        throw 'Self-test failed for a valid ICS role set.'
    }
    if (Test-IcsRoleSet $bad 'AmneziaVPN' 'Hosted') {
        throw 'Self-test failed for an invalid ICS role set.'
    }
    Write-Output 'Self-test OK.'
    exit 0
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdministrator = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdministrator) {
    if ($IcsWorker) { throw 'ICS worker requires administrator rights.' }

    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -PublicName `"$PublicName`" -Ssid `"$Ssid`""
    if ($Quiet) { $arguments += ' -Quiet' }
    $process = Start-Process powershell.exe `
        -Verb RunAs `
        -ArgumentList $arguments `
        -Wait `
        -PassThru
    exit $process.ExitCode
}

function Get-IcsConnections {
    $manager = New-Object -ComObject HNetCfg.HNetShare
    foreach ($connection in $manager.EnumEveryConnection()) {
        $properties = $manager.NetConnectionProps($connection)
        $configuration = $manager.INetSharingConfigurationForINetConnection($connection)
        [pscustomobject]@{
            Name = $properties.Name
            Connection = $connection
            Configuration = $configuration
            Enabled = [bool]$configuration.SharingEnabled
            Type = if (-not $configuration.SharingEnabled) {
                '-'
            } elseif ($configuration.SharingConnectionType -eq 0) {
                'Public'
            } else {
                'Private'
            }
        }
    }
}

function Invoke-IcsWorker {
    foreach ($serviceName in 'EventSystem', 'BFE', 'MpsSvc', 'SharedAccess') {
        Start-Service $serviceName -ErrorAction SilentlyContinue
    }

    $mobileHotspot = Get-Service icssvc -ErrorAction SilentlyContinue
    if ($null -ne $mobileHotspot -and $mobileHotspot.Status -eq 'Running') {
        Stop-Service icssvc -Force -ErrorAction SilentlyContinue
        Write-RepairLog 'Stopped the modern Mobile Hotspot service.'
    }

    $connections = @(Get-IcsConnections)
    $public = @($connections | Where-Object Name -eq $PublicName)
    $private = @($connections | Where-Object Name -eq $PrivateName)
    if ($public.Count -ne 1) {
        throw "Expected one connection named '$PublicName', found $($public.Count)."
    }
    if ($private.Count -ne 1) {
        throw "Expected one connection named '$PrivateName', found $($private.Count)."
    }

    foreach ($item in $connections) {
        $wrongPublic = $item.Enabled -and $item.Type -eq 'Public' -and
            $item.Name -ne $PublicName
        $wrongPrivate = $item.Enabled -and $item.Type -eq 'Private' -and
            ($item.Name -ne $PrivateName -or $ForcePrivate)
        if ($wrongPublic -or $wrongPrivate) {
            try {
                $item.Configuration.DisableSharing()
                Write-RepairLog "Disabled stale ICS role on '$($item.Name)'."
            }
            catch {
                Write-RepairLog "Could not disable ICS on '$($item.Name)': $($_.Exception.Message)"
            }
        }
    }

    if ($ForcePrivate -or -not ($private[0].Enabled -and $private[0].Type -eq 'Private')) {
        try {
            $putOptions = [System.Management.PutOptions]::new()
            $putOptions.Type = [System.Management.PutType]::UpdateOnly
            Get-WmiObject -Namespace 'root\Microsoft\HomeNet' `
                -Class HNet_ConnectionProperties `
                -ErrorAction SilentlyContinue |
                Where-Object IsIcsPrivate |
                ForEach-Object {
                    $_.IsIcsPrivate = $false
                    [void]$_.Put($putOptions)
                }
        }
        catch {
            Write-RepairLog "Could not clear stale private ICS flags: $($_.Exception.Message)"
        }
    }

    Start-Sleep -Seconds 2
    $connections = @(Get-IcsConnections)
    $public = @($connections | Where-Object Name -eq $PublicName)[0]
    $private = @($connections | Where-Object Name -eq $PrivateName)[0]

    if (-not ($public.Enabled -and $public.Type -eq 'Public')) {
        try {
            $public.Configuration.EnableSharing(0)
            Write-RepairLog "Enabled public ICS on '$PublicName'."
        }
        catch {
            Write-RepairLog "Public ICS call returned an error: $($_.Exception.Message)"
        }
    }

    $connections = @(Get-IcsConnections)
    $private = @($connections | Where-Object Name -eq $PrivateName)[0]
    if (-not ($private.Enabled -and $private.Type -eq 'Private')) {
        try {
            $private.Configuration.EnableSharing(1)
            Write-RepairLog "Enabled private ICS on '$PrivateName'."
        }
        catch {
            Write-RepairLog "Private ICS call returned an error: $($_.Exception.Message)"
        }
    }
}

if ($IcsWorker) {
    if ([string]::IsNullOrWhiteSpace($PrivateName)) {
        throw 'ICS worker requires -PrivateName.'
    }
    Invoke-IcsWorker
    exit 0
}

function Invoke-Netsh {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $netsh @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    $message = @($output | ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_ }) -join ' '
    Write-RepairLog "netsh $($Arguments -join ' '): exit=$exitCode; $message"
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $message }
}

function Get-HotspotAdapter {
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object InterfaceDescription -like '*Hosted Network Virtual Adapter*' |
        Sort-Object @{ Expression = { $_.Status -eq 'Up' }; Descending = $true })
    if ($adapters.Count -eq 0) { return $null }
    return $adapters[0]
}

function Start-OrRepairHostedNetwork {
    Start-Service WlanSvc -ErrorAction SilentlyContinue

    $ugreen = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object InterfaceDescription -like '*Ugreen*')
    if ($ugreen.Count -eq 0) { throw 'Ugreen USB Wi-Fi adapter was not found.' }
    if ($ugreen[0].Status -eq 'Disabled') {
        $ugreen[0] | Enable-NetAdapter -Confirm:$false
        Start-Sleep -Seconds 3
    }

    $allow = Invoke-Netsh @('wlan', 'set', 'hostednetwork', 'mode=allow', "ssid=$Ssid")
    if ($allow.ExitCode -ne 0) { throw 'Could not enable Hosted Network mode.' }

    $start = Invoke-Netsh @('wlan', 'start', 'hostednetwork')
    if ($start.ExitCode -ne 0) {
        Write-RepairLog 'Hosted Network is unavailable; recreating its virtual adapter.'
        [void](Invoke-Netsh @('wlan', 'stop', 'hostednetwork'))
        [void](Invoke-Netsh @('wlan', 'set', 'hostednetwork', 'mode=disallow'))

        $devices = @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue |
            Where-Object FriendlyName -eq 'Microsoft Hosted Network Virtual Adapter')
        foreach ($device in $devices) {
            & pnputil.exe /remove-device "$($device.InstanceId)" | Out-Null
        }

        Restart-Service WlanSvc -Force
        & pnputil.exe /scan-devices | Out-Null
        Start-Sleep -Seconds 5

        $allow = Invoke-Netsh @('wlan', 'set', 'hostednetwork', 'mode=allow', "ssid=$Ssid")
        if ($allow.ExitCode -ne 0) { throw 'Could not recreate Hosted Network mode.' }
        $start = Invoke-Netsh @('wlan', 'start', 'hostednetwork')
        if ($start.ExitCode -ne 0) {
            throw 'Could not start Hosted Network after recreating its virtual adapter.'
        }
    }

    Start-Sleep -Seconds 3
    $adapter = Get-HotspotAdapter
    if ($null -eq $adapter -or $adapter.Status -ne 'Up') {
        throw 'Hosted Network started, but its virtual adapter is not active.'
    }
    return $adapter
}

function Set-HotspotNetworkConfiguration {
    param([Parameter(Mandatory)]$Adapter)

    $address = Get-NetIPAddress `
        -InterfaceIndex $Adapter.InterfaceIndex `
        -AddressFamily IPv4 `
        -IPAddress $hotspotAddress `
        -ErrorAction SilentlyContinue
    if ($null -eq $address) {
        $result = Invoke-Netsh @(
            'interface', 'ipv4', 'set', 'address',
            "name=$($Adapter.Name)", 'source=static', "address=$hotspotAddress",
            'mask=255.255.255.0', 'gateway=none', 'store=persistent'
        )
        if ($result.ExitCode -ne 0) {
            throw "Could not assign $hotspotAddress to '$($Adapter.Name)'."
        }
        Start-Sleep -Seconds 2
    }

    Set-NetIPInterface `
        -InterfaceIndex $Adapter.InterfaceIndex `
        -AddressFamily IPv4 `
        -InterfaceMetric 1

    foreach ($prefix in $routePrefixes) {
        $routes = @(Get-NetRoute `
            -DestinationPrefix $prefix `
            -InterfaceIndex $Adapter.InterfaceIndex `
            -ErrorAction SilentlyContinue |
            Where-Object NextHop -eq '0.0.0.0')
        if ($routes.Count -eq 0) {
            New-NetRoute `
                -DestinationPrefix $prefix `
                -InterfaceIndex $Adapter.InterfaceIndex `
                -NextHop '0.0.0.0' `
                -RouteMetric 1 | Out-Null
        } else {
            $routes | Where-Object RouteMetric -ne 1 |
                Set-NetRoute -RouteMetric 1 -Confirm:$false
        }
    }
}

function Get-IcsBindings {
    @(Get-IcsConnections | Where-Object Enabled |
        ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Type = $_.Type }
        })
}

function Test-DhcpReady {
    $ports = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LocalPort -In 67, 68 -and
            $_.LocalAddress -In $hotspotAddress, '0.0.0.0'
        } |
        Select-Object -ExpandProperty LocalPort -Unique)
    return ($ports -contains 67 -and $ports -contains 68)
}

function Invoke-IcsRepairProcess {
    param(
        [string]$PowerShellPath,
        [string]$CurrentPrivateName,
        [bool]$Force
    )

    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -IcsWorker -Quiet -PublicName `"$PublicName`" -PrivateName `"$CurrentPrivateName`""
    if ($Force) { $arguments += ' -ForcePrivate' }
    $process = Start-Process `
        -FilePath $PowerShellPath `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -PassThru

    if (-not $process.WaitForExit(20000)) {
        Write-RepairLog "ICS worker timed out in $PowerShellPath; terminating it."
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    } else {
        Write-RepairLog "ICS worker exited with code $($process.ExitCode)."
    }
}

function Ensure-IcsBinding {
    param([Parameter(Mandatory)]$Adapter)

    $bindings = @(Get-IcsBindings)
    $bindingReady = Test-IcsRoleSet $bindings $PublicName $Adapter.Name
    $dhcpReady = Test-DhcpReady
    if ($bindingReady -and $dhcpReady) {
        Write-RepairLog 'ICS binding and DHCP listener are ready.'
        return
    }

    Write-RepairLog "Repairing ICS: bindingReady=$bindingReady; dhcpReady=$dhcpReady; private='$($Adapter.Name)'."
    $forcePrivateBinding = $bindingReady -and -not $dhcpReady
    $workers = @(
        "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe",
        "$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
    ) | Select-Object -Unique

    foreach ($worker in $workers) {
        if (-not (Test-Path -LiteralPath $worker)) { continue }
        Invoke-IcsRepairProcess $worker $Adapter.Name $forcePrivateBinding
        Start-Sleep -Seconds 2

        $Adapter = Get-HotspotAdapter
        Set-HotspotNetworkConfiguration $Adapter
        Start-Service SharedAccess -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5

        $bindings = @(Get-IcsBindings)
        if ((Test-IcsRoleSet $bindings $PublicName $Adapter.Name) -and
            (Test-DhcpReady)) {
            Write-RepairLog 'ICS was rebound and DHCP is listening.'
            return
        }
        $forcePrivateBinding = $true
    }

    $roles = @(Get-IcsBindings | ForEach-Object { "$($_.Name)=$($_.Type)" }) -join ', '
    throw "ICS repair did not create DHCP listeners. Current roles: $roles"
}

try {
    Write-RepairLog 'Repair started.'
    $adapter = Start-OrRepairHostedNetwork
    Set-HotspotNetworkConfiguration $adapter
    Ensure-IcsBinding $adapter
    $adapter = Get-HotspotAdapter
    Set-HotspotNetworkConfiguration $adapter
    Write-RepairLog "Repair completed: adapter='$($adapter.Name)', ifIndex=$($adapter.InterfaceIndex)."
    exit 0
}
catch {
    Write-RepairLog "Repair failed: $($_.Exception.Message)"
    Write-Error $_
    exit 1
}
