<div align="center">

<img src="assets/icon/wolium_128.png" width="96" alt="Wolium">

# Wolium

**Private activity tracker. Your data stays on your device.**

<a href="https://github.com/arturwo1/trackwolium/releases/latest/download/WoliumSetup.exe"><img src="https://img.shields.io/badge/Windows-WoliumSetup.exe-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Download for Windows"></a>
<a href="https://github.com/arturwo1/trackwolium/releases/latest/download/Wolium.apk"><img src="https://img.shields.io/badge/Android-Wolium.apk-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Download for Android"></a>
<a href="https://github.com/arturwo1/trackwolium/releases/latest/download/Wolium-linux-x86_64.tar.gz"><img src="https://img.shields.io/badge/Linux-tar.gz-FCC624?style=for-the-badge&logo=linux&logoColor=black" alt="Download for Linux"></a>

![Disk overhead](https://img.shields.io/badge/Disk%20overhead-0%25-3ba55d)
![No network](https://img.shields.io/badge/Telemetry-none-3ba55d)
![DTSys](https://img.shields.io/badge/DTSys-proprietary-23272a)

<img src="assets/screenshot.png" width="860" alt="Wolium preview">

</div>

## What it does

Wolium shows how much time you spend in each app: a zoomable activity graph, a per-app table and CSV export. Nothing is recorded until you accept the privacy policy, and nothing leaves your device.

## Install

**Windows 10 / 11.** Run `WoliumSetup.exe`. Windows SmartScreen may warn about an unknown publisher: choose *More info*, then *Run anyway*. Wolium is not code-signed yet.

**Android 8+.** Open `Wolium.apk` and allow installing from this source. On first start grant *Usage access* to Wolium. Android only keeps about a week of history, so open the app at least once a week to keep your statistics complete.

**Linux (X11 / XWayland).** Extract the archive and run `./install.sh`. Windows of pure Wayland apps are not visible to the tracker.

## Using the graph

| Action | Mouse | Touch |
| --- | --- | --- |
| Zoom | wheel | pinch |
| Pan | drag | drag |
| Reset | middle or double click | double tap |
| Details | hover the line, click to pin | tap |

## Platform differences

| | Windows | Linux | Android |
| --- | --- | --- | --- |
| Focused / open / minimized / background | yes | yes | focused only |
| Auto-update | yes | no | no |
| Local API, Discord activity | yes | no | no |

## Privacy

Data is stored in a local SQLite file. On Windows it is `%LOCALAPPDATA%\DTSys\Wolium`, on Linux `~/.local/share/DTSys/Wolium`. Updating never touches it, uninstalling asks first. Policy: https://wolium.netlify.app/privacy-policy/

## License

Proprietary, see [LICENSE](LICENSE). Contributions: see [CONTRIBUTING.md](CONTRIBUTING.md).
