[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
    exit 0
}

$sourceScript = Join-Path $PSScriptRoot 'YaloKinUgreenTray.ps1'
if (-not (Test-Path -LiteralPath $sourceScript)) {
    throw "Tray script not found: $sourceScript"
}

$installDirectory = Join-Path $env:ProgramData 'YaloKinUgreen'
$targetScript = Join-Path $installDirectory 'YaloKinUgreenTray.ps1'
$desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
$shortcutPath = Join-Path $desktop 'YaloKin Ugreen Hotspot.lnk'
$powerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
Copy-Item -LiteralPath $sourceScript -Destination $targetScript -Force
Unblock-File -LiteralPath $targetScript -ErrorAction SilentlyContinue

$oldTask = Get-ScheduledTask -TaskName 'YaloKin4 Route Repair' -ErrorAction SilentlyContinue
if ($null -ne $oldTask) {
    Stop-ScheduledTask -TaskName 'YaloKin4 Route Repair' -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName 'YaloKin4 Route Repair' | Out-Null
    Write-Output 'Disabled old scheduled route-repair task.'
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powerShellPath
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$targetScript`""
$shortcut.WorkingDirectory = $installDirectory
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,18"
$shortcut.Description = 'Start and monitor YaloKin Ugreen hotspot'
$shortcut.Save()

Start-Process `
    -FilePath $powerShellPath `
    -WindowStyle Hidden `
    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$targetScript`""

Write-Output "Installed tray application: $targetScript"
Write-Output "Desktop shortcut: $shortcutPath"
Write-Output "Log file: $(Join-Path $installDirectory 'hotspot.log')"
