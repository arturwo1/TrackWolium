# Platforms

## Android

Wolium collects statistics in the background every few hours without a permanent service, so you do not need to open the app to keep the history complete. Android keeps only about a week of raw usage events, so open Wolium at least once a week if your phone is aggressive about killing background work.

Only focused time is available. Resource metrics are desktop only.

## Linux

Windows are tracked on X11 and XWayland, and natively on Hyprland and Sway. On GNOME and KDE Wayland only background time is shown for pure Wayland apps unless the bridge below is installed.

### Wayland bridge

On GNOME and KDE Plasma 6 the installer adds a small bridge (a GNOME Shell extension or a KWin script) that sends only the window class and process id to the local collector over the session D-Bus. On GNOME, log out and back in once after installing, then enable the extension:

    gnome-extensions enable wolium-bridge@dtsys

The bridge scripts are not tested on real GNOME and KDE sessions yet. If no report arrives, the collector falls back to X11 and process data.

## macOS

Open the `.dmg`, drag Wolium to Applications, right-click it and choose *Open* on first start. No Screen Recording or Accessibility access is needed.

## Feature matrix

| | Windows | Linux | macOS | Android |
|---|---|---|---|---|
| Focused / open / minimized / background | yes | yes | yes | focused only |
| Resource metrics | yes | yes | yes | no |
| Update notification | yes | yes | yes | yes |
| Local API | yes | yes | yes | yes, foreground service with a persistent notification |
| Discord activity, restart button | yes | yes | yes | no |
