# Platforms

## Android

Wolium collects statistics and battery level/drain in the background via `SyncWorker` without a permanent background notification, and silently synchronizes paired LAN devices (including full history and stale peers older than 60 minutes) without leaving a persistent P2P notification. Android keeps only about a week of raw usage events, so open Wolium at least once a week if your phone is aggressive about killing background work.

Only focused time and per-app battery drain are recorded locally on Android, along with battery charge snapshots, unlocks, sleep, lock, and shutdown events. When paired desktop devices are enabled in the device filter, desktop states (`focused`, `open`, `minimized`, `background`), resource metrics, hardware totals, sorting options, and CSV columns become available in the Android UI.

An optional Accessibility Service (**Settings → Browser website tracking**) can track visited domains and clean page titles across supported mobile browsers. On Android 13+, if the system marks Accessibility as a *Restricted setting* for sideloaded APKs, open **App Info** (button provided right next to Accessibility Settings) → **⋮** menu → **Allow restricted settings**, then enable Wolium in Accessibility. List interactions support either explicit action buttons or gestures (long-press context menu), configurable in Settings.

## Linux

Windows are tracked on X11 and XWayland, and natively on Hyprland and Sway. On GNOME and KDE Wayland only background time is shown for pure Wayland apps unless the bridge below is installed. Power states (`sleep`, `hibernate`, `lock`, `reboot`, `shutdown`) and battery charge are tracked via systemd-logind / `/sys/class/power_supply`.

### Wayland bridge

On GNOME and KDE Plasma 6 the installer adds a small bridge (a GNOME Shell extension or a KWin script) that sends only the window class and process id to the local collector over the session D-Bus. On GNOME, log out and back in once after installing, then enable the extension:

    gnome-extensions enable wolium-bridge@dtsys

The bridge scripts are not tested on real GNOME and KDE sessions yet. If no report arrives, the collector falls back to X11 and process data.

## macOS

Open the `.dmg`, drag Wolium to Applications, right-click it and choose *Open* on first start. No Screen Recording or Accessibility access is needed. Power states are tracked via `NSWorkspace` notifications and battery status via `IOPowerSources`.

## Feature matrix

| | Windows | Linux | macOS | Android |
|---|---|---|---|---|
| Focused / open / minimized / background | yes | yes | yes | focused locally (all states from remote PCs) |
| Resource metrics & global hardware | yes | yes | yes | battery + remote PCs via LAN sync |
| Battery level & per-app drain | laptop / UPS level | laptop / UPS level | laptop level | battery level + per-app drain |
| Power states (sleep/hibernate/lock/reboot/shutdown) | yes | yes | yes | sleep / lock / shutdown |
| Browser website titles | extension | extension | extension | optional Accessibility Service |
| Update notification | yes | yes | yes | yes |
| Local API | yes | yes | yes | yes, foreground service with notification when enabled |
| Discord activity, restart button | yes | yes | yes | no |


