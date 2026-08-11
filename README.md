# YaloKin

Windows tray application for starting and monitoring a legacy Hosted Network hotspot on a dedicated Ugreen USB Wi-Fi adapter. It keeps the hotspot subnet reachable when AmneziaVPN adds competing routes.

## What it does

- starts, stops, restarts, and repairs `YaloKin-Ugreen`;
- assigns `192.168.137.1/24` to the hotspot adapter when required;
- maintains local `192.168.137.0/25` and `192.168.137.128/25` routes with metric `1`;
- monitors DHCP, the hotspot adapter, the local routes, and the AmneziaVPN default route;
- shows the current state in the Windows notification area;
- resets only the dedicated Ugreen adapter once if Windows reports that Hosted Network is in an invalid state.

The application does not change Internet Connection Sharing bindings. Configure ICS once in `ncpa.cpl`: share `AmneziaVPN` to `YaloKin-Ugreen`.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1;
- a Ugreen USB Wi-Fi adapter whose driver supports `netsh wlan` Hosted Network;
- an existing Hosted Network profile and the network connection alias `YaloKin-Ugreen`;
- an AmneziaVPN connection named `AmneziaVPN`;
- administrator rights.

## Install

Download both `.ps1` files to the same directory, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\Install-YaloKinUgreenTray.ps1"
```

The installer copies the application to `C:\ProgramData\YaloKinUgreen`, creates `YaloKin Ugreen Hotspot.lnk` on the public desktop, disables the older `YaloKin4 Route Repair` scheduled task if it exists, and starts the tray application.

## Tray menu

- `Start / repair hotspot`
- `Restart hotspot`
- `Stop hotspot`
- `Show details`
- `Open log`
- `Exit`

The log is stored at `C:\ProgramData\YaloKinUgreen\hotspot.log`.

## Status

- `Ready`: hotspot, DHCP, routes, and AmneziaVPN route are available.
- `NoVpn`: hotspot is ready, but the AmneziaVPN route is unavailable.
- `Degraded`: the hotspot is running but its address, DHCP, or routes need attention.
- `Stopped`: Hosted Network is not running.

## Self-test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File ".\YaloKinUgreenTray.ps1" -SelfTest
```
