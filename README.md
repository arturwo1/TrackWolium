<div align="center">

<img src="assets/icon/wolium_128.png" width="96" alt="Wolium">

# Wolium

**Private activity tracker. Your data stays on your device.**

<a href="https://github.com/arturwo1/trackwolium/releases/latest/download/WoliumSetup.exe"><img src="https://img.shields.io/badge/Windows-WoliumSetup.exe-0078D4?style=for-the-badge&logo=windows11&logoColor=white" alt="Download for Windows"></a>
<a href="https://github.com/arturwo1/trackwolium/releases/latest/download/Wolium.apk"><img src="https://img.shields.io/badge/Android-Wolium.apk-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Download for Android"></a>
<a href="https://github.com/arturwo1/trackwolium/releases/latest/download/Wolium-linux-x86_64.tar.gz"><img src="https://img.shields.io/badge/Linux-tar.gz-FCC624?style=for-the-badge&logo=linux&logoColor=black" alt="Download for Linux"></a>
<a href="https://github.com/arturwo1/trackwolium/releases/latest/download/Wolium-macos.dmg"><img src="https://img.shields.io/badge/macOS-Wolium.dmg-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS"></a>

<img src="assets/screenshot.png" width="860" alt="Wolium preview">

</div>

## What is Wolium

Wolium shows how much time you spend in each app: an interactive activity graph, a per-app table, daily leader, hidden apps and CSV export. Nothing is recorded until you accept the privacy policy, and nothing leaves your device.

## Install

| Platform | Steps |
| --- | --- |
| Windows 10 / 11 | Run `WoliumSetup.exe`. SmartScreen may warn about an unknown publisher: choose *More info*, then *Run anyway*. |
| Android 8+ | Open `Wolium.apk`, allow installing from this source, then grant *Usage access* on first start. |
| Linux (X11 / XWayland) | Extract the archive and run `./install.sh`. Windows of pure Wayland apps are not visible, so only background time is shown for them. |
| macOS 11+ | Open `Wolium-macos.dmg` and drag Wolium to Applications. On first start right-click it and choose *Open*. No Screen Recording or Accessibility access is needed. |

Wolium is not code-signed, which is why Windows and macOS show a warning on first start.

## Features

- Activity graph: zoom, pan, tooltips with per-app time and sessions down to seconds
- Time per app in four states: focused, open, minimized, background (Android: focused only)
- Date ranges: day, week, month, year or any custom period
- Hide apps you do not want to see; restore them in Settings
- CSV export and, on Android, backup and restore as a file
- Update notifications with one-click update
- Languages: English, Russian

| Graph control | Mouse | Touch |
| --- | --- | --- |
| Zoom | wheel | pinch |
| Pan | drag | drag |
| Reset | middle or double click | double tap |
| Details | hover the line, click to pin | tap, or long press and drag |

## Platform differences

| | Windows | Linux | macOS | Android |
| --- | --- | --- | --- | --- |
| Focused / open / minimized / background | yes | yes | yes | focused only |
| Update notification | yes | yes | yes | yes |
| Local API, Discord activity | yes | no | no | no |

## Android

Wolium collects statistics in the background every few hours without a permanent service, so you never need to open the app to keep the history complete. Android keeps only about a week of raw usage events, so open Wolium at least once a week if your phone is aggressive about killing background work.

## Privacy

Data is stored in a local SQLite file and never uploaded.

| Platform | Data folder |
| --- | --- |
| Windows | `%LOCALAPPDATA%\DTSys\Wolium` |
| Linux | `~/.local/share/DTSys/Wolium` |
| macOS | `~/Library/Application Support/DTSys/Wolium` |
| Android | app storage, included in Android's own backup when enabled |

Updating never touches your data, uninstalling asks first. Policy: https://wolium.netlify.app/privacy-policy/

## License

Proprietary, see [LICENSE](LICENSE). Contributions: see [CONTRIBUTING.md](CONTRIBUTING.md).
