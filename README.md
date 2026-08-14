# YaloKin

Windows tray application for starting and monitoring a legacy Hosted Network hotspot on a dedicated Ugreen USB Wi-Fi adapter. It keeps the hotspot subnet reachable when AmneziaVPN adds competing routes.

## What it does

- starts, stops, restarts, and repairs the current Microsoft Hosted Network virtual adapter;
- assigns `192.168.137.1/24` to the hotspot adapter when required;
- maintains local `192.168.137.0/25` and `192.168.137.128/25` routes with metric `1`;
- checks and automatically rebinds Internet Connection Sharing from `AmneziaVPN` to the current Hosted Network adapter;
- verifies the DHCP listeners on UDP ports `67` and `68` and repairs ICS when they disappear;
- starts the Windows SMB server and maintains an inbound TCP `445` firewall rule limited to local address `192.168.137.1` and clients in `192.168.137.0/24`;
- monitors DHCP, ICS, SMB access, the hotspot adapter, the local routes, and the AmneziaVPN default route;
- shows the current state in the Windows notification area;
- uses one router-and-radio tray icon in red (stopped), amber (no VPN or repair needed), and green (ready);
- discovers a recreated Hosted Network virtual adapter even if Windows changes its connection name or index.

The repair logic lives in `Repair-YaloKinUgreen.ps1`. The tray application calls the same script at startup, for manual repair, and when monitoring detects a broken address, route, ICS binding, DHCP listener, or SMB firewall rule. ICS changes run in a separate process with a timeout so a stuck Windows sharing API cannot freeze the tray.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1;
- a Ugreen USB Wi-Fi adapter whose driver supports `netsh wlan` Hosted Network;
- an existing Hosted Network profile;
- an AmneziaVPN connection named `AmneziaVPN`;
- administrator rights.

## Install

Download the three `.ps1` files to the same directory, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\Install-YaloKinUgreenTray.ps1"
```

The installer copies the application and repair script to `C:\ProgramData\YaloKinUgreen`, creates `YaloKin Ugreen Hotspot.lnk` on the public desktop, disables the older `YaloKin4 Route Repair` scheduled task if it exists, and starts the tray application.

## Manual repair

The same complete repair can be run without the tray application:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\Repair-YaloKinUgreen.ps1"
```

It starts or recreates Hosted Network, restores `192.168.137.1/24`, repairs both `/25` routes, checks the actual ICS public/private roles, rebinds them when needed, verifies that DHCP is listening, and enables SMB access only from the hotspot subnet.

## Tray menu

- `Start / repair hotspot`
- `Restart hotspot`
- `Stop hotspot`
- `Show details`
- `Open log`
- `Exit`

Tray events are stored at `C:\ProgramData\YaloKinUgreen\hotspot.log`; full repair and ICS operations are stored at `C:\ProgramData\YaloKinUgreen\repair.log`.

## Status

- `Ready`: hotspot, DHCP, SMB access, routes, and AmneziaVPN route are available.
- `NoVpn`: hotspot is ready, but the AmneziaVPN route is unavailable.
- `Degraded`: the hotspot is running but its address, ICS, DHCP, SMB access, or routes need attention; automatic repair is attempted once per minute.
- `Stopped`: Hosted Network is not running.

The tray icon is green for `Ready`, amber for `NoVpn` and `Degraded`, and red for `Stopped` or a status error.

## Self-test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\YaloKinUgreenTray.ps1" -SelfTest

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\Repair-YaloKinUgreen.ps1" -SelfTest
```
